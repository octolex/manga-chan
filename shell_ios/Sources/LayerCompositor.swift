//
//  LayerCompositor.swift
//
//  Executes the plan the engine hands us: under cache + live layers + over
//  cache. Everything below the layer being painted is flattened into one
//  texture, everything above into another, and only the layers between are
//  recomposited each frame.
//
//  Uses programmable blending — `[[color(0)]]` as a fragment input — to read
//  the destination out of tile memory rather than ping-ponging between
//  textures. That is unconditional on iPadOS (MSL Specification Table 5.5,
//  p146) but is NOT available on the iOS Simulator, which rejects it at
//  pipeline creation. The app therefore only runs on device; the simulator is
//  used for the engine and blend-maths tests, which do not construct this
//  class. See docs/metal-verified.md.
//

import Metal
import simd

final class LayerCompositor {

    private let device: MTLDevice
    private let pixelFormat: MTLPixelFormat

    /// Layer over destination, with a blend mode. Reads the destination from
    /// tile memory.
    private let blendPipeline: MTLRenderPipelineState
    /// Straight copy, no blending.
    private let blitPipeline: MTLRenderPipelineState
    /// r8 stroke coverage tinted with the ink colour, alpha-blended.
    private let inkPipeline: MTLRenderPipelineState

    private var width = 0
    private var height = 0

    private var layerTextures: [MCLayerId: MTLTexture] = [:]
    private var staleLayers: Set<MCLayerId> = []

    private var underCache: MTLTexture?
    private var overCache: MTLTexture?
    /// The active layer merged with the stroke in progress, before its own
    /// blend mode is applied.
    private var activeTemp: MTLTexture?

    private var tileScratch: [UInt8]
    private let tileSize: Int

    /// Paper colour behind everything. The background layer is modelled as a
    /// clear colour rather than pixels, so the compositor skips a whole layer
    /// of blending and export knows the page has an opaque ground.
    var backgroundColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)

    private(set) var layerUploads: UInt64 = 0

    init(device: MTLDevice, library: MTLLibrary,
         pixelFormat: MTLPixelFormat, tileSize: Int) throws {
        self.device = device
        self.pixelFormat = pixelFormat
        self.tileSize = tileSize
        self.tileScratch = [UInt8](repeating: 0, count: tileSize * tileSize * 4)

        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else {
                throw RendererError.missingFunction(name)
            }
            return f
        }

        // Programmable blending: the shader returns the finished result, so
        // fixed-function blending must stay off or it would blend the blend.
        let blend = MTLRenderPipelineDescriptor()
        blend.label = "Layer blend"
        blend.vertexFunction = try function("blend_vertex")
        blend.fragmentFunction = try function("blend_fragment")
        blend.colorAttachments[0].pixelFormat = pixelFormat
        blend.colorAttachments[0].isBlendingEnabled = false
        self.blendPipeline = try device.makeRenderPipelineState(descriptor: blend)

        let blit = MTLRenderPipelineDescriptor()
        blit.label = "Layer copy"
        blit.vertexFunction = try function("fullscreen_vertex")
        blit.fragmentFunction = try function("blit_fragment")
        blit.colorAttachments[0].pixelFormat = pixelFormat
        self.blitPipeline = try device.makeRenderPipelineState(descriptor: blit)

        let ink = MTLRenderPipelineDescriptor()
        ink.label = "Wet stroke"
        ink.vertexFunction = try function("fullscreen_vertex")
        ink.fragmentFunction = try function("composite_fragment")
        let attachment = ink.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one          // premultiplied source
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.inkPipeline = try device.makeRenderPipelineState(descriptor: ink)
    }

    // MARK: - Lifecycle

    func resize(width: Int, height: Int) {
        guard width > 0, height > 0, width != self.width || height != self.height else { return }
        self.width = width
        self.height = height

        // Every texture is screen-sized, so all of them are now the wrong size.
        layerTextures.removeAll()
        underCache = makeTexture("Under cache")
        overCache = makeTexture("Over cache")
        activeTemp = makeTexture("Active layer + stroke")
        Diagnostics.log("compositor resized to \(width)×\(height)")
    }

    func markLayerStale(_ layer: MCLayerId) {
        staleLayers.insert(layer)
    }

    func markAllLayersStale() {
        staleLayers.formUnion(layerTextures.keys)
    }

    /// Drops a layer's texture entirely, for a layer that no longer exists.
    func forgetLayer(_ layer: MCLayerId) {
        layerTextures.removeValue(forKey: layer)
        staleLayers.remove(layer)
    }

    func texture(for layer: MCLayerId) -> MTLTexture? { layerTextures[layer] }

    private func makeTexture(_ label: String) -> MTLTexture? {
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        // Shared so the CPU can read a layer back at stroke end. On unified
        // memory that costs nothing extra.
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = label
        return texture
    }

    // MARK: - Uploading layer pixels

    /// Brings a layer's texture in line with engine storage, if it has gone
    /// stale. Uploading is per-layer rather than per-frame: layers change when
    /// the user edits them, not sixty times a second.
    func syncLayer(_ layer: MCLayerId, engine: CanvasEngine) {
        var texture = layerTextures[layer]
        if texture == nil {
            texture = makeTexture("Layer \(layer)")
            layerTextures[layer] = texture
            staleLayers.insert(layer)
        }
        guard let texture, staleLayers.contains(layer) else { return }

        let bytesPerRow = tileSize * 4
        let columns = (width + tileSize - 1) / tileSize
        let rows = (height + tileSize - 1) / tileSize

        for ty in 0..<rows {
            for tx in 0..<columns {
                let originX = tx * tileSize
                let originY = ty * tileSize
                let regionWidth = min(tileSize, width - originX)
                let regionHeight = min(tileSize, height - originY)
                guard regionWidth > 0, regionHeight > 0 else { continue }

                let tile = EngineTile(x: Int32(tx), y: Int32(ty))
                let loaded = tileScratch.withUnsafeMutableBufferPointer { buffer -> Bool in
                    guard let base = buffer.baseAddress else { return false }
                    return engine.loadTile(tile, from: layer, into: base)
                }
                if !loaded {
                    // Never painted. Transparent rather than skipped: the
                    // texture may hold whatever a previous layer left there.
                    for index in tileScratch.indices { tileScratch[index] = 0 }
                }

                tileScratch.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    texture.replace(region: MTLRegionMake2D(originX, originY,
                                                            regionWidth, regionHeight),
                                    mipmapLevel: 0,
                                    withBytes: base,
                                    bytesPerRow: bytesPerRow)
                }
            }
        }

        staleLayers.remove(layer)
        layerUploads += 1
    }

    // MARK: - Compositing

    /// Index of the layer a clipped layer masks against: the nearest unclipped
    /// layer below it within the same run. Photoshop semantics — the clip is
    /// against the base's alpha, not the accumulated result beneath it.
    private func clipBase(for index: Int, in layers: [MCLayerId],
                          engine: CanvasEngine) -> MTLTexture? {
        var i = index
        while i > 0 {
            i -= 1
            guard let properties = engine.properties(of: layers[i]) else { return nil }
            if !properties.clipToBelow {
                return layerTextures[layers[i]]
            }
        }
        return nil
    }

    private func composite(_ layers: [MCLayerId], into encoder: MTLRenderCommandEncoder,
                           engine: CanvasEngine,
                           overrideTexture: [MCLayerId: MTLTexture] = [:]) {
        for (index, id) in layers.enumerated() {
            guard let properties = engine.properties(of: id), properties.visible else { continue }
            guard let source = overrideTexture[id] ?? layerTextures[id] else { continue }

            var mask: MTLTexture? = nil
            if properties.clipToBelow {
                mask = clipBase(for: index, in: layers, engine: engine)
                // A clipped layer with no base below it in this run has
                // nothing to clip to; drawing it unmasked matches how the
                // planner treats a clipped layer at the bottom of the stack.
            }

            var uniforms = MSBlendUniforms(mode: properties.blend,
                                           opacity: properties.opacity,
                                           useClipMask: mask != nil ? 1 : 0,
                                           _pad: 0)
            encoder.setRenderPipelineState(blendPipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentTexture(mask ?? source, index: 2)
            encoder.setFragmentBytes(&uniforms,
                                     length: MemoryLayout<MSBlendUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    /// Flattens a set of layers onto transparent. Valid only for runs the
    /// planner has already established are cacheable.
    func rebuildCache(_ layers: [MCLayerId], into target: MTLTexture?,
                      engine: CanvasEngine, commandBuffer: MTLCommandBuffer) {
        guard let target else { return }
        for id in layers { syncLayer(id, engine: engine) }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Flatten \(layers.count) layers"
        composite(layers, into: encoder, engine: engine)
        encoder.endEncoding()
    }

    func rebuildUnderCache(_ layers: [MCLayerId], engine: CanvasEngine,
                           commandBuffer: MTLCommandBuffer) {
        rebuildCache(layers, into: underCache, engine: engine, commandBuffer: commandBuffer)
    }

    func rebuildOverCache(_ layers: [MCLayerId], engine: CanvasEngine,
                          commandBuffer: MTLCommandBuffer) {
        rebuildCache(layers, into: overCache, engine: engine, commandBuffer: commandBuffer)
    }

    /// Merges the wet stroke into a copy of the active layer, so the layer's
    /// own blend mode applies to the combined result rather than to each half
    /// separately.
    private func buildActiveTemp(layer: MCLayerId, coverage: MTLTexture,
                                 inkColor: simd_float4, commandBuffer: MTLCommandBuffer) {
        guard let target = activeTemp, let source = layerTextures[layer] else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Active layer + wet stroke"

        encoder.setRenderPipelineState(blitPipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        var ink = inkColor
        encoder.setRenderPipelineState(inkPipeline)
        encoder.setFragmentTexture(coverage, index: 0)
        encoder.setFragmentBytes(&ink, length: MemoryLayout<simd_float4>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.endEncoding()
    }

    /// Draws the finished stroke permanently into a layer's texture.
    ///
    /// Called once, on the committing frame, before the layer is read back to
    /// the engine. Loading rather than clearing is the point: the stroke is
    /// added to what the layer already holds.
    func flattenStroke(into layer: MCLayerId, coverage: MTLTexture,
                       inkColor: simd_float4, commandBuffer: MTLCommandBuffer) {
        guard let target = layerTextures[layer] else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Commit stroke into layer"

        var ink = inkColor
        encoder.setRenderPipelineState(inkPipeline)
        encoder.setFragmentTexture(coverage, index: 0)
        encoder.setFragmentBytes(&ink, length: MemoryLayout<simd_float4>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Draws the finished frame.
    func present(into target: MTLTexture, plan: CompositePlanSnapshot,
                 engine: CanvasEngine, strokeCoverage: MTLTexture?,
                 inkColor: simd_float4, commandBuffer: MTLCommandBuffer) {

        for id in plan.live { syncLayer(id, engine: engine) }

        // Fold the wet stroke into the active layer first, so the layer's blend
        // mode sees one combined image.
        var overrides: [MCLayerId: MTLTexture] = [:]
        if let coverage = strokeCoverage,
           plan.activeLayer != MC_INVALID_LAYER,
           plan.live.contains(plan.activeLayer) {
            buildActiveTemp(layer: plan.activeLayer, coverage: coverage,
                            inkColor: inkColor, commandBuffer: commandBuffer)
            if let temp = activeTemp { overrides[plan.activeLayer] = temp }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = backgroundColor

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Present"

        // The caches are already flattened, so they composite with Normal at
        // full opacity — the planner guarantees the over cache holds only
        // source-over layers, which makes that equivalent.
        func compositeCache(_ texture: MTLTexture?) {
            guard let texture else { return }
            var uniforms = MSBlendUniforms(mode: 0, opacity: 1, useClipMask: 0, _pad: 0)
            encoder.setRenderPipelineState(blendPipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentTexture(texture, index: 2)
            encoder.setFragmentBytes(&uniforms,
                                     length: MemoryLayout<MSBlendUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        compositeCache(underCache)
        composite(plan.live, into: encoder, engine: engine, overrideTexture: overrides)
        compositeCache(overCache)

        encoder.endEncoding()
    }

    /// Reads a layer's texture back so the engine can take ownership of the
    /// pixels at stroke end.
    func readBack(layer: MCLayerId, tiles: [EngineTile], engine: CanvasEngine) {
        guard let texture = layerTextures[layer] else { return }
        let bytesPerRow = tileSize * 4

        for tile in tiles {
            let originX = Int(tile.x) * tileSize
            let originY = Int(tile.y) * tileSize
            guard originX >= 0, originY >= 0, originX < width, originY < height else { continue }

            let regionWidth = min(tileSize, width - originX)
            let regionHeight = min(tileSize, height - originY)

            tileScratch.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                // Edge tiles are partial, so zero first: the remainder must be
                // defined rather than whatever the previous tile left behind.
                if regionWidth < tileSize || regionHeight < tileSize {
                    raw.initializeMemory(as: UInt8.self, repeating: 0)
                }
                texture.getBytes(base,
                                 bytesPerRow: bytesPerRow,
                                 from: MTLRegionMake2D(originX, originY,
                                                       regionWidth, regionHeight),
                                 mipmapLevel: 0)
            }
            tileScratch.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                engine.storeTile(tile, in: layer, bytes: base)
            }
        }
    }
}

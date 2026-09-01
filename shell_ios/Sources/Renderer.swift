//
//  Renderer.swift
//
//  Owns the frame loop and the stroke in progress; LayerCompositor owns the
//  layer stack's pixels.
//
//  The stroke being drawn lives in a single-channel coverage texture that is
//  rebuilt from its geometry every frame. Three things fall out of that:
//
//    · Overlapping ribbon quads accumulate with MAX, so a dense self-
//      overlapping stroke has uniform coverage rather than darkening at every
//      overlap, and a semi-transparent stroke does not darken where it crosses
//      itself.
//    · Predicted touches are drawn alongside the real ones and vanish on the
//      next frame's clear, so a wrong guess can never reach a layer.
//    · Stroke opacity stays adjustable until the moment it is committed.
//
//  At stroke end the coverage is flattened into the active layer's texture,
//  and only the tiles it touched are read back to the engine. That crossing
//  happens once per stroke, never per frame.
//
//  Threading: the display link runs on the main run loop and touches arrive on
//  the main thread, so none of the state below needs locking.
//

import Metal
import QuartzCore
import UIKit
import simd

struct FrameStats {
    var fps: Double = 0
    var displayMaxFPS: Int = 0
    var cpuFrameMs: Double = 0
    var gpuFrameMs: Double = 0
    var frameIndex: UInt64 = 0
    var drawableSize: CGSize = .zero
    var samplesThisFrame: Int = 0
    /// Dabs stamped this frame, prediction included.
    var dabsThisFrame: Int = 0

    // Engine-side memory, mirrored into the HUD because we have no Instruments.
    var liveTiles: UInt64 = 0
    var residentTiles: UInt64 = 0
    var compressedTiles: UInt64 = 0
    var spilledTiles: UInt64 = 0
    var residentBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var spillBytes: UInt64 = 0
    var undoDepth: UInt64 = 0
    var historyTiles: UInt64 = 0
    var storesOutsideAction: UInt64 = 0
    var lastCaptureMs: Double = 0
    var gpuWaitMs: Double = 0

    // Compositor. `underRebuilds`/`overRebuilds` must stay flat while a stroke
    // is in progress; if they climb, the under/over optimisation has stopped
    // working and a deep document is paying full price every frame.
    var layerCount: Int = 0
    var liveLayerCount: Int = 0
    var underRebuilds: UInt64 = 0
    var overRebuilds: UInt64 = 0
}

enum RendererError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case noShaderLibrary
    case missingFunction(String)
    case engineUnavailable
    case programmableBlendingUnavailable

    var description: String {
        switch self {
        case .noDevice: return "no Metal device — this build cannot run on this hardware"
        case .noCommandQueue: return "could not create a Metal command queue"
        case .noShaderLibrary: return "default.metallib missing — the .metal file did not compile into the bundle"
        case .missingFunction(let name): return "shader function '\(name)' not found in default.metallib"
        case .engineUnavailable: return "the C++ canvas engine failed to start"
        case .programmableBlendingUnavailable:
            return "programmable blending is unavailable — this build needs a real device, not the Simulator"
        }
    }
}

final class Renderer: NSObject {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    /// Two pipelines over one shader, differing only in blend state.
    ///
    /// Maximum keeps the greater coverage, so a stroke never darkens where it
    /// crosses itself — what an inking pen wants. Buildup alpha-composites, so
    /// slow dense passes go darker than fast ones — what an airbrush wants.
    /// The choice belongs to the brush, so both are built up front.
    private let dabMaximumPipeline: MTLRenderPipelineState
    private let dabBuildupPipeline: MTLRenderPipelineState
    private let predictionPipeline: MTLRenderPipelineState
    private let layer: CAMetalLayer
    private let engine: CanvasEngine
    private let compositor: LayerCompositor

    private var displayLink: CAMetalDisplayLink?

    /// Coverage of the stroke in progress. Single channel: the ink colour is
    /// applied when it is composited, which is what keeps opacity adjustable
    /// until commit.
    private var scratchTexture: MTLTexture?

    private var stroke: BrushStroke?
    private var prediction: BrushStroke?
    private var strokeBuffer: MTLBuffer?
    private var strokeBufferCapacity = 0
    private var strokeActive = false

    /// Dabs already stamped into the coverage texture.
    ///
    /// Coverage accumulates across frames rather than being rebuilt from the
    /// whole stroke each time. Redrawing every dab per frame makes the frame
    /// cost grow with stroke length, which is exactly backwards: a long stroke
    /// is when the artist can least afford a dropped frame. Both accumulation
    /// modes are safe to build up incrementally — max is idempotent, and
    /// alpha-over is correct as long as each dab is drawn exactly once, which
    /// is what this counter guarantees.
    private var stampedDabs = 0
    private var coverageNeedsClear = true
    private var pendingCommit = false
    private var pendingTiles: [EngineTile] = []
    private var samplesThisFrame = 0

    /// Ink colour, straight (not premultiplied); the shader premultiplies.
    var inkColor = simd_float4(0.09, 0.09, 0.11, 1.0)

    var onStats: ((FrameStats) -> Void)?
    /// Fires when the layer stack changes in a way the panel should reflect.
    var onLayersChanged: (() -> Void)?

    private var stats = FrameStats()
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var smoothedFPS: Double = 0
    private var smoothedGPUMs: Double = 0
    private var smoothedCPUMs: Double = 0

    private static let coverageFormat: MTLPixelFormat = .r8Unorm

    var canvas: CanvasEngine { engine }

    init(layer: CAMetalLayer) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        guard let library = device.makeDefaultLibrary() else { throw RendererError.noShaderLibrary }
        guard let engine = CanvasEngine() else { throw RendererError.engineUnavailable }

        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else {
                throw RendererError.missingFunction(name)
            }
            return f
        }

        self.device = device
        self.commandQueue = queue
        self.layer = layer
        self.engine = engine

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        // Two drawables, not three. Three buys throughput at the cost of
        // latency, which is the wrong trade for a drawing app.
        layer.maximumDrawableCount = 2

        let dabs = MTLRenderPipelineDescriptor()
        dabs.label = "Dab coverage (max)"
        dabs.vertexFunction = try function("dab_vertex")
        dabs.fragmentFunction = try function("dab_coverage_fragment")
        let dabAttachment = dabs.colorAttachments[0]!
        dabAttachment.pixelFormat = Self.coverageFormat
        dabAttachment.isBlendingEnabled = true
        dabAttachment.rgbBlendOperation = .max
        dabAttachment.alphaBlendOperation = .max
        self.dabMaximumPipeline = try device.makeRenderPipelineState(descriptor: dabs)

        dabs.label = "Dab coverage (buildup)"
        dabAttachment.rgbBlendOperation = .add
        dabAttachment.alphaBlendOperation = .add
        dabAttachment.sourceRGBBlendFactor = .one
        dabAttachment.sourceAlphaBlendFactor = .one
        dabAttachment.destinationRGBBlendFactor = .oneMinusSourceColor
        dabAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.dabBuildupPipeline = try device.makeRenderPipelineState(descriptor: dabs)

        // Predicted dabs go straight onto the drawable in ink colour, so this
        // one composites rather than accumulating coverage.
        let predicted = MTLRenderPipelineDescriptor()
        predicted.label = "Predicted dabs"
        predicted.vertexFunction = try function("dab_vertex")
        predicted.fragmentFunction = try function("dab_ink_fragment")
        let predictedAttachment = predicted.colorAttachments[0]!
        predictedAttachment.pixelFormat = layer.pixelFormat
        predictedAttachment.isBlendingEnabled = true
        predictedAttachment.rgbBlendOperation = .add
        predictedAttachment.alphaBlendOperation = .add
        predictedAttachment.sourceRGBBlendFactor = .one
        predictedAttachment.sourceAlphaBlendFactor = .one
        predictedAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        predictedAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.predictionPipeline = try device.makeRenderPipelineState(descriptor: predicted)

        do {
            self.compositor = try LayerCompositor(device: device, library: library,
                                                  pixelFormat: layer.pixelFormat,
                                                  tileSize: engine.tileSize)
        } catch {
            // The Simulator rejects programmable blending at pipeline
            // creation. Saying so plainly beats a generic shader error.
            throw RendererError.programmableBlendingUnavailable
        }

        super.init()

        // Generous enough that nothing pages during normal drawing, but low
        // enough that the tier machinery is exercised on device rather than
        // only in tests.
        engine.setBudgets(residentBytes: 96 * UInt64(engine.tileByteCount),
                          compressedBytes: 32 * 1024 * 1024)

        Diagnostics.log("Metal device: \(device.name)")
        Diagnostics.log("  supportsFamily(.apple9): \(device.supportsFamily(.apple9))")
        Diagnostics.log("  hasUnifiedMemory: \(device.hasUnifiedMemory)")
        Diagnostics.log("  recommendedMaxWorkingSetSize: \(device.recommendedMaxWorkingSetSize / (1024 * 1024)) MB")
    }

    // MARK: - Stroke input

    /// The brush the next stroke will use. A value, so changing it mid-stroke
    /// cannot alter a stroke already in progress.
    var brush: MCBrush = mc_brush_ink_pen()

    func setStroke(_ stroke: BrushStroke?, sampleCount: Int) {
        if stroke !== self.stroke {
            stampedDabs = 0
            coverageNeedsClear = true
        }
        self.stroke = stroke
        strokeActive = stroke != nil
        samplesThisFrame += sampleCount
    }

    func setPrediction(_ prediction: BrushStroke?) {
        self.prediction = prediction
    }

    var engineTileSize: Int { engine.tileSize }

    /// Flattens the stroke into the active layer on the next frame, then hands
    /// the tiles it touched to the engine.
    func endStroke(tiles: Set<EngineTile>) {
        guard strokeActive else { return }
        prediction = nil
        pendingTiles = Array(tiles)
        pendingCommit = true
    }

    /// Discards the stroke without committing it. Nothing needs repainting:
    /// the coverage texture is rebuilt from geometry each frame and only drawn
    /// while a stroke is active.
    func abortStroke() {
        guard strokeActive || pendingCommit else { return }
        stroke = nil
        prediction = nil
        pendingTiles.removeAll(keepingCapacity: true)
        strokeActive = false
        pendingCommit = false
    }

    // MARK: - Layers

    func addLayer() {
        let id = engine.addLayer(named: "Layer \(engine.layerCount + 1)")
        compositor.markLayerStale(id)
        onLayersChanged?()
        Diagnostics.log("added layer \(id)")
    }

    func duplicateActiveLayer() {
        let id = engine.duplicateLayer(engine.activeLayer)
        compositor.markLayerStale(id)
        onLayersChanged?()
    }

    func removeLayer(_ layer: MCLayerId) {
        guard engine.removeLayer(layer) else { return }
        compositor.forgetLayer(layer)
        onLayersChanged?()
    }

    func selectLayer(_ layer: MCLayerId) {
        engine.setActiveLayer(layer)
        onLayersChanged?()
    }

    func moveLayer(_ layer: MCLayerId, to index: Int) {
        guard engine.moveLayer(layer, to: index) else { return }
        onLayersChanged?()
    }

    func setProperties(_ properties: LayerProperties, of layer: MCLayerId) {
        // Deliberately does not fire onLayersChanged. The panel initiated this
        // and has already updated itself; rebuilding it here would tear down
        // whichever control the user is still touching.
        engine.setProperties(properties, of: layer)
    }

    // MARK: - History

    @discardableResult
    func undo() -> Bool {
        guard let tiles = engine.undo() else { return false }
        // Undo can touch any layer, so every texture is suspect. Re-uploading
        // lazily on next use keeps this off the frame that has to stay
        // responsive.
        // No invalidateCaches here: the composite signature already covers
        // content revisions, so it rebuilds a cache only if undo actually
        // touched a layer inside it. Forcing both was costing two full
        // re-flattens per undo.
        compositor.markAllLayersStale()
        onLayersChanged?()
        Diagnostics.log("undo: \(tiles.count) tiles")
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let tiles = engine.redo() else { return false }
        compositor.markAllLayersStale()
        onLayersChanged?()
        Diagnostics.log("redo: \(tiles.count) tiles")
        return true
    }

    func clearActiveLayer() {
        let tiles = engine.clearActiveLayer()
        compositor.markLayerStale(engine.activeLayer)
        onLayersChanged?()
        Diagnostics.log("cleared active layer (\(tiles.count) tiles, undoable)")
    }

    // MARK: - Frame loop

    /// - Parameter maxFramesPerSecond: the panel's real capability, from
    ///   `UIScreen.maximumFramesPerSecond`. Queried rather than assumed —
    ///   iPad Air is 60Hz, iPad Pro is 120Hz, and hardcoding either is wrong
    ///   on the other.
    func start(maxFramesPerSecond: Int) {
        guard displayLink == nil else { return }

        let maxFPS = Float(max(30, maxFramesPerSecond))
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: maxFPS / 2,
                                                        maximum: maxFPS,
                                                        preferred: maxFPS)
        link.add(to: .main, forMode: .common)
        displayLink = link

        stats.displayMaxFPS = maxFramesPerSecond
        Diagnostics.log("display link started (panel max \(maxFramesPerSecond) Hz)")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        layer.drawableSize = size
        stats.drawableSize = size
    }

    private func ensureTextures() {
        let width = Int(layer.drawableSize.width)
        let height = Int(layer.drawableSize.height)
        guard width > 0, height > 0 else { return }

        if let existing = scratchTexture, existing.width == width, existing.height == height {
            return
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.coverageFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private   // the CPU never reads coverage
        scratchTexture = device.makeTexture(descriptor: descriptor)
        scratchTexture?.label = "Stroke coverage"
        // A new texture holds none of the stroke in progress, so whatever has
        // been stamped so far has to be stamped again.
        stampedDabs = 0
        coverageNeedsClear = true

        compositor.resize(width: width, height: height)
        // The textures themselves are new, which no content signature can see.
        engine.invalidateCaches()
        Diagnostics.log("textures \(width)×\(height)")
    }

    /// Uploads the dab array, growing the buffer geometrically.
    ///
    /// The engine appends dabs and never revises them, so the buffer only ever
    /// grows within a stroke. Reallocating on every touch event would be the
    /// obvious way to write this and would allocate hundreds of times per
    /// stroke; doubling means a handful of allocations for the longest stroke
    /// an artist can draw.
    private func dabBuffer(for stroke: BrushStroke) -> MTLBuffer? {
        let count = stroke.dabCount
        guard count > 0, let dabs = stroke.dabs else { return nil }

        let stride = MemoryLayout<MSDab>.stride
        if strokeBuffer == nil || strokeBufferCapacity < count {
            var capacity = max(1024, strokeBufferCapacity)
            while capacity < count { capacity *= 2 }
            strokeBuffer = device.makeBuffer(length: stride * capacity,
                                             options: .storageModeShared)
            strokeBuffer?.label = "Dabs"
            strokeBufferCapacity = capacity
        }
        guard let buffer = strokeBuffer else { return nil }

        // Copied wholesale rather than only the new tail. The tail is what
        // changes, but a stroke is at most a few hundred KB and the copy is
        // one memcpy against a per-frame GPU cost measured in milliseconds —
        // tracking a dirty range here would buy nothing measurable and would
        // be one more thing to get wrong.
        buffer.contents().copyMemory(from: dabs, byteCount: stride * count)
        return buffer
    }

    private func encodeCoverage(in commandBuffer: MTLCommandBuffer) {
        guard let scratch = scratchTexture, let stroke else { return }

        let count = stroke.dabCount
        // Nothing new and nothing to clear: the texture already holds the
        // right image, so the whole pass can be skipped. A stroke held still
        // costs no GPU time at all.
        guard coverageNeedsClear || count > stampedDabs else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scratch
        pass.colorAttachments[0].loadAction = coverageNeedsClear ? .clear : .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Dab coverage"
        encoder.setRenderPipelineState(
            brush.accumulation == MC_ACCUMULATION_BUILDUP.rawValue
                ? dabBuildupPipeline : dabMaximumPipeline)

        var uniforms = MSDabUniforms(
            viewportSize: simd_float2(Float(scratch.width), Float(scratch.height)))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MSDabUniforms>.stride,
                               index: Int(MSBufferIndexUniforms.rawValue))

        let first = coverageNeedsClear ? 0 : stampedDabs
        if count > first, let buffer = dabBuffer(for: stroke) {
            encoder.setVertexBuffer(buffer, offset: 0,
                                    index: Int(MSBufferIndexVertices.rawValue))
            // Six vertices per dab, one instance per dab, starting from the
            // first dab this frame has not already stamped.
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                   instanceCount: count - first, baseInstance: first)
        }
        encoder.endEncoding()

        stampedDabs = count
        coverageNeedsClear = false
    }

    /// Draws the predicted tail straight onto the drawable, after compositing.
    ///
    /// Not into the coverage texture, because coverage is now accumulated and a
    /// guess must not survive into the next frame — it would be baked into the
    /// stroke and then committed. Painting it over the finished frame instead
    /// costs one small pass and disappears on its own.
    private func encodePrediction(onto target: MTLTexture,
                                  in commandBuffer: MTLCommandBuffer) {
        guard let prediction, let dabs = prediction.dabs, prediction.dabCount > 0 else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Predicted dabs"
        encoder.setRenderPipelineState(predictionPipeline)

        var uniforms = MSDabUniforms(
            viewportSize: simd_float2(Float(target.width), Float(target.height)))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MSDabUniforms>.stride,
                               index: Int(MSBufferIndexUniforms.rawValue))

        let length = MemoryLayout<MSDab>.stride * prediction.dabCount
        if let buffer = device.makeBuffer(bytes: dabs, length: length,
                                          options: .storageModeShared) {
            buffer.label = "Predicted dabs"
            encoder.setVertexBuffer(buffer, offset: 0,
                                    index: Int(MSBufferIndexVertices.rawValue))
            var ink = inkColor
            encoder.setFragmentBytes(&ink, length: MemoryLayout<simd_float4>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                   instanceCount: prediction.dabCount)
        }
        encoder.endEncoding()
    }

    private func render(to drawable: CAMetalDrawable, targetTimestamp: CFTimeInterval) {
        let cpuStart = CACurrentMediaTime()

        ensureTextures()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Frame \(stats.frameIndex)"

        let dabCount = (stroke?.dabCount ?? 0) + (prediction?.dabCount ?? 0)
        let committing = pendingCommit
        let activeLayer = engine.activeLayer

        if strokeActive {
            encodeCoverage(in: commandBuffer)
        }

        if committing, let coverage = scratchTexture {
            compositor.syncLayer(activeLayer, engine: engine)
            compositor.flattenStroke(into: activeLayer, coverage: coverage,
                                     inkColor: inkColor, commandBuffer: commandBuffer)
        }

        let plan = engine.refreshPlan()
        if plan.underDirty {
            compositor.rebuildUnderCache(plan.under, engine: engine, commandBuffer: commandBuffer)
        }
        if plan.overDirty {
            compositor.rebuildOverCache(plan.over, engine: engine, commandBuffer: commandBuffer)
        }

        compositor.present(into: drawable.texture, plan: plan, engine: engine,
                           strokeCoverage: (strokeActive && !committing) ? scratchTexture : nil,
                           inkColor: inkColor, commandBuffer: commandBuffer)

        // Excluded on the committing frame, so a guess can never be flattened
        // into a layer.
        if strokeActive && !committing {
            encodePrediction(onto: drawable.texture, in: commandBuffer)
        }

        commandBuffer.addCompletedHandler { [weak self] buffer in
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
            DispatchQueue.main.async { self?.recordGPUTime(gpuMs) }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        if committing {
            // The one place we stall on the GPU. Reading the layer before the
            // flatten has actually run would capture it a frame stale. Once
            // per stroke, not per frame.
            let waitStarted = CACurrentMediaTime()
            commandBuffer.waitUntilCompleted()
            let readStarted = CACurrentMediaTime()

            engine.beginStroke("Stroke")
            compositor.readBack(layer: activeLayer, tiles: pendingTiles, engine: engine)
            engine.commitStroke()
            engine.evict()

            // Kept apart because they have different cures. The wait is the
            // GPU finishing the frame; the readback is the copy from a
            // screen-shaped texture into tiles.
            stats.gpuWaitMs = (readStarted - waitStarted) * 1000.0
            stats.lastCaptureMs = (CACurrentMediaTime() - readStarted) * 1000.0

            stroke = nil
            prediction = nil
            pendingTiles.removeAll(keepingCapacity: true)
            strokeActive = false
            pendingCommit = false
        }

        let cpuMs = (CACurrentMediaTime() - cpuStart) * 1000.0
        recordFrame(cpuMs: cpuMs, targetTimestamp: targetTimestamp,
                    dabCount: dabCount, plan: plan)
    }

    // MARK: - Statistics

    private func recordFrame(cpuMs: Double, targetTimestamp: CFTimeInterval,
                             dabCount: Int, plan: CompositePlanSnapshot) {
        stats.frameIndex &+= 1

        if lastFrameTimestamp > 0 {
            let delta = targetTimestamp - lastFrameTimestamp
            if delta > 0 {
                let instantFPS = 1.0 / delta
                smoothedFPS = smoothedFPS == 0 ? instantFPS : smoothedFPS * 0.9 + instantFPS * 0.1
            }
        }
        lastFrameTimestamp = targetTimestamp
        smoothedCPUMs = smoothedCPUMs == 0 ? cpuMs : smoothedCPUMs * 0.9 + cpuMs * 0.1

        stats.fps = smoothedFPS
        stats.cpuFrameMs = smoothedCPUMs
        stats.gpuFrameMs = smoothedGPUMs
        stats.samplesThisFrame = samplesThisFrame
        stats.dabsThisFrame = dabCount
        stats.layerCount = plan.layerCount
        stats.liveLayerCount = plan.live.count

        let engineStats = engine.stats
        stats.liveTiles = engineStats.liveTiles
        stats.residentTiles = engineStats.residentTiles
        stats.compressedTiles = engineStats.compressedTiles
        stats.spilledTiles = engineStats.spilledTiles
        stats.residentBytes = engineStats.residentBytes
        stats.compressedBytes = engineStats.compressedBytes
        stats.spillBytes = engineStats.spillFileBytes
        stats.undoDepth = engineStats.undoDepth
        stats.historyTiles = engineStats.historyTiles
        stats.storesOutsideAction = engineStats.storesOutsideAction
        stats.underRebuilds = engineStats.underCacheRebuilds
        stats.overRebuilds = engineStats.overCacheRebuilds

        onStats?(stats)
        samplesThisFrame = 0
    }

    private func recordGPUTime(_ gpuMs: Double) {
        smoothedGPUMs = smoothedGPUMs == 0 ? gpuMs : smoothedGPUMs * 0.9 + gpuMs * 0.1
    }
}

extension Renderer: CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        render(to: update.drawable, targetTimestamp: update.targetTimestamp)
    }
}

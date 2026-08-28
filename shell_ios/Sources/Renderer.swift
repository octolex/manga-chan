//
//  Renderer.swift
//
//  Three textures, and the relationship between them is the whole design:
//
//    canvas   bgra8  — committed strokes. Only ever written at stroke end.
//    scratch  r8     — coverage of the stroke currently being drawn.
//    drawable        — canvas, then scratch tinted and composited on top.
//
//  The in-progress stroke lives in `scratch` and is rebuilt from scratch (in
//  both senses) every frame. Three things fall out of that for free:
//
//    · Overlapping ribbon quads accumulate with MAX, so a dense self-
//      overlapping stroke has uniform coverage instead of darkening at every
//      overlap — and a semi-transparent stroke does not darken where it
//      crosses itself.
//    · Predicted touches are drawn into scratch alongside the real ones, and
//      because scratch is cleared each frame, a wrong prediction simply
//      disappears. It can never reach the canvas, because only committed
//      geometry is redrawn at commit time.
//    · Stroke opacity stays adjustable until the moment it is committed.
//
//  The engine handoff. When a stroke commits, the tiles it touched are read
//  back from the canvas texture and handed to the C++ engine, which owns undo
//  history, compression and paging. That crossing happens once per stroke, not
//  once per frame — a readback in the frame loop would cost more than
//  everything else here combined.
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
    var strokeVerticesThisFrame: Int = 0

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
}

enum RendererError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case noShaderLibrary
    case missingFunction(String)
    case engineUnavailable

    var description: String {
        switch self {
        case .noDevice: return "no Metal device — this build cannot run on this hardware"
        case .noCommandQueue: return "could not create a Metal command queue"
        case .noShaderLibrary: return "default.metallib missing — the .metal file did not compile into the bundle"
        case .missingFunction(let name): return "shader function '\(name)' not found in default.metallib"
        case .engineUnavailable: return "the C++ canvas engine failed to start"
        }
    }
}

final class Renderer: NSObject {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let coveragePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let blitPipeline: MTLRenderPipelineState
    private let layer: CAMetalLayer
    private let engine: CanvasEngine

    private var displayLink: CAMetalDisplayLink?

    private var canvasTexture: MTLTexture?
    private var scratchTexture: MTLTexture?
    private var canvasNeedsClear = true

    private var strokeVertices: [MSStrokeVertex] = []
    private var predictionVertices: [MSStrokeVertex] = []
    private var strokeBuffer: MTLBuffer?
    private var strokeBufferDirty = false
    private var strokeActive = false
    private var pendingCommit = false
    private var pendingTiles: [EngineTile] = []
    private var samplesThisFrame = 0

    /// Staging buffer for one tile, reused so a stroke commit does not churn
    /// the allocator once per tile.
    private var tileScratch: [UInt8]

    /// Ink colour, straight (not premultiplied); the composite shader
    /// premultiplies.
    var inkColor = simd_float4(0.09, 0.09, 0.11, 1.0)

    var onStats: ((FrameStats) -> Void)?

    private var stats = FrameStats()
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var smoothedFPS: Double = 0
    private var smoothedGPUMs: Double = 0
    private var smoothedCPUMs: Double = 0

    private static let scratchFormat: MTLPixelFormat = .r8Unorm

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
        self.tileScratch = [UInt8](repeating: 0, count: engine.tileByteCount)

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        // Two drawables, not three. Three buys throughput at the cost of
        // latency, which is the wrong trade for a drawing app.
        layer.maximumDrawableCount = 2

        // Coverage: MAX blending. Metal ignores the blend factors entirely for
        // min/max operations, so the destination simply keeps whichever
        // coverage is greater.
        let coverage = MTLRenderPipelineDescriptor()
        coverage.label = "Stroke coverage"
        coverage.vertexFunction = try function("stroke_vertex")
        coverage.fragmentFunction = try function("stroke_coverage_fragment")
        let coverageAttachment = coverage.colorAttachments[0]!
        coverageAttachment.pixelFormat = Self.scratchFormat
        coverageAttachment.isBlendingEnabled = true
        coverageAttachment.rgbBlendOperation = .max
        coverageAttachment.alphaBlendOperation = .max
        self.coveragePipeline = try device.makeRenderPipelineState(descriptor: coverage)

        // Composite: standard source-over with premultiplied source.
        let composite = MTLRenderPipelineDescriptor()
        composite.label = "Stroke composite"
        composite.vertexFunction = try function("fullscreen_vertex")
        composite.fragmentFunction = try function("composite_fragment")
        let compositeAttachment = composite.colorAttachments[0]!
        compositeAttachment.pixelFormat = layer.pixelFormat
        compositeAttachment.isBlendingEnabled = true
        compositeAttachment.rgbBlendOperation = .add
        compositeAttachment.alphaBlendOperation = .add
        compositeAttachment.sourceRGBBlendFactor = .one
        compositeAttachment.sourceAlphaBlendFactor = .one
        compositeAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        compositeAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.compositePipeline = try device.makeRenderPipelineState(descriptor: composite)

        let blit = MTLRenderPipelineDescriptor()
        blit.label = "Canvas blit"
        blit.vertexFunction = try function("fullscreen_vertex")
        blit.fragmentFunction = try function("blit_fragment")
        blit.colorAttachments[0].pixelFormat = layer.pixelFormat
        self.blitPipeline = try device.makeRenderPipelineState(descriptor: blit)

        super.init()

        // A budget generous enough that nothing pages during normal drawing,
        // but low enough that the tier machinery is actually exercised on
        // device rather than only in tests.
        engine.setBudgets(residentBytes: 96 * UInt64(engine.tileByteCount),
                          compressedBytes: 32 * 1024 * 1024)

        Diagnostics.log("Metal device: \(device.name)")
        Diagnostics.log("  supportsFamily(.apple8): \(device.supportsFamily(.apple8))")
        Diagnostics.log("  supportsFamily(.apple9): \(device.supportsFamily(.apple9))")
        Diagnostics.log("  hasUnifiedMemory: \(device.hasUnifiedMemory)")
        Diagnostics.log("  recommendedMaxWorkingSetSize: \(device.recommendedMaxWorkingSetSize / (1024 * 1024)) MB")
    }

    // MARK: - Stroke input

    /// Full committed geometry of the stroke in progress.
    func setStrokeGeometry(_ vertices: [MSStrokeVertex], sampleCount: Int) {
        strokeVertices = vertices
        strokeBufferDirty = true
        strokeActive = true
        samplesThisFrame += sampleCount
    }

    /// Lookahead geometry. Drawn into scratch but never committed.
    func setPredictionGeometry(_ vertices: [MSStrokeVertex]) {
        predictionVertices = vertices
    }

    /// Tile edge in pixels, so the input layer can work out which tiles a
    /// stroke covers without duplicating the constant.
    var engineTileSize: Int { engine.tileSize }

    /// Flattens the stroke into the canvas on the next frame, then hands the
    /// tiles it touched to the engine.
    /// - Parameter tiles: exactly the tiles the stroke covered.
    func endStroke(tiles: Set<EngineTile>) {
        guard strokeActive else { return }
        predictionVertices.removeAll(keepingCapacity: true)
        pendingTiles = Array(tiles)
        pendingCommit = true
    }

    /// Discards the stroke in progress without committing it to the canvas or
    /// the undo history. Used when a gesture takes over, or when a touch
    /// produced no geometry.
    ///
    /// Nothing needs repainting: the scratch texture is rebuilt from
    /// `strokeVertices` every frame and only composited while a stroke is
    /// active, so dropping the geometry is enough to make it vanish.
    func abortStroke() {
        guard strokeActive || pendingCommit else { return }
        strokeVertices.removeAll(keepingCapacity: true)
        predictionVertices.removeAll(keepingCapacity: true)
        pendingTiles.removeAll(keepingCapacity: true)
        strokeBuffer = nil
        strokeBufferDirty = false
        strokeActive = false
        pendingCommit = false
    }

    // MARK: - History

    func undo() -> Bool {
        guard let tiles = engine.undo() else { return false }
        applyTiles(tiles)
        Diagnostics.log("undo: \(tiles.count) tiles restored")
        return true
    }

    func redo() -> Bool {
        guard let tiles = engine.redo() else { return false }
        applyTiles(tiles)
        Diagnostics.log("redo: \(tiles.count) tiles restored")
        return true
    }

    func clearCanvas() {
        let tiles = engine.clear()
        applyTiles(tiles)
        Diagnostics.log("canvas cleared (\(tiles.count) tiles, undoable)")
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
        // Allowing the system to halve the rate when nothing is happening
        // saves battery. M4 should tighten this to pin the rate while a stroke
        // is in progress, where any drop is directly visible as lag.
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
        Diagnostics.log("display link stopped")
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

        if let existing = canvasTexture, existing.width == width, existing.height == height {
            return
        }

        func makeTexture(_ format: MTLPixelFormat,
                         _ storage: MTLStorageMode,
                         _ label: String) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                      width: width,
                                                                      height: height,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = storage
            let texture = device.makeTexture(descriptor: descriptor)
            texture?.label = label
            return texture
        }

        // The canvas is shared rather than private because the CPU has to read
        // it back at stroke end. On unified memory that costs nothing extra;
        // the scratch texture stays private since it is never read by the CPU.
        canvasTexture = makeTexture(layer.pixelFormat, .shared, "Canvas")
        scratchTexture = makeTexture(Self.scratchFormat, .private, "Stroke scratch")
        canvasNeedsClear = true

        Diagnostics.log("textures \(width)×\(height)")

        // A resize throws away the canvas texture, so repaint it from the
        // engine — otherwise rotating the iPad would silently erase the work.
        repopulateFromEngine()
    }

    // MARK: - Engine handoff

    /// Reads the tiles a finished stroke touched out of the canvas texture and
    /// hands them to the engine, which takes it from there.
    private func captureTiles(_ tiles: [EngineTile]) {
        guard let canvas = canvasTexture, !tiles.isEmpty else { return }
        let started = CACurrentMediaTime()
        let size = engine.tileSize
        let bytesPerRow = size * 4

        for tile in tiles {
            let originX = Int(tile.x) * size
            let originY = Int(tile.y) * size
            guard originX >= 0, originY >= 0,
                  originX < canvas.width, originY < canvas.height else { continue }

            let width = min(size, canvas.width - originX)
            let height = min(size, canvas.height - originY)

            tileScratch.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                // Edge tiles are partial. Zeroing first means the unused
                // remainder is defined rather than whatever the previous tile
                // left behind.
                if width < size || height < size {
                    raw.initializeMemory(as: UInt8.self, repeating: 0)
                }
                canvas.getBytes(base,
                                bytesPerRow: bytesPerRow,
                                from: MTLRegionMake2D(originX, originY, width, height),
                                mipmapLevel: 0)
            }
            tileScratch.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                engine.storeTile(tile, bytes: base)
            }
        }
        stats.lastCaptureMs = (CACurrentMediaTime() - started) * 1000.0
    }

    /// Pushes tiles from the engine back into the canvas texture.
    private func applyTiles(_ tiles: [EngineTile]) {
        guard let canvas = canvasTexture else { return }
        let size = engine.tileSize
        let bytesPerRow = size * 4

        for tile in tiles {
            let originX = Int(tile.x) * size
            let originY = Int(tile.y) * size
            guard originX >= 0, originY >= 0,
                  originX < canvas.width, originY < canvas.height else { continue }

            let width = min(size, canvas.width - originX)
            let height = min(size, canvas.height - originY)

            let loaded = tileScratch.withUnsafeMutableBufferPointer { buffer -> Bool in
                guard let base = buffer.baseAddress else { return false }
                return engine.loadTile(tile, into: base)
            }
            if !loaded {
                // Never painted, so it belongs at paper white rather than
                // whatever the texture happens to be showing.
                for index in tileScratch.indices { tileScratch[index] = 255 }
            }

            tileScratch.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                canvas.replace(region: MTLRegionMake2D(originX, originY, width, height),
                               mipmapLevel: 0,
                               withBytes: base,
                               bytesPerRow: bytesPerRow)
            }
        }
    }

    /// Repaints the whole canvas texture from engine storage. Used after a
    /// resize, which discards the texture.
    private func repopulateFromEngine() {
        guard let canvas = canvasTexture else { return }
        let size = engine.tileSize
        var tiles: [EngineTile] = []
        for ty in 0...((canvas.height - 1) / size) {
            for tx in 0...((canvas.width - 1) / size) {
                tiles.append(EngineTile(x: Int32(tx), y: Int32(ty)))
            }
        }
        applyTiles(tiles)
        canvasNeedsClear = false
    }

    // MARK: - Rendering

    private func strokeVertexBuffer() -> MTLBuffer? {
        guard !strokeVertices.isEmpty else { return nil }
        if strokeBufferDirty || strokeBuffer == nil {
            let length = MemoryLayout<MSStrokeVertex>.stride * strokeVertices.count
            strokeBuffer = device.makeBuffer(bytes: strokeVertices, length: length,
                                             options: .storageModeShared)
            strokeBuffer?.label = "Stroke vertices"
            strokeBufferDirty = false
        }
        return strokeBuffer
    }

    private func encodeScratch(in commandBuffer: MTLCommandBuffer,
                               scratch: MTLTexture,
                               includePrediction: Bool) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scratch
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Stroke coverage"
        encoder.setRenderPipelineState(coveragePipeline)

        if let buffer = strokeVertexBuffer() {
            encoder.setVertexBuffer(buffer, offset: 0, index: Int(MSBufferIndexVertices.rawValue))
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: strokeVertices.count)
        }

        if includePrediction, !predictionVertices.isEmpty {
            let length = MemoryLayout<MSStrokeVertex>.stride * predictionVertices.count
            if let buffer = device.makeBuffer(bytes: predictionVertices, length: length,
                                              options: .storageModeShared) {
                encoder.setVertexBuffer(buffer, offset: 0, index: Int(MSBufferIndexVertices.rawValue))
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: predictionVertices.count)
            }
        }

        encoder.endEncoding()
    }

    private func encodeComposite(in encoder: MTLRenderCommandEncoder, scratch: MTLTexture) {
        var ink = inkColor
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentTexture(scratch, index: 0)
        encoder.setFragmentBytes(&ink, length: MemoryLayout<simd_float4>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func render(to drawable: CAMetalDrawable, targetTimestamp: CFTimeInterval) {
        let cpuStart = CACurrentMediaTime()

        ensureTextures()
        guard let canvas = canvasTexture,
              let scratch = scratchTexture,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Frame \(stats.frameIndex)"

        let vertexCount = strokeVertices.count + predictionVertices.count
        let committingThisFrame = pendingCommit

        // Pass 1 — the stroke in progress. On the committing frame, prediction
        // is excluded so guessed geometry can never reach the canvas.
        if strokeActive {
            encodeScratch(in: commandBuffer, scratch: scratch,
                          includePrediction: !committingThisFrame)
        }

        // Pass 2 — flatten the finished stroke into the canvas.
        if committingThisFrame || canvasNeedsClear {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = canvas
            pass.colorAttachments[0].loadAction = canvasNeedsClear ? .clear : .load
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                encoder.label = "Commit stroke"
                if committingThisFrame {
                    encodeComposite(in: encoder, scratch: scratch)
                }
                encoder.endEncoding()
            }
            canvasNeedsClear = false
        }

        // Pass 3 — present: canvas, then the live stroke on top of it.
        let present = MTLRenderPassDescriptor()
        present.colorAttachments[0].texture = drawable.texture
        present.colorAttachments[0].loadAction = .dontCare
        present.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: present) {
            encoder.label = "Present"
            encoder.setRenderPipelineState(blitPipeline)
            encoder.setFragmentTexture(canvas, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            // On the committing frame the stroke is already in the canvas, so
            // drawing it again here would double-composite its antialiased edge.
            if strokeActive && !committingThisFrame {
                encodeComposite(in: encoder, scratch: scratch)
            }
            encoder.endEncoding()
        }

        commandBuffer.addCompletedHandler { [weak self] buffer in
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
            DispatchQueue.main.async { self?.recordGPUTime(gpuMs) }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        if committingThisFrame {
            // The one place we stall on the GPU. Reading the canvas before the
            // commit pass has actually run would capture the stroke as it was
            // one frame ago. It happens once per stroke, not per frame.
            commandBuffer.waitUntilCompleted()
            // Bracketing matters: storeTile only records undo state between a
            // begin and a commit. Without the begin, every stroke was written
            // straight through with no history at all.
            engine.beginStroke("Stroke")
            captureTiles(pendingTiles)
            engine.commitStroke()
            engine.evict()

            strokeVertices.removeAll(keepingCapacity: true)
            predictionVertices.removeAll(keepingCapacity: true)
            strokeBuffer = nil
            strokeBufferDirty = false
            strokeActive = false
            pendingCommit = false
            pendingTiles.removeAll(keepingCapacity: true)
        }

        let cpuMs = (CACurrentMediaTime() - cpuStart) * 1000.0
        recordFrame(cpuMs: cpuMs, targetTimestamp: targetTimestamp, vertexCount: vertexCount)
    }

    // MARK: - Statistics

    private func recordFrame(cpuMs: Double, targetTimestamp: CFTimeInterval, vertexCount: Int) {
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
        stats.strokeVerticesThisFrame = vertexCount

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

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
    private let coveragePipeline: MTLRenderPipelineState
    private let layer: CAMetalLayer
    private let engine: CanvasEngine
    private let compositor: LayerCompositor

    private var displayLink: CAMetalDisplayLink?

    /// Coverage of the stroke in progress. Single channel: the ink colour is
    /// applied when it is composited, which is what keeps opacity adjustable
    /// until commit.
    private var scratchTexture: MTLTexture?

    private var strokeVertices: [MSStrokeVertex] = []
    private var predictionVertices: [MSStrokeVertex] = []
    private var strokeBuffer: MTLBuffer?
    private var strokeBufferDirty = false
    private var strokeActive = false
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

        // Coverage accumulates with MAX. Metal ignores blend factors entirely
        // for min/max, so the destination simply keeps the greater value.
        let coverage = MTLRenderPipelineDescriptor()
        coverage.label = "Stroke coverage"
        coverage.vertexFunction = try function("stroke_vertex")
        coverage.fragmentFunction = try function("stroke_coverage_fragment")
        let attachment = coverage.colorAttachments[0]!
        attachment.pixelFormat = Self.coverageFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .max
        attachment.alphaBlendOperation = .max
        self.coveragePipeline = try device.makeRenderPipelineState(descriptor: coverage)

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

    func setStrokeGeometry(_ vertices: [MSStrokeVertex], sampleCount: Int) {
        strokeVertices = vertices
        strokeBufferDirty = true
        strokeActive = true
        samplesThisFrame += sampleCount
    }

    func setPredictionGeometry(_ vertices: [MSStrokeVertex]) {
        predictionVertices = vertices
    }

    var engineTileSize: Int { engine.tileSize }

    /// Flattens the stroke into the active layer on the next frame, then hands
    /// the tiles it touched to the engine.
    func endStroke(tiles: Set<EngineTile>) {
        guard strokeActive else { return }
        predictionVertices.removeAll(keepingCapacity: true)
        pendingTiles = Array(tiles)
        pendingCommit = true
    }

    /// Discards the stroke without committing it. Nothing needs repainting:
    /// the coverage texture is rebuilt from geometry each frame and only drawn
    /// while a stroke is active.
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
        engine.setProperties(properties, of: layer)
        onLayersChanged?()
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

        compositor.resize(width: width, height: height)
        // The textures themselves are new, which no content signature can see.
        engine.invalidateCaches()
        Diagnostics.log("textures \(width)×\(height)")
    }

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

    private func encodeCoverage(in commandBuffer: MTLCommandBuffer,
                                includePrediction: Bool) {
        guard let scratch = scratchTexture else { return }

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

    private func render(to drawable: CAMetalDrawable, targetTimestamp: CFTimeInterval) {
        let cpuStart = CACurrentMediaTime()

        ensureTextures()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Frame \(stats.frameIndex)"

        let vertexCount = strokeVertices.count + predictionVertices.count
        let committing = pendingCommit
        let activeLayer = engine.activeLayer

        // On the committing frame prediction is excluded, so a guess can never
        // be flattened into a layer.
        if strokeActive {
            encodeCoverage(in: commandBuffer, includePrediction: !committing)
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

            strokeVertices.removeAll(keepingCapacity: true)
            predictionVertices.removeAll(keepingCapacity: true)
            pendingTiles.removeAll(keepingCapacity: true)
            strokeBuffer = nil
            strokeBufferDirty = false
            strokeActive = false
            pendingCommit = false
        }

        let cpuMs = (CACurrentMediaTime() - cpuStart) * 1000.0
        recordFrame(cpuMs: cpuMs, targetTimestamp: targetTimestamp,
                    vertexCount: vertexCount, plan: plan)
    }

    // MARK: - Statistics

    private func recordFrame(cpuMs: Double, targetTimestamp: CFTimeInterval,
                             vertexCount: Int, plan: CompositePlanSnapshot) {
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

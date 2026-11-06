//
//  Renderer.swift
//
//  Owns the frame loop and the stroke in progress; LayerCompositor owns the
//  layer stack's pixels.
//
//  The stroke being drawn lives in its own coverage texture, accumulated as
//  dabs arrive. Three things fall out of that:
//
//    · Coverage carries ink density and stroke geometry in separate channels,
//      blended differently — see Shaders.metal. Density decides whether a
//      stroke darkens where it crosses itself; geometry keeps the edge
//      antialiased however many dabs pass over it.
//    · Predicted touches are painted onto the finished frame rather than into
//      coverage, so a wrong guess can never reach a layer.
//    · Each stroke keeps the brush and ink it began with, all the way to
//      its commit, so nothing done after the pen lifts can change a stroke
//      already drawn.
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
    /// One pipeline, with two blend operations on the one attachment.
    ///
    /// RGB carries ink density and accumulates with alpha-over, so flow decides
    /// how fast a stroke reaches full strength. Alpha carries the stroke's
    /// geometry and takes the maximum, so the antialiased edge survives however
    /// many dabs cross it. Compositing min(density, geometry) then gets each
    /// property from the channel that can express it — see Shaders.metal.
    ///
    /// This replaced a Maximum/Buildup switch. Accumulating alone bloats the
    /// edge; taking the maximum alone makes flow and opacity redundant.
    private let dabPipeline: MTLRenderPipelineState
    private let predictionPipeline: MTLRenderPipelineState
    private let layer: CAMetalLayer
    private let engine: CanvasEngine
    private let compositor: LayerCompositor

    private var displayLink: CAMetalDisplayLink?

    /// Coverage of the stroke in progress: ink density in RGB, geometry in
    /// alpha. The ink colour is applied when it is composited, which is what
    /// keeps opacity adjustable until commit.
    private var scratchTexture: MTLTexture?

    /// The grain map every dab is stamped through. Built once: it is a pure
    /// function of a fixed seed, it is 64 KB, and nothing at runtime changes
    /// it — depth and scale are uniforms, so the artist's controls never touch
    /// the texture itself.
    private var grainTexture: MTLTexture?

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
    /// channels are safe to build up incrementally — the maximum is
    /// idempotent, and alpha-over is correct as long as each dab is drawn
    /// exactly once, which is what this counter guarantees.
    private var stampedDabs = 0
    private var coverageNeedsClear = true
    /// Whether the current stroke has already been restamped for its end
    /// taper. Once is enough — the taper revises the stroke once, at the lift.
    private var restampedForTaper = false
    private var samplesThisFrame = 0

    /// A finished stroke waiting for the next frame to flatten it into its
    /// layer. Everything the commit needs is captured when the pen lifts.
    ///
    /// It used to be a flag plus whatever the renderer's state was when the
    /// frame came — the stroke, the active layer, the ink. So a second stroke
    /// begun inside the same frame replaced the first one's coverage before it
    /// was flattened, and the first stroke vanished; a finger touch cancelled
    /// in that window aborted it outright; and selecting another layer in it
    /// committed the stroke into the wrong one. Nothing now reads live state
    /// for a commit, and anything that would disturb one flushes it first —
    /// see `flushPendingCommit`.
    private struct PendingCommit {
        let tiles: [EngineTile]
        let layer: MCLayerId
        let ink: simd_float4
    }
    private var pendingCommit: PendingCommit?

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

    // The coverage format — four channels, because RGB holds ink density and
    // alpha the stroke's geometry and they need different blend operations,
    // which Metal splits only at the RGB/alpha boundary — lives in
    // StrokeCoverage, shared with the shader tests.

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
        dabs.label = "Dab coverage"
        dabs.vertexFunction = try function("dab_vertex")
        dabs.fragmentFunction = try function("dab_coverage_fragment")
        let dabAttachment = dabs.colorAttachments[0]!
        dabAttachment.pixelFormat = StrokeCoverage.pixelFormat
        dabAttachment.isBlendingEnabled = true

        // Ink density: alpha-over, so passes build.
        dabAttachment.rgbBlendOperation = .add
        dabAttachment.sourceRGBBlendFactor = .one
        dabAttachment.destinationRGBBlendFactor = .oneMinusSourceColor

        // Geometry: the maximum, so the silhouette stays the true antialiased
        // edge. Blend factors are ignored for a max operation.
        dabAttachment.alphaBlendOperation = .max
        self.dabPipeline = try device.makeRenderPipelineState(descriptor: dabs)

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

        grainTexture = GrainTexture.make(device: device)
        if grainTexture == nil {
            // Not fatal. The shader reads the grain only when depth is above
            // zero, so a brush with grain switched off draws exactly as before
            // — losing the texture must not cost us the app.
            Diagnostics.log("grain texture unavailable; grain will be inert")
        }

        Diagnostics.log("Metal device: \(device.name)")
        Diagnostics.log("  supportsFamily(.apple9): \(device.supportsFamily(.apple9))")
        Diagnostics.log("  hasUnifiedMemory: \(device.hasUnifiedMemory)")
        Diagnostics.log("  recommendedMaxWorkingSetSize: \(device.recommendedMaxWorkingSetSize / (1024 * 1024)) MB")
    }

    // MARK: - Stroke input

    /// The brush the next stroke will use. A value, and each stroke carries
    /// its own copy (`BrushStroke.brush`), so changing it mid-stroke cannot
    /// alter a stroke already in progress — its grain and its tint come from
    /// the brush it began with.
    var brush: MCBrush = mc_brush_ink_pen() {
        didSet { inkColor.w = Self.tint(for: brush) }
    }

    /// Where stroke opacity is applied depends on the brush's rendering style,
    /// and this is the only place the shell knows about it.
    ///
    /// **Glaze** tints the coverage buffer once at composite, which is what
    /// stops a stroke darkening where it crosses itself — a ceiling on the
    /// whole stroke. **Blending** puts opacity on each dab instead, back in the
    /// engine where the dab is built, so the coverage arrives already carrying
    /// it and the tint has to be 1 or it would be applied twice.
    ///
    /// The double-application is the bug this shape exists to make impossible:
    /// one place decides, and everything else asks it.
    private static func tint(for brush: MCBrush) -> Float {
        brush.renderingStyle == Int32(MC_RENDER_GLAZE.rawValue) ? brush.opacity : 1
    }

    /// The ink a given stroke composites with: the current colour, at the tint
    /// of the brush *that stroke* was begun with.
    private func ink(for stroke: BrushStroke?) -> simd_float4 {
        guard let stroke else { return inkColor }
        return simd_float4(inkColor.x, inkColor.y, inkColor.z, Self.tint(for: stroke.brush))
    }

    /// Ink colour without its alpha, which the rendering style owns.
    func setInkRGB(_ rgb: simd_float3) {
        inkColor = simd_float4(rgb.x, rgb.y, rgb.z, Self.tint(for: brush))
    }

    func setStroke(_ stroke: BrushStroke?, sampleCount: Int) {
        if stroke !== self.stroke {
            // A different stroke while the last one still waits for its frame:
            // the last one is flattened now, before its coverage is cleared
            // for the new one. Within one frame of a lift is quick hatching.
            flushPendingCommit()
            stampedDabs = 0
            coverageNeedsClear = true
            restampedForTaper = false
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
    /// the tiles it touched to the engine. The layer and ink are fixed now,
    /// at the lift, not read again when the frame comes.
    func endStroke(tiles: Set<EngineTile>) {
        guard strokeActive, pendingCommit == nil else { return }
        prediction = nil
        pendingCommit = PendingCommit(tiles: Array(tiles),
                                      layer: engine.activeLayer,
                                      ink: ink(for: stroke))
    }

    /// Discards the stroke in progress without committing it. Nothing needs
    /// repainting: the coverage is only drawn while a stroke is active.
    ///
    /// A stroke already *finished* is not this call's to discard. Once the pen
    /// has lifted the stroke is the artist's, and the only thing that can take
    /// it back is undo — so an abort arriving while one waits for its frame is
    /// about a newer touch the renderer has not been shown yet, and leaves the
    /// finished stroke alone.
    func abortStroke() {
        guard strokeActive, pendingCommit == nil else { return }
        stroke = nil
        prediction = nil
        strokeActive = false
    }

    /// Commits a finished stroke immediately rather than on the next frame.
    ///
    /// Called by anything that would otherwise disturb it: a new stroke, undo,
    /// a layer change. Costs one GPU round trip — the same wait the frame
    /// would have paid — but only in the rare case that something lands
    /// between the lift and the next frame.
    func flushPendingCommit() {
        guard let commit = pendingCommit,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Flush pending commit"
        ensureTextures()
        encodeCoverage(in: commandBuffer)
        if let coverage = scratchTexture {
            compositor.syncLayer(commit.layer, engine: engine)
            compositor.flattenStroke(into: commit.layer, coverage: coverage,
                                     inkColor: commit.ink, commandBuffer: commandBuffer)
        }
        commandBuffer.commit()
        completeCommit(commit, commandBuffer: commandBuffer)
    }

    /// Waits for the flatten, then hands the stroke's tiles to the engine as
    /// one undo step. The one place we stall on the GPU: reading the layer
    /// before the flatten has actually run would capture it a frame stale.
    /// Once per stroke, not per frame.
    private func completeCommit(_ commit: PendingCommit, commandBuffer: MTLCommandBuffer) {
        let waitStarted = CACurrentMediaTime()
        commandBuffer.waitUntilCompleted()
        let readStarted = CACurrentMediaTime()

        engine.beginStroke("Stroke")
        compositor.readBack(layer: commit.layer, tiles: commit.tiles, engine: engine)
        engine.commitStroke()
        engine.evict()

        // Kept apart because they have different cures. The wait is the GPU
        // finishing the frame; the readback is the copy from a screen-shaped
        // texture into tiles.
        stats.gpuWaitMs = (readStarted - waitStarted) * 1000.0
        stats.lastCaptureMs = (CACurrentMediaTime() - readStarted) * 1000.0

        stroke = nil
        prediction = nil
        strokeActive = false
        pendingCommit = nil
    }

    // MARK: - Layers

    func addLayer() {
        flushPendingCommit()
        let id = engine.addLayer(named: "Layer \(engine.layerCount + 1)")
        compositor.markLayerStale(id)
        onLayersChanged?()
        Diagnostics.log("added layer \(id)")
    }

    func duplicateActiveLayer() {
        flushPendingCommit()
        let id = engine.duplicateLayer(engine.activeLayer)
        compositor.markLayerStale(id)
        onLayersChanged?()
    }

    func removeLayer(_ layer: MCLayerId) {
        flushPendingCommit()
        guard engine.removeLayer(layer) else { return }
        compositor.forgetLayer(layer)
        onLayersChanged?()
    }

    func selectLayer(_ layer: MCLayerId) {
        flushPendingCommit()
        engine.setActiveLayer(layer)
        onLayersChanged?()
    }

    func moveLayer(_ layer: MCLayerId, to index: Int) {
        flushPendingCommit()
        guard engine.moveLayer(layer, to: index) else { return }
        onLayersChanged?()
    }

    func setProperties(_ properties: LayerProperties, of layer: MCLayerId) {
        flushPendingCommit()
        // Deliberately does not fire onLayersChanged. The panel initiated this
        // and has already updated itself; rebuilding it here would tear down
        // whichever control the user is still touching.
        engine.setProperties(properties, of: layer)
    }

    // MARK: - Eyedropper

    /// The colour on screen at a canvas pixel. A stroke still waiting for its
    /// frame is flattened first, so the eyedropper can pick the line that was
    /// just drawn.
    func compositeColor(atPixelX x: Int, y: Int) -> simd_float3 {
        flushPendingCommit()
        return engine.compositeColor(atPixelX: Int32(clamping: x), y: Int32(clamping: y))
    }

    // MARK: - History

    @discardableResult
    func undo() -> Bool {
        flushPendingCommit()
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
        flushPendingCommit()
        guard let tiles = engine.redo() else { return false }
        compositor.markAllLayersStale()
        onLayersChanged?()
        Diagnostics.log("redo: \(tiles.count) tiles")
        return true
    }

    func clearActiveLayer() {
        flushPendingCommit()
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
            pixelFormat: StrokeCoverage.pixelFormat, width: width, height: height,
            mipmapped: false)
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

    /// Uniforms for both dab passes, built in one place so the committed stroke
    /// and the predicted tail ahead of it cannot disagree about the grain.
    ///
    /// Depth is forced to zero when there is no texture, which makes the
    /// shader's `depth <= 0` early-out double as the guard that keeps it from
    /// ever sampling an unbound texture.
    private func dabUniforms(width: Int, height: Int, brush: MCBrush) -> MSDabUniforms {
        MSDabUniforms(viewportSize: simd_float2(Float(width), Float(height)),
                      grainDepth: grainTexture == nil ? 0 : brush.grainDepth,
                      grainScale: brush.grainScale,
                      grainBrightness: brush.grainBrightness,
                      grainContrast: brush.grainContrast,
                      grainMovement: brush.grainMovement,
                      _pad: 0)
    }

    private func encodeCoverage(in commandBuffer: MTLCommandBuffer) {
        guard let scratch = scratchTexture, let stroke else { return }

        let count = stroke.dabCount

        // The end taper shrinks dabs that were already stamped at full size,
        // and accumulated coverage cannot be taken back — so the stroke is
        // stamped again from nothing. Once, at the lift, and only for a brush
        // with an end taper. Until 2026-11-06 this case was not handled and
        // the end taper never reached the canvas.
        if !restampedForTaper, stroke.firstRevisedDab < stampedDabs {
            coverageNeedsClear = true
            restampedForTaper = true
        }

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
        encoder.setRenderPipelineState(dabPipeline)

        var uniforms = dabUniforms(width: scratch.width, height: scratch.height,
                                   brush: stroke.brush)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MSDabUniforms>.stride,
                               index: Int(MSBufferIndexUniforms.rawValue))
        // The fragment stage needs them too: the vertex stage decides *where*
        // the grain is sampled, the fragment stage how deeply.
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MSDabUniforms>.stride,
                                 index: Int(MSBufferIndexUniforms.rawValue))
        encoder.setFragmentTexture(grainTexture, index: 0)

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

        var uniforms = dabUniforms(width: target.width, height: target.height,
                                   brush: prediction.brush)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MSDabUniforms>.stride,
                               index: Int(MSBufferIndexUniforms.rawValue))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MSDabUniforms>.stride,
                                 index: Int(MSBufferIndexUniforms.rawValue))
        encoder.setFragmentTexture(grainTexture, index: 0)

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
        let commit = pendingCommit

        if strokeActive {
            encodeCoverage(in: commandBuffer)
        }

        if let commit, let coverage = scratchTexture {
            compositor.syncLayer(commit.layer, engine: engine)
            compositor.flattenStroke(into: commit.layer, coverage: coverage,
                                     inkColor: commit.ink, commandBuffer: commandBuffer)
        }

        let plan = engine.refreshPlan()
        if plan.underDirty {
            compositor.rebuildUnderCache(plan.under, engine: engine, commandBuffer: commandBuffer)
        }
        if plan.overDirty {
            compositor.rebuildOverCache(plan.over, engine: engine, commandBuffer: commandBuffer)
        }

        let live = strokeActive && commit == nil
        compositor.present(into: drawable.texture, plan: plan, engine: engine,
                           strokeCoverage: live ? scratchTexture : nil,
                           inkColor: ink(for: stroke), commandBuffer: commandBuffer)

        // Excluded on the committing frame, so a guess can never be flattened
        // into a layer.
        if live {
            encodePrediction(onto: drawable.texture, in: commandBuffer)
        }

        commandBuffer.addCompletedHandler { [weak self] buffer in
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
            DispatchQueue.main.async { self?.recordGPUTime(gpuMs) }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        if let commit {
            completeCommit(commit, commandBuffer: commandBuffer)
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

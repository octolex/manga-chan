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
//  Rebuilding the whole stroke each frame is O(stroke length) of GPU work per
//  frame. At M0 stroke lengths that is nothing. M3 replaces this with dab
//  stamping and per-tile culling, at which point it needs revisiting.
//
//  Threading: the display link runs on the main run loop and touches arrive on
//  the main thread, so none of the state below needs locking. If the render
//  loop ever moves to its own thread, that changes.
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
}

enum RendererError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case noShaderLibrary
    case missingFunction(String)

    var description: String {
        switch self {
        case .noDevice: return "no Metal device — this build cannot run on this hardware"
        case .noCommandQueue: return "could not create a Metal command queue"
        case .noShaderLibrary: return "default.metallib missing — the .metal file did not compile into the bundle"
        case .missingFunction(let name): return "shader function '\(name)' not found in default.metallib"
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
    private var samplesThisFrame = 0

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

        func function(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else {
                throw RendererError.missingFunction(name)
            }
            return f
        }

        self.device = device
        self.commandQueue = queue
        self.layer = layer

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

    /// Flattens the stroke into the canvas on the next frame.
    func endStroke() {
        guard strokeActive else { return }
        predictionVertices.removeAll(keepingCapacity: true)
        pendingCommit = true
    }

    func clearCanvas() {
        canvasNeedsClear = true
        strokeVertices.removeAll(keepingCapacity: true)
        predictionVertices.removeAll(keepingCapacity: true)
        strokeBufferDirty = true
        strokeActive = false
        pendingCommit = false
        Diagnostics.log("canvas cleared")
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

        func makeTexture(_ format: MTLPixelFormat, _ label: String) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                      width: width,
                                                                      height: height,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            let texture = device.makeTexture(descriptor: descriptor)
            texture?.label = label
            return texture
        }

        canvasTexture = makeTexture(layer.pixelFormat, "Canvas")
        scratchTexture = makeTexture(Self.scratchFormat, "Stroke scratch")
        canvasNeedsClear = true

        let mb = (width * height * 5) / (1024 * 1024) // 4 bytes canvas + 1 scratch
        Diagnostics.log("textures \(width)×\(height) (~\(mb) MB)")
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

    /// Redraws the in-progress stroke into the scratch texture.
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
        // The fullscreen triangle covers every pixel, so there is nothing worth
        // loading or clearing first.
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

        if committingThisFrame {
            strokeVertices.removeAll(keepingCapacity: true)
            predictionVertices.removeAll(keepingCapacity: true)
            strokeBuffer = nil
            strokeBufferDirty = false
            strokeActive = false
            pendingCommit = false
        }

        commandBuffer.addCompletedHandler { [weak self] buffer in
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
            DispatchQueue.main.async { self?.recordGPUTime(gpuMs) }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

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

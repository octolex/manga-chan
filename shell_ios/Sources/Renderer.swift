//
//  Renderer.swift
//
//  Two passes per frame:
//
//    1. Committed stroke geometry is drawn into a persistent canvas texture.
//    2. The canvas is blitted to the drawable, then predicted geometry is
//       drawn on top of it.
//
//  The split is the important part. Predicted touches are a guess about where
//  the Pencil is going, and they are frequently wrong. Drawing them only to
//  the drawable — which is discarded and rebuilt every frame — means a wrong
//  guess vanishes on the next frame instead of leaving a permanent artefact
//  on the canvas. That rule survives into the real tile engine at M1.
//
//  Threading: the display link runs on the main run loop and touches arrive on
//  the main thread, so the vertex queues below need no locking. If the render
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
    private let strokePipeline: MTLRenderPipelineState
    private let blitPipeline: MTLRenderPipelineState
    private let layer: CAMetalLayer

    private var displayLink: CAMetalDisplayLink?

    private var canvasTexture: MTLTexture?
    private var canvasNeedsClear = true

    private var committedVertices: [MSStrokeVertex] = []
    private var predictedVertices: [MSStrokeVertex] = []
    private var samplesThisFrame = 0

    /// Ink colour, straight (not premultiplied); the shader premultiplies.
    var inkColor = simd_float4(0.09, 0.09, 0.11, 1.0)

    var onStats: ((FrameStats) -> Void)?

    private var stats = FrameStats()
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var smoothedFPS: Double = 0
    private var smoothedGPUMs: Double = 0
    private var smoothedCPUMs: Double = 0

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

        let strokeDescriptor = MTLRenderPipelineDescriptor()
        strokeDescriptor.label = "Stroke ribbon"
        strokeDescriptor.vertexFunction = try function("stroke_vertex")
        strokeDescriptor.fragmentFunction = try function("stroke_fragment")
        let attachment = strokeDescriptor.colorAttachments[0]!
        attachment.pixelFormat = layer.pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        // Source factor is .one because the fragment shader already outputs
        // premultiplied alpha.
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.strokePipeline = try device.makeRenderPipelineState(descriptor: strokeDescriptor)

        let blitDescriptor = MTLRenderPipelineDescriptor()
        blitDescriptor.label = "Canvas blit"
        blitDescriptor.vertexFunction = try function("fullscreen_vertex")
        blitDescriptor.fragmentFunction = try function("blit_fragment")
        blitDescriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
        self.blitPipeline = try device.makeRenderPipelineState(descriptor: blitDescriptor)

        super.init()

        Diagnostics.log("Metal device: \(device.name)")
        Diagnostics.log("  supportsFamily(.apple8): \(device.supportsFamily(.apple8))")
        Diagnostics.log("  supportsFamily(.apple9): \(device.supportsFamily(.apple9))")
        Diagnostics.log("  hasUnifiedMemory: \(device.hasUnifiedMemory)")
        Diagnostics.log("  recommendedMaxWorkingSetSize: \(device.recommendedMaxWorkingSetSize / (1024 * 1024)) MB")
    }

    // MARK: - Input

    func appendCommitted(_ vertices: [MSStrokeVertex], sampleCount: Int) {
        committedVertices.append(contentsOf: vertices)
        samplesThisFrame += sampleCount
    }

    func setPredicted(_ vertices: [MSStrokeVertex]) {
        predictedVertices = vertices
    }

    func clearCanvas() {
        canvasNeedsClear = true
        committedVertices.removeAll(keepingCapacity: true)
        predictedVertices.removeAll(keepingCapacity: true)
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

    private func ensureCanvas() {
        let width = Int(layer.drawableSize.width)
        let height = Int(layer.drawableSize.height)
        guard width > 0, height > 0 else { return }

        if let existing = canvasTexture, existing.width == width, existing.height == height {
            return
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: layer.pixelFormat,
                                                                 width: width,
                                                                 height: height,
                                                                 mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        canvasTexture = device.makeTexture(descriptor: descriptor)
        canvasTexture?.label = "Canvas"
        canvasNeedsClear = true

        let mb = (width * height * 4) / (1024 * 1024)
        Diagnostics.log("canvas texture \(width)×\(height) (\(mb) MB)")
    }

    private func encode(_ vertices: [MSStrokeVertex], into encoder: MTLRenderCommandEncoder) {
        guard !vertices.isEmpty else { return }
        let length = MemoryLayout<MSStrokeVertex>.stride * vertices.count
        guard let buffer = device.makeBuffer(bytes: vertices, length: length, options: .storageModeShared) else {
            return
        }
        encoder.setRenderPipelineState(strokePipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: Int(MSBufferIndexVertices.rawValue))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    private func render(to drawable: CAMetalDrawable, targetTimestamp: CFTimeInterval) {
        let cpuStart = CACurrentMediaTime()

        ensureCanvas()
        guard let canvas = canvasTexture,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Frame \(stats.frameIndex)"

        let vertexCount = committedVertices.count + predictedVertices.count

        // Pass 1 — commit finished geometry into the canvas.
        if canvasNeedsClear || !committedVertices.isEmpty {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = canvas
            pass.colorAttachments[0].loadAction = canvasNeedsClear ? .clear : .load
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                encoder.label = "Commit strokes"
                encode(committedVertices, into: encoder)
                encoder.endEncoding()
            }
            canvasNeedsClear = false
            committedVertices.removeAll(keepingCapacity: true)
        }

        // Pass 2 — present the canvas, then the transient prediction on top.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        // The fullscreen triangle covers every pixel, so there is nothing worth
        // loading or clearing first.
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.label = "Present"
            encoder.setRenderPipelineState(blitPipeline)
            encoder.setFragmentTexture(canvas, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encode(predictedVertices, into: encoder)
            encoder.endEncoding()
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

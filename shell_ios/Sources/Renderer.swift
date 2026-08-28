//
//  Renderer.swift
//
//  M0 draws one triangle. The value here is not the triangle — it is that the
//  frame pacing, the GPU timing capture and the stats plumbing are correct
//  from the first commit, so that every later milestone is measured rather
//  than guessed at.
//

import Metal
import QuartzCore
import UIKit
import simd

struct FrameStats {
    var fps: Double = 0
    var cpuFrameMs: Double = 0
    var gpuFrameMs: Double = 0
    var frameIndex: UInt64 = 0
    var drawableSize: CGSize = .zero
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
    private let pipelineState: MTLRenderPipelineState
    private let layer: CAMetalLayer

    private var displayLink: CAMetalDisplayLink?
    private var vertexBuffer: MTLBuffer?

    /// Called on the main thread after every presented frame.
    var onStats: ((FrameStats) -> Void)?

    private var stats = FrameStats()
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var smoothedFPS: Double = 0
    private var smoothedGPUMs: Double = 0
    private var smoothedCPUMs: Double = 0

    init(layer: CAMetalLayer) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.noCommandQueue
        }
        guard let library = device.makeDefaultLibrary() else {
            throw RendererError.noShaderLibrary
        }
        guard let vertexFunction = library.makeFunction(name: "flat_vertex") else {
            throw RendererError.missingFunction("flat_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "flat_fragment") else {
            throw RendererError.missingFunction("flat_fragment")
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

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Flat colour pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
        self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        super.init()

        makeTriangle()

        Diagnostics.log("Metal device: \(device.name)")
        Diagnostics.log("  supportsFamily(.apple8): \(device.supportsFamily(.apple8))")
        Diagnostics.log("  supportsFamily(.apple9): \(device.supportsFamily(.apple9))")
        Diagnostics.log("  hasUnifiedMemory: \(device.hasUnifiedMemory)")
        Diagnostics.log("  recommendedMaxWorkingSetSize: \(device.recommendedMaxWorkingSetSize / (1024 * 1024)) MB")
    }

    private func makeTriangle() {
        let vertices: [MSVertex] = [
            MSVertex(position: simd_float2( 0.0,  0.55), color: simd_float4(0.95, 0.26, 0.35, 1.0)),
            MSVertex(position: simd_float2(-0.55, -0.45), color: simd_float4(0.20, 0.65, 0.95, 1.0)),
            MSVertex(position: simd_float2( 0.55, -0.45), color: simd_float4(0.98, 0.82, 0.25, 1.0)),
        ]
        vertexBuffer = device.makeBuffer(bytes: vertices,
                                         length: MemoryLayout<MSVertex>.stride * vertices.count,
                                         options: .storageModeShared)
        vertexBuffer?.label = "Triangle vertices"
    }

    // MARK: - Frame loop

    func start() {
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        // Ask for the full 120Hz the iPad Air M4 can deliver. Info.plist must
        // also set CADisableMinimumFrameDuration or this is silently ignored.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        Diagnostics.log("display link started")
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

    private func render(to drawable: CAMetalDrawable, targetTimestamp: CFTimeInterval) {
        let cpuStart = CACurrentMediaTime()

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1.0)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        commandBuffer.label = "Frame \(stats.frameIndex)"

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: Int(MSBufferIndexVertices.rawValue))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] buffer in
            // gpuStartTime/gpuEndTime are the only GPU timings available to us
            // without Instruments, so they carry a lot of weight in this project.
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
            DispatchQueue.main.async {
                self?.recordGPUTime(gpuMs)
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        let cpuMs = (CACurrentMediaTime() - cpuStart) * 1000.0
        recordCPUTime(cpuMs, targetTimestamp: targetTimestamp)
    }

    // MARK: - Statistics

    private func recordCPUTime(_ cpuMs: Double, targetTimestamp: CFTimeInterval) {
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
        onStats?(stats)
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

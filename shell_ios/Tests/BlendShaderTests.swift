//
//  BlendShaderTests.swift
//
//  Renders every blend mode in Metal and compares it, pixel by pixel, against
//  the CPU implementation in core/blend.cpp.
//
//  This is the test the whole simulator harness exists for. A shader that
//  blends subtly wrong compiles, runs at full speed, and produces output that
//  looks approximately right — on a device where we cannot attach a frame
//  debugger to find out otherwise. The CPU version is unit-tested against
//  known values; this pins the GPU to it.
//
//  Layout: the backdrop varies down the rows, the source across the columns,
//  so one draw covers every pairing. The source is uniform within a column,
//  which means the vertex shader's V flip cannot misalign the comparison —
//  a detail worth keeping if this grid is ever extended.
//

import XCTest
import Metal
import simd

final class BlendShaderTests: XCTestCase {

    /// Premultiplied RGBA8. Channels may never exceed alpha.
    private struct Pixel {
        let r: UInt8, g: UInt8, b: UInt8, a: UInt8
        var bytes: [UInt8] { [r, g, b, a] }
    }

    private let backdrops: [Pixel] = [
        Pixel(r: 0, g: 0, b: 0, a: 0),           // transparent
        Pixel(r: 0, g: 0, b: 0, a: 255),         // black
        Pixel(r: 255, g: 255, b: 255, a: 255),   // white
        Pixel(r: 128, g: 128, b: 128, a: 255),   // mid grey
        Pixel(r: 255, g: 0, b: 0, a: 255),       // red
        Pixel(r: 0, g: 200, b: 0, a: 255),       // green
        Pixel(r: 0, g: 0, b: 200, a: 255),       // blue
        Pixel(r: 64, g: 64, b: 64, a: 128),      // half-alpha grey
    ]

    private let sources: [Pixel] = [
        Pixel(r: 0, g: 0, b: 0, a: 0),
        Pixel(r: 0, g: 0, b: 0, a: 255),
        Pixel(r: 255, g: 255, b: 255, a: 255),
        Pixel(r: 128, g: 128, b: 128, a: 255),
        Pixel(r: 200, g: 40, b: 40, a: 255),
        Pixel(r: 40, g: 200, b: 80, a: 255),
        Pixel(r: 30, g: 30, b: 220, a: 255),
        Pixel(r: 90, g: 30, b: 60, a: 160),
    ]

    /// GPU and CPU both work in float and quantise to 8 bits at different
    /// points, and unpremultiplying a half-alpha pixel divides by ~0.5, which
    /// amplifies any disagreement. A few levels is expected; a wrong formula
    /// misses by far more than this.
    private let tolerance = 3

    func testEveryBlendModeMatchesTheCPUReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: type(of: self)))

        let pipeline = try makePipeline(device: device, library: library)

        let width = sources.count
        let height = backdrops.count

        let sourceTexture = try makeTexture(device: device, width: width, height: height,
                                            usage: [.shaderRead], label: "source")
        // Uniform down each column, so the V flip in the vertex shader cannot
        // shift which source a row is compared against.
        var sourceBytes = [UInt8]()
        for _ in 0..<height {
            for x in 0..<width { sourceBytes.append(contentsOf: sources[x].bytes) }
        }
        upload(sourceBytes, to: sourceTexture, width: width, height: height)

        let modeCount = Int(mc_blend_mode_count())
        XCTAssertEqual(modeCount, 26, "blend mode count changed; the shader table needs updating too")

        var worstDifference = 0
        var worstDescription = ""

        for opacity in [Float(1.0), Float(0.6)] {
            for mode in 0..<modeCount {
                let name = String(cString: mc_blend_mode_name(Int32(mode)))

                // The backdrop is the attachment: the shader reads it back out
                // of tile memory, which is what programmable blending means.
                let target = try makeTexture(device: device, width: width, height: height,
                                             usage: [.renderTarget, .shaderRead],
                                             label: "target-\(name)")
                var backdropBytes = [UInt8]()
                for y in 0..<height {
                    for _ in 0..<width { backdropBytes.append(contentsOf: backdrops[y].bytes) }
                }
                upload(backdropBytes, to: target, width: width, height: height)

                render(device: device, queue: queue, pipeline: pipeline,
                       target: target, source: sourceTexture,
                       mode: Int32(mode), opacity: opacity)

                var actual = [UInt8](repeating: 0, count: width * height * 4)
                target.getBytes(&actual,
                                bytesPerRow: width * 4,
                                from: MTLRegionMake2D(0, 0, width, height),
                                mipmapLevel: 0)

                for y in 0..<height {
                    for x in 0..<width {
                        var expected = [UInt8](repeating: 0, count: 4)
                        var backdrop = backdrops[y].bytes
                        var source = sources[x].bytes
                        mc_blend_pixel(Int32(mode), &backdrop, &source, opacity, &expected)

                        let offset = (y * width + x) * 4
                        for channel in 0..<4 {
                            let got = Int(actual[offset + channel])
                            let want = Int(expected[channel])
                            let difference = abs(got - want)
                            if difference > worstDifference {
                                worstDifference = difference
                                worstDescription =
                                    "\(name) opacity \(opacity) backdrop[\(y)] source[\(x)] "
                                    + "channel \(channel): GPU \(got) vs CPU \(want)"
                            }
                            XCTAssertLessThanOrEqual(
                                difference, tolerance,
                                "\(name) at opacity \(opacity), backdrop[\(y)] over source[\(x)], "
                                + "channel \(channel): GPU produced \(got), CPU expects \(want)")
                        }
                    }
                }
            }
        }

        print("blend shaders: \(modeCount) modes × \(backdrops.count * sources.count) pairs "
              + "× 2 opacities, worst channel difference \(worstDifference)")
        if !worstDescription.isEmpty {
            print("  worst case: \(worstDescription)")
        }
    }

    // MARK: - Metal helpers

    private func makePipeline(device: MTLDevice, library: MTLLibrary) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Blend under test"
        descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "blend_vertex"))
        descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "blend_fragment"))
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        // Fixed-function blending stays OFF. The shader reads the destination
        // itself and returns the finished result; enabling both would blend
        // the blend.
        descriptor.colorAttachments[0].isBlendingEnabled = false
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func makeTexture(device: MTLDevice, width: Int, height: Int,
                             usage: MTLTextureUsage, label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        // rgba8Unorm rather than the canvas's bgra8Unorm purely so the byte
        // order matches Rgba8 in core, removing a channel-swap from the
        // comparison. Blend maths does not care about channel order.
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.label = label
        return texture
    }

    private func upload(_ bytes: [UInt8], to texture: MTLTexture, width: Int, height: Int) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: base,
                            bytesPerRow: width * 4)
        }
    }

    private func render(device: MTLDevice, queue: MTLCommandQueue,
                        pipeline: MTLRenderPipelineState,
                        target: MTLTexture, source: MTLTexture,
                        mode: Int32, opacity: Float) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        // .load, not .clear: the backdrop has to survive into the shader,
        // which is the entire mechanism being tested.
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            XCTFail("could not encode the blend pass")
            return
        }

        var uniforms = MSBlendUniforms(mode: mode, opacity: opacity)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MSBlendUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        buffer.commit()
        buffer.waitUntilCompleted()
    }
}

//
//  DabShaderTests.swift
//
//  Pins the two accumulation modes in CI, on real Metal.
//
//  "Does a stroke darken where it crosses itself?" was a device test that could
//  only be answered by eye — and only at brush opacities where the difference
//  is actually visible, which is why it could not be judged at all while the
//  ink is hardwired to full strength. It is arithmetic, so it belongs here.
//
//  Both modes are checked, because each is correct for a different brush and a
//  regression in either is silent: max accumulation that has quietly become
//  alpha-over still draws a plausible-looking stroke.
//

import Metal
import XCTest

final class DabShaderTests: XCTestCase {

    private let size = 64

    func testMaximumAccumulationDoesNotDarkenOverlaps() throws {
        let coverage = try renderTwoOverlappingDabs(accumulation: .maximum, flow: 0.5)

        // Two half-strength dabs on top of each other must read exactly as one.
        // Alpha-over would give 0.75 here, which is the bead along a stroke
        // that crosses itself.
        XCTAssertEqual(coverage.overlap, 0.5, accuracy: 0.01,
                       "max accumulation must not build up within a stroke")
        XCTAssertEqual(coverage.single, 0.5, accuracy: 0.01)
    }

    func testBuildupAccumulationDoesDarkenOverlaps() throws {
        let coverage = try renderTwoOverlappingDabs(accumulation: .buildup, flow: 0.5)

        // 0.5 over 0.5 is 0.75. An airbrush is supposed to do this.
        XCTAssertEqual(coverage.overlap, 0.75, accuracy: 0.01,
                       "buildup accumulation must build up within a stroke")
        XCTAssertEqual(coverage.single, 0.5, accuracy: 0.01)
    }

    func testAFullyHardDabStillHasAnAntialiasedEdge() throws {
        let device = try metalDevice()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: type(of: self)))
        let texture = try makeCoverageTexture(device: device)

        // One large hard dab in the middle.
        let dab = MSDab(x: 32, y: 32, radius: 20, angle: 0, flow: 1,
                        roundness: 1, hardness: 1)
        try render([dab], accumulation: .maximum, device: device, queue: queue,
                   library: library, into: texture)
        let pixels = readBack(texture)

        XCTAssertEqual(Float(pixels[32 * size + 32]) / 255.0, 1.0, accuracy: 0.01,
                       "the centre of a hard dab is fully covered")
        XCTAssertEqual(Float(pixels[32 * size + 60]) / 255.0, 0.0, accuracy: 0.01,
                       "well outside the dab is empty")

        // Somewhere on the rim there must be a partially covered pixel. Without
        // one, the edge is a hard step and every dab reads as a polygon.
        var sawPartial = false
        for x in 0..<size {
            let value = Float(pixels[32 * size + x]) / 255.0
            if value > 0.05 && value < 0.95 { sawPartial = true }
        }
        XCTAssertTrue(sawPartial, "a hard dab must still be antialiased at the rim")
    }

    func testRoundnessFlattensTheDab() throws {
        let device = try metalDevice()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: type(of: self)))
        let texture = try makeCoverageTexture(device: device)

        // A flat nib, unrotated: wide across x, thin down y.
        let dab = MSDab(x: 32, y: 32, radius: 20, angle: 0, flow: 1,
                        roundness: 0.25, hardness: 1)
        try render([dab], accumulation: .maximum, device: device, queue: queue,
                   library: library, into: texture)
        let pixels = readBack(texture)

        XCTAssertGreaterThan(Float(pixels[32 * size + 46]) / 255.0, 0.9,
                             "the long axis reaches the full radius")
        XCTAssertLessThan(Float(pixels[46 * size + 32]) / 255.0, 0.1,
                          "the short axis is squashed by roundness")
    }

    // MARK: - Harness

    private enum Accumulation {
        case maximum
        case buildup
    }

    private struct Coverage {
        var single: Float
        var overlap: Float
    }

    private func renderTwoOverlappingDabs(accumulation: Accumulation,
                                          flow: Float) throws -> Coverage {
        let device = try metalDevice()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: type(of: self)))
        let texture = try makeCoverageTexture(device: device)

        // Two dabs sharing a wide overlap, well away from either rim so the
        // sample points are unambiguous.
        let a = MSDab(x: 24, y: 32, radius: 14, angle: 0, flow: flow,
                      roundness: 1, hardness: 1)
        let b = MSDab(x: 40, y: 32, radius: 14, angle: 0, flow: flow,
                      roundness: 1, hardness: 1)
        try render([a, b], accumulation: accumulation, device: device, queue: queue,
                   library: library, into: texture)

        let pixels = readBack(texture)
        return Coverage(single: Float(pixels[32 * size + 14]) / 255.0,   // only dab a
                        overlap: Float(pixels[32 * size + 32]) / 255.0)  // both
    }

    private func metalDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        return device
    }

    private func makeCoverageTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        // Shared rather than private: the test has to read it back, which the
        // app never does.
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.label = "Dab coverage under test"
        return texture
    }

    private func makePipeline(accumulation: Accumulation,
                              device: MTLDevice,
                              library: MTLLibrary) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Dab coverage under test"
        descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "dab_vertex"))
        descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "dab_coverage_fragment"))
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .r8Unorm
        attachment.isBlendingEnabled = true

        // These must stay identical to Renderer's. That duplication is the
        // weakness of this test: it verifies the shader and the blend maths,
        // not that the app configures the same state.
        switch accumulation {
        case .maximum:
            attachment.rgbBlendOperation = .max
            attachment.alphaBlendOperation = .max
        case .buildup:
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceColor
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func render(_ dabs: [MSDab],
                        accumulation: Accumulation,
                        device: MTLDevice,
                        queue: MTLCommandQueue,
                        library: MTLLibrary,
                        into texture: MTLTexture) throws {
        let pipeline = try makePipeline(accumulation: accumulation,
                                        device: device, library: library)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)

        var uniforms = MSDabUniforms(
            viewportSize: simd_float2(Float(size), Float(size)))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MSDabUniforms>.stride,
                               index: Int(MSBufferIndexUniforms.rawValue))

        var dabs = dabs
        encoder.setVertexBytes(&dabs, length: MemoryLayout<MSDab>.stride * dabs.count,
                               index: Int(MSBufferIndexVertices.rawValue))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: dabs.count)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    private func readBack(_ texture: MTLTexture) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: size,
                             from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return pixels
    }
}

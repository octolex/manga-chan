//
//  DabShaderTests.swift
//
//  Pins the dab shader in CI, on real Metal: accumulation, dab shape, grain.
//
//  "Does a stroke darken where it crosses itself?" was a device test that could
//  only be answered by eye — and only at brush opacities where the difference
//  is actually visible, which is why it could not be judged at all while the
//  ink is hardwired to full strength. It is arithmetic, so it belongs here.
//
//  Both accumulation modes are checked, because each is correct for a different
//  brush and a regression in either is silent: max accumulation that has quietly
//  become alpha-over still draws a plausible-looking stroke.
//
//  The grain tests are the same argument one step further. A grain sampled with
//  a flipped V, a missing half-texel, or the wrong address mode still produces a
//  textured stroke that looks entirely convincing in a screenshot — there is no
//  way to judge it by eye. So the shader is compared against the engine's own
//  CPU sampler, pixel by pixel, exactly as the blend modes are.
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
                        roundness: 1, hardness: 1, grainOffset: 0)
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
                        roundness: 0.25, hardness: 1, grainOffset: 0)
        try render([dab], accumulation: .maximum, device: device, queue: queue,
                   library: library, into: texture)
        let pixels = readBack(texture)

        XCTAssertGreaterThan(Float(pixels[32 * size + 46]) / 255.0, 0.9,
                             "the long axis reaches the full radius")
        XCTAssertLessThan(Float(pixels[46 * size + 32]) / 255.0, 0.1,
                          "the short axis is squashed by roundness")
    }

    // MARK: - Grain

    func testGrainMatchesTheEngineReference() throws {
        let scale: Float = 96
        let pixels = try renderGrained(
            [dab(x: 32, y: 32, radius: 26)], depth: 1, scale: scale, movement: MSGrainCanvas)
        let map = try XCTUnwrap(GrainTexture.bytes())

        // Sampled well inside the rim, where the analytic edge is exactly 1 and
        // the only thing left in the coverage is the grain. That is what makes
        // an exact comparison possible at all: near the edge, coverage is the
        // product of grain and an antialiased falloff we deliberately do not
        // reproduce on the CPU.
        var compared = 0
        for y in 20...44 {
            for x in 20...44 {
                guard insideDab(x: x, y: y, cx: 32, cy: 32, radius: 26, margin: 3) else { continue }

                // The rasteriser samples at pixel centres, and the vertex shader
                // interpolates the canvas position linearly, so the fragment at
                // (x, y) carries exactly (x + 0.5, y + 0.5).
                let expected = mc_grain_sample(map, Int32(GrainTexture.size),
                                               (Float(x) + 0.5) / scale,
                                               (Float(y) + 0.5) / scale)
                let got = Float(pixels[y * size + x]) / 255.0

                // Three of 255. One comes from quantising the r8Unorm target,
                // the rest from the sampler's sub-texel weight precision, which
                // Metal only guarantees to 8 bits. A flipped V or a missing
                // half-texel misses by far more than this.
                XCTAssertEqual(got, expected, accuracy: 0.012,
                               "grain at (\(x), \(y)) disagrees with the engine reference")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 200, "the comparison must actually cover the dab")
    }

    func testGrainDepthOffLeavesCoverageExact() throws {
        let pixels = try renderGrained(
            [dab(x: 32, y: 32, radius: 24, flow: 0.5)],
            depth: 0, scale: 96, movement: MSGrainCanvas)

        // The "off" end of the slider has to be genuinely off. A grain that
        // still modulated faintly at zero would make every brush in the app
        // lighter than it was before grain existed.
        XCTAssertEqual(Float(pixels[32 * size + 32]) / 255.0, 0.5, accuracy: 0.01)
    }

    func testCanvasGrainSurvivesOverlappingDabs() throws {
        let scale: Float = 96
        let map = try XCTUnwrap(GrainTexture.bytes())

        // Two dabs sharing a wide overlap, under max accumulation.
        let overlapped = try renderGrained(
            [dab(x: 24, y: 32, radius: 18), dab(x: 40, y: 32, radius: 18)],
            depth: 1, scale: scale, movement: MSGrainCanvas)

        // Canvas grain is anchored to the pixel, so every dab covering a pixel
        // samples the same value there and max(g·c₁, g·c₂) = g·max(c₁, c₂). The
        // overlap must therefore read as the plain grain — no doubling, no
        // second pattern laid over the first. This identity is the whole reason
        // canvas grain reads as paper rather than as print on the stroke, and a
        // grain accidentally anchored to the dab would break it here and
        // nowhere else.
        for x in 28...36 {
            let expected = mc_grain_sample(map, Int32(GrainTexture.size),
                                           (Float(x) + 0.5) / scale,
                                           32.5 / scale)
            XCTAssertEqual(Float(overlapped[32 * size + x]) / 255.0, expected, accuracy: 0.012,
                           "overlapping dabs changed the canvas grain at x=\(x)")
        }
    }

    func testRollingGrainMovesWithTheStrokeAndCanvasGrainDoesNot() throws {
        // The same dab in the same place, at two points along the stroke.
        let atStart = dab(x: 32, y: 32, radius: 24, grainOffset: 0)
        let farAlong = dab(x: 32, y: 32, radius: 24, grainOffset: 137)

        let rollingA = try renderGrained([atStart], depth: 1, scale: 96, movement: MSGrainRolling)
        let rollingB = try renderGrained([farAlong], depth: 1, scale: 96, movement: MSGrainRolling)
        let canvasA = try renderGrained([atStart], depth: 1, scale: 96, movement: MSGrainCanvas)
        let canvasB = try renderGrained([farAlong], depth: 1, scale: 96, movement: MSGrainCanvas)

        // Rolling grain must consume the arc length the engine records per dab.
        // If `grainOffset` never reached the shader these two would be
        // identical, and the mode would silently be a second copy of Canvas.
        var rollingDifferences = 0
        var canvasDifferences = 0
        for y in 24...40 {
            for x in 24...40 {
                if rollingA[y * size + x] != rollingB[y * size + x] { rollingDifferences += 1 }
                if canvasA[y * size + x] != canvasB[y * size + x] { canvasDifferences += 1 }
            }
        }
        XCTAssertGreaterThan(rollingDifferences, 100,
                             "rolling grain must scroll with arc length")

        // And canvas grain must ignore it entirely: anchored to the pixel, it
        // cannot care where along the stroke the dab happens to be.
        XCTAssertEqual(canvasDifferences, 0,
                       "canvas grain must not depend on position along the stroke")
    }

    // MARK: - Harness

    private enum Accumulation {
        case maximum
        case buildup
    }

    private func dab(x: Float, y: Float, radius: Float,
                     flow: Float = 1, grainOffset: Float = 0) -> MSDab {
        MSDab(x: x, y: y, radius: radius, angle: 0, flow: flow,
              roundness: 1, hardness: 1, grainOffset: grainOffset)
    }

    /// True well inside the dab, where the analytic edge has already reached 1.
    private func insideDab(x: Int, y: Int, cx: Float, cy: Float,
                           radius: Float, margin: Float) -> Bool {
        let dx = Float(x) + 0.5 - cx
        let dy = Float(y) + 0.5 - cy
        return (dx * dx + dy * dy).squareRoot() < radius - margin
    }

    private func renderGrained(_ dabs: [MSDab],
                               depth: Float,
                               scale: Float,
                               movement: MSGrainMovement) throws -> [UInt8] {
        let device = try metalDevice()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: type(of: self)))
        let texture = try makeCoverageTexture(device: device)
        let grain = try XCTUnwrap(GrainTexture.make(device: device))

        try render(dabs, accumulation: .maximum, device: device, queue: queue,
                   library: library, into: texture,
                   grain: grain, depth: depth, scale: scale, movement: movement)
        return readBack(texture)
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
                      roundness: 1, hardness: 1, grainOffset: 0)
        let b = MSDab(x: 40, y: 32, radius: 14, angle: 0, flow: flow,
                      roundness: 1, hardness: 1, grainOffset: 0)
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
                        into texture: MTLTexture,
                        grain: MTLTexture? = nil,
                        depth: Float = 0,
                        scale: Float = 1,
                        movement: MSGrainMovement = MSGrainCanvas) throws {
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
            viewportSize: simd_float2(Float(size), Float(size)),
            grainDepth: depth,
            grainScale: scale,
            grainMovement: Int32(movement.rawValue),
            _pad: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MSDabUniforms>.stride,
                               index: Int(MSBufferIndexUniforms.rawValue))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MSDabUniforms>.stride,
                                 index: Int(MSBufferIndexUniforms.rawValue))
        // Bound even for the tests that use no grain: the shader declares the
        // texture, and Metal's validation layer objects to an unbound one
        // whether or not the sample is reached.
        encoder.setFragmentTexture(grain ?? GrainTexture.make(device: device), index: 0)

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

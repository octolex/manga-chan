//
//  DabShaderTests.swift
//
//  Pins the dab shader in CI, on real Metal: the ink model, dab shape, grain.
//
//  "Does a stroke darken where it crosses itself?" was a device test that could
//  only be answered by eye — and only at brush opacities where the difference
//  is actually visible, which is why it could not be judged at all while the
//  ink is hardwired to full strength. It is arithmetic, so it belongs here.
//
//  Coverage carries two numbers with different blend operations: ink density in
//  RGB, stroke geometry in alpha, composited as min(density, geometry). Both
//  ends of that are checked, because either one alone is plausible and wrong.
//  Density alone bloats the antialiased edge; geometry alone makes flow and
//  opacity redundant. A regression in either still draws a convincing stroke.
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

    // MARK: - Ink model

    func testFullFlowDoesNotDarkenOverlaps() throws {
        let coverage = try renderTwoOverlappingDabs(flow: 1)

        // At full flow one pass saturates, so a second changes nothing. This is
        // what the Maximum mode used to provide, now reached by a value rather
        // than by a switch.
        XCTAssertEqual(coverage.overlap, 1.0, accuracy: 0.01,
                       "full flow must not build past solid")
        XCTAssertEqual(coverage.single, 1.0, accuracy: 0.01)
    }

    func testPartialFlowBuildsUpOnOverlaps() throws {
        let coverage = try renderTwoOverlappingDabs(flow: 0.5)

        // 0.5 over 0.5 is 0.75. A pencil is supposed to do this, and reaching it
        // no longer needs a mode — only a lower flow. That is the whole point of
        // removing the switch: these two tests differ by a value, not a state.
        XCTAssertEqual(coverage.overlap, 0.75, accuracy: 0.01,
                       "flow below full must build up within a stroke")
        XCTAssertEqual(coverage.single, 0.5, accuracy: 0.01)
    }

    func testDensityAccumulationDoesNotBloatTheEdge() throws {
        // The regression test for the trap that shaped this design.
        //
        // Ink density accumulates, so a pixel just outside the stroke's true
        // edge picks up a little from every dab that passes near it. Left to
        // itself that saturates to 1 at tight spacing: the stroke grows a pixel
        // and its rim goes hard. The geometry channel is the only thing that
        // still remembers the edge was soft, and min() at composite time is what
        // applies it. Drop either half and this test fails.
        //
        // A dense row of dabs is the worst case and also the ordinary one — it
        // is what every stroke is.
        var dabs: [MSDab] = []
        for i in 0..<60 {
            dabs.append(dab(x: 8 + Float(i) * 0.8, y: 32, radius: 10))
        }
        let pixels = try renderCoverage(dabs)

        // Straight down from the middle of the row to well outside it. There
        // must be a partially covered pixel on the way; without one the edge is
        // a hard step, which is exactly what unchecked accumulation produces.
        var sawPartial = false
        for y in 32...52 where composited(pixels, x: 32, y: y) > 0.05
                             && composited(pixels, x: 32, y: y) < 0.95 {
            sawPartial = true
        }
        XCTAssertTrue(sawPartial, "accumulation bloated the edge into a hard step")

        // And the edge stays where the geometry puts it. These dabs have radius
        // 10 centred on y=32, so y=46 is outside however much density piled up.
        XCTAssertEqual(composited(pixels, x: 32, y: 32), 1.0, accuracy: 0.02,
                       "the body of the stroke is solid")
        XCTAssertEqual(composited(pixels, x: 32, y: 46), 0.0, accuracy: 0.02,
                       "well outside the stroke stays empty")
    }

    // MARK: - Dab shape

    func testAFullyHardDabStillHasAnAntialiasedEdge() throws {
        let pixels = try renderCoverage([dab(x: 32, y: 32, radius: 20)])

        XCTAssertEqual(composited(pixels, x: 32, y: 32), 1.0, accuracy: 0.01,
                       "the centre of a hard dab is fully covered")
        XCTAssertEqual(composited(pixels, x: 60, y: 32), 0.0, accuracy: 0.01,
                       "well outside the dab is empty")

        var sawPartial = false
        for x in 0..<size {
            let value = composited(pixels, x: x, y: 32)
            if value > 0.05 && value < 0.95 { sawPartial = true }
        }
        XCTAssertTrue(sawPartial, "a hard dab must still be antialiased at the rim")
    }

    func testRoundnessFlattensTheDab() throws {
        // A flat nib, unrotated: wide across x, thin down y.
        let nib = MSDab(x: 32, y: 32, radius: 20, angle: 0, flow: 1,
                        roundness: 0.25, hardness: 1, grainOffset: 0)
        let pixels = try renderCoverage([nib])

        XCTAssertGreaterThan(composited(pixels, x: 46, y: 32), 0.9,
                             "the long axis reaches the full radius")
        XCTAssertLessThan(composited(pixels, x: 32, y: 46), 0.1,
                          "the short axis is squashed by roundness")
    }

    // MARK: - Grain

    func testGrainMatchesTheEngineReference() throws {
        // Flow below full and depth below full on purpose. The threshold
        // renormalises, so at flow 1 the body of a stroke is solid and there is
        // no grain left to compare; and at depth 1 much of the map clamps to
        // zero, where a wrong sampler would agree with a right one. These values
        // keep every sampled pixel strictly between 0 and 1, so every one of
        // them carries information.
        let scale: Float = 96
        let flow: Float = 0.7
        let depth: Float = 0.6

        let pixels = try renderCoverage([dab(x: 32, y: 32, radius: 26, flow: flow)],
                                        depth: depth, scale: scale)
        let map = try XCTUnwrap(GrainTexture.bytes())

        var compared = 0
        for y in 20...44 {
            for x in 20...44 {
                guard insideDab(x: x, y: y, cx: 32, cy: 32, radius: 26, margin: 3) else { continue }

                // The rasteriser samples at pixel centres and the vertex shader
                // interpolates the canvas position linearly, so the fragment at
                // (x, y) carries exactly (x + 0.5, y + 0.5).
                let grain = mc_grain_sample(map, Int32(GrainTexture.size),
                                            (Float(x) + 0.5) / scale,
                                            (Float(y) + 0.5) / scale)
                let tooth = grain * depth
                let expected = (flow - tooth) / (1 - tooth)

                // Wider than the 3-of-255 the multiply version allowed, because
                // the threshold amplifies: d/d(grain) of the expression above is
                // about -1.1 at these values, so a sampler off by one level
                // lands a little over one level out here.
                XCTAssertEqual(composited(pixels, x: x, y: y), expected, accuracy: 0.015,
                               "grain at (\(x), \(y)) disagrees with the engine reference")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 200, "the comparison must actually cover the dab")
    }

    func testFullFlowLeavesNoToothShowing() throws {
        // A deliberate consequence of thresholding rather than multiplying, and
        // pinned so it is not later mistaken for a bug and "fixed" back into a
        // veil. Ink that covers completely hides the surface under it; that is
        // why a marker shows no paper texture and a pencil does.
        let pixels = try renderCoverage([dab(x: 32, y: 32, radius: 24, flow: 1)],
                                        depth: 1, scale: 96)

        for x in 26...38 {
            XCTAssertEqual(composited(pixels, x: x, y: 32), 1.0, accuracy: 0.02,
                           "full flow must cover the tooth at x=\(x)")
        }
    }

    func testGrainDepthOffLeavesCoverageExact() throws {
        let pixels = try renderCoverage([dab(x: 32, y: 32, radius: 24, flow: 0.5)],
                                        depth: 0, scale: 96)

        // The "off" end of the slider has to be genuinely off. A grain that
        // still bit faintly at zero would change every brush in the app.
        XCTAssertEqual(composited(pixels, x: 32, y: 32), 0.5, accuracy: 0.01)
    }

    func testGrainIsAnchoredToTheCanvasNotTheDab() throws {
        // The defining property of canvas grain: the tooth at a canvas pixel is
        // a property of that pixel, so two different dabs covering it find the
        // same grain there. Both sample points sit deep inside their dab, where
        // geometry is 1, so the only thing that could differ is the grain.
        let a = try renderCoverage([dab(x: 26, y: 32, radius: 22, flow: 0.6)],
                                   depth: 0.7, scale: 96)
        let b = try renderCoverage([dab(x: 38, y: 32, radius: 22, flow: 0.6)],
                                   depth: 0.7, scale: 96)

        for x in 30...34 {
            XCTAssertEqual(composited(a, x: x, y: 32), composited(b, x: x, y: 32),
                           accuracy: 0.01,
                           "the tooth at x=\(x) moved with the dab instead of staying on the canvas")
        }
    }

    func testRollingGrainMovesWithTheStrokeAndCanvasGrainDoesNot() throws {
        // The same dab in the same place, at two points along the stroke.
        let atStart = dab(x: 32, y: 32, radius: 24, flow: 0.6, grainOffset: 0)
        let farAlong = dab(x: 32, y: 32, radius: 24, flow: 0.6, grainOffset: 137)

        let rollingA = try renderCoverage([atStart], depth: 0.7, scale: 96, movement: MSGrainRolling)
        let rollingB = try renderCoverage([farAlong], depth: 0.7, scale: 96, movement: MSGrainRolling)
        let canvasA = try renderCoverage([atStart], depth: 0.7, scale: 96)
        let canvasB = try renderCoverage([farAlong], depth: 0.7, scale: 96)

        // Rolling grain must consume the arc length the engine records per dab.
        // If `grainOffset` never reached the shader these would be identical and
        // the mode would silently be a second copy of Canvas.
        var rollingDifferences = 0
        var canvasDifferences = 0
        for y in 24...40 {
            for x in 24...40 {
                if composited(rollingA, x: x, y: y) != composited(rollingB, x: x, y: y) {
                    rollingDifferences += 1
                }
                if composited(canvasA, x: x, y: y) != composited(canvasB, x: x, y: y) {
                    canvasDifferences += 1
                }
            }
        }
        XCTAssertGreaterThan(rollingDifferences, 100,
                             "rolling grain must scroll with arc length")
        XCTAssertEqual(canvasDifferences, 0,
                       "canvas grain must not depend on position along the stroke")
    }

    // MARK: - Harness

    private struct Coverage {
        var single: Float
        var overlap: Float
    }

    private func dab(x: Float, y: Float, radius: Float,
                     flow: Float = 1, grainOffset: Float = 0) -> MSDab {
        MSDab(x: x, y: y, radius: radius, angle: 0, flow: flow,
              roundness: 1, hardness: 1, grainOffset: grainOffset)
    }

    /// What the composite pass would produce: ink density capped by geometry.
    /// Every assertion goes through this rather than reading a raw channel, so
    /// the tests check what reaches the canvas rather than an intermediate.
    private func composited(_ pixels: [UInt8], x: Int, y: Int) -> Float {
        let i = (y * size + x) * 4
        return min(Float(pixels[i]) / 255.0, Float(pixels[i + 3]) / 255.0)
    }

    /// True well inside the dab, where the analytic edge has already reached 1.
    private func insideDab(x: Int, y: Int, cx: Float, cy: Float,
                           radius: Float, margin: Float) -> Bool {
        let dx = Float(x) + 0.5 - cx
        let dy = Float(y) + 0.5 - cy
        return (dx * dx + dy * dy).squareRoot() < radius - margin
    }

    private func renderTwoOverlappingDabs(flow: Float) throws -> Coverage {
        // Two dabs sharing a wide overlap, well away from either rim so the
        // sample points are unambiguous.
        let a = dab(x: 24, y: 32, radius: 14, flow: flow)
        let b = dab(x: 40, y: 32, radius: 14, flow: flow)
        let pixels = try renderCoverage([a, b])
        return Coverage(single: composited(pixels, x: 14, y: 32),   // only dab a
                        overlap: composited(pixels, x: 32, y: 32))  // both
    }

    private func renderCoverage(_ dabs: [MSDab],
                                depth: Float = 0,
                                scale: Float = 1,
                                movement: MSGrainMovement = MSGrainCanvas) throws -> [UInt8] {
        let device = try metalDevice()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: type(of: self)))
        let texture = try makeCoverageTexture(device: device)
        let grain = try XCTUnwrap(GrainTexture.make(device: device))

        try render(dabs, device: device, queue: queue, library: library,
                   into: texture, grain: grain,
                   depth: depth, scale: scale, movement: movement)
        return readBack(texture)
    }

    private func metalDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        return device
    }

    private func makeCoverageTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        // Shared rather than private: the test has to read it back, which the
        // app never does.
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.label = "Dab coverage under test"
        return texture
    }

    private func makePipeline(device: MTLDevice,
                              library: MTLLibrary) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Dab coverage under test"
        descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "dab_vertex"))
        descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "dab_coverage_fragment"))
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .rgba8Unorm
        attachment.isBlendingEnabled = true

        // These must stay identical to Renderer's. That duplication is the
        // weakness of this test: it verifies the shader and the blend maths, not
        // that the app configures the same state.
        attachment.rgbBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceColor
        attachment.alphaBlendOperation = .max
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func render(_ dabs: [MSDab],
                        device: MTLDevice,
                        queue: MTLCommandQueue,
                        library: MTLLibrary,
                        into texture: MTLTexture,
                        grain: MTLTexture? = nil,
                        depth: Float = 0,
                        scale: Float = 1,
                        movement: MSGrainMovement = MSGrainCanvas) throws {
        let pipeline = try makePipeline(device: device, library: library)

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
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: size * 4,
                             from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return pixels
    }
}

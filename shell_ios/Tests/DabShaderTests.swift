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
        // Full flow and mid depth on purpose. The composite takes the smaller
        // of density and tooth, so any pixel where density is the smaller one
        // reads back a flat number that carries nothing about the sampler — a
        // wrong sampler would pass there. Flow 1 puts the tooth on the bottom
        // everywhere, and depth 0.6 keeps it clear of both 0 and 1, so all 200+
        // sampled pixels are live.
        let scale: Float = 96
        let flow: Float = 1.0
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
                let tooth = (1 - depth) + grain * depth
                let expected = min(flow, tooth)

                // Back to the tight bound the multiply version allowed: the
                // expression is linear in the sampled value with slope `depth`,
                // so a sampler off by one level of 255 lands under one level out
                // rather than being amplified.
                XCTAssertEqual(composited(pixels, x: x, y: y), expected, accuracy: 0.008,
                               "grain at (\(x), \(y)) disagrees with the engine reference")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 200, "the comparison must actually cover the dab")
    }

    func testFullFlowStillShowsTheTooth() throws {
        // This test asserted the exact opposite until 2026-09-05, when Procreate
        // was measured on device: at full opacity and full grain depth the paper
        // is plainly visible through the body of a stroke. The old assertion was
        // reasoning ("a marker shows no paper texture") pinned as if it were a
        // measurement, and it defended a model that failed on device three times.
        let pixels = try renderCoverage([dab(x: 32, y: 32, radius: 24, flow: 1)],
                                        depth: 1, scale: 96)

        var belowHalf = 0
        var aboveHalf = 0
        for x in 26...38 {
            if composited(pixels, x: x, y: 32) < 0.5 { belowHalf += 1 } else { aboveHalf += 1 }
        }
        // Both, not merely "some texture": a stroke where every pixel dipped
        // would be a veil at constant strength, and one where none did would be
        // the bug this replaces.
        XCTAssertGreaterThan(belowHalf, 0, "full flow must not paint over the tooth")
        XCTAssertGreaterThan(aboveHalf, 0, "the tooth must not mask the whole stroke either")
    }

    func testCanvasGrainNeverFillsInButRollingGrainDoes() throws {
        // The measurement that settled the whole grain model, and the one no
        // test defended while three implementations of it failed on device.
        // Procreate, 2026-09-05: scrub twenty passes over one patch and canvas
        // grain is exactly as textured as after one pass, while rolling grain
        // goes solid.
        //
        // Both modes get the same twenty dabs in the same place. The only
        // difference is the arc length each one carries.
        let stack = (0..<20).map {
            dab(x: 32, y: 32, radius: 24, flow: 1, grainOffset: Float($0) * 37)
        }
        let one = [dab(x: 32, y: 32, radius: 24, flow: 1, grainOffset: 0)]

        let canvasOnce = try renderCoverage(one, depth: 1, scale: 96)
        let canvasMany = try renderCoverage(stack, depth: 1, scale: 96)
        let rollingMany = try renderCoverage(stack, depth: 1, scale: 96,
                                             movement: MSGrainRolling)

        var canvasMoved = 0
        var canvasTotal: Float = 0
        var rollingTotal: Float = 0
        var samples = 0
        for y in 24...40 {
            for x in 24...40 {
                guard insideDab(x: x, y: y, cx: 32, cy: 32, radius: 24, margin: 3) else { continue }
                samples += 1
                if abs(composited(canvasMany, x: x, y: y)
                       - composited(canvasOnce, x: x, y: y)) > 0.01 { canvasMoved += 1 }
                canvasTotal += composited(canvasMany, x: x, y: y)
                rollingTotal += composited(rollingMany, x: x, y: y)
            }
        }
        XCTAssertGreaterThan(samples, 200, "the comparison must actually cover the dab")

        // Canvas is the exact assertion: not "less fill", none at all.
        XCTAssertEqual(canvasMoved, 0,
                       "canvas grain filled in under repeated passes; the tooth must be permanent")

        // Rolling is a relative one on purpose. How far twenty passes climb
        // depends on how much contrast the map has, and ours is smooth fractal
        // noise clustered near mid-grey — pinning an absolute level here would
        // be pinning the map rather than the mechanism.
        let canvasMean = canvasTotal / Float(samples)
        let rollingMean = rollingTotal / Float(samples)
        print("grain fill: canvas \(canvasMean), rolling \(rollingMean)")
        XCTAssertGreaterThan(rollingMean, canvasMean + 0.1,
                             "rolling grain must fill in where canvas grain cannot")
    }

    /// The shader's Brightness and Contrast are the engine's, to the pixel.
    ///
    /// `grain_levels` in Shaders.metal is a hand-copy of `mc::grainLevels`, and
    /// a hand-copy is a thing that drifts. Nothing about a mismatch here would
    /// announce itself: it compiles, it renders, and the grain is simply not
    /// quite the grain the engine believes it is applying — the most expensive
    /// class of bug this project can have, and the reason the harness exists.
    func testGrainLevelsMatchTheEngineReference() throws {
        let scale: Float = 96
        let depth: Float = 0.6
        let map = try XCTUnwrap(GrainTexture.bytes())

        // Both signs of both controls, and one pair together — the order they
        // are applied in is exactly the kind of thing a hand-copy gets wrong,
        // and it only shows when both are non-zero.
        for (brightness, contrast) in [(Float(0.0), Float(1.0)),
                                       (Float(0.0), Float(-0.6)),
                                       (Float(0.25), Float(0.0)),
                                       (Float(-0.2), Float(0.7))] {
            let pixels = try renderCoverage([dab(x: 32, y: 32, radius: 26, flow: 1)],
                                            depth: depth, scale: scale,
                                            brightness: brightness, contrast: contrast)
            var compared = 0
            for y in 20...44 {
                for x in 20...44 {
                    guard insideDab(x: x, y: y, cx: 32, cy: 32, radius: 26, margin: 3) else { continue }
                    let raw = mc_grain_sample(map, Int32(GrainTexture.size),
                                              (Float(x) + 0.5) / scale,
                                              (Float(y) + 0.5) / scale)
                    let levelled = mc_grain_levels(raw, brightness, contrast)
                    let expected = min(Float(1.0), (1 - depth) + levelled * depth)

                    XCTAssertEqual(composited(pixels, x: x, y: y), expected, accuracy: 0.01,
                                   "levels at (\(x), \(y)) disagree with the engine "
                                   + "at brightness \(brightness), contrast \(contrast)")
                    compared += 1
                }
            }
            XCTAssertGreaterThan(compared, 200)
        }
    }

    /// Neutral settings sample the raw map, and that has to be exact.
    ///
    /// Both sides take an early-out when brightness and contrast are zero,
    /// because `(s - 0.5) + 0.5` is not `s` in floating point. Every brush that
    /// never opens the grain section goes down this path, so it is the one that
    /// most needs to be the same on both sides of the ABI.
    func testNeutralLevelsChangeNothing() throws {
        let scale: Float = 96
        let depth: Float = 0.6
        let plain = try renderCoverage([dab(x: 32, y: 32, radius: 26, flow: 1)],
                                       depth: depth, scale: scale)
        let neutral = try renderCoverage([dab(x: 32, y: 32, radius: 26, flow: 1)],
                                         depth: depth, scale: scale,
                                         brightness: 0, contrast: 0)
        XCTAssertEqual(plain, neutral, "neutral levels must be a no-op, not nearly one")
    }

    /// Contrast is what turns our map from a wash into tooth.
    ///
    /// The measurement, in the engine's own suite: 90.1% of the grain map sits
    /// between 0.2 and 0.8, and full contrast takes that to 14.3%. This is the
    /// same claim made where it matters — on the rendered coverage — because
    /// the whole reason the first grain attempt was rejected was that it "veiled
    /// the stroke uniformly", and it did, and it was the map rather than the
    /// mechanism.
    func testContrastSpreadsTheRenderedTooth() throws {
        let scale: Float = 96
        let depth: Float = 1.0
        let dabs = [dab(x: 32, y: 32, radius: 26, flow: 1)]

        func spread(contrast: Float) throws -> Double {
            let pixels = try renderCoverage(dabs, depth: depth, scale: scale,
                                            contrast: contrast)
            var values: [Double] = []
            for y in 20...44 {
                for x in 20...44 where insideDab(x: x, y: y, cx: 32, cy: 32,
                                                 radius: 26, margin: 3) {
                    values.append(Double(composited(pixels, x: x, y: y)))
                }
            }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
                / Double(values.count)
            return variance.squareRoot()
        }

        let flat = try spread(contrast: 0)
        let crisp = try spread(contrast: 1)
        print("tooth spread: \(flat) raw -> \(crisp) at full contrast")
        XCTAssertGreaterThan(crisp, flat * 1.5,
                             "full contrast must visibly open the tooth out")
    }

    func testGrainDepthOffLeavesCoverageExact() throws {
        let pixels = try renderCoverage([dab(x: 32, y: 32, radius: 24, flow: 0.5)],
                                        depth: 0, scale: 96)

        // The "off" end of the slider has to be genuinely off. A grain that
        // still bit faintly at zero would change every brush in the app — and
        // with the tooth now multiplying the geometry channel, a depth of 0 has
        // to yield a tooth of exactly 1 rather than merely nearly 1.
        XCTAssertEqual(composited(pixels, x: 32, y: 32), 0.5, accuracy: 0.01)
    }

    func testGrainIsAnchoredToTheCanvasNotTheDab() throws {
        // The defining property of canvas grain: the tooth at a canvas pixel is
        // a property of that pixel, so two different dabs covering it find the
        // same grain there. Both sample points sit deep inside their dab, where
        // geometry is 1, so the only thing that could differ is the grain.
        // Flow 1 so the tooth is what the composite returns; at a lower flow
        // the density would clamp the brighter half of the map to one constant
        // and the comparison would pass there whatever the grain did.
        let a = try renderCoverage([dab(x: 26, y: 32, radius: 22, flow: 1)],
                                   depth: 0.7, scale: 96)
        let b = try renderCoverage([dab(x: 38, y: 32, radius: 22, flow: 1)],
                                   depth: 0.7, scale: 96)

        for x in 30...34 {
            XCTAssertEqual(composited(a, x: x, y: 32), composited(b, x: x, y: 32),
                           accuracy: 0.01,
                           "the tooth at x=\(x) moved with the dab instead of staying on the canvas")
        }
    }

    func testRollingGrainMovesWithTheStrokeAndCanvasGrainDoesNot() throws {
        // The same dab in the same place, at two points along the stroke.
        let atStart = dab(x: 32, y: 32, radius: 24, flow: 1, grainOffset: 0)
        let farAlong = dab(x: 32, y: 32, radius: 24, flow: 1, grainOffset: 137)

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

    // MARK: - Precision and sub-pixel dabs (2026-11-06)

    /// The density a pixel at the centre of `count` identical dabs should reach,
    /// in exact arithmetic: alpha-over of `perDab`, `count` times.
    private func exactDensity(perDab: Float, count: Int) -> Float {
        1 - pow(1 - perDab, Float(count))
    }

    /// A low Blending opacity must still build.
    ///
    /// Each dab at Opacity *o* carries `o^2.6`, which at 5% is about a tenth of
    /// one 8-bit step. In an 8-bit buffer every such dab rounds to nothing, so a
    /// stroke at 5% drew nothing however long it was scrubbed. This renders the
    /// stroke's own centre — 28 dabs, about what one pass of the default pen
    /// lays on a pixel, then 560 for a twenty-pass scrub — in the shipping
    /// format, and also in 8-bit for the record.
    func testLowBlendingOpacityStillBuilds() throws {
        for (opacity, count) in [(Float(0.05), 28), (Float(0.05), 560), (Float(0.10), 28)] {
            let perDab = pow(opacity, 2.6)
            let dabs = Array(repeating: dab(x: 32, y: 32, radius: 20, flow: perDab), count: count)
            let exact = exactDensity(perDab: perDab, count: count)
            let shipping = composited(try renderCoverage(dabs), x: 32, y: 32)
            let eightBit = composited(try renderCoverage(dabs, format: .rgba8Unorm), x: 32, y: 32)
            print(String(format: "coverage precision: opacity %.0f%%, %ld dabs — exact %.4f, shipping %.4f, 8-bit %.4f",
                         opacity * 100, count, exact, shipping, eightBit))
            XCTAssertEqual(shipping, exact, accuracy: max(0.002, exact * 0.05),
                           "the coverage buffer is too coarse for a \(Int(opacity * 100))% Blending stroke")
        }
    }

    /// A dab smaller than a pixel must show wherever it lands.
    ///
    /// Drawn at its true size, a 0.4 px dab centred on a pixel corner touches
    /// no pixel centre and draws nothing — the beaded or missing 1 px line of
    /// bug 13. Drawn at the minimum size with its flow scaled by area, the ink
    /// it puts down is about the same wherever it lands.
    func testSubPixelDabIsDrawnWhereverItLands() throws {
        var totals: [Float] = []
        for offset: Float in [0.0, 0.25, 0.5] {
            let pixels = try renderCoverage([dab(x: 32 + offset, y: 32 + offset, radius: 0.4)])
            var total: Float = 0
            for y in 28...36 { for x in 28...36 { total += composited(pixels, x: x, y: y) } }
            totals.append(total)
        }
        print("sub-pixel dab: total ink at three landings \(totals)")
        XCTAssertTrue(totals.allSatisfy { $0 > 0 }, "a sub-pixel dab vanished: \(totals)")
        let spread = (totals.max() ?? 0) / max(totals.min() ?? 1, 1e-6)
        XCTAssertLessThan(spread, 1.5, "a sub-pixel dab's weight depends on where it lands: \(totals)")
    }

    /// Below the minimum size, weight goes as area: half the radius, a quarter
    /// of the ink. At and above it, nothing changes.
    func testSubPixelDabsTradeSizeForOpacity() throws {
        func total(_ radius: Float) throws -> Float {
            let pixels = try renderCoverage([dab(x: 32.5, y: 32.5, radius: radius)])
            var sum: Float = 0
            for y in 26...38 { for x in 26...38 { sum += composited(pixels, x: x, y: y) } }
            return sum
        }
        let full = try total(MS_MIN_DRAWN_RADIUS)
        let half = try total(MS_MIN_DRAWN_RADIUS / 2)
        XCTAssertEqual(half / full, 0.25, accuracy: 0.02)
    }

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
    private func composited(_ pixels: [Float], x: Int, y: Int) -> Float {
        let i = (y * size + x) * 4
        return min(pixels[i], pixels[i + 3])
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
                                movement: MSGrainMovement = MSGrainCanvas,
                                brightness: Float = 0,
                                contrast: Float = 0,
                                format: MTLPixelFormat = StrokeCoverage.pixelFormat) throws -> [Float] {
        let device = try metalDevice()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: type(of: self)))
        let texture = try makeCoverageTexture(device: device, format: format)
        let grain = try XCTUnwrap(GrainTexture.make(device: device))

        try render(dabs, device: device, queue: queue, library: library,
                   into: texture, grain: grain,
                   depth: depth, scale: scale, movement: movement,
                   brightness: brightness, contrast: contrast)
        return readBack(texture)
    }

    private func metalDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        return device
    }

    /// The shipping format unless a test asks for another — every existing
    /// test now runs on exactly what the renderer accumulates into.
    private func makeCoverageTexture(device: MTLDevice,
                                     format: MTLPixelFormat) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        // Shared rather than private: the test has to read it back, which the
        // app never does.
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.label = "Dab coverage under test"
        return texture
    }

    private func makePipeline(device: MTLDevice, library: MTLLibrary,
                              format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Dab coverage under test"
        descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "dab_vertex"))
        descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "dab_coverage_fragment"))
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = format
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
                        movement: MSGrainMovement = MSGrainCanvas,
                        brightness: Float = 0,
                        contrast: Float = 0) throws {
        let pipeline = try makePipeline(device: device, library: library,
                                        format: texture.pixelFormat)

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
            grainBrightness: brightness,
            grainContrast: contrast,
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

        // A buffer, not setVertexBytes: Metal caps inline bytes at 4 KB, which
        // is 128 dabs, and the precision tests stamp hundreds.
        let length = MemoryLayout<MSDab>.stride * dabs.count
        let dabBuffer = try XCTUnwrap(dabs.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: length, options: .storageModeShared)
        })
        encoder.setVertexBuffer(dabBuffer, offset: 0, index: Int(MSBufferIndexVertices.rawValue))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: dabs.count)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// RGBA normalised to 0...1, whichever unorm format the texture is.
    private func readBack(_ texture: MTLTexture) -> [Float] {
        let count = size * size * 4
        switch texture.pixelFormat {
        case .rgba16Unorm:
            var raw = [UInt16](repeating: 0, count: count)
            raw.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                texture.getBytes(base, bytesPerRow: size * 8,
                                 from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            }
            return raw.map { Float($0) / 65535.0 }
        default:
            var raw = [UInt8](repeating: 0, count: count)
            raw.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                texture.getBytes(base, bytesPerRow: size * 4,
                                 from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            }
            return raw.map { Float($0) / 255.0 }
        }
    }
}

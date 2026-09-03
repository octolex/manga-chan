//
//  ColorPickerTests.swift
//
//  The colour picker, rendered and read back pixel by pixel.
//
//  Three bugs reached the device in one build here, and every one of them was
//  visible in a screenshot and invisible to every test we had: the brightness
//  axis drawn upside down, drags eaten by the enclosing scroll view, and a hue
//  strip painted as twelve flat bands. That is the same shape as every other
//  bug this project has shipped — UIKit doing something reasonable at the wrong
//  moment, in the shell, where the C++ suite cannot see it.
//
//  Two of the three are geometry in a bitmap, so they are assertable. The
//  scroll-hijack one is not: it needs a real gesture recogniser arbitrating a
//  real touch sequence, so it stays a device test. Worth being honest about
//  which is which rather than pretending the whole class is covered.
//

import UIKit
import XCTest

final class ColorPickerTests: XCTestCase {

    // The picker's own layout: a 150pt square, then a 26pt hue strip 10pt
    // below it, then the swatch row.
    private let width: CGFloat = 300
    private let squareHeight: CGFloat = 150
    private let hueStripMidY: CGFloat = 173

    private func makePicker(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> ColorPickerView {
        let picker = ColorPickerView(frame: CGRect(x: 0, y: 0, width: width, height: 220))
        picker.setColor(UIColor(hue: hue, saturation: saturation,
                                brightness: brightness, alpha: 1))
        picker.setNeedsLayout()
        picker.layoutIfNeeded()
        return picker
    }

    func testTheColourRoundTripsThroughTheControl() {
        let picker = makePicker(hue: 0.6, saturation: 0.8, brightness: 0.7)

        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(picker.color.getHue(&h, saturation: &s, brightness: &b, alpha: &a))
        XCTAssertEqual(h, 0.6, accuracy: 0.01)
        XCTAssertEqual(s, 0.8, accuracy: 0.01)
        XCTAssertEqual(b, 0.7, accuracy: 0.01)
    }

    func testBrightnessRunsBrightAtTheTop() throws {
        // Marker parked in the bottom-left so its ring is nowhere near the
        // pixels being sampled.
        let picker = makePicker(hue: 0.5, saturation: 0.08, brightness: 0.08)
        let raster = try XCTUnwrap(rasterise(picker))

        let top = raster.rgb(x: width * 0.6, y: 15)
        let bottom = raster.rgb(x: width * 0.6, y: squareHeight - 15)

        // Guards the harness rather than the picker: if layer.render produced
        // nothing, everything below would compare zero against zero and pass.
        XCTAssertGreaterThan(luminance(top), 0.05,
                             "the square rendered empty — this is a harness failure, not a picker one")

        // The whole bug: a drawRect context is y-flipped relative to Core
        // Graphics, so a CGImage drawn through context.draw(_:in:) lands upside
        // down. Touch mapping stayed correct, so the picker returned the colour
        // you meant and showed you a different one.
        XCTAssertGreaterThan(luminance(top), luminance(bottom) + 0.3,
                             "the brightness axis is upside down")
    }

    func testSaturationRunsGreyAtTheLeft() throws {
        let picker = makePicker(hue: 0.5, saturation: 0.08, brightness: 0.08)
        let raster = try XCTUnwrap(rasterise(picker))

        let grey = raster.rgb(x: width * 0.1, y: squareHeight * 0.5)
        let vivid = raster.rgb(x: width * 0.9, y: squareHeight * 0.5)

        // Distance between the extreme channels is saturation, near enough for
        // an axis-direction check and free of any colour-space argument.
        XCTAssertGreaterThan(spread(vivid), spread(grey) + 0.2,
                             "the saturation axis is reversed")
    }

    func testTheHueStripIsAGradientRatherThanBands() throws {
        let picker = makePicker(hue: 0.5, saturation: 0.8, brightness: 0.8)
        let raster = try XCTUnwrap(rasterise(picker))

        // Twelve flat rectangles yield twelve distinct colours no matter how
        // finely they are sampled. An interpolated ramp yields nearly one per
        // sample, so counting them separates the two decisively.
        var seen = Set<Int>()
        let samples = 60
        for i in 0..<samples {
            let x = 5 + (width - 10) * CGFloat(i) / CGFloat(samples - 1)
            let c = raster.rgb(x: x, y: hueStripMidY)
            seen.insert(Int(c.r * 255) << 16 | Int(c.g * 255) << 8 | Int(c.b * 255))
        }
        XCTAssertGreaterThan(seen.count, 30,
                             "the hue strip is banded: \(seen.count) distinct colours in \(samples) samples")
    }

    // MARK: - Harness

    private struct Raster {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let scale: CGFloat

        /// Sampled in view points; the renderer works at the screen's scale.
        func rgb(x: CGFloat, y: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let px = min(max(Int(x * scale), 0), width - 1)
            let py = min(max(Int(y * scale), 0), height - 1)
            let i = (py * width + px) * 4
            return (CGFloat(pixels[i]) / 255.0,
                    CGFloat(pixels[i + 1]) / 255.0,
                    CGFloat(pixels[i + 2]) / 255.0)
        }
    }

    private func rasterise(_ view: UIView) -> Raster? {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { context in
            view.layer.render(in: context.cgContext)
        }
        guard let cg = image.cgImage, view.bounds.height > 0 else { return nil }

        let w = cg.width
        let h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            // Row 0 of a bitmap context's buffer is the top of the image, so
            // the buffer indexes the same way the view is read on screen.
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Raster(pixels: pixels, width: w, height: h,
                      scale: CGFloat(h) / view.bounds.height)
    }

    private func luminance(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    private func spread(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b))
    }
}

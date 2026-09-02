//
//  ColorPickerView.swift
//
//  A saturation/brightness square over a hue slider — the layout every
//  painting app converges on, because it puts the two axes an artist adjusts
//  most under one thumb and leaves hue as a deliberate second act.
//
//  The square is drawn once per hue into a CGImage rather than per frame.
//  Redrawing 256×256 pixels on every touch move would be the obvious way to
//  write this and would cost more than the whole brush engine.
//

import UIKit

final class ColorPickerView: UIView {

    /// Fires continuously while dragging. Callers must not rebuild this view in
    /// response — that lesson cost us the opacity slider once already.
    var onChange: ((UIColor) -> Void)?

    private(set) var hue: CGFloat = 0
    private(set) var saturation: CGFloat = 0
    private(set) var brightness: CGFloat = 0

    private let square = SquareView()
    private let hueSlider = HueSliderView()
    private let swatch = UIView()
    private let readout = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    var color: UIColor {
        UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    func setColor(_ color: UIColor) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return }
        hue = h
        saturation = s
        brightness = b
        square.hue = h
        square.marker = CGPoint(x: s, y: 1 - b)
        hueSlider.hue = h
        refresh()
    }

    private func build() {
        square.translatesAutoresizingMaskIntoConstraints = false
        hueSlider.translatesAutoresizingMaskIntoConstraints = false
        swatch.translatesAutoresizingMaskIntoConstraints = false
        readout.translatesAutoresizingMaskIntoConstraints = false

        swatch.layer.cornerRadius = 6
        swatch.layer.borderWidth = 1
        swatch.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor

        readout.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        readout.textColor = UIColor(white: 1, alpha: 0.6)

        addSubview(square)
        addSubview(hueSlider)
        addSubview(swatch)
        addSubview(readout)

        NSLayoutConstraint.activate([
            square.topAnchor.constraint(equalTo: topAnchor),
            square.leadingAnchor.constraint(equalTo: leadingAnchor),
            square.trailingAnchor.constraint(equalTo: trailingAnchor),
            square.heightAnchor.constraint(equalToConstant: 150),

            hueSlider.topAnchor.constraint(equalTo: square.bottomAnchor, constant: 10),
            hueSlider.leadingAnchor.constraint(equalTo: leadingAnchor),
            hueSlider.trailingAnchor.constraint(equalTo: trailingAnchor),
            hueSlider.heightAnchor.constraint(equalToConstant: 26),

            swatch.topAnchor.constraint(equalTo: hueSlider.bottomAnchor, constant: 10),
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 44),
            swatch.heightAnchor.constraint(equalToConstant: 24),
            swatch.bottomAnchor.constraint(equalTo: bottomAnchor),

            readout.centerYAnchor.constraint(equalTo: swatch.centerYAnchor),
            readout.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 10),
        ])

        square.onChange = { [weak self] s, b in
            guard let self else { return }
            saturation = s
            brightness = b
            refresh()
        }
        hueSlider.onChange = { [weak self] h in
            guard let self else { return }
            hue = h
            square.hue = h
            refresh()
        }

        setColor(UIColor(white: 0.09, alpha: 1))
    }

    private func refresh() {
        swatch.backgroundColor = color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        readout.text = String(format: "#%02X%02X%02X",
                              Int(r * 255), Int(g * 255), Int(b * 255))
        onChange?(color)
    }
}

// MARK: - Saturation / brightness square

private final class SquareView: UIView, ScrollDragImmune {

    var onChange: ((CGFloat, CGFloat) -> Void)?

    /// Marker position in unit coordinates: x is saturation, y is 1 - brightness.
    var marker: CGPoint = .zero { didSet { setNeedsDisplay() } }

    var hue: CGFloat = 0 {
        didSet {
            guard hue != oldValue else { return }
            cached = nil
            setNeedsDisplay()
        }
    }

    /// The gradient for the current hue. Rebuilt only when the hue changes, not
    /// on every touch: this is a per-pixel loop, and running it per drag event
    /// would cost more than everything else on screen put together.
    private var cached: CGImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        layer.cornerRadius = 8
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        if cached == nil { cached = makeGradient() }
        if let cached {
            // UIImage.draw rather than context.draw(_:in:). A drawRect context
            // is y-flipped relative to Core Graphics, so drawing a CGImage
            // through the CG call renders it upside down — which inverted the
            // brightness axis on screen while the touch mapping below stayed
            // correct. The picker therefore returned the colour you meant and
            // showed you a different one, which is the worst way for a colour
            // picker to be wrong.
            UIImage(cgImage: cached).draw(in: bounds)
        }

        // A ring rather than a filled dot, so the colour under it stays visible.
        let centre = CGPoint(x: marker.x * bounds.width, y: marker.y * bounds.height)
        let ring = CGRect(x: centre.x - 8, y: centre.y - 8, width: 16, height: 16)
        context.setLineWidth(2)
        context.setStrokeColor(UIColor.white.cgColor)
        context.strokeEllipse(in: ring)
        context.setLineWidth(1)
        context.setStrokeColor(UIColor(white: 0, alpha: 0.5).cgColor)
        context.strokeEllipse(in: ring.insetBy(dx: -1.5, dy: -1.5))
    }

    private func makeGradient() -> CGImage? {
        // Deliberately coarse. The result is scaled up to the view, and the
        // gradient is smooth enough that 64×64 is indistinguishable from full
        // resolution while costing a sixteenth as much to build.
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            let brightness = 1 - CGFloat(y) / CGFloat(side - 1)
            for x in 0..<side {
                let saturation = CGFloat(x) / CGFloat(side - 1)
                let colour = UIColor(hue: hue, saturation: saturation,
                                     brightness: brightness, alpha: 1)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                colour.getRed(&r, green: &g, blue: &b, alpha: &a)
                let i = (y * side + x) * 4
                pixels[i] = UInt8(r * 255)
                pixels[i + 1] = UInt8(g * 255)
                pixels[i + 2] = UInt8(b * 255)
                pixels[i + 3] = 255
            }
        }

        return pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return context.makeImage()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { track(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { track(touches) }

    private func track(_ touches: Set<UITouch>) {
        guard let point = touches.first?.location(in: self), bounds.width > 0 else { return }
        let x = min(max(point.x / bounds.width, 0), 1)
        let y = min(max(point.y / bounds.height, 0), 1)
        marker = CGPoint(x: x, y: y)
        onChange?(x, 1 - y)
    }
}

// MARK: - Hue slider

private final class HueSliderView: UIView, ScrollDragImmune {

    var onChange: ((CGFloat) -> Void)?
    var hue: CGFloat = 0 { didSet { setNeedsDisplay() } }

    /// The hue ramp, built once.
    ///
    /// This was twelve filled rectangles, on the reasoning that the eye cannot
    /// resolve banding on a 26pt strip. It plainly can — the bands were the
    /// first thing anyone noticed. They were also a lie about the mapping: a
    /// band painted the hue at its left edge while a tap anywhere in it
    /// selected the hue under the finger, so the strip could be up to a
    /// twelfth of the spectrum away from what it would give you. Interpolating
    /// makes the colour shown at a point the colour that point returns.
    private static let spectrum: CGGradient? = {
        // Every 10 degrees. Core Graphics interpolates in RGB between stops,
        // which at that spacing is indistinguishable from a true HSV sweep.
        let steps = 36
        var colours: [CGColor] = []
        var locations: [CGFloat] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            colours.append(UIColor(hue: t, saturation: 1, brightness: 1, alpha: 1).cgColor)
            locations.append(t)
        }
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colours as CFArray, locations: locations)
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        layer.cornerRadius = 6
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        if let gradient = Self.spectrum {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: bounds.width, y: 0),
                                       options: [])
        }

        let x = hue * bounds.width
        context.setLineWidth(3)
        context.setStrokeColor(UIColor.white.cgColor)
        context.stroke(CGRect(x: x - 2, y: 1, width: 4, height: bounds.height - 2))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { track(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { track(touches) }

    private func track(_ touches: Set<UITouch>) {
        guard let point = touches.first?.location(in: self), bounds.width > 0 else { return }
        // Clamped just short of 1: hue wraps, so exactly 1.0 snaps back to red
        // and the marker jumps to the far end of the strip under the finger.
        hue = min(max(point.x / bounds.width, 0), 0.9999)
        onChange?(hue)
    }
}

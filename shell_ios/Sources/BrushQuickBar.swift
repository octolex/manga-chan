//
//  BrushQuickBar.swift
//
//  Size and Opacity, always on screen, on the edge of the canvas.
//
//  These two are promoted out of the settings panel because they are the two a
//  person changes constantly while drawing and everything else they change
//  occasionally. Procreate makes the same split — those two on the main screen,
//  the rest behind Brush Studio — and it is the right one: a control you reach
//  for every few strokes should never cost a panel open.
//
//  On the **leading** edge by default, and that is a device finding rather than
//  a guess. It was built on the right, as asked for; drawing with it there
//  showed the reason Procreate defaults to the left, which is handedness — a
//  right-handed artist's palm rests along the right edge of the glass, so
//  controls there sit under the hand holding the pen.
//
//  The rule this settles, which is the useful part: **the controls belong on
//  the side of the hand that is not holding the pen.** That makes the default a
//  statement about the majority and the swap a necessity rather than a nicety —
//  a left-handed artist has the mirror-image problem, exactly as badly. The
//  side is CanvasViewController's, since it owns the constraints; see
//  `controlSide` there.
//
//  Both sliders inherit variable-gain scrubbing from PrecisionSlider, which is
//  the point of having built that first: brush size is a value people want
//  exactly, and on a 1:1 slider lifting the finger is what takes it away.
//

import UIKit

protocol BrushQuickBarDelegate: AnyObject {
    func quickBar(_ bar: BrushQuickBar, didChangeSize size: Float)
    func quickBar(_ bar: BrushQuickBar, didChangeOpacity opacity: Float)
}

final class BrushQuickBar: UIView {

    /// Which side of the canvas the controls live on.
    ///
    /// Declared here because this is the control the choice is *about*, but
    /// deliberately not stored here: the bar is symmetric and draws the same
    /// either way, so the side is purely a layout fact and belongs to whoever
    /// owns the constraints. A copy kept in here would be a second source of
    /// truth for something only one place can act on.
    enum Edge {
        case leading
        case trailing
    }

    weak var delegate: BrushQuickBarDelegate?

    private let sizeSlider = PrecisionSlider(axis: .vertical)
    private let opacitySlider = PrecisionSlider(axis: .vertical)
    private let sizeReadout = UILabel()
    private let opacityReadout = UILabel()

    /// Brush size is set in canvas pixels and spans two orders of magnitude, so
    /// the slider is not linear in it — see `sizeFromPosition`.
    private let sizeRange: ClosedRange<Float> = 1...400

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("BrushQuickBar is created in code")
    }

    // MARK: - Values

    var size: Float = 14 {
        didSet {
            sizeSlider.value = positionForSize(size)
            sizeReadout.text = format(size: size)
        }
    }

    var opacity: Float = 1 {
        didSet {
            opacitySlider.value = opacity
            opacityReadout.text = format(opacity: opacity)
        }
    }

    /// Size runs on a square curve rather than linearly.
    ///
    /// The useful range is 1 px to a few hundred, and a linear slider spends
    /// three quarters of its travel between 100 and 400 — sizes nobody picks
    /// carefully — while 1 to 20, where every increment is visible, gets a few
    /// millimetres. Squaring gives the small end most of the track.
    ///
    /// This is the same rule that was written down for Flow: when a control's
    /// useful range bunches at one end, the fix is the curve on the slider, not
    /// a change to what the number means.
    private func sizeFromPosition(_ t: Float) -> Float {
        let span = sizeRange.upperBound - sizeRange.lowerBound
        return sizeRange.lowerBound + span * t * t
    }

    private func positionForSize(_ size: Float) -> Float {
        let span = sizeRange.upperBound - sizeRange.lowerBound
        guard span > 0 else { return 0 }
        let normalised = (min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
                          - sizeRange.lowerBound) / span
        return normalised.squareRoot()
    }

    /// Below 10% the readout carries a decimal, for the same reason the size
    /// readout does: the bottom of this range is where the values are chosen
    /// carefully, and "3%" for anything between 2.5 and 3.5 hides exactly the
    /// distinction the precision scrubbing was built to let a person make.
    private func format(opacity: Float) -> String {
        let percent = opacity * 100
        return percent < 9.95 ? String(format: "%.1f%%", percent)
                              : "\(Int(percent.rounded()))%"
    }

    private func format(size: Float) -> String {
        // Sub-pixel precision matters at the bottom of the range and is noise
        // at the top, so the readout follows the value rather than a constant.
        size < 10 ? String(format: "%.1f", size) : "\(Int(size.rounded()))"
    }

    // MARK: - Build

    private func build() {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 18
        container.alignment = .center
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        container.addArrangedSubview(column(slider: sizeSlider,
                                            readout: sizeReadout,
                                            caption: "SIZE"))
        container.addArrangedSubview(column(slider: opacitySlider,
                                            readout: opacityReadout,
                                            caption: "OPACITY"))

        sizeSlider.value = positionForSize(size)
        sizeSlider.onChange = { [weak self] position, _ in
            guard let self else { return }
            let newSize = sizeFromPosition(position)
            sizeReadout.text = format(size: newSize)
            delegate?.quickBar(self, didChangeSize: newSize)
        }

        // Down to 1%, not 2%. The old floor was set when Opacity was a ceiling
        // on the finished stroke, where anything under a few percent was an
        // invisible stroke and the floor was a kindness. It is a per-dab
        // multiplier now, so 1% is a real working value — the thinnest glaze
        // the brush can lay, built up over passes — and the floor was in the
        // way. It stops above zero because a 0% brush is a brush that draws
        // nothing, which reads as the app being broken.
        opacitySlider.range = 0.01...1
        opacitySlider.value = opacity
        opacitySlider.onChange = { [weak self] newValue, _ in
            guard let self else { return }
            opacityReadout.text = format(opacity: newValue)
            delegate?.quickBar(self, didChangeOpacity: newValue)
        }

        sizeReadout.text = format(size: size)
        opacityReadout.text = format(opacity: opacity)
    }

    private func column(slider: PrecisionSlider,
                        readout: UILabel,
                        caption: String) -> UIView {
        readout.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        readout.textColor = .white
        readout.textAlignment = .center
        readout.layer.cornerRadius = 6
        readout.layer.cornerCurve = .continuous
        readout.clipsToBounds = true
        readout.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        readout.setContentCompressionResistancePriority(.required, for: .vertical)

        let label = UILabel()
        label.text = caption
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = UIColor(white: 1, alpha: 0.55)
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [readout, slider, label])
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .center

        NSLayoutConstraint.activate([
            // A fixed travel, so the two sliders read as a pair and the value
            // per point is the same on both.
            slider.heightAnchor.constraint(equalToConstant: 190),
            slider.widthAnchor.constraint(equalToConstant: 36),
            readout.widthAnchor.constraint(equalToConstant: 44),
            readout.heightAnchor.constraint(equalToConstant: 20),
        ])
        return stack
    }
}

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
//  On the **right** edge, as asked for. Worth recording that Procreate defaults
//  to the left, and the reason is handedness: a right-handed artist's palm
//  rests along the right edge of the glass, so controls there sit under the
//  hand. `edge` exists so that is a preference rather than a rebuild, and the
//  device round is what should settle which default is right for this app.
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

    enum Edge {
        case leading
        case trailing
    }

    weak var delegate: BrushQuickBarDelegate?

    /// Which side of the canvas the bar sits on. A preference, not a rebuild —
    /// see the note at the top about handedness.
    let edge: Edge

    private let sizeSlider = PrecisionSlider(axis: .vertical)
    private let opacitySlider = PrecisionSlider(axis: .vertical)
    private let sizeReadout = UILabel()
    private let opacityReadout = UILabel()

    /// Brush size is set in canvas pixels and spans two orders of magnitude, so
    /// the slider is not linear in it — see `sizeFromPosition`.
    private let sizeRange: ClosedRange<Float> = 1...400

    init(edge: Edge = .trailing) {
        self.edge = edge
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
            opacityReadout.text = "\(Int((opacity * 100).rounded()))%"
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

        opacitySlider.range = 0.02...1
        opacitySlider.value = opacity
        opacitySlider.onChange = { [weak self] newValue, _ in
            guard let self else { return }
            opacityReadout.text = "\(Int((newValue * 100).rounded()))%"
            delegate?.quickBar(self, didChangeOpacity: newValue)
        }

        sizeReadout.text = format(size: size)
        opacityReadout.text = "\(Int((opacity * 100).rounded()))%"
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

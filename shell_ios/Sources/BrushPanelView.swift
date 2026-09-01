//
//  BrushPanelView.swift
//
//  Colour and the brush settings that can be judged by drawing with them.
//
//  This is not the brush editor. It is the subset that unblocks testing: until
//  now nothing on the device could change ink colour, stroke weight or opacity,
//  which made several questions unanswerable by hand — whether a stroke darkens
//  where it crosses itself cannot be seen at all when the ink is opaque black.
//
//  Two rules learned the hard way, both enforced here:
//
//    1. Continuous controls never rebuild the panel. A slider that is rebuilt
//       mid-drag is destroyed under the finger and the gesture ends after one
//       value.
//    2. Nothing here lets a touch through to the canvas. The Pencil will
//       happily draw straight through a panel that does not swallow its own
//       touches.
//

import UIKit

protocol BrushPanelDelegate: AnyObject {
    func brushPanel(_ panel: BrushPanelView, didChange brush: MCBrush)
    func brushPanel(_ panel: BrushPanelView, didChangeColor color: UIColor)
}

final class BrushPanelView: UIView {

    weak var delegate: BrushPanelDelegate?

    private let scrollView = RestorableScrollView()
    private let stack = UIStackView()
    private let picker = ColorPickerView()

    private var brush = mc_brush_ink_pen()

    /// Labels are updated in place while a slider moves, so each one is held
    /// rather than looked up — a rebuild would take the slider with it.
    private var valueLabels: [String: UILabel] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    // Swallow touches rather than letting them fall through to the canvas.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

    private func build() {
        backgroundColor = UIColor(white: 0.13, alpha: 0.95)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        clipsToBounds = true

        stack.axis = .vertical
        stack.spacing = 14
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // A scroll view has no intrinsic content size, so without this the
        // panel collapses to nothing — the same bug the layers panel had.
        let hug = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        hug.priority = .defaultHigh
        hug.isActive = true

        stack.addArrangedSubview(heading("Colour"))
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.onChange = { [weak self] colour in
            guard let self else { return }
            delegate?.brushPanel(self, didChangeColor: colour)
        }
        stack.addArrangedSubview(picker)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Brush"))

        stack.addArrangedSubview(slider(
            "Size", key: "size", value: brush.size, range: 1...120,
            format: { String(format: "%.0f px", $0) },
            apply: { $0.size = $1 }))

        stack.addArrangedSubview(slider(
            "Opacity", key: "opacity", value: brush.opacity, range: 0.02...1,
            format: { "\(Int($0 * 100))%" },
            apply: { $0.opacity = $1 }))

        stack.addArrangedSubview(slider(
            "Flow", key: "flow", value: brush.flow, range: 0.02...1,
            format: { "\(Int($0 * 100))%" },
            apply: { $0.flow = $1 }))

        stack.addArrangedSubview(slider(
            "Hardness", key: "hardness", value: brush.hardness, range: 0...1,
            format: { "\(Int($0 * 100))%" },
            apply: { $0.hardness = $1 }))

        stack.addArrangedSubview(slider(
            "Stabilization", key: "smoothing", value: brush.smoothing, range: 0...0.9,
            format: { "\(Int($0 / 0.9 * 100))%" },
            apply: { $0.smoothing = $1 }))

        stack.addArrangedSubview(slider(
            "Spacing", key: "spacing", value: brush.spacing, range: 0.02...0.5,
            format: { String(format: "%.0f%% of size", $0 * 100) },
            apply: { $0.spacing = $1 }))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Accumulation"))
        stack.addArrangedSubview(accumulationControl())
    }

    /// Called when the panel opens, so it shows what is actually in effect
    /// rather than what it last set.
    func sync(brush: MCBrush, color: UIColor) {
        self.brush = brush
        picker.setColor(color)
    }

    // MARK: - Pieces

    private func heading(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = UIColor(white: 1, alpha: 0.45)
        return label
    }

    private func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor(white: 1, alpha: 0.12)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func slider(_ title: String,
                        key: String,
                        value: Float,
                        range: ClosedRange<Float>,
                        format: @escaping (Float) -> String,
                        apply: @escaping (inout MCBrush, Float) -> Void) -> UIView {
        let name = UILabel()
        name.text = title
        name.font = .systemFont(ofSize: 14)
        name.textColor = .white

        let readout = UILabel()
        readout.text = format(value)
        readout.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        readout.textColor = UIColor(white: 1, alpha: 0.6)
        readout.textAlignment = .right
        valueLabels[key] = readout

        let header = UIStackView(arrangedSubviews: [name, readout])
        header.axis = .horizontal
        header.distribution = .fill
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let control = UISlider()
        control.minimumValue = range.lowerBound
        control.maximumValue = range.upperBound
        control.value = value
        control.minimumTrackTintColor = UIColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1)
        // Explicit height, or the enclosing stack compresses it when space runs
        // short and the rows overlap instead of scrolling.
        control.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let action = UIAction { [weak self] act in
            guard let self, let slider = act.sender as? UISlider else { return }
            apply(&brush, slider.value)
            // Updated in place. Rebuilding here would destroy the slider the
            // finger is still on, ending the drag after a single value.
            valueLabels[key]?.text = format(slider.value)
            delegate?.brushPanel(self, didChange: brush)
        }
        control.addAction(action, for: .valueChanged)

        let row = UIStackView(arrangedSubviews: [header, control])
        row.axis = .vertical
        row.spacing = 2
        return row
    }

    private func accumulationControl() -> UIView {
        let control = UISegmentedControl(items: ["Maximum", "Buildup"])
        control.selectedSegmentIndex = brush.accumulation == MC_ACCUMULATION_BUILDUP.rawValue ? 1 : 0
        control.selectedSegmentTintColor = UIColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1)
        control.heightAnchor.constraint(equalToConstant: 32).isActive = true
        control.addAction(UIAction { [weak self] act in
            guard let self, let segmented = act.sender as? UISegmentedControl else { return }
            brush.accumulation = segmented.selectedSegmentIndex == 1
                ? MC_ACCUMULATION_BUILDUP.rawValue : MC_ACCUMULATION_MAXIMUM.rawValue
            delegate?.brushPanel(self, didChange: brush)
        }, for: .valueChanged)

        let note = UILabel()
        note.numberOfLines = 0
        note.font = .systemFont(ofSize: 11)
        note.textColor = UIColor(white: 1, alpha: 0.45)
        note.text = "Maximum never darkens where a stroke crosses itself. "
                  + "Buildup does — set Flow below 100% to see the difference."

        let row = UIStackView(arrangedSubviews: [control, note])
        row.axis = .vertical
        row.spacing = 8
        return row
    }
}

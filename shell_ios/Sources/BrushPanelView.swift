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

    /// The sliders themselves, and how each formats its value, so a change
    /// made *elsewhere* can be adopted without rebuilding. Size and opacity now
    /// live in two places — here and on the quick bar — and they are one value.
    private var sliders: [String: PrecisionSlider] = [:]
    private var formatters: [String: (Float) -> String] = [:]

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

        // Sections follow Procreate's Brush Studio groupings rather than an
        // order of our own. Not deference — it is the only grouping that has
        // been tested against real use, and docs/procreate-brush-settings.md is
        // organised the same way, so a person can read one against the other.
        //
        // Collapsible because "see everything" and "find anything" pull against
        // each other past about a dozen controls. Everything but Shape starts
        // closed: the panel opens showing what is most often changed, and the
        // rest is one tap away rather than a scroll away.

        stack.addArrangedSubview(section("Shape", expanded: true, rows: [
            slider("Size", key: "size", value: brush.size, range: 1...400,
                   format: { $0 < 10 ? String(format: "%.1f px", $0) : String(format: "%.0f px", $0) },
                   apply: { $0.size = $1 }),
            slider("Hardness", key: "hardness", value: brush.hardness, range: 0...1,
                   format: { "\(Int($0 * 100))%" },
                   apply: { $0.hardness = $1 }),
            slider("Roundness", key: "roundness", value: brush.roundness, range: 0.05...1,
                   format: { $0 > 0.99 ? "round" : "\(Int($0 * 100))%" },
                   apply: { $0.roundness = $1 }),
            slider("Angle", key: "angle", value: brush.angle, range: 0...6.2831853,
                   format: { String(format: "%.0f°", $0 * 180 / .pi) },
                   apply: { $0.angle = $1 }),
            toggle("Angle follows the stroke", isOn: brush.angleFollowsDirection != 0,
                   apply: { $0.angleFollowsDirection = $1 ? 1 : 0 }),
            // Count is only meaningful with scatter or angle jitter — without
            // either the stamps land on top of one another. The rows sit
            // together so that reads as one idea rather than three settings.
            slider("Count", key: "shapeCount", value: Float(brush.shapeCount), range: 1...12,
                   format: { $0 < 1.5 ? "1 stamp" : "\(Int($0.rounded())) stamps" },
                   apply: { $0.shapeCount = Int32($1.rounded()) }),
            slider("Count jitter", key: "shapeCountJitter", value: brush.shapeCountJitter, range: 0...1,
                   format: { $0 < 0.005 ? "off" : "−\(Int($0 * 100))%" },
                   apply: { $0.shapeCountJitter = $1 }),
            slider("Scatter", key: "scatter", value: brush.scatter, range: 0...1.5,
                   format: { $0 < 0.005 ? "off" : String(format: "%.0f%% of size", $0 * 100) },
                   apply: { $0.scatter = $1 }),
            slider("Size jitter", key: "sizeJitter", value: brush.sizeJitter, range: 0...1,
                   format: { $0 < 0.005 ? "off" : "−\(Int($0 * 100))%" },
                   apply: { $0.sizeJitter = $1 }),
            slider("Angle jitter", key: "angleJitter", value: brush.angleJitter, range: 0...3.1415927,
                   format: { $0 < 0.01 ? "off" : String(format: "±%.0f°", $0 * 180 / .pi) },
                   apply: { $0.angleJitter = $1 }),
        ]))

        stack.addArrangedSubview(section("Rendering", rows: [
            slider("Opacity", key: "opacity", value: brush.opacity, range: 0.02...1,
                   format: { "\(Int($0 * 100))%" },
                   apply: { $0.opacity = $1 }),
            // The two are not two opacities, and the readouts say which is
            // which: Opacity is the ceiling a stroke cannot pass however much
            // it overlaps itself, Flow is how fast it gets there.
            slider("Flow", key: "flow", value: brush.flow, range: 0.02...1,
                   format: { $0 > 0.995 ? "100% — one pass is solid" : "\(Int($0 * 100))%" },
                   apply: { $0.flow = $1 }),
            slider("Flow jitter", key: "flowJitter", value: brush.flowJitter, range: 0...1,
                   format: { $0 < 0.005 ? "off" : "−\(Int($0 * 100))%" },
                   apply: { $0.flowJitter = $1 }),
        ]))

        stack.addArrangedSubview(section("Stroke path", rows: [
            slider("Spacing", key: "spacing", value: brush.spacing, range: 0.02...0.5,
                   format: { String(format: "%.0f%% of size", $0 * 100) },
                   apply: { $0.spacing = $1 }),
            slider("Stabilization", key: "smoothing", value: brush.smoothing, range: 0...0.9,
                   format: { $0 < 0.005 ? "off" : "\(Int($0 / 0.9 * 100))%" },
                   apply: { $0.smoothing = $1 }),
            slider("Minimum size", key: "minimumSizeFraction",
                   value: brush.minimumSizeFraction, range: 0...0.5,
                   format: { "\(Int($0 * 100))% of size" },
                   apply: { $0.minimumSizeFraction = $1 }),
        ]))

        // Two tapers, because a finger reports no real pressure and a
        // pressure-driven brush makes nothing recognisable from one. Each end
        // is independent, which is what Procreate presents as a Vector2D.
        stack.addArrangedSubview(section("Taper — Pencil", rows: taperRows(
            keyPrefix: "taperPressure",
            start: brush.taper.pressure.start, end: brush.taper.pressure.end,
            applyStartLength: { $0.taper.pressure.start.length = $1 },
            applyStartScale: { $0.taper.pressure.start.scale = $1 },
            applyEndLength: { $0.taper.pressure.end.length = $1 },
            applyEndScale: { $0.taper.pressure.end.scale = $1 })))

        stack.addArrangedSubview(section("Taper — finger", rows: taperRows(
            keyPrefix: "taperTouch",
            start: brush.taper.touch.start, end: brush.taper.touch.end,
            applyStartLength: { $0.taper.touch.start.length = $1 },
            applyStartScale: { $0.taper.touch.start.scale = $1 },
            applyEndLength: { $0.taper.touch.end.length = $1 },
            applyEndScale: { $0.taper.touch.end.scale = $1 })))

        stack.addArrangedSubview(section("Grain", rows: [
            slider("Depth", key: "grainDepth", value: brush.grainDepth, range: 0...1,
                   format: { $0 < 0.005 ? "off" : "\(Int($0 * 100))%" },
                   apply: { $0.grainDepth = $1 }),
            // In canvas pixels, and over a wide range, because the two ends are
            // different media rather than two settings of one: fine is a tooth
            // the ink catches on, coarse is a texture the stroke sits inside.
            slider("Scale", key: "grainScale", value: brush.grainScale, range: 24...600,
                   format: { String(format: "%.0f px", $0) },
                   apply: { $0.grainScale = $1 }),
            grainMovementControl(),
        ]))

        // Dynamics are shown as range only. The *curve* is a graph in Procreate
        // and is now a graph in the model too, but nothing draws one yet — see
        // "Deferred" in ROADMAP.md. Showing minimum and maximum without the
        // curve is honest; inventing a slider that pretends to be a curve
        // would not be.
        stack.addArrangedSubview(section("Pencil pressure", rows: [
            toggle("Pressure changes size", isOn: brush.sizeDynamics.byPressure.enabled != 0,
                   apply: { $0.sizeDynamics.byPressure.enabled = $1 ? 1 : 0 }),
            slider("Size at no pressure", key: "sizePressureMin",
                   value: brush.sizeDynamics.byPressure.minimum, range: 0...1,
                   format: { "\(Int($0 * 100))%" },
                   apply: { $0.sizeDynamics.byPressure.minimum = $1 }),
            toggle("Pressure changes flow", isOn: brush.flowDynamics.byPressure.enabled != 0,
                   apply: { $0.flowDynamics.byPressure.enabled = $1 ? 1 : 0 }),
            slider("Flow at no pressure", key: "flowPressureMin",
                   value: brush.flowDynamics.byPressure.minimum, range: 0...1,
                   format: { "\(Int($0 * 100))%" },
                   apply: { $0.flowDynamics.byPressure.minimum = $1 }),
        ]))

        stack.addArrangedSubview(section("Speed", rows: [
            toggle("Speed changes size", isOn: brush.sizeDynamics.byVelocity.enabled != 0,
                   apply: { $0.sizeDynamics.byVelocity.enabled = $1 ? 1 : 0 }),
            slider("Size at full speed", key: "sizeVelocityMax",
                   value: brush.sizeDynamics.byVelocity.maximum, range: 0...2,
                   format: { "\(Int($0 * 100))%" },
                   apply: { $0.sizeDynamics.byVelocity.maximum = $1 }),
            slider("Speed reference", key: "velocityReference",
                   value: brush.velocityReference, range: 200...6000,
                   format: { String(format: "%.0f px/s", $0) },
                   apply: { $0.velocityReference = $1 }),
        ]))
    }

    /// The four rows one taper needs. Built once and used for both, so the
    /// Pencil and finger sections cannot drift apart in wording or range.
    private func taperRows(keyPrefix: String,
                           start: MCTaperEnd,
                           end: MCTaperEnd,
                           applyStartLength: @escaping (inout MCBrush, Float) -> Void,
                           applyStartScale: @escaping (inout MCBrush, Float) -> Void,
                           applyEndLength: @escaping (inout MCBrush, Float) -> Void,
                           applyEndScale: @escaping (inout MCBrush, Float) -> Void) -> [UIView] {
        let length: (Float) -> String = { $0 < 0.5 ? "off" : String(format: "%.0f px", $0) }
        let scale: (Float) -> String = { $0 < 0.005 ? "to a point" : "\(Int($0 * 100))%" }
        return [
            slider("Start length", key: "\(keyPrefix)StartLength", value: start.length,
                   range: 0...300, format: length, apply: applyStartLength),
            slider("Start width", key: "\(keyPrefix)StartScale", value: start.scale,
                   range: 0...1, format: scale, apply: applyStartScale),
            slider("End length", key: "\(keyPrefix)EndLength", value: end.length,
                   range: 0...300, format: length, apply: applyEndLength),
            slider("End width", key: "\(keyPrefix)EndScale", value: end.scale,
                   range: 0...1, format: scale, apply: applyEndScale),
        ]
    }

    /// Called when the panel opens, so it shows what is actually in effect
    /// rather than what it last set.
    ///
    /// Only the controls something *else* can change need refreshing, and today
    /// that is exactly the two the quick bar owns. Every other setting on this
    /// panel is only ever changed from this panel, so its control is already
    /// showing the truth.
    ///
    /// Stated rather than assumed, because it stops being true the moment a
    /// third thing edits a brush — a preset being loaded, say. When that
    /// arrives, `slider(...)` needs to take a reader closure instead of a
    /// starting value, and this becomes a loop over every key.
    func sync(brush: MCBrush, color: UIColor) {
        self.brush = brush
        picker.setColor(color)
        refreshFromBrush(brush)
    }

    // MARK: - Pieces

    /// A titled group that can be folded away.
    ///
    /// Its own small view rather than a closure and a gesture recogniser
    /// wired from here: the open/closed state belongs to the section, and a
    /// panel-level dictionary of them would be one more thing to keep in step
    /// with a rebuild.
    private func section(_ title: String,
                         expanded: Bool = false,
                         rows: [UIView]) -> UIView {
        CollapsibleSection(title: title.uppercased(), expanded: expanded, rows: rows)
    }

    /// A labelled switch, for the settings that are genuinely on or off.
    private func toggle(_ title: String,
                        isOn: Bool,
                        apply: @escaping (inout MCBrush, Bool) -> Void) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 14)
        label.textColor = .white
        label.numberOfLines = 0

        let control = UISwitch()
        control.isOn = isOn
        control.onTintColor = UIColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.addAction(UIAction { [weak self] act in
            guard let self, let sw = act.sender as? UISwitch else { return }
            apply(&brush, sw.isOn)
            delegate?.brushPanel(self, didChange: brush)
        }, for: .valueChanged)

        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return row
    }

    private func heading(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = UIColor(white: 1, alpha: 0.45)
        return label
    }


    /// Adopt a brush that was changed somewhere else.
    ///
    /// Updates in place rather than rebuilding, for the same reason the labels
    /// are: rebuilding would replace the very controls a finger might be on,
    /// and it would throw away the panel's scroll position on every drag of the
    /// quick bar.
    ///
    /// Deliberately silent — it does not call the delegate. The quick bar is
    /// what changed the brush; telling it back would be a loop.
    func refreshFromBrush(_ brush: MCBrush) {
        self.brush = brush
        applyToControl(key: "size", value: brush.size)
        applyToControl(key: "opacity", value: brush.opacity)
    }

    /// Named for what it does to avoid colliding with the `apply` closures the
    /// slider factory takes, which write to a brush rather than to a control.
    private func applyToControl(key: String, value: Float) {
        sliders[key]?.value = value
        if let format = formatters[key] {
            valueLabels[key]?.text = format(value)
        }
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

        // PrecisionSlider rather than UISlider, so every control in the app
        // slows down as the finger moves away from its track. See
        // SliderScrubbing for why that matters: on a 1:1 slider the last thing
        // that happens before you get the value you asked for is that lifting
        // your finger takes it away again.
        let control = PrecisionSlider(axis: .horizontal)
        control.range = range
        control.value = value
        control.fillColor = UIColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1)
        // Explicit height, or the enclosing stack compresses it when space runs
        // short and the rows overlap instead of scrolling.
        control.heightAnchor.constraint(equalToConstant: 36).isActive = true

        sliders[key] = control
        formatters[key] = format

        control.onChange = { [weak self] newValue, _ in
            guard let self else { return }
            apply(&brush, newValue)
            // Updated in place. Rebuilding here would destroy the slider the
            // finger is still on, ending the drag after a single value.
            valueLabels[key]?.text = format(newValue)
            delegate?.brushPanel(self, didChange: brush)
        }

        let row = UIStackView(arrangedSubviews: [header, control])
        row.axis = .vertical
        row.spacing = 2
        return row
    }

    private func grainMovementControl() -> UIView {
        let control = UISegmentedControl(items: ["Canvas", "Rolling"])
        control.selectedSegmentIndex = brush.grainMovement == Int32(MC_GRAIN_ROLLING.rawValue) ? 1 : 0
        control.selectedSegmentTintColor = UIColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1)
        control.heightAnchor.constraint(equalToConstant: 32).isActive = true
        control.addAction(UIAction { [weak self] act in
            guard let self, let segmented = act.sender as? UISegmentedControl else { return }
            brush.grainMovement = segmented.selectedSegmentIndex == 1
                ? Int32(MC_GRAIN_ROLLING.rawValue) : Int32(MC_GRAIN_CANVAS.rawValue)
            delegate?.brushPanel(self, didChange: brush)
        }, for: .valueChanged)

        let note = UILabel()
        note.numberOfLines = 0
        note.font = .systemFont(ofSize: 11)
        note.textColor = UIColor(white: 1, alpha: 0.45)
        // Says what to *do* to tell them apart, because the difference is
        // invisible on a single straight stroke and obvious the moment one
        // crosses itself.
        note.text = "Canvas pins the grain to the paper, so a stroke crossing "
                  + "its own path finds the same texture there. Rolling carries "
                  + "it along the stroke, so crossings show."

        let row = UIStackView(arrangedSubviews: [control, note])
        row.axis = .vertical
        row.spacing = 8
        return row
    }
}

/// A heading that folds its contents away.
///
/// Lives here rather than in its own file because nothing else needs it yet,
/// and a type used once is easier to read next to its only caller.
private final class CollapsibleSection: UIStackView {

    private let chevron = UILabel()
    private let body = UIStackView()

    init(title: String, expanded: Bool, rows: [UIView]) {
        super.init(frame: .zero)

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = UIColor(white: 1, alpha: 0.45)

        chevron.font = .systemFont(ofSize: 11, weight: .semibold)
        chevron.textColor = UIColor(white: 1, alpha: 0.45)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [label, chevron])
        header.axis = .horizontal
        header.alignment = .center
        header.isLayoutMarginsRelativeArrangement = true
        // A header is a target for a finger, not a caption, so it gets real
        // height rather than the height of its text.
        header.layoutMargins = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        header.isUserInteractionEnabled = true
        header.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                           action: #selector(toggleSection)))

        body.axis = .vertical
        body.spacing = 12

        for row in rows {
            body.addArrangedSubview(row)
        }

        axis = .vertical
        spacing = 0
        addArrangedSubview(header)
        addArrangedSubview(body)

        setExpanded(expanded)
    }

    required init(coder: NSCoder) {
        fatalError("CollapsibleSection is created in code")
    }

    private func setExpanded(_ open: Bool) {
        // `isHidden` on an arranged subview, not a height constraint: the stack
        // view removes it from layout entirely, so a closed section costs
        // nothing and the scroll content shrinks to match.
        body.isHidden = !open
        chevron.text = open ? "▾" : "▸"
    }

    @objc private func toggleSection() {
        setExpanded(body.isHidden)
    }
}

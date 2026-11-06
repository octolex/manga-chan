//
//  PressureSmoothing.swift
//
//  Procreate's Preferences → Pressure and Smoothing: the settings that belong
//  to the person rather than to a brush. Their pressure curve — how hard they
//  press is a property of their hand, not of a pen — and app-wide floors for
//  the stabilisers, which matter most to someone whose hand trembles.
//
//  The arithmetic is in the engine (core/input_filter.h), where it is tested.
//  This file holds the values, persists them, and draws the panel.
//

import UIKit

/// The person's settings. Persisted, because being asked every launch would
/// be worse than being wrong once.
struct PressureSmoothingSettings: Codable, Equatable {

    /// Two draggable points on the pressure curve, in 0...1. Two rather than
    /// Procreate's add-as-many-as-you-like: two already make an S-curve, the
    /// shape people actually reach for, and a fixed pair cannot be dragged
    /// into an order that folds the curve back on itself.
    var curve: [CGPoint] = PressureSmoothingSettings.linearCurve

    var pressureSmoothing: Float = 0
    var stabilization: Float = 0
    var motionFiltering: Float = 0
    var motionFilteringExpression: Float = 0

    static let linearCurve = [CGPoint(x: 1.0 / 3.0, y: 1.0 / 3.0),
                              CGPoint(x: 2.0 / 3.0, y: 2.0 / 3.0)]

    private static let defaultsKey = "pressureAndSmoothing"

    static func load() -> PressureSmoothingSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(Self.self, from: data),
              settings.curve.count == 2 else {
            return PressureSmoothingSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// True when both points sit on the diagonal. Sent to the engine as an
    /// empty curve then, so a person who never touched it gets the identity
    /// path — bit for bit what the Pencil reported.
    var curveIsLinear: Bool {
        curve.allSatisfy { abs($0.x - $0.y) < 0.005 }
    }

    var engineCurve: MCResponseCurve {
        var result = MCResponseCurve()
        guard !curveIsLinear else { return result }
        let points = curve.sorted { $0.x < $1.x }
        result.count = Int32(points.count)
        withUnsafeMutableBytes(of: &result.x) { raw in
            let xs = raw.bindMemory(to: Float.self)
            for (i, p) in points.enumerated() where i < xs.count { xs[i] = Float(p.x) }
        }
        withUnsafeMutableBytes(of: &result.y) { raw in
            let ys = raw.bindMemory(to: Float.self)
            for (i, p) in points.enumerated() where i < ys.count { ys[i] = Float(p.y) }
        }
        return result
    }

    var engineSettings: MCInputSettings {
        var settings = mc_input_settings_default()
        settings.pressureCurve = engineCurve
        settings.pressureSmoothing = pressureSmoothing
        settings.stabilization = stabilization
        settings.motionFiltering = motionFiltering
        settings.motionFilteringExpression = motionFilteringExpression
        return settings
    }
}

// MARK: - Curve editor

/// The pressure curve as a graph with two handles, drawn with the engine's own
/// evaluation so what is on screen is exactly what a stroke will get.
///
/// Raw touches and `ScrollDragImmune` rather than a pan recogniser, exactly as
/// the colour picker's square: the panel scrolls, and a drag on the curve must
/// edit the curve rather than scroll the panel out from under it (bug 8's
/// shape).
final class PressureCurveView: UIView, ScrollDragImmune {

    var points: [CGPoint] = PressureSmoothingSettings.linearCurve {
        didSet { setNeedsDisplay(); positionHandles() }
    }

    /// Fires on every drag step, and once more with `isFinal` on release.
    var onChange: (([CGPoint], _ isFinal: Bool) -> Void)?

    private var dragging: Int?
    private let handles = [UIView(), UIView()]
    private let inset: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.08, alpha: 1)
        layer.cornerRadius = 8
        contentMode = .redraw
        for handle in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
            handle.layer.cornerRadius = 11
            handle.backgroundColor = .white
            handle.layer.borderColor = UIColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1).cgColor
            handle.layer.borderWidth = 3
            handle.isUserInteractionEnabled = false
            addSubview(handle)
        }
        isAccessibilityElement = true
        accessibilityLabel = "Pressure curve"
    }

    required init?(coder: NSCoder) {
        fatalError("PressureCurveView is created in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionHandles()
    }

    private var plot: CGRect { bounds.insetBy(dx: inset, dy: inset) }

    private func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: plot.minX + p.x * plot.width, y: plot.maxY - p.y * plot.height)
    }

    private func curvePoint(_ v: CGPoint) -> CGPoint {
        CGPoint(x: min(max((v.x - plot.minX) / plot.width, 0), 1),
                y: min(max((plot.maxY - v.y) / plot.height, 0), 1))
    }

    private func positionHandles() {
        for (handle, point) in zip(handles, points) {
            handle.center = viewPoint(point)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(UIColor(white: 1, alpha: 0.12).cgColor)
        context.setLineWidth(1)
        for i in 1..<4 {
            let f = CGFloat(i) / 4
            context.move(to: CGPoint(x: plot.minX + f * plot.width, y: plot.minY))
            context.addLine(to: CGPoint(x: plot.minX + f * plot.width, y: plot.maxY))
            context.move(to: CGPoint(x: plot.minX, y: plot.minY + f * plot.height))
            context.addLine(to: CGPoint(x: plot.maxX, y: plot.minY + f * plot.height))
        }
        context.strokePath()

        // The linear reference, so a bend reads as a bend.
        context.setStrokeColor(UIColor(white: 1, alpha: 0.25).cgColor)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.move(to: viewPoint(.zero))
        context.addLine(to: viewPoint(CGPoint(x: 1, y: 1)))
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])

        var settings = PressureSmoothingSettings()
        settings.curve = points
        var curve = settings.engineCurve
        context.setStrokeColor(UIColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1).cgColor)
        context.setLineWidth(3)
        for i in 0...64 {
            let t = Float(i) / 64
            let y = settings.curveIsLinear ? t : mc_response_curve_evaluate(&curve, t)
            let p = viewPoint(CGPoint(x: CGFloat(t), y: CGFloat(y)))
            if i == 0 { context.move(to: p) } else { context.addLine(to: p) }
        }
        context.strokePath()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let location = touches.first?.location(in: self) else { return }
        let distances = points.map { point -> CGFloat in
            let v = viewPoint(point)
            let dx = v.x - location.x, dy = v.y - location.y
            return (dx * dx + dy * dy).squareRoot()
        }
        if let nearest = distances.indices.min(by: { distances[$0] < distances[$1] }),
           distances[nearest] < 44 {
            dragging = nearest
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let index = dragging, let location = touches.first?.location(in: self) else { return }
        var p = curvePoint(location)
        // Each handle stays on its own side of the other, so the curve can
        // never fold back.
        let gap: CGFloat = 0.03
        if index == 0 { p.x = min(p.x, points[1].x - gap) }
        if index == 1 { p.x = max(p.x, points[0].x + gap) }
        p.x = min(max(p.x, gap), 1 - gap)
        points[index] = p
        onChange?(points, false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if dragging != nil { onChange?(points, true) }
        dragging = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

// MARK: - Panel

final class PressureSmoothingPanel: UIView {

    var onChange: ((PressureSmoothingSettings) -> Void)?

    private(set) var settings = PressureSmoothingSettings()
    private let scrollView = RestorableScrollView()
    private let curveView = PressureCurveView()
    private var sliders: [WritableKeyPath<PressureSmoothingSettings, Float>: (PrecisionSlider, UILabel)] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("PressureSmoothingPanel is created in code")
    }

    // Swallow touches that land on the panel's background, so they never fall
    // through to the canvas responder — the same rule as the brush panel.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

    func sync(_ settings: PressureSmoothingSettings) {
        self.settings = settings
        curveView.points = settings.curve
        for (key, pair) in sliders {
            pair.0.value = settings[keyPath: key]
            pair.1.text = Self.percent(settings[keyPath: key])
        }
    }

    private static func percent(_ v: Float) -> String {
        v < 0.005 ? "None" : "\(Int((v * 100).rounded()))%"
    }

    private func build() {
        backgroundColor = UIColor(white: 0.13, alpha: 0.95)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous

        clipsToBounds = true

        // Scrolls when the screen is too short for it — an 11-inch iPad in
        // landscape — and hugs its content otherwise, as the brush panel does.
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
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
        let hug = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        hug.priority = .defaultHigh
        hug.isActive = true

        stack.addArrangedSubview(heading("Pressure and Smoothing"))

        let curveHeader = UIStackView()
        curveHeader.axis = .horizontal
        let curveLabel = UILabel()
        curveLabel.text = "Pressure curve"
        curveLabel.font = .systemFont(ofSize: 14)
        curveLabel.textColor = .white
        let reset = UIButton(type: .system)
        reset.setTitle("Reset", for: .normal)
        reset.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            settings.curve = PressureSmoothingSettings.linearCurve
            curveView.points = settings.curve
            onChange?(settings)
        }, for: .touchUpInside)
        curveHeader.addArrangedSubview(curveLabel)
        curveHeader.addArrangedSubview(reset)
        stack.addArrangedSubview(curveHeader)

        curveView.heightAnchor.constraint(equalTo: curveView.widthAnchor).isActive = true
        curveView.onChange = { [weak self] points, _ in
            guard let self else { return }
            settings.curve = points
            onChange?(settings)
        }
        stack.addArrangedSubview(curveView)

        let note = UILabel()
        note.numberOfLines = 0
        note.font = .systemFont(ofSize: 11)
        note.textColor = UIColor(white: 1, alpha: 0.45)
        note.text = "Pencil only. Below the diagonal, a light touch draws lighter; "
                  + "above it, heavier. Applies to every brush."
        stack.addArrangedSubview(note)

        stack.addArrangedSubview(slider("Pressure smoothing", \.pressureSmoothing))
        stack.addArrangedSubview(slider("Stabilization", \.stabilization))
        stack.addArrangedSubview(slider("Motion filtering", \.motionFiltering))
        stack.addArrangedSubview(slider("Motion filtering expression", \.motionFilteringExpression))

        let floorNote = UILabel()
        floorNote.numberOfLines = 0
        floorNote.font = .systemFont(ofSize: 11)
        floorNote.textColor = UIColor(white: 1, alpha: 0.45)
        floorNote.text = "A floor under every brush: a brush with more of its own keeps it."
        stack.addArrangedSubview(floorNote)
    }

    private func heading(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = UIColor(white: 1, alpha: 0.45)
        return label
    }

    private func slider(_ title: String,
                        _ key: WritableKeyPath<PressureSmoothingSettings, Float>) -> UIView {
        let name = UILabel()
        name.text = title
        name.font = .systemFont(ofSize: 14)
        name.textColor = .white
        let readout = UILabel()
        readout.text = Self.percent(settings[keyPath: key])
        readout.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        readout.textColor = UIColor(white: 1, alpha: 0.6)
        readout.textAlignment = .right
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [name, readout])
        header.axis = .horizontal

        let control = PrecisionSlider(axis: .horizontal)
        control.range = 0...1
        control.value = settings[keyPath: key]
        control.fillColor = UIColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1)
        control.heightAnchor.constraint(equalToConstant: 36).isActive = true
        control.onChange = { [weak self] value, _ in
            guard let self else { return }
            settings[keyPath: key] = value
            readout.text = Self.percent(value)
            onChange?(settings)
        }
        sliders[key] = (control, readout)

        let row = UIStackView(arrangedSubviews: [header, control])
        row.axis = .vertical
        row.spacing = 2
        return row
    }
}

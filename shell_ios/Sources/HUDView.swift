//
//  HUDView.swift
//
//  The instrumentation overlay. With no Instruments and no Metal frame
//  debugger available, this HUD is the primary performance measurement tool
//  for the whole project, so it ships in M0 rather than being retrofitted.
//
//  Tap it to cycle between compact and detailed.
//

import UIKit

final class HUDView: UIView {

    private enum Mode: Int, CaseIterable {
        case compact
        case detailed
        case hidden
    }

    private let label = UILabel()
    private var mode: Mode = .detailed
    private var latest = FrameStats()
    private var input = InputStats()
    private var staticInfo: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = true

        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cycleMode)))

        staticInfo = [
            String(cString: core_build_info()),
            "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
        ]
        render()
    }

    @objc private func cycleMode() {
        let all = Mode.allCases
        mode = all[(all.firstIndex(of: mode)! + 1) % all.count]
        render()
    }

    func update(with stats: FrameStats) {
        latest = stats
        render()
    }

    func update(input stats: InputStats) {
        input = stats
        render()
    }

    func addStaticLine(_ line: String) {
        staticInfo.append(line)
        render()
    }

    private func render() {
        switch mode {
        case .hidden:
            label.text = "·"
            alpha = 0.25

        case .compact:
            alpha = 1.0
            label.text = String(format: "%.0f fps   gpu %.2f ms", latest.fps, latest.gpuFrameMs)

        case .detailed:
            alpha = 1.0
            // Frame budget comes from the panel, not a constant — 16.6 ms on a
            // 60Hz iPad Air, 8.3 ms on a 120Hz iPad Pro.
            let budgetMs = latest.displayMaxFPS > 0 ? 1000.0 / Double(latest.displayMaxFPS) : 0
            var lines: [String] = []
            lines.append(String(format: "fps      %6.1f / %d", latest.fps, latest.displayMaxFPS))
            lines.append(String(format: "budget   %6.2f ms", budgetMs))
            lines.append(String(format: "cpu      %6.2f ms", latest.cpuFrameMs))
            lines.append(String(format: "gpu      %6.2f ms", latest.gpuFrameMs))
            lines.append(String(format: "frame    %6llu", latest.frameIndex))
            // Pencil samples arriving per frame. At 60Hz with 240Hz Pencil
            // sampling this should sit near 4 while drawing; a persistent 1
            // means coalesced touches are not being consumed.
            lines.append(String(format: "samples  %6d", latest.samplesThisFrame))
            lines.append(String(format: "verts    %6d", latest.strokeVerticesThisFrame))
            lines.append(String(format: "peak/fr  %6d", input.peakSamplesPerFrame))
            lines.append(String(format: "drawable %.0f×%.0f",
                                latest.drawableSize.width, latest.drawableSize.height))

            lines.append("")
            lines.append("input    \(input.touchType)")
            lines.append(String(format: "pressure %6.3f", input.pressure))
            lines.append(String(format: "tilt     %6.1f°", input.altitudeDegrees))
            lines.append(String(format: "azimuth  %6.1f°", input.azimuthDegrees))
            // A dash rather than a number distinguishes "this Pencil has no
            // barrel roll" from "barrel roll is reading exactly zero".
            lines.append("roll     " + (input.rollDegrees < 0
                                        ? "     —" : String(format: "%6.1f°", input.rollDegrees)))
            lines.append("hover    " + (input.hoverOffset < 0
                                        ? "     —" : String(format: "%6.1f", input.hoverOffset)))
            lines.append(String(format: "squeeze  %6d", input.squeezeCount))
            lines.append(String(format: "dbl-tap  %6d", input.doubleTapCount))

            lines.append("")
            lines.append(contentsOf: staticInfo)
            label.text = lines.joined(separator: "\n")
        }
        invalidateIntrinsicContentSize()
    }
}

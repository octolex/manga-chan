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
            var lines: [String] = []
            lines.append(String(format: "fps      %6.1f", latest.fps))
            lines.append(String(format: "cpu      %6.2f ms", latest.cpuFrameMs))
            lines.append(String(format: "gpu      %6.2f ms", latest.gpuFrameMs))
            lines.append(String(format: "frame    %6llu", latest.frameIndex))
            lines.append(String(format: "drawable %.0f×%.0f",
                                latest.drawableSize.width, latest.drawableSize.height))
            lines.append("")
            lines.append(contentsOf: staticInfo)
            label.text = lines.joined(separator: "\n")
        }
        invalidateIntrinsicContentSize()
    }
}

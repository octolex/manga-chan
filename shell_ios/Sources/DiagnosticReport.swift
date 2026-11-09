//
//  DiagnosticReport.swift
//
//  A short, curated report the tester copies with one button and pastes to
//  Claude (asked for by octolex, 2026-11-09).
//
//  Curated on purpose. A raw log of every Pencil sample is thousands of lines a
//  reader skims; what decides a bug is a few numbers per stroke and the shape
//  of the frame times. So this keeps one line per stroke for the last twenty
//  strokes, a rolling window of frame times, and the tail of the session log,
//  and nothing else: about 5–10 KB, a few screens. It never contains the
//  drawing itself.
//
//  Plain Swift with no UIKit, so its arithmetic is tested in CI. The view
//  controller supplies the device facts and the pasteboard.
//

import Foundation

/// One stroke, summarised to the numbers that have decided bugs so far: the
/// start pressures (bug 27), the pressure range, the QuickShape fit.
struct StrokeRecord {
    var device: String = "pencil"
    var samples: Int = 0
    var dabs: Int = 0
    var durationMs: Double = 0
    var lengthPx: Float = 0
    var pressureMin: Float = 1
    var pressureMax: Float = 0
    var startPressures: [Float] = []
    var shape: String?

    var line: String {
        var text = String(format: "%@ %4ld smp %6ld dabs %6.0f ms %7.0f px  p %.2f–%.2f  start %@",
                          device, samples, dabs, durationMs, Double(lengthPx),
                          Double(pressureMin), Double(pressureMax),
                          startPressures.map { String(format: "%.2f", $0) }.joined(separator: " "))
        if let shape { text += "  shape " + shape }
        return text
    }
}

/// A fixed window of recent values with the three numbers worth reading.
struct RollingTimes {
    let capacity: Int
    private(set) var values: [Double] = []
    private var next = 0

    init(capacity: Int) { self.capacity = capacity }

    mutating func add(_ value: Double) {
        if values.count < capacity {
            values.append(value)
        } else {
            values[next] = value
        }
        next = (next + 1) % capacity
    }

    /// Mean, 95th percentile and maximum. The 95th rather than the mean is
    /// the one that says whether frames are being dropped.
    var summary: (mean: Double, p95: Double, max: Double) {
        guard !values.isEmpty else { return (0, 0, 0) }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.down)))
        return (values.reduce(0, +) / Double(values.count), sorted[index], sorted.last ?? 0)
    }
}

final class DiagnosticReport {

    static let shared = DiagnosticReport()

    static let strokeCapacity = 20
    /// About ten seconds at 60 Hz.
    static let frameCapacity = 600

    private(set) var strokes: [StrokeRecord] = []
    private(set) var cpu = RollingTimes(capacity: frameCapacity)
    private(set) var gpu = RollingTimes(capacity: frameCapacity)

    func record(stroke: StrokeRecord) {
        strokes.append(stroke)
        if strokes.count > Self.strokeCapacity {
            strokes.removeFirst(strokes.count - Self.strokeCapacity)
        }
    }

    func recordCPU(_ ms: Double) { cpu.add(ms) }
    func recordGPU(_ ms: Double) { gpu.add(ms) }

    /// The report. Each argument is a block of `key value` lines the caller
    /// already has to hand; this assembles them in a fixed order so two
    /// reports can be compared line by line.
    func text(header: [String], brush: [String], input: [String],
              engine: [String], logTail: [String]) -> String {
        var out: [String] = ["Manga-Chan diagnostic report"]
        out += header
        out.append("")
        out.append("== brush")
        out += brush
        out.append("")
        out.append("== pressure and smoothing")
        out += input
        out.append("")
        let c = cpu.summary, g = gpu.summary
        out.append("== frames (last \(cpu.values.count))")
        out.append(String(format: "cpu ms  mean %.2f  p95 %.2f  max %.2f", c.mean, c.p95, c.max))
        out.append(String(format: "gpu ms  mean %.2f  p95 %.2f  max %.2f", g.mean, g.p95, g.max))
        out += engine
        out.append("")
        out.append("== last \(strokes.count) strokes, oldest first")
        out += strokes.map(\.line)
        out.append("")
        out.append("== log tail")
        out += logTail
        return out.joined(separator: "\n")
    }

    /// The brush as `name value` lines: every setting a device finding has
    /// depended on, not every field.
    static func describe(_ b: MCBrush) -> [String] {
        func f(_ v: Float) -> String { String(format: "%.3f", v) }
        let style = b.renderingStyle == Int32(MC_RENDER_GLAZE.rawValue) ? "glaze" : "blending"
        let grain = b.grainMovement == Int32(MC_GRAIN_ROLLING.rawValue) ? "rolling" : "canvas"
        let p = b.sizeDynamics.byPressure
        return [
            "size \(f(b.size))  spacing \(f(b.spacing))  hardness \(f(b.hardness))  roundness \(f(b.roundness))",
            "flow \(f(b.flow))  opacity \(f(b.opacity))  rendering \(style)",
            "size by pressure \(p.enabled != 0 ? "on" : "off") min \(f(p.minimum)) max \(f(p.maximum)) curve points \(p.curve.count)",
            "minimum size \(f(b.minimumSizeFraction))",
            "streamline \(f(b.smoothing))  stabilization \(f(b.stabilization))  motion filtering \(f(b.motionFiltering)) expression \(f(b.motionFilteringExpression))",
            "taper pencil start \(f(b.taper.pressure.start.length))/\(f(b.taper.pressure.start.scale)) end \(f(b.taper.pressure.end.length))/\(f(b.taper.pressure.end.scale))",
            "grain depth \(f(b.grainDepth)) scale \(f(b.grainScale)) brightness \(f(b.grainBrightness)) contrast \(f(b.grainContrast)) \(grain)",
            "count \(b.shapeCount) scatter \(f(b.scatter)) size jitter \(f(b.sizeJitter)) angle jitter \(f(b.angleJitter)) flow jitter \(f(b.flowJitter))",
        ]
    }
}

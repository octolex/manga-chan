//
//  DiagnosticReportTests.swift
//
//  The diagnostic report is meant to be short enough to read: bounded no
//  matter how long the session ran, with its sections in a fixed order so two
//  reports compare line by line.
//

import XCTest

final class DiagnosticReportTests: XCTestCase {

    func testRollingTimesSummarise() {
        var times = RollingTimes(capacity: 100)
        for i in 1...100 { times.add(Double(i)) }
        let s = times.summary
        XCTAssertEqual(s.mean, 50.5, accuracy: 1e-9)
        XCTAssertEqual(s.p95, 96, accuracy: 1e-9)
        XCTAssertEqual(s.max, 100, accuracy: 1e-9)
    }

    func testRollingTimesForgetTheOldest() {
        var times = RollingTimes(capacity: 10)
        for _ in 0..<10 { times.add(100) }   // an old slow patch
        for _ in 0..<10 { times.add(1) }     // then all fast
        XCTAssertEqual(times.values.count, 10)
        XCTAssertEqual(times.summary.max, 1, accuracy: 1e-9)
    }

    func testTheReportStaysShortHoweverLongTheSession() {
        let report = DiagnosticReport()
        var stroke = StrokeRecord()
        stroke.samples = 400
        stroke.dabs = 12_000
        stroke.startPressures = [0.9, 0.6, 0.25, 0.03, 0.03, 0.03, 0.03, 0.03]
        stroke.shape = "none · line 3.10 arc 2.00 ellipse — polygon 1.40"
        for _ in 0..<500 { report.record(stroke: stroke) }
        for _ in 0..<5000 { report.recordCPU(1.0); report.recordGPU(2.0) }
        XCTAssertEqual(report.strokes.count, DiagnosticReport.strokeCapacity)

        let longLine = String(repeating: "x", count: 200)
        let text = report.text(header: ["build 0.3.105 (105)"],
                               brush: DiagnosticReport.describe(mc_brush_ink_pen()),
                               input: ["pressure curve linear"],
                               engine: ["fps 60.0"],
                               logTail: Array(repeating: longLine, count: 40))
        print("diagnostic report: \(text.utf8.count) bytes for 500 strokes and 5000 frames")
        XCTAssertLessThan(text.utf8.count, 16_384)

        // Sections in a fixed order.
        let order = ["== brush", "== pressure and smoothing", "== frames", "== last 20 strokes",
                     "== log tail"]
        var cursor = text.startIndex
        for heading in order {
            guard let range = text.range(of: heading, range: cursor..<text.endIndex) else {
                return XCTFail("missing or out of order: \(heading)")
            }
            cursor = range.upperBound
        }
        XCTAssertTrue(text.contains("start 0.90 0.60 0.25 0.03"))
    }
}

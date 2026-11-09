//
//  DiagnosticLogTests.swift
//
//  Entries are asked for by id, so ids must be stable and per category, each
//  category must keep its own history, and copying must send exactly what
//  was selected.
//

import XCTest

final class DiagnosticLogTests: XCTestCase {

    func testIdsCountPerCategory() {
        let log = DiagnosticLog()
        XCTAssertEqual(log.add(.stroke, "a"), "S1")
        XCTAssertEqual(log.add(.stroke, "b"), "S2")
        XCTAssertEqual(log.add(.shape, "c"), "Q1")
        XCTAssertEqual(log.add(.error, "d"), "E1")
        XCTAssertEqual(log.add(.stroke, "e"), "S3")
    }

    func testEachCategoryKeepsItsOwnHistory() {
        let log = DiagnosticLog()
        for i in 0..<10 { log.add(.stroke, "stroke \(i)") }
        // An idle hour of frame entries must not push the strokes out.
        for i in 0..<1000 { log.add(.frame, "frame \(i)") }
        XCTAssertEqual(log.count(in: .stroke), 10)
        XCTAssertEqual(log.count(in: .frame), DiagnosticLog.capacityPerCategory)
        // The oldest frames went, and ids keep counting rather than restarting.
        XCTAssertEqual(log.entries(in: [.frame]).last?.id, "F1000")
        XCTAssertEqual(log.entries(in: [.frame]).first?.id, "F901")
    }

    func testFilterAndSearch() {
        let log = DiagnosticLog()
        let base = Date(timeIntervalSince1970: 1000)
        log.add(.stroke, "pencil 40 smp", detail: "streamline 0.350", time: base)
        log.add(.shape, "none · line 3.10", time: base.addingTimeInterval(1))
        log.add(.stroke, "finger 12 smp", time: base.addingTimeInterval(2))
        XCTAssertEqual(log.entries(in: [.stroke]).map(\.id), ["S1", "S2"])
        XCTAssertEqual(log.entries(matching: "s2").map(\.id), ["S2"], "an id finds its entry")
        XCTAssertEqual(log.entries(matching: "STREAMLINE").map(\.id), ["S1"], "detail is searched")
        XCTAssertEqual(log.entries().map(\.id), ["S1", "Q1", "S2"], "oldest first across categories")
    }

    func testCopyingSendsExactlyTheSelection() {
        let log = DiagnosticLog()
        log.add(.stroke, "first", detail: "brush lines")
        log.add(.stroke, "second")
        let chosen = log.entries().filter { $0.id == "S1" }
        let text = DiagnosticLog.text(for: chosen, build: "0.3.105 (105)")
        XCTAssertTrue(text.contains("[S1]"))
        XCTAssertTrue(text.contains("brush lines"))
        XCTAssertFalse(text.contains("[S2]"))
        XCTAssertTrue(text.hasPrefix("Manga-Chan diagnostic entries · 0.3.105 (105)"))
    }
}

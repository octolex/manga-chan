//
//  DiagnosticLog.swift
//
//  Categorised, numbered log entries the tester can browse, filter and copy
//  selectively (octolex, 2026-11-09).
//
//  The design answers one worry stated with the request: that Claude would be
//  handed too much. So every entry has a short id — S12 is the twelfth stroke,
//  Q3 the third QuickShape hold, E1 the first error — and Claude asks for
//  entries by id: "send S12 to S15, and every E". The tester filters,
//  selects, and copies exactly those. Volume stops being a problem because
//  nothing is sent that was not asked for.
//
//  Each category keeps its own last 100 entries, so an idle hour of frame
//  summaries cannot push the strokes out.
//
//  Plain Swift, no UIKit, tested in CI. Main thread only.
//

import Foundation

struct DiagnosticEntry: Equatable {

    enum Category: String, CaseIterable {
        case build, stroke, shape, frame, gesture, layer, settings, error

        /// The id prefix: one letter, distinct per category.
        var letter: String {
            switch self {
            case .build: return "B"
            case .stroke: return "S"
            case .shape: return "Q"
            case .frame: return "F"
            case .gesture: return "G"
            case .layer: return "L"
            case .settings: return "C"
            case .error: return "E"
            }
        }
    }

    let id: String
    let category: Category
    let time: Date
    /// One line, shown in the list.
    let summary: String
    /// Everything else, shown when the entry is opened and included when it is
    /// copied. Empty when the summary says it all.
    let detail: String

    var copyText: String {
        let stamp = DiagnosticLog.timeFormatter.string(from: time)
        var text = "[\(id)] \(stamp) \(category.rawValue): \(summary)"
        if !detail.isEmpty { text += "\n" + detail }
        return text
    }
}

final class DiagnosticLog {

    static let shared = DiagnosticLog()
    static let capacityPerCategory = 100

    private var byCategory: [DiagnosticEntry.Category: [DiagnosticEntry]] = [:]
    private var counters: [DiagnosticEntry.Category: Int] = [:]

    /// Called whenever an entry is added, so an open viewer can refresh.
    var onChange: (() -> Void)?

    @discardableResult
    func add(_ category: DiagnosticEntry.Category, _ summary: String,
             detail: String = "", time: Date = Date()) -> String {
        let number = (counters[category] ?? 0) + 1
        counters[category] = number
        let entry = DiagnosticEntry(id: "\(category.letter)\(number)", category: category,
                                    time: time, summary: summary, detail: detail)
        var list = byCategory[category] ?? []
        list.append(entry)
        if list.count > Self.capacityPerCategory {
            list.removeFirst(list.count - Self.capacityPerCategory)
        }
        byCategory[category] = list
        onChange?()
        return entry.id
    }

    /// Entries in the given categories whose id, summary or detail contains
    /// `search` (case-insensitive), oldest first.
    func entries(in categories: Set<DiagnosticEntry.Category> = Set(DiagnosticEntry.Category.allCases),
                 matching search: String = "") -> [DiagnosticEntry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return categories.flatMap { byCategory[$0] ?? [] }
            .filter { entry in
                query.isEmpty
                    || entry.id.lowercased() == query
                    || entry.summary.lowercased().contains(query)
                    || entry.detail.lowercased().contains(query)
            }
            .sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    }

    func count(in category: DiagnosticEntry.Category) -> Int { byCategory[category]?.count ?? 0 }

    /// What "Copy selected" puts on the clipboard.
    static func text(for entries: [DiagnosticEntry], build: String) -> String {
        (["Manga-Chan diagnostic entries · \(build)"] + entries.map(\.copyText))
            .joined(separator: "\n\n")
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

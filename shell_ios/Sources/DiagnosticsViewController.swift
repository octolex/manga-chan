//
//  DiagnosticsViewController.swift
//
//  The diagnostic log, browsable: filter by category, search, tap entries to
//  open and select them, copy only what was asked for. See DiagnosticLog for
//  why it works by id.
//

import UIKit

final class DiagnosticsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    /// Builds the curated summary report on demand; supplied by the canvas,
    /// which owns the renderer it reads.
    var makeSummary: (() -> String)?
    var build = AppVersion.short

    private let log = DiagnosticLog.shared
    private var shown: [DiagnosticEntry] = []
    private var selected: Set<String> = []
    private var categories = Set(DiagnosticEntry.Category.allCases)

    private let table = UITableView(frame: .zero, style: .plain)
    private let search = UISearchTextField()
    private let chipRow = UIStackView()
    private var chips: [DiagnosticEntry.Category: UIButton] = [:]
    private let copySelectedButton = UIButton(type: .system)
    private let status = UILabel()

    private let accent = UIColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(white: 0.1, alpha: 1)

        let title = UILabel()
        title.text = "Diagnostics"
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = .white

        let close = UIButton(type: .system)
        close.setTitle("Done", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        let titleRow = UIStackView(arrangedSubviews: [title, UIView(), close])
        titleRow.axis = .horizontal

        let note = UILabel()
        note.numberOfLines = 0
        note.font = .systemFont(ofSize: 13)
        note.textColor = UIColor(white: 1, alpha: 0.55)
        note.text = "Claude asks for entries by id — \"S12 to S15, and every E\". "
                  + "Filter, tap the entries to select them, then Copy selected. "
                  + "Numbers about strokes and frames only, never the drawing."

        search.placeholder = "Search, or type an id like S12"
        search.autocorrectionType = .no
        search.autocapitalizationType = .none
        search.addAction(UIAction { [weak self] _ in self?.reload() }, for: .editingChanged)

        chipRow.axis = .horizontal
        chipRow.spacing = 6
        let chipScroll = UIScrollView()
        chipScroll.showsHorizontalScrollIndicator = false
        chipScroll.translatesAutoresizingMaskIntoConstraints = false
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.addSubview(chipRow)
        NSLayoutConstraint.activate([
            chipRow.topAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.topAnchor),
            chipRow.bottomAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.bottomAnchor),
            chipRow.leadingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.leadingAnchor),
            chipRow.trailingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.trailingAnchor),
            chipRow.heightAnchor.constraint(equalTo: chipScroll.frameLayoutGuide.heightAnchor),
            chipScroll.heightAnchor.constraint(equalToConstant: 34),
        ])
        for category in DiagnosticEntry.Category.allCases {
            let chip = UIButton(type: .system)
            chip.layer.cornerRadius = 8
            chip.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
            chip.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            chip.addAction(UIAction { [weak self] _ in self?.toggle(category) }, for: .touchUpInside)
            chips[category] = chip
            chipRow.addArrangedSubview(chip)
        }

        let selectShown = button("Select shown") { [weak self] in
            guard let self else { return }
            selected.formUnion(shown.map(\.id))
            reload()
        }
        let clear = button("Clear selection") { [weak self] in
            self?.selected.removeAll()
            self?.reload()
        }
        copySelectedButton.addAction(UIAction { [weak self] _ in self?.copySelected() }, for: .touchUpInside)
        copySelectedButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        let summary = button("Copy summary") { [weak self] in
            guard let self, let text = makeSummary?() else { return }
            UIPasteboard.general.string = text
            status.text = "Summary copied (\(text.utf8.count / 1024 + 1) KB). Paste it to Claude."
        }
        let actions = UIStackView(arrangedSubviews: [copySelectedButton, selectShown, clear, UIView(), summary])
        actions.axis = .horizontal
        actions.spacing = 16

        status.font = .systemFont(ofSize: 13)
        status.textColor = UIColor(white: 1, alpha: 0.7)
        status.numberOfLines = 0

        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 52
        table.register(UITableViewCell.self, forCellReuseIdentifier: "entry")

        let stack = UIStackView(arrangedSubviews: [titleRow, note, search, chipScroll, actions, status, table])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
        ])

        log.onChange = { [weak self] in self?.reload() }
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        log.onChange = nil
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15)
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func toggle(_ category: DiagnosticEntry.Category) {
        // Tapping the only chip that is on turns everything back on, rather
        // than leaving an empty list that looks broken.
        if categories == [category] {
            categories = Set(DiagnosticEntry.Category.allCases)
        } else if categories.count == DiagnosticEntry.Category.allCases.count {
            categories = [category]
        } else if categories.contains(category) {
            categories.remove(category)
        } else {
            categories.insert(category)
        }
        reload()
    }

    private func reload() {
        shown = log.entries(in: categories, matching: search.text ?? "")
        for (category, chip) in chips {
            let on = categories.contains(category)
            chip.setTitle("\(category.letter) \(category.rawValue) \(log.count(in: category))", for: .normal)
            chip.backgroundColor = on ? accent : UIColor(white: 0.22, alpha: 1)
            chip.tintColor = on ? .white : UIColor(white: 1, alpha: 0.6)
        }
        copySelectedButton.setTitle("Copy selected (\(selected.count))", for: .normal)
        copySelectedButton.isEnabled = !selected.isEmpty
        table.reloadData()
        for (row, entry) in shown.enumerated() where selected.contains(entry.id) {
            table.selectRow(at: IndexPath(row: row, section: 0), animated: false, scrollPosition: .none)
        }
    }

    private func copySelected() {
        let entries = log.entries().filter { selected.contains($0.id) }
        guard !entries.isEmpty else { return }
        let text = DiagnosticLog.text(for: entries, build: build)
        UIPasteboard.general.string = text
        status.text = "Copied \(entries.count) entries (\(text.utf8.count / 1024 + 1) KB). Paste them to Claude."
    }

    // MARK: Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        shown.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath)
        let entry = shown[indexPath.row]
        let open = selected.contains(entry.id)
        var config = cell.defaultContentConfiguration()
        config.text = "\(entry.id)  \(DiagnosticLog.timeFormatter.string(from: entry.time))  \(entry.summary)"
        config.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        config.textProperties.color = .white
        config.textProperties.numberOfLines = open ? 0 : 2
        // A selected entry is opened: its full detail shows under it, which
        // is also exactly what Copy selected will send.
        config.secondaryText = open && !entry.detail.isEmpty ? entry.detail : nil
        config.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        config.secondaryTextProperties.color = UIColor(white: 1, alpha: 0.7)
        config.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = config
        cell.backgroundColor = .clear
        cell.accessoryType = open ? .checkmark : .none
        let highlight = UIView()
        highlight.backgroundColor = accent.withAlphaComponent(0.25)
        cell.selectedBackgroundView = highlight
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selected.insert(shown[indexPath.row].id)
        refreshRow(indexPath)
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        selected.remove(shown[indexPath.row].id)
        refreshRow(indexPath)
    }

    private func refreshRow(_ indexPath: IndexPath) {
        copySelectedButton.setTitle("Copy selected (\(selected.count))", for: .normal)
        copySelectedButton.isEnabled = !selected.isEmpty
        table.reloadRows(at: [indexPath], with: .automatic)
        if selected.contains(shown[indexPath.row].id) {
            table.selectRow(at: indexPath, animated: false, scrollPosition: .none)
        }
    }
}

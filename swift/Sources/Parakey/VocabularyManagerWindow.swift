// SuperDictate — full manual CRUD window for the vocabulary/text-corrections
// store, opened from the Settings panel. Table view over VocabularyStore;
// add/edit/delete operate directly on the store (not through
// Settings.transcriptCorrections, so origin/created_at are preserved
// exactly as VocabularyStore tracks them).

import AppKit

@MainActor
final class VocabularyManagerWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: VocabularyStore
    private var window: NSWindow?
    private var tableView: NSTableView?
    private var records: [VocabularyRecord] = []

    init(store: VocabularyStore) {
        self.store = store
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            reload()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Словарь / Text Corrections"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = buildContentView()
        window.center()
        self.window = window
        reload()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        tableView = nil
    }

    private func buildContentView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true

        let sourceColumn = NSTableColumn(identifier: .init("source"))
        sourceColumn.title = "Оригинал"
        sourceColumn.width = 180
        let replacementColumn = NSTableColumn(identifier: .init("replacement"))
        replacementColumn.title = "Замена"
        replacementColumn.width = 180
        let originColumn = NSTableColumn(identifier: .init("origin"))
        originColumn.title = "Источник"
        originColumn.width = 90
        let dateColumn = NSTableColumn(identifier: .init("date"))
        dateColumn.title = "Добавлено"
        dateColumn.width = 90

        tableView.addTableColumn(sourceColumn)
        tableView.addTableColumn(replacementColumn)
        tableView.addTableColumn(originColumn)
        tableView.addTableColumn(dateColumn)

        scrollView.documentView = tableView
        self.tableView = tableView

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let addButton = makeButton(title: "Добавить", action: #selector(addTapped))
        let editButton = makeButton(title: "Изменить", action: #selector(editTapped))
        let deleteButton = makeButton(title: "Удалить", action: #selector(deleteTapped))
        let importButton = makeButton(title: "Импорт…", action: #selector(importTapped))
        let exportButton = makeButton(title: "Экспорт…", action: #selector(exportTapped))

        [addButton, editButton, deleteButton, importButton, exportButton].forEach { buttonRow.addArrangedSubview($0) }

        root.addArrangedSubview(scrollView)
        root.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        return root
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func reload() {
        records = store.all()
        tableView?.reloadData()
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let record = records[row]
        let text: String
        switch identifier.rawValue {
        case "source": text = record.source
        case "replacement": text = record.replacement
        case "origin": text = record.origin == .learned ? "выучено" : "вручную"
        case "date": text = String(record.createdAt.prefix(10))
        default: text = ""
        }
        let field = NSTextField(labelWithString: text)
        return field
    }

    // MARK: - Actions

    @objc private func addTapped() {
        guard let pair = promptForCorrection(existingSource: "", existingReplacement: "") else { return }
        guard let validated = normalizedTranscriptCorrections(
            [TranscriptCorrection(source: pair.source, replacement: pair.replacement)]
        ).first else {
            presentError("That correction was rejected: it's empty, too long, or contains characters Parakey can't store.")
            return
        }
        // Only refuse for genuinely new sources — an add that overwrites
        // an existing row (case/whitespace-insensitive) is an update, not
        // a new row, and must not be blocked by the cap. See I5 in the
        // final-review fix report.
        let isNewSource = !records.contains {
            normalizedTranscriptCorrectionSource($0.source) == normalizedTranscriptCorrectionSource(validated.source)
        }
        if isNewSource, store.count() >= MAX_TRANSCRIPT_CORRECTIONS {
            presentError("Parakey keeps at most \(MAX_TRANSCRIPT_CORRECTIONS) corrections, and that limit has been reached. Delete an existing entry before adding a new one.")
            return
        }
        _ = try? store.upsert(source: validated.source, replacement: validated.replacement, origin: .manual)
        reload()
    }

    @objc private func editTapped() {
        guard let tableView, tableView.selectedRow >= 0, records.indices.contains(tableView.selectedRow) else { return }
        let record = records[tableView.selectedRow]
        guard let pair = promptForCorrection(existingSource: record.source, existingReplacement: record.replacement) else { return }
        guard let validated = normalizedTranscriptCorrections(
            [TranscriptCorrection(source: pair.source, replacement: pair.replacement)]
        ).first else {
            presentError("That correction was rejected: it's empty, too long, or contains characters Parakey can't store.")
            return
        }
        let collidesWithOtherRow = records.contains { other in
            other.id != record.id
                && normalizedTranscriptCorrectionSource(other.source) == normalizedTranscriptCorrectionSource(validated.source)
        }
        if collidesWithOtherRow {
            presentError("A correction for \"\(validated.source)\" already exists.")
            return
        }
        if normalizedTranscriptCorrectionSource(validated.source) != normalizedTranscriptCorrectionSource(record.source) {
            store.delete(id: record.id)
        }
        _ = try? store.upsert(source: validated.source, replacement: validated.replacement, origin: record.origin)
        reload()
    }

    @objc private func deleteTapped() {
        guard let tableView, tableView.selectedRow >= 0, records.indices.contains(tableView.selectedRow) else { return }
        store.delete(id: records[tableView.selectedRow].id)
        reload()
    }

    private func promptForCorrection(existingSource: String, existingReplacement: String) -> (source: String, replacement: String)? {
        var currentSource = existingSource
        var currentReplacement = existingReplacement

        while true {
            let alert = NSAlert()
            alert.messageText = "Text Correction"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")

            let container = NSStackView()
            container.orientation = .vertical
            container.spacing = 8
            container.frame = NSRect(x: 0, y: 0, width: 280, height: 60)

            let sourceField = NSTextField(string: currentSource)
            sourceField.placeholderString = "Model said…"
            let replacementField = NSTextField(string: currentReplacement)
            replacementField.placeholderString = "Should say…"
            container.addArrangedSubview(sourceField)
            container.addArrangedSubview(replacementField)
            alert.accessoryView = container

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let source = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = replacementField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            currentSource = source
            currentReplacement = replacement
            if !source.isEmpty, !replacement.isEmpty {
                return (source, replacement)
            }
            presentError("Both fields are required.")
        }
    }

    @objc private func importTapped() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let imported = try? TranscriptCorrectionsTransfer.read(from: url) else {
            presentError("Could not read that corrections file.")
            return
        }
        for correction in normalizedTranscriptCorrections(imported) {
            _ = try? store.upsert(source: correction.source, replacement: correction.replacement, origin: .manual)
        }
        reload()
    }

    @objc private func exportTapped() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.nameFieldStringValue = "corrections"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let corrections = records.map { TranscriptCorrection(source: $0.source, replacement: $0.replacement) }
        do {
            try TranscriptCorrectionsTransfer.write(corrections, to: url)
        } catch {
            presentError("Could not save that corrections file: \(error.localizedDescription)")
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }
}

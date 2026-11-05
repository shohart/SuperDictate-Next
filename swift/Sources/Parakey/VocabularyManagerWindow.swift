// SuperDictate — full manual CRUD window for the vocabulary/text-corrections
// store, opened from the Settings panel. Table view over VocabularyStore;
// add/edit/delete operate directly on the store (not through
// Settings.transcriptCorrections, so origin/created_at are preserved
// exactly as VocabularyStore tracks them).

import AppKit
import UniformTypeIdentifiers

@MainActor
final class VocabularyManagerWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: VocabularyStore
    private var window: NSWindow?
    private var tableView: NSTableView?
    private var records: [VocabularyRecord] = []
    // ASR Hotwords tab (docs/specs/user-hotword-vocabulary-spec.md §7):
    // a separate list, independent from the corrections table above.
    private var hotwordTableView: NSTableView?
    private var hotwordPhraseField: NSTextField?
    private var hotwords: [HotwordPhraseRecord] = []
    private var changeObserver: NSObjectProtocol?

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
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 470),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Словарь / Text Corrections"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = buildTabbedContentView()
        window.center()
        self.window = window
        // Learning in the agent, the account sync and other windows change
        // the store behind this table: reload on the shared notification.
        changeObserver = DistributedNotificationCenter.default().addObserver(
            forName: VOCABULARY_CHANGED_NOTIFICATION, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let changeObserver {
            DistributedNotificationCenter.default().removeObserver(changeObserver)
        }
        changeObserver = nil
        window = nil
        tableView = nil
        hotwordTableView = nil
        hotwordPhraseField = nil
    }

    /// Corrections editor and ASR hotwords as two tabs; the corrections
    /// view is embedded unchanged.
    private func buildTabbedContentView() -> NSView {
        let corrections = NSView()
        let correctionsContent = buildContentView()
        corrections.addSubview(correctionsContent)
        NSLayoutConstraint.activate([
            correctionsContent.topAnchor.constraint(equalTo: corrections.topAnchor),
            correctionsContent.leadingAnchor.constraint(equalTo: corrections.leadingAnchor),
            correctionsContent.trailingAnchor.constraint(equalTo: corrections.trailingAnchor),
            correctionsContent.bottomAnchor.constraint(equalTo: corrections.bottomAnchor),
        ])

        let tabView = NSTabView()
        let correctionsItem = NSTabViewItem(identifier: "corrections")
        correctionsItem.label = t("Исправления", "Corrections")
        correctionsItem.view = corrections
        let hotwordsItem = NSTabViewItem(identifier: "hotwords")
        hotwordsItem.label = t("ASR-термины", "ASR Hotwords")
        hotwordsItem.view = buildHotwordsView()
        tabView.addTabViewItem(correctionsItem)
        tabView.addTabViewItem(hotwordsItem)
        return tabView
    }

    private func buildHotwordsView() -> NSView {
        let container = NSView()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let explanation = NSTextField(wrappingLabelWithString: t(
            "Фразы, которые распознавание должно понимать лучше (имена, термины). Они лишь подсказывают распознаванию и сами ничего не заменяют в тексте.",
            "Phrases recognition should understand better (names, terms). They only guide recognition and never replace text on their own."
        ))
        explanation.setAccessibilityLabel(t("Пояснение к ASR-терминам", "ASR hotwords explanation"))

        let formatNote = NSTextField(wrappingLabelWithString: t(
            "Импорт: текстовый файл UTF-8, одна фраза на строку. Пустые строки и строки, начинающиеся с «#», пропускаются; дубликаты игнорируются. Одна фраза — не более четырёх слов.",
            "Import: a UTF-8 text file, one phrase per line. Blank lines and lines starting with # are skipped; duplicates are ignored. A phrase is at most four words."
        ))
        formatNote.font = .systemFont(ofSize: 11)
        formatNote.textColor = .secondaryLabelColor
        formatNote.setAccessibilityLabel(t("Формат файла импорта ASR-терминов", "ASR hotword import file format"))

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel(t("Список ASR-терминов", "ASR hotwords list"))
        let enabledColumn = NSTableColumn(identifier: .init("hotwordEnabled"))
        enabledColumn.title = t("Включено", "Enabled")
        enabledColumn.width = 80
        let phraseColumn = NSTableColumn(identifier: .init("hotwordPhrase"))
        phraseColumn.title = t("Фраза", "Phrase")
        phraseColumn.width = 440
        table.addTableColumn(enabledColumn)
        table.addTableColumn(phraseColumn)
        scrollView.documentView = table
        hotwordTableView = table

        let field = NSTextField()
        field.placeholderString = t("Новая фраза…", "New phrase…")
        field.target = self
        field.action = #selector(addHotwordTapped)
        field.setAccessibilityLabel(t("Новая ASR-фраза", "New ASR hotword phrase"))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        hotwordPhraseField = field
        let addButton = makeButton(title: t("Добавить", "Add"), action: #selector(addHotwordTapped))
        addButton.setAccessibilityLabel(t("Добавить ASR-фразу", "Add ASR hotword"))
        let deleteButton = makeButton(title: t("Удалить", "Delete"), action: #selector(deleteHotwordTapped))
        deleteButton.setAccessibilityLabel(t("Удалить выбранную ASR-фразу", "Delete selected ASR hotword"))
        let importButton = makeButton(title: t("Импорт…", "Import…"), action: #selector(importHotwordsTapped))
        importButton.setAccessibilityLabel(t("Импортировать ASR-фразы из файла", "Import ASR hotwords from a file"))
        let buttonRow = NSStackView(views: [field, addButton, deleteButton, importButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        root.addArrangedSubview(explanation)
        root.addArrangedSubview(formatNote)
        root.addArrangedSubview(scrollView)
        root.addArrangedSubview(buttonRow)
        NSLayoutConstraint.activate([
            explanation.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            formatNote.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        return container
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
        let asrHintColumn = NSTableColumn(identifier: .init("asrHint"))
        asrHintColumn.title = t("Подсказка ASR", "ASR hint")
        asrHintColumn.width = 90
        asrHintColumn.headerToolTip = t(
            "Подсказывать ли распознаванию эту замену как термин. По умолчанию: ручные записи — да, выученные — только термины (латиница, цифры, аббревиатуры). Щелчок задаёт значение явно.",
            "Whether recognition is biased toward this replacement as a term. By default manual entries are, learned ones only when term-like (Latin, digits, acronyms). A click sets it explicitly."
        )

        tableView.addTableColumn(sourceColumn)
        tableView.addTableColumn(replacementColumn)
        tableView.addTableColumn(originColumn)
        tableView.addTableColumn(dateColumn)
        tableView.addTableColumn(asrHintColumn)

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
        let cleanupButton = makeButton(title: t("Почистить словарь…", "Clean up…"), action: #selector(cleanupTapped))
        cleanupButton.toolTip = t("Найти в выученных записях мусор (правки пунктуации, словоформы, переписанный текст), цепочки, дубликаты и разнобой регистра. Перед изменением будет показан список. Ручные записи не трогаются.",
                                  "Find junk in learned entries (punctuation edits, inflections, rewritten text), chains, duplicates and case conflicts. A preview is shown before anything changes. Manual entries are never touched.")

        [addButton, editButton, deleteButton, importButton, exportButton, cleanupButton].forEach { buttonRow.addArrangedSubview($0) }

        root.addArrangedSubview(scrollView)
        root.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        return root
    }

    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: Settings.shared.interfaceLanguage)
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func reload() {
        records = store.all()
        tableView?.reloadData()
        hotwords = store.hotwordPhrases()
        hotwordTableView?.reloadData()
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === hotwordTableView ? hotwords.count : records.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === hotwordTableView { return hotwordCell(column: tableColumn, row: row) }
        guard records.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let record = records[row]
        if identifier.rawValue == "asrHint" {
            return asrHintCheckbox(for: record)
        }
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

    /// Shows the effective state (AsrHotwordSelection); an entry that can
    /// never be a hotword (too short, too long, a punctuation-only edit)
    /// is shown off and disabled.
    private func asrHintCheckbox(for record: VocabularyRecord) -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(asrHintToggled(_:)))
        let eligible = AsrHotwordSelection.eligiblePhrase(source: record.source, replacement: record.replacement) != nil
        checkbox.state = AsrHotwordSelection.isEffective(record) ? .on : .off
        checkbox.isEnabled = eligible
        if !eligible {
            checkbox.toolTip = t("Эта замена не подходит для подсказки: слишком короткая или длинная, без букв или отличается только пунктуацией.",
                                 "This replacement cannot be a hint: too short or too long, no letters, or a punctuation-only edit.")
        } else if record.asrHint == nil {
            checkbox.toolTip = t("Автоматически", "Automatic")
        } else {
            checkbox.toolTip = t("Задано вручную", "Set explicitly")
        }
        return checkbox
    }

    @objc private func asrHintToggled(_ sender: NSButton) {
        guard let tableView else { return }
        let row = tableView.row(for: sender)
        guard records.indices.contains(row) else { return }
        do {
            try store.setAsrHint(id: records[row].id, hint: sender.state == .on)
        } catch {
            presentError(t("Не удалось сохранить подсказку ASR: \(error.localizedDescription)",
                           "Could not save the ASR hint: \(error.localizedDescription)"))
        }
        reload()
    }

    // MARK: - ASR hotwords

    private func hotwordCell(column: NSTableColumn?, row: Int) -> NSView? {
        guard hotwords.indices.contains(row), let identifier = column?.identifier else { return nil }
        let hotword = hotwords[row]
        if identifier.rawValue == "hotwordEnabled" {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(hotwordToggled(_:)))
            checkbox.state = hotword.enabled ? .on : .off
            checkbox.setAccessibilityLabel(t("Включить «\(hotword.phrase)»", "Enable “\(hotword.phrase)”"))
            return checkbox
        }
        return NSTextField(labelWithString: hotword.phrase)
    }

    @objc private func hotwordToggled(_ sender: NSButton) {
        guard let hotwordTableView else { return }
        let row = hotwordTableView.row(for: sender)
        guard hotwords.indices.contains(row) else { return }
        do {
            try store.setHotwordPhraseEnabled(id: hotwords[row].id, enabled: sender.state == .on)
        } catch {
            presentError(t("Не удалось сохранить ASR-фразу: \(error.localizedDescription)",
                           "Could not save the ASR hotword: \(error.localizedDescription)"))
        }
        reload()
    }

    @objc private func addHotwordTapped() {
        guard let hotwordPhraseField else { return }
        let phrase = hotwordPhraseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        do {
            try store.addHotwordPhrase(phrase)
            hotwordPhraseField.stringValue = ""
        } catch {
            presentError(t("Не удалось добавить ASR-фразу: \(error.localizedDescription)",
                           "Could not add the ASR hotword: \(error.localizedDescription)"))
        }
        reload()
    }

    @objc private func deleteHotwordTapped() {
        guard let hotwordTableView, hotwords.indices.contains(hotwordTableView.selectedRow) else { return }
        do {
            try store.deleteHotwordPhrase(id: hotwords[hotwordTableView.selectedRow].id)
        } catch {
            presentError(t("Не удалось удалить ASR-фразу: \(error.localizedDescription)",
                           "Could not delete the ASR hotword: \(error.localizedDescription)"))
        }
        reload()
    }

    /// One phrase per line; blank lines, `#` comments and duplicates are skipped.
    private func importHotwords(text: String) -> (added: Int, failed: Int, firstFailure: String) {
        var added = 0
        var failed = 0
        var firstFailure = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            do {
                _ = try store.addHotwordPhrase(line)
                added += 1
            } catch VocabularyStoreError.duplicatePhrase {
                // Expected on import: an existing or repeated phrase is skipped.
            } catch {
                failed += 1
                if firstFailure.isEmpty { firstFailure = error.localizedDescription }
            }
        }
        return (added, failed, firstFailure)
    }

    @objc private func importHotwordsTapped() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .utf8PlainText, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.message = t("Выберите текстовый файл со списком фраз — по одной на строку.",
                          "Choose a text file with one phrase per line.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            presentError(t("Не удалось прочитать файл. Используйте кодировку UTF-8.",
                           "Could not read the file. Use UTF-8 encoding."))
            return
        }
        let (added, failed, firstFailure) = importHotwords(text: text)
        reload()
        if failed > 0 {
            presentError(t("Импортировано фраз: \(added), пропущено с ошибкой: \(failed) (первая ошибка: \(firstFailure)).",
                           "Imported phrases: \(added), skipped with error: \(failed) (first error: \(firstFailure))."))
        } else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = t("Импорт завершён", "Import complete")
            alert.informativeText = t("Добавлено фраз: \(added). Дубликаты, пустые строки и комментарии пропущены.",
                                      "Added phrases: \(added). Duplicates, blank lines and comments were skipped.")
            alert.runModal()
        }
    }

    // MARK: - Actions

    /// Spec vocabulary-hygiene §2: the manual editor applies only rule 1
    /// (trim edge punctuation) and rule 3 (junk replacement).
    private func manualHygiene(_ pair: (source: String, replacement: String)) -> (source: String, replacement: String)? {
        guard let reviewed = VocabularyHygiene.reviewManual(source: pair.source, replacement: pair.replacement) else {
            presentError(t("Замена должна содержать букву и быть не короче 2 символов (без учёта пунктуации по краям).",
                           "The replacement needs a letter and at least 2 characters (edge punctuation is not counted)."))
            return nil
        }
        return reviewed
    }

    @objc private func addTapped() {
        guard let prompted = promptForCorrection(existingSource: "", existingReplacement: ""),
              let pair = manualHygiene(prompted) else { return }
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
        do {
            _ = try store.upsert(source: validated.source, replacement: validated.replacement, origin: .manual)
        } catch {
            // Never swallow this: the agent process holds its own
            // connection to the same corrections.sqlite, and a lock
            // contention (or any other SQLite failure) that silently
            // drops the row is exactly how "I saved a correction but it
            // didn't appear" happens.
            presentError("Could not save that correction: \(error.localizedDescription)")
            reload()
            return
        }
        reload()
    }

    @objc private func editTapped() {
        guard let tableView, tableView.selectedRow >= 0, records.indices.contains(tableView.selectedRow) else { return }
        let record = records[tableView.selectedRow]
        guard let prompted = promptForCorrection(existingSource: record.source, existingReplacement: record.replacement),
              let pair = manualHygiene(prompted) else { return }
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
        let sourceChanged = normalizedTranscriptCorrectionSource(validated.source) != normalizedTranscriptCorrectionSource(record.source)
        if sourceChanged {
            store.delete(id: record.id)
        }
        do {
            let saved = try store.upsert(source: validated.source, replacement: validated.replacement, origin: record.origin)
            // A changed source is a fresh row: carry the explicit ASR hint over.
            if sourceChanged, let hint = record.asrHint {
                try store.setAsrHint(id: saved.id, hint: hint)
            }
        } catch {
            presentError("Could not save that correction: \(error.localizedDescription)")
            reload()
            return
        }
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
        var failedCount = 0
        var firstFailureMessage = ""
        for correction in normalizedTranscriptCorrections(imported) {
            do {
                _ = try store.upsert(source: correction.source, replacement: correction.replacement, origin: .manual)
            } catch {
                failedCount += 1
                if firstFailureMessage.isEmpty {
                    firstFailureMessage = error.localizedDescription
                }
            }
        }
        reload()
        if failedCount > 0 {
            presentError("\(failedCount) correction(s) could not be imported (first error: \(firstFailureMessage)).")
        }
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

    // MARK: - Cleanup (spec vocabulary-hygiene §3)

    @objc private func cleanupTapped() {
        let plan = store.cleanupPlan()
        guard !plan.isEmpty else {
            let alert = NSAlert()
            alert.messageText = t("Словарь в порядке", "The vocabulary is clean")
            alert.informativeText = t("В выученных записях нечего удалять или исправлять.",
                                      "Nothing to delete or fix in the learned entries.")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = t("Почистить словарь?", "Clean up the vocabulary?")
        let duplicateCount = plan.deletions.filter { if case .duplicate = $0.reason { return true } else { return false } }.count
        alert.informativeText = t(
            "Удалить: \(plan.deletions.count - duplicateCount), исправить: \(plan.rewrites.count), убрать дубликатов: \(duplicateCount). Ручные записи не меняются.",
            "Delete: \(plan.deletions.count - duplicateCount), fix: \(plan.rewrites.count), remove duplicates: \(duplicateCount). Manual entries stay unchanged."
        )
        alert.addButton(withTitle: t("Почистить", "Clean Up"))
        alert.addButton(withTitle: t("Отмена", "Cancel"))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 12)
        textView.autoresizingMask = [.width]
        textView.string = cleanupPreviewText(plan)
        scrollView.documentView = textView
        alert.accessoryView = scrollView

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.applyCleanup(plan)
            log("vocabulary: cleanup applied — \(plan.deletions.count) deleted, \(plan.rewrites.count) rewritten")
        } catch {
            presentError(t("Не удалось почистить словарь: \(error.localizedDescription)",
                           "Could not clean up the vocabulary: \(error.localizedDescription)"))
        }
        reload()
    }

    private func cleanupPreviewText(_ plan: VocabularyHygiene.CleanupPlan) -> String {
        func pair(_ source: String, _ replacement: String) -> String { "«\(source)» → «\(replacement)»" }
        var lines: [String] = []
        let rejected = plan.deletions.compactMap { deletion -> (VocabularyRecord, VocabularyHygiene.RejectReason)? in
            if case .rejected(let reason) = deletion.reason { return (deletion.record, reason) }
            return nil
        }
        if !rejected.isEmpty {
            lines.append(t("Удалить (\(rejected.count)):", "Delete (\(rejected.count)):"))
            for (record, reason) in rejected {
                lines.append("  " + pair(record.source, record.replacement) + " — " + reasonText(reason))
            }
            lines.append("")
        }
        if !plan.rewrites.isEmpty {
            lines.append(t("Исправить (\(plan.rewrites.count)):", "Fix (\(plan.rewrites.count)):"))
            for rewrite in plan.rewrites {
                let kinds = rewrite.kinds.map(kindText).joined(separator: ", ")
                lines.append("  " + pair(rewrite.record.source, rewrite.record.replacement)
                             + "  ⇒  " + pair(rewrite.source, rewrite.replacement) + " — " + kinds)
            }
            lines.append("")
        }
        if !plan.merges.isEmpty {
            let removed = plan.merges.reduce(0) { $0 + $1.removed.count }
            lines.append(t("Объединить дубликаты (удалить \(removed)):", "Merge duplicates (delete \(removed)):"))
            for merge in plan.merges {
                let names = merge.removed.map { pair($0.source, $0.replacement) }.joined(separator: ", ")
                lines.append("  " + names + t("  — остаётся «\(merge.keptSource)»", "  — keeps «\(merge.keptSource)»"))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func reasonText(_ reason: VocabularyHygiene.RejectReason) -> String {
        switch reason {
        case .punctuation: return t("правка только пунктуации или регистра", "punctuation or case only")
        case .noLetters: return t("в замене нет букв", "no letters in the replacement")
        case .inflection: return t("смена словоформы", "word-form change")
        case .rewrite: return t("переписан текст, а не термин", "text rewrite, not a term")
        }
    }

    private func kindText(_ kind: VocabularyHygiene.CleanupRewriteKind) -> String {
        switch kind {
        case .trimmed: return t("пунктуация по краям", "edge punctuation")
        case .chain: return t("цепочка", "chain")
        case .caseUnified: return t("единый регистр", "unified case")
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }
}

#if DEBUG
extension VocabularyManagerWindowController {
    /// Self-test `hotword-window`: drives the real tab's controls without
    /// putting a window on screen and writes what it draws to `imageURL`.
    func exerciseHotwordsTabForSelfTest(imageURL: URL?) throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw VocabularyLearningTestFailure("hotword window: \(message)") }
        }
        let view = buildHotwordsView()
        // In a window that is never ordered in: controls draw as in the app.
        let offscreen = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        offscreen.isReleasedWhenClosed = false
        offscreen.contentView = view
        reload()
        guard let field = hotwordPhraseField, let table = hotwordTableView else {
            throw VocabularyLearningTestFailure("hotword window: the controls were not built")
        }
        field.stringValue = "Дунималова Анаида Георгиевна"
        addHotwordTapped()
        try expect(store.hotwordPhrases().map(\.phrase) == ["Дунималова Анаида Георгиевна"], "Add stores the phrase")
        try expect(field.stringValue.isEmpty && numberOfRows(in: table) == 1, "Add clears the field and fills the table")

        let imported = importHotwords(text: "# суд\r\nАрбитражный суд города Москвы\r\n\r\nарбитражный СУД ГОРОДА москвы\r\nЕФРСБ\r\nфинансовый управляющий\r\n")
        reload()
        try expect(imported.added == 3 && imported.failed == 0, "import counts: \(imported)")
        try expect(numberOfRows(in: table) == 4, "import fills the table")

        view.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        guard let columnIndex = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "hotwordEnabled" }),
              let checkbox = table.view(atColumn: columnIndex, row: 1, makeIfNecessary: true) as? NSButton else {
            throw VocabularyLearningTestFailure("hotword window: no checkbox in the row")
        }
        checkbox.state = .off
        _ = checkbox.sendAction(checkbox.action, to: checkbox.target)
        try expect(store.hotwordPhrases()[1].enabled == false, "the checkbox turns the phrase off")
        try expect(!store.asrHotwordPhrases().contains("Арбитражный суд города Москвы"), "an unchecked phrase leaves the ASR list")

        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        deleteHotwordTapped()
        try expect(store.hotwordPhrases().map(\.phrase) == ["Дунималова Анаида Георгиевна", "Арбитражный суд города Москвы", "финансовый управляющий"], "Delete removes the selected row")
        try expect(store.hotwordTombstones().map(\.key) == ["ефрсб"], "Delete leaves a tombstone")
        try expect(store.all().isEmpty, "terms create no replacement rules")

        if let imageURL {
            view.layoutSubtreeIfNeeded()
            table.layoutSubtreeIfNeeded()
            offscreen.displayIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: imageURL)
            }
        }
    }
}
#endif

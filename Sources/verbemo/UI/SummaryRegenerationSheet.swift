import AppKit

/// The request is captured when a choice is displayed, and retained for an explicit retry.
@MainActor
final class SummaryRegenerationSheet {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
                         styleMask: [.titled], backing: .buffered, defer: false)
    let picker = NSPopUpButton()
    let disclosure = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "")
    let create = NSButton()
    private let cancel = NSButton()
    private let onSettings: (() -> Void)?
    private let run: (SummaryRequest) async throws -> Void
    private let onFailure: (any Error) -> Void
    private let completion: () -> Void
    private var request: SummaryRequest?
    private var finished = false
    private(set) var task: Task<Void, Never>?
    private static let choices: [String?] = [nil, "codex-cli", "claude-cli", "openai-api", "anthropic-api", "ollama"]

    init(onSettings: (() -> Void)? = nil, run: @escaping (SummaryRequest) async throws -> Void,
         onFailure: @escaping (any Error) -> Void, completion: @escaping () -> Void) {
        self.run = run; self.completion = completion; self.onSettings = onSettings
        self.onFailure = onFailure
        window.title = localised("Create a new summary", "Создать новую сводку")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = JournalStyle.paper
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: window.title)
        heading.font = JournalStyle.titleFont(18)
        heading.textColor = JournalStyle.ink
        let note = NSTextField(wrappingLabelWithString: localised(
            "Uses the selected transcript version. The previous summary is kept on failure or cancellation.",
            "Используется выбранная версия расшифровки. При ошибке или отмене предыдущая сводка сохранится."))
        note.textColor = JournalStyle.muted
        picker.addItems(withTitles: [localised("From settings", "Из настроек"), "Codex", "Claude Code", "OpenAI API", "Anthropic API", "Ollama"])
        picker.identifier = .init("summary.provider")
        picker.setAccessibilityLabel(localised("Provider for this summary", "Способ для этой сводки"))
        picker.target = self; picker.action = #selector(selectionChanged)
        disclosure.identifier = .init("summary.destination")
        disclosure.font = .systemFont(ofSize: 12)
        disclosure.textColor = JournalStyle.ink
        status.identifier = .init("summary.status")
        status.font = .systemFont(ofSize: 12)
        status.textColor = JournalStyle.muted
        create.bezelStyle = .rounded; create.keyEquivalent = "\r"
        create.identifier = .init("summary.create")
        create.target = self; create.action = #selector(start)
        cancel.title = localised("Cancel", "Отмена")
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        cancel.target = self; cancel.action = #selector(cancelClicked)
        let buttons = NSStackView(views: [SetupLayout.spacer(), cancel, create])
        buttons.spacing = 8
        let content = NSStackView(views: [heading, note, picker, disclosure, status, buttons])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        if onSettings != nil {
            let settings = NSButton(title: localised("Summary settings…", "Настройки сводки…"), target: self, action: #selector(settingsClicked))
            settings.isBordered = false
            settings.font = .systemFont(ofSize: 12)
            settings.contentTintColor = JournalStyle.muted
            buttons.insertArrangedSubview(settings, at: 0)
        }
        let surface = JournalSurface(JournalStyle.paper)
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 440),
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: surface.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -20),
        ])
        window.contentView = surface
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        selectionChanged()
    }

    @objc func selectionChanged() {
        guard task == nil else { return }
        status.stringValue = ""
        status.isHidden = true
        create.title = localised("Check and create", "Проверить и создать")
        do {
            request = try SummaryRequest.capture(backend: Self.choices[picker.indexOfSelectedItem])
            disclosure.stringValue = request?.disclosure ?? ""
            create.isEnabled = true
        } catch {
            request = nil; disclosure.stringValue = error.localizedDescription
            create.isEnabled = false
        }
        resize()
    }

    @objc func start() {
        guard !finished, task == nil, let request else { return }
        picker.isEnabled = false; create.isEnabled = false
        status.stringValue = localised("Checking access and creating the summary…", "Проверка доступа и создание сводки…")
        dismiss()
        task = Task { [self] in
            do {
                try await run(request)
                task = nil
                close()
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                task = nil
                if cancelled { close(); return }
                status.stringValue = error.localizedDescription
                status.isHidden = false
                picker.isEnabled = true; create.isEnabled = true
                create.title = localised("Retry same choice", "Повторить с тем же выбором")
                resize()
                onFailure(error)
            }
        }
    }

    @objc private func cancelClicked() {
        if let task {
            task.cancel()
            status.stringValue = localised("Cancelling…", "Отмена…")
            cancel.isEnabled = false
        } else { close() }
    }

    @objc private func settingsClicked() {
        guard task == nil else { return }
        close()
        onSettings?()
    }

    private func close() {
        guard !finished else { return }
        finished = true
        dismiss()
        completion()
    }

    private func dismiss() {
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }

    private func resize() {
        window.contentView?.layoutSubtreeIfNeeded()
        if let size = window.contentView?.fittingSize { window.setContentSize(size) }
    }
}

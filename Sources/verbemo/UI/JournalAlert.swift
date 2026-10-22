import AppKit

@MainActor
extension NSAlert {
    func beginJournalSheetModal(for parent: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        let panel = window
        let observer = observeJournalPresentation(of: panel)
        beginSheetModal(for: parent) { response in
            NotificationCenter.default.removeObserver(observer)
            completionHandler?(response)
        }
        if parent.attachedSheet === panel { layoutForJournal(in: panel) }
    }

    func beginJournalSheetModal(for parent: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            beginJournalSheetModal(for: parent) { continuation.resume(returning: $0) }
        }
    }

    @discardableResult
    func runJournalModal() -> NSApplication.ModalResponse {
        // NSAlert lays out again when presented, so style after its final layout.
        let observer = observeJournalPresentation(of: window)
        defer { NotificationCenter.default.removeObserver(observer) }
        return runModal()
    }

    private func observeJournalPresentation(of panel: NSWindow) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
            object: panel, queue: .main) { [self] _ in
                MainActor.assumeIsolated { layoutForJournal(in: panel) }
            }
    }

    /// Reading NSAlert.window triggers native layout; use the already presented window.
    private func layoutForJournal(in window: NSWindow) {
        guard !(window.contentView is JournalSurface) else { return }
        let nativeDefaultButton = window.defaultButtonCell
        let heading = NSTextField(wrappingLabelWithString: messageText)
        heading.identifier = .init("dialog.heading")
        heading.font = JournalStyle.titleFont(20)
        heading.textColor = JournalStyle.ink
        let note = NSTextField(wrappingLabelWithString: informativeText)
        note.font = .systemFont(ofSize: 13)
        note.textColor = JournalStyle.muted
        note.isHidden = informativeText.isEmpty
        let actions = NSStackView(views: [SetupLayout.spacer()] + buttons.reversed())
        actions.spacing = 8
        let content = NSStackView(views: [heading, note])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        if let accessoryView {
            let height = accessoryView.frame.height
            content.addArrangedSubview(accessoryView)
            accessoryView.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        }
        content.addArrangedSubview(actions)
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let surface = JournalAlertSurface(JournalStyle.paper)
        surface.cancelButton = buttons.first { $0.keyEquivalent == "\u{1b}" } ?? (buttons.count == 1 ? buttons.first : nil)
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 452),
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: surface.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -24),
        ])
        window.title = messageText
        window.contentView = surface
        window.setContentSize(surface.fittingSize)
        window.autorecalculatesKeyViewLoop = true
        window.defaultButtonCell = nativeDefaultButton
        window.initialFirstResponder = surface
        window.makeFirstResponder(surface)
    }
}

@MainActor
private final class JournalAlertSurface: JournalSurface {
    var cancelButton: NSButton?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func cancelOperation(_ sender: Any?) {
        guard let cancelButton else { super.cancelOperation(sender); return }
        _ = cancelButton.sendAction(cancelButton.action, to: cancelButton.target)
    }
}

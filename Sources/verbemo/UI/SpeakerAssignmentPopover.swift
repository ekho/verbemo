import AppKit

@MainActor
final class SpeakerAssignmentPopover: NSViewController {
    let editor: SpeakerAssignmentEditor
    var onAssign: ((CalendarParticipant?, String?) throws -> Void)?
    var onDismiss: (() -> Void)?
    private var draft: (CalendarParticipant?, String?)
    private var completed = false
    private var hasChanges = false
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    init(speaker: String, title: String, entry: SpeakerNames.Entry?, participants: [CalendarParticipant], canEdit: Bool) {
        editor = SpeakerAssignmentEditor(speaker: speaker, title: title, entry: entry,
                                         participants: participants, canEdit: canEdit, inline: false)
        draft = (participants.first { $0.id == entry?.participantID }, entry?.name)
        super.init(nibName: nil, bundle: nil)
        editor.onAssign = { [weak self] participant, name in
            self?.draft = (participant, name)
            self?.hasChanges = true
        }
        editor.onSubmit = { [weak self] in _ = self?.apply() }
        editor.onCancel = { [weak self] in self?.cancel() }
        let scope = NSTextField(wrappingLabelWithString: localised(
            "All lines by \(title) in the selected transcript version.",
            "Все реплики «\(title)» в выбранной версии расшифровки."))
        scope.font = .systemFont(ofSize: 12)
        let save = NSButton(title: localised("Apply", "Применить"), target: self, action: #selector(applyClicked))
        save.identifier = .init("speaker.apply")
        save.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        save.imagePosition = .imageLeading
        save.bezelStyle = .rounded
        save.isEnabled = editor.choice.isEnabled
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: localised("Cancel", "Отмена"), target: self, action: #selector(cancel))
        cancel.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        cancel.imagePosition = .imageLeading
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [NSView(), cancel, save])
        actions.spacing = 8
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.setAccessibilityRole(.staticText)
        let stack = NSStackView(views: [scope, editor, errorLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.widthAnchor.constraint(equalToConstant: 380).isActive = true
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        view = stack
        preferredContentSize = NSSize(width: 380, height: 160)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(editor.choice) }
    @discardableResult func apply() -> Bool {
        guard !completed, editor.choice.isEnabled, !editor.isChoosing else { return false }
        view.window?.makeFirstResponder(nil)
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        do {
            if hasChanges { try onAssign?(draft.0, draft.1) }
            completed = true
            onDismiss?()
            return true
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
            preferredContentSize = NSSize(width: 380, height: max(180, view.fittingSize.height))
            return false
        }
    }
    @objc private func applyClicked() { apply() }
    @objc func cancel() { guard !completed else { return }; completed = true; onDismiss?() }
}

@MainActor
final class SpeakerEditButton: NSButton, NSPopoverDelegate {
    var makeEditor: (() -> SpeakerAssignmentPopover?)?
    var onRestoreFocus: (() -> Void)?
    private var popover: NSPopover?
    private var restoreFocusAfterClose: (() -> Void)?
    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        isBordered = false
        target = self
        action = #selector(openEditor)
        identifier = .init("speaker.edit")
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openEditor() {
        guard isEnabled, let editor = makeEditor?() else { return }
        let popover = NSPopover()
        self.popover = popover
        restoreFocusAfterClose = onRestoreFocus
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = editor
        editor.onDismiss = { [weak self] in self?.popover?.performClose(nil) }
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        let restore = restoreFocusAfterClose ?? onRestoreFocus
        restoreFocusAfterClose = nil
        if let restore { restore() } else { window?.makeFirstResponder(self) }
    }
}

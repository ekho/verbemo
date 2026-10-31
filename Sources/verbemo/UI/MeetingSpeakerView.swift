import AppKit

@MainActor
private final class SpeakerAssignmentChoice: NSComboBox {
    private var dropdownWindows: [NSWindow] = []

    override init(frame frameRect: NSRect) {
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        super.init(frame: frameRect)
        dropdownWindows = NSApp.windows.filter {
            !existing.contains(ObjectIdentifier($0)) && ($0.accessibilityParent() as? NSCell) === cell
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        // AppKit can keep hidden dropdown windows after releasing their unretained AX parent cell.
        for window in dropdownWindows { window.setAccessibilityParent(nil) }
    }
}

/// One native choice supports calendar identities and names entered by hand.
@MainActor
final class SpeakerAssignmentEditor: NSStackView, NSComboBoxDelegate {
    let name = NSTextField(labelWithString: "")
    let link = SpeakerLinkButton()
    let choice: NSComboBox = SpeakerAssignmentChoice()
    var onAssign: ((CalendarParticipant?, String?) throws -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    private let participants: [CalendarParticipant]
    private let inline: Bool
    private var original: String
    private var participantID: String?
    private var saving = false
    private var reverting = false
    private var choosing = false
    private var selectionChanged = false
    private var failedDraft: (text: String, participant: CalendarParticipant?, manual: String?)?
    var isChoosing: Bool { choosing }

    init(speaker: String, title: String, entry: SpeakerNames.Entry?, participants: [CalendarParticipant], canEdit: Bool, inline: Bool) {
        self.participants = participants
        self.inline = inline
        original = entry?.name ?? ""
        participantID = entry?.participantID
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        name.stringValue = entry?.name ?? title
        name.toolTip = name.stringValue
        name.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        name.textColor = StudioStyle.muted
        name.identifier = .init("speaker.name")
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        choice.isEditable = true
        choice.completes = false
        choice.font = .systemFont(ofSize: 12)
        choice.placeholderString = localised("Choose or type a name", "Выберите или введите имя")
        choice.addItems(withObjectValues: [localised("Not matched", "Не сопоставлен")] + participants.map(Self.title))
        if let id = entry?.participantID, let index = participants.firstIndex(where: { $0.id == id }) {
            choice.selectItem(at: index + 1)
            original = Self.title(participants[index])
        }
        choice.stringValue = original
        choice.delegate = self
        choice.identifier = .init("speaker.choice")
        choice.setAccessibilityLabel(localised("Name for ", "Имя для ") + title)
        choice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        choice.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        choice.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        let linked = entry?.participantID.map { id in participants.contains { $0.id == id } } ?? false
        link.title = ""
        link.image = NSImage(systemSymbolName: inline ? "pencil" : "link", accessibilityDescription: nil)
        link.unlinked = !linked
        link.contentTintColor = linked ? StudioStyle.accent : .systemRed
        link.isBordered = false
        link.identifier = .init("speaker.link")
        link.toolTip = linked
            ? localised("Participant linked. Click to change.", "Участник сопоставлен. Нажмите, чтобы изменить.")
            : localised("Participant not linked. Click to match or enter a name.", "Участник не сопоставлен. Нажмите, чтобы выбрать или ввести имя.")
        link.setAccessibilityLabel(link.toolTip)
        link.target = self
        link.action = #selector(beginEditing)
        let enabled = canEdit && !SpeakerNames.isUnknown(speaker)
        link.isEnabled = enabled
        choice.isEnabled = enabled
        setViews([name, choice, link], in: .center)
        name.isHidden = !inline
        choice.isHidden = inline
        link.widthAnchor.constraint(equalToConstant: 22).isActive = true
        link.heightAnchor.constraint(equalToConstant: 22).isActive = true
        link.isHidden = !inline
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func title(_ participant: CalendarParticipant) -> String {
        participant.name + " · " + (participant.email ?? participant.id)
    }
    @objc private func beginEditing() {
        guard choice.isEnabled else { return }
        name.isHidden = true
        choice.isHidden = false
        window?.makeFirstResponder(choice)
        choice.selectText(nil)
    }
    func comboBoxWillPopUp(_ notification: Notification) {
        choosing = true
        failedDraft = nil
        selectionChanged = false
    }
    func comboBoxWillDismiss(_ notification: Notification) {
        let event = NSApp?.currentEvent
        let cancelled = event?.type == .keyDown && event?.keyCode == 53
        // Assignment can rebuild this view; AppKit must finish dismissing its list first.
        Task { @MainActor [self] in
            choosing = false
            if cancelled {
                restoreChoice()
                endEditing()
            } else if selectionChanged {
                commitSelection()
            } else {
                if choice.stringValue == original { restoreChoice() }
                commitText()
            }
            selectionChanged = false
        }
    }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        if choosing { selectionChanged = true; return }
        commitSelection()
    }
    private func commitSelection() {
        guard !choosing, !saving, !reverting, failedDraft == nil else { return }
        let index = choice.indexOfSelectedItem
        guard index >= 0 else { return }
        if index > 0, participantID == participants[index - 1].id,
           original == Self.title(participants[index - 1]) { endEditing(); return }
        save(participant: index > 0 ? participants[index - 1] : nil, manual: nil)
    }
    func controlTextDidEndEditing(_ notification: Notification) { commitText() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !choosing, let onCancel { onCancel(); return true }
            selectionChanged = false
            failedDraft = nil
            restoreChoice()
            endEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if !choosing, let onSubmit { onSubmit(); return true }
            if let failedDraft, failedDraft.text == choice.stringValue {
                self.failedDraft = nil
                save(participant: failedDraft.participant, manual: failedDraft.manual)
            } else { commitText() }
            return true
        }
        return false
    }
    func controlTextDidChange(_ notification: Notification) { failedDraft = nil }
    private func commitText() {
        guard !choosing, !saving, !reverting, failedDraft == nil else { return }
        guard choice.stringValue != original else { endEditing(); return }
        save(participant: nil, manual: choice.stringValue)
    }
    private func save(participant: CalendarParticipant?, manual: String?) {
        guard choice.isEnabled, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try onAssign?(participant, manual)
            participantID = participant?.id
            original = participant.map(Self.title) ?? manual ?? ""
            choice.stringValue = original
            endEditing()
        } catch {
            let draft = participant.map(Self.title) ?? manual ?? ""
            failedDraft = (draft, participant, manual)
            reverting = true
            // Let AppKit finish dismissing its dropdown before presenting an error.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if failedDraft?.text == draft { choice.stringValue = draft }
                reverting = false
                if let window { NSAlert(error: error).beginJournalSheetModal(for: window) }
            }
        }
    }
    private func restoreChoice() {
        reverting = true
        defer { reverting = false }
        if let participantID, let index = participants.firstIndex(where: { $0.id == participantID }) {
            choice.selectItem(at: index + 1)
        } else if choice.indexOfSelectedItem >= 0 {
            choice.deselectItem(at: choice.indexOfSelectedItem)
        }
        choice.stringValue = original
    }
    private func endEditing() {
        if inline { choice.isHidden = true; name.isHidden = false }
    }
}

@MainActor
final class SpeakerLinkButton: NSButton {
    var unlinked = false
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if unlinked {
            NSColor.systemRed.setStroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: bounds.midX - 6, y: bounds.midY - 6))
            slash.line(to: NSPoint(x: bounds.midX + 6, y: bounds.midY + 6))
            slash.lineWidth = 1.5
            slash.stroke()
        }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

@MainActor
final class MeetingSpeakerView: NSStackView {
    let editor: NSView
    init(title: String? = nil, editor: NSView) {
        self.editor = editor
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        if let title {
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: 13, weight: .medium)
            setViews([heading, editor, SetupLayout.hairline()], in: .center)
        } else {
            edgeInsets = .init()
            setViews([editor], in: .center)
        }
        for view in arrangedSubviews { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

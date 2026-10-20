import AppKit

@MainActor
final class LiveTranscriptView: NSView, NSTextFieldDelegate {
    var onRename: ((String) throws -> Void)?
    private let name = NSTextField()
    private var savedTitle = ""
    var title: String {
        get { savedTitle }
        set {
            savedTitle = newValue
            if name.currentEditor() == nil { name.stringValue = newValue }
        }
    }
    init(content: NSView) {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 24, weight: .semibold)
        name.isBordered = false
        name.drawsBackground = false
        name.identifier = .init("recording-title")
        name.setAccessibilityLabel(localised("Current meeting title", "Название текущей встречи"))
        name.delegate = self
        let heading = NSTextField(labelWithString: localised("Real-time transcription", "Расшифровка в реальном времени"))
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: localised(
            "Preliminary text. The final transcript and summary are prepared after the meeting.",
            "Предварительный текст. Полная расшифровка и сводка готовятся после встречи."))
        note.textColor = .secondaryLabelColor
        let sourceNote = NSTextField(wrappingLabelWithString: localised(
            "You and Them describe audio sources, not verified participant names.",
            "«Вы» и «Они» — источники звука, а не подтверждённые имена участников."))
        sourceNote.font = .systemFont(ofSize: 11)
        sourceNote.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [name, heading, note, content, sourceNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            name.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func controlTextDidEndEditing(_ notification: Notification) {
        let proposed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard proposed != savedTitle else { return }
        do {
            try onRename?(proposed)
            title = proposed
        } catch {
            name.stringValue = savedTitle
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }
}

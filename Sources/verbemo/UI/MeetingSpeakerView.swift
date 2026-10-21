import AppKit

@MainActor
final class MeetingSpeakerView: NSStackView {
    private let editor: NSView
    private let button = NSButton()
    init(title: String, subtitle: String, unknown: Bool, editor: NSView) {
        self.editor = editor
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        button.title = title
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.alignment = .left
        button.isBordered = false
        button.image = NSImage(systemSymbolName: unknown ? "questionmark.circle" : "person.crop.circle", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.cell?.lineBreakMode = .byTruncatingTail
        button.target = self
        button.action = #selector(toggleEditor)
        button.setAccessibilityLabel(localised("Edit speaker: ", "Изменить участника: ") + title)
        button.setAccessibilityValue(0)
        let note = JournalStyle.caption(unknown ? localised("Unidentified voice", "Голос не определён") : subtitle)
        setViews([button, note, editor], in: .center)
        editor.isHidden = true
        for view in arrangedSubviews { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggleEditor() {
        editor.isHidden.toggle()
        button.setAccessibilityValue(editor.isHidden ? 0 : 1)
        if !editor.isHidden { window?.recalculateKeyViewLoop() }
    }
}

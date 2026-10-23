import AppKit

/// First-run permissions inside the application window, with a progress note.
@MainActor
final class SetupPage: NSObject {
    /// Whether a recording is in progress. Registering at login and testing
    /// system audio both disturb a running recording, and nothing in this
    /// page is worth losing a meeting for.
    var isRecording: (() -> Bool)? {
        didSet { form.isRecording = isRecording }
    }
    /// Called when the user leaves setup.
    var onFinished: (() -> Void)?

    private let form = SetupForm(mode: .permissions)
    private(set) var contentView = NSView()
    private let footerNote = NSTextField(labelWithString: "")

    override init() {
        super.init()

        let scroll = SetupLayout.scroller(around: form.view)

        footerNote.font = .systemFont(ofSize: 12)
        footerNote.textColor = .secondaryLabelColor
        footerNote.lineBreakMode = .byTruncatingTail

        let footer = NSStackView(views: [footerNote])
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        footerNote.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let divider = SetupLayout.hairline()
        divider.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(divider)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 16),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        contentView = content

        form.onStateChange = { [weak self] in self?.updateFooter() }
        updateFooter()
    }

    func stopForTermination() -> [Task<Void, Never>] { form.stopForTermination() }

    func prepare() {
        if !isVisible { Analytics.track(.setupOpened) }
        form.reload()
    }

    var isVisible: Bool { contentView.window?.isVisible == true }

    /// Permissions remain available in Settings after leaving this page.
    func finish() {
        SetupState.markCompleted()
        form.stop()
        onFinished?()
    }

    private func updateFooter() {
        footerNote.stringValue = form.outstandingSentence
    }
}

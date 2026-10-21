import AppKit

/// First-run permissions inside the application window. The footer offers
/// the next missing permission without blocking access to the rest of the app.
@MainActor
final class SetupPage: NSObject {
    /// Whether a recording is in progress. Registering at login and testing
    /// system audio both disturb a running recording, and nothing in this
    /// page is worth losing a meeting for.
    var isRecording: (() -> Bool)? {
        didSet { form.isRecording = isRecording }
    }
    /// Called when setup is finished or deferred.
    var onFinished: (() -> Void)?

    private let form = SetupForm(mode: .permissions)
    private(set) var contentView = NSView()
    private let footerNote = NSTextField(labelWithString: "")
    private let primary = NSButton(
        title: localised("Done", "Готово"), target: nil, action: nil)

    override init() {
        super.init()

        let scroll = SetupLayout.scroller(around: form.view)

        footerNote.font = .systemFont(ofSize: 12)
        footerNote.textColor = .secondaryLabelColor
        footerNote.lineBreakMode = .byTruncatingTail

        let later = NSButton(
            title: localised("Later", "Позже"), target: self, action: #selector(laterClicked))
        later.bezelStyle = .rounded
        later.identifier = .init("setup.later")
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        primary.target = self
        primary.action = #selector(primaryClicked)

        let footer = NSStackView(views: [footerNote, later, primary])
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

    func prepare() {
        if !isVisible { Analytics.track(.setupOpened) }
        form.reload()
    }

    var isVisible: Bool { contentView.window?.isVisible == true }

    @objc private func laterClicked() {
        finish()
    }

    @objc private func primaryClicked() {
        // The button does the next unfinished thing, and only finishes when
        // there is nothing left it can do from here.
        if let next = form.nextAction {
            next()
            return
        }
        finish()
    }

    /// Permissions remain available in Settings after setup is deferred.
    private func finish() {
        SetupState.markCompleted()
        form.stop()
        onFinished?()
    }

    /// The one line above the buttons, and what the button itself says. Both
    /// are the form's answers — this only arranges them.
    private func updateFooter() {
        footerNote.stringValue = form.outstandingSentence
        primary.title = form.nextActionTitle
        primary.isEnabled = !form.isDownloading
    }
}

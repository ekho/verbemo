import AppKit

/// The small window behind **About Verbemo**: whose program this is, where its
/// source is, and how to ask for one like it.
///
/// Every Mac application has this window and it is always in the same place,
/// which is the whole reason for it — somebody wondering who wrote a thing
/// that has been recording their meetings for a month looks under About
/// before anywhere else. verbemo had nowhere to answer: it runs as
/// `.accessory`, so its application menu is only on screen while one of its
/// windows is in front, and neither the status window nor Settings is a place
/// for a name.
///
/// It says four things and does nothing. A window with an action in it is a
/// window that has to know what the recorder is doing; this one can be opened
/// at any moment of a recording and cost nothing.
@MainActor
final class AboutWindow: NSObject {
    private let panel: NSWindow
    private(set) var contentView = NSView()
    private var linkButtons: [NSButton] = []

    override convenience init() { self.init(hostWindow: nil) }

    init(hostWindow: NSWindow?) {
        panel = hostWindow ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
            // No resize and no minimise: there is nothing in here that a
            // bigger window would show more of.
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        if hostWindow == nil { panel.title = localised("About Verbemo", "О программе Verbemo") }
        panel.isReleasedWhenClosed = false

        let icon = NSImageView()
        icon.image = NSApplication.shared.applicationIconImage
        icon.setAccessibilityLabel("Verbemo")
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 72),
            icon.heightAnchor.constraint(equalToConstant: 72),
        ])

        let name = NSTextField(labelWithString: "Verbemo")
        name.font = .systemFont(ofSize: 22, weight: .semibold)

        let version = NSTextField(labelWithString: Self.versionLine ?? "")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        // A bare `swift run` has no bundle and therefore no version; an empty
        // line would leave a gap where a sentence looks like it went missing.
        version.isHidden = Self.versionLine == nil

        let tagline = NSTextField(labelWithString: localised(
            "Records microphone and call audio, transcribes live and after meetings, separates speakers, and creates summaries with decisions and tasks. Keeps recordings and results on your computer, with a choice of local models or cloud services.",
            "Записывает звук с микрофона и из приложений звонков, расшифровывает речь в реальном времени и после встречи. Разделяет реплики по говорящим и готовит сводку с решениями и задачами. Хранит записи и результаты на компьютере. Для обработки можно выбрать локальные модели или облачные сервисы."))
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center
        tagline.lineBreakMode = .byWordWrapping
        tagline.maximumNumberOfLines = 0
        tagline.preferredMaxLayoutWidth = hostWindow == nil ? 260 : 620

        linkButtons = [
            link(localised("Source code on GitHub", "Исходный код на GitHub"), Self.sourceRepository),
            link(localised("Support", "Поддержка"), Self.supportPage),
            link(localised("Origin and licenses", "Происхождение и лицензии"), Self.originPage),
        ]
        let links = NSStackView(views: linkButtons)
        links.orientation = .vertical
        links.alignment = .centerX
        links.spacing = 4

        let stack = NSStackView(views: [icon, name, version, tagline, links])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        // The links are a group of their own, and the gap above them is what
        // says so.
        stack.setCustomSpacing(18, after: tagline)
        stack.setCustomSpacing(4, after: name)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        contentView = content
        if hostWindow == nil { panel.contentView = content }
        // The height is whatever the words come to. Russian runs a fifth
        // longer than English and the version line is missing from a bare
        // build, so a number written here would be the right one for one of
        // the four windows this can be.
        if hostWindow == nil {
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: Self.width, height: content.fittingSize.height))
        panel.center()
        }
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { panel.isVisible }

    /// What the window says, for the walk that reads every window in both
    /// languages. The title is in here because it is a sentence like the
    /// others, and it is the one that is not inside the content view.
    var view: NSView? { contentView }
    var title: String { panel.title }

    /// The three links, as they read and where they go. The window is
    /// nothing but these, so this is how anything outside checks them.
    var offeredLinks: [(title: String, url: String)] {
        linkButtons.map { ($0.title, $0.identifier?.rawValue ?? "") }
    }

    /// Wide enough for the longest of the three links with room around it,
    /// and no wider: nothing in here is a paragraph.
    private static let width: CGFloat = 340

    static let sourceRepository = "https://github.com/ekho/verbemo"
    static let supportPage = "https://github.com/ekho/verbemo/issues"
    static let originPage = "https://github.com/ekho/verbemo/blob/master/docs/origin.md"

    /// The version, as the bundle knows it. Nil for a bare build, which has
    /// no `Info.plist` to have been stamped by `make app`.
    static var versionLine: String? {
        guard let info = Runtime.appBundle?.infoDictionary,
              let short = info["CFBundleShortVersionString"] as? String
        else { return nil }
        let build = info["CFBundleVersion"] as? String
        let number = build.map { "\(short) (\($0))" } ?? short
        return localised("Version \(number)", "Версия \(number)")
    }

    private func link(_ title: String, _ url: String) -> NSButton {
        SetupLayout.link(title, url, target: self, action: #selector(linkClicked(_:)))
    }

    @objc private func linkClicked(_ sender: NSButton) {
        guard let url = sender.identifier.flatMap({ URL(string: $0.rawValue) }) else { return }
        NSWorkspace.shared.open(url)
    }
}

import AppKit

/// Product information and project links, mounted in the application window.
@MainActor
final class AboutPage: NSObject {
    private(set) var contentView = NSView()
    var onCheckForUpdates: (() -> Void)?
    private let updates = NSButton()
    var updatesAvailable = false { didSet { updates.isHidden = !updatesAvailable } }
    private var linkButtons: [NSButton] = []

    override init() {
        super.init()

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
            "Записывает звук с микрофона и из приложений звонков, расшифровывает речь в реальном времени и после встречи. Выполняет диаризацию и готовит сводку с решениями и задачами. Хранит записи и результаты на компьютере. Для обработки можно выбрать локальные модели или облачные сервисы."))
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .left
        tagline.lineBreakMode = .byWordWrapping
        tagline.maximumNumberOfLines = 0
        tagline.preferredMaxLayoutWidth = 620

        linkButtons = [
            link(localised("Source code on GitHub", "Исходный код на GitHub"), Self.sourceRepository),
            link(localised("Support", "Поддержка"), Self.supportPage),
            link(localised("Origin and licenses", "Происхождение и лицензии"), Self.originPage),
        ]
        updates.title = localised("Check for updates…", "Проверить обновления…")
        updates.bezelStyle = .rounded
        updates.target = self
        updates.action = #selector(checkForUpdatesClicked)
        updates.identifier = .init("about.checkUpdates")
        updates.isHidden = true
        let links = NSStackView(views: [updates] + linkButtons)
        links.orientation = .vertical
        links.alignment = .leading
        links.spacing = 18

        let identity = NSStackView(views: [name, version])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 6
        let heading = NSStackView(views: [icon, identity])
        heading.spacing = 24
        heading.alignment = .centerY
        let stack = NSStackView(views: [heading, tagline, links])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        // The links are a group of their own, and the gap above them is what
        // says so.
        stack.setCustomSpacing(18, after: tagline)
        stack.translatesAutoresizingMaskIntoConstraints = false
        tagline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tagline.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let content = FlippedStackView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        contentView = content
    }

    /// The three links, as they read and where they go.
    var offeredLinks: [(title: String, url: String)] {
        linkButtons.map { ($0.title, $0.identifier?.rawValue ?? "") }
    }

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

    @objc private func checkForUpdatesClicked() { onCheckForUpdates?() }

    private func link(_ title: String, _ url: String) -> NSButton {
        SetupLayout.link(title, url, target: self, action: #selector(linkClicked(_:)))
    }

    @objc private func linkClicked(_ sender: NSButton) {
        guard let url = sender.identifier.flatMap({ URL(string: $0.rawValue) }) else { return }
        NSWorkspace.shared.open(url)
    }
}

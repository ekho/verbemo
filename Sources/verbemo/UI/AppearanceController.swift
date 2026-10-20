import AppKit

@MainActor
final class AppearanceController {
    enum Theme: String { case system, light, dark }
    private weak var window: NSWindow?
    private var watch: ConfigWatch.Token?
    private(set) var theme = Theme.system
    init(window: NSWindow) {
        self.window = window
        apply()
        watch = ConfigWatch.observe { [weak self] in self?.apply() }
    }
    private func apply() {
        guard !Config.settingsUnknown else { return }
        theme = Theme(rawValue: Config.interfaceTheme()) ?? .system
        let appearance: NSAppearance? = switch theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        NSApplication.shared.appearance = appearance
        window?.appearance = appearance
    }
}

import AppKit

@MainActor
final class SidebarView: JournalSurface {
    private let libraryHost = NSView()

    init() {
        super.init(StudioStyle.sidebar)
        identifier = .init("journal.sidebar")
        libraryHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(libraryHost)
        NSLayoutConstraint.activate([
            libraryHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            libraryHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            libraryHost.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            libraryHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func mountLibrary(_ view: NSView) {
        guard view.superview !== libraryHost else { return }
        libraryHost.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        libraryHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: libraryHost.leadingAnchor), view.trailingAnchor.constraint(equalTo: libraryHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: libraryHost.topAnchor), view.bottomAnchor.constraint(equalTo: libraryHost.bottomAnchor),
        ])
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           (event.characters?.lowercased() == "f" || event.charactersIgnoringModifiers?.lowercased() == "f") {
            if (window as? WorkspaceWindow)?.onFindMeeting?() == true { return true }
            guard let search = libraryHost.journalSearchField else { return false }
            window?.makeFirstResponder(search)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private extension NSView {
    var journalSearchField: NSSearchField? {
        if let search = self as? NSSearchField { return search }
        return subviews.lazy.compactMap(\.journalSearchField).first
    }
}

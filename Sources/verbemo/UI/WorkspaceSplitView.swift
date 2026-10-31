import AppKit

@MainActor
final class WorkspaceSplitController: NSSplitViewController {
    let libraryItem: NSSplitViewItem

    init(sidebar: NSView, content: NSView) {
        let library = NSViewController(); library.view = sidebar
        let document = NSViewController(); document.view = content
        libraryItem = NSSplitViewItem(viewController: library)
        libraryItem.minimumThickness = 220
        libraryItem.maximumThickness = 480
        libraryItem.holdingPriority = .init(260)
        libraryItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        let documentItem = NSSplitViewItem(viewController: document)
        documentItem.minimumThickness = 420
        super.init(nibName: nil, bundle: nil)
        let split = WorkspaceSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.identifier = .init("workspace.library-split")
        split.setAccessibilityLabel(localised("Meeting library width", "Ширина библиотеки встреч"))
        split.setAccessibilityHelp(localised("Drag the divider or use left/right arrows", "Перетащите разделитель или используйте стрелки влево/вправо"))
        splitView = split
        addSplitViewItem(libraryItem)
        addSplitViewItem(documentItem)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class WorkspaceSplitView: NSSplitView {
    private var maximumWidth: CGFloat { max(220, min(480, bounds.width - 420 - dividerThickness)) }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard let sidebar = arrangedSubviews.first, !sidebar.isHidden else { return super.keyDown(with: event) }
        let width: CGFloat
        switch event.keyCode {
        case 123: width = sidebar.frame.width - 16
        case 124: width = sidebar.frame.width + 16
        case 115: width = 220
        case 119: width = maximumWidth
        default: return super.keyDown(with: event)
        }
        setPosition(max(220, min(maximumWidth, width)), ofDividerAt: 0)
    }
}

@MainActor
final class WorkspaceWindow: NSWindow {
    var onFindMeeting: (() -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           (event.characters?.lowercased() == "f" || event.charactersIgnoringModifiers?.lowercased() == "f"),
           onFindMeeting?() == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

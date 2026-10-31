import AppKit

@MainActor
final class WorkspaceSplitView: NSSplitView, NSSplitViewDelegate {
    init(sidebar: NSView, content: NSView) {
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        identifier = .init("workspace.library-split")
        for view in [sidebar, content] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addArrangedSubview(view)
        }
        setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        setAccessibilityLabel(localised("Meeting library width", "Ширина библиотеки встреч"))
        setAccessibilityHelp(localised("Drag the divider or use left/right arrows", "Перетащите разделитель или используйте стрелки влево/вправо"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawDivider(in rect: NSRect) {
        if subviews.first?.isHidden != true { super.drawDivider(in: rect) }
    }
    private var maximumWidth: CGFloat { max(220, min(480, bounds.width - 420 - dividerThickness)) }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 220 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { maximumWidth }
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(220, min(maximumWidth, proposedPosition))
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { subview === subviews.first }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { subviews.first?.isHidden == true }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        needsDisplay = true
        guard subviews.count == 2 else { return super.resizeSubviews(withOldSize: oldSize) }
        let sidebar = subviews[0], content = subviews[1]
        if sidebar.isHidden { sidebar.frame = .zero; content.frame = bounds; return }
        let previousWidth = sidebar.frame.width > 0 ? sidebar.frame.width : JournalStyle.sidebarWidth
        let width = max(220, min(maximumWidth, previousWidth))
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        content.frame = NSRect(x: width + dividerThickness, y: 0,
                               width: max(0, bounds.width - width - dividerThickness), height: bounds.height)
    }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard let sidebar = subviews.first, !sidebar.isHidden else { return super.keyDown(with: event) }
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

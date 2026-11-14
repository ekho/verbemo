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
    override var dividerColor: NSColor { StudioStyle.line }
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
final class InspectorDivider: NSView {
    var onResize: ((CGFloat) -> Void)?
    private var width: CGFloat = 270
    private var maximum: CGFloat = 480
    private var dragStart: (x: CGFloat, width: CGFloat)?

    init() {
        super.init(frame: .zero)
        identifier = .init("meeting.inspector-divider")
        widthAnchor.constraint(equalToConstant: 7).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityOrientation(.vertical)
        setAccessibilityLabel(localised("Meeting details width", "Ширина деталей встречи"))
        toolTip = localised("Drag or use left/right arrows to resize meeting details", "Перетащите или используйте стрелки влево/вправо для изменения ширины деталей")
        setAccessibilityHelp(toolTip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func draw(_ dirtyRect: NSRect) {
        StudioStyle.line.setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
        (window?.firstResponder === self ? StudioStyle.accent : StudioStyle.muted).setFill()
        NSBezierPath(roundedRect: .init(x: bounds.midX - 1.5, y: bounds.midY - 16, width: 3, height: 32), xRadius: 1.5, yRadius: 1.5).fill()
    }
    func update(width: CGFloat, maximum: CGFloat) {
        self.width = width
        self.maximum = maximum
        super.setAccessibilityValue(NSNumber(value: Double(width)))
        setAccessibilityMinValue(270)
        setAccessibilityMaxValue(NSNumber(value: Double(maximum)))
    }
    private func resize(to proposed: CGFloat) {
        guard !isHiddenOrHasHiddenAncestor, proposed.isFinite else { return }
        onResize?(max(270, min(maximum, proposed)))
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    override func setAccessibilityValue(_ value: Any?) {
        if let number = value as? NSNumber { resize(to: CGFloat(number.doubleValue)) }
    }
    override func accessibilityPerformIncrement() -> Bool { resize(to: width + 16); return true }
    override func accessibilityPerformDecrement() -> Bool { resize(to: width - 16); return true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = (event.locationInWindow.x, width)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        resize(to: dragStart.width + dragStart.x - event.locationInWindow.x)
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: resize(to: width + 16)
        case 124: resize(to: width - 16)
        case 115: resize(to: 270)
        case 119: resize(to: maximum)
        default: super.keyDown(with: event)
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
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

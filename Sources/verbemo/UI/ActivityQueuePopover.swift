import AppKit

@MainActor
final class ActivityQueuePopover: NSObject, NSPopoverDelegate {
    private struct Job: Equatable {
        let run: ProcessingOperations.Snapshot
        let title: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.run.id == rhs.run.id && lhs.run.kind == rhs.run.kind
                && lhs.run.state == rhs.run.state && lhs.title == rhs.title
        }
    }

    @MainActor
    private struct Row {
        let job: Job
        let confirming: Bool
        let pending: Bool
        let view: NSView
        let divider = SetupLayout.hairline()
    }

    let view = JournalSurface(JournalStyle.paper)
    var onOpenProcessing: (() -> Void)?
    var onChange: (() -> Void)?
    var onResult: ((String) -> Void)?
    private let operations: ProcessingOperations
    private let popover = NSPopover()
    private let rows = NSStackView()
    private let runningHeading = NSTextField(labelWithString: localised("Running", "В работе"))
    private let waitingHeading = NSTextField(labelWithString: localised("Waiting", "Ожидают"))
    private let empty = NSTextField(labelWithString: localised("The queue is empty.", "Очередь пуста."))
    private let counts = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let processing = NSButton()
    private weak var anchor: NSButton?
    private lazy var scroll = SetupLayout.scroller(around: rows)
    private lazy var scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 42)
    private var jobs: [Job] = []
    private var displayedRows: [UUID: Row] = [:]
    private var confirming: UUID?
    private var pending: Set<UUID> = []
    private var stopping = false
    private let width: CGFloat = 420

    init(operations: ProcessingOperations) {
        self.operations = operations
        super.init()
        view.identifier = .init("activity.queue-popover")
        let title = NSTextField(labelWithString: localised("Task queue", "Очередь задач"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = JournalStyle.ink
        counts.font = .systemFont(ofSize: 11)
        counts.textColor = JournalStyle.muted
        let heading = NSStackView(views: [title, counts])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.identifier = .init("activity.queue-close")
        closeButton.setAccessibilityLabel(localised("Close task queue", "Закрыть очередь задач"))
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        let header = NSStackView(views: [heading, SetupLayout.spacer(), closeButton])
        header.alignment = .centerY
        header.heightAnchor.constraint(equalToConstant: 42).isActive = true

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 5
        scroll.identifier = .init("activity.queue-list")
        scrollHeight.isActive = true

        processing.attributedTitle = NSAttributedString(
            string: localised("Open Processing", "Открыть обработку"),
            attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 12)])
        processing.isBordered = false
        processing.identifier = .init("activity.queue-processing")
        processing.target = self
        processing.action = #selector(openProcessing)
        processing.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let footer = NSStackView(views: [processing, SetupLayout.spacer()])
        let stack = NSStackView(views: [header, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        let controller = NSViewController()
        controller.view = view
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        for heading in [runningHeading, waitingHeading] {
            heading.font = .systemFont(ofSize: 11, weight: .semibold)
            heading.textColor = JournalStyle.muted
        }
        empty.textColor = JournalStyle.muted
    }

    func update(_ work: ActivityWork, title: (URL) -> String) {
        let next = work.jobs.map { Job(run: $0, title: $0.session.map(title) ?? localised("Import", "Импорт")) }
        guard next != jobs else { return }
        jobs = next
        if !jobs.contains(where: { $0.run.id == confirming && $0.run.state == .running }) { confirming = nil }
        if popover.isShown { render() }
    }

    func toggle(from button: NSButton) {
        guard !stopping, button.window != nil else { return }
        if popover.isShown { closeClicked(); return }
        anchor = button
        render()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        view.window?.makeFirstResponder(closeButton)
    }

    func stop() {
        stopping = true
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) { confirming = nil }

    @objc private func closeClicked() {
        popover.close()
        if let anchor { anchor.window?.makeFirstResponder(anchor) }
    }

    @objc private func openProcessing() {
        closeClicked()
        onOpenProcessing?()
    }

    private func render(focus: NSUserInterfaceItemIdentifier? = nil) {
        let firstResponder = view.window?.firstResponder as? NSView
        let rowHadFocus = firstResponder?.isDescendant(of: rows) == true
        let focusID = focus ?? (rowHadFocus ? firstResponder?.identifier : nil)
        let origin = scroll.contentView.bounds.origin
        let running = jobs.filter { $0.run.state != .waiting }
        let waiting = jobs.filter { $0.run.state == .waiting }
        counts.stringValue = localised("Running \(running.count) · Waiting \(waiting.count)",
                                       "В работе \(running.count) · Ожидают \(waiting.count)")
        let ids = Set(jobs.map { $0.run.id })
        displayedRows = displayedRows.filter { ids.contains($0.key) }
        var content: [NSView] = []
        for (heading, group) in [(runningHeading, running), (waitingHeading, waiting)] where !group.isEmpty {
            content.append(heading)
            for job in group {
                let row = row(for: job)
                content.append(row.view)
                content.append(row.divider)
            }
        }
        updateRows(content.isEmpty ? [empty] : content)
        scrollHeight.constant = min(264, max(42, rows.fittingSize.height))
        let size = NSSize(width: width, height: 110 + scrollHeight.constant)
        popover.contentViewController?.preferredContentSize = size
        popover.contentSize = size
        view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(
            NSRect(origin: origin, size: scroll.contentView.bounds.size)).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        if let focusID {
            let button = content.lazy.compactMap { ($0 as? NSStackView)?.arrangedSubviews.first { $0.identifier == focusID } }.first
            if firstResponder !== button || button == nil { view.window?.makeFirstResponder(button ?? processing) }
        }
    }

    private func updateRows(_ desired: [NSView]) {
        let retained = Set(desired.map(ObjectIdentifier.init))
        for child in rows.arrangedSubviews where !retained.contains(ObjectIdentifier(child)) {
            rows.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        for (index, child) in desired.enumerated() {
            let current = rows.arrangedSubviews
            if current.indices.contains(index), current[index] === child { continue }
            if child.superview === rows {
                rows.removeArrangedSubview(child)
                child.removeFromSuperview()
            }
            rows.insertArrangedSubview(child, at: index)
            child.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    private func row(for job: Job) -> Row {
        let id = job.run.id
        let isConfirming = confirming == id
        let isPending = pending.contains(id)
        if let row = displayedRows[id], row.job == job, row.confirming == isConfirming, row.pending == isPending { return row }
        let row = Row(job: job, confirming: isConfirming, pending: isPending, view: makeRow(job))
        displayedRows[id] = row
        return row
    }

    private func makeRow(_ job: Job) -> NSView {
        let run = job.run
        let kind = ActivityWork.kindTitle(run.kind)
        let title = NSTextField(labelWithString: job.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = JournalStyle.ink
        title.toolTip = job.title
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stage = NSTextField(labelWithString: kind)
        stage.font = .systemFont(ofSize: 11)
        stage.textColor = JournalStyle.muted
        let labels = NSStackView(views: [title, stage])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let row = NSStackView(views: [labels, SetupLayout.spacer()])
        row.alignment = .centerY
        row.spacing = 6
        if run.state == .cancelling || pending.contains(run.id) {
            let status = NSTextField(labelWithString: localised("Cancelling…", "Отменяется…"))
            status.font = .systemFont(ofSize: 11)
            status.textColor = JournalStyle.muted
            row.addArrangedSubview(status)
        } else if run.state == .waiting {
            let remove = QueueActionButton(localised("Remove", "Убрать"), id: "remove", run: run.id) { [weak self] in
                self?.request(job, remove: true)
            }
            remove.setAccessibilityLabel(localised("Remove \(job.title), \(kind), from queue", "Убрать из очереди: \(job.title), \(kind)"))
            row.addArrangedSubview(remove)
        } else if confirming == run.id {
            let keep = QueueActionButton(localised("Continue", "Продолжить"), id: "keep", run: run.id) { [weak self] in
                self?.confirming = nil
                self?.render(focus: .init("activity.queue-cancel.\(run.id)"))
            }
            let cancel = QueueActionButton(localised("Cancel task", "Отменить задание"), id: "confirm", run: run.id) { [weak self] in
                self?.request(job, remove: false)
            }
            cancel.contentTintColor = .systemRed
            cancel.setAccessibilityLabel(localised("Confirm cancellation of \(job.title), \(kind)", "Подтвердить отмену: \(job.title), \(kind)"))
            row.addArrangedSubview(keep)
            row.addArrangedSubview(cancel)
        } else {
            let cancel = QueueActionButton(localised("Cancel…", "Отменить…"), id: "cancel", run: run.id) { [weak self] in
                self?.confirming = run.id
                self?.render(focus: .init("activity.queue-keep.\(run.id)"))
            }
            cancel.contentTintColor = .systemRed
            cancel.setAccessibilityLabel(localised("Cancel \(job.title), \(kind)", "Отменить: \(job.title), \(kind)"))
            row.addArrangedSubview(cancel)
        }
        return row
    }

    private func request(_ job: Job, remove: Bool) {
        let run = job.run
        guard !stopping, pending.insert(run.id).inserted else { return }
        confirming = nil
        render()
        Task { [weak self, operations] in
            let result = if remove { await operations.removeWaiting(run) }
                else { await operations.cancelAndWait(run) }
            guard let self, !stopping else { return }
            pending.remove(run.id)
            onChange?()
            if popover.isShown { render() }
            let outcome: String
            switch result {
            case .cancelled where remove && run.kind == .importMedia:
                outcome = localised("Import removed from the queue.", "Импорт убран из очереди.")
            case .cancelled where remove:
                outcome = localised("Removed from the current queue. Automatic processing may add it again.",
                                    "Убрано из текущей очереди. Автообработка может добавить задание снова.")
            case .cancelled:
                outcome = localised("Task cancelled. Completed results are preserved.",
                                    "Задание отменено. Готовые результаты сохранены.")
            case .completed:
                outcome = localised("The task completed before cancellation.", "Задание успело завершиться.")
            case .failed(let reason):
                outcome = localised("Task failed. \(reason)", "Задание завершилось с ошибкой. \(reason)")
            case nil:
                outcome = localised("Task status changed. Check the queue for available actions.",
                                    "Состояние задания изменилось. Проверьте доступные действия в очереди.")
            }
            let subject = run.session == nil ? job.title : "\(job.title) · \(ActivityWork.kindTitle(run.kind))"
            onResult?("\(subject) · \(outcome)")
        }
    }
}

@MainActor
private final class QueueActionButton: NSButton {
    private let invoke: () -> Void

    init(_ title: String, id: String, run: UUID, invoke: @escaping () -> Void) {
        self.invoke = invoke
        super.init(frame: .zero)
        self.title = title
        identifier = .init("activity.queue-\(id).\(run)")
        bezelStyle = .rounded
        setContentCompressionResistancePriority(.required, for: .horizontal)
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    @objc private func pressed() { invoke() }
}

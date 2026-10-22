import AppKit

/// One event selector for the recording draft and the saved meeting inspector.
@MainActor
final class CalendarEventPicker: NSStackView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    typealias Loader = (CalendarEventQuery) async throws -> [CalendarWatcher.Meeting]
    typealias Resolver = (CalendarWatcher.Meeting) async throws -> CalendarWatcher.Meeting
    var loadEvents: Loader?
    var resolveEvent: Resolver?
    var onSelect: ((CalendarWatcher.Meeting?) throws -> Void)?
    let button = NSButton()
    let clear = NSButton()
    let search = NSSearchField()
    let date = NSDatePicker()
    let status = NSTextField(wrappingLabelWithString: "")
    let table = NSTableView()
    private let access = NSButton()
    private let popover = NSPopover()
    private var task: Task<Void, Never>?
    private var contextID: String?
    private(set) var meetings: [CalendarWatcher.Meeting] = []
    private(set) var selectedMeeting: CalendarWatcher.Meeting?

    init() {
        super.init(frame: .zero)
        spacing = 6
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        button.imagePosition = .imageTrailing
        button.alignment = .left
        button.cell?.lineBreakMode = .byTruncatingTail
        button.identifier = .init("calendar.choose")
        button.setAccessibilityLabel(localised("Choose calendar event", "Выбрать событие календаря"))
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.target = self; button.action = #selector(open)
        clear.bezelStyle = .rounded
        clear.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        clear.imagePosition = .imageOnly
        clear.identifier = .init("calendar.clear")
        clear.toolTip = localised("Unlink calendar event", "Снять связь с событием календаря")
        clear.setAccessibilityLabel(clear.toolTip)
        clear.target = self; clear.action = #selector(clearSelection)
        addArrangedSubview(button); addArrangedSubview(clear)
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        clear.widthAnchor.constraint(equalToConstant: 30).isActive = true
        clear.heightAnchor.constraint(equalToConstant: 30).isActive = true
        setSelection(nil)

        search.placeholderString = localised("Title or date (DD.MM.YYYY)", "Название или дата (ДД.ММ.ГГГГ)")
        search.setAccessibilityLabel(search.placeholderString)
        search.identifier = .init("calendar.search")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        date.datePickerStyle = .textFieldAndStepper
        date.datePickerElements = .yearMonthDay
        date.setAccessibilityLabel(localised("Event date", "Дата события"))
        date.identifier = .init("calendar.date")
        date.target = self; date.action = #selector(dateChanged)
        let dateRow = NSStackView(views: [NSTextField(labelWithString: localised("Date", "Дата")), SetupLayout.spacer(), date])
        let column = NSTableColumn(identifier: .init("event"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.style = .fullWidth
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(chooseRow)
        table.identifier = .init("calendar.results")
        table.setAccessibilityLabel(localised("Calendar events", "События календаря"))
        let scroller = NSScrollView()
        scroller.documentView = table
        scroller.hasVerticalScroller = true
        scroller.drawsBackground = false
        scroller.heightAnchor.constraint(equalToConstant: 240).isActive = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.identifier = .init("calendar.search-status")
        access.title = localised("Allow access in macOS…", "Разрешить доступ в macOS…")
        access.bezelStyle = .rounded
        access.target = self; access.action = #selector(openPermissions)
        access.isHidden = true
        let fields = NSStackView(views: [search, dateRow, scroller, status, access])
        fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 10
        fields.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        fields.widthAnchor.constraint(equalToConstant: 410).isActive = true
        for view in [search, dateRow, scroller, status] as [NSView] {
            view.widthAnchor.constraint(equalTo: fields.widthAnchor, constant: -28).isActive = true
        }
        let controller = NSViewController(); controller.view = fields
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(date: Date, snapshot: MeetingCalendarMetadata?, contextID: String, enabled: Bool = true) {
        if self.contextID != contextID {
            cancel()
            self.contextID = contextID
            self.date.dateValue = date
            search.stringValue = ""
        }
        button.title = snapshot?.title ?? localised("Choose event…", "Выбрать событие…")
        button.toolTip = snapshot.map { $0.title + "\n" + MeetingCalendarView.dateLine($0) }
        clear.isHidden = snapshot == nil
        button.isEnabled = enabled
        clear.isEnabled = enabled
        if !enabled { cancel() }
    }
    func setSelection(_ meeting: CalendarWatcher.Meeting?) {
        selectedMeeting = meeting
        button.title = meeting?.title ?? localised("Choose event…", "Выбрать событие…")
        clear.isHidden = meeting == nil
    }
    @objc func open() {
        guard button.isEnabled, button.window != nil else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(search)
        reload()
    }
    func reload(debounce: Bool = false) {
        task?.cancel()
        meetings = []; table.reloadData()
        status.stringValue = localised("Loading calendar events…", "Загрузка событий календаря…")
        access.isHidden = true
        let query = CalendarEventQuery(date: date.dateValue, text: search.stringValue)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(250)) }
                guard let loadEvents else { throw CalendarSelectionError.accessDenied }
                let result = try await loadEvents(query)
                guard !Task.isCancelled else { return }
                meetings = result
                table.reloadData()
                let from = String(MeetingPresentation.date(query.range.start).prefix(10))
                let to = String(MeetingPresentation.date(query.range.end.addingTimeInterval(-1)).prefix(10))
                let range = from == to ? from : from + " – " + to
                status.stringValue = (result.isEmpty ? localised("No events found. ", "События не найдены. ") : "")
                    + range + " · " + TimeZone.current.identifier
            } catch {
                guard !Task.isCancelled else { return }
                show(error)
            }
        }
    }
    func settled() async { await task?.value }
    func cancel() { task?.cancel(); popover.close() }
    func controlTextDidChange(_ obj: Notification) { reload(debounce: true) }
    @objc private func dateChanged() { search.stringValue = ""; reload() }
    @objc private func openPermissions() { SetupPermissions.openSettings(.calendar) }
    @objc func clearSelection() {
        task?.cancel()
        do { try onSelect?(nil); setSelection(nil); popover.close() }
        catch { present(error) }
    }
    @objc private func chooseRow() {
        guard meetings.indices.contains(table.selectedRow) else { return }
        choose(meetings[table.selectedRow])
    }
    func choose(_ meeting: CalendarWatcher.Meeting) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let current = try await resolveEvent?(meeting) ?? meeting
                guard !Task.isCancelled else { return }
                try onSelect?(current)
                setSelection(current)
                popover.close()
            } catch {
                guard !Task.isCancelled else { return }
                present(error)
            }
        }
    }
    private func show(_ error: Error) {
        status.stringValue = error.localizedDescription
        access.isHidden = (error as? CalendarSelectionError) != .accessDenied
    }
    private func present(_ error: Error) {
        show(error)
        if !popover.isShown, let window { NSAlert(error: error).beginSheetModal(for: window) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { meetings.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let event = meetings[row]
        let title = NSTextField(labelWithString: event.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let snapshot = MeetingCalendarMetadata(MeetingContext(meeting: event, app: nil).metaFields["calendar"] as? [String: Any] ?? [:])
        let detail = NSTextField(labelWithString: [snapshot.map { MeetingCalendarView.dateLine($0) }, event.calendarTitle].compactMap { $0 }.joined(separator: " · "))
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let cell = NSStackView(views: [title, detail])
        cell.orientation = .vertical; cell.alignment = .leading; cell.spacing = 3
        cell.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        for field in [title, detail] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.widthAnchor.constraint(equalTo: cell.widthAnchor, constant: -16).isActive = true
        }
        cell.toolTip = event.title + "\n" + detail.stringValue
        return cell
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): cancel(); return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !meetings.isEmpty else { return true }
            let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = max(0, min(meetings.count - 1, table.selectedRow + step))
            table.selectRowIndexes([row], byExtendingSelection: false); table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)): chooseRow(); return true
        default: return false
        }
    }
}

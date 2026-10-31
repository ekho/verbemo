import AppKit

/// Reuse native rows so a long meeting does not create thousands of controls at once.
@MainActor
final class MeetingTranscriptView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    var onPlayFrom: ((TimeInterval) -> Void)?
    var onAssign: ((String, CalendarParticipant?, String?) throws -> Void)?
    struct ReadingPosition { let segment: Int; let offset: CGFloat }
    private var searchRanges: [Int: [NSRange]] = [:]
    private var focusedSearch: (segment: Int, range: NSRange)?
    func readingPosition() -> ReadingPosition? {
        let rows = table.rows(in: documentVisibleRect)
        guard rows.location != NSNotFound, rows.length > 0 else { return nil }
        return .init(segment: rows.location, offset: documentVisibleRect.minY - table.rect(ofRow: rows.location).minY)
    }
    func restoreReadingPosition(_ position: ReadingPosition?) {
        guard let position, segments.indices.contains(position.segment) else { return }
        table.layoutSubtreeIfNeeded()
        let row = table.rect(ofRow: position.segment)
        let y = row.minY + max(0, min(position.offset, row.height - 1))
        contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, table.bounds.height - contentView.bounds.height))))
        reflectScrolledClipView(contentView)
    }
    func setSearch(matches: [Int: [NSRange]], focusedSegment: Int? = nil, focusedRange: NSRange? = nil) {
        let nextFocus = focusedSegment.flatMap { segment in focusedRange.map { (segment: segment, range: $0) } }
        guard searchRanges != matches || focusedSearch?.segment != nextFocus?.segment || focusedSearch?.range != nextFocus?.range else { return }
        let position = readingPosition()
        searchRanges = matches
        focusedSearch = nextFocus
        table.reloadData()
        restoreReadingPosition(position)
    }
    func revealSearchSegment(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        table.scrollRowToVisible(index)
    }
    private let table = NSTableView()
    private var segments: [Transcript.Segment] = []
    private var names: SpeakerNames?
    private var participants: [CalendarParticipant] = []
    private var canEdit = false
    private var canPlay = false
    private var canMatchParticipants = true
    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        table.addTableColumn(NSTableColumn(identifier: .init("utterance")))
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = StudioStyle.line
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(localised("Transcript and speaker assignments", "Расшифровка и сопоставление участников"))
        documentView = table
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setFrameSize(_ newSize: NSSize) {
        let position = abs(newSize.width - frame.width) > 0.5 ? readingPosition() : nil
        super.setFrameSize(newSize)
        restoreReadingPosition(position)
    }
    func update(transcript: Transcript, names: SpeakerNames?, participants: [CalendarParticipant], canEdit: Bool, canPlay: Bool = false, canMatchParticipants: Bool = true) {
        let changed = segments != transcript.segments || self.names?.speakers != names?.speakers
            || self.participants != participants || self.canEdit != canEdit
            || self.canPlay != canPlay || self.canMatchParticipants != canMatchParticipants
        segments = transcript.segments
        self.names = names
        self.participants = participants
        self.canEdit = canEdit
        self.canPlay = canPlay
        self.canMatchParticipants = canMatchParticipants
        if changed { table.reloadData() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { segments.count }
    func tableViewColumnDidResize(_ notification: Notification) {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(segments.indices))
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let available = tableView.tableColumns[0].width - 16
        let width = SegmentCell.textWidth(available)
        let rect = (segments[row].text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 15)])
        return (available >= 590 ? max(52, ceil(rect.height)) : ceil(rect.height) + 60) + 20
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("utterance")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SegmentCell) ?? SegmentCell()
        cell.identifier = id
        let segment = segments[row]
        cell.time.title = String(format: "%02d:%02d", segment.start_ms / 60_000, (segment.start_ms / 1000) % 60)
        cell.time.tag = row
        cell.time.target = self
        cell.time.action = #selector(playFrom(_:))
        cell.time.isEnabled = canPlay
        cell.time.toolTip = localised("Play from \(cell.time.title)", "Воспроизвести с \(cell.time.title)")
        cell.time.setAccessibilityLabel(cell.time.toolTip)
        let text = NSMutableAttributedString(string: segment.text, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: StudioStyle.ink])
        for range in searchRanges[row] ?? [] where NSMaxRange(range) <= text.length {
            let active = focusedSearch?.segment == row && focusedSearch?.range == range
            text.addAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor.withAlphaComponent(active ? 0.65 : 0.25), range: range)
        }
        cell.body.attributedStringValue = text
        let title = Self.speakerTitle(segment.speaker, in: segments)
        let entry = SpeakerNames.isUnknown(segment.speaker) ? nil : names?.speakers[segment.speaker]
        cell.name.stringValue = entry?.name ?? title
        cell.name.toolTip = cell.name.stringValue
        cell.voice.stringValue = StudioStyle.voiceLabel(segment.speaker)
        cell.voice.setAccessibilityLabel(localised("Voice ", "Голос ") + cell.voice.stringValue)
        cell.edit.isEnabled = canEdit && !SpeakerNames.isUnknown(segment.speaker)
        cell.edit.toolTip = localised("Change speaker: ", "Изменить говорящего: ") + cell.name.stringValue
        cell.edit.setAccessibilityLabel(cell.edit.toolTip)
        cell.edit.onRestoreFocus = { [weak self] in
            guard let self, self.segments.indices.contains(row), self.segments[row] == segment else { return }
            self.table.layoutSubtreeIfNeeded()
            if let cell = self.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SegmentCell {
                self.window?.makeFirstResponder(cell.edit)
            }
        }
        cell.edit.makeEditor = { [weak self] in
            guard let self else { return nil }
            let choices = self.canMatchParticipants || segment.speaker == "me" ? self.participants : []
            let editable = self.canEdit && !SpeakerNames.isUnknown(segment.speaker)
            let currentEntry = SpeakerNames.isUnknown(segment.speaker) ? nil : self.names?.speakers[segment.speaker]
            let assign = self.onAssign
            let editor = SpeakerAssignmentPopover(speaker: segment.speaker, title: title, entry: currentEntry,
                                                  participants: choices, canEdit: editable)
            editor.onAssign = { participant, name in try assign?(segment.speaker, participant, name) }
            return editor
        }
        cell.updateWidth(tableView.tableColumns[0].width - 16)
        return cell
    }
    @objc private func playFrom(_ sender: NSButton) {
        guard canPlay, segments.indices.contains(sender.tag) else { return }
        onPlayFrom?(Double(segments[sender.tag].start_ms) / 1000)
    }
    static func speakerTitle(_ speaker: String, in segments: [Transcript.Segment]) -> String {
        if SpeakerNames.isUnknown(speaker) { return SpeakerNames.described(label: speaker) }
        if speaker == "me" { return SpeakerNames.described(label: speaker) }
        var labels: [String] = []
        for segment in segments where !SpeakerNames.isUnknown(segment.speaker) && !labels.contains(segment.speaker) { labels.append(segment.speaker) }
        let number = (labels.firstIndex(of: speaker) ?? 0) + 1
        return localised("Speaker \(number)", "Говорящий \(number)")
    }
}

@MainActor
private final class SegmentCell: NSTableCellView {
    let time = NSButton(title: "", target: nil, action: nil)
    let body = NSTextField(wrappingLabelWithString: "")
    let name = NSTextField(labelWithString: "")
    let voice = StudioStyle.voiceBadge("")
    let edit = SpeakerEditButton()
    private let metadata = NSStackView()
    private let stack = NSStackView()
    private var metadataWidth: NSLayoutConstraint!
    private var bodyWidth: NSLayoutConstraint!
    static func textWidth(_ available: CGFloat) -> CGFloat { max(160, available >= 590 ? available - 206 : available) }
    init() {
        super.init(frame: .zero)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.isBordered = false
        time.image = NSImage(systemSymbolName: "play", accessibilityDescription: nil)
        time.imagePosition = .imageLeading
        time.contentTintColor = StudioStyle.muted
        time.identifier = .init("transcript.playFrom")
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = StudioStyle.ink
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.font = .systemFont(ofSize: 15)
        body.isSelectable = true
        body.identifier = .init("transcript.words")
        let identity = NSStackView(views: [voice, name, edit])
        identity.spacing = 6
        metadata.setViews([identity, time], in: .center)
        metadata.orientation = .vertical
        metadata.alignment = .leading
        metadata.spacing = 4
        identity.widthAnchor.constraint(equalTo: metadata.widthAnchor).isActive = true
        stack.setViews([metadata, body], in: .center)
        stack.alignment = .top
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        metadataWidth = metadata.widthAnchor.constraint(equalToConstant: 190)
        bodyWidth = body.widthAnchor.constraint(equalTo: stack.widthAnchor)
        bodyWidth.isActive = true
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }
    func updateWidth(_ available: CGFloat) {
        let wide = available >= 590
        stack.orientation = wide ? .horizontal : .vertical
        stack.alignment = wide ? .top : .leading
        stack.spacing = wide ? 16 : 8
        metadataWidth.isActive = wide
        bodyWidth.constant = wide ? -206 : 0
        let width = Self.textWidth(available)
        if abs(body.preferredMaxLayoutWidth - width) > 0.5 { body.preferredMaxLayoutWidth = width }
    }
    override func layout() { updateWidth(bounds.width - 16); super.layout() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

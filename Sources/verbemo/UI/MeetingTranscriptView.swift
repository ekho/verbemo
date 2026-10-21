import AppKit

/// Reuse native rows so a long meeting does not create thousands of controls at once.
@MainActor
final class MeetingTranscriptView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    var onMap: ((String, CalendarParticipant?) throws -> Void)?
    private let table = NSTableView()
    private var segments: [Transcript.Segment] = []
    private var names: SpeakerNames?
    private var participants: [CalendarParticipant] = []
    private var canEdit = false
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
        table.intercellSpacing = NSSize(width: 0, height: 18)
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(localised("Transcript and speaker assignments", "Расшифровка и сопоставление участников"))
        documentView = table
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(transcript: Transcript, names: SpeakerNames?, participants: [CalendarParticipant], canEdit: Bool) {
        segments = transcript.segments
        self.names = names
        self.participants = participants
        self.canEdit = canEdit
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { segments.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let width = max(160, tableView.tableColumns[0].width - 20)
        let rect = (segments[row].text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 14)])
        return max(78, ceil(rect.height) + 42)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("utterance")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SegmentCell) ?? SegmentCell()
        cell.identifier = id
        let segment = segments[row]
        cell.time.stringValue = String(format: "%02d:%02d", segment.start_ms / 60_000, (segment.start_ms / 1000) % 60)
        cell.body.stringValue = segment.text
        cell.body.preferredMaxLayoutWidth = max(160, tableView.tableColumns[0].width - 20)
        Self.configureParticipants(cell.person, speaker: segment.speaker, names: names,
                                   participants: participants, fallback: Self.speakerTitle(segment.speaker, in: segments))
        cell.person.tag = row
        cell.person.target = self
        cell.person.action = #selector(mapped(_:))
        cell.person.isEnabled = canEdit
        cell.person.setAccessibilityLabel(localised("Who is speaking at \(cell.time.stringValue)?", "Кто говорит в \(cell.time.stringValue)?"))
        return cell
    }
    @objc private func mapped(_ sender: NSPopUpButton) {
        guard canEdit, segments.indices.contains(sender.tag) else { return }
        let id = sender.selectedItem?.representedObject as? String
        let participant = participants.first { $0.id == id }
        do { try onMap?(segments[sender.tag].speaker, participant) }
        catch { if let window { NSAlert(error: error).beginSheetModal(for: window) }; table.reloadData() }
    }
    static func speakerTitle(_ speaker: String, in segments: [Transcript.Segment]) -> String {
        if SpeakerNames.isUnknown(speaker) { return SpeakerNames.described(label: speaker) }
        var labels: [String] = []
        for segment in segments where !SpeakerNames.isUnknown(segment.speaker) && !labels.contains(segment.speaker) { labels.append(segment.speaker) }
        let number = (labels.firstIndex(of: speaker) ?? 0) + 1
        return localised("Speaker \(number)", "Говорящий \(number)")
    }
    static func configureParticipants(_ popup: NSPopUpButton, speaker: String, names: SpeakerNames?, participants: [CalendarParticipant], fallback: String) {
        popup.removeAllItems()
        let entry = names?.speakers[speaker]
        let manual = entry?.participantID == nil ? entry?.name : entry?.manualName
        popup.addItem(withTitle: (manual ?? fallback) + localised(" · not matched", " · не сопоставлен"))
        for participant in participants {
            popup.addItem(withTitle: participant.name + (participant.email.map { " · " + $0 } ?? ""))
            popup.lastItem?.representedObject = participant.id
        }
        if let id = entry?.participantID, let index = popup.itemArray.firstIndex(where: { $0.representedObject as? String == id }) { popup.selectItem(at: index) }
    }
}

@MainActor
private final class SegmentCell: NSTableCellView {
    let time = NSTextField(labelWithString: "")
    let person = NSPopUpButton()
    let body = NSTextField(wrappingLabelWithString: "")
    init() {
        super.init(frame: .zero)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .secondaryLabelColor
        body.font = .systemFont(ofSize: 14)
        body.isSelectable = true
        person.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let head = NSStackView(views: [time, person])
        head.spacing = 12
        let stack = NSStackView(views: [head, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            head.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

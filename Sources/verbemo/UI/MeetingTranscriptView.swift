import AppKit

/// Reuse native rows so a long meeting does not create thousands of controls at once.
@MainActor
final class MeetingTranscriptView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    var onPlayFrom: ((TimeInterval) -> Void)?
    var onAssign: ((String, CalendarParticipant?, String?) throws -> Void)?
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
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(localised("Transcript and speaker assignments", "Расшифровка и сопоставление участников"))
        documentView = table
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(transcript: Transcript, names: SpeakerNames?, participants: [CalendarParticipant], canEdit: Bool, canPlay: Bool = false, canMatchParticipants: Bool = true) {
        segments = transcript.segments
        self.names = names
        self.participants = participants
        self.canEdit = canEdit
        self.canPlay = canPlay
        self.canMatchParticipants = canMatchParticipants
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { segments.count }
    func tableViewColumnDidResize(_ notification: Notification) {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(segments.indices))
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let width = max(160, tableView.tableColumns[0].width - 20)
        let rect = (segments[row].text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 14)])
        return max(54, ceil(rect.height) + 36)
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
        cell.body.stringValue = segment.text
        cell.body.preferredMaxLayoutWidth = max(160, tableView.tableColumns[0].width - 20)
        let editor = SpeakerAssignmentEditor(speaker: segment.speaker, title: Self.speakerTitle(segment.speaker, in: segments),
            entry: SpeakerNames.isUnknown(segment.speaker) ? nil : names?.speakers[segment.speaker],
            participants: canMatchParticipants || segment.speaker == "me" ? participants : [], canEdit: canEdit, inline: true)
        let assign = onAssign
        editor.onAssign = { participant, name in try assign?(segment.speaker, participant, name) }
        cell.setEditor(editor)
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
    private let head = NSStackView()
    private var editor: NSView?
    init() {
        super.init(frame: .zero)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.isBordered = false
        time.contentTintColor = JournalStyle.accent
        time.identifier = .init("transcript.playFrom")
        body.font = .systemFont(ofSize: 14)
        body.isSelectable = true
        head.addArrangedSubview(time)
        head.spacing = 12
        let stack = NSStackView(views: [head, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
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
    func setEditor(_ view: NSView) {
        if let editor { head.removeArrangedSubview(editor); editor.removeFromSuperview() }
        editor = view
        head.addArrangedSubview(view)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

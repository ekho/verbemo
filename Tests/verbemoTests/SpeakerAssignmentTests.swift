import AppKit
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome) @MainActor
struct SpeakerAssignmentTests {
    @Test func participantsHaveTheirOwnTabWithVisibleEditors() throws {
        let root = Home.current.url.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try SessionFixture.make()
        let dir = root.appendingPathComponent("meeting")
        try FileManager.default.moveItem(at: fixture, to: dir)
        let app = ApplicationWindow()
        defer { app.hide() }
        let library = MeetingLibraryController(root: root, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.navigate(.allMeetings)
        let views = library.contentView.allDescendants
        let button = try #require(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "meeting.result.participants" })
        #expect(button.sendAction(button.action, to: button.target))
        let inspector = try #require(views.first { $0.identifier?.rawValue == "meeting.inspector-content" })
        #expect(!inspector.allDescendants.contains { $0 is MeetingSpeakerView })
        let editor = try #require(library.contentView.allDescendants.compactMap { $0 as? NSComboBox }.first)
        #expect(!editor.isHiddenOrHasHiddenAncestor)
        #expect(editor.isEnabled)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        if let output = ProcessInfo.processInfo.environment["VERBEMO_SPEAKER_SNAPSHOT"] {
            app.panel.setContentSize(NSSize(width: 1100, height: 760))
            app.panel.contentView?.layoutSubtreeIfNeeded()
            let content = try #require(app.panel.contentView)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
        withExtendedLifetime(library) {}
    }

    @Test func transcriptNamesAreTextUntilTheLinkButtonIsClicked() throws {
        let view = MeetingTranscriptView()
        let transcript = Transcript(engine: "whisper", model: "test", created_at: "", segments: [
            .init(speaker: "them A", start_ms: 1000, end_ms: 2000, text: "Hello"),
        ])
        view.update(transcript: transcript, names: nil, participants: [], canEdit: true)
        let table = try #require(view.documentView as? NSTableView)
        let row = try #require(view.tableView(table, viewFor: table.tableColumns[0], row: 0))
        let link = try #require(row.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "speaker.link" })
        #expect(link.contentTintColor == .systemRed)
        #expect(link.toolTip?.isEmpty == false)
        let name = try #require(row.allDescendants.first { $0.identifier?.rawValue == "speaker.name" })
        let editor = try #require(row.allDescendants.compactMap { $0 as? NSComboBox }.first)
        #expect(!name.isHidden)
        #expect(editor.isHiddenOrHasHiddenAncestor)
        #expect(link.sendAction(link.action, to: link.target))
        #expect(name.isHidden)
        #expect(!editor.isHiddenOrHasHiddenAncestor)
        #expect(editor.isEditable)
    }

    @Test(.freshHome(config: #"{"user_email":"  OWNER@Example.test ","user_name":"My name"}"#))
    func emailLinksOnlyTheKnownOwnerAndHonorsManualUnlink() throws {
        let dir = try SessionFixture.make(meta: ["calendar": [
            "event_id": "event", "association": "confirmed", "participants": [
                ["id": "owner", "name": "Calendar name", "email": "owner@example.test"],
            ],
        ]])
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = try #require(SpeakerNames.read(from: dir))
        #expect(names.speakers["me"]?.participantID == "owner")
        #expect(names.speakers["me"]?.name == "My name")
        #expect(names.speakers["them A"]?.participantID == nil)
        try PostProcessor.setSpeakerParticipant("me", participant: nil, in: dir)
        #expect(SpeakerNames.read(from: dir)?.speakers["me"]?.participantID == nil)
        #expect(SpeakerNames.read(from: dir)?.speakers["me"]?.name == "My name")
    }

    @Test(.freshHome(config: #"{"user_email":"owner@example.test"}"#))
    func ambiguousOrUnconfirmedEmailNeverLinks() throws {
        for association in ["candidate", "confirmed"] {
            let dir = try SessionFixture.make(meta: ["calendar": [
                "event_id": "event", "association": association, "participants": [
                    ["id": "one", "name": "One", "email": "owner@example.test"],
                    ["id": "two", "name": "Two", "email": "OWNER@example.test"],
                ],
            ]])
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(SpeakerNames.read(from: dir)?.speakers["me"]?.participantID == nil)
        }
    }

    @Test func editableChoiceSavesTheSelectedIdentityAndFreeTextOnce() throws {
        let participants = [CalendarParticipant(id: "one", name: "Alex", email: "one@example.test"),
                            CalendarParticipant(id: "two", name: "Alex", email: "two@example.test")]
        let editor = SpeakerAssignmentEditor(speaker: "them A", title: "Speaker 1", entry: nil,
            participants: participants, canEdit: true, inline: false)
        var saves: [(String?, String?)] = []
        editor.onAssign = { saves.append(($0?.id, $1)) }
        editor.choice.selectItem(at: 2)
        editor.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification))
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(saves.count == 1)
        #expect(saves.first?.0 == "two")
        editor.choice.stringValue = "Free name"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(saves.count == 2)
        #expect(saves.last?.0 == nil)
        #expect(saves.last?.1 == "Free name")
        editor.choice.stringValue = "Discard"
        #expect(editor.control(editor.choice, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(saves.count == 2)
        #expect(editor.choice.stringValue == "Free name")
    }

    @Test func customNamesReplaceCalendarLinksAtomicallyAndCanBeCleared() throws {
        let dir = try SessionFixture.make(meta: ["calendar": ["event_id": "event", "association": "confirmed",
            "participants": [["id": "anna", "name": "Anna"]]]])
        defer { try? FileManager.default.removeItem(at: dir) }
        try PostProcessor.setSpeakerParticipant("them A", participant: .init(id: "anna", name: "Anna"), in: dir)
        let raw = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        try PostProcessor.setSpeakerParticipant("them A", participant: nil, name: " Custom name ", in: dir)
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.participantID == nil)
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.name == "Custom name")
        #expect(try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8).contains("Custom name"))
        try PostProcessor.setSpeakerParticipant("them A", participant: nil, name: "", in: dir)
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.name == nil)
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == raw)
    }

    @Test func failedSelectionDoesNotTurnIntoAManualNameOnFocusLoss() async {
        let editor = SpeakerAssignmentEditor(speaker: "them A", title: "Speaker 1",
            entry: .init(name: "Original", source: .manual),
            participants: [.init(id: "anna", name: "Anna")], canEdit: true, inline: false)
        var attempts = 0
        editor.onAssign = { _, _ in attempts += 1; throw CocoaError(.fileWriteUnknown) }
        editor.choice.selectItem(at: 1)
        editor.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification))
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        await Task.yield()
        #expect(editor.choice.stringValue == "Original")
        #expect(attempts == 1)
    }
}

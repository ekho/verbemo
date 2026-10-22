import Foundation
import AppKit
import Testing
@testable import verbemo

struct MeetingCalendarMetadataTests {
    @Test func legacyAndCandidatesNeverClaimAConfirmedAssociation() throws {
        let legacy = MeetingCalendarMetadata(["title": "Planning", "attendees": ["Anna"], "link": "https://call.example"])
        #expect(legacy?.isConfirmed == false)
        #expect(legacy?.eventURL == nil)
        #expect(MeetingCalendarMetadata(["association": "confirmed", "title": "No identity"])?.isConfirmed == false)
        let candidate = MeetingCalendarMetadata(["event_id": "event", "association": "candidate", "title": "Planning", "agenda": "  "])
        #expect(candidate?.isConfirmed == false)
        #expect(candidate?.agenda == nil)
    }
    @Test func snapshotKeepsDuplicateNamesDistinctAndRejectsUnsafeLinks() throws {
        let meta = try #require(MeetingCalendarMetadata(["schema_version": 2, "event_id": "event", "association": "confirmed", "title": "Planning", "event_url": "file:///tmp/private", "participants": [["id": "a", "name": "Alex", "email": "a@example.test"], ["id": "b", "name": "Alex"]], "future": 42]))
        #expect(meta.isConfirmed)
        #expect(meta.participants.map(\.id) == ["a", "b"])
        #expect(meta.eventURL == nil)
    }
    @Test @MainActor func matchedEventIsLinkedWithoutExplicitConfirmation() {
        var event = CalendarWatcher.Meeting(id: "event", title: "Planning", start: Date(), end: Date().addingTimeInterval(600), attendees: ["Anna"], link: "https://call.example", looksLikeCall: true)
        event.timeZoneIdentifier = "America/New_York"
        let linked = MeetingContext(meeting: event, app: nil)
        #expect(MeetingCalendarMetadata(linked.metaFields["calendar"] as? [String: Any] ?? [:])?.isConfirmed == true)
        #expect(MeetingCalendarMetadata(linked.metaFields["calendar"] as? [String: Any] ?? [:])?.timeZoneIdentifier == "America/New_York")
    }
    @Test @MainActor func missingOrUnidentifiedEventsDoNotCreateALink() {
        #expect(MeetingContext(meeting: nil, app: nil).metaFields["calendar"] == nil)
        for (id, persistent) in [("temporary", false), ("", true)] {
            var event = CalendarWatcher.Meeting(id: id, title: "Planning", start: Date(), end: Date().addingTimeInterval(600), attendees: [], link: nil, looksLikeCall: true)
            event.hasPersistentID = persistent
            let context = MeetingContext(meeting: event, app: nil)
            let snapshot = MeetingCalendarMetadata(context.metaFields["calendar"] as? [String: Any] ?? [:])
            #expect(snapshot?.isConfirmed == false)
            #expect(snapshot?.association == nil)
        }
    }
}

@Suite(.serialized)
struct SpeakerParticipantMappingTests {
    @Test(.freshHome) func pendingReplacementCannotReceiveParticipantMapping() throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("whisper".utf8).write(to: dir.appendingPathComponent(TranscriptVersions.requestFile))
        #expect(throws: (any Error).self) { try PostProcessor.setSpeakerParticipant("them A", participant: .init(id: "anna", name: "Anna"), in: dir) }
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.participantID == nil)
    }
    private func session() throws -> URL {
        try SessionFixture.make(meta: ["calendar": ["schema_version": 2, "event_id": "event", "association": "confirmed", "title": "Planning", "agenda": "LOCAL_ONLY", "participants": [["id": "anna", "name": "Anna", "email": "private@example.test"]]]])
    }
    @Test(.freshHome) func mappingAndUnlinkPreserveIndependentManualName() throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        PostProcessor.rename("them A", to: "Manual name", in: dir)
        let person = CalendarParticipant(id: "anna", name: "Anna")
        try PostProcessor.setSpeakerParticipant("them A", participant: person, in: dir)
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.participantID == "anna")
        #expect(try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8).contains("Anna"))
        try PostProcessor.setSpeakerParticipant("them A", participant: nil, in: dir)
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.name == "Manual name")
        #expect(!SessionClaim.isHeld(dir))
    }
    @Test(.freshHome) func mappingIsVersionScopedAndRejectsForeignParticipantsAndBusySessions() throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archived = try #require(try TranscriptVersions.archiveCurrent(dir))
        let person = CalendarParticipant(id: "anna", name: "Anna")
        try Transcript(engine: "whisper", model: "new", created_at: "2026-10-20T10:00:00Z", segments: SessionFixture.meeting).write(to: dir)
        try PostProcessor.setSpeakerParticipant("them A", participant: person, in: archived)
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.participantID == nil)
        #expect(throws: (any Error).self) { try PostProcessor.setSpeakerParticipant("missing speaker", participant: person, in: dir) }
        #expect(throws: (any Error).self) { try PostProcessor.setSpeakerParticipant("them A", participant: .init(id: "stranger", name: "Anna"), in: dir) }
        try SessionClaim.acquire(dir, stage: .finish)
        defer { SessionClaim.release(dir) }
        #expect(throws: (any Error).self) { try PostProcessor.setSpeakerParticipant("them A", participant: person, in: dir) }
    }
    @Test(.freshHome) func archivedDirectoryCannotPointOutsideTheMeeting() throws {
        let dir = try session()
        let outside = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: outside) }
        try Transcript(engine: "whisper", model: "outside", created_at: "2026-10-20T10:00:00Z", segments: SessionFixture.meeting).write(to: outside)
        let archives = dir.appendingPathComponent("transcripts")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        let link = archives.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try PostProcessor.setSpeakerParticipant("them A", participant: .init(id: "anna", name: "Anna"), in: link) }
        #expect(SpeakerNames.read(from: outside) == nil)
    }
    @Test(.freshHome) func newGenerationDoesNotInheritCalendarIdentities() throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PostProcessor.setSpeakerParticipant("them A", participant: .init(id: "anna", name: "Anna"), in: dir)
        let replacement = Transcript(engine: "assemblyai", model: "new", created_at: "2026-10-20T10:00:00Z", segments: SessionFixture.meeting)
        try TranscriptVersions.commit(replacement, to: dir)
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.participantID == nil)
    }

}

@Suite(.serialized) @MainActor
struct MeetingCalendarViewTests {
    @Test func htmlAgendaRendersFormattingAndLinksBeforeTruncation() throws {
        let view = MeetingCalendarView()
        view.update(MeetingCalendarMetadata([
            "event_id": "html", "association": "confirmed", "title": "Planning",
            "agenda": "<p><b>План</b> &amp; <i>цели</i><br><a href=\"https://example.test/agenda\">Документ</a></p><ul><li>Обсуждение</li></ul>",
        ]))
        let field = try #require(view.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "calendar.agenda" })
        let text = field.attributedStringValue
        #expect(text.string.components(separatedBy: .newlines).prefix(2) == ["План & цели", "Документ"])
        #expect(text.string.contains("Обсуждение"))
        #expect(!text.string.contains("<"))
        #expect(!view.allDescendants.contains { $0.identifier?.rawValue == "calendar.expand-agenda" })
        let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let link = (text.string as NSString).range(of: "Документ")
        try #require(link.location != NSNotFound)
        #expect(text.attribute(.link, at: link.location, effectiveRange: nil) as? URL == URL(string: "https://example.test/agenda"))
    }

    @Test func longHtmlAgendaExpandsAndCollapsesRenderedText() throws {
        let view = MeetingCalendarView()
        let notes = String(repeating: "Тема 👩🏽‍💻 встречи ", count: 12).trimmingCharacters(in: .whitespaces)
        view.update(MeetingCalendarMetadata([
            "event_id": "html", "association": "confirmed", "agenda": "<b>\(notes)</b>",
        ]))
        func field() throws -> NSTextField {
            try #require(view.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "calendar.agenda" })
        }
        let preview = try field().stringValue
        #expect(preview.count <= 100 && !preview.contains("<"))
        for expected in [notes, preview] {
            let button = try #require(view.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "calendar.expand-agenda" })
            #expect(button.sendAction(button.action, to: button.target))
            #expect(try field().stringValue == expected)
            let font = try #require(try field().attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        }
    }

    @Test func plainAgendaKeepsLiteralCharactersAndNewlines() throws {
        let view = MeetingCalendarView()
        let notes = "План: 2 < 3 & 5 > 4\n**буквально** <person@example.test>"
        view.update(MeetingCalendarMetadata(["event_id": "plain", "association": "confirmed", "agenda": notes]))
        let field = try #require(view.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "calendar.agenda" })
        #expect(field.stringValue == notes)
    }

    @Test func htmlAgendaIgnoresActiveContentAndUnsafeLinks() {
        let text = CalendarAgenda.render("""
            <p style="background:url(https://example.test/track)">Текст<script>hidden()</script>
            <img src="https://example.test/pixel"><iframe src="https://example.test">hidden</iframe>
            <a href="file:///private/data">Файл</a><a href="javascript:alert(1)">Скрипт</a>
            <b>Незакрытый &nbsp; &#128512;
            """)
        #expect(text.string.contains("Текст"))
        #expect(text.string.contains("Незакрытый"))
        #expect(text.string.contains("😀"))
        #expect(!text.string.contains("hidden"))
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
            #expect(attributes[.link] == nil)
            #expect(attributes[.attachment] == nil)
        }
    }

    @Test func agendaPreviewKeepsWholeWordsAtTheBoundary() {
        let word = String(repeating: "я", count: 98)
        #expect(MeetingCalendarView.agendaPreview(word + " и далее") == word + " и")
        #expect(MeetingCalendarView.agendaPreview(word + " слово") == word)
        #expect(MeetingCalendarView.agendaPreview(String(repeating: "я", count: 101)).isEmpty)
    }

    @Test(.speaking(.russian), arguments: [5, 10]) func agendaAndInviteesStartVisibleAndExpandIndependently(participantCount: Int) throws {
        let view = MeetingCalendarView()
        let agenda = String(repeating: "План встречи ", count: 10).trimmingCharacters(in: .whitespaces)
        let metadata = try #require(MeetingCalendarMetadata([
            "event_id": "event", "association": "confirmed", "title": "Планирование", "agenda": agenda,
            "participants": (1...participantCount).map { ["id": "p\($0)", "name": "Участник \($0)"] },
        ]))
        var opens = 0
        view.onOpen = { opens += 1 }
        view.update(metadata)
        func button(_ id: String) throws -> NSButton {
            try #require(view.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id })
        }
        func field(_ id: String) throws -> NSTextField {
            try #require(view.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id })
        }
        let title = try button("calendar.open")
        #expect(title.title == "Планирование")
        _ = NSApplication.shared.sendAction(try #require(title.action), to: title.target, from: title)
        #expect(opens == 1)
        let preview = try field("calendar.agenda")
        #expect(!preview.isHiddenOrHasHiddenAncestor)
        #expect(preview.stringValue == String(agenda.prefix(100)).split(separator: " ").dropLast().joined(separator: " "))
        let invitees = try field("calendar.invitees")
        #expect(invitees.stringValue.components(separatedBy: "\n").count == 4)
        let expandAgenda = try button("calendar.expand-agenda")
        _ = NSApplication.shared.sendAction(try #require(expandAgenda.action), to: expandAgenda.target, from: expandAgenda)
        #expect(try field("calendar.agenda").stringValue == agenda)
        #expect(try field("calendar.invitees").stringValue.components(separatedBy: "\n").count == 4)
        let expandPeople = try button("calendar.expand-invitees")
        #expect(expandPeople.title == "Показать всех")
        _ = NSApplication.shared.sendAction(try #require(expandPeople.action), to: expandPeople.target, from: expandPeople)
        #expect(try field("calendar.invitees").stringValue.components(separatedBy: "\n").count == participantCount)
        view.update(metadata)
        #expect(try field("calendar.agenda").stringValue == agenda)
        view.update(MeetingCalendarMetadata(["event_id": "another", "association": "confirmed", "agenda": agenda, "title": "Other"]))
        #expect(try field("calendar.agenda").stringValue.count <= 100)
    }

    @Test func shortAgendaAndFourPeopleNeedNoExpansion() throws {
        let view = MeetingCalendarView()
        for length in [0, 99, 100] {
            let agenda = String(repeating: "я", count: length)
            view.update(MeetingCalendarMetadata([
                "event_id": "event", "association": "confirmed", "title": "Planning", "agenda": agenda,
                "participants": (1...4).map { ["id": "p\($0)", "name": "Person \($0)"] },
            ]))
            #expect(!view.allDescendants.contains { $0.identifier?.rawValue == "calendar.expand-agenda" })
            #expect(!view.allDescendants.contains { $0.identifier?.rawValue == "calendar.expand-invitees" })
            if length > 0 {
                let text = try #require(view.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "calendar.agenda" })
                #expect(text.stringValue == agenda)
            }
        }
    }

    @Test func candidateUsesTheSharedPickerAndNeverOpensTheCallAsACalendar() throws {
        let view = MeetingCalendarView()
        view.update(MeetingCalendarMetadata(["event_id": "event", "association": "candidate", "title": "Planning", "link": "https://call.example"]))
        let buttons = view.allDescendants.compactMap { $0 as? NSButton }
        #expect(!buttons.contains { $0.identifier?.rawValue == "calendar.confirm" })
        #expect(!buttons.contains { $0.identifier?.rawValue == "calendar.open" })
        view.update(nil)
        #expect(view.isHidden)
    }
    @Test func transcriptUsesReusableRowsAndMatchesPeopleByID() {
        let view = MeetingTranscriptView()
        view.update(transcript: SessionFixture.transcript, names: nil,
            participants: [.init(id: "a", name: "Alex"), .init(id: "b", name: "Alex")], canEdit: true)
        let table = view.allDescendants.compactMap { $0 as? NSTableView }.first
        #expect(table?.numberOfRows == SessionFixture.meeting.count)
    }
}

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
    @Test @MainActor func recordingTriggerDecidesWhetherTheEventIsConfirmed() {
        let event = CalendarWatcher.Meeting(id: "event", title: "Planning", start: Date(), end: Date().addingTimeInterval(600), attendees: ["Anna"], link: "https://call.example", looksLikeCall: true)
        let candidate = MeetingContext(meeting: event, app: nil)
        let linked = MeetingContext(meeting: event, app: nil, confirmed: true)
        #expect(MeetingCalendarMetadata(candidate.metaFields["calendar"] as? [String: Any] ?? [:])?.isConfirmed == false)
        #expect(MeetingCalendarMetadata(linked.metaFields["calendar"] as? [String: Any] ?? [:])?.isConfirmed == true)
    }
}

@Suite(.serialized)
struct SpeakerParticipantMappingTests {
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
    @Test func candidateNeedsConfirmationAndNeverOpensTheCallAsACalendar() throws {
        let view = MeetingCalendarView()
        view.update(MeetingCalendarMetadata(["event_id": "event", "association": "candidate", "title": "Planning", "link": "https://call.example"]))
        let buttons = view.allDescendants.compactMap { $0 as? NSButton }
        #expect(buttons.contains { $0.identifier?.rawValue == "calendar.confirm" })
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

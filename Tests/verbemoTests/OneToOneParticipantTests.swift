import Foundation
import Testing
@testable import verbemo

@Suite(.serialized, .freshHome(config: #"{"user_email":[" OWNER@example.test ","work@example.test"]}"#))
struct OneToOneParticipantTests {
    private func session(labels: [String] = ["me", "them A"], association: String = "confirmed",
                         emails: [String] = ["owner@example.test", "guest@example.test"]) throws -> URL {
        try SessionFixture.make(segments: labels.enumerated().map {
            .init(speaker: $0.element, start_ms: $0.offset * 1000, end_ms: ($0.offset + 1) * 1000, text: "Hello")
        }, meta: ["calendar": ["event_id": "event", "association": association,
            "participants": emails.enumerated().map { ["id": "p\($0.offset)", "name": "Person \($0.offset)", "email": $0.element] }]])
    }

    @Test(arguments: [["me", "them A"], ["me", "them"], ["them A"]])
    func linksTheOnlyRemoteVoiceAndPersistsIt(labels: [String]) throws {
        let dir = try session(labels: labels)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let names = try #require(SpeakerNames.read(from: dir))
        let label = try #require(labels.last)
        #expect(names.speakers[label]?.participantID == "p1")
        #expect(names.speakers[label]?.name == "Person 1")
        try names.write(to: dir)
        let stored = try JSONDecoder().decode(SpeakerNames.self, from: Data(contentsOf: dir.appendingPathComponent("speakers.json")))
        #expect(stored.speakers[label]?.participantID == "p1")
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == raw)
    }

    @Test func manualChoicesAndExplicitUnlinkWin() throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PostProcessor.setSpeakerParticipant("them A", participant: nil, name: "Manual", in: dir)
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.name == "Manual")
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.participantID == nil)
        try PostProcessor.setSpeakerParticipant("them A", participant: .init(id: "p1", name: "Person 1"), in: dir)
        try PostProcessor.setSpeakerParticipant("them A", participant: nil, name: "", in: dir)
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.participantID == nil)
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.name == nil)
    }

    @Test func manualOwnerNameDoesNotBlockPeerMatchingButAConflictingIdentityDoes() throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PostProcessor.setSpeakerParticipant("me", participant: nil, name: "Manual owner", in: dir)
        #expect(SpeakerNames.read(from: dir)?.speakers["me"]?.name == "Manual owner")
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.participantID == "p1")
        try PostProcessor.setSpeakerParticipant("me", participant: .init(id: "p1", name: "Person 1"), in: dir)
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.participantID == nil)
        let markdown = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(!markdown.contains("them A → Person 1"))
    }

    @Test func ambiguousInvitationsOrVoicesStayUnmatched() throws {
        for (labels, association, emails) in [
            (["me", "them A", "them B"], "confirmed", ["owner@example.test", "guest@example.test"]),
            (["me", "them ?"], "confirmed", ["owner@example.test", "guest@example.test"]),
            (["speaker A", "speaker B"], "confirmed", ["owner@example.test", "guest@example.test"]),
            (["me", "them A"], "candidate", ["owner@example.test", "guest@example.test"]),
            (["me", "them A"], "confirmed", ["owner@example.test", "work@example.test"]),
            (["me", "them A"], "confirmed", ["other@example.test", "guest@example.test"]),
            (["me", "them A"], "confirmed", ["owner@example.test", "guest@example.test", "third@example.test"]),
        ] {
            let dir = try session(labels: labels, association: association, emails: emails)
            defer { try? FileManager.default.removeItem(at: dir) }
            for label in labels where label != "me" {
                #expect(SpeakerNames.read(from: dir)?.speakers[label]?.participantID == nil)
            }
        }
    }

    @Test func localDiarizationMustCompleteBeforeMatching() throws {
        let dir = try session(labels: ["me", "them"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = try #require(PostProcessor.readTranscript(dir))
        try Transcript(engine: "whisper", model: "test", created_at: transcript.created_at, segments: transcript.segments).write(to: dir)
        #expect(SpeakerNames.read(from: dir)?.speakers["them"]?.participantID == nil)
        for status: DiarizationState.Status in [.pending, .running, .failed, .skipped, .completed] {
            try DiarizationState(request: .init(engine: "whisper", threshold: 0.5), status: status).write(to: dir)
            #expect(SpeakerNames.read(from: dir)?.speakers["them"]?.participantID == (status == .completed ? "p1" : nil))
        }
    }

    @Test func calendarChangesRecomputeOnlyAutomaticLinksInEachVersion() throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SpeakerNames.read(from: dir)?.write(to: dir)
        let archive = try #require(try TranscriptVersions.archiveCurrent(dir))
        try SessionState.amend(dir, with: ["calendar": ["event_id": "replacement", "association": "confirmed", "participants": [
            ["id": "p0", "name": "Owner", "email": "owner@example.test"],
            ["id": "new", "name": "New guest", "email": "new@example.test"],
        ]]])
        #expect(SpeakerNames.read(from: archive)?.speakers["them A"]?.participantID == "new")
        try SessionState.amend(dir, with: ["calendar": nil])
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.participantID == nil)
        #expect(SpeakerNames.read(from: archive)?.speakers["them A"]?.participantID == nil)
    }
}

import Foundation
import Testing
import CallIntegrations
@testable import KTalkIntegration

struct KTalkAudioTests {
    private let track = #"{"run":"test","type":"track","id":"p1","generation":1,"rate":48000,"participant":{"id":"p1","name":"Same name","isLocal":false,"isGuest":true,"microphoneMuted":false}}"#

    @Test func decodesParticipantPCMWithoutChangingItsClockOrIdentity() throws {
        var decoder = KTalkAudioDecoder(runID: "test")
        guard case .track(let source) = try decoder.receive(track) else {
            Issue.record("Expected participant descriptor"); return
        }
        #expect(source.participant.name == "Same name")
        #expect(source.participant.id == "p1")
        guard case .audio(let chunk) = try decoder.receive(#"{"run":"test","type":"audio","id":"p1","generation":1,"rate":48000,"frame":96000,"pcm":"AAAAAAAAAD8AAAC/"}"#) else {
            Issue.record("Expected PCM"); return
        }
        #expect(chunk.samples == [0, 0.5, -0.5])
        #expect(chunk.frameStart == 96000)
        #expect(chunk.trackID == "p1")
    }

    @Test func rejectsUnsafePCMAndUnknownSources() throws {
        for payload in [
            #"{"run":"test","type":"audio","id":"p1","generation":1,"rate":48000,"frame":-1,"pcm":"AAAAAA=="}"#,
            #"{"run":"test","type":"audio","id":"p1","generation":1,"rate":48000,"frame":0,"pcm":"AADAfw=="}"#,
            #"{"run":"test","type":"audio","id":"other","generation":1,"rate":48000,"frame":0,"pcm":"AAAAAA=="}"#,
            #"{"run":"test","type":"audio","id":"p1","generation":2,"rate":48000,"frame":0,"pcm":"AAAAAA=="}"#,
            #"{"run":"test","type":"audio","id":"p1","generation":1,"rate":44100,"frame":0,"pcm":"AAAAAA=="}"#,
            #"{"run":"test","type":"audio","id":"p1","generation":1,"rate":48000,"frame":0,"pcm":"AA=="}"#,
        ] {
            var decoder = KTalkAudioDecoder(runID: "test")
            _ = try decoder.receive(track)
            #expect(throws: (any Error).self) { try decoder.receive(payload) }
        }
        var decoder = KTalkAudioDecoder(runID: "test")
        _ = try decoder.receive(track)
        let oversized = Data(repeating: 0, count: 4 * 4097).base64EncodedString()
        #expect(throws: (any Error).self) {
            try decoder.receive("{\"run\":\"test\",\"type\":\"audio\",\"id\":\"p1\",\"generation\":1,\"rate\":48000,\"frame\":0,\"pcm\":\"\(oversized)\"}")
        }
    }

    @Test func distinguishesReplacementRemovalAndAnOldCaptureRun() throws {
        var decoder = KTalkAudioDecoder(runID: "test")
        _ = try decoder.receive(track)
        _ = try decoder.receive(#"{"run":"test","type":"audio","id":"p1","generation":1,"rate":48000,"frame":100,"pcm":"AAAAAA=="}"#)
        #expect(throws: (any Error).self) {
            try decoder.receive(#"{"run":"test","type":"audio","id":"p1","generation":1,"rate":48000,"frame":99,"pcm":"AAAAAA=="}"#)
        }
        #expect(try decoder.receive(#"{"run":"old","type":"ended"}"#) == nil)
        let replacement = track.replacingOccurrences(of: "\"generation\":1", with: "\"generation\":2")
        guard case .track(let next) = try decoder.receive(replacement) else { Issue.record("Expected replacement"); return }
        #expect(next.generation == 2)
        #expect(next.participant.id == "p1")
        #expect(try decoder.receive(#"{"run":"test","type":"removed","id":"p1"}"#) == .removed("p1"))
        #expect(throws: (any Error).self) {
            try decoder.receive(#"{"run":"test","type":"audio","id":"p1","generation":2,"rate":48000,"frame":101,"pcm":"AAAAAA=="}"#)
        }
        #expect(throws: (any Error).self) { try decoder.receive(track) }
        #expect(try decoder.receive(#"{"run":"test","type":"ended"}"#) == .ended)
    }

    @Test func invalidCaptureEndpointsFailBeforeAnyConnection() throws {
        #expect(throws: (any Error).self) {
            try KTalkAudioCapture(space: URL(string: "https://other.example")!, port: 9333, callID: "target:room")
        }
        #expect(throws: (any Error).self) {
            try KTalkAudioCapture(space: URL(string: "https://test.ktalk.ru")!, port: 80, callID: "target:room")
        }
    }
}

import Foundation
import Testing
import CallIntegrations
@testable import KTalkIntegration

struct KTalkModelTests {
    let space = URL(string: "https://synthetic.ktalk.ru")!
    let joined = #"{"kind":"conference","joined":true,"room":{"key":"probe","title":"Synthetic room","conference_id":"meeting-a"},"local_participant_id":"self","microphone_muted":true,"camera_muted":true,"participants":[{"id":"self","name":"Test Host","local":true,"guest":false,"microphone_muted":true,"camera_muted":true},{"id":"peer","name":"Test Guest","local":false,"guest":true,"microphone_muted":false,"camera_muted":true}]}"#

    @Test func localMuteAndStructuredRosterSurviveProjection() throws {
        let result = try KTalkModel.reading(Data(joined.utf8), targetID: "window", space: space)
        #expect(result.participation == .inCall)
        #expect(result.call?.id == "window:meeting-a")
        #expect(result.call?.url?.absoluteString == "https://synthetic.ktalk.ru/probe")
        #expect(result.call?.microphoneMuted == true)
        #expect(result.call?.localParticipantID == "self")
        #expect(result.call?.participants?.map(\.name) == ["Test Host", "Test Guest"])
        #expect(result.call?.participants?.last?.microphoneMuted == false)
    }
    @Test func prejoinAndSchemaFailureCannotPretendToBeJoined() throws {
        let preparing = joined.replacingOccurrences(of: #""joined":true"#, with: #""joined":false"#)
        #expect(try KTalkModel.reading(Data(preparing.utf8), targetID: "w", space: space).participation == .preparing)
        #expect(try KTalkModel.reading(Data(#"{"kind":"unsupported_schema"}"#.utf8), targetID: "w", space: space).participation == .unknown)
        #expect(throws: (any Error).self) {
            try KTalkModel.reading(Data(#"{"kind":"conference","joined":true}"#.utf8), targetID: "w", space: space)
        }
    }
    @Test func receiverValidationRejectsCredentialsQueriesAndRemoteDebugger() {
        #expect(KTalkModel.validSpace(space))
        for value in ["http://synthetic.ktalk.ru", "https://evilktalk.ru", "https://a.ktalk.ru.evil.test", "https://u:p@a.ktalk.ru", "https://a.ktalk.ru/?token=secret", "https://a.ktalk.ru/room", "https://a.ktalk.ru:443"] {
            #expect(!KTalkModel.validSpace(URL(string: value)!))
        }
        #expect(KTalkModel.validDebugger(URL(string: "ws://127.0.0.1:9333/devtools/page/window")!, port: 9333))
        for value in ["ws://evil.test:9333/devtools/page/window", "ws://127.0.0.1:9334/devtools/page/window", "ws://u:p@127.0.0.1:9333/devtools/page/window", "ws://127.0.0.1:9333/devtools/browser/x", "ws://127.0.0.1:9333/devtools/page/x?token=secret"] {
            #expect(!KTalkModel.validDebugger(URL(string: value)!, port: 9333))
        }
    }
}

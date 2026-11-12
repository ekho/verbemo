import Foundation
import Testing
import CallIntegrations
@testable import verbemo

@MainActor
struct CallIntegrationRecordingTests {
    func observation(_ state: CallParticipation = .inCall, muted: Bool? = true, date: Date = Date(), id: String = "test-call") -> CallObservation {
        .init(integrationID: "ktalk", application: .init(bundleID: "kontur.talk", name: "Толк"),
              observedAt: date, participation: state, source: .application,
              call: .init(id: id, title: "Synthetic call", participants: [], microphoneMuted: muted))
    }

    @Test func integrationControlsStartAndLossDoesNotStopOrRearm() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = Config.AutoRecordSettings()
        settings.calendar = false; settings.startDelay = 0; settings.stopDelay = 10
        settings.silenceStop = 1000; settings.minDuration = 0
        var reading = observation(.preparing, date: now)
        var session: FakeAutoSession?
        var starts = 0, stops = 0
        let controller = AutoRecordController(settings: settings, calendar: nil, loadSettings: { settings },
            checkMic: { configuration in
                #expect(configuration.ignoreApps.contains("kontur.talk"))
                return .init(active: false, names: [], families: [], allHolders: ["KTalk helper"])
            }, now: { now }, callObservations: { [reading] })
        controller.currentSession = { session }
        controller.startRecording = { trigger, context in
            #expect(context.callObservation?.call?.title == "Synthetic call")
            starts += 1; session = FakeAutoSession(startedAt: now, trigger: trigger); return true
        }
        controller.stopRecording = { _ in stops += 1; session = nil }
        controller.tick()
        #expect(starts == 0)
        reading = observation(date: now)
        controller.tick()
        #expect(starts == 1)
        now.addTimeInterval(30)
        reading = observation(.unknown, date: now)
        controller.tick()
        #expect(stops == 0)
        controller.noteManualStop(); session = nil
        now.addTimeInterval(30); reading.observedAt = now
        controller.tick()
        #expect(starts == 1)
        reading = observation(.idle, date: now)
        controller.tick()
        now.addTimeInterval(15); reading.observedAt = now; controller.tick()
        reading = observation(date: now); controller.tick()
        #expect(starts == 2)
    }

    @Test func asynchronousCaptureFailureUsesTheAutomaticStartBackoff() {
        let h = AutoRecordHarness()
        h.micActive = true
        h.run(for: 15)
        #expect(h.starts.count == 1)
        h.controller.noteCaptureFailure()
        h.session = nil
        h.run(for: 20)
        #expect(h.starts.count == 1)
        h.run(for: 15)
        #expect(h.starts.count == 2)
    }

    @Test func ordinaryCaptureIgnoresCallMuteButHonoursSessionPause() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var context = MeetingContext()
        context.applyCall(observation())
        let mic = FakeMicRecorder(), system = FakeSystemRecorder()
        let session = try RecordingSession(root: root, context: context, mic: mic, system: system)
        #expect(mic.privacyGate == nil)
        #expect(!mic.isMuted && mic.privacyGate == nil)
        session.updateCallObservation([observation(muted: false)])
        #expect(!mic.isMuted && mic.privacyGate == nil)
        session.updateCallObservation([observation(muted: true)])
        session.pause()
        #expect(mic.isMuted && system.isMuted)
        session.resume()
        #expect(!mic.isMuted && mic.privacyGate == nil)
        #expect(!system.isMuted)
        session.updateCallObservation([observation(muted: false, date: Date().addingTimeInterval(-10))])
        #expect(!mic.isMuted && mic.privacyGate == nil)
        session.updateCallObservation([observation(muted: false, id: "other-call")])
        #expect(!mic.isMuted && mic.privacyGate == nil)
        session.updateCallObservation([observation(muted: false)])
        #expect(!mic.isMuted && mic.privacyGate == nil)
        session.updateCallObservation([])
        #expect(!mic.isMuted && mic.privacyGate == nil)
    }

    @Test func callParticipantsAreNotFabricatedCalendarInvitees() throws {
        var context = MeetingContext(title: "Scheduled meeting", attendees: ["Calendar invitee"])
        context.applyCall(observation())
        #expect(context.title == "Scheduled meeting")
        #expect(context.attendees == ["Calendar invitee"])
        #expect(context.participants.isEmpty)
        let fields = context.metaFields
        #expect((fields["calendar"] as? [String: Any])?["title"] as? String == "Scheduled meeting")
        #expect((fields["call"] as? [String: Any])?["integration_id"] as? String == "ktalk")
    }

    @Test func ordinaryCaptureKeepsRawMicrophoneWhenCallArrivesMuted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var idle = observation(.idle); idle.call = nil
        let mic = FakeMicRecorder()
        let session = try RecordingSession(root: root, mic: mic, system: FakeSystemRecorder(), callObservations: [idle])
        session.updateCallObservation([idle])
        #expect(mic.privacyGate == nil)
        #expect(!mic.isMuted && mic.privacyGate == nil)
        session.updateCallObservation([observation(muted: true)])
        #expect(!mic.isMuted && mic.privacyGate == nil)
        #expect(session.callIntegrationID == "ktalk")
        session.updateCallObservation([observation(muted: false)])
        #expect(!mic.isMuted && mic.privacyGate == nil)
        session.updateCallObservation([])
        #expect(!mic.isMuted && mic.privacyGate == nil)
    }

    @Test func manuallyStartedCallKeepsItsStopHoldWhenObserverDisappears() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = Config.AutoRecordSettings()
        settings.calendar = false; settings.stopDelay = 10; settings.startDelay = 0
        var reading = observation(date: now)
        var session: FakeAutoSession? = FakeAutoSession(startedAt: now, trigger: .manual)
        session?.callIntegrationID = "ktalk"
        var starts = 0
        let controller = AutoRecordController(settings: settings, calendar: nil, loadSettings: { settings },
            checkMic: { _ in .init(active: false, names: [], families: [], allHolders: []) },
            now: { now }, callObservations: { [reading] })
        controller.currentSession = { session }
        controller.startRecording = { _, _ in starts += 1; return true }
        controller.noteManualStart()
        controller.noteManualStop()
        session = nil
        reading = observation(.unknown, date: now)
        controller.tick()
        now.addTimeInterval(20); reading.observedAt = now; controller.tick()
        reading = observation(date: now); controller.tick()
        #expect(starts == 0)
        #expect(controller.phase == .standingDown(.manualStop))
    }

    @Test func aDifferentCDPCallAtTheSameRoomURLCannotReplaceSessionIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var original = observation(muted: false)
        original.call?.url = URL(string: "https://synthetic.ktalk.ru/room")
        var context = MeetingContext(); context.applyCall(original)
        let mic = FakeMicRecorder()
        let session = try RecordingSession(root: root, context: context, mic: mic, system: FakeSystemRecorder())
        session.updateCallObservation([original])
        #expect(mic.privacyGate == nil)
        #expect(!mic.isMuted && mic.privacyGate == nil)
        var other = original; other.call?.id = "another-conference"
        session.updateCallObservation([other])
        #expect(!mic.isMuted && mic.privacyGate == nil)
        #expect(session.context.callObservation?.call == nil)
    }

    @Test func unknownAtStartupDoesNotMuteOrdinaryCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var unknown = observation(.unknown); unknown.call = nil
        var context = MeetingContext(); context.applyCall(unknown)
        let mic = FakeMicRecorder()
        let session = try RecordingSession(root: root, context: context, mic: mic,
                                          system: FakeSystemRecorder(), callObservations: [unknown])
        #expect(mic.privacyGate == nil)
        #expect(!mic.isMuted && mic.privacyGate == nil)
        var idle = observation(.idle); idle.call = nil
        session.updateCallObservation([idle])
        #expect(!mic.isMuted && mic.privacyGate == nil)
        session.updateCallObservation([observation(muted: true)])
        #expect(!mic.isMuted && mic.privacyGate == nil)
    }
}

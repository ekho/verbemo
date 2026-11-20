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
        var starts = 0
        var stops: [String] = []
        let controller = AutoRecordController(settings: settings, calendar: nil, loadSettings: { settings },
            checkMic: { configuration in
                #expect(configuration.ignoreApps.contains("kontur.talk") == (reading.participation != .unknown))
                return .init(active: false, names: [], families: [], allHolders: ["KTalk helper"])
            }, now: { now }, callObservations: { [reading] })
        controller.currentSession = { session }
        controller.startRecording = { trigger, context in
            #expect(context.callObservation?.call?.title == "Synthetic call")
            starts += 1; session = FakeAutoSession(startedAt: now, trigger: trigger); return true
        }
        controller.stopRecording = { reason in stops.append(reason); session = nil }
        controller.tick()
        #expect(starts == 0)
        reading = observation(date: now)
        controller.tick()
        #expect(starts == 1)
        now.addTimeInterval(30)
        reading = observation(.unknown, date: now)
        controller.tick()
        #expect(stops.isEmpty)
        controller.noteManualStop(); session = nil
        now.addTimeInterval(30); reading.observedAt = now
        controller.tick()
        #expect(starts == 1)
        reading = observation(.idle, date: now)
        controller.tick()
        now.addTimeInterval(15); reading.observedAt = now; controller.tick()
        reading = observation(date: now); controller.tick()
        #expect(starts == 2)
        reading = observation(.idle, date: now)
        controller.tick()
        #expect(stops.isEmpty)
        now.addTimeInterval(settings.stopDelay + 1)
        reading.observedAt = now
        controller.tick()
        #expect(stops == ["call-ended"])
    }

    @Test(arguments: [0, 5], [CallObservationSource.accessibility, .application])
    func manualStopAllowsTheNextConfirmedCall(gap: Int, source: CallObservationSource) {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = Config.AutoRecordSettings()
        settings.calendar = false
        settings.startDelay = 3
        settings.stopDelay = 15
        var reading = observation(date: now, id: "first")
        var session: FakeAutoSession?
        var starts: [String] = []
        let controller = AutoRecordController(settings: settings, calendar: nil, loadSettings: { settings },
            checkMic: { .init(active: !$0.ignoreApps.contains("kontur.talk"), names: [], families: [], allHolders: []) },
            now: { now }, callObservations: { [reading] })
        controller.currentSession = { session }
        controller.startRecording = { trigger, context in
            starts.append(context.callObservation?.call?.id ?? "missing")
            session = FakeAutoSession(startedAt: now, trigger: trigger)
            return true
        }
        func poll(_ id: String, _ seconds: Int, state: CallParticipation = .inCall,
                  from otherSource: CallObservationSource? = nil, age: TimeInterval = 0, participationID: String? = nil) {
            for _ in 0..<seconds {
                now.addTimeInterval(1)
                reading = observation(state, date: now.addingTimeInterval(-age), id: id)
                reading.source = otherSource ?? source
                reading.call?.participationID = participationID
                controller.tick()
            }
        }

        poll("first", 5)
        #expect(starts == ["first"])
        controller.noteManualStop()
        session = nil
        poll("first", 20)
        poll("different-source-id", 5, from: source == .application ? .accessibility : .application)
        poll("updated-audio-id", 5, participationID: "first")
        poll("", 5)
        poll("stale", 5, age: 6)
        poll("brief-candidate", 1)
        poll("first", 5)
        #expect(controller.notice == .manualStop)
        #expect(starts == ["first"])

        poll("", gap, state: .idle)
        poll("next", 3)
        #expect(starts == ["first"])
        poll("next", 1)
        #expect(starts == ["first", "next"])
        #expect(controller.notice == nil)
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

    @Test(arguments: [CallParticipation.unknown, .inCall, .idle, .preparing])
    func unknownCallIntegrationFallsBackToMicrophoneAutostart(_ participation: CallParticipation) {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = Config.AutoRecordSettings()
        settings.calendar = false
        let process = AudioProcesses.Process(object: 1, pid: 100,
            bundleID: "kontur.talk.helper", name: "Толк Helper",
            runningInput: true, runningOutput: false)
        var starts = 0
        let controller = AutoRecordController(settings: settings, calendar: nil, loadSettings: { settings },
            checkMic: {
                MicActivityMonitor.evaluate(processes: [process], callApps: $0.callApps, ignoring: $0.ignoreApps)
            }, now: { now }, callObservations: {
                [.init(integrationID: "ktalk", application: .init(bundleID: "kontur.talk", name: "Толк"),
                       observedAt: now.addingTimeInterval(participation == .unknown ? 0 : -6),
                       participation: participation)]
            })
        controller.startRecording = { trigger, context in
            #expect(trigger == .micActivity)
            #expect(context.callObservation == nil)
            #expect(context.appFamilies == ["kontur.talk"])
            starts += 1
            return true
        }
        controller.tick()
        now.addTimeInterval(settings.startDelay)
        controller.tick()
        #expect(starts == 1)
    }

    @Test(arguments: [CallParticipation.idle, .preparing])
    func confirmedCallStateSuppressesRawMicrophoneAutostart(_ participation: CallParticipation) {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = Config.AutoRecordSettings()
        settings.calendar = false
        let process = AudioProcesses.Process(object: 1, pid: 100,
            bundleID: "kontur.talk.helper", name: "Толк Helper",
            runningInput: true, runningOutput: false)
        var starts = 0
        let controller = AutoRecordController(settings: settings, calendar: nil, loadSettings: { settings },
            checkMic: {
                MicActivityMonitor.evaluate(processes: [process], callApps: $0.callApps, ignoring: $0.ignoreApps)
            }, now: { now }, callObservations: { [self.observation(participation, date: now)] })
        controller.startRecording = { _, _ in starts += 1; return true }
        controller.tick()
        now.addTimeInterval(settings.startDelay)
        controller.tick()
        #expect(starts == 0)
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
        #expect(session.integrationCall?.integrationID == "ktalk")
        session.updateCallObservation([observation(muted: false)])
        #expect(!mic.isMuted && mic.privacyGate == nil)
        session.updateCallObservation([])
        #expect(!mic.isMuted && mic.privacyGate == nil)
    }

    @Test(arguments: [false, true])
    func manuallyStartedCallKeepsItsStopHoldWhenObserverDisappears(alreadyInNextCall: Bool) {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = Config.AutoRecordSettings()
        settings.calendar = false; settings.stopDelay = 10; settings.startDelay = 0
        var reading = observation(date: now)
        var session: FakeAutoSession? = FakeAutoSession(startedAt: now, trigger: .manual)
        session?.integrationCall = reading
        var starts = 0
        let controller = AutoRecordController(settings: settings, calendar: nil, loadSettings: { settings },
            checkMic: { _ in .init(active: false, names: [], families: [], allHolders: []) },
            now: { now }, callObservations: { [reading] })
        controller.currentSession = { session }
        controller.startRecording = { _, _ in starts += 1; return true }
        controller.noteManualStart()
        let stoppedID = alreadyInNextCall ? "joined-before-stop" : "test-call"
        reading = observation(date: now, id: stoppedID)
        controller.noteManualStop()
        session = nil
        reading = observation(.unknown, date: now)
        controller.tick()
        now.addTimeInterval(20); reading.observedAt = now; controller.tick()
        reading = observation(date: now, id: stoppedID); controller.tick()
        #expect(starts == 0)
        #expect(controller.phase == .standingDown(.manualStop))
        reading = observation(date: now, id: "next-call"); controller.tick()
        #expect(starts == 1)
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

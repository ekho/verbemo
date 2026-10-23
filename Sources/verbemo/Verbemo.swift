import AppKit
import ArgumentParser
import Foundation

@main
struct Verbemo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verbemo",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [
            Run.self, Setup.self, Doctor.self, Install.self, Sessions.self, FormatTranscripts.self,
            ProcessSession.self,
            Record.self, AnalyticsCommand.self,
        ],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        // Someone already recording is the answer to "start verbemo": show them
        // its window rather than starting a second recorder beside it.
        if SingleInstance.handOverToRunningCopy() {
            FileHandle.standardError.write(Data("verbemo is already running\n".utf8))
            return
        }

        // The release image is deliberately read-only. Offer the ordinary Mac
        // installation before anything stores a path to that temporary volume.
        InterfaceLanguage.adoptFromSystem()
        let app = VerbemoApplication.shared
        app.setActivationPolicy(Config.dockIcon() ? .regular : .accessory)
        DockPresentation.update(state: .idle, elapsed: nil, application: app)
        if ApplicationRelocation.offerMoveIfNeeded() { return }

        // A copy started from a shell is not its own responsible process, so
        // everything it asks macOS for is billed to the terminal: the grants
        // land on Ghostty or Terminal, Verbemo.app never appears in the
        // permission lists, and the setup window reads the terminal's answers
        // back as if they were its own — green rows for grants this program
        // does not have (.issues/rca-002, and measured again with a signed
        // bundle on 19 August 2026). The README's `verbemo setup` is exactly
        // that shell, on exactly the machine where nothing is granted yet.
        //
        // So the command opens the app and steps aside. What it was asked to
        // do still happens: `verbemo setup` has already marked setup pending,
        // and the copy LaunchServices starts opens the window itself.
        if Runtime.shouldHandOffToBundle(bundle: Runtime.appBundle), let bundle = Runtime.appBundle {
            // Rebuilt from this command's own options rather than forwarded
            // from the command line: `verbemo setup` reaches here through
            // `Run.parse([])`, and passing "setup" on would send the new copy
            // looking for a running app that is itself.
            let forwarded = ["run"] + (out.map { ["--out", $0] } ?? [])
            if Runtime.handOffToBundle(bundle, arguments: forwarded) {
                FileHandle.standardError.write(Data(
                    "opened Verbemo.app — permissions belong to the app, not to this terminal\n".utf8))
                return
            }
            // Carrying on is better than refusing to start, but the grants
            // this copy collects are the terminal's and someone should know.
            let warning = "warning: could not open Verbemo.app; running here instead, and macOS "
                + "will attribute any permission granted now to this terminal rather than "
                + "to verbemo\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }

        // Keep the command line pointing at this bundle, so agents and
        // scripts reach the same signed program the app runs.
        if case .success(true) = AgentCLI.install() {
            FileHandle.standardError.write(Data(
                "pointed \(AgentCLI.path.path) at this app\n".utf8))
        }

        let root = Config.resolveRoot(cliOverride: out)

        // An app is started in `/`, and every process we spawn inherits that.
        // An agent CLI started at the root of the disk goes looking around it,
        // and macOS bills the privacy prompts it earns to us — we are the
        // responsible process for everything we launch. Sit in the recordings
        // folder instead, which is the only place we have business in.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.changeCurrentDirectoryPath(root.path)

        // Start after any handoff or move from the disk image, but before the
        // first setup window can report that it appeared.
        Analytics.start(surface: .app)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root, includeBackendChecks: false)
        let startupAction = DoctorReport.startupAction(checks: checks, setupPending: SetupState.isPending)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            // A failed permission is exactly what the first-run window exists
            // to repair. `verbemo setup` also resets this marker before launching,
            // so a denied grant can never make the repair UI unreachable.
            if startupAction == .refuse {
                let alert = NSAlert()
                alert.messageText = StartupAlert.title
                alert.informativeText = StartupAlert.body(for: checks)
                alert.runJournalModal()
                throw ExitCode(1)
            }
        }
        if startupAction == .setup { SetupState.reset() }

        // Settled before the first window is built, and never again: every
        // label, menu item and banner reads it as it is created, so a language
        // that changed underneath them would leave one window in each. It is
        // the same promise the startup window makes — the
        // setting takes effect at the next launch, and the window says so.
        // Interface language and the NSApplication were settled before the
        // possible move-from-DMG prompt; no window existed before that point.
        // .regular puts verbemo in the Dock and in ⌘-Tab. That's the point: the
        // menu bar is not a dependable place for the only control surface of a
        // recorder — when it fills up macOS parks the status item off-screen
        // and it stays clickable but invisible. The Dock can't be crowded out.
        let controller = AppController(root: root, followsConfiguredRoot: out == nil)

        // NSApp holds its delegate weakly, and a Dock icon is useless if
        // clicking it does nothing.
        let delegate = AppDelegate()
        delegate.onReopen = { alreadyActive in
            MainActor.assumeIsolated { controller.toggleWindow(alreadyActive: alreadyActive) }
        }
        delegate.onPrepareTermination = { completion in
            MainActor.assumeIsolated {
                controller.prepareForTermination(completion: completion)
            }
        }
        // Asked before the quit rather than after it, which is the whole
        // difference: onTerminate saves the session, this decides whether the
        // meeting should be interrupted at all.
        delegate.quitGate = QuitGate(
            recordingElapsed: { MainActor.assumeIsolated { controller.recordingElapsed } })
        delegate.onShowSettings = { MainActor.assumeIsolated { controller.showSettings() } }
        delegate.onShowSetup = { MainActor.assumeIsolated { controller.showSetup() } }
        delegate.onImport = { MainActor.assumeIsolated { controller.chooseMediaToImport() } }
        controller.onSetupAvailable = { available in
            MainActor.assumeIsolated { delegate.setupAvailable(available) }
        }
        delegate.onCheckForUpdates = { MainActor.assumeIsolated { controller.checkForUpdates() } }
        delegate.onShowAbout = { MainActor.assumeIsolated { controller.showAbout() } }
        app.delegate = delegate
        app.mainMenu = Self.mainMenu(settingsTarget: delegate)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            Self.quitFromTheRunLoop { MainActor.assumeIsolated { controller.shutdown() } }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        // Logout, restart, `launchctl kickstart -k`, `verbemo install
        // --uninstall` — all of them send SIGTERM, and the default action for
        // it kills us outright. PCM capture is recoverable after a hard kill,
        // but handling SIGTERM still turns a reboot into a clean stop with a
        // finished meta.json instead of work the next launch has to adopt.
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler {
            FileHandle.standardError.write(Data("\nSIGTERM — finalizing\n".utf8))
            Self.quitFromTheRunLoop { MainActor.assumeIsolated { controller.shutdown() } }
        }
        sigterm.resume()
        signal(SIGTERM, SIG_IGN)

        // Start/stop from a hotkey tool: kill -USR1 $(pgrep -x verbemo)
        let sigusr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        sigusr1.setEventHandler {
            MainActor.assumeIsolated { controller.toggleRecording() }
        }
        sigusr1.resume()
        signal(SIGUSR1, SIG_IGN)

        FileHandle.standardError.write(Data(
            "verbemo up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
        // Retained until the run loop exits: NSApp's delegate reference is
        // weak, and a deallocated one silently stops handling Dock clicks.
        withExtendedLifetime(delegate) {}
    }
    // Adapted from dm0xa's upstream safe-quit work; provenance is in docs/history.
    private static func quitFromTheRunLoop(_ quit: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { quit() }
        }
    }

}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    /// Where recordings go. It follows `recordings_dir` while verbemo runs —
    /// see `adoptPendingRoot` — unless `--out` named a folder for this run.
    private var root: URL
    private let followsConfiguredRoot: Bool
    /// A folder chosen while something was still being written into the old
    /// one, waiting for that to finish.
    private var pendingRoot: URL?
    private let menuBar = MenuBarController(visible: Config.menuBarIcon())
    private let window = ApplicationWindow()
    private var setupBuilt = false
    private lazy var setupPage: SetupPage = {
        setupBuilt = true
        let setup = SetupPage()
        setup.isRecording = { [weak self] in self?.isRecording == true }
        setup.onFinished = { [weak self] in
            self?.startAutomaticFeatures(requestCalendarAccess: false)
            self?.offerSetup()
        }
        return setup
    }()
    /// Sparkle, and verbemo's rule that a meeting outranks an update. Lazy only
    /// so that its gate can ask `self` whether a recording is running; it is
    /// built in `init` all the same, where the menu asks whether updates are
    /// available at all.
    private lazy var updates = AppUpdates(
        gate: UpdateGate(isBusy: { [weak self] in self?.isBusyForUpdate == true })
    )
    // Reserve synchronously before spawning a Task: otherwise stopping the
    // recording leaves a gap before the actor has accepted its work.
    private var pendingProcessing = 0
    private var isBusyForUpdate: Bool {
        isStopping || isRecording || pendingProcessing > 0 || imports.isRunning || mediaImportTask != nil
            || sweeps?.isBusy == true || (recordingsBuilt && recordings.isProcessing)
    }
    private func processingStarted() {
        pendingProcessing += 1
        updates.activityDidChange()
    }
    private func processingFinished() {
        pendingProcessing -= 1
        updates.activityDidChange()
    }
    private let operations: ProcessingOperations
    private let transcription: TranscriptionCoordinator
    private lazy var termination = AppTermination(operations: operations)
    private let liveTransitions = LiveTranscriptionTransitions()
    private var uiCleanup: [Task<Void, Never>] = []
    private var isStopping: Bool { !operations.isAccepting }
    /// The sweep of the recordings folder, after the queue and one at a time
    /// — see `SweepScheduler`. It sweeps whatever folder is current when it
    /// runs.
    private var sweeps: SweepScheduler!
    private var mediaImport: MediaImportCoordinator
    private let liveTranscription = LiveTranscriptionCoordinator()
    private let calendar = CalendarWatcher()
    private let autoRecord: AutoRecordController
    private var session: RecordingSession?
    /// Whether a meeting is being recorded. The session itself stays private —
    /// four things need this one fact about it (the settings form, the setup
    /// form, the update gate, and the quit alert) and none of them need the
    /// session.
    var isRecording: Bool { session != nil }
    /// How long the current recording has been running, or nil when there is
    /// none. Both facts in one answer, because whoever is about to be
    /// interrupted needs the number and not just the yes.
    var recordingElapsed: TimeInterval? {
        session.map { Date().timeIntervalSince($0.startedAt) }
    }
    private var liveRecordingStatus = LiveTranscriptionCoordinator.Status.idle
    private var ticker: Timer?
    private var recordingsBuilt = false
    private lazy var recordings: MeetingLibraryController = makeLibrary()

    private func makeLibrary() -> MeetingLibraryController {
        recordingsBuilt = true
        let library = MeetingLibraryController(root: root, hostWindow: self.window.panel)
        self.window.isProcessing = { [weak self] in self?.isBusyForUpdate == true }
        library.calendarSearch = { [weak self] query in
            guard let self else { throw CancellationError() }
            return try await self.calendar.search(query)
        }
        library.calendarResolve = { [weak self] meeting in
            guard let self else { throw CancellationError() }
            return try await self.calendar.resolve(meeting)
        }
        library.onActivityChange = { [weak self] in self?.updates.activityDidChange() }
        library.onOpenActiveRecording = { [weak self] in self?.window.showActiveRecording() }
        library.onRenameActiveRecording = { [weak self] title in
            guard let self, let session = self.session else { throw CocoaError(.fileNoSuchFile) }
            try session.rename(to: title)
            self.window.recordingTitle = title
            self.updateActiveRecording()
        }
        library.onRetranscribe = { [weak self] _ in self?.catchUp() }
        library.onImportFiles = { [weak self] files in self?.importFiles(files) }
        library.onCancelImport = { [weak self] in self?.cancelImport() }
        let coordinator = transcription
        library.onResumeDiarization = { [weak self] dir, request in
            self?.processingStarted()
            defer { self?.processingFinished() }
            try await coordinator.resumeDiarization(dir, request: request)
        }
        library.onRetryDiarization = { [weak self] dir in
            self?.processingStarted()
            defer { self?.processingFinished() }
            try await coordinator.diarizeNow(dir)
        }
        library.onSkipDiarization = { [weak self] dir in
            self?.processingStarted()
            defer { self?.processingFinished() }
            try await coordinator.skipDiarization(dir)
        }
        return library
    }
    private var network: NetworkMonitor?
    private var setupRequestObserver: NSObjectProtocol?
    /// How the app menu is told whether to offer **Setup…**; the status
    /// item's own menu is reached directly.
    var onSetupAvailable: ((Bool) -> Void)?
    /// Takes up settings changed in the UI or configuration file.
    private var settingsApplier: SettingsApplier?
    /// Hears edits made to the config file from outside — above all the one
    /// that fixes a file verbemo could not read.
    private var configDiskWatch: ConfigWatch.DiskWatch?
    /// Whether the config file was unreadable the last time anybody looked,
    /// so that its becoming readable again is acted on once: the sessions
    /// held while it was broken are still in the folder and need offering to
    /// the queue again.
    private var configWasUnreadable = false
    private var recordRequestObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    /// App Nap throttles timers, network and IPC for an app nobody is looking
    /// at — which is verbemo's normal condition and exactly when it must not be
    /// slow. A recorder that answers a request three seconds late has already
    /// missed the beginning of the meeting. Idle sleep is allowed between meetings.
    private var awake: NSObjectProtocol?
    /// Held only while recording: the Mac may sleep between meetings, but not
    /// in the middle of one.
    private var recordingActivity: NSObjectProtocol?
    private var automaticFeaturesStarted = false
    private var mediaImportTask: Task<Void, Never>?
    private var importOperationID: UUID?
    private var cancelledImportOperationID: UUID?
    private var imports = ImportQueue()
    /// The request to stop the importer mid-file, kept so that a run started
    /// after it can wait for it: arriving late, it would stop the new run.
    private var importStop: Task<Void, Never>?

    init(root: URL, followsConfiguredRoot: Bool = true, autoRecord watcher: AutoRecordController? = nil,
         operations: ProcessingOperations = .shared) {
        self.root = root
        self.followsConfiguredRoot = followsConfiguredRoot
        self.operations = operations
        transcription = TranscriptionCoordinator(operations: operations)
        mediaImport = MediaImportCoordinator(root: root, operations: operations)

        let settings = Config.autoRecord()
        // The calendar is worth reading for names even when it isn't a
        // trigger: "Integration sync (zoom.us)" beats "20:39" in a folder list
        // whether or not the event is what started the recording.
        self.autoRecord = watcher ?? AutoRecordController(
            settings: settings, calendar: calendar,
            canStartRecording: { SetupPermissions.microphone() == .granted })
        sweeps = SweepScheduler(
            waitForQueue: { [transcription] in await transcription.waitUntilIdle() },
            sweep: { [weak self] in
                guard let self, !isStopping else { return }
                await PostProcessor.sweep(root: root)
                sessionsChanged()
            }, operations: operations)
        sweeps.onActivityChange = { [weak self] in self?.updates.activityDidChange() }

        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onTogglePause = { [weak self] in self?.togglePause() }
        menuBar.onToggleAutoRecord = { [weak self] in self?.toggleAutoRecord() }
        window.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onShowMeetings = { [weak self] in self?.showMeetings() }
        menuBar.onShowRecording = { [weak self] in
            guard let self, self.session != nil else { return }
            self.window.showActiveRecording()
            self.window.bringToFront()
        }
        menuBar.onImport = { [weak self] in self?.chooseMediaToImport() }
        menuBar.onShowSettings = { [weak self] in self?.showSettings() }
        menuBar.onShowSetup = { [weak self] in self?.showSetup() }
        window.onCheckForUpdates = { [weak self] in self?.updates.checkForUpdates() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.update(state: .idle, elapsed: nil)
        window.updatesAvailable = updates.isAvailable
        window.readAudioLevels = { [weak self] in self?.session?.audioLevels ?? (.off, .off) }

        window.libraryProvider = { [weak self] in self?.recordings }
        window.onRenameRecording = { [weak self] name in
            guard let session = self?.session else { throw CocoaError(.fileNoSuchFile) }
            try session.rename(to: name)
        }
        window.onToggle = { [weak self] in self?.toggle() }
        window.recordingCalendar = { [weak self] date in
            guard let self, Config.useCalendar() else { return nil }
            await self.calendar.requestAccess()
            guard self.calendar.authorized, Config.useCalendar() else { return nil }
            return (self.calendar.bestMatch(for: Date()), self.calendar.meetings(on: date))
        }
        window.calendarSearch = { [weak self] query in
            guard let self else { throw CancellationError() }
            return try await self.calendar.search(query)
        }
        window.calendarResolve = { [weak self] meeting in
            guard let self else { throw CancellationError() }
            return try await self.calendar.resolve(meeting)
        }
        window.onStartRecording = { [weak self] title, meeting in
            guard let self, self.session == nil else { return }
            self.autoRecord.noteManualStart()
            let context = self.recordingContext(meeting: Config.useCalendar() ? meeting : nil)
            self.startSession(trigger: .manual, context: context, title: title)
        }
        window.onTogglePause = { [weak self] in self?.togglePause() }
        window.onToggleAutoRecord = { [weak self] in self?.toggleAutoRecord() }
        window.onToggleLive = { [weak self] enabled in self?.toggleLive(enabled) }
        window.onImportFiles = { [weak self] files in self?.importFiles(files) }
        window.onCancelImport = { [weak self] in self?.cancelImport() }
        window.onChooseImport = { [weak self] in self?.chooseMediaToImport() }
        window.updateLivePreference(enabled: Config.liveTranscriptionEnabled())
        if Config.showWindowAtLaunch(), !SetupState.isPending { window.show() }

        autoRecord.currentSession = { [weak self] in self?.session }
        autoRecord.startRecording = { [weak self] trigger, context in
            self?.startSession(trigger: trigger, context: context) ?? false
        }
        autoRecord.stopRecording = { [weak self] reason in
            self?.stopSession(reason: reason)
        }

        // Adopt anything a crash left behind *before* the queue scans, so a
        // rescued session is transcribed in the same pass as the clean ones.
        RecordingSession.recoverInterrupted(root: root)

        menuBar.updateAutoRecord(enabled: autoRecord.enabled, notice: nil)
        window.updateAutoRecord(enabled: autoRecord.enabled, decision: nil)

        // Runs for the life of the daemon, not just while recording: the menu
        // also shows what the auto-record loop is thinking, and a status line
        // that only updates during a recording is worse than none.
        ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }

        if let ticker { RunLoop.main.add(ticker, forMode: .common) }

        Notifications.install { [weak self] folder in
            if let folder {
                Analytics.track(.artifactOpened, [
                    .artifact: .text(Analytics.Artifact.sessionFolder.rawValue),
                ])
                NSWorkspace.shared.open(folder)
            } else {
                self?.showWindow()
            }
        }

        awake = ProcessInfo.processInfo.beginActivity(
            options: Wakefulness.lifetime,
            reason: "verbemo watches for meetings and answers its command line")

        offerSetup()
        settingsApplier = SettingsApplier(
            apply: { [weak self] change in self?.take(change) },
            always: { [weak self] in
                self?.showConfigProblems()
                // auto_record.enabled is written by Settings, the setup form,
                // the menu and the status window alike, and obeyed from here.
                self?.autoRecord.reloadSettings()
                self?.showAutoRecord()
            })
        configDiskWatch = ConfigWatch.DiskWatch()
        showConfigProblems()
        setupRequestObserver = SetupRequest.observe { [weak self] in self?.showSetup() }
        activateObserver = SingleInstance.observe { [weak self] in self?.showWindow() }
        // A recording does not go on across a sleep. The Mac only sleeps
        // mid-recording when somebody shuts the lid or chooses Sleep — idle
        // sleep is held off while recording — and for this Mac that is the
        // end of the meeting. Carrying on meant a track that paused for the
        // length of the sleep beside one that did not, a mic restart asked
        // to pad hours of silence, and a duration ceiling reached the moment
        // the lid opened. Stopping here keeps what was recorded exactly as it
        // was; a call still going on after wake is a new recording.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.autoRecord.noteSystemSleep()
                self?.stopSession(reason: "system-sleep")
            }
        }
        recordRequestObserver = RecordRequest.observe { [weak self] action in
            self?.perform(action)
        }
        // The wizard may remain open indefinitely, including after a revoked
        // permission sent an existing installation back to setup. Watching a
        // call must not wait for that window or for a calendar permission
        // prompt. The watcher itself waits for an already-granted microphone.
        autoRecord.start()
        showAutoRecord()
        if SetupState.isPending {
            showSetup()
        } else {
            startAutomaticFeatures(requestCalendarAccess: true)
        }
    }

    /// Where verbemo is visible: the menu bar, the Dock, both, or neither.
    ///
    /// Applied while running rather than at the next launch, which is the
    /// whole reason the two switches are safe to offer. Turning off the last
    /// icon leaves a program with nowhere to click, and someone who has just
    /// done it by accident should be able to see what happened and put it
    /// back in the window they are already standing in — not restart the
    /// program to find out.
    private func applyIconPreferences() {
        menuBar.setVisible(Config.menuBarIcon())
        window.applyDockPreference()
    }

    /// Resume processing and optional calendar prompts after setup. Microphone
    /// watching starts independently, so this window cannot suppress meetings.
    private func startAutomaticFeatures(requestCalendarAccess: Bool) {
        guard !isStopping, !automaticFeaturesStarted else { return }
        automaticFeaturesStarted = true

        processingStarted()
        Task { [transcription, root, self] in
            defer { processingFinished() }
            await transcription.setStatusHandler { _ in
                Task { @MainActor [weak self] in
                    self?.processingStatusChanged()
                }
            }
            await transcription.resumePending(root: root)
            // After the queue has drained, not merely after it has been asked
            // to start: a session that transcribes in this pass gets named
            // and summarized by the coordinator itself, and the sweep is only
            // for what was left over from earlier runs. `resumePending`
            // returns as soon as its drain begins, and a sweep started then
            // walked the folder alongside it.
            sweeps.request()
            await transcription.waitUntilIdle()
        }

        // A backlog deferred for want of a model is only half-solved by
        // recording the fact — something has to come back for it when the
        // network does.
        let monitor = NetworkMonitor { [weak self] in
            Task { @MainActor [weak self] in self?.sweeps.request() }
        }
        monitor.start()
        network = monitor

        // A calendar prompt can stay unanswered. It must never hold up the
        // already-running microphone watcher.
        if requestCalendarAccess && (Config.useCalendar() || Config.autoRecord().calendar) {
            Task { [weak self] in await self?.calendar.requestAccess() }
        }
        autoRecord.reloadSettings()
        showAutoRecord()
    }

    /// Start or stop by signal — `kill -USR1 $(pgrep -x verbemo)` — so a hotkey
    /// tool can drive recording without going through the menu.
    func toggleRecording() { toggle() }

    func checkForUpdates() { updates.checkForUpdates() }

    /// Both menu commands end here, so there is one picker and one import
    /// pipeline regardless of where a person starts from.
    func chooseMediaToImport() {
        guard !isStopping else { return }
        guard let files = MediaImportPicker.choose(), !files.isEmpty else { return }
        importFiles(files)
    }

    /// Also used by drag-and-drop entry points in the meeting and live pages. The importer
    /// publishes complete filesystem sessions; only then are they handed to
    /// the ordinary transcription queue, exactly like a recording just ended.
    func importFiles(_ files: [URL]) {
        guard operations.isAccepting else { imports.close(); return }
        if let id = importOperationID,
           !operations.snapshot().contains(where: { $0.id == id && $0.state != .cancelling }) {
            noteImportCancellation(id)
        }
        if imports.add(files) { startImportRun() }
        updates.activityDidChange()
    }

    /// One run of the importer: batch after batch until nothing is waiting
    /// or somebody cancels, then one summary for the whole run.
    private func startImportRun() {
        guard let ticket = try? operations.register(session: nil, kind: .importMedia) else {
            imports.close()
            _ = imports.runEnded()
            return
        }
        importOperationID = ticket.id
        cancelledImportOperationID = nil
        window.navigate(.allMeetings)
        window.bringToFront()
        let stop = importStop
        mediaImportTask = Task { [weak self, mediaImport] in
            do {
                try await ticket.run { [weak self, mediaImport] in
                    guard let self else { return }
                    await withTaskCancellationHandler {
                        await self.runImportBatches(ticket.id, after: stop, using: mediaImport)
                    } onCancel: {
                        Task { @MainActor [weak self] in self?.noteImportCancellation(ticket.id) }
                    }
                }
            } catch {
                self?.noteImportCancellation(ticket.id)
                self?.finishImport(.init(cancelled: true))
            }
            guard let self, importOperationID == ticket.id else { return }
            mediaImportTask = nil
            importOperationID = nil
            cancelledImportOperationID = nil
            if !operations.isAccepting { imports.close() }
            // Files dropped while this run was stopping are a new request.
            if imports.runEnded() {
                startImportRun()
            } else {
                adoptPendingRoot()
            }
            updates.activityDidChange()
        }
    }

    private func runImportBatches(_ id: UUID, after stop: Task<Void, Never>?,
                                  using mediaImport: MediaImportCoordinator) async {
        await stop?.value
        var combined = MediaImportCoordinator.Result()
        while !Task.isCancelled, let batch = imports.nextBatch() {
            let result = await mediaImport.importFiles(batch) { [weak self] update in
                Task { @MainActor [weak self] in self?.showImport(update) }
            }
            combined.imported.append(contentsOf: result.imported)
            combined.duplicates.append(contentsOf: result.duplicates)
            combined.failures.append(contentsOf: result.failures)
            combined.cancelled = combined.cancelled || result.cancelled
            for imported in result.imported {
                guard !Task.isCancelled else { break }
                processingStarted()
                await transcription.enqueue(imported.session)
                Task { [self, transcription] in
                    await transcription.waitUntilIdle()
                    processingFinished()
                }
            }
            if result.cancelled { noteImportCancellation(id); break }
        }
        if Task.isCancelled {
            noteImportCancellation(id)
            combined.cancelled = true
        }
        finishImport(combined)
    }

    private func noteImportCancellation(_ id: UUID) {
        guard importOperationID == id, cancelledImportOperationID != id else { return }
        cancelledImportOperationID = id
        if operations.isAccepting { imports.cancel() } else { imports.close() }
    }

    func cancelImport() {
        if let id = importOperationID { noteImportCancellation(id) } else { imports.cancel() }
        mediaImportTask?.cancel()
        let previous = importStop
        importStop = Task { [mediaImport] in
            await previous?.value
            await mediaImport.cancel()
        }
    }

    /// Entered only after QuitGate accepts quitting; admission closes before capture stops.
    func prepareForTermination(completion: @escaping () -> Void) -> Bool {
        let task = termination.begin(stop: { [self] in
            stopServices()
            stopSession(reason: "app-quit")
            let text = localised("Stopping…", "Останавливаю…")
            window.showStopping(text)
        }, finishRecording: { [self] in
            await liveTransitions.wait()
            await liveTranscription.finishRecording()
        }, finishServices: { [self] in
            await importStop?.value
            await mediaImportTask?.value
            for task in uiCleanup { await task.value }
            uiCleanup.removeAll()
            if let awake { ProcessInfo.processInfo.endActivity(awake); self.awake = nil }
        })
        Task { await task.value; completion() }
        return true
    }

    private func stopServices() {
        ticker?.invalidate(); ticker = nil
        autoRecord.stop()
        network?.stop(); network = nil
        settingsApplier = nil
        configDiskWatch = nil
        if let setupRequestObserver { DistributedNotificationCenter.default().removeObserver(setupRequestObserver) }
        if let recordRequestObserver { DistributedNotificationCenter.default().removeObserver(recordRequestObserver) }
        if let activateObserver { DistributedNotificationCenter.default().removeObserver(activateObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        imports.close()
        cancelImport()
        uiCleanup = window.stopForTermination()
        if recordingsBuilt { uiCleanup += recordings.stopForTermination() }
        if setupBuilt { uiCleanup += setupPage.stopForTermination() }
    }

    private func showImport(_ update: MediaImportCoordinator.Update) {
        window.updateImport(update)
        recordings.updateImport(update)
    }

    private func finishImport(_ result: MediaImportCoordinator.Result) {
        window.finishImport(result)
        recordings.finishImport(result)
    }

    /// Signals use the same AppKit confirmation and deferred cleanup as menu/Dock quit.
    func shutdown() { NSApp.terminate(nil) }

    /// What `verbemo record` asks for. Asking to start what is already running,
    /// or to stop what isn't, is not an error — it is the state the caller
    /// wanted, and scripts should be able to say it twice.
    private func perform(_ action: RecordRequest.Action) {
        switch action {
        case .start where session == nil: toggle()
        case .stop where session != nil: toggle()
        case .toggle: toggle()
        case .start, .stop: break
        }
    }

    private func toggle() {
        guard !isStopping else { return }
        if session == nil {
            autoRecord.noteManualStart()
            startSession(trigger: .manual, context: currentContext())
        } else {
            autoRecord.noteManualStop()
            stopSession(reason: "manual")
        }
    }

    private func togglePause() {
        guard !isStopping, let session else { return }
        if session.isPaused {
            session.resume()
        } else {
            session.pause()
        }
        tick()
    }

    /// The menu's and the main window's switch. It writes
    /// `auto_record.enabled` like every other surface does, so the answer
    /// survives a relaunch and Settings shows the same thing.
    private func toggleAutoRecord() {
        guard !isStopping else { return }
        autoRecord.setEnabled(!autoRecord.enabled)
        showAutoRecord()
    }

    private func showAutoRecord() {
        let decision = autoRecord.enabled ? autoRecord.lastDecision : nil
        menuBar.updateAutoRecord(enabled: autoRecord.enabled, notice: autoRecord.notice)
        window.updateAutoRecord(enabled: autoRecord.enabled, decision: decision)
    }

    /// The main window's live-transcript switch. It only writes, as the
    /// setup form's switch does; the recording is rewired by `take`, which
    /// hears both.
    private func toggleLive(_ enabled: Bool) {
        guard !isStopping else { return }
        let wasEnabled = Config.liveTranscriptionEnabled()
        Config.update(
            path: ["live_transcription", "enabled"], value: enabled ? true : nil)
        // Download/retry also works when the preference was already on.
        if enabled && wasEnabled { rewireLive(true) }
    }

    /// One setting that changed while verbemo was running.
    private func take(_ change: SettingsApplier.Change) {
        guard !isStopping else { return }
        switch change {
        case .liveTranscription(let enabled):
            window.updateLivePreference(enabled: enabled)
            rewireLive(enabled)
        case .icons:
            applyIconPreferences()
        case .recordingsRoot(let folder):
            guard followsConfiguredRoot else { return }
            pendingRoot = folder
            adoptPendingRoot()
        }
    }

    /// Move to the recordings folder the config now names, if nothing is
    /// being written into the old one.
    ///
    /// Choosing a folder in Setup used to change nothing until the next
    /// launch, and said nothing about it: the next meeting went on landing
    /// in the old folder while the window showed the new one. Now the next
    /// recording or import goes to the new folder, and the meeting library
    /// shows what is in it. A recording or an import under way finishes where
    /// it started — a session is one folder — and the move waits for it.
    private func adoptPendingRoot() {
        guard !isStopping, let folder = pendingRoot, session == nil, mediaImportTask == nil else { return }
        pendingRoot = nil
        guard folder != root.standardizedFileURL else { return }
        root = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // For the same reason `Run` sits in the recordings folder at launch:
        // an agent CLI started anywhere else goes looking around it.
        FileManager.default.changeCurrentDirectoryPath(folder.path)
        mediaImport = MediaImportCoordinator(root: folder, operations: operations)
        FileHandle.standardError.write(Data("recordings → \(folder.path)\n".utf8))
        // The new folder may be an old one, with its own leftovers: a crash
        // to adopt, sessions nobody transcribed.
        RecordingSession.recoverInterrupted(root: folder)
        if automaticFeaturesStarted { catchUp() }
        if recordingsBuilt { recordings.setRoot(folder) }
    }

    /// Start or stop the live transcript under a recording already running.
    private func rewireLive(_ enabled: Bool) {
        guard !isStopping, let session else { return }

        // Close the old epoch synchronously. Any partial result already in
        // flight is rejected by the coordinator's epoch check.
        session.installLiveAudioSinks(mic: nil, system: nil)
        let language = LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())
        liveTransitions.append { [liveTranscription] in
            await liveTranscription.setEnabled(enabled, language: language)
        }
    }

    /// What we can tell about a meeting being started by hand: whichever call
    /// app is already holding the microphone, plus the calendar's view of now.
    private func currentContext() -> MeetingContext {
        recordingContext(meeting: Config.useCalendar() ? calendar.bestMatch(for: Date()) : nil)
    }

    private func recordingContext(meeting: CalendarWatcher.Meeting?) -> MeetingContext {
        let settings = Config.autoRecord()
        let mic = MicActivityMonitor.check(
            callApps: settings.callApps, ignoring: settings.ignoreApps
        )
        return MeetingContext(
            meeting: meeting,
            app: mic.names.first,
            appFamilies: mic.families
        )
    }

    /// Whether a recording is running once this returns. The auto-record
    /// loop decides from the answer when to try again.
    @discardableResult
    private func startSession(trigger: RecordingSession.Trigger, context: MeetingContext, title: String? = nil) -> Bool {
        guard !isStopping else { return false }
        guard session == nil else { return true }
        do {
            let newSession = try RecordingSession(root: root, context: context, trigger: trigger, title: title)
            try newSession.start()
            session = newSession
            updates.activityDidChange()
            FileHandle.standardError.write(Data(
                "● recording (\(trigger.rawValue)) → \(newSession.dir.path)\n".utf8
            ))
            if trigger != .manual {
                notifyUser(
                    title: localised("verbemo — recording started", "verbemo — запись началась"),
                    body: context.folderSuffix ?? newSession.dir.lastPathComponent,
                    opening: newSession.dir
                )
            }
        } catch {
            Analytics.track(.recordingStartFailed, [
                .trigger: .text(trigger.rawValue),
                .component: .text(
                    (error as? RecordingSession.StartFailure)?.analyticsComponent ?? "unknown"),
                .reason: .text(Analytics.reason(for: error).rawValue),
            ])
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            // One banner, replaced by each repeat rather than stacked under
            // it: an auto-start retrying against the same refusal has nothing
            // new to say the second time.
            notifyUser(
                title: localised("verbemo — recording failed", "verbemo — не удалось начать запись"),
                body: "\(error)",
                replacing: Self.startFailedBanner)
            return false
        }

        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: Wakefulness.recording,
            reason: "verbemo is recording a meeting")

        guard let newSession = session else { return true }
        let liveEnabled = Config.liveTranscriptionEnabled()
        let liveLanguage = LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())
        liveTransitions.append { [weak self, liveTranscription] in
            await liveTranscription.beginRecording(
                enabled: liveEnabled,
                language: liveLanguage,
                update: { [weak self] snapshot in
                    Task { @MainActor in self?.showLive(snapshot) }
                },
                // The sinks arrive when Nemotron starts consuming, which is
                // several seconds after the recording began. Only the session
                // that asked for them may have them.
                attach: { [weak self] sinks in
                    Task { @MainActor in
                        guard let self, self.session === newSession else { return }
                        newSession.installLiveAudioSinks(
                            mic: sinks?.mic, system: sinks?.system)
                    }
                }
            )
        }

        present(.recording, elapsed: "0:00")
        return true
    }

    private static let startFailedBanner = "recording-start-failed"

    private func stopSession(reason: String = "manual") {
        if let recordingActivity {
            ProcessInfo.processInfo.endActivity(recordingActivity)
            self.recordingActivity = nil
        }
        guard let session else { return }
        session.installLiveAudioSinks(mic: nil, system: nil)
        let finished = session.stop(reason: reason)
        let duration = Date().timeIntervalSince(session.startedAt)
        FileHandle.standardError.write(Data(
            "○ stopped (\(reason)) · \(Self.format(duration)) · \(session.dir.path)\n".utf8
        ))
        processingStarted()
        self.session = nil
        present(.idle, elapsed: nil)
        adoptPendingRoot()

        // A mic that opened for a few seconds was never a meeting. Throwing
        // these away is what keeps the recordings folder worth opening — but
        // only ever for recordings we started ourselves, and only when the
        // recording ended because the meeting did. The rule itself lives on
        // AutoRecordController, which is the type that knows how long each
        // way of ending waits before it fires; what is left of the recording
        // once that wait is taken out is what gets compared.
        let settings = Config.autoRecord()
        if AutoRecordController.shouldDiscard(
            trigger: session.trigger, reason: reason, duration: duration, settings: settings) {
            let meeting = duration
                - (AutoRecordController.trailingQuiet(for: reason, settings: settings) ?? 0)
            FileHandle.standardError.write(Data(
                ("discarded \(session.dir.lastPathComponent): \(Int(meeting))s of meeting in "
                    + "\(Int(duration))s of recording is under the \(Int(settings.minDuration))s "
                    + "minimum for an automatic recording\n").utf8
            ))
            session.discard()
            liveTransitions.append { [self, liveTranscription] in
                await liveTranscription.finishRecording()
                processingFinished()
            }
            return
        }

        let dir = session.dir
        // A folder whose meta.json could not be written is not a session yet:
        // queued, it failed at once for want of one and put a "transcription
        // failed" banner over a recording that had not failed at all. Its
        // manifest is kept, and the next launch's recovery finishes it and
        // hands it to the queue.
        let queue = finished ? transcription : nil
        if !finished {
            FileHandle.standardError.write(Data(
                ("not queued: \(dir.lastPathComponent) has no meta.json yet — recovery "
                    + "finishes it at the next launch\n").utf8))
        }
        let handoff = liveTransitions.append { [liveTranscription] in
            // Drop the large streaming model before Parakeet begins its final,
            // canonical pass so the two heavyweight ASR pipelines don't
            // compete for memory or the Neural Engine.
            await liveTranscription.finishRecording()
            await queue?.enqueue(dir)
        }
        Task { [self] in
            await handoff.value
            await queue?.waitUntilIdle()
            processingFinished()
        }
    }

    /// Say what is wrong with the config file, and pick up the work held
    /// while it could not be read once it can.
    private func showConfigProblems() {
        let problems = Config.problems()
        menuBar.updateConfigProblem(problems.first?.headline)
        window.updateConfigProblem(problems.first?.headline)

        let unreadable = Config.unreadableReason != nil
        defer { configWasUnreadable = unreadable }
        guard configWasUnreadable, !unreadable, automaticFeaturesStarted else { return }
        catchUp()
    }

    /// Offer the current recordings folder to the queue, and sweep it once
    /// the queue has drained. A fixed config that also names a new folder
    /// asks for this twice in one turn — once for the folder, once for the
    /// file — and gets the queue asked twice, which it takes as once, and
    /// one sweep.
    private func catchUp() {
        guard !isStopping else { return }
        let folder = root
        processingStarted()
        Task { [transcription, self] in
            await transcription.resumePending(root: folder)
            sweeps.request()
            await transcription.waitUntilIdle()
            processingFinished()
        }
    }

    private func processingStatusChanged() {
        guard !isStopping else { return }
        // Each change of status follows the end of a session's work — its
        // transcript, names and summary — or the start of the next, so the
        // meeting library reads again rather than going on offering
        // Finish processing for work that has been done.
        sessionsChanged()
    }

    /// The recordings folder changed behind the meeting library's back.
    private func sessionsChanged() {
        if recordingsBuilt { recordings.sessionsChanged() }
    }

    private func showLive(_ snapshot: LiveTranscriptionCoordinator.Snapshot) {
        liveRecordingStatus = snapshot.status
        updateActiveRecording()
        window.updateLive(snapshot)
        switch snapshot.status {
        case .overloaded, .error:
            // The coordinator has closed its queues; detach here as well so
            // the real-time recorders stop making now-unused buffer copies.
            session?.installLiveAudioSinks(mic: nil, system: nil)
        case .idle, .paused, .downloading, .loading, .live, .modelMissing:
            break
        }
    }

    /// Bring the main window up — from the menu, a notification, or a
    /// second launch of an already-running verbemo. All three are someone
    /// asking for the window this second, so it comes forward rather than
    /// waiting behind whatever they were looking at.
    func showWindow() { window.bringToFront() }

    /// Settings use the same window as meetings, including menu-bar activation.
    func showSettings() {
        guard !isStopping else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.navigate(.general)
        window.bringToFront()
    }

    /// About is a page in the same window.
    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        window.navigate(.about)
        window.bringToFront()
    }

    /// First-run setup: opened by the first launch, by the menu item while
    /// that is still there, and by `verbemo setup` at any time.
    ///
    /// The command resets the marker before it rings, which is what makes it
    /// the way back to the wizard on a machine that has been through setup —
    /// so the menus are asked again here, and the item is on offer for as
    /// long as the first run is unfinished.
    func showSetup() {
        guard !isStopping else { return }
        NSApp.activate(ignoringOtherApps: true)
        offerSetup()
        window.presentSetup(setupPage)
    }

    /// Offer permissions while first-run setup is pending. The CLI can reopen it.
    private func offerSetup() {
        let available = SetupState.isPending
        menuBar.setupAvailable(available)
        onSetupAvailable?(available)
    }

    /// The Dock icon: show the window, or put it away if verbemo was already in
    /// front and it's sitting there.
    func toggleWindow(alreadyActive: Bool) {
        if alreadyActive, window.isVisible {
            window.hide()
        } else {
            window.show()
        }
    }

    /// Reflect state everywhere it's shown at once, so the three surfaces can
    /// never disagree about whether something is being recorded.
    private func present(_ state: MenuBarController.State, elapsed: String?) {
        menuBar.update(state: state, elapsed: elapsed)
        window.recordingTitle = session?.title ?? localised("New meeting", "Новая встреча")
        window.update(state: state, elapsed: elapsed)
        updateActiveRecording()
        DockPresentation.update(state: state, elapsed: elapsed)
    }

    private func updateActiveRecording() {
        guard recordingsBuilt else { return }
        recordings.setActiveRecording(session.map {
            MeetingPresentation.ActiveRecording(dir: $0.dir, title: $0.title ?? localised("New meeting", "Новая встреча"), started: $0.startedAt, paused: $0.isPaused, liveStatus: liveRecordingStatus)
        })
    }

    private func tick() {
        guard !isStopping else { return }
        let decision = autoRecord.enabled ? autoRecord.lastDecision : nil
        menuBar.updateAutoRecord(enabled: autoRecord.enabled, notice: autoRecord.notice)
        window.updateAutoRecord(enabled: autoRecord.enabled, decision: decision)
        guard let session else { return }
        present(
            session.isPaused ? .paused : .recording,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Analytics.track(.artifactOpened, [
            .artifact: .text(Analytics.Artifact.recordingsRoot.rawValue),
        ])
        NSWorkspace.shared.open(root)
    }

    private func showMeetings() {
        guard !isStopping else { return }
        // A session put back in the queue should start transcribing now, not
        // at the next launch — the person asking for it is watching.
        recordings.onRetranscribe = { [weak self] _ in
            self?.catchUp()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.navigate(.allMeetings)
        window.bringToFront()
    }

    /// The elapsed time as the recording controls show it. Not private and not
    /// isolated because `verbemo doctor` prints the same number from a command
    /// that never touches AppKit, and one shape for it is the point.
    nonisolated static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// Keeps the application icon as stable identity while the system-defined Dock
/// badge carries transient recording state. Appearance variants belong to the
/// app icon asset and follow the person's macOS appearance, not the recorder.
@MainActor
enum DockPresentation {
    static func update(
        state: MenuBarController.State,
        elapsed: String?,
        application: NSApplication = .shared
    ) {
        application.dockTile.badgeLabel = state == .idle ? nil : elapsed
    }
}

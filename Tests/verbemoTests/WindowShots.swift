import AppKit
import Foundation
import Testing

@testable import verbemo

/// Offscreen pictures of the real Journal pages for human layout review.
/// These are opt-in fixtures, not pixel assertions or GUI acceptance evidence.
/// `docs/testing/window-shots.md` lists their output and rendering limits.
@Suite(
    .serialized, .enabled(if: ProcessInfo.processInfo.environment["VERBEMO_SHOTS"] != nil),
    .freshHome(config: speakerShotsConfig),
    .speaking(shotsLanguage))
@MainActor
struct WindowShots {
    private var directory: String {
        ProcessInfo.processInfo.environment["VERBEMO_SHOTS"] ?? NSTemporaryDirectory()
    }
    private var light: NSAppearance? { NSAppearance(named: .aqua) }
    private var dark: NSAppearance? { NSAppearance(named: .darkAqua) }

    @Test("New recording with and without a calendar event, in both appearances")
    func newRecordingSheet() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-21T10:00:00Z")!
        let event = CalendarWatcher.Meeting(id: "synthetic-event", title: "Обсуждение нового сайта",
            start: now, end: now.addingTimeInterval(2700), attendees: ["Анна", "Михаил"], link: nil,
            looksLikeCall: true, calendarTitle: "Демонстрационный календарь")
        for (name, appearance) in [("light", light), ("dark", dark)] {
            for enabled in [false, true] {
                let sheet = NewRecordingSheet(calendarEnabled: enabled, now: now) { _ in (event, [event]) }
                defer { sheet.panel.close() }
                show(sheet.panel, in: appearance)
                sheet.load()
                await sheet.settled()
                try write(sheet.panel, "new-recording-\(enabled ? "calendar" : "timestamp")-\(name)")
            }
        }
    }

    @Test("First-run permissions inside Journal, in both appearances and at minimum width")
    func setupPage() throws {
        for (name, appearance) in [("light", light), ("dark", dark)] {
            try withJournal(builtIn: appearance) { app, _ in
                let setup = SetupPage(calendar: CalendarWatcher(store: CalendarFixtureStore(), authorizationStatus: { .notDetermined }))
                defer { withExtendedLifetime(setup) {} }
                app.presentSetup(setup)
                try write(app.panel, "setup-permissions-\(name)")
                app.panel.setContentSize(NSSize(width: 760, height: 680))
                try write(app.panel, "setup-permissions-\(name)-narrow")
            }
        }
        try withJournal(builtIn: light) { app, _ in
            let setup = SetupPage(calendar: CalendarWatcher(store: CalendarFixtureStore(), authorizationStatus: { .notDetermined }))
            defer { withExtendedLifetime(setup) {} }
            app.presentSetup(setup)
            show(app.panel, in: dark)
            try write(app.panel, "setup-permissions-switched-to-dark")
            show(app.panel, in: light)
            try write(app.panel, "setup-permissions-switched-back-to-light")
        }
    }

    @Test("Every settings page in Journal, in both appearances and at minimum width")
    func settingsPages() throws {
        for (name, appearance) in [("light", light), ("dark", dark)] {
            try withJournal(builtIn: appearance) { app, _ in
                for destination in [ApplicationNavigationState.Destination.general, .recording,
                                    .transcription, .summary, .calendar, .storage] {
                    app.panel.setContentSize(NSSize(width: 1340, height: 820))
                    app.navigate(destination)
                    try write(app.panel, "settings-\(destination.rawValue)-\(name)")
                    app.panel.setContentSize(NSSize(width: 760, height: 680))
                    try write(app.panel, "settings-\(destination.rawValue)-\(name)-narrow")
                    if destination == .storage {
                        scrollToBottom(in: app.settings.content(for: destination))
                        try write(app.panel, "settings-storage-\(name)-narrow-bottom")
                    }
                }
            }
        }
        try withJournal(builtIn: dark) { app, _ in
            app.navigate(.transcription)
            show(app.panel, in: light)
            try write(app.panel, "settings-transcription-switched-to-light")
            show(app.panel, in: dark)
            try write(app.panel, "settings-transcription-switched-back-to-dark")
        }
    }

    @Test("Calendar selection with synthetic calendars, at narrow and wide widths")
    func calendarSelectionSettings() throws {
        let store = CalendarFixtureStore()
        let work = store.addCalendar("Рабочие встречи")
        _ = store.addCalendar("Личный календарь")
        _ = store.addCalendar("Очень длинное название общего календаря проектной команды")
        Config.update(path: ["calendar_ids"], value: [work.calendarIdentifier])
        for (name, appearance) in [("light", light), ("dark", dark)] {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 780),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let settings = SettingsController(hostWindow: panel,
                calendar: CalendarWatcher(store: store, authorizationStatus: { .fullAccess }))
            defer { _ = settings.stopForTermination(); panel.close() }
            panel.contentView = settings.content(for: .calendar)
            show(panel, in: appearance)
            try write(panel, "calendar-selection-\(name)")
            panel.setContentSize(NSSize(width: 500, height: 780))
            try write(panel, "calendar-selection-\(name)-narrow")
            #expect(panel.contentLayoutRect.width <= 502, "Long calendar titles must not widen the settings page")
            try withJournal(builtIn: appearance) { app, _ in
                let setup = SetupPage(calendar: CalendarWatcher(store: store, authorizationStatus: { .fullAccess }))
                defer { _ = setup.stopForTermination() }
                app.presentSetup(setup)
                try write(app.panel, "setup-calendar-selection-\(name)")
                app.panel.setContentSize(NSSize(width: 760, height: 680))
                try write(app.panel, "setup-calendar-selection-\(name)-narrow")
                scrollToBottom(in: setup.contentView)
                try write(app.panel, "setup-calendar-selection-\(name)-narrow-bottom")
            }
        }
    }

    @Test("Cloud-only transcription explains unavailable local speaker separation")
    func cloudOnlyPage() throws {
        try withFreshHome(config: [
            "transcription": ["enabled": true, "engine": "openai", "local_diarization": true],
        ]) { _ in
            for (name, appearance) in [("light", light), ("dark", dark)] {
                try withJournal(builtIn: appearance) { app, _ in
                    app.navigate(.transcription)
                    if Platform.supportsLocalModels {
                        try scrollToCard("transcription.local-diarization", in: app.panel)
                    }
                    try write(app.panel, "settings-transcription-cloud-only-\(name)")
                    app.panel.setContentSize(NSSize(width: 760, height: 680))
                    if Platform.supportsLocalModels {
                        try scrollToCard("transcription.local-diarization", in: app.panel)
                    }
                    try write(app.panel, "settings-transcription-cloud-only-\(name)-narrow")
                }
            }
        }
    }

    @Test("A long speaker-model error on the narrow transcription page",
          .enabled(if: Platform.supportsLocalModels))
    func diarizationErrorInNarrowSettings() throws {
        for (name, appearance) in [("light", light), ("dark", dark)] {
            try withJournal(builtIn: appearance) { app, _ in
                app.navigate(.transcription)
                app.panel.setContentSize(NSSize(width: 760, height: 680))
                let card = try #require(app.panel.contentView?.allDescendants
                    .compactMap { $0 as? ChoiceCard }
                    .first { $0.id == "diarization.nemotron-3" })
                card.report(localised(
                    "download error: The speaker model is incomplete or corrupt: "
                        + "Nemotron-3-Diarization.q8_0.gguf.",
                    "ошибка загрузки: The speaker model is incomplete or corrupt: "
                        + "Nemotron-3-Diarization.q8_0.gguf."))
                try scrollToDiarization(in: app.panel)
                try write(app.panel, "settings-transcription-\(name)-narrow-diarization-error")
            }
        }
    }

    @Test("Local and speaker download progress on the narrow transcription page",
          .enabled(if: Platform.supportsLocalModels))
    func modelDownloadProgressInNarrowSettings() throws {
        for (name, appearance) in [("light", light), ("dark", dark)] {
            try withJournal(builtIn: appearance) { app, _ in
                app.navigate(.transcription)
                app.panel.setContentSize(NSSize(width: 760, height: 680))
                for (id, fraction, shot) in [
                    ("parakeet", 0.37, "local"),
                    ("diarization.nemotron-3", 0.64, "diarization"),
                ] {
                    let card = try #require(app.panel.contentView?.allDescendants
                        .compactMap { $0 as? ChoiceCard }.first { $0.id == id })
                    let progress = try #require(card.allDescendants
                        .compactMap { $0 as? ModelDownloadProgress }.first)
                    let download = try #require(card.allDescendants
                        .compactMap { $0 as? NSButton }
                        .first { $0.identifier?.rawValue.contains(".download.") == true })
                    card.report("")
                    download.isHidden = true
                    progress.begin()
                    progress.update(fraction)
                    try scrollToCard("choice.\(id)", in: app.panel)
                    try write(app.panel, "settings-transcription-\(name)-narrow-\(shot)-progress")
                    progress.end()
                    download.isHidden = false
                }
            }
        }
    }

    @Test("About inside Journal, in both appearances")
    func aboutPage() throws {
        for (name, appearance) in [("light", light), ("dark", dark)] {
            try withJournal(builtIn: appearance) { app, _ in
                app.navigate(.about)
                try write(app.panel, "about-\(name)")
            }
        }
    }

    @Test("Every view on Journal's transcription page with its frame and control state")
    func viewTree() throws {
        try withJournal(builtIn: light) { app, _ in
            app.navigate(.transcription)
            let root = try #require(app.panel.contentView)
            root.layoutSubtreeIfNeeded()
            var lines: [String] = []
            describe(root, in: root, depth: 0, into: &lines)
            try lines.joined(separator: "\n").write(
                toFile: "\(directory)/tree.txt", atomically: true, encoding: .utf8)
        }
    }

    /// Put every scroller in a view at the end of its content, so a picture
    /// of it shows what is down there rather than what is at the top.
    @MainActor
    private func scrollToBottom(in view: NSView?) {
        guard let view else { return }
        view.layoutSubtreeIfNeeded()

        var pending = [view]
        while let next = pending.popLast() {
            pending.append(contentsOf: next.subviews)
            guard let scroll = next as? NSScrollView,
                  let document = scroll.documentView else { continue }
            // The forms in these windows are flipped, so the end of the
            // content is the largest y rather than the smallest.
            let hidden = document.frame.height - scroll.contentView.bounds.height
            guard hidden > 0 else { continue }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: hidden))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        view.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func scrollToDiarization(in panel: NSWindow) throws {
        try scrollToCard("choice.diarization.nemotron-3", in: panel)
    }

    @MainActor
    private func scrollToCard(_ id: String, in panel: NSWindow) throws {
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let card = try #require(content.allDescendants.first {
            $0.identifier?.rawValue == id
        })
        var ancestor = card.superview
        while ancestor != nil, !(ancestor is NSScrollView) { ancestor = ancestor?.superview }
        let scroll = try #require(ancestor as? NSScrollView)
        let document = try #require(scroll.documentView)
        let cardFrame = card.convert(card.bounds, to: document)
        let y = max(0, cardFrame.midY - scroll.contentView.bounds.height / 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        content.layoutSubtreeIfNeeded()
    }

    /// Hand the existing window to the other appearance, the way the Mac does.
    private func show(_ panel: NSWindow, in appearance: NSAppearance?) {
        NSApp.appearance = appearance
        panel.appearance = appearance
    }

    // MARK: - taking the picture

    /// Write the window's contents out, on a background.
    ///
    /// The background is the part worth explaining. `cacheDisplay` renders the
    /// views and nothing underneath them, so everything that is really the
    /// window rather than a view — the plain background, a tab view's material
    /// — comes out transparent, and a dark window's white text flattened onto
    /// white is a blank page. Rather than leave every reader of these files to
    /// know that, a plain view painted in `windowBackgroundColor` goes in
    /// behind the form for the length of the exposure.
    @MainActor
    private func write(_ panel: NSWindow, _ name: String) throws {
        let view = try #require(panel.contentView)
        view.layoutSubtreeIfNeeded()
        // A change of appearance is repainted on a later turn of the run loop.
        // Without this the first picture after one catches a window halfway.
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        view.displayIfNeeded()

        let bounds = view.bounds
        let ground = Ground(frame: bounds)
        ground.autoresizingMask = [.width, .height]
        view.addSubview(ground, positioned: .below, relativeTo: nil)
        defer { ground.removeFromSuperview() }

        let shot = try #require(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: shot)
        let png = try #require(shot.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
    }

    // MARK: - the listing

    @MainActor
    private func describe(
        _ view: NSView, in root: NSView, depth: Int, into lines: inout [String]
    ) {
        let frame = view.convert(view.bounds, to: root)
        lines.append(String(
            format: "%@%@ x=%.1f y=%.1f w=%.1f h=%.1f %@%@",
            String(repeating: "  ", count: depth),
            "\(type(of: view))",
            frame.origin.x, frame.origin.y, frame.width, frame.height,
            view.isHidden ? "HIDDEN " : "",
            label(view)))
        for sub in view.subviews { describe(sub, in: root, depth: depth + 1, into: &lines) }
    }

    /// Enough of a view to recognise it in the listing. A switch reports its
    /// state here because it will not report it in a picture: an `NSSwitch` is
    /// drawn by SwiftUI, and offscreen it comes out in the off position
    /// whatever it is set to.
    @MainActor
    private func label(_ view: NSView) -> String {
        if let toggle = view as? NSSwitch { return "SWITCH \(toggle.state == .on ? "ON" : "off")" }
        if let menu = view as? NSPopUpButton { return "POPUP \"\(menu.titleOfSelectedItem ?? "")\"" }
        if let button = view as? NSButton { return "button \"\(button.title.prefix(30))\"" }
        if let field = view as? NSTextField {
            let shown = field.stringValue.isEmpty
                ? (field.placeholderString.map { "placeholder \"\($0)\"" } ?? "")
                : "\"\(field.stringValue.prefix(48))\""
            return shown
        }
        if let image = view as? NSImageView {
            return "image \(image.image?.accessibilityDescription ?? "—")"
        }
        return ""
    }
}

/// The paper the picture is taken on; see `write(_:_:)`. It draws rather than
/// tints a layer so that `cacheDisplay` renders it, and it reads the colour
/// inside `draw` so the colour is the one this appearance asks for.
private final class Ground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// Journal's meeting and live pages, including window chrome, over synthetic data.
@Suite(
    .serialized, .enabled(if: ProcessInfo.processInfo.environment["VERBEMO_SHOTS"] != nil),
    .freshHome(config: speakerShotsConfig),
    .speaking(shotsLanguage))
@MainActor
struct WindowGallery {
    private var directory: String {
        ProcessInfo.processInfo.environment["VERBEMO_SHOTS"] ?? NSTemporaryDirectory()
    }
    private var light: NSAppearance? { NSAppearance(named: .aqua) }
    private var dark: NSAppearance? { NSAppearance(named: .darkAqua) }

    @Test("Journal's empty library and live transcript, in both appearances")
    func livePage() throws {
        for (name, appearance) in [("light", light), ("dark", dark)] {
            try withJournal(builtIn: appearance) { app, _ in
                app.update(state: .idle, elapsed: nil)
                app.updateAutoRecord(enabled: true, decision: localised("ready", "готов"))
                try write(app.panel, "journal-empty-\(name)")

                app.recordingTitle = localised("Release review", "Разбор релиза")
                app.update(state: .recording, elapsed: "12:04")
                app.updateLive(.init(
                    isRecording: true, isEnabled: true, entries: Self.conversation, status: .live))
                app.showActiveRecording()
                try write(app.panel, "journal-live-\(name)")
                app.panel.setContentSize(NSSize(width: 760, height: 680))
                try write(app.panel, "journal-live-\(name)-narrow")
            }
        }
    }

    @Test("Meeting summary, transcript and speaker processing states inside Journal")
    func meetingPages() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, appearance) in [("light", light), ("dark", dark)] {
            try withJournal(builtIn: appearance, root: root) { app, library in
                let table = try #require(library.listContentView.allDescendants
                    .compactMap { $0 as? MeetingTableView }.first)
                for (row, state) in [(0, "completed"), (1, "pending"), (2, "failed")] {
                    try #require(table.numberOfRows > row)
                    table.selectRowIndexes([row], byExtendingSelection: false)
                    try selectResult("transcript", in: library)
                    try write(app.panel, "journal-meeting-\(state)-\(name)")
                }
                table.selectRowIndexes([0], byExtendingSelection: false)
                try selectResult("summary", in: library)
                try write(app.panel, "journal-meeting-summary-\(name)")
                app.panel.setContentSize(NSSize(width: 760, height: 680))
                try write(app.panel, "journal-meeting-summary-\(name)-narrow")
                let inspector = try #require(library.toolbarContent.allDescendants
                    .compactMap { $0 as? NSButton }
                    .first { $0.identifier?.rawValue == "meeting.inspector" })
                _ = NSApp.sendAction(try #require(inspector.action), to: inspector.target, from: inspector)
                try write(app.panel, "journal-meeting-inspector-\(name)-narrow")
            }
        }
    }

    @Test("Transcript versions at Journal's minimum width, in both appearances")
    func meetingVersions() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026.08.20-1030")
        try TranscriptVersions.archiveCurrent(dir)
        try Transcript(engine: "whisper", model: "large-v3", created_at: "2026-08-20T12:00:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000,
                text: localised("The second transcript keeps the first result available.",
                                "Вторая расшифровка сохраняет первый результат доступным."))]).write(to: dir)
        for (name, appearance) in [("light", light), ("dark", dark)] {
            try withJournal(builtIn: appearance, root: root) { app, library in
                app.panel.setContentSize(NSSize(width: 760, height: 680))
                try selectResult("transcript", in: library)
                try write(app.panel, "journal-meeting-versions-\(name)-narrow")
            }
        }
    }

    private func selectResult(_ id: String, in library: MeetingLibraryController) throws {
        let button = try #require(library.contentView.allDescendants
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "meeting.result.\(id)" })
        _ = NSApp.sendAction(try #require(button.action), to: button.target, from: button)
    }

    // MARK: - what the pictures are of

    /// A few lines of a meeting, long enough to fill the transcript pane.
    /// These pictures introduce verbemo to readers of the matching-language
    /// README or landing page, so the example speech follows the interface.
    private static var conversation: [LiveTranscriptState.Entry] {
        [
            .speech(.init(speaker: .them, text: localised(
                "Let's go through the release.", "Давай пройдёмся по релизу."),
                          startMilliseconds: 0, isProvisional: false)),
            .speech(.init(speaker: .you, text: localised(
                "Yes — two changes and the notes are written.",
                "Да — две правки и заметки готовы."),
                          startMilliseconds: 2600, isProvisional: false)),
            .speech(.init(speaker: .them, text: localised(
                "Did we fix the wait after the call?", "А ожидание после звонка починили?"),
                          startMilliseconds: 6100, isProvisional: false)),
            .speech(.init(speaker: .you, text: localised(
                "Fifteen seconds now, down from ninety.",
                "Теперь пятнадцать секунд вместо девяноста."),
                          startMilliseconds: 9400, isProvisional: true)),
        ]
    }

    /// Four sessions on disk, covering the four things the list can say about
    /// one. Written into a folder of its own so nothing here can be confused
    /// for a real recording.
    private static func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbemo-gallery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try session(
            in: root, named: "2026.08.20-1030",
            meta: [
                "started": "2026-08-20T10:30:00Z", "duration_seconds": 2760,
                "title": localised("Release review", "Разбор релиза"),
                "trigger": "mic-activity",
            ],
            transcript: true, speakers: true, summary: true)
        var completed = DiarizationState(
            request: .init(engine: "parakeet", threshold: 0.6), status: .completed)
        completed.confirmedSpeakers = 3
        completed.hasUnknown = true
        try completed.write(to: root.appendingPathComponent("2026.08.20-1030"))

        try session(
            in: root, named: "2026.08.19-1615",
            meta: [
                "started": "2026-08-19T16:15:00Z", "duration_seconds": 1500,
                "title": localised("Weekly with Fyodor", "Планёрка с Фёдором"),
                "trigger": "calendar", "files": ["source": "source.caf"],
            ],
            transcript: true, speakers: false, summary: false)
        try DiarizationState(
            request: .init(engine: "parakeet", threshold: 0.6), status: .pending)
            .write(to: root.appendingPathComponent("2026.08.19-1615"))
        try TestAudio.write(to: root.appendingPathComponent("2026.08.19-1615/source.caf"), seconds: 2) { _, _ in 0 }

        try session(
            in: root, named: "2026.08.19-0905",
            meta: [
                "started": "2026-08-19T09:05:00Z", "duration_seconds": 480,
                "title": localised("Call with the studio", "Звонок со студией"),
                "trigger": "mic-activity",
                "files": ["source": "source.caf"],
                SessionState.Key.transcriptionFailed:
                    "no spoken audio in the recording",
            ],
            transcript: false, speakers: false, summary: false)
        var failedDiarization = DiarizationState(
            request: .init(engine: "parakeet", threshold: 0.6), status: .failed)
        failedDiarization.reason = localised("Model unavailable", "Модель недоступна")
        try failedDiarization.write(to: root.appendingPathComponent("2026.08.19-0905"))
        try TestAudio.write(to: root.appendingPathComponent("2026.08.19-0905/source.caf"), seconds: 2) { _, _ in 0 }

        try session(
            in: root, named: "2026.08.18-1400",
            meta: [
                "started": "2026-08-18T14:00:00Z", "duration_seconds": 3600,
                "title": localised("Design conversation", "Разговор про дизайн"),
                "trigger": "manual",
            ],
            transcript: true, speakers: true, summary: true)

        return root
    }

    private static func session(
        in root: URL, named name: String, meta: [String: Any],
        transcript: Bool, speakers: Bool, summary: Bool
    ) throws {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: dir.appendingPathComponent("meta.json"))

        if transcript {
            let json = Transcript(
                engine: "parakeet", model: "v3", created_at: "2026-08-20T11:20:00Z",
                segments: [
                    .init(speaker: "me", start_ms: 0, end_ms: 2400,
                          text: localised(
                            "Let's go through what's left.",
                            "Давай пройдёмся по тому, что осталось.")),
                    .init(speaker: "them A", start_ms: 2400, end_ms: 6100,
                          text: localised(
                            "Two edits and the release notes.",
                            "Две правки и заметки к релизу.")),
                    .init(speaker: "them B", start_ms: 6100, end_ms: 9000,
                          text: localised("I'll take the checklist.", "Я возьму чек-лист.")),
                ]
            )
            try JSONEncoder().encode(json)
                .write(to: dir.appendingPathComponent("transcript.json"))
        }
        if speakers {
            try SpeakerNames(speakers: [
                "them A": .init(name: localised("Fyodor", "Фёдор"), source: .model),
                "them B": .init(name: localised("Maria", "Мария"), source: .manual),
            ]).write(to: dir)
        }
        if summary {
            try Data(localised(
                "# notes\n\nTwo changes, and the notes are written.\n",
                "# заметки\n\nДве правки, и заметки готовы.\n"
            ).utf8)
                .write(to: dir.appendingPathComponent("summary.md"))
        }
    }

    /// The same exposure as `WindowShots.write(_:_:)` — see the comment there
    /// about the background — except that it photographs the window's own
    /// frame view rather than its content view, so the title bar and the three
    /// buttons in the corner are in the picture. That is the difference
    /// between a screenshot of a Mac window and a rectangle of controls, and
    /// this suite's whole errand is showing somebody what verbemo looks like.
    ///
    /// The buttons come out grey rather than red, yellow and green: they are
    /// drawn for a window that is not the active application's, and a test
    /// binary is not an application that macOS will activate. An inactive
    /// window is a real state, and it is the one these pictures are of.
    @MainActor
    private func write(_ panel: NSWindow, _ name: String) throws {
        let exposed = panel.contentView?.superview ?? panel.contentView
        let view = try #require(exposed)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        view.displayIfNeeded()

        let bounds = view.bounds
        let ground = GalleryGround(frame: bounds)
        ground.autoresizingMask = [.width, .height]
        view.addSubview(ground, positioned: .below, relativeTo: nil)
        defer { ground.removeFromSuperview() }

        let shot = try #require(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: shot)
        let png = try #require(shot.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
    }
}

/// Only ApplicationWindow creates an NSWindow; every fixture uses its real pages.
@MainActor
private func withJournal(
    builtIn appearance: NSAppearance?, root: URL? = nil,
    _ body: (ApplicationWindow, MeetingLibraryController) throws -> Void
) throws {
    _ = NSApplication.shared
    let previousAppearance = NSApp.appearance
    defer { NSApp.appearance = previousAppearance }
    NSApp.appearance = appearance
    var window: ApplicationWindow?
    appearance?.performAsCurrentDrawingAppearance { window = ApplicationWindow() }
    let app = try #require(window)
    defer { app.hide() }
    app.panel.appearance = appearance
    app.panel.setContentSize(NSSize(width: 1340, height: 820))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let library = MeetingLibraryController(
        root: root ?? Home.current.url.appendingPathComponent("meetings"),
        pasteboard: pasteboard, hostWindow: app.panel)
    library.onRetryDiarization = { _ in }
    library.onSkipDiarization = { _ in }
    app.libraryProvider = { library }
    try body(app, library)
}

private final class GalleryGround: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// `VERBEMO_SHOTS_LANGUAGE`, or English — put in force by each suite's trait
/// for its own tests' tasks rather than for the process.
private let shotsLanguage: InterfaceLanguage =
    ProcessInfo.processInfo.environment["VERBEMO_SHOTS_LANGUAGE"]
        .flatMap(InterfaceLanguage.init(rawValue:)) ?? .english

private let speakerShotsConfig = #"{"transcription":{"enabled":true,"engine":"parakeet","local_diarization":true}}"#

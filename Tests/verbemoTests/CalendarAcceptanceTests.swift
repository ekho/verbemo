import AppKit
import Testing
@testable import verbemo

/// Opt-in interactive fixture: real Journal UI, synthetic event source, no EventKit or audio capture.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VERBEMO_CALENDAR_ACCEPTANCE"] != nil))
@MainActor
struct CalendarAcceptanceTests {
    @Test(.speaking(.russian)) func interactiveJournal() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VERBEMO_CALENDAR_ACCEPTANCE"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Home.process.writeConfig(["interface_language": "ru", "interface_theme": "dark", "calendar": true,
            "summary": ["enabled": false], "speaker_names": ["enabled": false], "transcription": ["enabled": false]])
        let root = Home.process.url.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().date(from: "2026-10-21T10:00:00Z")!
        func event(_ id: String, _ title: String, day: Int = 0) -> CalendarWatcher.Meeting {
            let start = now.addingTimeInterval(Double(day) * 86400)
            return .init(id: id, title: title, start: start, end: start.addingTimeInterval(3600),
                attendees: ["Анна Тестовая", "Михаил Тестовый"], link: nil, looksLikeCall: true,
                calendarTitle: "Синтетический календарь", agenda: "Проверяем выбор события, поиск и сохранность ручных имён. Реальные календари не читаются.",
                participants: [.init(id: "anna", name: "Анна Тестовая"), .init(id: "mikhail", name: "Михаил Тестовый")],
                timeZoneIdentifier: "Europe/Moscow")
        }
        let events = [event("planning", "Планирование интерфейса"), event("review", "Проверка календаря", day: 1),
                      event("deleted", "Удалённое событие")]
        let dir = root.appendingPathComponent("2026.10.21-1300 Приёмка календаря")
        try FileManager.default.moveItem(at: SessionFixture.make(meta: ["title": "Приёмка календаря", "started": "2026-10-21T10:00:00Z", "duration_seconds": 600]), to: dir)
        PostProcessor.rename("them A", to: "Имя вручную", in: dir)
        _ = try TranscriptVersions.archiveCurrent(dir)
        try Transcript(engine: "whisper", model: "test-current", created_at: "2026-10-21T11:00:00Z", segments: SessionFixture.meeting).write(to: dir)
        let app = ApplicationWindow()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let library = MeetingLibraryController(root: root, pasteboard: pasteboard, hostWindow: app.panel)
        let load: CalendarEventPicker.Loader = { query in
            if query.title == "нетдоступа" { throw CalendarSelectionError.accessDenied }
            return events.filter(query.matches)
        }
        let resolve: CalendarEventPicker.Resolver = { selected in
            guard selected.id != "deleted" else { throw CalendarSelectionError.missingEvent }
            return selected
        }
        library.calendarSearch = load; library.calendarResolve = resolve
        app.libraryProvider = { library }
        app.calendarSearch = load; app.calendarResolve = resolve
        app.recordingCalendar = { _ in (events[0], events) }
        var drafts: [[String: String]] = []
        app.onStartRecording = { title, event in drafts.append(["title": title, "event_id": event?.id ?? ""]) }
        NSApp.setActivationPolicy(.regular)
        app.show(); app.bringToFront()
        app.panel.title = "Verbemo — Calendar acceptance (synthetic)"
        defer { app.hide(); app.settings.setup.stop() }
        try Data(dir.path.utf8).write(to: output.appendingPathComponent("fixture-path.txt"))
        try Data("ready".utf8).write(to: output.appendingPathComponent("ready"))
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline && !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish").path) {
            while let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("finish").path), "Interactive acceptance timed out without completion")
        #expect(!drafts.isEmpty, "Complete a synthetic recording draft through the UI")
        let result: [String: Any] = ["drafts": drafts, "metadata": SessionState.read(dir) ?? [:],
            "manualName": SpeakerNames.read(from: dir)?.speakers["them A"]?.name ?? "", "versions": TranscriptVersions.read(dir).count]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"))
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.name == "Имя вручную")
        #expect(TranscriptVersions.read(dir).count >= 2)
    }
}

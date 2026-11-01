import AppKit
import Testing

@testable import verbemo

@Suite(.serialized, .freshHome(config: #"{"speaker_names":{"enabled":false},"summary":{"enabled":false}}"#))
@MainActor
struct RecordingsCopySummaryTests {
    private func invoke(_ item: NSMenuItem) throws {
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    }

    @Test("Copy menu actions are unavailable without a selected recording")
    func noRecording() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: Home.current.url, pasteboard: pasteboard, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        let button = try #require(library.toolbarContent.allDescendants.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "meeting.copy"
        })
        #expect(button.target === library)
        #expect(button.action != nil)
        #expect(library.makeCopyMenu().items.allSatisfy { !$0.isEnabled })
    }

    @Test("Copy follows current and archived versions and refuses a pending request")
    func selectedVersion() async throws {
        let root = Home.current.url.appendingPathComponent("recordings")
        let session = root.appendingPathComponent("2026-10-20-meeting")
        let archive = session.appendingPathComponent("transcripts/old")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: session.appendingPathComponent("meta.json"))
        for (dir, engine, summary) in [(archive, "parakeet", "## Archived\n\n- Old result\n"),
                                       (session, "whisper", "## Current\n\n- New result\n")] {
            try Transcript(engine: engine, model: "test", created_at: "2026-10-20T09:00:00Z",
                segments: [.init(speaker: "A", start_ms: 0, end_ms: 1000, text: engine)])
                .write(to: dir)
            try Data(summary.utf8).write(to: dir.appendingPathComponent("summary.md"))
        }
        try Data("gigaam".utf8).write(to: session.appendingPathComponent(TranscriptVersions.requestFile))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, pasteboard: pasteboard, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        let selector = try #require(library.contentView.allDescendants.compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "transcript-versions"
        })
        #expect(selector.numberOfItems == 3)
        #expect(selector.indexOfSelectedItem == 1)
        let copy = library.makeCopyMenu().items[1]
        #expect(copy.isEnabled)
        try invoke(copy)
        #expect(pasteboard.string(forType: .string) == "## Current\n\n- New result\n")
        selector.selectItem(at: 0)
        selector.sendAction(selector.action, to: selector.target)
        try invoke(copy)
        #expect(pasteboard.string(forType: .string) == "## Archived\n\n- Old result\n")
        library.refresh()
        await library.settled()
        #expect(selector.indexOfSelectedItem == 0)
        selector.selectItem(at: 2)
        selector.sendAction(selector.action, to: selector.target)
        #expect(library.makeCopyMenu().items.allSatisfy { !$0.isEnabled })
        // A menu opened for a completed version cannot copy after the selection changes.
        try invoke(copy)
        #expect(pasteboard.string(forType: .string) == "## Archived\n\n- Old result\n")
        selector.selectItem(at: 0)
        selector.sendAction(selector.action, to: selector.target)
        try FileManager.default.removeItem(at: archive.appendingPathComponent("summary.md"))
        try invoke(copy)
        #expect(!library.makeCopyMenu().items[1].isEnabled)
        #expect(pasteboard.string(forType: .string) == "## Archived\n\n- Old result\n")
        library.refresh()
        await library.settled()
        #expect(!library.makeCopyMenu().items[1].isEnabled)
        selector.selectItem(at: 1)
        selector.sendAction(selector.action, to: selector.target)
        #expect(library.makeCopyMenu().items[1].isEnabled)
    }

    @Test("Missing, empty and unreadable summaries disable copying", arguments: ["missing", "empty", "blank", "invalid", "denied"])
    func unavailableSummary(_ state: String) throws {
        let root = Home.current.url.appendingPathComponent("recordings")
        let dir = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("meta.json"))
        let file = dir.appendingPathComponent("summary.md")
        if state != "missing" {
            let data: Data
            switch state {
            case "invalid": data = Data([0xff])
            case "blank": data = Data(" \n\t".utf8)
            case "denied": data = Data("Unreadable".utf8)
            default: data = Data()
            }
            try data.write(to: file)
        }
        if state == "denied" { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path) }
        defer { if state == "denied" { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) } }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep clipboard", forType: .string)
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, pasteboard: pasteboard, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        let copy = library.makeCopyMenu().items[1]
        #expect(!copy.isEnabled)
        try invoke(copy)
        #expect(pasteboard.string(forType: .string) == "Keep clipboard")
    }

    @Test("The copy menu offers plain text and Markdown and clears stale rich text")
    func pasteboardFormats() throws {
        let root = Home.current.url.appendingPathComponent("recordings")
        let dir = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("meta.json"))
        let markdown = "## Решения\n\n- **First**\n  - Nested\n"
        try Data(markdown.utf8).write(to: dir.appendingPathComponent("summary.md"))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(Data("old".utf8), forType: .rtf)
        let app = ApplicationWindow()
        let library = MeetingLibraryController(root: root, pasteboard: pasteboard, hostWindow: app.panel)
        app.libraryProvider = { library }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        app.navigate(.allMeetings)
        defer { withExtendedLifetime(app) {} }
        let menu = library.makeCopyMenu()
        try invoke(menu.items[0])
        #expect(pasteboard.string(forType: .string) == "Решения\n• First\n• Nested")
        #expect(pasteboard.data(forType: .rtf) == nil)
        try invoke(menu.items[1])
        #expect(pasteboard.string(forType: .string) == markdown)
    }

    @Test("The copy button and menu use the interface language", arguments: InterfaceLanguage.allCases)
    func localizedCopyMenu(_ language: InterfaceLanguage) throws {
        try InterfaceLanguage.$scoped.withValue(language) {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let app = ApplicationWindow()
            let library = MeetingLibraryController(root: Home.current.url, pasteboard: pasteboard, hostWindow: app.panel)
            app.libraryProvider = { library }
        app.panel.contentView?.layoutSubtreeIfNeeded()
            app.navigate(.allMeetings)
            defer { withExtendedLifetime(app) {} }
            let button = try #require(library.toolbarContent.allDescendants.compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "meeting.copy"
            })
            #expect(button.title == (language == .english ? "Copy" : "Копировать"))
            #expect(library.makeCopyMenu().items.map(\.title) == (language == .english
                ? ["Summary · Text", "Summary · Markdown", "Transcript · Text", "Transcript · Markdown"]
                : ["Сводка · Текст", "Сводка · Markdown", "Расшифровка · Текст", "Расшифровка · Markdown"]))
        }
    }
}

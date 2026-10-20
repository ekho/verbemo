import AppKit
import Testing

@testable import verbemo

@Suite(.serialized, .freshHome(config: #"{"speaker_names":{"enabled":false},"summary":{"enabled":false}}"#))
struct RecordingsCopySummaryTests {
    @Test("Copy is unavailable without a selected recording")
    @MainActor
    func noRecording() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let window = RecordingsWindow(root: Home.current.url, pasteboard: pasteboard)
        let button = try #require(window.view?.allDescendants.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "copy-summary"
        })
        #expect(!button.isEnabled)
        withExtendedLifetime(window) {}
    }

    @Test("Copy follows current and archived versions and refuses a pending request")
    @MainActor
    func selectedVersion() async throws {
        _ = NSApplication.shared
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
        let window = RecordingsWindow(root: root, pasteboard: pasteboard)
        let views = try #require(window.view).allDescendants
        let button = try #require(views.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "copy-summary"
        })
        let selector = try #require(views.compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "transcript-versions"
        })
        #expect(selector.numberOfItems == 3)
        #expect(selector.indexOfSelectedItem == 1)
        #expect(button.isEnabled)
        #expect(button.keyEquivalent == "c")
        #expect(button.keyEquivalentModifierMask == [.command, .shift])
        // performClick's animation can stop the async Swift Testing runner's main run loop.
        #expect(button.sendAction(button.action, to: button.target))
        #expect(pasteboard.string(forType: .string) == "## Current\n\n- New result\n")
        #expect(button.title == "Copied")
        selector.selectItem(at: 0)
        selector.sendAction(selector.action, to: selector.target)
        #expect(button.title == "Copy summary")
        #expect(button.sendAction(button.action, to: button.target))
        #expect(pasteboard.string(forType: .string) == "## Archived\n\n- Old result\n")
        window.show()
        await window.settled()
        #expect(selector.indexOfSelectedItem == 0)
        selector.selectItem(at: 2)
        selector.sendAction(selector.action, to: selector.target)
        #expect(!button.isEnabled)
        // Even a stale action must not copy the completed result beside this request.
        button.sendAction(button.action, to: button.target)
        #expect(pasteboard.string(forType: .string) == "## Archived\n\n- Old result\n")
        selector.selectItem(at: 0)
        selector.sendAction(selector.action, to: selector.target)
        try FileManager.default.removeItem(at: archive.appendingPathComponent("summary.md"))
        #expect(button.sendAction(button.action, to: button.target))
        #expect(!button.isEnabled)
        #expect(pasteboard.string(forType: .string) == "## Archived\n\n- Old result\n")
        window.show()
        await window.settled()
        #expect(!button.isEnabled)
        selector.selectItem(at: 1)
        selector.sendAction(selector.action, to: selector.target)
        #expect(button.isEnabled)
        withExtendedLifetime(window) {}
    }

    @Test("Missing, empty and unreadable summaries disable copying", arguments: ["missing", "empty", "blank", "invalid", "denied"])
    @MainActor
    func unavailableSummary(_ state: String) throws {
        _ = NSApplication.shared
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
        let window = RecordingsWindow(root: root, pasteboard: pasteboard)
        let button = try #require(window.view?.allDescendants.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "copy-summary"
        })
        #expect(!button.isEnabled)
        button.sendAction(button.action, to: button.target)
        #expect(pasteboard.string(forType: .string) == "Keep clipboard")
        withExtendedLifetime(window) {}
    }

    @Test("Copy offers Markdown and formatted RTF without a fixed text colour", arguments: [NSAppearance.Name.aqua, .darkAqua])
    @MainActor
    func pasteboardFormats(_ appearance: NSAppearance.Name) throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let markdown = "## Решения\n\n- **First**\n- Second\n"
        try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            #expect(RecordingsWindow.copy(summary: markdown, to: pasteboard))
        }
        #expect(pasteboard.string(forType: .string) == markdown)
        let rtf = try #require(pasteboard.data(forType: .rtf))
        let pasted = try NSAttributedString(data: rtf,
            options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(pasted.string == "Решения\n• First\n• Second")
        let first = (pasted.string as NSString).range(of: "First")
        let font = try #require(pasted.attribute(.font, at: first.location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        // Cocoa writes a default colour table even for uncoloured text; cf0 is automatic.
        #expect(String(decoding: rtf, as: UTF8.self).range(of: #"\\cf[1-9]"#,
                                                        options: .regularExpression) == nil)
    }

    @Test("A failed RTF conversion still replaces the clipboard with Markdown")
    @MainActor
    func textFallback() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(Data("old".utf8), forType: .rtf)
        #expect(RecordingsWindow.copy(summary: "# Plain fallback", to: pasteboard, rtf: { _ in
            throw CocoaError(.fileWriteUnknown)
        }))
        #expect(pasteboard.string(forType: .string) == "# Plain fallback")
        #expect(pasteboard.data(forType: .rtf) == nil)
    }

    @Test("Copied RTF preserves nested paragraph indentation")
    @MainActor
    func richTextListIndents() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        RecordingsWindow.copy(summary: "- Stages:\n  1. Upload\n  2. Generate\n\nTail", to: pasteboard)
        let rtf = try #require(pasteboard.data(forType: .rtf))
        let pasted = try NSAttributedString(data: rtf,
            options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let range = (pasted.string as NSString).range(of: "1. Upload")
        try #require(range.location != NSNotFound)
        let paragraph = try #require(pasted.attribute(.paragraphStyle, at: range.location,
                                                      effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.firstLineHeadIndent == 20)
        #expect(paragraph.headIndent == 40)
    }

    @Test("The copy action confirms in the interface language", arguments: InterfaceLanguage.allCases)
    @MainActor
    func localizedConfirmation(_ language: InterfaceLanguage) throws {
        try InterfaceLanguage.$scoped.withValue(language) {
            _ = NSApplication.shared
            let root = Home.current.url.appendingPathComponent("recordings")
            let session = root.appendingPathComponent("meeting")
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: session.appendingPathComponent("meta.json"))
            try Data("Summary".utf8).write(to: session.appendingPathComponent("summary.md"))
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let window = RecordingsWindow(root: root, pasteboard: pasteboard)
            let button = try #require(window.view?.allDescendants.compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "copy-summary"
            })
            #expect(button.title == (language == .english ? "Copy summary" : "Скопировать саммари"))
            #expect(button.sendAction(button.action, to: button.target))
            #expect(button.title == (language == .english ? "Copied" : "Скопировано"))
            withExtendedLifetime(window) {}
        }
    }
}

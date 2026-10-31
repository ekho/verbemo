import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct MeetingTranscriptReadingTests {
    @Test func wideningALongUtteranceKeepsItsSegment() throws {
        _ = NSApplication.shared
        let view = MeetingTranscriptView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let transcript = Transcript(engine: "test", model: "test", created_at: "test", segments: (0..<20).map {
            .init(speaker: "them A", start_ms: $0 * 1000, end_ms: ($0 + 1) * 1000,
                  text: String(repeating: "Длинная учебная реплика. ", count: 100)) })
        view.update(transcript: transcript, names: nil, participants: [], canEdit: false)
        view.layoutSubtreeIfNeeded()
        let table = try #require(view.documentView as? NSTableView)
        view.restoreReadingPosition(.init(segment: 8, offset: table.rect(ofRow: 8).height * 0.85))
        #expect(view.readingPosition()?.segment == 8)
        window.setContentSize(NSSize(width: 1000, height: 300))
        view.layoutSubtreeIfNeeded()
        #expect(view.readingPosition()?.segment == 8)
    }
    @Test func transientCloseKeepsTheChosenSearchFocus() async throws {
        _ = NSApplication.shared
        let search = NSSearchField()
        let pencil = SpeakerEditButton()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSStackView(views: [search, pencil])
        defer { window.orderOut(nil) }
        window.makeFirstResponder(search)
        let chosen = window.firstResponder
        var restores = 0
        pencil.onRestoreFocus = { restores += 1; window.makeFirstResponder(pencil) }
        pencil.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        for _ in 0..<4 { await Task.yield() }
        #expect(window.firstResponder === chosen)
        #expect(restores == 0)
    }
    @Test func searchAndResizeRetainTheReadingSegment() throws {
        _ = NSApplication.shared
        let view = MeetingTranscriptView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let transcript = Transcript(engine: "test", model: "fixture", created_at: "test", segments: (0..<180).map {
            .init(speaker: "them A", start_ms: $0 * 10000, end_ms: ($0 + 1) * 10000,
                  text: "Реплика \($0). " + String(repeating: "Длинная учебная фраза. ", count: 8))
        })
        view.update(transcript: transcript, names: nil, participants: [], canEdit: false)
        view.layoutSubtreeIfNeeded()
        view.revealSearchSegment(80)
        let before = try #require(view.readingPosition())
        #expect(before.segment > 0)
        view.setSearch(matches: [80: [NSRange(location: 0, length: 7)]])
        let afterSearch = try #require(view.readingPosition())
        #expect(afterSearch.segment == before.segment)
        #expect(abs(afterSearch.offset - before.offset) < 1)
        window.setContentSize(NSSize(width: 420, height: 320))
        view.layoutSubtreeIfNeeded()
        let afterResize = try #require(view.readingPosition())
        #expect(afterResize.segment == before.segment)
        #expect(abs(afterResize.offset - before.offset) < 1)
        view.setSearch(matches: [:])
        #expect(view.readingPosition()?.segment == before.segment)
    }
    @Test func unchangedRefreshRetainsTheSelectedText() throws {
        _ = NSApplication.shared
        let view = MeetingTranscriptView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let transcript = Transcript(engine: "test", model: "fixture", created_at: "test", segments: [
            .init(speaker: "them A", start_ms: 0, end_ms: 1000, text: "Выделенная фраза 🎙️")
        ])
        view.update(transcript: transcript, names: nil, participants: [], canEdit: false)
        view.layoutSubtreeIfNeeded()
        let table = try #require(view.documentView as? NSTableView)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let words = try #require(cell.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "transcript.words" })
        words.selectText(nil)
        let editor = try #require(words.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: 10))
        view.update(transcript: transcript, names: nil, participants: [], canEdit: false)
        view.layoutSubtreeIfNeeded()
        #expect(words.currentEditor() === editor)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 10))
    }

}

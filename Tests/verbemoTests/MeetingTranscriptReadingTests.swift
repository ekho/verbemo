import AppKit
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct MeetingTranscriptReadingTests {
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
        view.restoreReadingPosition(before)
        let afterResize = try #require(view.readingPosition())
        #expect(afterResize.segment == before.segment)
        #expect(abs(afterResize.offset - before.offset) < 1)
        view.setSearch(matches: [:])
        #expect(view.readingPosition()?.segment == before.segment)
    }
}

import AppKit
import Testing

@testable import verbemo

/// The live page keeps its rows separate as transcript and import states change.
@Suite(.serialized)
struct LiveTranscriptContentTests {
    @Test(.freshHome, .speaking(.russian)) @MainActor
    func missingModelOffersAnExplicitDownloadAndErrorsOfferRetry() throws {
        let content = LiveTranscriptContent()
        var requests: [Bool] = []
        content.onToggleLive = { requests.append($0) }
        content.updateLive(.init(isRecording: true, isEnabled: true, entries: [], status: .modelMissing))
        let download = try #require(content.contentView.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "live.download" })
        #expect(!download.isHidden)
        #expect(download.title == "Скачать модель")
        #expect(NSApp.sendAction(try #require(download.action), to: download.target, from: download))
        #expect(requests == [true])
        content.updateLive(.init(isRecording: true, isEnabled: false, entries: [], status: .paused))
        #expect(download.isHidden)
        content.updateLive(.init(isRecording: true, isEnabled: true, entries: [], status: .error("Offline")))
        #expect(!download.isHidden)
        #expect(download.title == "Повторить")
        content.updateLive(.init(isRecording: false, isEnabled: true, entries: [], status: .idle))
        #expect(download.isHidden)
    }

    @Test("Live speaker labels use the adaptive label colour", .freshHome, .speaking(.english))
    @MainActor
    func liveSpeakerLabelsFollowTheAppearance() throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = previousAppearance }

        let app = ApplicationWindow()
        defer { app.hide() }
        app.panel.appearance = NSAppearance(named: .darkAqua)
        app.update(state: .recording, elapsed: "00:01")
        app.showActiveRecording()
        app.updateLive(.init(
            isRecording: true,
            isEnabled: true,
            entries: [
                .speech(.init(
                    speaker: .them,
                    text: "Verbemo",
                    startMilliseconds: 0,
                    isProvisional: false,
                )),
                .speech(.init(
                    speaker: .you,
                    text: "Verbemo",
                    startMilliseconds: 1,
                    isProvisional: false,
                )),
            ],
            status: .live
        ))

        let transcript = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? NSTextView }.first)
        for label in ["Them", "You"] {
            let range = (transcript.string as NSString).range(of: label)
            try #require(range.location != NSNotFound)
            let colour = transcript.textStorage?.attribute(
                .foregroundColor,
                at: range.location,
                effectiveRange: nil
            ) as? NSColor
            #expect(colour == .labelColor, "\(label) does not follow the window appearance")
        }
    }

    @Test("Live rows stay separate without resizing the application window", .freshHome)
    @MainActor
    func everyStateIsAnArrangement() throws {
        _ = NSApplication.shared
        let app = ApplicationWindow()
        defer { app.hide() }
        app.panel.setContentSize(NSSize(width: 1340, height: 820))
        app.update(state: .recording, elapsed: "03:06")
        app.showActiveRecording()
        let content = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? MediaDropView }.first)
        let rows = try #require(content.subviews.compactMap { $0 as? NSStackView }.first)
        let originalFrame = app.panel.frame

        let speech = LiveTranscriptState.Entry.speech(.init(
            speaker: .you, text: "verbemo", startMilliseconds: 0, isProvisional: false))

        app.updateLive(.init(isRecording: true, isEnabled: false, entries: [], status: .paused))
        check(rows, content, "recording, live off")
        app.updateConfigProblem("The config file could not be read")
        check(rows, content, "configuration problem")

        app.updateImport(.init(
            source: URL(fileURLWithPath: "/tmp/interview.mov"),
            index: 1, total: 2, stage: .checking, fraction: nil))
        check(rows, content, "recording while checking an import")
        app.updateImport(.init(
            source: URL(fileURLWithPath: "/tmp/interview.mov"),
            index: 1, total: 2, stage: .normalizing, fraction: 0.5))
        check(rows, content, "recording while converting an import")

        app.updateLive(.init(
            isRecording: true, isEnabled: true, entries: [speech], status: .live))
        check(rows, content, "recording, transcript open")
        app.updateConfigProblem(nil)
        app.updateLive(.init(
            isRecording: false, isEnabled: true, entries: [speech], status: .idle))
        check(rows, content, "stopped, transcript folded away")
        #expect(app.panel.frame == originalFrame)

        for height in [680.0, 820.0] as [CGFloat] {
            app.panel.setContentSize(NSSize(width: 760, height: height))
            check(rows, content, "window resized to \(height)")
        }
    }

    /// Every visible row exactly `spacing` below the one above it, the first
    /// at the top inset and enough room in the mounted content to hold them.
    @MainActor
    private func check(
        _ rows: NSStackView, _ content: NSView, _ state: String
    ) {
        content.window?.contentView?.layoutSubtreeIfNeeded()
        let shown = rows.views.filter { !$0.isHidden }
        var expected = rows.edgeInsets.top
        for row in shown {
            let top = rows.bounds.height - row.frame.maxY
            #expect(abs(top - expected) < 0.5,
                    "\(state): \(describe(row)) is at \(top), not \(expected)")
            expected = top + row.frame.height + rows.spacing
        }
        #expect(rows.fittingSize.height <= content.bounds.height + 0.5,
                "\(state): the content is shorter than its rows")
    }

    @MainActor
    private func describe(_ view: NSView) -> String {
        if let button = view as? NSButton { return button.title }
        if let field = view as? NSTextField { return field.stringValue }
        if let stack = view as? NSStackView {
            return stack.views.map { describe($0) }.joined(separator: "+")
        }
        return "\(type(of: view))"
    }
}

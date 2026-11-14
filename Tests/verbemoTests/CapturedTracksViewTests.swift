import AppKit
import Testing
@testable import verbemo

@Suite(.serialized)
@MainActor
struct CapturedTracksViewTests {
    static func track(_ key: String, name: String = "", local: Bool = false) -> CallAudioMetadata.Track {
        .init(fileKey: key, sourceID: "private-source", speakerID: key, participantID: "private-person",
              name: name, isLocal: local, generation: 1, sampleRate: 48000)
    }

    @Test(.freshHome, .speaking(.english), arguments: [760, 1340])
    func currentSourceAndTracksAreIndependentOfLiveText(width: Int) throws {
        let app = ApplicationWindow()
        defer { app.hide() }
        app.panel.setContentSize(NSSize(width: width, height: 600))
        app.update(state: .recording, elapsed: "00:05")
        app.showActiveRecording()
        app.updateLive(.init(isRecording: true, isEnabled: false, entries: [], status: .idle))
        let view = try #require(app.panel.contentView?.allDescendants.compactMap { $0 as? LiveTranscriptView }.first)
        let source = try #require(view.allDescendants.first { $0.identifier?.rawValue == "recording.source" } as? NSTextField)
        let scroll = try #require(view.allDescendants.first { $0.identifier?.rawValue == "recording.tracks" } as? NSScrollView)
        func rows() -> [NSTextField] {
            view.allDescendants.compactMap { $0 as? NSTextField }.filter { $0.identifier?.rawValue == "recording.track" }
        }
        let tracks = [Self.track("local", name: "Alex", local: true), Self.track("remote", name: "Sam"), Self.track("unknown")]
        app.updateCaptureSource(.preparing, tracks: tracks)
        #expect(source.stringValue == "Preparing call audio…")
        #expect(scroll.isHidden)
        app.updateCaptureSource(.direct)
        #expect(rows().map(\.stringValue) == ["No participant audio is arriving"])
        app.updateCaptureSource(.direct, tracks: tracks)
        app.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(source.stringValue == "Separate KTalk participant tracks")
        #expect(!scroll.isHiddenOrHasHiddenAncestor)
        #expect(rows().map(\.stringValue) == ["You — Alex", "Participant — Sam", "Participant — name unknown"])
        #expect(rows().allSatisfy { $0.accessibilityLabel() == $0.stringValue && $0.visibleRect.height > 0 })
        #expect(view.allDescendants.compactMap { $0 as? AudioLevelView }.allSatisfy { $0.isHiddenOrHasHiddenAncestor })
        let title = try #require(view.allDescendants.first { $0.identifier?.rawValue == "recording-title" } as? NSTextField)
        view.beginRenaming()
        #expect(title.currentEditor() != nil)
        app.updateCaptureSource(.direct, tracks: [Self.track("replacement", name: "Renamed", local: true)])
        #expect(title.currentEditor() != nil, "A track update must not interrupt editing")
        #expect(rows().map(\.stringValue) == ["You — Renamed"])
        app.panel.makeFirstResponder(nil)
        app.updateCaptureSource(.preparing, tracks: tracks, recovering: true)
        #expect(source.stringValue.contains("KTalk audio unavailable"))
        #expect(scroll.isHidden)
        #expect(!rows().contains { $0.stringValue.contains("Alex") })
        for state in [RecordingSession.CaptureSource.fallback, .failed, .ended, .ordinary] {
            app.updateCaptureSource(state, tracks: tracks)
            #expect(source.stringValue == state.title)
            #expect(scroll.isHidden)
            let meters = view.allDescendants.compactMap { $0 as? AudioLevelView }
            #expect(meters.allSatisfy { $0.isHiddenOrHasHiddenAncestor == (state != .fallback && state != .ordinary) })
        }
    }
}

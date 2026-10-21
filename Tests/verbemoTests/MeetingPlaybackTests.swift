import AppKit
import AVFoundation
import Testing
@testable import verbemo

@Suite(.serialized) @MainActor
struct MeetingPlaybackTests {
    @Test(.freshHome) func bothSourcesPlayOnTheirRecordedTimeline() async throws {
        let dir = Home.current.url.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("meta.json"))
        try TestAudio.write(to: dir.appendingPathComponent("mic.caf"), seconds: 1, sampleRate: 16_000) { _, _ in 0.2 }
        try TestAudio.write(to: dir.appendingPathComponent("system.caf"), seconds: 1, sampleRate: 16_000) { _, _ in 0.4 }
        try SessionState.amend(dir, with: ["files": ["mic": "mic.caf", "system": "system.caf"], "start_offset_ms": ["mic": 0, "system": 500]])
        let item = try await MeetingPlaybackView.makeItem(MeetingPlaybackView.sources(in: dir))
        #expect(abs(try await item.asset.load(.duration).seconds - 1.5) < 0.01)
        let reader = try AVAssetReader(asset: item.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: try await item.asset.loadTracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = item.audioMix
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
            let result = values.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            #expect(result == kCMBlockBufferNoErr)
            samples += values
        }
        #expect(reader.status == .completed)
        #expect(samples.count >= 24_000)
        guard samples.count >= 24_000 else { return }
        #expect(abs(samples[4_000] - 0.1) < 0.01)
        #expect(abs(samples[12_000] - 0.3) < 0.01)
        #expect(abs(samples[20_000] - 0.2) < 0.01)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["mic.caf", "system.caf", "meta.json"])
    }

    @Test(.freshHome, .speaking(.russian)) func transcriptTimestampPlaysTheSharedTimelineAndDisablesWithoutAudio() async throws {
        let dir = try TestAudio.rawSession(seconds: 4)
        defer { try? FileManager.default.removeItem(at: dir) }
        let player = MeetingPlaybackView()
        player.player.isMuted = true
        player.setMeeting(dir)
        await player.settled()
        let transcript = Transcript(engine: "nemotron", model: "test", created_at: "", segments: [
            .init(speaker: "me", start_ms: 1500, end_ms: 2500, text: "Проверка времени."),
        ])
        let view = MeetingTranscriptView()
        view.onPlayFrom = { player.play(from: $0) }
        view.update(transcript: transcript, names: nil, participants: [], canEdit: false, canPlay: true)
        let table = try #require(view.documentView as? NSTableView)
        let row = try #require(view.tableView(table, viewFor: table.tableColumns[0], row: 0))
        let button = try #require(row.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "transcript.playFrom" })
        #expect(button.isEnabled)
        #expect(button.accessibilityLabel() == "Воспроизвести с 00:01")
        #expect(NSApplication.shared.sendAction(try #require(button.action), to: button.target, from: button))
        for _ in 0..<100 {
            if player.player.currentTime().seconds >= 1.49 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(player.player.currentTime().seconds >= 1.49)
        #expect(player.player.currentTime().seconds < 2.5)
        #expect(player.player.rate > 0)
        player.setMeeting(nil)
        view.update(transcript: transcript, names: nil, participants: [], canEdit: false)
        let disabledRow = try #require(view.tableView(table, viewFor: table.tableColumns[0], row: 0))
        let disabled = try #require(disabledRow.allDescendants.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "transcript.playFrom" })
        #expect(!disabled.isEnabled)
        player.play(from: .nan)
        player.play(from: 1.5)
        #expect(player.player.rate == 0)
        #expect(player.player.currentItem == nil)
    }

    @Test(.freshHome) func archivedStereoIsNotPlayedTwiceAndSelectionClearsOldAudio() async throws {
        let dir = Home.current.url.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("meta.json"))
        try TestAudio.write(to: dir.appendingPathComponent("audio.caf"), seconds: 0.25, channels: 2) { _, _ in 0 }
        try SessionState.amend(dir, with: ["files": ["mic": "audio.caf", "system": "audio.caf"], "audio_channels": ["mic": 0, "system": 1]])
        #expect(MeetingPlaybackView.sources(in: dir).count == 1)
        let view = MeetingPlaybackView()
        view.setMeeting(dir)
        await view.settled()
        let item = try #require(view.player.currentItem)
        #expect(try await item.asset.loadTracks(withMediaType: .audio).count == 1)
        view.setMeeting(nil)
        #expect(view.player.currentItem == nil)
        #expect(view.player.rate == 0)
        #expect(view.isHidden)
        view.setMeeting(dir)
        view.setMeeting(nil)
        await view.settled()
        #expect(view.player.currentItem == nil, "Cancelled loading must not restore a previous meeting")
    }

    @Test(.freshHome, .speaking(.russian)) func corruptAudioIsReportedInsteadOfPlayingOnlyTheGoodTrack() async throws {
        let dir = Home.current.url.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("meta.json"))
        try TestAudio.write(to: dir.appendingPathComponent("mic.caf"), seconds: 0.1) { _, _ in 0 }
        try Data("broken".utf8).write(to: dir.appendingPathComponent("system.caf"))
        try SessionState.amend(dir, with: ["files": ["mic": "mic.caf", "system": "system.caf"]])
        let view = MeetingPlaybackView()
        view.setMeeting(dir)
        await view.settled()
        #expect(view.player.currentItem == nil)
        let message = try #require(view.allDescendants.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "playback.message" })
        #expect(!message.isHiddenOrHasHiddenAncestor)
        #expect(message.stringValue == "Не удалось воспроизвести аудио встречи.")
    }
}

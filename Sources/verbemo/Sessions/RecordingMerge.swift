import AVFoundation
import Foundation

/// Builds an ordinary session in hidden staging; source claims live through publication or cleanup.
enum RecordingMerge {
    struct Source: Sendable {
        let key: String
        let url: URL
        let offsetMs: Int
        let durationMs: Int
        let participant: CallAudioMetadata.Track?
    }
    struct Part: Sendable {
        let dir: URL
        let title: String
        let started: Date
        let durationMs: Int
        let metadata: Data
        let sources: [Source]
    }
    struct Plan: Sendable {
        let parts: [Part]
        var durationMs: Int { parts.reduce(0) { $0 + $1.durationMs } }
    }
    struct Unavailable: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func inspect(_ directories: [URL]) throws -> Plan {
        let dirs = directories.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard dirs.count >= 2, Set(dirs.map(\.path)).count == dirs.count else {
            throw Unavailable(message: localised("Select at least two different recordings.", "Выберите хотя бы две разные записи."))
        }
        let parts = try dirs.map { dir -> Part in
            try Task.checkCancellation()
            guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".recording.json").path) else {
                throw Unavailable(message: localised("Stop recording before merging: ", "Перед объединением остановите запись: ") + dir.lastPathComponent)
            }
            let data = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
            guard let meta = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = meta["files"] as? [String: String], !files.isEmpty,
                  let stamp = meta["started"] as? String, let started = date(stamp),
                  meta["audio_discarded"] as? Bool != true else {
                throw Unavailable(message: localised("Recording metadata or audio is unavailable: ", "Нет доступных сведений или аудио: ") + dir.lastPathComponent)
            }
            let parsed = try SessionMeta.read(from: dir)
            let known = parsed.callAudio?.tracks ?? []
            guard Set(files.keys).isSubset(of: Set(known.map(\.fileKey)).union(["mic", "system", "source"])) else {
                throw Unavailable(message: localised("Unsupported audio tracks: ", "Неподдерживаемые дорожки: ") + dir.lastPathComponent)
            }
            guard (meta["start_offset_ms"] == nil || meta["start_offset_ms"] is [String: Int]),
                  (meta["audio_channels"] == nil || meta["audio_channels"] is [String: Int]) else { throw CocoaError(.fileReadCorruptFile) }
            let offsets = meta["start_offset_ms"] as? [String: Int] ?? [:]
            let channels = meta["audio_channels"] as? [String: Int] ?? [:]
            var sources: [Source] = []
            for (key, file) in files.sorted(by: { $0.key < $1.key }) {
                guard file == URL(fileURLWithPath: file).lastPathComponent, !file.contains("\\"),
                      ["caf", "m4a"].contains((file as NSString).pathExtension.lowercased()),
                      (offsets[key] ?? 0) >= 0 else { throw CocoaError(.fileReadCorruptFile) }
                let url = dir.appendingPathComponent(file)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
                let audio = try AVAudioFile(forReading: url)
                let rate = audio.processingFormat.sampleRate
                guard rate.isFinite, (8000...192000).contains(rate) else { throw CocoaError(.fileReadCorruptFile) }
                let channelKeys = files.keys.filter { files[$0] == file }
                if channels[key] != nil {
                    // A shared archive must describe every channel, all on the same clock.
                    guard Set(channelKeys.compactMap { channels[$0] }) == Set(0..<Int(audio.processingFormat.channelCount)),
                          Set(channelKeys.map { offsets[$0] ?? 0 }).count == 1 else {
                        throw Unavailable(message: localised("Unsupported channel layout: ", "Неподдерживаемое расположение каналов: ") + file)
                    }
                }
                let participant = known.first { $0.fileKey == key }
                guard participant == nil || channels[key] == nil else { throw CocoaError(.fileReadCorruptFile) }
                if let previous = sources.first(where: { $0.url == url }) {
                    guard previous.offsetMs == (offsets[key] ?? 0) else { throw CocoaError(.fileReadCorruptFile) }
                    continue
                }
                let milliseconds = (Double(audio.length) / rate * 1000).rounded(.up)
                guard milliseconds.isFinite, milliseconds < Double(Int.max / 4) else { throw CocoaError(.fileReadCorruptFile) }
                sources.append(Source(key: key, url: url, offsetMs: offsets[key] ?? 0,
                    durationMs: Int(milliseconds), participant: participant))
            }
            guard sources.contains(where: { $0.durationMs > 0 }) else {
                throw Unavailable(message: localised("No audio frames in: ", "Нет аудиоданных: ") + dir.lastPathComponent)
            }
            let declared = (meta["duration_seconds"] as? NSNumber)?.doubleValue ?? 0
            guard declared.isFinite, declared >= 0, declared < Double(Int.max / 4000),
                  sources.allSatisfy({ $0.offsetMs < Int.max / 4 }) else { throw CocoaError(.fileReadCorruptFile) }
            let duration = max(Int((declared * 1000).rounded(.up)), sources.map { $0.offsetMs + $0.durationMs }.max() ?? 0)
            return Part(dir: dir, title: meta["title"] as? String ?? dir.lastPathComponent,
                started: started, durationMs: duration, metadata: data, sources: sources)
        }.sorted { ($0.started, $0.dir.path) < ($1.started, $1.dir.path) }
        guard parts.reduce(0.0, { $0 + Double($1.durationMs) }) < Double(Int.max / 1000) else { throw CocoaError(.fileReadCorruptFile) }
        return Plan(parts: parts)
    }

    static func create(_ directories: [URL], in root: URL, operations: ProcessingOperations = .shared,
                       expected: Plan? = nil, write: (AVAudioFile, AVAudioPCMBuffer) throws -> Void = { try $0.write(from: $1) }) throws -> URL {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let dirs = directories.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard dirs.allSatisfy({ $0.deletingLastPathComponent().path == root.path }) else { throw CocoaError(.fileReadNoPermission) }
        var claimed: [URL] = []
        defer { for dir in claimed { SessionClaim.release(dir) } }
        for dir in dirs.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            guard !operations.snapshot().contains(where: { $0.session?.path == dir.path }) else {
                throw Unavailable(message: localised("Recording is busy: ", "Запись занята: ") + dir.lastPathComponent)
            }
            try SessionClaim.acquire(dir, stage: .finish)
            claimed.append(dir)
        }
        let plan = try inspect(dirs)
        if let expected, expected.parts.map(\.metadata) != plan.parts.map(\.metadata) {
            throw Unavailable(message: localised("The recordings changed. Review the selection and try again.", "Записи изменились. Проверьте выбор и повторите объединение."))
        }
        try Task.checkCancellation()
        removeAbandonedStaging(in: root)
        let id = UUID().uuidString
        let staging = root.appendingPathComponent(".merge-\(ProcessInfo.processInfo.processIdentifier)-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var files: [String: String] = [:], offsets: [String: Int] = [:]
        var tracks: [CallAudioMetadata.Track] = []
        var periods: [CallAudioMetadata.Period] = []
        var provenance: [[String: Any]] = []
        var calendars: [[String: Any]?] = []
        let hasOrdinary = plan.parts.contains { $0.sources.contains { $0.participant == nil && $0.durationMs > 0 } }
        var cursor = 0
        for (index, part) in plan.parts.enumerated() {
            try Task.checkCancellation()
            guard let original = try JSONSerialization.jsonObject(with: part.metadata) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            calendars.append(original["calendar"] as? [String: Any])
            var origin: [String: Any] = ["session": part.dir.lastPathComponent, "started": original["started"] ?? "",
                "offset_ms": cursor, "duration_ms": part.durationMs, "files": original["files"] ?? [:],
                "start_offset_ms": original["start_offset_ms"] ?? [:], "audio_channels": original["audio_channels"] ?? [:]]
            origin["call_audio"] = original["call_audio"]
            provenance.append(origin)
            if let info = try SessionMeta.read(from: part.dir).callAudio {
                periods += info.periods.map {
                    .init(mode: $0.mode, startMs: cursor + $0.startMs,
                        endMs: cursor + ($0.endMs ?? part.durationMs), reason: $0.reason)
                }
            } else { periods.append(.init(mode: .fallback, startMs: cursor, endMs: cursor + part.durationMs)) }
            for source in part.sources {
                guard var track = source.participant else { continue }
                let key = "call_part\(index + 1)_\(track.fileKey)"
                let tail = part.sources.filter { $0.durationMs > 0 }.max { $0.offsetMs + $0.durationMs < $1.offsetMs + $1.durationMs }
                let padding = !hasOrdinary && index == plan.parts.count - 1 && tail?.key == source.key
                    && part.durationMs > source.offsetMs + source.durationMs
                let file = key + "." + (padding ? "caf" : source.url.pathExtension.lowercased())
                if padding {
                    try pad(source, to: staging.appendingPathComponent(file), durationMs: part.durationMs - source.offsetMs, write: write)
                } else { try copy(source.url, to: staging.appendingPathComponent(file)) }
                try validate(staging.appendingPathComponent(file), emptyAllowed: source.durationMs == 0)
                files[key] = file
                offsets[key] = cursor + source.offsetMs
                track.fileKey = key
                track.speakerID = "call_part\(index + 1)_\(track.speakerID)"
                while track.name.utf8.count > 4000 { track.name.removeLast() }
                track.name += localised(" · Part \(index + 1)", " · Часть \(index + 1)")
                tracks.append(track)
            }
            cursor += part.durationMs
        }
        if hasOrdinary {
            let output = staging.appendingPathComponent("source.m4a")
            try renderOrdinary(plan, to: output, write: write)
            try validate(output, minimumMs: plan.durationMs)
            files["source"] = "source.m4a"; offsets["source"] = 0
        }
        guard let first = plan.parts.first else { throw CocoaError(.fileReadCorruptFile) }
        var meta: [String: Any] = ["title": localised("Merged · ", "Объединено · ") + first.title,
            "started": ISO8601DateFormatter().string(from: first.started),
            "ended": ISO8601DateFormatter().string(from: first.started.addingTimeInterval(Double(cursor) / 1000)),
            "duration_seconds": cursor / 1000, "trigger": "merge", "stop_reason": "merge",
            "files": files, "start_offset_ms": offsets, "merge": provenance]
        if !tracks.isEmpty {
            meta["call_audio"] = try CallAudioMetadata(integrationID: "merge", callID: id, periods: periods, tracks: tracks).jsonValue()
        }
        if let calendar = calendars.first ?? nil, !calendar.isEmpty,
           calendars.allSatisfy({ $0.map { NSDictionary(dictionary: $0).isEqual(to: calendar) } == true }) {
            meta["calendar"] = calendar
        }
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("meta.json"), options: .atomic)
        _ = try SessionMeta.read(from: staging)
        try Task.checkCancellation()
        let stamp = ISO8601DateFormatter().string(from: first.started).replacingOccurrences(of: ":", with: "-")
        let destination = root.appendingPathComponent("\(stamp) Merged-\(id.prefix(8))", isDirectory: true)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    private static func renderOrdinary(_ plan: Plan, to url: URL,
                                       write: (AVAudioFile, AVAudioPCMBuffer) throws -> Void) throws {
        let rate = 48_000.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384),
              let samples = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        for part in plan.parts {
            let readers = try part.sources.filter { $0.participant == nil && $0.durationMs > 0 }.map {
                try AudioTrackReader(url: $0.url, rate: rate, offset: Double($0.offsetMs) / 1000)
            }
            let length = AVAudioFramePosition(part.durationMs) * 48
            var position: AVAudioFramePosition = 0
            while position < length {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(16_384, length - position))
                buffer.frameLength = count
                samples.update(repeating: 0, count: Int(count))
                for reader in readers where !reader.spent {
                    _ = try reader.read(into: samples, frames: count, at: position, adding: true)
                }
                for i in 0..<Int(count) { samples[i] = min(1, max(-1, samples[i])) }
                try write(file, buffer)
                position += AVAudioFramePosition(count)
            }
        }
    }

    /// AVComposition drops trailing empty edits, so the final pause needs actual silent frames.
    private static func pad(_ source: Source, to url: URL, durationMs: Int,
                            write: (AVAudioFile, AVAudioPCMBuffer) throws -> Void) throws {
        let reader = try AudioTrackReader(url: source.url)
        let rate = reader.sourceRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384),
              let samples = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        let file = try AVAudioFile(forWriting: url, settings: AudioFormats.pcmSettings(sampleRate: rate, channels: 1),
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let length = AVAudioFramePosition((Double(durationMs) * rate / 1000).rounded(.up))
        var position: AVAudioFramePosition = 0
        while position < length {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(16_384, length - position))
            buffer.frameLength = count
            samples.update(repeating: 0, count: Int(count))
            _ = try reader.read(into: samples, frames: count, at: position)
            try write(file, buffer)
            position += AVAudioFramePosition(count)
        }
    }

    private static func copy(_ source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { break }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
    }

    private static func validate(_ url: URL, minimumMs: Int = 0, emptyAllowed: Bool = false) throws {
        if emptyAllowed, try AVAudioFile(forReading: url).length == 0 { return }
        let reader = try AudioTrackReader(url: url)
        var frames: Int64 = 0
        while let buffer = try reader.next(16_384) {
            try Task.checkCancellation()
            frames += Int64(buffer.frameLength)
        }
        guard Double(frames) / reader.sourceRate * 1000 + 1 >= Double(minimumMs) else { throw CocoaError(.fileReadCorruptFile) }
    }

    private static func date(_ stamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: stamp) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: stamp)
    }

    private static func removeAbandonedStaging(in root: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(".merge-") {
            let pieces = entry.lastPathComponent.split(separator: "-")
            guard pieces.count >= 3, let pid = Int32(pieces[1]), pid > 0, !RecordingSession.processIsAlive(pid) else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

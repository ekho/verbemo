import AppKit
import AVFoundation

@MainActor
final class MeetingPlaybackView: JournalSurface {
    struct Source: Equatable {
        let url: URL
        let offsetMs: Int
    }
    private(set) var player = AVPlayer()
    private let play = NSButton()
    private let timeline = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let time = NSTextField(labelWithString: "00:00 / 00:00")
    private let volume = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let speed = NSPopUpButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]
    private var sources: [Source] = []
    private var duration: Double = 0
    private var loading: Task<Void, Never>?
    private var ticking: Task<Void, Never>?

    init() {
        super.init(JournalStyle.inset)
        identifier = .init("meeting.playback")
        layer?.cornerRadius = 9
        play.isBordered = false
        play.contentTintColor = JournalStyle.accent
        play.target = self
        play.action = #selector(togglePlayback)
        play.identifier = .init("playback.play")
        play.widthAnchor.constraint(equalToConstant: 30).isActive = true
        play.heightAnchor.constraint(equalToConstant: 30).isActive = true
        timeline.target = self
        timeline.action = #selector(seek)
        timeline.isContinuous = true
        timeline.identifier = .init("playback.timeline")
        timeline.setAccessibilityLabel(localised("Meeting position", "Позиция во встрече"))
        timeline.setContentHuggingPriority(.init(1), for: .horizontal)
        timeline.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = JournalStyle.muted
        volume.controlSize = .small
        volume.target = self
        volume.action = #selector(changeVolume)
        volume.setAccessibilityLabel(localised("Playback volume", "Громкость воспроизведения"))
        volume.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let speaker = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)!)
        speaker.contentTintColor = JournalStyle.muted
        speed.addItems(withTitles: ["0.75×", "1×", "1.25×", "1.5×", "2×"])
        speed.selectItem(at: 1)
        speed.isBordered = false
        speed.font = .systemFont(ofSize: 11)
        speed.target = self
        speed.action = #selector(changeSpeed)
        speed.setAccessibilityLabel(localised("Playback speed", "Скорость воспроизведения"))
        let row = NSStackView(views: [play, timeline, time, speaker, volume, speed])
        row.spacing = 8
        message.font = .systemFont(ofSize: 11)
        message.textColor = JournalStyle.muted
        message.identifier = .init("playback.message")
        let stack = NSStackView(views: [row, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        message.isHidden = true
        refreshControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { loading?.cancel(); ticking?.cancel() }

    static func sources(in dir: URL) -> [Source] {
        let meta = SessionState.read(dir) ?? [:]
        let files = meta["files"] as? [String: String] ?? [:]
        let offsets = meta["start_offset_ms"] as? [String: Int] ?? [:]
        let available = Set(MeetingPresentation.audioFiles(dir))
        var seen: Set<URL> = []
        return files.sorted { $0.key < $1.key }.compactMap { key, name in
            let url = dir.appendingPathComponent(name).standardizedFileURL
            guard available.contains(url), seen.insert(url).inserted else { return nil }
            return Source(url: url, offsetMs: max(0, offsets[key] ?? 0))
        }
    }

    /// A shared timeline streams the originals without exporting or rewriting audio.
    static func makeItem(_ sources: [Source]) async throws -> AVPlayerItem {
        let composition = AVMutableComposition()
        var tracks: [AVMutableCompositionTrack] = []
        for source in sources {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: source.url)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            for track in audio {
                let range = try await track.load(.timeRange)
                guard range.duration.isNumeric, range.duration.seconds > 0 else { continue }
                guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try destination.insertTimeRange(range, of: track, at: CMTime(value: Int64(source.offsetMs), timescale: 1000))
                tracks.append(destination)
            }
        }
        guard !tracks.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(1 / Float(tracks.count), at: .zero)
            return parameters
        }
        let item = AVPlayerItem(asset: composition)
        item.audioMix = mix
        return item
    }

    func setMeeting(_ dir: URL?) {
        let next = dir.map(Self.sources) ?? []
        isHidden = next.isEmpty
        guard sources != next else { return }
        sources = next
        loading?.cancel()
        ticking?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        duration = 0
        timeline.doubleValue = 0
        message.isHidden = next.isEmpty
        message.stringValue = localised("Loading audio…", "Загрузка аудио…")
        refreshControls()
        guard !next.isEmpty else { return }
        loading = Task { [weak self] in
            do {
                let item = try await Self.makeItem(next)
                let duration = try await item.asset.load(.duration)
                try Task.checkCancellation()
                guard let self else { return }
                self.player.replaceCurrentItem(with: item)
                self.duration = duration.seconds
                self.timeline.maxValue = duration.seconds
                self.message.isHidden = true
                self.refreshControls()
                self.ticking = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.refreshControls()
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    }
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.message.stringValue = localised("Could not play the meeting audio.", "Не удалось воспроизвести аудио встречи.")
                self.message.toolTip = error.localizedDescription
                self.message.isHidden = false
            }
        }
    }
    func settled() async { await loading?.value }

    func play(from seconds: TimeInterval) {
        guard seconds.isFinite, duration > 0, let item = player.currentItem, item.status != .failed else { return }
        player.seek(to: CMTime(seconds: min(duration, max(0, seconds)), preferredTimescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.playImmediately(atRate: rates[speed.indexOfSelectedItem])
        refreshControls()
    }

    private func refreshControls() {
        let failed = player.currentItem?.status == .failed
        if failed {
            player.pause()
            message.stringValue = localised("Could not play the meeting audio.", "Не удалось воспроизвести аудио встречи.")
            message.isHidden = false
        }
        play.isEnabled = player.currentItem != nil && !failed
        timeline.isEnabled = play.isEnabled
        let playing = player.rate != 0
        play.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        play.setAccessibilityLabel(playing ? localised("Pause playback", "Приостановить воспроизведение") : localised("Play meeting", "Воспроизвести встречу"))
        let position = player.currentTime().seconds
        let seconds = position.isFinite ? max(0, position) : 0
        if timeline.cell?.isHighlighted != true { timeline.doubleValue = seconds }
        time.stringValue = Self.timestamp(seconds) + " / " + Self.timestamp(duration)
        timeline.setAccessibilityValueDescription(Self.timestamp(seconds))
    }
    private static func timestamp(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(max(0, seconds)) : 0
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
    @objc private func togglePlayback() {
        if player.rate != 0 { player.pause() }
        else {
            if player.currentTime().seconds >= duration - 0.05 { player.seek(to: .zero) }
            player.playImmediately(atRate: rates[speed.indexOfSelectedItem])
        }
        refreshControls()
    }
    @objc private func seek() { player.seek(to: CMTime(seconds: timeline.doubleValue, preferredTimescale: 1000)) }
    @objc private func changeVolume() { player.volume = volume.floatValue }
    @objc private func changeSpeed() { if player.rate != 0 { player.rate = rates[speed.indexOfSelectedItem] } }
}

import Foundation

/// Presentation reads the session's recorded states, never a simulated percentage.
enum MeetingPresentation {
    enum StageState { case done, active, pending, off, failed }
    struct Stage {
        var symbol: String
        var title: String
        var state: StageState
        var diarized = false
    }
    static func date(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter.string(from: date)
    }
    static func matches(_ item: SessionInventory.Item, filter: ApplicationNavigationState.Destination, query: String) -> Bool {
        let steps = [item.transcript, item.speakers, item.summary]
        let busy = SessionClaim.isHeld(item.dir)
        if filter == .processing && !busy && !steps.contains(where: \.isOutstanding) { return false }
        if filter == .attention && !item.unreadableDiarization && item.diarization?.status != .failed
            && !steps.contains(where: { if case .failed = $0 { return true }; return false }) { return false }
        return query.isEmpty || ([item.title ?? item.name, item.name, date(item.started)] + (MeetingCalendarMetadata.read(from: item.dir)?.participants.map(\.name) ?? []))
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
    static func audioFiles(_ dir: URL) -> [URL] {
        let files = SessionState.read(dir)?["files"] as? [String: String] ?? [:]
        return files.sorted { $0.key < $1.key }.compactMap { _, path in
            let file = dir.appendingPathComponent(path).standardizedFileURL
            guard file.deletingLastPathComponent() == dir.standardizedFileURL,
                  FileManager.default.fileExists(atPath: file.path) else { return nil }
            return file
        }
    }
    static func calendarLinked(_ dir: URL) -> Bool {
        MeetingCalendarMetadata.read(from: dir)?.isConfirmed == true
    }
    static func stages(_ item: SessionInventory.Item) -> [Stage] {
        let busy = SessionClaim.isHeld(item.dir)
        let ready = item.transcript == .done && !TranscriptVersions.isRequested(item.dir)
        func stage(_ step: SessionInventory.Step, symbol: String, label: String, done: String, active: Bool) -> Stage {
            if active { return Stage(symbol: symbol, title: label, state: .active) }
            switch step {
            case .done: return Stage(symbol: symbol, title: done, state: .done)
            case .off: return Stage(symbol: symbol, title: localised("Summary was not created", "Сводка не создавалась"), state: .off)
            case .failed(let reason): return Stage(symbol: symbol, title: reason, state: .failed)
            case .pending, .deferred: return Stage(symbol: symbol, title: label, state: .pending)
            }
        }
        var result: [Stage] = []
        if calendarLinked(item.dir) { result.append(Stage(symbol: "calendar", title: localised("Linked calendar event", "Связано с событием календаря"), state: .done)) }
        result.append(Stage(symbol: "mic", title: localised("Recording saved", "Запись сохранена"), state: .done))
        var transcript = stage(item.transcript, symbol: "doc.text", label: localised("Transcription", "Расшифровка"),
            done: localised("Transcript ready", "Расшифровка готова"), active: busy && !ready)
        transcript.diarized = item.diarization.map { $0.status != .skipped } ?? ((item.namedSpeakers?.total ?? 0) > 2)
        if transcript.diarized { transcript.title += localised(" · speaker separation enabled", " · диаризация включена") }
        result.append(transcript)
        result.append(stage(item.summary, symbol: "checklist", label: localised("Preparing summary", "Подготовка сводки"),
            done: localised("Summary ready", "Сводка готова"), active: busy && ready && item.summary != .off))
        return result
    }
}

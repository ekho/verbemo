import Foundation

/// Presentation reads the session's recorded states, never a simulated percentage.
enum MeetingPresentation {
    enum StageState { case done, active, paused, pending, waiting, off, failed }
    struct Attention: Equatable {
        let dir: URL
        let title: String
        let problems: [String]
    }

    struct ActiveRecording: Equatable {
        let dir: URL
        var title: String
        let started: Date
        var paused: Bool
        var liveStatus: LiveTranscriptionCoordinator.Status
        var captureSource: RecordingSession.CaptureSource = .ordinary
        var item: SessionInventory.Item {
            .init(dir: dir, name: dir.lastPathComponent, title: title, started: started, duration: nil,
                trigger: nil, engine: nil, transcript: .pending, diarization: nil, unreadableDiarization: false,
                speakers: .off, summary: Config.summary().enabled ? .pending : .off, namedSpeakers: nil, sizeBytes: 0, hasAudio: true)
        }
        var attentionProblem: String? {
            switch liveStatus {
            case .modelMissing: localised("Live transcription needs the Nemotron model", "Для онлайн-расшифровки нужна модель Nemotron")
            case .overloaded: localised("Live transcription stopped because the Mac couldn't keep up",
                                        "Онлайн-расшифровка остановлена: мак не успевает")
            case .error(let reason): localised("Live transcription failed", "Сбой онлайн-расшифровки") + ": " + reason
            default: nil
            }
        }
    }
    struct Stage {
        var symbol: String
        var title: String
        var state: StageState
        var diarized = false
        var activitySymbol: String? = nil
    }
    static func date(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter.string(from: date)
    }
    static func matches(_ item: SessionInventory.Item, filter: ApplicationNavigationState.Destination, query: String, active: ActiveRecording? = nil) -> Bool {
        let steps = [item.transcript, item.speakers, item.summary]
        let busy = SessionClaim.isHeld(item.dir)
        if filter == .processing && !busy && !steps.contains(where: \.isOutstanding) { return false }
        if filter == .attention && attention(for: item, active: active) == nil { return false }
        return query.isEmpty || ([item.title ?? item.name, item.name, date(item.started)] + (MeetingCalendarMetadata.read(from: item.dir)?.participants.map(\.name) ?? []))
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func attention(for item: SessionInventory.Item, active: ActiveRecording? = nil) -> Attention? {
        var problems: [String] = []
        func add(_ label: String, reason: String?) {
            let detail = reason?.split(whereSeparator: \.isNewline).joined(separator: " ") ?? ""
            problems.append(detail.isEmpty ? label : label + ": " + detail)
        }
        if let active, active.dir == item.dir, let problem = active.attentionProblem { add(problem, reason: nil) }
        if let failure = SessionState.read(item.dir)?["capture_failure"] as? String {
            add(localised("Recording incomplete", "Запись неполная"), reason: failure)
        }
        if case .failed(let reason) = item.transcript {
            add(localised("Transcription failed", "Сбой расшифровки"), reason: reason)
        }
        if item.unreadableDiarization {
            add(localised("Speaker separation state could not be read", "Не удалось прочитать состояние диаризации"), reason: nil)
        } else if let diarization = item.diarization, diarization.hasFailedAttempt {
            add(localised("Speaker separation failed", "Сбой диаризации"), reason: diarization.reason)
        }
        if case .failed(let reason) = item.speakers {
            add(localised("Naming speakers failed", "Не удалось определить имена говорящих"), reason: reason)
        }
        if case .failed(let reason) = item.summary {
            add(localised("Summary creation failed", "Сбой создания сводки"), reason: reason)
        }
        guard !problems.isEmpty else { return nil }
        return Attention(dir: item.dir, title: item.title ?? item.name, problems: problems)
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
    static func stages(_ item: SessionInventory.Item, active: ActiveRecording? = nil, version: TranscriptVersions.Version? = nil) -> [Stage] {
        if let active, active.dir == item.dir {
            var stages: [Stage] = []
            if calendarLinked(item.dir) { stages.append(Stage(symbol: "calendar", title: localised("Linked calendar event", "Связано с событием календаря"), state: .done)) }
            stages.append(Stage(symbol: "mic", title: active.paused ? localised("Recording paused", "Запись приостановлена") : active.captureSource.title, state: active.paused ? .paused : [.preparing, .ended].contains(active.captureSource) ? .waiting : .active))
            stages.append(Stage(symbol: "doc.text", title: localised("Transcription waits for the recording to finish", "Расшифровка ожидает окончания записи"), state: .waiting))
            stages.append(item.summary == .off
                ? Stage(symbol: "checklist", title: localised("Summary was not created", "Сводка не создавалась"), state: .off)
                : Stage(symbol: "checklist", title: localised("Summary waits for transcription", "Сводка ожидает расшифровки"), state: .waiting))
            return stages
        }
        let session = item.dir
        let item = version.flatMap { $0.dir != session ? SessionInventory.item(for: $0.dir) : nil } ?? item
        let requested = TranscriptVersions.isRequested(session)
        let transcriptStep = version?.state ?? item.transcript
        let busy = SessionClaim.isHeld(session)
        let ready = transcriptStep == .done && (version?.isRequest == false || !requested)
        let operations = ProcessingOperations.shared.snapshot().filter {
            $0.session == session.standardizedFileURL.resolvingSymlinksInPath()
        }
        let operation = operations.first { $0.state != .waiting } ?? operations.first
        let versionOperation = operation.flatMap { operation -> ProcessingOperations.Snapshot? in
            guard let version else { return operation }
            if operation.kind == .transcription {
                return version.isRequest || (version.isCurrent && !requested) ? operation : nil
            }
            guard !version.isRequest,
                  (operation.artifactDirectory ?? session.standardizedFileURL.resolvingSymlinksInPath()) == version.dir.standardizedFileURL.resolvingSymlinksInPath() else { return nil }
            return operation
        }
        func stage(_ step: SessionInventory.Step, symbol: String, label: String, done: String, active: Bool) -> Stage {
            if active { return Stage(symbol: symbol, title: label, state: .active) }
            switch step {
            case .done: return Stage(symbol: symbol, title: done, state: .done)
            case .off: return Stage(symbol: symbol, title: symbol == "checklist"
                ? localised("Summary was not created", "Сводка не создавалась")
                : localised("Transcript not created", "Расшифровка не создавалась"), state: .off)
            case .failed(let reason): return Stage(symbol: symbol, title: reason, state: .failed)
            case .pending, .deferred: return Stage(symbol: symbol, title: label, state: .pending)
            }
        }
        var result: [Stage] = []
        if calendarLinked(item.dir) { result.append(Stage(symbol: "calendar", title: localised("Linked calendar event", "Связано с событием календаря"), state: .done)) }
        let incomplete = SessionState.read(item.dir)?["capture_failure"] != nil
        result.append(Stage(symbol: "mic", title: incomplete ? localised("Recording incomplete", "Запись неполная")
            : localised("Recording saved", "Запись сохранена"), state: incomplete ? .failed : .done))
        var transcript = stage(transcriptStep, symbol: "doc.text", label: localised("Transcript not created", "Расшифровка не создавалась"),
            done: localised("Transcript ready", "Расшифровка готова"), active: false)
        if let operation = versionOperation, [.transcription, .diarization, .postProcessing].contains(operation.kind) {
            let action: String
            switch operation.kind {
            case .diarization:
                action = localised("Diarization", "Диаризация")
                transcript.activitySymbol = "person.wave.2"
            case .postProcessing:
                action = item.speakers.isOutstanding ? localised("Speaker naming", "Определение имён")
                    : localised("Finishing processing", "Завершение обработки")
                transcript.activitySymbol = "person.text.rectangle"
            default: action = localised("Transcription", "Расшифровка")
            }
            transcript.state = operation.state == .running ? .active : .waiting
            transcript.title = operation.state == .cancelling
                ? localised("Cancelling: ", "Отмена: ") + action
                : operation.state == .waiting ? localised("Queued: ", "В очереди: ") + action : action
        } else if busy && !ready {
            transcript.state = .waiting
            transcript.title = localised("Transcription waits for other processing to finish", "Расшифровка ожидает завершения другой обработки")
        } else if transcriptStep == .deferred {
            transcript.title = localised("Transcription deferred — retry processing", "Расшифровка отложена — повторите обработку")
        } else if requested && version?.isRequest != false && transcriptStep == .pending {
            transcript.title = localised("Transcription queued", "Расшифровка в очереди")
        }
        if transcript.state != .active, versionOperation == nil {
            if item.unreadableDiarization {
                transcript.state = .failed
                transcript.title = localised("Transcript blocked: diarization state cannot be read", "Расшифровка заблокирована: не читается состояние диаризации")
            } else if ready, let state = item.diarization, !state.isFinal {
                transcript.state = state.hasFailedAttempt || state.status == .partial ? .failed : .waiting
                transcript.activitySymbol = "person.wave.2"
                transcript.title = transcript.state == .failed
                    ? localised("Transcript needs a diarization decision", "Расшифровка требует решения по диаризации")
                    : localised("Transcript waits for diarization", "Расшифровка ожидает диаризацию")
            }
        }
        transcript.diarized = ready && (item.diarization.map { $0.status == .completed } ?? item.isDiarized)
        result.append(transcript)
        let summaryStep: SessionInventory.Step = version?.isRequest == true ? .pending : item.summary
        var summary = stage(summaryStep, symbol: "checklist", label: localised("Preparing summary", "Подготовка сводки"),
            done: localised("Summary ready", "Сводка готова"), active: versionOperation?.kind == .summary && versionOperation?.state == .running)
        if summary.state == .failed { summary.title = localised("Summary creation failed", "Сбой создания сводки") }
        if let operation = versionOperation, operation.kind == .summary, operation.state != .running {
            summary.state = operation.state == .cancelling ? .waiting : .pending
            summary.title = operation.state == .cancelling
                ? localised("Cancelling summary", "Создание сводки отменяется")
                : localised("Summary queued", "Сводка в очереди")
        } else if summary.state != .active && summary.state != .failed && summaryStep != .done {
            summary.state = .waiting
            if !ready {
                summary.title = versionOperation != nil || (requested && transcriptStep == .pending)
                    ? localised("Summary waits for transcription", "Сводка ожидает расшифровки")
                    : localised("Create a finished transcript first", "Сначала создайте окончательную расшифровку")
            } else if item.unreadableDiarization {
                summary.title = localised("Summary blocked: diarization state cannot be read", "Сводка заблокирована: не читается состояние диаризации")
            } else if let diarization = item.diarization, !diarization.isFinal {
                summary.title = diarization.hasFailedAttempt || diarization.status == .partial
                    ? localised("Summary waits for diarization — retry or skip", "Сводка ожидает диаризацию — повторите или пропустите её")
                    : diarization.status == .deferred
                        ? localised("Summary waits for the diarization model — download or skip", "Сводка ожидает модель диаризации — скачайте её или пропустите этап")
                        : localised("Summary waits for diarization", "Сводка ожидает диаризацию")
            } else if versionOperation?.kind == .postProcessing && item.speakers.isOutstanding {
                summary.title = localised("Summary waits for speaker naming", "Сводка ожидает определения имён")
            } else if operation != nil || busy || requested {
                summary.title = localised("Summary waits for other processing to finish", "Сводка ожидает завершения другой обработки")
            } else if summaryStep == .deferred {
                summary.title = localised("Summary deferred — retry processing", "Сводка отложена — повторите обработку")
            } else if summaryStep == .off {
                summary.state = .off
                summary.title = localised("Summary was not created", "Сводка не создавалась")
            } else {
                summary.state = .pending
                summary.title = localised("Summary not started", "Сводка ещё не запущена")
            }
        }
        result.append(summary)
        return result
    }
}

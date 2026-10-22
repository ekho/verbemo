import Foundation

/// One availability decision shared by menu items and content buttons.
struct MeetingActionState {
    enum Action: String, CaseIterable {
        case rename, copyTranscript, retranscribe, copySummary, regenerateSummary, openFolder, openTranscript, delete
    }
    var transcriptReady: Bool
    var summaryReady: Bool
    var hasAudio: Bool
    var isRecording: Bool
    var isBusy: Bool
    var configReadable: Bool
    var transcriptionEnabled: Bool
    var summaryEnabled: Bool
    var hasPendingTranscript = false

    func reason(for action: Action) -> String? {
        switch action {
        case .rename: return nil
        case .copyTranscript, .openTranscript:
            return transcriptReady ? nil : localised("The transcript is not ready.", "Расшифровка ещё не готова.")
        case .copySummary:
            return summaryReady ? nil : localised("No summary is available.", "Сводка ещё не готова.")
        case .openFolder:
            return isRecording ? localised("Available after recording ends.", "Доступно после завершения записи.") : nil
        case .delete, .retranscribe, .regenerateSummary:
            if isRecording { return localised("Finish the recording first.", "Сначала завершите запись.") }
            if isBusy { return localised("Wait for processing to finish.", "Дождитесь завершения обработки.") }
            if action == .delete { return nil }
            if !configReadable { return localised("Fix config.json before processing.", "Сначала исправьте config.json.") }
            if action == .regenerateSummary {
                if !transcriptReady || hasPendingTranscript { return localised("A finished transcript is required.", "Сначала нужна готовая расшифровка.") }
            } else {
                if !hasAudio { return localised("The source audio was not kept.", "Исходное аудио не сохранено.") }
                if !transcriptionEnabled { return localised("Enable transcription in settings.", "Включите расшифровку в настройках.") }
            }
            return nil
        }
    }
}

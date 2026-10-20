using static Verbemo.Core.Localization.Localized;

namespace Verbemo.Core.Processing;

public enum MeetingAction { Rename, CopyTranscript, Retranscribe, CopySummary, RegenerateSummary, OpenFolder, Delete }

public sealed record MeetingActionState(bool TranscriptReady, bool SummaryReady, bool HasAudio, bool IsRecording,
    bool IsBusy, bool ConfigReadable, bool TranscriptionEnabled, bool SummaryEnabled, bool HasPendingTranscript = false)
{
    public string? Reason(MeetingAction action)
    {
        if (action == MeetingAction.Rename) return null;
        if (action == MeetingAction.CopyTranscript) return TranscriptReady ? null : T("The transcript is not ready.", "Расшифровка ещё не готова.");
        if (action == MeetingAction.CopySummary) return SummaryReady ? null : T("No summary is available.", "Сводка ещё не готова.");
        if (action == MeetingAction.OpenFolder) return IsRecording ? T("Available after recording ends.", "Доступно после завершения записи.") : null;
        if (IsRecording) return T("Finish the recording first.", "Сначала завершите запись.");
        if (IsBusy) return T("Wait for processing to finish.", "Дождитесь завершения обработки.");
        if (action == MeetingAction.Delete) return null;
        if (!ConfigReadable) return T("Fix config.json before processing.", "Сначала исправьте config.json.");
        if (action == MeetingAction.RegenerateSummary)
        {
            if (!TranscriptReady || HasPendingTranscript) return T("A finished transcript is required.", "Сначала нужна готовая расшифровка.");
            if (!SummaryEnabled) return T("Enable summary generation in settings.", "Включите создание сводки в настройках.");
        }
        else
        {
            if (!HasAudio) return T("The source audio was not kept.", "Исходное аудио не сохранено.");
            if (!TranscriptionEnabled) return T("Enable transcription in settings.", "Включите расшифровку в настройках.");
        }
        return null;
    }
}

using static Verbemo.Core.Localization.Localized;

namespace Verbemo.Core.Processing;

public enum MeetingFilter { All, Processing, Attention }

public static class MeetingPresentation
{
    public static string Date(SessionListItem item) => item.StartedAt.ToLocalTime().ToString("dd.MM.yyyy HH:mm", System.Globalization.CultureInfo.InvariantCulture);
    public static bool Matches(SessionListItem item, MeetingFilter filter, string query, bool busy) =>
        item.Title.Contains(query.Trim(), StringComparison.CurrentCultureIgnoreCase) && filter switch
        {
            MeetingFilter.Processing => busy || item.Transcript is ProcessingStep.Recording or ProcessingStep.Transcribing or ProcessingStep.Pending,
            MeetingFilter.Attention => item.Problem is not null || new[] { item.Transcript, item.SpeakerNames, item.Summary }.Any(s => s is ProcessingStep.Failed or ProcessingStep.Deferred),
            _ => true,
        };
    public static string SummaryLabel(ProcessingStep step, bool russian = false) => step switch
    {
        ProcessingStep.Off => russian ? "Сводка не создавалась" : T("No summary was created", "Сводка не создавалась"),
        ProcessingStep.Done => T("Summary ready", "Сводка готова"),
        ProcessingStep.Failed or ProcessingStep.Deferred => T("Summary needs attention", "Сводка требует внимания"),
        _ => T("Summary pending", "Ожидание сводки"),
    };
}

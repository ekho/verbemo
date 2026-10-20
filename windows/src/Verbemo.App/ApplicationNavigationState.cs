namespace Verbemo.App;

internal enum ApplicationDestination { AllMeetings, Processing, Attention, General, Recording, Transcription, Summary, Storage, About, Live }

internal sealed class ApplicationNavigationState
{
    public ApplicationDestination Destination { get; set; } = ApplicationDestination.AllMeetings;
    public string Query { get; set; } = "";
    public string? SessionDirectory { get; set; }
    public string? VersionKey { get; set; }
    public int Tab { get; set; }
}

using Verbemo.Core.Processing;

namespace Verbemo.Core.Tests;

public sealed class MeetingActionStateTests
{
    private static readonly MeetingActionState Ready = new(true, true, true, false, false, true, true, true);

    [Fact]
    public void Menu_groups_each_copy_with_its_processing_command() => Assert.Equal(
        new[] { MeetingAction.Rename, MeetingAction.CopyTranscript, MeetingAction.Retranscribe, MeetingAction.CopySummary,
            MeetingAction.RegenerateSummary, MeetingAction.OpenFolder, MeetingAction.Delete }, Enum.GetValues<MeetingAction>());

    [Fact]
    public void Summary_requires_finished_transcript_and_usable_settings()
    {
        Assert.Null(Ready.Reason(MeetingAction.RegenerateSummary));
        foreach (var state in new[] { Ready with { TranscriptReady = false }, Ready with { HasPendingTranscript = true },
            Ready with { IsRecording = true }, Ready with { IsBusy = true }, Ready with { ConfigReadable = false },
            Ready with { SummaryEnabled = false } })
            Assert.NotNull(state.Reason(MeetingAction.RegenerateSummary));
    }

    [Fact]
    public void Ready_copies_survive_processing_but_destructive_actions_wait()
    {
        var busy = Ready with { IsBusy = true };
        Assert.Null(busy.Reason(MeetingAction.CopyTranscript));
        Assert.Null(busy.Reason(MeetingAction.CopySummary));
        Assert.NotNull(busy.Reason(MeetingAction.Delete));
        Assert.NotNull((Ready with { HasAudio = false }).Reason(MeetingAction.Retranscribe));
        Assert.NotNull((Ready with { TranscriptionEnabled = false }).Reason(MeetingAction.Retranscribe));
        Assert.NotNull((Ready with { IsRecording = true }).Reason(MeetingAction.OpenFolder));
    }
}

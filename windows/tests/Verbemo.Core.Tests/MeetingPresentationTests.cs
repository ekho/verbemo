using Verbemo.Core.Processing;

namespace Verbemo.Core.Tests;

public sealed class MeetingPresentationTests
{
    private static SessionListItem Meeting(ProcessingStep transcript, ProcessingStep summary) => new("path", "Words", new(2026,10,20,10,0,0,TimeSpan.Zero),
        2280,"manual","whisper",transcript,ProcessingStep.Done,summary,0,true);
    [Fact]
    public void Filters_follow_actual_states_and_date_is_explicit()
    {
        var ready = Meeting(ProcessingStep.Done, ProcessingStep.Done);
        Assert.Contains("20.10.2026", MeetingPresentation.Date(ready));
        Assert.False(MeetingPresentation.Matches(ready, MeetingFilter.Processing, "", false));
        Assert.True(MeetingPresentation.Matches(ready, MeetingFilter.All, "words", false));
        Assert.False(MeetingPresentation.Matches(ready, MeetingFilter.All, "absent", false));
        Assert.True(MeetingPresentation.Matches(ready, MeetingFilter.Processing, "", true));
        Assert.True(MeetingPresentation.Matches(Meeting(ProcessingStep.Failed,ProcessingStep.Pending), MeetingFilter.Attention, "", false));
        Assert.Equal("Сводка не создавалась", MeetingPresentation.SummaryLabel(ProcessingStep.Off, russian: true));
    }
}

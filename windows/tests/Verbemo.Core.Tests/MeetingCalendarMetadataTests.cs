using System.Text.Json;
using Verbemo.Core.Sessions;

namespace Verbemo.Core.Tests;

public sealed class MeetingCalendarMetadataTests
{
    [Fact]
    public void Participants_are_ordered_by_email_with_missing_addresses_last()
    {
        using var json = JsonDocument.Parse("""
            {"participants":[{"id":"z","name":"Aaron","email":"z@example.test"},
            {"id":"none","name":"No email"},{"id":"b","name":"Alex","email":" B@example.test "},
            {"id":"a","name":"Zoe","email":"a@example.test"}]}
            """);
        Assert.Equal(["a", "b", "z", "none"], MeetingCalendarMetadata.Parse(json.RootElement).Participants.Select(p => p.Id));
    }

    [Theory]
    [InlineData("candidate", false)]
    [InlineData("confirmed", true)]
    public void Only_explicit_identity_is_linked_and_call_url_is_never_calendar_url(string association, bool linked)
    {
        using var json = JsonDocument.Parse("{\"event_id\":\"event\",\"association\":\""+association+"\",\"link\":\"https://call.test\",\"event_url\":\"file:///private\",\"participants\":[{\"id\":\"a\",\"name\":\"Alex\"},{\"id\":\"b\",\"name\":\"Alex\"}],\"agenda\":\"  \"}");
        var metadata = MeetingCalendarMetadata.Parse(json.RootElement);
        Assert.Equal(linked, metadata.IsConfirmed);
        Assert.Null(metadata.EventUrl);
        Assert.Null(metadata.Agenda);
        Assert.Equal(2, metadata.Participants.Count);
        using var legacy = JsonDocument.Parse("{\"title\":\"Old invitation\",\"attendees\":[\"Alex\"]}");
        Assert.False(MeetingCalendarMetadata.Parse(legacy.RootElement).IsConfirmed);
    }
}

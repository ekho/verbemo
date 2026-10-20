using System.Text.Json;
using System.Text.Json.Serialization;

namespace Verbemo.Core.Sessions;

public sealed record CalendarParticipant([property: JsonPropertyName("id")] string Id, [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("email")] string? Email = null, [property: JsonPropertyName("organizer")] bool? Organizer = null);

public sealed record MeetingCalendarMetadata(string? EventId, string? Association, string Title, string? CalendarTitle,
    Uri? EventUrl, string? Agenda, IReadOnlyList<CalendarParticipant> Participants)
{
    public bool IsConfirmed => Association == "confirmed" && !string.IsNullOrWhiteSpace(EventId);
    public static MeetingCalendarMetadata Parse(JsonElement json)
    {
        string? Text(string key) => json.TryGetProperty(key,out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        var url = Uri.TryCreate(Text("event_url"),UriKind.Absolute,out var parsed) && parsed.Scheme is "http" or "https" ? parsed : null;
        var agenda = Text("agenda")?.Trim();
        var participants = new List<CalendarParticipant>();
        if (json.TryGetProperty("participants",out var list) && list.ValueKind == JsonValueKind.Array)
            foreach(var entry in list.EnumerateArray())
            {
                try
                {
                    var person = entry.Deserialize<CalendarParticipant>();
                    if(person is not null && !string.IsNullOrWhiteSpace(person.Id) && !string.IsNullOrWhiteSpace(person.Name)
                        && participants.All(p => p.Id != person.Id)) participants.Add(person);
                }
                catch(JsonException) { }
            }
        return new(Text("event_id"),Text("association"),Text("title") ?? "",Text("calendar_title"),url,
            string.IsNullOrEmpty(agenda) ? null : agenda,participants);
    }
    public static async Task<MeetingCalendarMetadata?> ReadAsync(string directory, CancellationToken cancellationToken = default)
    {
        try
        {
            using var json = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(directory,"meta.json"),cancellationToken).ConfigureAwait(false));
            return json.RootElement.TryGetProperty("calendar",out var calendar) && calendar.ValueKind == JsonValueKind.Object ? Parse(calendar) : null;
        }
        catch(Exception error) when(error is IOException or JsonException or UnauthorizedAccessException) { return null; }
    }
}

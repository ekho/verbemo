using Verbemo.App;
using Verbemo.Core.Configuration;
using Verbemo.Core.Processing;
using Verbemo.Core.Sessions;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class SpeakerParticipantMappingTests
{
    [Fact]
    public async Task Mapping_uses_invited_identity_is_version_scoped_and_unlink_restores_manual_name()
    {
        var root = Path.Combine(Path.GetTempPath(), "verbemo-mapping", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var settings = AppSettings.CreateConservative(root);
        using var http = new HttpClient();
        await using var analytics = new AnalyticsService(root, () => settings, () => false, http);
        await using var processor = new ProcessingCoordinator(() => settings, () => true, new SecretStore(), new ModelManager(root,http),http,analytics);
        try
        {
            File.WriteAllText(Path.Combine(root,"meta.json"), "{\"title\":\"Test\",\"calendar\":{\"event_id\":\"e\",\"association\":\"confirmed\",\"participants\":[{\"id\":\"a\",\"name\":\"Alex\"},{\"id\":\"b\",\"name\":\"Alex\"}]}}");
            await TranscriptWriter.WriteAsync(root,"Test",new("whisper","tiny",DateTimeOffset.UtcNow,[new(0,1000,"Hello","A")]));
            await processor.SetSpeakerNameAsync(root,"A","Manual");
            await TranscriptVersions.ArchiveCurrentAsync(root);
            var archive = Directory.GetDirectories(Path.Combine(root,"transcripts")).Single();
            await processor.SetSpeakerParticipantAsync(archive,"A",new CalendarParticipant("b","Forged name"));
            var bound = await SpeakerFile.ReadAsync(archive,default);
            Assert.Equal("Alex",bound.Names["A"]);
            Assert.Equal("b",bound.ParticipantIds["A"]);
            Assert.Equal("Manual",(await SpeakerFile.ReadAsync(root,default)).Names["A"]);
            await processor.SetSpeakerParticipantAsync(archive,"A",null);
            Assert.Equal("Manual",(await SpeakerFile.ReadAsync(archive,default)).Names["A"]);
            await Assert.ThrowsAsync<InvalidOperationException>(() => processor.SetSpeakerParticipantAsync(root,"A",new CalendarParticipant("outside","Unknown")));
            File.WriteAllText(Path.Combine(root,TranscriptVersions.RequestFile),"whisper");
            await Assert.ThrowsAsync<InvalidOperationException>(() => processor.SetSpeakerParticipantAsync(root,"A",new CalendarParticipant("a","Alex")));
        }
        finally { Directory.Delete(root,true); }
    }
}

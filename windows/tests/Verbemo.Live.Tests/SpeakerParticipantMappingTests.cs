using Verbemo.App;
using Verbemo.Core.Configuration;
using Verbemo.Core.Processing;
using Verbemo.Core.Sessions;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class SpeakerParticipantMappingTests
{
    [Fact]
    public async Task No_self_email_or_auto_identity_does_not_read_or_change_the_transcript()
    {
        var root = Path.Combine(Path.GetTempPath(), "verbemo-self-mapping", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var settings = AppSettings.CreateConservative(root);
        using var http = new HttpClient();
        await using var analytics = new AnalyticsService(root, () => settings, () => false, http);
        await using var processor = new ProcessingCoordinator(() => settings, () => true, new SecretStore(), new ModelManager(root, http), http, analytics);
        try
        {
            File.WriteAllText(Path.Combine(root, "meta.json"), "{}");
            File.WriteAllText(Path.Combine(root, "transcript.json"), "not a transcript");
            await processor.RefreshSelfParticipantAsync(root);
            Assert.Equal("not a transcript", File.ReadAllText(Path.Combine(root, "transcript.json")));
            Assert.False(File.Exists(Path.Combine(root, "speakers.json")));
            Assert.False(processor.IsBusy);
        }
        finally { Directory.Delete(root, true); }
    }

    [Theory]
    [InlineData("me", " ME@EXAMPLE.TEST ", "confirmed", "self")]
    [InlineData("them A", "me@example.test", "confirmed", null)]
    [InlineData("me A", "me@example.test", "confirmed", null)]
    [InlineData("?", "me@example.test", "confirmed", null)]
    [InlineData("me ?", "me@example.test", "confirmed", null)]
    [InlineData("me", "other@example.test", "confirmed", null)]
    [InlineData("me", "me@example.test", "suggested", null)]
    [InlineData("me", "", "confirmed", null)]
    [InlineData("me", "me@example.test", "duplicate", null)]
    [InlineData("me", "me@example.test", "missing", null)]
    public async Task Self_identity_uses_only_unique_confirmed_email_for_known_me(string label, string email, string association, string? expectedId)
    {
        var root = Path.Combine(Path.GetTempPath(), "verbemo-self-mapping", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var settings = System.Text.Json.JsonSerializer.Deserialize<AppSettings>("{\"user_email\":" + System.Text.Json.JsonSerializer.Serialize(email) + "}", AppSettings.JsonOptions)!;
            settings.UserName = "Account Name";
            settings.SpeakerNames.Backend = "none";
            using var http = new HttpClient();
            var models = new LanguageModels(http, new SecretStore(), () => settings);
            var naming = new SpeakerNamingService(models, () => settings);
            var metadata = "{\"calendar\":{\"event_id\":\"e\",\"association\":\"" + (association == "duplicate" ? "confirmed" : association) + "\",\"participants\":[{\"id\":\"self\",\"name\":\"Invited Name\",\"email\":\"me@example.test\"},{\"id\":\"other\",\"name\":\"Account Name\",\"email\":\"different@example.test\"}";
            if (association == "duplicate") metadata += ",{\"id\":\"duplicate\",\"name\":\"Another\",\"email\":\"ME@example.test\"}";
            metadata += "]}}";
            File.WriteAllText(Path.Combine(root, "meta.json"), association == "missing" ? "{}" : metadata);
            var document = new TranscriptDocument("whisper", "tiny", DateTimeOffset.UtcNow, [new(0, 1000, "Hello", label)]);
            await naming.ResolveAsync(root, document, default);
            var file = await SpeakerFile.ReadAsync(root, default);
            Assert.Equal(expectedId, file.ParticipantIds.GetValueOrDefault(label));
            if (expectedId is not null) Assert.Equal("Account Name", file.Names[label]);
            if (label != "me") Assert.False(file.Names.ContainsKey(label));
        }
        finally { Directory.Delete(root, true); }
    }

    [Theory]
    [InlineData(null)]
    [InlineData("Configured")]
    public async Task Opening_existing_version_links_known_me_even_when_model_naming_is_disabled(string? userName)
    {
        var root = Path.Combine(Path.GetTempPath(), "verbemo-self-mapping", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var settings = AppSettings.CreateConservative(root);
        settings.UserEmail = "me@example.test";
        settings.UserName = userName;
        using var http = new HttpClient();
        await using var analytics = new AnalyticsService(root, () => settings, () => false, http);
        await using var processor = new ProcessingCoordinator(() => settings, () => true, new SecretStore(), new ModelManager(root, http), http, analytics);
        try
        {
            File.WriteAllText(Path.Combine(root, "meta.json"), "{\"title\":\"Test\",\"calendar\":{\"event_id\":\"e\",\"association\":\"confirmed\",\"participants\":[{\"id\":\"self\",\"name\":\"Calendar\",\"email\":\"me@example.test\"}]}}");
            await TranscriptWriter.WriteAsync(root, "Test", new("whisper", "tiny", DateTimeOffset.UtcNow, [new(0, 1000, "Hello", "me")]));
            await TranscriptVersions.ArchiveCurrentAsync(root);
            var archive = Directory.GetDirectories(Path.Combine(root, "transcripts")).Single();
            var current = File.ReadAllBytes(Path.Combine(root, "transcript.json"));
            await processor.RefreshSelfParticipantAsync(archive);
            var mapped = await SpeakerFile.ReadAsync(archive, default);
            Assert.Equal("self", mapped.ParticipantIds["me"]);
            Assert.Equal(userName ?? "Calendar", mapped.Names["me"]);
            Assert.Contains(userName ?? "Calendar", File.ReadAllText(Path.Combine(archive, "transcript.md")));
            Assert.Equal(current, File.ReadAllBytes(Path.Combine(root, "transcript.json")));
            Assert.Empty((await SpeakerFile.ReadAsync(root, default)).ParticipantIds);
            settings.UserEmail = null;
            await processor.RefreshSelfParticipantAsync(archive);
            var cleared = await SpeakerFile.ReadAsync(archive, default);
            Assert.Empty(cleared.ParticipantIds);
            Assert.Equal(userName, cleared.Names.GetValueOrDefault("me"));
            settings.UserEmail = "me@example.test";
            await processor.RefreshSelfParticipantAsync(archive);
            await processor.SetSpeakerParticipantAsync(archive, "me", null);
            await processor.RefreshSelfParticipantAsync(archive);
            var unlinked = await SpeakerFile.ReadAsync(archive, default);
            Assert.Empty(unlinked.ParticipantIds);
            Assert.Equal(userName, unlinked.Names.GetValueOrDefault("me"));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task Self_link_preserves_manual_choice_and_unlink_does_not_relink()
    {
        var root = Path.Combine(Path.GetTempPath(), "verbemo-self-mapping", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var settings = System.Text.Json.JsonSerializer.Deserialize<AppSettings>("{\"user_email\":\"me@example.test\",\"user_name\":\"Account\"}", AppSettings.JsonOptions)!;
        settings.SpeakerNames.Backend = "none";
        using var http = new HttpClient();
        await using var analytics = new AnalyticsService(root, () => settings, () => false, http);
        await using var processor = new ProcessingCoordinator(() => settings, () => true, new SecretStore(), new ModelManager(root, http), http, analytics);
        try
        {
            File.WriteAllText(Path.Combine(root, "meta.json"), "{\"calendar\":{\"event_id\":\"e\",\"association\":\"confirmed\",\"participants\":[{\"id\":\"self\",\"name\":\"Calendar\",\"email\":\"me@example.test\"}]}}");
            var document = new TranscriptDocument("whisper", "tiny", DateTimeOffset.UtcNow, [new(0, 1000, "Hello", "me")]);
            await TranscriptWriter.WriteAsync(root, "Test", document);
            await processor.SetSpeakerNameAsync(root, "me", "Manual");
            var naming = new SpeakerNamingService(new LanguageModels(http, new SecretStore(), () => settings), () => settings);
            await naming.ResolveAsync(root, document, default);
            Assert.Equal("Manual", (await SpeakerFile.ReadAsync(root, default)).Names["me"]);
            await processor.SetSpeakerParticipantAsync(root, "me", new("self", "Forged"));
            await processor.SetSpeakerParticipantAsync(root, "me", null);
            await naming.ResolveAsync(root, document, default);
            var unlinked = await SpeakerFile.ReadAsync(root, default);
            Assert.Empty(unlinked.ParticipantIds);
            Assert.Equal("Manual", unlinked.Names["me"]);
            await processor.SetSpeakerNameAsync(root, "me", "");
            await naming.ResolveAsync(root, document, default);
            Assert.False((await SpeakerFile.ReadAsync(root, default)).ParticipantIds.ContainsKey("me"));
        }
        finally { Directory.Delete(root, true); }
    }

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
            await TranscriptWriter.WriteAsync(root,"Test",new("whisper","tiny",DateTimeOffset.UtcNow,[new(0,1000,"Uncertain","?")]));
            await Assert.ThrowsAsync<InvalidOperationException>(() => processor.SetSpeakerParticipantAsync(root,"?",new CalendarParticipant("a","Alex")));
            await Assert.ThrowsAsync<InvalidOperationException>(() => processor.SetSpeakerNameAsync(root,"?","Alex"));
            await TranscriptWriter.WriteAsync(root,"Test",new("whisper","tiny",DateTimeOffset.UtcNow,[new(0,1000,"Hello","them")]));
            var before = File.ReadAllBytes(Path.Combine(root,"transcript.json"));
            await Assert.ThrowsAsync<InvalidOperationException>(() => processor.SetSpeakerParticipantAsync(root,"them",new CalendarParticipant("a","Alex")));
            Assert.Equal(before,File.ReadAllBytes(Path.Combine(root,"transcript.json")));
            File.WriteAllText(Path.Combine(root,TranscriptVersions.RequestFile),"whisper");
            await Assert.ThrowsAsync<InvalidOperationException>(() => processor.SetSpeakerParticipantAsync(root,"A",new CalendarParticipant("a","Alex")));
        }
        finally { Directory.Delete(root,true); }
    }
}

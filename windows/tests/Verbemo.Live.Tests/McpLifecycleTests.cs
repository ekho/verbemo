using System.IO;
using System.Net;
using System.Net.Http;
using System.Text.Json.Nodes;
using Verbemo.App;
using Verbemo.App.MCP;
using Verbemo.Core.Configuration;
using Verbemo.Core.MCP;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class McpLifecycleTests
{
    private sealed class Fixture : IAsyncDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(),"verbemo-mcp-test-"+Guid.NewGuid().ToString("N"));
        public SecretStore Secrets { get; } = new("Verbemo.Task4.Lifecycle/"+Guid.NewGuid().ToString("N")+"/");
        public AppSettingsStore Store { get; }
        public McpController Controller { get; }
        public string Token { get; } = McpController.NewToken();
        public int Port { get; } = McpTransportTests.Port();
        public string AudioPath { get; }
        public Fixture(bool token=true)
        {
            Directory.CreateDirectory(Root); var library=Path.Combine(Root,"library"); var meeting=Path.Combine(library,"meeting"); Directory.CreateDirectory(meeting);
            AudioPath=Path.Combine(meeting,"mic.wav"); using(var file=File.Create(AudioPath)) file.SetLength(40*1024*1024);
            File.WriteAllText(Path.Combine(meeting,"meta.json"),"""{"title":"Synthetic","started":"2026-10-28T10:00:00Z","ended":"2026-10-28T11:00:00Z","files":{"mic":"mic.wav"}}""");
            Store=new(Path.Combine(Root,"config.json"),Root); var settings=Store.Defaults; settings.RecordingsDirectory=library; settings.Mcp.Enabled=true; settings.Mcp.Port=Port; Store.Save(settings);
            if(token) Secrets.Set(McpController.TokenName,Token);
            Controller=new(Store,Secrets,(root,port,ct)=>new McpLibrary.Runtime(root,port,cancellation:ct),new Dictionary<string,JsonNode?>());
        }
        public string AudioUri()
        {
            var settings=Store.Load().Settings; var runtime=new McpLibrary.Runtime(settings.RecordingsDirectory,Port);
            var id=McpContract.MeetingId(settings.RecordingsDirectory,"meeting");
            return McpQueries.Call("get_meeting_audio",new JsonObject { ["meeting_id"]=id },runtime)["items"]![0]!["download_uri"]!.GetValue<string>();
        }
        public async ValueTask DisposeAsync() { await Controller.DisposeAsync(); Secrets.Set(McpController.TokenName,null); Directory.Delete(Root,true); }
    }
    [Fact]
    public async Task Synced_enable_without_local_token_stays_closed_and_does_not_create_credentials()
    {
        await using var fixture=new Fixture(token:false); await fixture.Controller.ReconcileAsync();
        Assert.Equal("token_missing",fixture.Controller.Status); Assert.Null(fixture.Controller.ActiveEndpoint); Assert.Null(fixture.Secrets.GetStrict(McpController.TokenName)); Assert.True(fixture.Store.Load().Settings.Mcp.Enabled);
    }
    [Theory]
    [InlineData("null")]
    [InlineData("{broken")]
    [InlineData("{\"mcp\":{\"enabled\":true,\"port\":\"52763\"}}")]
    [InlineData("{\"mcp\":{\"enabled\":true,\"port\":1023}}")]
    public async Task Corrupt_config_closes_existing_service_without_rewriting_saved_data(string corrupt)
    {
        await using var fixture=new Fixture(); await fixture.Controller.ReconcileAsync(); using var client=McpTransportTests.Client(fixture.Port,fixture.Token);
        File.WriteAllText(fixture.Store.ConfigPath,corrupt);
        using var response=await McpTransportTests.Post(client,"""{"jsonrpc":"2.0","id":1,"method":"tools/list"}"""); Assert.Equal(HttpStatusCode.ServiceUnavailable,response.StatusCode);
        Assert.Equal(corrupt,File.ReadAllText(fixture.Store.ConfigPath)); Assert.Null(fixture.Controller.ActiveEndpoint);
    }
    [Fact]
    public async Task Head_and_single_range_return_original_bytes_and_unsatisfiable_range_is_explicit()
    {
        await using var fixture=new Fixture(); await fixture.Controller.ReconcileAsync(); using var client=McpTransportTests.Client(fixture.Port,fixture.Token); var uri=fixture.AudioUri();
        using var head=await client.SendAsync(new(HttpMethod.Head,uri)); Assert.Equal(HttpStatusCode.OK,head.StatusCode); Assert.Equal(40*1024*1024,head.Content.Headers.ContentLength); Assert.Empty(await head.Content.ReadAsByteArrayAsync());
        using var range=new HttpRequestMessage(HttpMethod.Get,uri); range.Headers.Range=new(3,18); using var partial=await client.SendAsync(range);
        Assert.Equal(HttpStatusCode.PartialContent,partial.StatusCode); Assert.Equal(new byte[16],await partial.Content.ReadAsByteArrayAsync()); Assert.Equal("bytes 3-18/41943040",partial.Content.Headers.ContentRange!.ToString());
        using var invalid=new HttpRequestMessage(HttpMethod.Get,uri); invalid.Headers.Range=new(41943040,null); using var rejected=await client.SendAsync(invalid); Assert.Equal(HttpStatusCode.RequestedRangeNotSatisfiable,rejected.StatusCode);
    }
    [Theory]
    [InlineData("token")]
    [InlineData("root")]
    [InlineData("config")]
    [InlineData("stop")]
    public async Task Lifecycle_change_cancels_inflight_audio_and_removes_active_endpoint(string change)
    {
        await using var fixture=new Fixture(); await fixture.Controller.ReconcileAsync(); using var client=McpTransportTests.Client(fixture.Port,fixture.Token);
        using var response=await client.GetAsync(fixture.AudioUri(),HttpCompletionOption.ResponseHeadersRead); await using var stream=await response.Content.ReadAsStreamAsync(); var buffer=new byte[65536]; long received=await stream.ReadAsync(buffer);
        Assert.True(received>0);
        if(change=="token") { await fixture.Controller.RotateAsync(); Assert.Equal("running",fixture.Controller.Status); Assert.NotNull(fixture.Controller.ActiveEndpoint); }
        else if(change=="root") { var settings=fixture.Store.Load().Settings; settings.RecordingsDirectory=Path.Combine(fixture.Root,"new-root"); Directory.CreateDirectory(settings.RecordingsDirectory); fixture.Store.Save(settings); await fixture.Controller.ReconcileAsync(); }
        else if(change=="config") File.WriteAllText(fixture.Store.ConfigPath,"{broken");
        else await fixture.Controller.DisposeAsync();
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try { while(true) { var count=await stream.ReadAsync(buffer,timeout.Token); if(count==0) break; received+=count; } } catch(IOException) { } catch(HttpRequestException) { }
        Assert.True(received<41943040,"Revoked audio must not complete.");
        if(change is "config" or "stop") Assert.Null(fixture.Controller.ActiveEndpoint);
        if(change=="token") { using var old=await McpTransportTests.Post(client,"""{"jsonrpc":"2.0","id":1,"method":"tools/list"}"""); Assert.Equal(HttpStatusCode.Unauthorized,old.StatusCode); }
    }
    [Fact]
    public async Task Audio_longer_than_json_deadline_completes_when_each_read_is_active()
    {
        await using var fixture=new Fixture(); await fixture.Controller.ReconcileAsync(); using var client=McpTransportTests.Client(fixture.Port,fixture.Token);
        using var response=await client.GetAsync(fixture.AudioUri(),HttpCompletionOption.ResponseHeadersRead); await using var stream=await response.Content.ReadAsStreamAsync();
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(100)); var buffer=new byte[65536]; long total=0; var elapsed=System.Diagnostics.Stopwatch.StartNew();
        while(true) { var count=await stream.ReadAsync(buffer,timeout.Token); if(count==0) break; Assert.True(buffer.AsSpan(0,count).IndexOfAnyExcept((byte)0)<0); total+=count; await Task.Delay(55,timeout.Token); }
        Assert.Equal(41943040,total); Assert.True(elapsed.Elapsed>TimeSpan.FromSeconds(30));
    }
}

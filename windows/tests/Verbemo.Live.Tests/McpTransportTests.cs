using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using Verbemo.App;
using Verbemo.App.MCP;
using Verbemo.Core.MCP;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class McpTransportTests
{
    private const string Token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    internal static int Port() { using var listener = new TcpListener(IPAddress.Loopback,0); listener.Start(); return ((IPEndPoint)listener.LocalEndpoint).Port; }
    internal static HttpClient Client(int port, string? token = Token)
    {
        var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseProxy = false }) { BaseAddress = new Uri($"http://127.0.0.1:{port}"), Timeout = TimeSpan.FromSeconds(40) };
        if(token is not null) client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer",token);
        client.DefaultRequestHeaders.Accept.ParseAdd("application/json, text/event-stream"); return client;
    }
    internal static Task<HttpResponseMessage> Post(HttpClient client, string json) => client.PostAsync("/mcp",new StringContent(json,Encoding.UTF8,"application/json"));
    private static McpServer Server(int port, Func<bool>? current = null, Func<string,JsonObject,CancellationToken,Task<JsonObject>>? query = null) => new(port, Token,current ?? (() => true),
        query ?? ((name,args,ct) => Task.FromResult(new JsonObject { ["echo"] = args["meeting_id"]?.DeepClone() })),
        (_,_,_) => throw new McpFailure("artifact_missing"));

    [Fact]
    public async Task Stateless_sdk_negotiates_real_codex_initialize_and_lists_only_eight_readonly_tools()
    {
        var port=Port(); await using var server=Server(port); await server.StartAsync(); using var client=Client(port);
        using var initialized=await Post(client,"""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex","version":"0.154.0"}}}""");
        Assert.Equal(HttpStatusCode.OK,initialized.StatusCode);
        var reply=McpBridge.DecodeReply(await initialized.Content.ReadAsByteArrayAsync(),initialized.Content.Headers.ContentType!.MediaType!);
        Assert.Equal("2025-11-25",reply["result"]!["protocolVersion"]!.GetValue<string>());
        using var listed=await Post(client,"""{"jsonrpc":"2.0","id":2,"method":"tools/list"}""");
        var tools=McpBridge.DecodeReply(await listed.Content.ReadAsByteArrayAsync(),listed.Content.Headers.ContentType!.MediaType!)["result"]!["tools"]!.AsArray();
        Assert.Equal(McpContract.Tools.Order(),tools.Select(x=>x!["name"]!.GetValue<string>()).Order());
        Assert.All(tools,x=> { Assert.True(x!["annotations"]!["readOnlyHint"]!.GetValue<bool>()); Assert.False(x["annotations"]!["openWorldHint"]!.GetValue<bool>()); });
    }

    [Fact]
    public async Task Concurrent_clients_reusing_id_receive_their_own_result()
    {
        var port=Port(); await using var server=Server(port); await server.StartAsync(); using var a=Client(port); using var b=Client(port);
        var replies=await Task.WhenAll(Post(a,"""{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_meeting","arguments":{"meeting_id":"alpha"}}}"""),Post(b,"""{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_meeting","arguments":{"meeting_id":"beta"}}}"""));
        for(var i=0;i<2;i++) { using var response=replies[i]; var result=McpBridge.DecodeReply(await response.Content.ReadAsByteArrayAsync(),response.Content.Headers.ContentType!.MediaType!); Assert.Equal(i==0?"alpha":"beta",result["result"]!["structuredContent"]!["echo"]!.GetValue<string>()); }
    }

    [Theory]
    [InlineData(null,null,401)]
    [InlineData("wrong",null,401)]
    [InlineData(Token,"null",403)]
    [InlineData(Token,"http://evil.example",403)]
    public async Task Every_endpoint_authenticates_before_parsing(string? token,string? origin,int expected)
    {
        var port=Port(); await using var server=Server(port); await server.StartAsync(); using var client=Client(port,token);
        if(origin is not null) client.DefaultRequestHeaders.Add("Origin",origin);
        using var response=await Post(client,"private-malformed-content"); Assert.Equal(expected,(int)response.StatusCode);
        Assert.DoesNotContain("private-malformed-content",await response.Content.ReadAsStringAsync());
        using var audio=await client.GetAsync("/audio/m_bad/a_bad"); Assert.Equal(expected,(int)audio.StatusCode);
    }

    [Fact]
    public async Task Current_configuration_failure_revokes_admission_without_exposing_exception()
    {
        bool current=true; var port=Port(); await using var server=Server(port,()=>current); await server.StartAsync(); using var client=Client(port);
        current=false; using var response=await Post(client,"""{"jsonrpc":"2.0","id":1,"method":"tools/list"}"""); Assert.Equal(HttpStatusCode.ServiceUnavailable,response.StatusCode);
    }

    [Fact]
    public async Task Secret_rotation_uses_an_isolated_credential_target()
    {
        var store=new SecretStore("Verbemo.Task4.Tests/"+Guid.NewGuid().ToString("N")+"/");
        try { Assert.Null(store.GetStrict("mcp.token")); var first=McpController.NewToken(); store.Set("mcp.token",first); Assert.Equal(first,store.GetStrict("mcp.token")); Assert.Matches("^[0-9a-f]{64}$",first); var second=McpController.NewToken(); Assert.NotEqual(first,second); store.Set("mcp.token",second); Assert.Equal(second,store.GetStrict("mcp.token")); }
        finally { store.Set("mcp.token",null); }
        await Task.CompletedTask;
    }

    [Theory]
    [InlineData("data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n",true)]
    [InlineData("data: {}\n\ndata: {}\n\n",false)]
    [InlineData("data: {}",false)]
    public void Bridge_requires_one_complete_bounded_sse_response(string data,bool valid)
    {
        if(valid) Assert.Equal(1,McpBridge.DecodeReply(Encoding.UTF8.GetBytes(data),"text/event-stream")["id"]!.GetValue<int>());
        else Assert.Throws<McpFailure>(()=>McpBridge.DecodeReply(Encoding.UTF8.GetBytes(data),"text/event-stream"));
    }
    [Theory]
    [InlineData("bytes=0-9",0,10,true)]
    [InlineData("bytes=90-",90,10,true)]
    [InlineData("bytes=-20",80,20,true)]
    [InlineData("bytes=0-999",0,100,true)]
    [InlineData("bytes=100-",-1,0,true)]
    [InlineData("bytes=0-1,3-4",-1,0,true)]
    [InlineData("bytes=+1-2",-1,0,true)]
    [InlineData("bytes= 1-2",-1,0,true)]
    public void Single_byte_range_rejects_invalid_syntax(string text,long offset,long count,bool partial)
        => Assert.Equal((offset,count,partial),McpServer.Range(text,100));

    [Fact]
    public void Failed_credential_read_is_not_absence()
    {
        var invalid=new SecretStore("");
        Assert.Throws<System.ComponentModel.Win32Exception>(()=>invalid.GetStrict(""));
    }

    [Fact]
    public async Task Canceled_request_keeps_quota_until_concrete_work_finishes_across_generations()
    {
        var release=new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        var entered=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); int count=0;
        var limits=new McpLimits(); var port=Port();
        await using var first=new McpServer(port,Token,()=>true,(_,_,_)=>{ if(Interlocked.Increment(ref count)==8) entered.TrySetResult(); return release.Task; },(_,_,_)=>throw new McpFailure("artifact_missing"),limits);
        await first.StartAsync(); using var client=Client(port); using var cancel=new CancellationTokenSource();
        var calls=Enumerable.Range(0,8).Select(_=>client.PostAsync("/mcp",new StringContent("""{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_meeting","arguments":{}}}""",Encoding.UTF8,"application/json"),cancel.Token)).ToArray();
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(10)); cancel.Cancel(); await first.DisposeAsync();
            var otherPort=Port(); await using var second=new McpServer(otherPort,Token,()=>true,(_,_,_)=>Task.FromResult(new JsonObject()),(_,_,_)=>throw new McpFailure("artifact_missing"),limits);
            await second.StartAsync(); using var other=Client(otherPort);
            using var denied=await Post(other,"""{"jsonrpc":"2.0","id":1,"method":"tools/list"}"""); Assert.Equal(HttpStatusCode.ServiceUnavailable,denied.StatusCode);
            release.TrySetResult(new JsonObject());
            for(var attempt=0;attempt<100 && limits.Json.CurrentCount!=8;attempt++) await Task.Delay(20);
            using var accepted=await Post(other,"""{"jsonrpc":"2.0","id":1,"method":"tools/list"}"""); Assert.Equal(HttpStatusCode.OK,accepted.StatusCode);
        }
        finally { release.TrySetResult(new JsonObject()); try { await Task.WhenAll(calls); } catch(OperationCanceledException) { } }
    }

    [Fact]
    public async Task Host_origin_and_untrusted_error_content_are_checked_before_sdk_disclosure()
    {
        var port=Port(); await using var server=Server(port); await server.StartAsync(); using var client=Client(port);
        client.DefaultRequestHeaders.Host="localhost:"+port; using var badHost=await Post(client,"{}"); Assert.Equal(HttpStatusCode.Forbidden,badHost.StatusCode);
        client.DefaultRequestHeaders.Host="127.0.0.1:"+port; client.DefaultRequestHeaders.Add("Origin","http://127.0.0.1:"+port);
        using var badBody=await Post(client,"{\"secret-marker\":"); Assert.Equal(HttpStatusCode.BadRequest,badBody.StatusCode); Assert.DoesNotContain("secret-marker",await badBody.Content.ReadAsStringAsync());
        using var valid=await Post(client,"""{"jsonrpc":"2.0","id":1,"method":"tools/list"}"""); Assert.Equal(HttpStatusCode.OK,valid.StatusCode);
    }
    [Fact]
    public async Task Oversized_complete_rpc_reply_is_a_safe_error_instead_of_dropped_connection()
    {
        var port=Port(); await using var server=Server(port,query:(_,_,_)=>Task.FromResult(new JsonObject { ["text"]=new string('界',150000) })); await server.StartAsync(); using var client=Client(port);
        using var response=await Post(client,"""{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_meeting","arguments":{}}}""");
        var result=McpBridge.DecodeReply(await response.Content.ReadAsByteArrayAsync(),response.Content.Headers.ContentType!.MediaType!); Assert.Contains("response_too_large",result.ToJsonString()); Assert.True(McpContract.Encode(result).Length<1048576);
    }

    [Fact]
    public async Task Request_body_limit_rejects_without_running_query()
    {
        var calls=0; var port=Port(); await using var server=Server(port,query:(_,_,_)=> { Interlocked.Increment(ref calls); return Task.FromResult(new JsonObject()); }); await server.StartAsync(); using var client=Client(port);
        using var response=await Post(client,"{\"padding\":\""+new string('x',1048576)+"\"}"); Assert.False(response.IsSuccessStatusCode); Assert.Equal(0,calls);
    }
}

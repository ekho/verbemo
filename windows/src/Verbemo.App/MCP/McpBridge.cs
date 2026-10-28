using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Verbemo.Core.Configuration;
using Verbemo.Core.MCP;

namespace Verbemo.App.MCP;

/// <summary>Stdio client adapter. It never starts the app or accesses the meeting library.</summary>
internal sealed class McpBridge(AppSettingsStore store,SecretStore secrets,string? outputDirectory=null)
{
    private readonly string outputPath=Path.GetFullPath(outputDirectory ?? Path.Combine(Path.GetTempPath(),"verbemo-mcp-"+Guid.NewGuid().ToString("N")));
    private static readonly UTF8Encoding Utf8=new(false,true);
    private readonly SemaphoreSlim outputGate=new(1,1);
    private readonly ConcurrentDictionary<string,CancellationTokenSource> active=new();
    private readonly ConcurrentDictionary<string,Task> tasks=new();
    public static int Main(string[] arguments)
    {
        if(arguments.Length!=1 && !(arguments.Length==3 && arguments[1]=="--output-dir")) return 2;
        try
        {
            var input=Console.OpenStandardInput(); var output=Console.OpenStandardOutput();
            if(ReferenceEquals(input,Stream.Null) || ReferenceEquals(output,Stream.Null)) return 2;
            var profile=McpProfile.Current();
            return new McpBridge(profile.Store,new SecretStore(profile.CredentialPrefix),arguments.Length==3 ? arguments[2] : null).RunAsync(input,output).GetAwaiter().GetResult();
        }
        catch { return 1; }
    }
    internal async Task<int> RunAsync(Stream input,Stream output)
    {
        using var lifetime=new CancellationTokenSource();
        var buffer=new byte[65536]; using var pending=new MemoryStream();
        try
        {
            while(!lifetime.IsCancellationRequested)
            {
                var count=await input.ReadAsync(buffer,lifetime.Token).ConfigureAwait(false); if(count==0) break;
                for(var i=0;i<count;i++)
                {
                    if(buffer[i]!=10) { if(pending.Length>=McpContract.HardResponseBytes) return 1; pending.WriteByte(buffer[i]); continue; }
                    var line=pending.ToArray(); pending.SetLength(0); JsonObject request;
                    try { request=JsonNode.Parse(line) as JsonObject ?? throw new JsonException(); }
                    catch { await Write(Error(null,-32700,"Parse error"),output,lifetime.Token).ConfigureAwait(false); continue; }
                    if(request["method"]?.GetValue<string>()=="notifications/cancelled")
                    { var cancelled=request["params"]?["requestId"]?.ToJsonString(); if(cancelled is not null && active.TryGetValue(cancelled,out var previous)) Cancel(previous); continue; }
                    var key=request["id"]?.ToJsonString() ?? Guid.NewGuid().ToString("N");
                    var scope=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                    if(active.Count>=8 || !active.TryAdd(key,scope))
                    { scope.Dispose(); if(request.ContainsKey("id")) await Write(Error(request["id"],-32603,"Bridge busy"),output,lifetime.Token).ConfigureAwait(false); continue; }
                    tasks[key]=RunOne();
                    async Task RunOne()
                    {
                        try { var reply=await ExchangeAsync(request,scope.Token).ConfigureAwait(false); if(reply is not null && !scope.IsCancellationRequested) await Write(reply,output,scope.Token).ConfigureAwait(false); }
                        catch { lifetime.Cancel(); }
                        finally { active.TryRemove(key,out _); tasks.TryRemove(key,out _); scope.Dispose(); }
                    }
                }
            }
        }
        catch (Exception error) when(error is IOException or OperationCanceledException or JsonException or InvalidOperationException) { }
        finally
        {
            lifetime.Cancel(); foreach(var scope in active.Values) Cancel(scope);
            await Task.WhenAny(Task.WhenAll(tasks.Values),Task.Delay(TimeSpan.FromSeconds(2))).ConfigureAwait(false);
        }
        return 0;
    }
    private static void Cancel(CancellationTokenSource scope)
    { try { scope.Cancel(); } catch (ObjectDisposedException) { } }
    private async Task Write(JsonObject value,Stream output,CancellationToken cancellation)
    {
        var bytes=McpContract.Encode(value); if(bytes.Length>McpContract.HardResponseBytes) throw new McpFailure("response_too_large");
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(cancellation); deadline.CancelAfter(TimeSpan.FromSeconds(30));
        await outputGate.WaitAsync(deadline.Token).ConfigureAwait(false);
        try { await output.WriteAsync(bytes,deadline.Token).ConfigureAwait(false); await output.WriteAsync(new byte[]{10},deadline.Token).ConfigureAwait(false); await output.FlushAsync(deadline.Token).ConfigureAwait(false); }
        finally { outputGate.Release(); }
    }
    internal async Task<JsonObject?> ExchangeAsync(JsonObject request,CancellationToken cancellation)
    {
        var id=request["id"]; var created=new List<string>(); var complete=false;
        try
        {
            if(request.ContainsKey("id") && !(id is JsonValue value && (value.TryGetValue<long>(out _) || value.TryGetValue<string>(out var text) && Utf8.GetByteCount(text)<=1024))) return Error(null,-32600,"Invalid request id");
            var load=McpController.ReadConfiguration(store); var config=load.Settings;
            var token=secrets.GetStrict(McpController.TokenName);
            if(!config.Mcp.Enabled || !McpController.ValidToken(token)) throw new McpFailure("server_stopping");
            using var client=new HttpClient(new HttpClientHandler { AllowAutoRedirect=false,UseProxy=false }) { Timeout=Timeout.InfiniteTimeSpan };
            client.DefaultRequestHeaders.Authorization=new AuthenticationHeaderValue("Bearer",token);
            client.DefaultRequestHeaders.Accept.ParseAdd("application/json, text/event-stream");
            using var timeout=CancellationTokenSource.CreateLinkedTokenSource(cancellation); timeout.CancelAfter(TimeSpan.FromSeconds(30));
            using var message=new HttpRequestMessage(HttpMethod.Post,$"http://127.0.0.1:{config.Mcp.Port}/mcp") { Content=new ByteArrayContent(McpContract.Encode(request)) };
            message.Content.Headers.ContentType=new MediaTypeHeaderValue("application/json");
            using var response=await client.SendAsync(message,HttpCompletionOption.ResponseHeadersRead,timeout.Token).ConfigureAwait(false);
            if(!response.IsSuccessStatusCode) throw new McpFailure("data_unreadable");
            if(response.StatusCode==HttpStatusCode.Accepted) return null;
            var body=await McpServer.ReadBounded(await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false),McpContract.HardResponseBytes+8192,TimeSpan.FromSeconds(10),timeout.Token).ConfigureAwait(false);
            var reply=DecodeReply(body,response.Content.Headers.ContentType?.MediaType ?? "");
            if(!JsonNode.DeepEquals(reply["id"],id) || reply["jsonrpc"]?.GetValue<string>()!="2.0" || reply.ContainsKey("method")) throw new McpFailure("data_unreadable");
            timeout.CancelAfter(Timeout.InfiniteTimeSpan);
            if(request["method"]?.GetValue<string>()=="tools/call" && request["params"]?["name"]?.GetValue<string>()=="get_meeting_audio"
                && reply["error"] is null && reply["result"]?["isError"]?.GetValue<bool>()!=true && reply["result"]?["structuredContent"] is JsonObject content)
            {
                if(content["items"] is not JsonArray items) throw new McpFailure("data_unreadable");
                using var directory=OpenOutput();
                foreach(var item in items)
                {
                    var metadata=item?.AsObject() ?? throw new McpFailure("data_unreadable");
                    var uri=metadata["download_uri"]?.GetValue<string>() ?? "";
                    if(!Permitted(uri,config.Mcp.Port) || metadata["size_bytes"] is not JsonValue sizeValue || !sizeValue.TryGetValue<long>(out var size) || size<0) throw new McpFailure("data_unreadable");
                    var extension=Path.GetExtension(metadata["filename"]?.GetValue<string>() ?? "").ToLowerInvariant();
                    if(!new[]{".caf",".wav",".m4a",".mp3",".flac",".ogg",".opus",".aac",".wma",".mp4",".mov",".mkv",".webm"}.Contains(extension)) throw new McpFailure("data_unreadable");
                    var path=Path.Combine(outputPath,Guid.NewGuid().ToString("N")+extension);
                    await using var file=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None,65536,FileOptions.Asynchronous); created.Add(path);
                    using var download=new HttpRequestMessage(HttpMethod.Get,uri);
                    using var headers=CancellationTokenSource.CreateLinkedTokenSource(cancellation); headers.CancelAfter(TimeSpan.FromSeconds(30));
                    using var audio=await client.SendAsync(download,HttpCompletionOption.ResponseHeadersRead,headers.Token).ConfigureAwait(false);
                    if(audio.StatusCode!=HttpStatusCode.OK || audio.Content.Headers.ContentLength!=size) throw new McpFailure("data_unreadable");
                    headers.CancelAfter(Timeout.InfiniteTimeSpan);
                    await using var stream=await audio.Content.ReadAsStreamAsync(cancellation).ConfigureAwait(false); var buffer=new byte[65536]; long received=0;
                    while(true)
                    {
                        using var idle=CancellationTokenSource.CreateLinkedTokenSource(cancellation); idle.CancelAfter(TimeSpan.FromSeconds(30));
                        var count=await stream.ReadAsync(buffer,idle.Token).ConfigureAwait(false); if(count==0) break;
                        if(received+count>size) throw new McpFailure("data_unreadable");
                        await file.WriteAsync(buffer.AsMemory(0,count),idle.Token).ConfigureAwait(false); received+=count;
                    }
                    if(received!=size) throw new McpFailure("data_unreadable");
                    await file.FlushAsync(cancellation).ConfigureAwait(false); file.Flush(true); metadata["local_path"]=path;
                }
                content.Remove("resources"); reply["result"]=McpContract.ResultEnvelope(content);
            }
            if(McpContract.Encode(reply).Length>McpContract.HardResponseBytes) throw new McpFailure("response_too_large");
            cancellation.ThrowIfCancellationRequested(); complete=true; return reply;
        }
        catch { return id is null ? null : Error(id,-32603,"Verbemo bridge unavailable or transfer failed; check the running app and local MCP settings"); }
        finally { if(!complete) foreach(var path in created) { try { File.Delete(path); } catch(IOException) { } catch(UnauthorizedAccessException) { } } }
    }
    internal static JsonObject Error(JsonNode? id,int code,string message) => new() { ["jsonrpc"]="2.0",["id"]=id?.DeepClone(),["error"]=new JsonObject { ["code"]=code,["message"]=message } };
    internal static JsonObject DecodeReply(byte[] bytes,string contentType,int maximum=McpContract.HardResponseBytes+8192)
    {
        try
        {
            if(bytes.Length>maximum) throw new McpFailure("response_too_large");
            var text=Utf8.GetString(bytes);
            if(contentType=="text/event-stream")
            {
                var events=new List<string>(); var lines=new List<string>();
                foreach(var line in text.Replace("\r\n","\n",StringComparison.Ordinal).Split('\n'))
                {
                    if(line.Length==0) { if(lines.Count>0) { events.Add(string.Join('\n',lines)); lines.Clear(); } }
                    else if(line.StartsWith("data:",StringComparison.Ordinal)) lines.Add(line[5..].StartsWith(' ') ? line[6..] : line[5..]);
                }
                if(lines.Count!=0 || events.Count!=1) throw new McpFailure("data_unreadable"); text=events[0];
            }
            else if(contentType!="application/json") throw new McpFailure("data_unreadable");
            if(Utf8.GetByteCount(text)>McpContract.HardResponseBytes) throw new McpFailure("response_too_large");
            return JsonNode.Parse(text) as JsonObject ?? throw new McpFailure("data_unreadable");
        }
        catch(McpFailure) { throw; }
        catch { throw new McpFailure("data_unreadable"); }
    }
    internal static bool Permitted(string uri,int port) => Regex.IsMatch(uri,$"^http://127\\.0\\.0\\.1:{port}/audio/m_[0-9a-fA-F]{{64}}/a_[0-9a-fA-F]{{64}}$");
    private McpFiles.DirectoryHandle OpenOutput()
    {
        var parent=Path.GetDirectoryName(outputPath) ?? throw new McpFailure("data_unreadable");
        using var anchor=McpFiles.DirectoryHandle.Root(parent);
        var user=WindowsIdentity.GetCurrent().User ?? throw new McpFailure("data_unreadable");
        if(!Directory.Exists(outputPath))
        {
            var security=new DirectorySecurity(); security.SetOwner(user); security.SetAccessRuleProtection(true,false);
            security.AddAccessRule(new FileSystemAccessRule(user,FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
            new DirectoryInfo(outputPath).Create(security);
        }
        var held=McpFiles.DirectoryHandle.Root(outputPath);
        try
        {
            var permissions=new DirectoryInfo(outputPath).GetAccessControl(AccessControlSections.Owner|AccessControlSections.Access);
            if(!user.Equals(permissions.GetOwner(typeof(SecurityIdentifier)))) throw new McpFailure("data_unreadable");
            foreach(FileSystemAccessRule rule in permissions.GetAccessRules(true,true,typeof(SecurityIdentifier)))
                if(rule.AccessControlType==AccessControlType.Allow && !rule.IdentityReference.Equals(user)
                    && rule.IdentityReference.Value is not ("S-1-5-18" or "S-1-5-32-544")) throw new McpFailure("data_unreadable");
            return held;
        }
        catch { held.Dispose(); throw; }
    }
}

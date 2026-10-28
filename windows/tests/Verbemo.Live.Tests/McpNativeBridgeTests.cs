#if DEBUG
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using Verbemo.App;
using Verbemo.App.MCP;
using Verbemo.Core.Configuration;
using Verbemo.Core.MCP;
using Xunit;
using Xunit.Abstractions;

namespace Verbemo.Live.Tests;

[Collection("McpClipboard")]
public sealed class McpNativeBridgeTests(ITestOutputHelper output)
{
    [Fact]
    public async Task Actual_winexe_inherited_pipes_download_original_audio_and_exit_on_eof()
    {
        var root=Path.Combine(Path.GetTempPath(),"VerbemoMcp-native-"+Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        var old=Environment.GetEnvironmentVariable(ProductIdentity.TestDataEnvironmentVariable); SecretStore? secrets=null; McpController? controller=null;
        try
        {
            Environment.SetEnvironmentVariable(ProductIdentity.TestDataEnvironmentVariable,root);
            var profile=McpProfile.Current(); Assert.NotEqual(ProductIdentity.CredentialPrefix,profile.CredentialPrefix); Assert.Equal(profile.DataDirectory,profile.HomeDirectory); Assert.StartsWith(".Test.",profile.InstanceSuffix);
            secrets=new(profile.CredentialPrefix); secrets.Set(McpController.TokenName,McpController.NewToken());
            Environment.SetEnvironmentVariable(ProductIdentity.TestDataEnvironmentVariable,root.ToUpperInvariant()+@"\.");
            Assert.Equal(profile.CredentialPrefix,McpProfile.Current().CredentialPrefix);
            Assert.Equal(profile.InstanceSuffix,McpProfile.Current().InstanceSuffix);
            Environment.SetEnvironmentVariable(ProductIdentity.TestDataEnvironmentVariable,root);
            var library=Path.Combine(root,"library"); var meeting=Path.Combine(library,"meeting"); Directory.CreateDirectory(meeting);
            File.WriteAllText(Path.Combine(meeting,"meta.json"),"""{"title":"Native pipe fixture","files":{"mic":"mic.wav"}}""");
            var bytes=Enumerable.Range(0,200000).Select(i=>(byte)(i%251)).ToArray(); File.WriteAllBytes(Path.Combine(meeting,"mic.wav"),bytes);
            var store=profile.Store; var settings=AppSettings.CreateConservative(profile.HomeDirectory); settings.RecordingsDirectory=library; settings.Mcp.Enabled=true; settings.Mcp.Port=McpTransportTests.Port(); store.Save(settings);
            Assert.StartsWith(profile.DataDirectory,store.Defaults.RecordingsDirectory);
            var language=Verbemo.Core.Localization.Localized.Current;
            await using(var runtime=VerbemoRuntime.Create())
            {
                Assert.Equal(profile.DataDirectory,runtime.DataDirectory);
                Assert.True(runtime.Mcp.ReadToken()==secrets.GetStrict(McpController.TokenName),"GUI runtime must use the same isolated protected store as the bridge.");
                Assert.Equal(library,runtime.Settings.RecordingsDirectory);
            }
            Verbemo.Core.Localization.Localized.Current=language;
            controller=new(store,secrets,(path,port,ct)=>new McpLibrary.Runtime(path,port,cancellation:ct),new Dictionary<string,JsonNode?>()); await controller.ReconcileAsync(); Assert.Equal("running",controller.Status);
            output.WriteLine("Native QA isolation (Runtime + bridge assertions): profile="+profile.DataDirectory+" credentialPrefix="+profile.CredentialPrefix+" instanceSuffix="+profile.InstanceSuffix);
            var executable=Environment.GetEnvironmentVariable("VERBEMO_MCP_TEST_EXE") ?? throw new InvalidOperationException("Exact Debug WinExe path required.");
            var start=new ProcessStartInfo(executable) { UseShellExecute=false,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,CreateNoWindow=true,StandardInputEncoding=new UTF8Encoding(false),StandardOutputEncoding=new UTF8Encoding(false) };
            start.ArgumentList.Add("mcp"); start.ArgumentList.Add("--output-dir"); start.ArgumentList.Add(Path.Combine(root,"downloads")); start.Environment[ProductIdentity.TestDataEnvironmentVariable]=root;
            using var process=Process.Start(start)!; var errors=process.StandardError.ReadToEndAsync();
            async Task<JsonObject> Exchange(string request)
            { await process.StandardInput.WriteLineAsync(request); await process.StandardInput.FlushAsync(); var line=await process.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(30)); Assert.NotNull(line); return JsonNode.Parse(line)!.AsObject(); }
            var initialized=await Exchange("""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"native-pipe-test","version":"1"}}}""");
            Assert.NotNull(initialized["result"]); Assert.Equal(IntPtr.Zero,process.MainWindowHandle);
            var listed=await Exchange("""{"jsonrpc":"2.0","id":2,"method":"tools/list"}"""); Assert.Equal(8,listed["result"]!["tools"]!.AsArray().Count);
            var id=McpContract.MeetingId(library,"meeting");
            var downloaded=await Exchange(new JsonObject { ["jsonrpc"]="2.0",["id"]=3,["method"]="tools/call",["params"]=new JsonObject { ["name"]="get_meeting_audio",["arguments"]=new JsonObject { ["meeting_id"]=id } } }.ToJsonString());
            var local=downloaded["result"]!["structuredContent"]!["items"]![0]!["local_path"]!.GetValue<string>(); Assert.StartsWith(Path.Combine(root,"downloads"),local); Assert.Equal(bytes,File.ReadAllBytes(local));
            process.StandardInput.Close(); await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)); Assert.Equal(0,process.ExitCode); Assert.Empty(await errors);
            output.WriteLine("Actual WinExe pipe initialize/tools-list/audio/EOF: PASS; source bytes unchanged="+bytes.SequenceEqual(File.ReadAllBytes(Path.Combine(meeting,"mic.wav"))));
            await controller.DisposeAsync();
            using var absent=Process.Start(start)!; var absentErrors=absent.StandardError.ReadToEndAsync();
            await absent.StandardInput.WriteLineAsync("""{"jsonrpc":"2.0","id":4,"method":"tools/list"}"""); await absent.StandardInput.FlushAsync();
            var failure=JsonNode.Parse((await absent.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)))!)!; Assert.NotNull(failure["error"]); Assert.Equal(IntPtr.Zero,absent.MainWindowHandle);
            absent.StandardInput.Close(); await absent.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)); Assert.Empty(await absentErrors); output.WriteLine("Absent-app native bridge safe failure/no GUI: PASS");
        }
        finally
        {
            if(controller is not null) await controller.DisposeAsync();
            secrets?.Set(McpController.TokenName,null); Environment.SetEnvironmentVariable(ProductIdentity.TestDataEnvironmentVariable,old); Directory.Delete(root,true);
        }
    }
}
#endif

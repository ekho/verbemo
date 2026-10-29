using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.Win32.SafeHandles;
using Verbemo.Core.Configuration;
using Verbemo.Core.MCP;

namespace Verbemo.App.MCP;

internal sealed class McpController(AppSettingsStore store, SecretStore secrets,
    Func<string, int, CancellationToken, McpLibrary.Runtime> snapshot,
    IReadOnlyDictionary<string, JsonNode?> applied) : IAsyncDisposable
{
    internal const string TokenName = "mcp.token";
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly McpLimits limits = new();
    private readonly object stateLock = new();
    private McpServer? server;
    private long revision;
    private volatile bool exiting;
    private int shutdownStarted;
    public string Status { get; private set; } = "disabled";
    public string? ActiveEndpoint { get; private set; }
    public event EventHandler? Changed;
    public static string NewToken() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
    internal static bool ValidToken(string? value) => value is { Length: 64 } && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    public string? ReadToken() => secrets.GetStrict(TokenName);
    public void EnsureToken()
    {
        var current = ReadToken();
        if (current is null) secrets.Set(TokenName, NewToken());
        else if (!ValidToken(current)) throw new McpFailure("credentials_unavailable");
    }
    public async Task RotateAsync()
    {
        Revoke();
        try { secrets.Set(TokenName, NewToken()); }
        catch { SetStatus("credentials_unavailable"); throw new McpFailure("credentials_unavailable"); }
        await ReconcileAsync().ConfigureAwait(false);
    }
    public void Revoke()
    {
        lock (stateLock)
        {
            Interlocked.Increment(ref revision);
            server?.StopAdmission();
            ActiveEndpoint = null;
            if (Status is "running" or "starting") SetStatus("reconfiguring");
        }
    }
    private void SetStatusFor(long expected, string status)
    {
        lock (stateLock) if (!exiting && expected == revision) SetStatus(status);
    }
    private void SetStatus(string status) { Status = status; ActiveEndpoint = status == "running" ? ActiveEndpoint : null; Changed?.Invoke(this, EventArgs.Empty); }
    internal static SettingsLoad ReadConfiguration(AppSettingsStore store)
    {
        var load = store.Load();
        if (load.IsUnreadable || load.Raw is null) throw new McpFailure("configuration_unreadable");
        return load;
    }
    public async Task ReconcileAsync()
    {
        long expected;
        lock (stateLock) { Revoke(); expected = revision; }
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            McpServer? previous;
            lock (stateLock)
            {
                if (exiting || expected != revision) return;
                previous = server; server = null;
            }
            if (previous is not null) await previous.DisposeAsync().ConfigureAwait(false);
            if (exiting || expected != Volatile.Read(ref revision)) return;
            var load = ReadConfiguration(store); var config = load.Settings;
            if (!config.Mcp.Enabled) { SetStatusFor(expected,"disabled"); return; }
            var token = ReadToken();
            if (!ValidToken(token)) { SetStatusFor(expected,token is null ? "token_missing" : "credentials_unavailable"); return; }
            var fingerprint = McpContract.Hash(McpContract.Encode(load.Raw!));
            bool Current()
            {
                if (exiting || expected != Volatile.Read(ref revision)) return false;
                try
                {
                    var fresh = ReadConfiguration(store);
                    if (McpContract.Hash(McpContract.Encode(fresh.Raw!)) == fingerprint && McpServer.SameToken(token!, ReadToken())) return !exiting && expected == Volatile.Read(ref revision);
                }
                catch { }
                lock (stateLock)
                {
                    // A stale read must never revoke the generation that replaced it.
                    if (!exiting && expected == revision) { Revoke(); SetStatus("configuration_changed"); }
                }
                return false;
            }
            McpSettings Settings()
            {
                var values = SettingsDocument.ToNode(config);
                var effective = SettingsSchema.Entries.ToDictionary(e => e.Path, e => SettingsDocument.Get(values,e.Path));
                var configured = new Dictionary<string,bool> { ["mcp.token"] = true };
                foreach (var (key, name) in new[] { ("transcription.openai.api_key", SecretNames.OpenAi), ("transcription.assemblyai.api_key", SecretNames.AssemblyAi), ("transcription.elevenlabs.api_key", SecretNames.ElevenLabs), ("summary.api_key",SecretNames.Anthropic), ("summary.openai_api_key",SecretNames.OpenAi), ("summary.openai_compatible_api_key",SecretNames.OpenAiCompatible) })
                    configured[key] = !string.IsNullOrEmpty(secrets.GetStrict(name));
                return new(load.Raw!,effective,applied,configured,store.HomeDirectory);
            }
            var next = new McpServer(config.Mcp.Port, token!, Current,
                (name,args,ct) => Task.Run(() => McpQueries.Call(name,args,snapshot(config.RecordingsDirectory,config.Mcp.Port,ct),name == "get_settings" ? Settings() : null), CancellationToken.None),
                (meeting,audio,ct) => Task.Run(() => McpLibrary.OpenAudio(meeting,audio,snapshot(config.RecordingsDirectory,config.Mcp.Port,ct)), CancellationToken.None), limits);
            lock (stateLock)
            {
                if (exiting || expected != revision) { next.StopAdmission(); return; }
                server = next; SetStatus("starting");
            }
            await next.StartAsync().ConfigureAwait(false);
            var ready = Current();
            lock (stateLock)
            {
                if (ready && !exiting && expected == revision)
                { ActiveEndpoint = $"http://127.0.0.1:{config.Mcp.Port}/mcp"; SetStatus("running"); return; }
            }
            await next.DisposeAsync().ConfigureAwait(false);
            lock (stateLock) if (ReferenceEquals(server,next)) server = null;
        }
        catch (McpFailure error) { SetStatusFor(expected,error.Code); }
        catch
        {
            SetStatusFor(expected,"unavailable");
            McpServer? failed;
            lock (stateLock) { failed = server; server = null; }
            if (failed is not null) await failed.DisposeAsync().ConfigureAwait(false);
        }
        finally { gate.Release(); }
    }
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref shutdownStarted, 1) != 0) return;
        McpServer? active;
        lock (stateLock) { exiting = true; Revoke(); SetStatus("stopping"); active = server; }
        if (active is not null) await active.DisposeAsync().ConfigureAwait(false);
        lock (stateLock) SetStatus("stopped");
    }
}

/// <summary>Both early bridge and GUI use the same DEBUG-only isolated profile identity.</summary>
internal sealed record McpProfile(string DataDirectory, string HomeDirectory, string CredentialPrefix, string InstanceSuffix)
{
    public AppSettingsStore Store => new(Path.Combine(DataDirectory,"config.json"), HomeDirectory);
    public static McpProfile Current()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
#if DEBUG
        if (Environment.GetEnvironmentVariable(ProductIdentity.TestDataEnvironmentVariable) is { Length: >0 } configured)
        {
            var path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(configured));
            // Resolve case, short names and directory aliases without creating a profile in bridge mode.
            using var handle = CreateFileW(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero);
            if (handle.IsInvalid) throw new McpFailure("test_profile_unavailable");
            var name = new StringBuilder(32768); var length = GetFinalPathNameByHandleW(handle,name,(uint)name.Capacity,0);
            if (length == 0 || length >= name.Capacity) throw new McpFailure("test_profile_unavailable");
            path = name.ToString(); if (path.StartsWith(@"\\?\",StringComparison.Ordinal)) path = path[4..];
            var id = McpContract.Hash(Path.TrimEndingDirectorySeparator(path).ToUpperInvariant());
            return new(path,path,"Verbemo.Test/"+id+"/",".Test."+id);
        }
#endif
        return new(ProductIdentity.DataDirectory(local),home,ProductIdentity.CredentialPrefix,"");
    }
#if DEBUG
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    private static extern SafeFileHandle CreateFileW(string name,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,StringBuilder path,uint capacity,uint flags);
#endif
}

using System.Text;
using Verbemo.App;
using Xunit;

namespace Verbemo.Live.Tests;

public sealed class CommandLineToolsTests
{
    [Fact]
    public async Task Meeting_CLI_disables_Hindsight_hooks_and_preserves_inherited_environment()
    {
        var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell", "v1.0", "powershell.exe");
        const string script = "[Console]::Write($env:HINDSIGHT_DISABLE_HOOKS + ':' + $env:PATH)";
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var output = await CommandLineTools.RunAsync(powershell,
            ["-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script))],
            "", Path.GetTempPath(), timeout.Token);

        Assert.Equal("1:" + Environment.GetEnvironmentVariable("PATH"), output);
    }
}

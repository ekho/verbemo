# Verbemo for Windows

Windows and macOS share this source tree, root `VERSION`, source commit and
common release. See [source provenance](../docs/windows-source-import.md) and
[release runbook](../docs/releasing.md). [Downloads](https://github.com/ekho/verbemo/releases)
point to Verbemo's own Releases until a complete own release is verified.
There is no current claim of a signed public Verbemo installer or catalog entry.

## Build and test on Windows

Install Git, .NET 10 SDK, CMake, Visual Studio C++ Build Tools with Desktop
Development with C++, and a Windows 11 SDK. Native packaging needs the MSVC
compiler; a managed build alone cannot validate local transcription.
From the repository root in developer PowerShell:

```powershell
dotnet restore windows/Verbemo.Windows.slnx
dotnet build windows/Verbemo.Windows.slnx -c Release --no-restore
dotnet test windows/tests/Verbemo.Core.Tests/Verbemo.Core.Tests.csproj -c Release --no-restore
dotnet test windows/tests/Verbemo.Live.Tests/Verbemo.Live.Tests.csproj -c Release --no-restore
dotnet run --project windows/src/Verbemo.App/Verbemo.App.csproj -c Release
```

To build complete unsigned development packages from a clean committed checkout:

```powershell
$version = (Get-Content VERSION -Raw).Trim()
$commit = (git rev-parse HEAD).Trim()
& windows/scripts/Build-Release.ps1 -Version $version -SourceCommit $commit -OutputDirectory "$env:TEMP/verbemo-development-$commit" -Development
```

The output directory must be new. The script restores/tests managed code,
builds native final/live runtimes, publishes the app and packages Setup, Portable
and stable-channel update files. It verifies unsigned metadata with
`publishable: false`; those files cannot pass the signed common release gate.
A native CPU smoke test or successful packaging does not establish audio,
model quality, graphical flow, install/uninstall or two-version update acceptance.
Use a connected Windows host and record exactly what ran there. Follow the
[acceptance checklist](BETA.md) and [live-transcript procedure](LIVE_TRANSCRIPTION.md).

## Running and troubleshooting

Windows requires Windows 11 24H2 or later on x64. Download the selected final
transcription model and the separate live model in Settings. Local summaries
need a running local Ollama server. Cloud processing and subscription CLIs send
meeting input to the selected provider; a desktop login may not sign in its CLI.
Windows has no calendar integration. Its public `mcp` command is a local client
bridge for the running app; it does not start recording or processing.

Settings, models and logs live under `%LOCALAPPDATA%\Verbemo Data`.
API keys are stored in Windows Credential Manager under the `Verbemo/` prefix;
recordings default to `%USERPROFILE%\Verbemo Recordings`. Verbemo does not
modify Amanu's files or migrate them automatically. Choose an existing recordings
directory explicitly if needed. See [Support](../SUPPORT.md) and [Privacy](../PRIVACY.md).
App usage reporting is disabled and cannot be enabled by an old config field.

Closing a window leaves the app in the tray; Quit stops it normally. Installed
copies download stable updates while idle and install pending packages at the
next normal **primary** startup, before runtime/recording begins. Checking or
downloading does not apply, exit or restart. A second launch cannot autoapply
against a live primary instance. Portable copies do not self-update.

## Signing and packaging

Public artifacts are `Verbemo-<VERSION>-windows-x64-Setup.exe` and
`Verbemo-<VERSION>-windows-x64-Portable.zip`, in the same release/tag as macOS.
Signed builds require your own PFX and password and a verified timestamp; the
[common workflow](../.github/workflows/release.yml) scopes credentials to the
signing step and cleans temporary key files. Local signed invocation uses the
actual `-CertificatePath` and `-CertificatePassword` parameters of
`Build-Release.ps1`; do not expose secrets in shell history, process arguments or logs.
Use the workflow for release signing rather than putting a password in a command.

[Package metadata preparation](packaging/README.md) consumes verified real
artifacts. Historical manifests are retained in [docs/history](../docs/history/amanu-packaging/README.md),
with their publisher and hashes unchanged. No Verbemo Scoop or WinGet installation
command is advertised before actual catalog publication and install validation.

## Local MCP

Open Settings → MCP. MCP is off by default; when off, only its toggle is shown.
When enabled, the Server, Connection and Access sections expand inline. Server
shows the selected address separately from the actual listening state. Connection
provides localized URL, PowerShell command and agent-setup prompt blocks for
Codex, Claude Desktop, Claude Code, OpenCode v2 and a local OpenChamber backend.
Each block has its own Copy action. There is no cloud web-chat connector.

The server listens only on `127.0.0.1`, by default port `52763`; `mcp.port` may be
an integer from `1024` to `65535`. `mcp.enabled` defaults to `false`. Explicit
local enable or token rotation creates a protected token in Windows Credential
Manager. A synced enabled config without a local token stays closed. Access
always displays `***`; Copy, Ctrl+C and context-menu Copy resolve the full current
token only on the user's action. Native clients use the bridge without copying a
token:

```powershell
& 'C:\path\to\Verbemo.exe' mcp
# Optional client-owned private output directory:
& 'C:\path\to\Verbemo.exe' mcp --output-dir 'C:\private\meeting-audio'
```

The bridge uses redirected stdin/stdout, never launches the GUI, and returns
complete original audio files through `local_path`. Its default output directory
is private and temporary, one per bridge process. Finished files remain for the
client to use; remove them when finished. The eight tools only read saved data.
Closing the window keeps MCP active. Quit cancels requests immediately; token,
root and config changes revoke existing transfers. Unreadable config closes MCP
without rewriting the saved enabled setting. See [MCP details](../docs/mcp.md).

For isolated DEBUG native tests, create a synthetic profile directory before
setting `VERBEMO_TEST_DATA`. Both GUI and early bridge derive a separate credential
prefix and instance suffix from its canonical Windows path, and keep default
recordings under that profile. Release builds ignore this override. Automated
native-process tests require the exact Debug executable in
`VERBEMO_MCP_TEST_EXE`; never point native QA at a production credential slot.

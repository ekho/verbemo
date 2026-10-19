param(
    [Parameter(Mandatory = $false)]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [string]$CertificatePath,

    [Parameter(Mandatory = $false)]
    [string]$CertificatePassword
)

$ErrorActionPreference = "Stop"
$windowsRoot = Split-Path -Parent $PSScriptRoot
$sourceVersion = (Get-Content -LiteralPath (Join-Path $windowsRoot "..\VERSION") -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $sourceVersion }
if ($Version -ne $sourceVersion) { throw "Package version must match VERSION ($sourceVersion)." }
$publishDirectory = Join-Path $windowsRoot "artifacts\publish"
$releaseDirectory = Join-Path $windowsRoot "artifacts\release"
$toolDirectory = Join-Path $windowsRoot ".tools"

& (Join-Path $windowsRoot 'tests/Test-ReleaseInstallerName.ps1')

dotnet restore (Join-Path $windowsRoot "Verbemo.Windows.slnx")
if ($LASTEXITCODE -ne 0) { throw "Could not restore the Windows solution." }
dotnet test (Join-Path $windowsRoot "tests\Verbemo.Core.Tests\Verbemo.Core.Tests.csproj") --configuration Release --no-restore
if ($LASTEXITCODE -ne 0) { throw "Core tests failed." }
dotnet test (Join-Path $windowsRoot "tests\Verbemo.Live.Tests\Verbemo.Live.Tests.csproj") --configuration Release --no-restore
if ($LASTEXITCODE -ne 0) { throw "Windows live tests failed." }
dotnet publish (Join-Path $windowsRoot "src\Verbemo.App\Verbemo.App.csproj") `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    --property:Version=$Version `
    --output $publishDirectory
if ($LASTEXITCODE -ne 0) { throw "Could not publish the Windows app." }
& (Join-Path $PSScriptRoot "Build-LocalRuntime.ps1") -PublishDirectory $publishDirectory
& (Join-Path $PSScriptRoot "Build-LiveRuntime.ps1") -PublishDirectory $publishDirectory

if (-not (Test-Path (Join-Path $toolDirectory "vpk.exe"))) {
    dotnet tool install --tool-path $toolDirectory vpk --version 1.2.0
}

$arguments = @(
    "pack",
    "--packId", "Verbemo",
    "--packVersion", $Version,
    "--packDir", $publishDirectory,
    "--mainExe", "Verbemo.exe",
    "--packTitle", "Verbemo",
    "--packAuthors", "Verbemo",
    "--icon", (Join-Path $windowsRoot "src\Verbemo.App\Assets\Verbemo.ico"),
    "--channel", "stable",
    "--runtime", "win-x64",
    "--releaseNotes", (Join-Path $windowsRoot "RELEASE_NOTES.md"),
    "--outputDir", $releaseDirectory
)

if ($CertificatePath) {
    $fullCertificatePath = (Resolve-Path $CertificatePath).Path
    $arguments += @(
        "--signParams",
        "/td sha256 /fd sha256 /f `"$fullCertificatePath`" /p `"$CertificatePassword`" /tr http://timestamp.digicert.com"
    )
}

& (Join-Path $toolDirectory "vpk.exe") @arguments
if ($LASTEXITCODE -ne 0) { throw "Could not package the Windows installer." }
$installerPath = & (Join-Path $PSScriptRoot 'Set-ReleaseInstallerName.ps1') `
    -ReleaseDirectory $releaseDirectory -Version $Version
Write-Host "Verbemo installer: $installerPath"
Write-Host "Verbemo release artifacts: $releaseDirectory"

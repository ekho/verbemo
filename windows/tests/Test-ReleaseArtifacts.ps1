param([string] $ScriptsDirectory = (Join-Path $PSScriptRoot '../scripts'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert-Rejected([scriptblock] $Action, [string] $Expected) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    if ($message -notlike "*$Expected*") { throw "Expected '$Expected', got '$message'." }
}
$version = (Get-Content (Join-Path $PSScriptRoot '../../VERSION') -Raw).Trim()
$build = Join-Path $ScriptsDirectory 'Build-Release.ps1'
$out = Join-Path ([IO.Path]::GetTempPath()) "verbemo-preflight-$([Guid]::NewGuid())"
# These fail before invoking dotnet, vpk, native builds or opening the output directory.
Assert-Rejected { & $build -Version '999.0.0' -SourceCommit ('a' * 40) -OutputDirectory $out } 'must match VERSION'
Assert-Rejected { & $build -Version $version -SourceCommit ('a' * 40) -OutputDirectory $out } 'own certificate'
if (Test-Path $out) { throw 'Rejected release preflight created output.' }
[void][IO.Directory]::CreateDirectory($out)
try {
    [IO.File]::WriteAllText((Join-Path $out 'keep.txt'), 'existing release')
    Assert-Rejected { & $build -Version $version -SourceCommit ('a' * 40) -OutputDirectory $out -Development } 'must be new'
    if ([IO.File]::ReadAllText((Join-Path $out 'keep.txt')) -ne 'existing release') { throw 'Existing output was changed.' }
} finally { Remove-Item -LiteralPath $out -Recurse -Force }
Write-Host '3 release preflight tests passed.'

# Synthetic archives exercise the verifier's coverage and fail-closed policy only.
# They do not establish an actual signed release or certificate trust.
$fixture = Join-Path ([IO.Path]::GetTempPath()) "verbemo-artifacts-$([Guid]::NewGuid())"
$global:VerbemoSignatureCalls = [Collections.Generic.List[string]]::new()
$global:VerbemoTestSigner = 'A' * 40
$global:VerbemoTestTimestamp = $true
$global:VerbemoToolExit = 0
function Get-AuthenticodeSignature([string] $LiteralPath) {
    $global:VerbemoSignatureCalls.Add($LiteralPath)
    return [PSCustomObject]@{ Status = 'Valid'; SignerCertificate = [PSCustomObject]@{ Thumbprint = $global:VerbemoTestSigner };
        TimeStamperCertificate = $(if ($global:VerbemoTestTimestamp) { [PSCustomObject]@{ Subject = 'fixture' } } else { $null }) }
}
try {
    $publish = Join-Path $fixture 'publish'
    $release = Join-Path $fixture 'release'
    [void][IO.Directory]::CreateDirectory($release)
    $files = @('Verbemo.exe', 'Verbemo.dll', 'Verbemo.Core.dll', 'local-runtime/transcribe-cli.exe',
        'local-runtime/ggml.dll', 'live-runtime/transcribe.dll', 'Licenses/Verbemo-LICENSE.txt', 'Licenses/Markdig.txt',
        'local-runtime/licenses/transcribe.cpp-LICENSE', 'local-runtime/licenses/ggml-LICENSE',
        'live-runtime/licenses/transcribe.cpp-LICENSE', 'live-runtime/licenses/ggml-LICENSE')
    foreach ($name in $files) {
        $path = Join-Path $publish $name
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        [IO.File]::WriteAllText($path, "fixture bytes $name")
    }
    $portable = Join-Path $fixture 'portable'
    [void][IO.Directory]::CreateDirectory($portable)
    Copy-Item -LiteralPath $publish -Destination (Join-Path $portable 'current') -Recurse
    foreach ($name in @('Verbemo.exe', 'Update.exe')) { [IO.File]::WriteAllText((Join-Path $portable $name), 'fixture') }
    $package = Join-Path $fixture 'package'
    [void][IO.Directory]::CreateDirectory((Join-Path $package 'lib'))
    Copy-Item -LiteralPath $publish -Destination (Join-Path $package 'lib/net45') -Recurse
    foreach ($name in @('Squirrel.exe', 'Verbemo_ExecutionStub.exe')) { [IO.File]::WriteAllText((Join-Path $package "lib/net45/$name"), 'fixture') }
    [IO.Compression.ZipFile]::CreateFromDirectory($portable, (Join-Path $release "Verbemo-$version-windows-x64-Portable.zip"))
    [IO.Compression.ZipFile]::CreateFromDirectory($package, (Join-Path $release "Verbemo-$version-stable-full.nupkg"))
    [IO.File]::WriteAllText((Join-Path $release "Verbemo-$version-windows-x64-Setup.exe"), 'fixture')
    $tool = Join-Path $fixture 'verify.ps1'
    [IO.File]::WriteAllText($tool, '$global:LASTEXITCODE = $global:VerbemoToolExit')
    $verify = Join-Path $ScriptsDirectory 'Test-ReleaseSignatures.ps1'
    $parameters = @{ PublishDirectory = $publish; ReleaseDirectory = $release; Version = $version; ExpectedThumbprint = ('A' * 40); SignatureTool = $tool }
    $result = & $verify @parameters
    if ($result.authenticode -ne 'verified' -or $global:VerbemoSignatureCalls.Count -ne 23) { throw "Incorrect signature coverage: $($global:VerbemoSignatureCalls.Count)" }
    foreach ($name in @('Squirrel.exe', 'Verbemo_ExecutionStub.exe', 'Update.exe')) {
        if (@($global:VerbemoSignatureCalls | Where-Object { [IO.Path]::GetFileName($_) -eq $name }).Count -ne 1) { throw "Missing archive verification: $name" }
    }
    $global:VerbemoTestSigner = 'B' * 40
    Assert-Rejected { & $verify @parameters } 'unexpected certificate'
    $global:VerbemoTestSigner = 'A' * 40
    $global:VerbemoTestTimestamp = $false
    Assert-Rejected { & $verify @parameters } 'timestamp'
    $global:VerbemoTestTimestamp = $true
    $global:VerbemoToolExit = 2
    Assert-Rejected { & $verify @parameters } 'chain/timestamp'
    $global:VerbemoToolExit = 0
    # Corrupting a license in a final archive must fail even for unsigned local builds.
    [IO.File]::WriteAllText((Join-Path $portable 'current/Licenses/Markdig.txt'), 'changed')
    Remove-Item (Join-Path $release "Verbemo-$version-windows-x64-Portable.zip")
    [IO.Compression.ZipFile]::CreateFromDirectory($portable, (Join-Path $release "Verbemo-$version-windows-x64-Portable.zip"))
    Assert-Rejected { & $verify -PublishDirectory $publish -ReleaseDirectory $release -Version $version -Development } 'License bytes changed'
    Write-Host '5 synthetic archive/signature policy tests passed.'
} finally {
    if (Test-Path $fixture) { Remove-Item $fixture -Recurse -Force }
    Remove-Item Function:Get-AuthenticodeSignature
    Remove-Variable VerbemoSignatureCalls, VerbemoTestSigner, VerbemoTestTimestamp, VerbemoToolExit -Scope Global
}

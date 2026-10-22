param(
    [Parameter(Mandatory = $true)] [string] $PublishDirectory,
    [Parameter(Mandatory = $true)] [string] $ReleaseDirectory,
    [string] $Version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../VERSION') -Raw).Trim(),
    [string] $ExpectedThumbprint,
    [string] $SignatureTool,
    [switch] $Development
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $Development -and ($ExpectedThumbprint -notmatch '^[A-Fa-f0-9]{40}$' -or -not (Test-Path -LiteralPath $SignatureTool -PathType Leaf))) {
    throw 'Release verification requires the selected own certificate thumbprint and signtool.'
}
function Assert-OwnSignature([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required signed payload is missing: $Path" }
    if ($Development) { return }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ne $ExpectedThumbprint) { throw "Invalid or unexpected certificate for $Path" }
    if ($null -eq $signature.TimeStamperCertificate) { throw "Missing Authenticode timestamp for $Path" }
    & $SignatureTool verify /pa /all /v /tw $Path | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Authenticode chain/timestamp verification failed for $Path" }
}
function Assert-Payload([string] $Directory) {
    foreach ($relative in @('Verbemo.exe', 'Verbemo.dll', 'Verbemo.Core.dll', 'local-runtime/transcribe-cli.exe')) {
        Assert-OwnSignature (Join-Path $Directory $relative)
    }
    # Built native payload belongs to this package. Framework/vendor dependencies outside these
    # directories retain their vendor identities; they are never treated as first-party signatures.
    foreach ($runtime in @('local-runtime', 'live-runtime')) {
        $libraries = @(Get-ChildItem -LiteralPath (Join-Path $Directory $runtime) -Filter '*.dll' -File)
        if ($libraries.Count -eq 0) { throw "Missing native libraries in $runtime" }
        foreach ($library in $libraries) { Assert-OwnSignature $library.FullName }
    }
    foreach ($license in @('Licenses/Verbemo-LICENSE.txt', 'Licenses/Markdig.txt', 'Licenses/HtmlAgilityPack.txt',
        'local-runtime/licenses/transcribe.cpp-LICENSE', 'local-runtime/licenses/ggml-LICENSE',
        'live-runtime/licenses/transcribe.cpp-LICENSE', 'live-runtime/licenses/ggml-LICENSE')) {
        $path = Join-Path $Directory $license
        $original = Join-Path $PublishDirectory $license
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) { throw "License is missing: $license" }
        if ((Get-FileHash -LiteralPath $path).Hash -ne (Get-FileHash -LiteralPath $original).Hash) { throw "License bytes changed: $license" }
    }
}
Assert-Payload $PublishDirectory
Assert-OwnSignature (Join-Path $ReleaseDirectory "Verbemo-$Version-windows-x64-Setup.exe")
$archives = @("Verbemo-$Version-stable-full.nupkg", "Verbemo-$Version-windows-x64-Portable.zip")
foreach ($name in $archives) {
    $extractPath = Join-Path ([IO.Path]::GetTempPath()) "verbemo-signature-$([Guid]::NewGuid())"
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $ReleaseDirectory $name), $extractPath)
        if ($name.EndsWith('.nupkg')) {
            $payload = Join-Path $extractPath 'lib/app'
            Assert-Payload $payload
            Assert-OwnSignature (Join-Path $payload 'Squirrel.exe')
            Assert-OwnSignature (Join-Path $payload 'Verbemo_ExecutionStub.exe')
        } else {
            Assert-Payload (Join-Path $extractPath 'current')
            Assert-OwnSignature (Join-Path $extractPath 'Verbemo.exe')
            Assert-OwnSignature (Join-Path $extractPath 'Update.exe')
        }
    } finally {
        if (Test-Path -LiteralPath $extractPath) { Remove-Item -LiteralPath $extractPath -Recurse -Force }
    }
}
if ($Development) {
    Write-Output @{ authenticode = 'unsigned-development'; timestamp = 'unverified'; certificate_thumbprint = $null }
} else {
    Write-Output @{ authenticode = 'verified'; timestamp = 'verified'; certificate_thumbprint = $ExpectedThumbprint.ToUpperInvariant() }
}

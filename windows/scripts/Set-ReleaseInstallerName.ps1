param(
    [Parameter(Mandatory = $true)] [string] $ReleaseDirectory,
    [Parameter(Mandatory = $true)] [string] $Version
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw "Invalid release version: $Version" }
$metadataPath = Join-Path $ReleaseDirectory 'assets.stable.json'
$assets = @(Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json)
$renames = @()
foreach ($kind in @('Installer', 'Portable')) {
    $entry = @($assets | Where-Object Type -eq $kind)
    if ($entry.Count -ne 1) { throw "Expected exactly one $kind in assets.stable.json." }
    $suffix = if ($kind -eq 'Installer') { 'Setup.exe' } else { 'Portable.zip' }
    $name = "Verbemo-$Version-windows-x64-$suffix"
    $old = $entry[0].RelativeFileName
    if ($old -notin @("Verbemo-stable-$suffix", $name)) { throw "Unexpected $kind filename: $old" }
    if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDirectory $old) -PathType Leaf)) { throw "$kind is missing: $old" }
    if ($old -ne $name -and (Test-Path -LiteralPath (Join-Path $ReleaseDirectory $name))) { throw "Versioned $kind already exists: $name" }
    $renames += @{ Entry = $entry[0]; Old = $old; New = $name }
}
$full = @($assets | Where-Object Type -eq 'Full')
if ($assets.Count -ne 3 -or $full.Count -ne 1 -or $full[0].RelativeFileName -ne "Verbemo-$Version-stable-full.nupkg") {
    throw 'Expected only the current full update package, installer and portable.'
}
if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDirectory $full[0].RelativeFileName) -PathType Leaf)) { throw 'Referenced full package is missing.' }
# Validate every collision and input before changing any name. Rename preserves signed bytes.
foreach ($rename in $renames) {
    if ($rename.Old -ne $rename.New) { Rename-Item -LiteralPath (Join-Path $ReleaseDirectory $rename.Old) -NewName $rename.New }
    $rename.Entry.RelativeFileName = $rename.New
}
[IO.File]::WriteAllText($metadataPath, ($assets | ConvertTo-Json -Depth 10 -AsArray), [Text.UTF8Encoding]::new($false))
# The common publisher writes the single SHA256SUMS after combining both platforms.
Write-Output (Join-Path $ReleaseDirectory "Verbemo-$Version-windows-x64-Setup.exe")

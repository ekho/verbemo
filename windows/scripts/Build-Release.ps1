param(
    [Parameter(Mandatory = $true)] [string] $Version,
    [Parameter(Mandatory = $true)] [string] $SourceCommit,
    [Parameter(Mandatory = $true)] [string] $OutputDirectory,
    [string] $CertificatePath,
    [string] $CertificatePassword,
    [switch] $Development
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$windowsRoot = Split-Path -Parent $PSScriptRoot
$root = [IO.Path]::GetFullPath((Join-Path $windowsRoot '..'))
$sourceVersion = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
if ($Version -ne $sourceVersion) { throw "Package version must match VERSION ($sourceVersion)." }
if ($Version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw 'Invalid release VERSION.' }
if (-not $Development -and -not $CertificatePath) { throw 'Release mode requires your own certificate PFX; use -Development for unsigned local validation.' }
if ($Development -and ($CertificatePath -or $CertificatePassword)) { throw 'Development builds do not accept release credentials.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'OutputDirectory must be new; previous release files must not be mixed.' }
function Read-Git([string[]] $Arguments) {
    $result = & git -C $root @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot verify release source repository.' }
    return ($result -join "`n").Trim()
}
if ((Read-Git -Arguments @('remote', 'get-url', 'origin')) -notin @('git@github.com:ekho/verbemo.git', 'https://github.com/ekho/verbemo.git', 'https://github.com/ekho/verbemo', 'ssh://git@github.com/ekho/verbemo.git')) { throw 'origin must be ekho/verbemo.' }
if ((Read-Git -Arguments @('rev-parse', '--is-shallow-repository')) -ne 'false') { throw 'Full source history is required for the common build number.' }
if ($SourceCommit -notmatch '^[0-9a-f]{40}$' -or (Read-Git -Arguments @('rev-parse', 'HEAD')) -ne $SourceCommit) { throw 'SourceCommit must be the full current HEAD SHA.' }
if (Read-Git -Arguments @('status', '--porcelain', '--untracked-files=all')) { throw 'Release source working tree is dirty.' }
if ((Read-Git -Arguments @('show', "${SourceCommit}:VERSION")) -ne $Version) { throw 'Committed VERSION does not match.' }
$buildNumber = [int](Read-Git -Arguments @('rev-list', '--count', $SourceCommit))
$releaseDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$workDirectory = Join-Path ([IO.Path]::GetTempPath()) "verbemo-package-$([Guid]::NewGuid())"
$publishDirectory = Join-Path $workDirectory 'publish'
$toolDirectory = Join-Path $windowsRoot '.tools'
$certificate = $null
try {
    [void][IO.Directory]::CreateDirectory($workDirectory)
    # This temporary PFX contains a private key. Restrict it to this Windows account and
    # remove it in finally; no password enters a command line or VPK's diagnostic output.
    if (-not $Development) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $workDirectory -AclObject $acl
        try {
            $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
                (Resolve-Path -LiteralPath $CertificatePath).Path, $CertificatePassword,
                [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet -bor
                [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        } catch { throw 'Cannot load the selected own certificate PFX.' }
        if (-not $certificate.HasPrivateKey) { throw 'Selected own certificate has no private key.' }
        $temporaryPfx = Join-Path $workDirectory 'signing.pfx'
        [IO.File]::WriteAllBytes($temporaryPfx, $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, ''))
    }
    [void][IO.Directory]::CreateDirectory($releaseDirectory)
    & (Join-Path $windowsRoot 'tests/Test-ReleaseInstallerName.ps1')
    dotnet restore (Join-Path $windowsRoot 'Verbemo.Windows.slnx')
    if ($LASTEXITCODE -ne 0) { throw 'Could not restore the Windows solution.' }
    foreach ($project in @('Verbemo.Core.Tests', 'Verbemo.Live.Tests')) {
        dotnet test (Join-Path $windowsRoot "tests/$project/$project.csproj") --configuration Release --no-restore
        if ($LASTEXITCODE -ne 0) { throw "$project failed." }
    }
    dotnet publish (Join-Path $windowsRoot 'src/Verbemo.App/Verbemo.App.csproj') --configuration Release --runtime win-x64 --self-contained true --property:Version=$Version --output $publishDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Could not publish the Windows app.' }
    & (Join-Path $PSScriptRoot 'Build-LocalRuntime.ps1') -PublishDirectory $publishDirectory
    & (Join-Path $PSScriptRoot 'Build-LiveRuntime.ps1') -PublishDirectory $publishDirectory
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $publishDirectory 'Licenses/Verbemo-LICENSE.txt')
    if (-not (Test-Path (Join-Path $toolDirectory 'vpk.exe'))) {
        dotnet tool install --tool-path $toolDirectory vpk --version 1.2.0
        if ($LASTEXITCODE -ne 0) { throw 'Could not install the pinned Velopack tool.' }
    }
    $vpk = Join-Path $toolDirectory 'vpk.exe'
    $installedTools = (& dotnet tool list --tool-path $toolDirectory | Out-String)
    if ($LASTEXITCODE -ne 0 -or $installedTools -notmatch '(?m)^vpk\s+1\.2\.0\s+vpk\s*$') { throw 'Release packaging requires exactly Velopack 1.2.0.' }
    $arguments = @('--skip-updates', 'pack', '--packId', 'Verbemo', '--packVersion', $Version, '--packDir', $publishDirectory,
        '--mainExe', 'Verbemo.exe', '--packTitle', 'Verbemo', '--packAuthors', 'Verbemo',
        '--icon', (Join-Path $windowsRoot 'src/Verbemo.App/Assets/Verbemo.ico'), '--channel', 'stable',
        '--runtime', 'win-x64', '--delta', 'None', '--releaseNotes', (Join-Path $windowsRoot 'RELEASE_NOTES.md'), '--outputDir', $releaseDirectory)
    $signatureTool = $null
    if (-not $Development) {
        $signatureTools = @(Get-ChildItem -LiteralPath $toolDirectory -Recurse -Filter signtool.exe -File)
        if ($signatureTools.Count -ne 1) { throw 'Expected the pinned Velopack signtool.' }
        $signatureTool = $signatureTools[0].FullName
        # Sign our own payload even if it already carries a trusted, unrelated signature.
        $owned = @(Get-ChildItem -LiteralPath $publishDirectory -File | Where-Object { $_.Name -in @('Verbemo.exe', 'Verbemo.dll', 'Verbemo.Core.dll') })
        foreach ($runtime in @('local-runtime', 'live-runtime')) { $owned += @(Get-ChildItem -LiteralPath (Join-Path $publishDirectory $runtime) -File | Where-Object { $_.Extension -in @('.exe', '.dll', '.node') }) }
        foreach ($file in $owned) {
            & $signatureTool sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com /f $temporaryPfx $file.FullName | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not sign the first-party payload.' }
        }
        $arguments += @('--signParams', "/fd SHA256 /td SHA256 /tr http://timestamp.digicert.com /f `"$temporaryPfx`"")
    }
    & $vpk @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Could not package the Windows release.' }
    & (Join-Path $PSScriptRoot 'Set-ReleaseInstallerName.ps1') -ReleaseDirectory $releaseDirectory -Version $Version | Out-Null
    # Legacy migration feeds are unnecessary for this new package ID.
    $legacy = Join-Path $releaseDirectory 'RELEASES-stable'
    if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy }
    $verify = @{ PublishDirectory = $publishDirectory; ReleaseDirectory = $releaseDirectory; Version = $Version; Development = $Development }
    if (-not $Development) { $verify.ExpectedThumbprint = $certificate.Thumbprint; $verify.SignatureTool = $signatureTool }
    $signature = & (Join-Path $PSScriptRoot 'Test-ReleaseSignatures.ps1') @verify
    $names = @("Verbemo-$Version-windows-x64-Setup.exe", "Verbemo-$Version-windows-x64-Portable.zip", "Verbemo-$Version-stable-full.nupkg", 'assets.stable.json', 'releases.stable.json')
    $feed = Get-Content -LiteralPath (Join-Path $releaseDirectory 'releases.stable.json') -Raw | ConvertFrom-Json
    $packages = @($feed.Assets)
    if ($packages.Count -ne 1) { throw 'Feed must reference only the current full package.' }
    $package = $packages[0]
    $packageName = "Verbemo-$Version-stable-full.nupkg"
    $packagePath = Join-Path $releaseDirectory $packageName
    if ($package.PackageId -ne 'Verbemo' -or $package.Version -ne $Version -or $package.Type -ne 'Full' -or
        $package.FileName -ne $packageName -or $package.SHA256 -ne (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash -or
        $package.Size -ne (Get-Item -LiteralPath $packagePath).Length) { throw 'Feed package metadata/hash does not match the current full package.' }
    $files = @($names | ForEach-Object {
        $path = Join-Path $releaseDirectory $_
        @{ name = $_; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); size = (Get-Item -LiteralPath $path).Length }
    })
    $receipt = @{ platform = 'windows'; version = $Version; source_commit = $SourceCommit; build_number = $buildNumber;
        publishable = (-not $Development); signature = $signature; files = $files }
    [IO.File]::WriteAllText((Join-Path $releaseDirectory 'windows-build.json'), ($receipt | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    Write-Host "Verbemo Windows artifacts: $releaseDirectory (publishable=$(-not $Development))"
} finally {
    if ($null -ne $certificate) { $certificate.Dispose() }
    if (Test-Path -LiteralPath $workDirectory) { Remove-Item -LiteralPath $workDirectory -Recurse -Force }
}

param(
    [string] $ScriptPath = (Join-Path $PSScriptRoot '../scripts/Set-ReleaseInstallerName.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function New-ReleaseFixture {
    $directory = Join-Path ([IO.Path]::GetTempPath()) "verbemo release name $([Guid]::NewGuid())"
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $directory 'Verbemo-stable-Setup.exe'), [byte[]](0, 1, 2, 255))
    [IO.File]::WriteAllText((Join-Path $directory 'Verbemo-0.1.0-stable-full.nupkg'), 'update package')
    [IO.File]::WriteAllBytes((Join-Path $directory 'Verbemo-stable-Portable.zip'), [byte[]](3, 4, 5, 254))
    [IO.File]::WriteAllText((Join-Path $directory 'releases.stable.json'), '{"Assets":[]}' )
    $assets = @(
        @{ RelativeFileName = 'Verbemo-stable-Setup.exe'; Type = 'Installer' },
        @{ RelativeFileName = 'Verbemo-stable-Portable.zip'; Type = 'Portable' },
        @{ RelativeFileName = 'Verbemo-0.1.0-stable-full.nupkg'; Type = 'Full' }
    )
    [IO.File]::WriteAllText((Join-Path $directory 'assets.stable.json'), ($assets | ConvertTo-Json))
    return $directory
}

function Assert-Rejected([scriptblock] $Action, [string] $ExpectedMessage) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -like "*$ExpectedMessage*") "Expected rejection '$ExpectedMessage', got '$message'."
}

$tests = @(
    @{
        Name = 'Installer name, metadata and checksums agree without changing signed bytes or the update feed'
        Run = {
            param($directory)
            $result = & $ScriptPath -ReleaseDirectory $directory -Version '0.1.0'
            $expectedPath = Join-Path $directory 'Verbemo-0.1.0-windows-x64-Setup.exe'
            Assert-True ($result -eq $expectedPath) 'The returned installer path must include the package version.'
            Assert-True (Test-Path -LiteralPath $expectedPath) 'The versioned installer was not created.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $directory 'Verbemo-stable-Setup.exe'))) 'The unversioned installer remains.'
            Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($expectedPath)) -eq 'AAEC/w==') 'Installer bytes changed; an Authenticode signature would be invalidated.'
            $assets = @(Get-Content -LiteralPath (Join-Path $directory 'assets.stable.json') -Raw | ConvertFrom-Json)
            Assert-True (@($assets | Where-Object Type -eq 'Installer')[0].RelativeFileName -eq 'Verbemo-0.1.0-windows-x64-Setup.exe') 'Installer metadata still points at a stale filename.'
            Assert-True (@($assets | Where-Object Type -eq 'Full')[0].RelativeFileName -eq 'Verbemo-0.1.0-stable-full.nupkg') 'Update package metadata changed.'
            Assert-True ([IO.File]::ReadAllText((Join-Path $directory 'releases.stable.json')) -eq '{"Assets":[]}') 'The updater feed changed.'
            $portable = Join-Path $directory 'Verbemo-0.1.0-windows-x64-Portable.zip'
            Assert-True (Test-Path -LiteralPath $portable) 'Portable filename must include version and architecture.'
            Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($portable)) -eq 'AwQF/g==') 'Portable bytes changed.'
            Assert-True (@($assets | Where-Object Type -eq 'Portable')[0].RelativeFileName -eq 'Verbemo-0.1.0-windows-x64-Portable.zip') 'Portable inventory name is stale.'
            Assert-True (-not (Test-Path (Join-Path $directory 'SHA256SUMS'))) 'Platform finalization must not produce private checksums.'

        }
    },
    @{
        Name = 'An existing versioned installer is never overwritten'
        Run = {
            param($directory)
            $path = Join-Path $directory 'Verbemo-0.1.0-windows-x64-Setup.exe'
            [IO.File]::WriteAllText($path, 'existing installer')
            $metadata = [IO.File]::ReadAllText((Join-Path $directory 'assets.stable.json'))
            Assert-Rejected { & $ScriptPath -ReleaseDirectory $directory -Version '0.1.0' } 'already exists'
            Assert-True ([IO.File]::ReadAllText($path) -eq 'existing installer') 'Existing installer was overwritten.'
            Assert-True (Test-Path -LiteralPath (Join-Path $directory 'Verbemo-stable-Setup.exe')) 'Original installer was lost.'
            Assert-True ([IO.File]::ReadAllText((Join-Path $directory 'assets.stable.json')) -eq $metadata) 'Metadata changed after a rejected rename.'
        }
    },
    @{
        Name = 'Missing installer leaves metadata unchanged'
        Run = {
            param($directory)
            Remove-Item -LiteralPath (Join-Path $directory 'Verbemo-stable-Setup.exe')
            $metadata = [IO.File]::ReadAllText((Join-Path $directory 'assets.stable.json'))
            Assert-Rejected { & $ScriptPath -ReleaseDirectory $directory -Version '0.1.0' } 'missing'
            Assert-True ([IO.File]::ReadAllText((Join-Path $directory 'assets.stable.json')) -eq $metadata) 'Metadata changed without an installer.'
        }
    },
    @{
        Name = 'Portable collision leaves every original file and inventory unchanged'
        Run = {
            param($directory)
            [IO.File]::WriteAllText((Join-Path $directory 'Verbemo-0.1.0-windows-x64-Portable.zip'), 'existing')
            Assert-Rejected { & $ScriptPath -ReleaseDirectory $directory -Version '0.1.0' } 'already exists'
            Assert-True (Test-Path (Join-Path $directory 'Verbemo-stable-Setup.exe')) 'Partial rename after portable collision.'
        }
    },
    @{
        Name = 'Missing referenced package rejects before rename'
        Run = {
            param($directory)
            Remove-Item (Join-Path $directory 'Verbemo-0.1.0-stable-full.nupkg')
            Assert-Rejected { & $ScriptPath -ReleaseDirectory $directory -Version '0.1.0' } 'missing'
            Assert-True (Test-Path (Join-Path $directory 'Verbemo-stable-Setup.exe')) 'Partial rename without full package.'
        }
    },
    @{
        Name = 'Invalid version cannot rename files'
        Run = {
            param($directory)
            Assert-Rejected { & $ScriptPath -ReleaseDirectory $directory -Version '../0.1.0' } 'Invalid release version'
            Assert-True (Test-Path -LiteralPath (Join-Path $directory 'Verbemo-stable-Setup.exe')) 'Invalid version changed the installer.'
        }
    },
    @{
        Name = 'Repeated finalization preserves bytes and inventory'
        Run = {
            param($directory)
            & $ScriptPath -ReleaseDirectory $directory -Version '0.1.0' | Out-Null
            $metadata = [IO.File]::ReadAllText((Join-Path $directory 'assets.stable.json'))
            $result = & $ScriptPath -ReleaseDirectory $directory -Version '0.1.0'
            Assert-True ($result -eq (Join-Path $directory 'Verbemo-0.1.0-windows-x64-Setup.exe')) 'Repeated finalization changed the filename.'
            Assert-True ([IO.File]::ReadAllText((Join-Path $directory 'assets.stable.json')) -eq $metadata) 'Repeated finalization changed inventory.'
        }
    }
)

$failed = 0
foreach ($test in $tests) {
    $directory = New-ReleaseFixture
    try {
        & $test.Run $directory
        Write-Host "PASS: $($test.Name)"
    } catch {
        $failed++
        Write-Host "FAIL: $($test.Name): $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}
if ($failed -gt 0) { throw "$failed installer naming test(s) failed." }
Write-Host "$($tests.Count) installer naming tests passed."

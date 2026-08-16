#Requires -Version 5.1
<#
.SYNOPSIS
    Validates reuse of already-downloaded dependency installers from sibling
    installer directories (Find-DeltaReusableInstaller /
    Copy-DeltaReusableInstaller, lib\DeltaInstaller.Common.ps1) and its
    integration into the per-dependency download functions.

.DESCRIPTION
    Operators routinely keep several unpacked copies of this installer side
    by side, each with its own populated installers\ cache. When a required
    installer is missing from the current .\installers directory, the shared
    helper looks for the EXACT same filename in <sibling>\installers\ and
    copies it in rather than re-downloading it. The sibling's name is
    irrelevant by design.

    What these cases pin down:

      - the "already cached" branch of a Get-*Installer function is
        untouched: no sibling search, no copy, no download;
      - an exact filename match in an arbitrarily named sibling is copied in
        and used instead of downloading;
      - a DIFFERENT version in a sibling is never used, which is the whole
        reason the match is exact rather than a wildcard;
      - the search is one level deep on both sides and never treats the
        current installer directory as a sibling of itself;
      - a candidate that fails the caller's own integrity check is discarded,
        the search continues, and an all-candidates-rejected outcome falls
        back to the normal download rather than failing the installation.

    Runs entirely against a temporary sandbox and stubs - no network access,
    no real downloads, no Administrator rights - in the same style as
    tools\test-delta-service-definition.ps1 and
    tools\test-delta-uninstall-service-cleanup.ps1. The download functions
    under test are extracted from setup.ps1 by AST rather than dot-sourced,
    because dot-sourcing that file would run its whole orchestration block.
    Extracting them means these cases run the real shipped function bodies,
    not copies that could drift from them.

    Every sandbox path deliberately contains spaces.

    Exits 0 if every case passes, 1 otherwise.

.EXAMPLE
    .\tools\test-delta-installer-reuse.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Common.ps1')

$Script:Failures = 0
$Script:Passes   = 0

function Assert-True {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail
    )
    if ($Condition) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $Script:Passes++
    }
    else {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor Red }
        $Script:Failures++
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Expected,
        [AllowNull()]$Actual
    )
    Assert-True -Name $Name -Condition ("$Expected" -eq "$Actual") -Detail "Expected '$Expected' but got '$Actual'."
}

# ---------------------------------------------------------------------------
# The functions under test, taken from the shipped scripts themselves
# ---------------------------------------------------------------------------

function Import-FunctionFromScript {
    <#
      Returns a single named function's source text from another script file
      without executing anything else in it. The alternative - dot-sourcing
      setup.ps1 - would run its orchestration block.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FunctionName
    )

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw "$Path failed to parse: $(($errors | ForEach-Object { $_.Message }) -join '; ')"
    }

    $definition = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName },
        $true
    ) | Select-Object -First 1

    if (-not $definition) {
        throw "$FunctionName was not found in $Path."
    }

    return $definition.Extent.Text
}

$Script:SetupScriptPath = Join-Path -Path $Script:ProjectRoot -ChildPath 'setup.ps1'
. ([scriptblock]::Create((Import-FunctionFromScript -Path $Script:SetupScriptPath -FunctionName 'Get-NodeInstaller')))
. ([scriptblock]::Create((Import-FunctionFromScript -Path $Script:SetupScriptPath -FunctionName 'Get-PostGISInstaller')))
. ([scriptblock]::Create((Import-FunctionFromScript -Path $Script:SetupScriptPath -FunctionName 'Test-PostGISInstallerIntegrity')))

# ---------------------------------------------------------------------------
# Stubs
#
# Defined AFTER the dot-sources above so they shadow the real
# implementations. The console vocabulary is captured rather than printed:
# what the operator is told about a reuse is part of the behaviour under
# test, and silence keeps the pass/fail list readable.
# ---------------------------------------------------------------------------

$Script:ConsoleLines  = @()
$Script:DownloadCalls = @()

function Write-Step    { param([Parameter(Mandatory)][string]$Message) $Script:ConsoleLines += $Message }
function Write-Detail  { param([Parameter(Mandatory)][string]$Message) $Script:ConsoleLines += $Message }
function Write-Success { param([Parameter(Mandatory)][string]$Message) $Script:ConsoleLines += $Message }

function Stop-Setup {
    param([Parameter(Mandatory)][string]$Message)
    throw "STOP-SETUP: $Message"
}

# Configuration the extracted functions read. Filenames mirror the shipped
# pins closely enough to be realistic; nothing here changes a real pin.
$Script:InstallerConfig = @{
    NODE_INSTALLER    = 'node-v24.18.0-x64.msi'
    POSTGIS_INSTALLER = 'postgis-bundle-pg17x64-setup-3.6.2-1.exe'
}
$Script:RequiredNodeVersion   = '24.18.0'
$Script:NodeDownloadUrl       = 'https://example.invalid/node-v24.18.0-x64.msi'
$Script:RequiredPostGISVersion = '3.6.2'
$Script:PostGISDownloadUrl    = 'https://example.invalid/postgis-bundle-pg17x64-setup-3.6.2-1.exe'
$Script:PostGISChecksumUrl    = 'https://example.invalid/postgis-bundle-pg17x64-setup-3.6.2-1.exe.md5'

# Serves both roles the real cmdlet plays in the code under test: an
# -OutFile download (recorded, never performed over the network) and the
# PostGIS checksum fetch. $Script:ChecksumContent = $null makes the checksum
# file "unavailable", the case the real function treats as skip-not-fail.
$Script:ChecksumContent = $null

function Invoke-WebRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Uri,
        $OutFile,
        [switch]$UseBasicParsing,
        $TimeoutSec
    )

    if ($OutFile) {
        $Script:DownloadCalls += [pscustomobject]@{ Uri = "$Uri"; OutFile = "$OutFile" }
        Set-Content -LiteralPath $OutFile -Value 'downloaded-payload' -Encoding Ascii -NoNewline
        return
    }

    if ($null -eq $Script:ChecksumContent) {
        throw "404 (stub): $Uri"
    }

    return [pscustomobject]@{ Content = $Script:ChecksumContent }
}

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

# $env:TEMP is frequently an 8.3 short path (…\ADMINI~1\…), while the helper
# reports what the filesystem itself returns - the long form. Resolving the
# base once here keeps the two comparable, so a path assertion below is
# testing the helper rather than Windows' short-name aliasing.
$Script:SandboxRoot = Join-Path -Path (Get-Item -LiteralPath $env:TEMP).FullName -ChildPath "delta reuse tests $([guid]::NewGuid().ToString('N'))"

function New-TestSandbox {
    <#
      Builds a fresh "parent directory" holding one current installer
      directory (the equivalent of $PSScriptRoot) with its own installers\
      cache. Every name contains a space on purpose.
    #>
    param([switch]$WithoutCacheDirectory)

    $root        = Join-Path -Path $Script:SandboxRoot -ChildPath ([guid]::NewGuid().ToString('N'))
    $projectRoot = Join-Path -Path $root -ChildPath 'DELTA windows installer 1.0.13'
    $destination = Join-Path -Path $projectRoot -ChildPath 'installers'

    New-Item -Path $projectRoot -ItemType Directory -Force | Out-Null
    if (-not $WithoutCacheDirectory) {
        New-Item -Path $destination -ItemType Directory -Force | Out-Null
    }

    $Script:ConsoleLines  = @()
    $Script:DownloadCalls = @()

    return [pscustomobject]@{
        Root        = $root
        ProjectRoot = $projectRoot
        Destination = $destination
    }
}

function New-TestFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Content = 'sibling-payload'
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    if ($Content -eq '') {
        New-Item -Path $Path -ItemType File -Force | Out-Null
    }
    else {
        Set-Content -LiteralPath $Path -Value $Content -Encoding Ascii -NoNewline
    }
    return $Path
}

function Get-TestFileContent {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw)
}

function Test-ConsoleMentions {
    param([Parameter(Mandatory)][string]$Text)
    return [bool](@($Script:ConsoleLines | Where-Object { $_ -like "*$Text*" }).Count -gt 0)
}

$Script:NodeFileName   = $Script:InstallerConfig.NODE_INSTALLER
$Script:PostGISFileName = $Script:InstallerConfig.POSTGIS_INSTALLER

New-Item -Path $Script:SandboxRoot -ItemType Directory -Force | Out-Null

try {

    # -----------------------------------------------------------------------
    # 1. Already present in the current cache - existing behaviour unchanged
    # -----------------------------------------------------------------------

    $case = New-TestSandbox
    New-TestFile -Path (Join-Path -Path $case.Destination -ChildPath $Script:NodeFileName) -Content 'local-payload' | Out-Null
    # A sibling holding a DIFFERENT copy of the same filename, which must be
    # left alone entirely: the local cache is authoritative.
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "old delta\installers\$($Script:NodeFileName)") -Content 'sibling-payload' | Out-Null

    $result = Get-NodeInstaller -DestinationDirectory $case.Destination

    Assert-Equal -Name '1. Cached installer is returned from the current cache' `
        -Expected (Join-Path -Path $case.Destination -ChildPath $Script:NodeFileName) -Actual $result
    Assert-Equal -Name '1. Cached installer is not overwritten by a sibling copy' `
        -Expected 'local-payload' -Actual (Get-TestFileContent -Path $result)
    Assert-Equal -Name '1. Cached installer triggers no download' -Expected 0 -Actual $Script:DownloadCalls.Count
    Assert-True  -Name '1. Cached installer triggers no sibling search' `
        -Condition (-not (Test-ConsoleMentions -Text 'sibling installer directories'))
    Assert-True  -Name '1. Cached installer still reports the cache hit' `
        -Condition (Test-ConsoleMentions -Text 'Using cached Node.js installer')

    # -----------------------------------------------------------------------
    # 2. Exact file in a conventionally named sibling
    # -----------------------------------------------------------------------

    $case = New-TestSandbox
    $sibling = New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "DELTA windows installer 1.0.12\installers\$($Script:NodeFileName)") -Content 'sibling-payload'

    $result = Get-NodeInstaller -DestinationDirectory $case.Destination

    Assert-Equal -Name '2. Sibling installer is copied into the current cache' `
        -Expected (Join-Path -Path $case.Destination -ChildPath $Script:NodeFileName) -Actual $result
    Assert-Equal -Name '2. Reused file has the sibling content' -Expected 'sibling-payload' -Actual (Get-TestFileContent -Path $result)
    Assert-Equal -Name '2. Reuse skips the download' -Expected 0 -Actual $Script:DownloadCalls.Count
    Assert-True  -Name '2. Source file is left in place' -Condition (Test-Path -LiteralPath $sibling -PathType Leaf)
    Assert-True  -Name '2. Reuse is announced to the operator' `
        -Condition ((Test-ConsoleMentions -Text 'Searching sibling installer directories') -and (Test-ConsoleMentions -Text $sibling))

    # -----------------------------------------------------------------------
    # 3. Exact file in an arbitrarily named sibling (no naming pattern)
    # -----------------------------------------------------------------------

    foreach ($siblingName in @('potpot', 'installer backup', 'testing123', 'old-delta')) {
        $case = New-TestSandbox
        New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "$siblingName\installers\$($Script:NodeFileName)") -Content "payload-$siblingName" | Out-Null

        $result = Get-NodeInstaller -DestinationDirectory $case.Destination

        Assert-Equal -Name "3. Sibling '$siblingName' is reused regardless of its name" `
            -Expected "payload-$siblingName" -Actual (Get-TestFileContent -Path $result)
        Assert-Equal -Name "3. Sibling '$siblingName' reuse skips the download" -Expected 0 -Actual $Script:DownloadCalls.Count
    }

    # -----------------------------------------------------------------------
    # 4. A different version in a sibling is ignored
    # -----------------------------------------------------------------------

    $case = New-TestSandbox
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath 'old delta\installers\node-v22.11.0-x64.msi') -Content 'wrong-version' | Out-Null
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath 'older delta\installers\node-v24.18.0-x86.msi') -Content 'wrong-arch' | Out-Null

    $candidates = @(Find-DeltaReusableInstaller -FileName $Script:NodeFileName -DestinationDirectory $case.Destination)
    Assert-Equal -Name '4. A differently versioned installer is not a candidate' -Expected 0 -Actual $candidates.Count

    $result = Get-NodeInstaller -DestinationDirectory $case.Destination
    Assert-Equal -Name '4. A differently versioned sibling falls back to the download' -Expected 1 -Actual $Script:DownloadCalls.Count
    Assert-Equal -Name '4. Downloaded file is the one returned' -Expected 'downloaded-payload' -Actual (Get-TestFileContent -Path $result)

    # -----------------------------------------------------------------------
    # 5. A sibling without an installers directory is ignored cleanly
    # -----------------------------------------------------------------------

    $case = New-TestSandbox
    New-Item -Path (Join-Path -Path $case.Root -ChildPath 'some other project') -ItemType Directory -Force | Out-Null
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "some other project\$($Script:NodeFileName)") -Content 'not-in-a-cache' | Out-Null

    $candidates = @(Find-DeltaReusableInstaller -FileName $Script:NodeFileName -DestinationDirectory $case.Destination)
    Assert-Equal -Name '5. A sibling with no installers directory yields no candidate' -Expected 0 -Actual $candidates.Count

    $result = Get-NodeInstaller -DestinationDirectory $case.Destination
    Assert-Equal -Name '5. A sibling with no installers directory falls back to the download' -Expected 1 -Actual $Script:DownloadCalls.Count

    # -----------------------------------------------------------------------
    # 6. No sibling has the file - normal download path
    # -----------------------------------------------------------------------

    $case = New-TestSandbox
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "old delta\installers\$($Script:PostGISFileName)") -Content 'a-different-dependency' | Out-Null

    $result = Get-NodeInstaller -DestinationDirectory $case.Destination
    Assert-Equal -Name '6. No reusable installer falls back to the download' -Expected 1 -Actual $Script:DownloadCalls.Count
    Assert-Equal -Name '6. Download target is the current cache' `
        -Expected (Join-Path -Path $case.Destination -ChildPath $Script:NodeFileName) -Actual $Script:DownloadCalls[0].OutFile
    Assert-Equal -Name '6. Download uses the unchanged pinned URL' -Expected $Script:NodeDownloadUrl -Actual $Script:DownloadCalls[0].Uri

    # A missing cache directory is created by the reuse path, exactly as the
    # download path already created it.
    $case = New-TestSandbox -WithoutCacheDirectory
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "potpot\installers\$($Script:NodeFileName)") -Content 'sibling-payload' | Out-Null
    $result = Get-NodeInstaller -DestinationDirectory $case.Destination
    Assert-Equal -Name '6. Reuse creates the cache directory when it does not exist yet' `
        -Expected 'sibling-payload' -Actual (Get-TestFileContent -Path $result)

    # -----------------------------------------------------------------------
    # 7. The current installer directory is never its own sibling
    # -----------------------------------------------------------------------

    $case = New-TestSandbox
    New-TestFile -Path (Join-Path -Path $case.Destination -ChildPath $Script:NodeFileName) -Content 'local-payload' | Out-Null

    $candidates = @(Find-DeltaReusableInstaller -FileName $Script:NodeFileName -DestinationDirectory $case.Destination)
    Assert-Equal -Name '7. The current installer directory is excluded from the sibling search' -Expected 0 -Actual $candidates.Count

    # ...including when the caller spells the same directory differently.
    $oddlySpelled = (Join-Path -Path $case.ProjectRoot -ChildPath 'INSTALLERS\')
    $candidates = @(Find-DeltaReusableInstaller -FileName $Script:NodeFileName -DestinationDirectory $oddlySpelled)
    Assert-Equal -Name '7. Exclusion survives casing/trailing-separator differences' -Expected 0 -Actual $candidates.Count

    # -----------------------------------------------------------------------
    # 8. The search is one level deep on both sides
    # -----------------------------------------------------------------------

    $case = New-TestSandbox
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "old delta\installers\nested\$($Script:NodeFileName)") -Content 'too-deep-1' | Out-Null
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "old delta\nested\installers\$($Script:NodeFileName)") -Content 'too-deep-2' | Out-Null
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "deep\deeper\installers\$($Script:NodeFileName)") -Content 'too-deep-3' | Out-Null
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "loose\$($Script:NodeFileName)") -Content 'too-shallow' | Out-Null

    $candidates = @(Find-DeltaReusableInstaller -FileName $Script:NodeFileName -DestinationDirectory $case.Destination)
    Assert-Equal -Name '8. Nothing outside <sibling>\installers\<file> is a candidate' -Expected 0 -Actual $candidates.Count

    $result = Get-NodeInstaller -DestinationDirectory $case.Destination
    Assert-Equal -Name '8. A deep-only match still falls back to the download' -Expected 1 -Actual $Script:DownloadCalls.Count

    # A zero-length neighbouring copy is not a candidate either - every
    # download path in this project already treats an empty file as failure.
    $case = New-TestSandbox
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "old delta\installers\$($Script:NodeFileName)") -Content '' | Out-Null
    $candidates = @(Find-DeltaReusableInstaller -FileName $Script:NodeFileName -DestinationDirectory $case.Destination)
    Assert-Equal -Name '8. A zero-length sibling copy is not a candidate' -Expected 0 -Actual $candidates.Count

    # -----------------------------------------------------------------------
    # 9. Paths containing spaces
    # -----------------------------------------------------------------------

    $case = New-TestSandbox
    $spacedSibling = New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "a very old delta build\installers\$($Script:NodeFileName)") -Content 'spaced-payload'

    $candidates = @(Find-DeltaReusableInstaller -FileName $Script:NodeFileName -DestinationDirectory $case.Destination)
    Assert-Equal -Name '9. A sibling under paths with spaces is found' -Expected 1 -Actual $candidates.Count
    Assert-Equal -Name '9. The candidate path is the spaced sibling' -Expected $spacedSibling -Actual $candidates[0]

    $result = Get-NodeInstaller -DestinationDirectory $case.Destination
    Assert-Equal -Name '9. A sibling under paths with spaces is reused' -Expected 'spaced-payload' -Actual (Get-TestFileContent -Path $result)
    Assert-Equal -Name '9. A sibling under paths with spaces skips the download' -Expected 0 -Actual $Script:DownloadCalls.Count

    # -----------------------------------------------------------------------
    # 10. Integrity validation rejects a candidate
    # -----------------------------------------------------------------------

    # 10a. Helper level: the only candidate fails validation.
    $case = New-TestSandbox
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "old delta\installers\$($Script:NodeFileName)") -Content 'corrupt' | Out-Null

    $reused = Copy-DeltaReusableInstaller -FileName $Script:NodeFileName -DestinationDirectory $case.Destination -Validate { param($CandidatePath) $false }
    Assert-True  -Name '10a. A rejected candidate returns nothing to reuse' -Condition ($null -eq $reused)
    Assert-True  -Name '10a. A rejected candidate is removed from the current cache' `
        -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $case.Destination -ChildPath $Script:NodeFileName)))

    # 10b. Helper level: a rejected candidate does not block a good one.
    $case = New-TestSandbox
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "aaa stale copy\installers\$($Script:NodeFileName)") -Content 'corrupt' | Out-Null
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "zzz good copy\installers\$($Script:NodeFileName)") -Content 'genuine' | Out-Null

    $reused = Copy-DeltaReusableInstaller -FileName $Script:NodeFileName -DestinationDirectory $case.Destination -Validate {
        param($CandidatePath)
        (Get-Content -LiteralPath $CandidatePath -Raw) -eq 'genuine'
    }
    Assert-Equal -Name '10b. The search continues past a rejected candidate' -Expected 'genuine' -Actual (Get-TestFileContent -Path $reused)

    # 10c. Integration: PostGIS's own published-MD5 check rejects a sibling
    #      copy, and the normal download runs instead. The real
    #      Test-PostGISInstallerIntegrity is used here, not a stub.
    $case = New-TestSandbox
    $badCopy = New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "old delta\installers\$($Script:PostGISFileName)") -Content 'tampered-postgis-bundle'
    $goodHash = (Get-FileHash -LiteralPath (New-TestFile -Path (Join-Path -Path $case.Root -ChildPath 'reference\payload.bin') -Content 'genuine-postgis-bundle') -Algorithm MD5).Hash
    $Script:ChecksumContent = "$goodHash  $($Script:PostGISFileName)"

    $result = Get-PostGISInstaller -DestinationDirectory $case.Destination
    Assert-Equal -Name '10c. A checksum-failing sibling copy falls back to the download' -Expected 1 -Actual $Script:DownloadCalls.Count
    Assert-Equal -Name '10c. The rejected copy is not what gets returned' -Expected 'downloaded-payload' -Actual (Get-TestFileContent -Path $result)
    Assert-True  -Name '10c. The rejected copy is left untouched in its own directory' `
        -Condition ((Get-TestFileContent -Path $badCopy) -eq 'tampered-postgis-bundle')
    Assert-True  -Name '10c. The rejection is reported to the operator' `
        -Condition (Test-ConsoleMentions -Text 'did not pass integrity validation')

    # 10d. Integration: a sibling copy that PASSES the same check is reused.
    $case = New-TestSandbox
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "old delta\installers\$($Script:PostGISFileName)") -Content 'genuine-postgis-bundle' | Out-Null
    $Script:ChecksumContent = "$goodHash  $($Script:PostGISFileName)"

    $result = Get-PostGISInstaller -DestinationDirectory $case.Destination
    Assert-Equal -Name '10d. A checksum-passing sibling copy is reused' -Expected 'genuine-postgis-bundle' -Actual (Get-TestFileContent -Path $result)
    Assert-Equal -Name '10d. A checksum-passing sibling copy skips the download' -Expected 0 -Actual $Script:DownloadCalls.Count

    # 10e. An unavailable checksum file stays "skip, not fail" - the existing
    #      rule, unchanged, on the reuse path too.
    $case = New-TestSandbox
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "old delta\installers\$($Script:PostGISFileName)") -Content 'unverifiable-bundle' | Out-Null
    $Script:ChecksumContent = $null

    $result = Get-PostGISInstaller -DestinationDirectory $case.Destination
    Assert-Equal -Name '10e. An unavailable checksum file does not block reuse' -Expected 'unverifiable-bundle' -Actual (Get-TestFileContent -Path $result)

    # ...and the unchanged fatal path still stops setup on a real mismatch.
    $Script:ChecksumContent = "$goodHash  $($Script:PostGISFileName)"
    $threw = $false
    try {
        Test-PostGISInstallerIntegrity -InstallerPath $result
    }
    catch {
        $threw = "$($_.Exception.Message)" -like 'STOP-SETUP:*'
    }
    Assert-True -Name '10e. The default (fatal) checksum behaviour is unchanged' -Condition $threw

    # -----------------------------------------------------------------------
    # 11. WinSW: the reuse path honours the mandatory SHA-256 pin
    #
    #     The real Get-DeltaWinSwBinary (already loaded through
    #     lib\DeltaInstaller.Common.ps1) is used here, not an extract - it is
    #     the one caller whose validation runs inside its own bounded
    #     verify/re-download loop, so "a rejected neighbouring copy cannot
    #     loop forever" is a property worth pinning down directly.
    # -----------------------------------------------------------------------

    $Script:InstallerConfig.WINSW_INSTALLER = 'WinSW-2.12.0-NET461.exe'
    $Script:InstallerConfig.WINSW_VERSION   = '2.12.0'
    $Script:InstallerConfig.WINSW_URL       = 'https://example.invalid/WinSW-2.12.0-NET461.exe'

    $winswFileName = $Script:InstallerConfig.WINSW_INSTALLER
    $downloadedSha = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([Text.Encoding]::ASCII.GetBytes('downloaded-payload'))) -Algorithm SHA256).Hash

    # 11a. A neighbouring copy matching the pinned digest is reused.
    $case = New-TestSandbox
    $winswSource = New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "old delta\installers\$winswFileName") -Content 'genuine-winsw'
    $Script:InstallerConfig.WINSW_SHA256 = (Get-FileHash -LiteralPath $winswSource -Algorithm SHA256).Hash

    $result = Get-DeltaWinSwBinary -DestinationDirectory $case.Destination
    Assert-Equal -Name '11a. A digest-matching WinSW copy is reused' -Expected 'genuine-winsw' -Actual (Get-TestFileContent -Path $result)
    Assert-Equal -Name '11a. A digest-matching WinSW copy skips the download' -Expected 0 -Actual $Script:DownloadCalls.Count

    # 11b. A neighbouring copy failing the pinned digest is discarded and the
    #      normal download runs instead.
    $case = New-TestSandbox
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "old delta\installers\$winswFileName") -Content 'tampered-winsw' | Out-Null
    $Script:InstallerConfig.WINSW_SHA256 = $downloadedSha

    $result = Get-DeltaWinSwBinary -DestinationDirectory $case.Destination
    Assert-Equal -Name '11b. A digest-failing WinSW copy falls back to the download' -Expected 1 -Actual $Script:DownloadCalls.Count
    Assert-Equal -Name '11b. The downloaded WinSW binary is the one returned' -Expected 'downloaded-payload' -Actual (Get-TestFileContent -Path $result)

    # 11c. Neither a neighbouring copy nor a download can satisfy the pin:
    #      the existing bounded retry still gives up rather than re-copying
    #      the same rejected candidate forever.
    $case = New-TestSandbox
    New-TestFile -Path (Join-Path -Path $case.Root -ChildPath "old delta\installers\$winswFileName") -Content 'tampered-winsw' | Out-Null
    $Script:InstallerConfig.WINSW_SHA256 = 'F' * 64

    $stopped = $false
    try {
        Get-DeltaWinSwBinary -DestinationDirectory $case.Destination | Out-Null
    }
    catch {
        $stopped = "$($_.Exception.Message)" -like '*STOP-SETUP:*'
    }
    Assert-True  -Name '11c. An unsatisfiable WinSW digest still stops setup' -Condition $stopped
    Assert-Equal -Name '11c. The retry stays bounded at two attempts' -Expected 2 -Actual $Script:DownloadCalls.Count

    # -----------------------------------------------------------------------
    # Wiring: every dependency download path goes through the shared helper
    # -----------------------------------------------------------------------

    $wiring = @(
        @{ File = 'setup.ps1';                       Function = 'Get-NodeInstaller' }
        @{ File = 'setup.ps1';                       Function = 'Get-PostgresInstaller' }
        @{ File = 'setup.ps1';                       Function = 'Get-PostGISInstaller' }
        @{ File = 'setup-nginx.ps1';                 Function = 'Get-NginxPackage' }
        @{ File = 'setup-iis.ps1';                   Function = 'Get-DeltaArrComponentPackage' }
        @{ File = 'lib\DeltaInstaller.Service.ps1';  Function = 'Get-DeltaWinSwBinary' }
    )

    foreach ($entry in $wiring) {
        $source = Import-FunctionFromScript -Path (Join-Path -Path $Script:ProjectRoot -ChildPath $entry.File) -FunctionName $entry.Function
        Assert-True -Name "Wiring: $($entry.File) / $($entry.Function) uses the shared reuse helper" `
            -Condition ($source -like '*Copy-DeltaReusableInstaller*')
    }
}
finally {
    Remove-Item -LiteralPath $Script:SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Passed: $($Script:Passes)  Failed: $($Script:Failures)"

if ($Script:Failures -gt 0) { exit 1 }
exit 0

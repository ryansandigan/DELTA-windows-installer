#Requires -Version 5.1
<#
.SYNOPSIS
    DELTA Windows Installer - orchestrator. Node.js, PostgreSQL, PostGIS,
    and the DELTA database itself.

.DESCRIPTION
    This script is the installation orchestrator: it coordinates each
    phase and, for the database lifecycle, invokes the reusable sibling
    scripts init_db.ps1 and upgrade_database.ps1 rather than duplicating
    their logic. Shared helpers (logging, error handling, PostgreSQL
    discovery, credential handling, DATABASE_URL construction) live in
    lib\DeltaInstaller.Common.ps1, dot-sourced by all three entry-point
    scripts - see that file's own header for the rationale.

    Phase 1 verifies whether the required Node.js version is already present
    on this machine and, if not, downloads and silently installs it from the
    official Node.js distribution.

    Phase 2A does the same for the PostgreSQL *server* only: detects an
    existing installation, and if none matches the required major version,
    downloads and silently installs it via the EDB installer's own
    unattended-mode support. If a matching, already-running installation IS
    found, the operator is offered a choice instead of an automatic skip:
    reuse it (recommended - see Resolve-ExistingPostgresCredentials, which
    validates the supplied password live and offers retry/reset/cancel on
    an authentication failure) or install a fresh instance alongside it.

    Phase 2B makes the PostGIS extension usable against that instance:
    downloads the official standalone PostGIS bundle installer (versioned to
    the installed PostgreSQL major version), verifies it against PostGIS's
    published checksum when available, installs it via its NSIS silent mode,
    and validates success by actually running CREATE EXTENSION postgis and
    SELECT PostGIS_Full_Version() - not just checking for files.

    Before any of that, Resolve-DeltaAppRoot asks where DELTA should
    actually be deployed - defaulting to C:\DELTA on a bare Enter, but
    never assumed to be that specific path anywhere else in this script.
    The answer is stored once, in $Script:DeltaRuntimeRoot, and every
    later phase reads that variable rather than a literal path - runtime
    deployment, the database stage's .env target, uploads/logs,
    dependency installation, and the eventual Windows Service working
    directory all follow whatever was chosen here.

    Install-DeltaRuntime then deploys the dts_shared_binary artifact -
    shipped inside this installer repository - into $Script:DeltaRuntimeRoot,
    the separate directory DELTA actually runs from, and
    Initialize-DeltaRuntimeDirectories creates its uploads\/logs\
    subdirectories (confirmed by source audit to be where the application
    resolves them, relative to its own working directory - not a fixed
    C:\DELTA assumption), grants the current account Modify permission on
    them, and proves they're actually writable before continuing. The
    database stage then asks for the DELTA database name (default dts_db)
    and generates or updates <AppRoot>\.env from the repository's
    .env.example template. On a fresh PostgreSQL install this always means
    creating the database via init_db.ps1; when an existing PostgreSQL
    instance was reused, Complete-DatabaseSetupForExistingPostgres instead
    checks whether that database already exists and, if so, asks whether to
    recreate it, upgrade it (upgrade_database.ps1), or leave it untouched -
    <AppRoot>\.env is regenerated with the final connection information in
    every case.

    Phase 3 (Install-DeltaDependencies) installs the DELTA runtime's own
    Node dependencies - Yarn, `yarn install --production`, dotenv-cli - by
    running dts_shared_binary's own init_website.bat, but only when they
    aren't already present (Test-DeltaRuntimeDependenciesInstalled), so a
    repeat run doesn't reinstall them every time. A confirmed gap found
    during Windows validation - dotenv-cli lands in Yarn's own global bin,
    which nothing else puts on PATH - is fixed permanently and
    idempotently by Add-YarnGlobalBinToPersistentPath, which appends that
    directory to the persistent User PATH (not just this session's
    $env:Path), so `dotenv` still resolves in a brand-new console or
    after a reboot, not only for the remainder of this one run.

    Finally, Confirm-DeltaRuntimeNotRunning detects whether a DELTA
    instance from a previous run is still active (by process command
    line, matched specifically to this runtime directory - never a
    generic node.exe sweep) and stops it, so a repeat run never leaves two
    instances bound to the same port. start.bat itself is deliberately
    NOT invoked by this script - application startup remains a manual,
    operator-run step for this validation phase; the final message tells
    the operator to run it themselves.

    This is a multi-phase DELTA installer, built incrementally - see "Future
    phases" at the bottom of this file for how later phases (the Windows
    Service, database upgrade auto-detection) are expected to be added.

    Safe to run repeatedly: if the required software is already installed,
    no download or install is performed for that phase.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is the directory containing this .ps1 file; falls back to
# the current directory only in the unlikely case a script file has no
# $PSScriptRoot (e.g. content piped in rather than run from a saved file).
# Computed first, before anything else, since the shared helper library,
# the installer cache, and the shipped dts_shared_binary artifact source
# are all resolved relative to it. The DELTA *runtime* directory
# ($Script:DeltaRuntimeRoot) is deliberately NOT relative to this at all -
# it's resolved later, interactively, by Resolve-DeltaAppRoot - see
# lib\DeltaInstaller.Common.ps1 for why even its default value
# ($Script:DefaultDeltaRuntimeRoot, C:\DELTA) isn't derived from
# $PSScriptRoot either.
$Script:ProjectRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# The dts_shared_binary artifact ships *inside* the installer repository
# (this is the source of the deployment copy, not where DELTA runs from -
# see Install-DeltaRuntime below and Resolve-DeltaAppRoot for how
# $Script:DeltaRuntimeRoot, the runtime destination, actually gets set).
# Update-DeltaRuntimeArtifact (lib\DeltaRuntimeArtifact.ps1, run in the
# orchestration block below before Install-DeltaRuntime) keeps this
# directory itself current against the DELTA GitHub Releases API -
# downloading/replacing it first if needed - so every phase after that
# point can keep treating it as a fixed, already-current input the same
# way it always has.
$Script:DeltaRuntimeSourceDirectory = Join-Path -Path $Script:ProjectRoot -ChildPath 'dts_shared_binary'

# See lib\DeltaInstaller.Common.ps1's own header for why this is a plain
# dot-sourced file rather than a .psm1 module, and why $Script:ProjectRoot
# must be set before this line rather than computed inside it.
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Common.ps1')

# Automatic dts_shared_binary acquisition/update (GitHub Releases API) -
# deliberately independent of the rest of this script; see that file's own
# header for why it takes its inputs as parameters rather than reading
# $Script: state defined below. Only borrows Write-Step/Write-Detail/
# Write-Success/Write-PhaseBanner/Stop-Setup from the dot-source above.
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaRuntimeArtifact.ps1')

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$Script:RequiredNodeVersion = '24.18.0'
$Script:NodeDownloadUrl     = "https://nodejs.org/dist/v$($Script:RequiredNodeVersion)/node-v$($Script:RequiredNodeVersion)-x64.msi"
$Script:WorkingDirectory    = Join-Path -Path $env:TEMP -ChildPath 'delta-setup'

# Downloaded installers are cached project-locally in .\installers (sibling
# to this script), not in %TEMP% - so repeated smoke tests reuse the same
# ~350 MB+ downloads instead of re-fetching them every run.
$Script:InstallersDirectory = Join-Path -Path $Script:ProjectRoot -ChildPath 'installers'

# PostgreSQL (Phase 2A). EDB does not publish a stable, guaranteed
# download URL the way nodejs.org does - this filename pattern
# (get.enterprisedb.com/postgresql/postgresql-{version}-{build}-windows-x64.exe)
# was confirmed live via a direct HTTP request at the time this was written,
# not officially documented as permanent. Re-verify against
# https://www.enterprisedb.com/downloads/postgres-postgresql-downloads
# before bumping $RequiredPostgresVersion. See docs/06-deployment-risks.md
# ("EDB installer has no stable download URL") for the full finding.
$Script:RequiredPostgresVersion      = '16.14'
$Script:RequiredPostgresBuild        = '2'
$Script:RequiredPostgresMajorVersion = ($Script:RequiredPostgresVersion -split '\.')[0]
$Script:PostgresDownloadUrl          = "https://get.enterprisedb.com/postgresql/postgresql-$($Script:RequiredPostgresVersion)-$($Script:RequiredPostgresBuild)-windows-x64.exe"
$Script:PostgresInstallPrefix        = "C:\Program Files\PostgreSQL\$($Script:RequiredPostgresMajorVersion)"
$Script:PostgresDataDirectory        = Join-Path -Path $Script:PostgresInstallPrefix -ChildPath 'data'
$Script:PostgresServiceName          = "postgresql-x64-$($Script:RequiredPostgresMajorVersion)"
$Script:PostgresPort                 = '5432'
$Script:PostgresSuperuser            = 'postgres'
$Script:PostgresHost                 = 'localhost'

# Cached for reuse across phases within a single run - Phase 2A sets this
# the first time it actually prompts (fresh install, major-version
# mismatch, or the operator choosing to reuse an existing installation -
# see Resolve-ExistingPostgresCredentials); Phase 2B and the database
# stage below reuse it via Get-CachedPostgresSuperuserPassword rather
# than prompting again. Stays $null only if Phase 2A's original
# not-running idempotent-skip path fires, in which case the database
# stage prompts once itself.
$Script:PostgresSuperuserPassword = $null

# Set by Install-PostgreSql only when the operator explicitly chose to
# reuse an already-installed, already-running PostgreSQL instance rather
# than installing a fresh one. Read by Complete-DatabaseSetup to decide
# between the original "always create fresh" flow and the reuse-aware
# recreate/upgrade/keep flow (Complete-DatabaseSetupForExistingPostgres) -
# a fresh install never needs that decision, since the DELTA database
# provably doesn't exist yet on an instance this run just created.
$Script:PostgresReuseMode = $false

# PostGIS (Phase 2B). Official standalone bundle installers, distributed by
# the PostGIS project itself (not EDB) at download.osgeo.org, versioned per
# PostgreSQL major version. Verified directly during the Phase 2B review:
# downloaded and ran postgis-bundle-pg16x64-setup-3.6.2-1.exe with /S
# against a real PostgreSQL 16 instance - confirmed silent (no window),
# confirmed CREATE EXTENSION postgis + SELECT PostGIS_Full_Version() both
# succeed afterward. Unlike the PostgreSQL installer, official MD5
# checksums are published alongside each release - see
# Test-PostGISInstallerIntegrity. Re-verify the version/build at
# https://download.osgeo.org/postgis/windows/pg<major>/ before bumping.
$Script:RequiredPostGISVersion = '3.6.2'
$Script:RequiredPostGISBuild   = '1'
$Script:PostGISDownloadUrl     = "https://download.osgeo.org/postgis/windows/pg$($Script:RequiredPostgresMajorVersion)/postgis-bundle-pg$($Script:RequiredPostgresMajorVersion)x64-setup-$($Script:RequiredPostGISVersion)-$($Script:RequiredPostGISBuild).exe"
$Script:PostGISChecksumUrl     = "$($Script:PostGISDownloadUrl).md5"

# DELTA database + environment file. init_db.ps1/upgrade_database.ps1 own
# the actual database logic (invoked as sibling scripts, see
# Invoke-DeltaDatabaseInit below); this script only generates the
# environment file and collects the database name, per the database/
# environment workflow assessment's finding that dts_shared_binary\
# ships no .env template of its own - .env.example at the project root
# (this installer repository) is the only verified-accurate template
# found. The generated .env itself is written under $Script:DeltaRuntimeRoot
# (the operator-chosen application directory - see Resolve-DeltaAppRoot)
# - never anywhere inside the installer repository, so it survives
# independently of it.
#
# Deliberately NOT computed here as a top-level $Script:EnvTargetPath:
# $Script:DeltaRuntimeRoot's real value isn't known until
# Resolve-DeltaAppRoot prompts for it, which happens after this
# Configuration section runs - New-DeltaEnvironmentFile computes its
# target path itself, at the point it's actually needed, instead.
$Script:DefaultDeltaDatabaseName = 'dts_db'
$Script:EnvTemplatePath          = Join-Path -Path $Script:ProjectRoot -ChildPath '.env.example'

# Set by Resolve-ExistingDeltaDeployment - 'Upgrade' (default), 'Recreate',
# or 'Fresh'. Stays 'Upgrade' unmodified whenever no existing DELTA
# deployment is found at all, which is exactly what makes that case behave
# identically to every phase's own pre-existing idempotent behavior with
# zero special-casing required elsewhere. Read by New-DeltaEnvironmentFile
# (via its -ForceRegenerateFromTemplate switch) once DATABASE_URL is
# finally known, later in the run - see Resolve-ExistingDeltaDeployment's
# own header for why the 'Recreate' choice can only be recorded here, not
# acted on immediately.
$Script:DeltaDeploymentLifecycle = 'Upgrade'

# ---------------------------------------------------------------------------
# Generic helpers
#
# Write-SetupBanner, Write-PhaseBanner, Write-Step, Write-Detail,
# Write-Success, Stop-Setup, Test-IsAdministrator, and ConvertTo-PlainText
# now live in lib\DeltaInstaller.Common.ps1 (dot-sourced above) - shared
# with init_db.ps1 and upgrade_database.ps1. Only what's genuinely
# specific to this script's own installation phases stays here.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Update-SessionEnvironmentPath now lives in lib\DeltaInstaller.Common.ps1 -
# uninstall.ps1 needs the identical Machine+User PATH refresh (e.g. right
# after an MSI uninstall) that this script does after an install.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Node.js detection now lives in lib\DeltaInstaller.Common.ps1
# (Find-NodeExecutable, Get-InstalledNodeVersion) - uninstall.ps1 needs the
# exact same "is Node.js actually usable right now" detection this script
# uses, so it was promoted to the shared file the same way PostgreSQL
# detection already was, rather than let a second copy of either function
# exist.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

function Get-NodeInstaller {
    <#
      Returns a cached Node.js installer from $DestinationDirectory if one is
      already present, downloading it only when missing. $DestinationDirectory
      is normally the project-local .\installers cache (see
      $Script:InstallersDirectory), not a per-run temp folder - the whole
      point is that repeated runs reuse the same download.
    #>
    param([Parameter(Mandatory)][string]$DestinationDirectory)

    if (-not (Test-Path -Path $DestinationDirectory)) {
        New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null
    }

    $installerPath = Join-Path -Path $DestinationDirectory -ChildPath "node-v$($Script:RequiredNodeVersion)-x64.msi"

    if (Test-Path -Path $installerPath) {
        Write-Step 'Using cached Node.js installer...'
        Write-Detail "Cache: $installerPath"
        return $installerPath
    }

    Write-Step "Downloading Node.js v$($Script:RequiredNodeVersion) installer..."
    Write-Detail "Source: $($Script:NodeDownloadUrl)"
    Write-Detail "Target: $installerPath"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Script:NodeDownloadUrl -OutFile $installerPath -UseBasicParsing
    }
    catch {
        Stop-Setup "Failed to download the Node.js installer from $($Script:NodeDownloadUrl): $($_.Exception.Message)"
    }

    if (-not (Test-Path -Path $installerPath) -or (Get-Item -Path $installerPath).Length -eq 0) {
        Stop-Setup "Download reported success but the installer file is missing or empty: $installerPath"
    }

    Write-Success '    Download complete.'
    return $installerPath
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

function Install-NodeMsi {
    <#
      Runs the MSI silently via msiexec and waits for it to finish.
      Exit code 0 = success. 3010 = success, reboot recommended (not
      required to continue this script). Anything else is a hard failure.
    #>
    param([Parameter(Mandatory)][string]$InstallerPath)

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to install Node.js. Re-run this script from an elevated PowerShell session.'
    }

    $logPath = Join-Path -Path $Script:WorkingDirectory -ChildPath 'node-install.log'

    Write-Step 'Installing Node.js (silent MSI install)...'
    Write-Detail "Log: $logPath"
    Write-Detail 'This may take several minutes.'

    $argumentString = "/i `"$InstallerPath`" /qn /norestart /log `"$logPath`""
    $process = Start-ProcessWithActivityIndicator -FilePath 'msiexec.exe' -ArgumentList $argumentString -ActivityName 'Installing Node.js'

    switch ($process.ExitCode) {
        0 {
            Write-Success '    Installation completed successfully.'
        }
        3010 {
            Write-Detail 'Installation completed successfully. A reboot is recommended but not required to continue.'
        }
        default {
            Stop-Setup "The Node.js installer returned exit code $($process.ExitCode). See the log for details: $logPath"
        }
    }
}

# ---------------------------------------------------------------------------
# Phase 1 entry point
# ---------------------------------------------------------------------------

function Install-NodeJs {
    <#
      Phase 1 of the DELTA installer. Idempotent: if the exact required
      version is already installed, this returns immediately without
      downloading or installing anything.
    #>

    Write-PhaseBanner 'Phase 1 - Node.js'
    Write-Step 'Checking for an existing Node.js installation...'
    $nodePath = Find-NodeExecutable

    if ($nodePath) {
        $installedVersion = Get-InstalledNodeVersion -NodeExecutablePath $nodePath

        if ($installedVersion -eq $Script:RequiredNodeVersion) {
            Write-Host ''
            Write-Host 'Node.js detected.'
            Write-Host ''
            Write-Host 'Version:'
            Write-Host "v$installedVersion"
            Write-Host ''
            Write-Host 'Status:'
            Write-Host 'Already installed.'
            Write-Host ''
            Write-Host 'Skipping installation.'
            return
        }

        Write-Host ''
        Write-Host 'Node.js detected.'
        Write-Host ''
        Write-Host 'Installed:'
        Write-Host $(if ($installedVersion) { "v$installedVersion" } else { '(unknown version)' })
        Write-Host ''
        Write-Host 'Required:'
        Write-Host "v$($Script:RequiredNodeVersion)"
        Write-Host ''
        Write-Host 'Updating installation...'
    }
    else {
        Write-Detail 'Node.js was not found on this system.'
    }

    Write-Host ''
    $installerPath = Get-NodeInstaller -DestinationDirectory $Script:InstallersDirectory
    Install-NodeMsi -InstallerPath $installerPath

    Write-Step 'Refreshing environment variables for this session...'
    Update-SessionEnvironmentPath

    Write-Step 'Validating installation...'
    $confirmedNodePath = Find-NodeExecutable
    if (-not $confirmedNodePath) {
        Stop-Setup 'Node.js installation appeared to succeed, but node.exe could not be located afterward.'
    }

    $finalVersion = Get-InstalledNodeVersion -NodeExecutablePath $confirmedNodePath
    if ($finalVersion -ne $Script:RequiredNodeVersion) {
        Stop-Setup "Version mismatch after installation. Expected v$($Script:RequiredNodeVersion) but found $(if ($finalVersion) { "v$finalVersion" } else { 'no reported version' })."
    }

    $npmVersion = $null
    try {
        $npmVersion = & npm '-v' 2>$null
    }
    catch {
        $npmVersion = $null
    }
    if (-not $npmVersion) {
        Stop-Setup 'Node.js installation succeeded, but npm was not found afterward.'
    }

    Write-Host ''
    Write-Success 'Node.js successfully installed.'
    Write-Host ''
    Write-Host 'Node:'
    Write-Host "v$finalVersion"
    Write-Host ''
    Write-Host 'npm:'
    Write-Host ($npmVersion | Select-Object -First 1).ToString().Trim()
}

# ---------------------------------------------------------------------------
# PostgreSQL detection and credential handling now live in
# lib\DeltaInstaller.Common.ps1 (Find-PostgresInstallation,
# Get-PostgresBinDirectory, Read-PostgresSuperuserPassword) - shared with
# init_db.ps1 and upgrade_database.ps1.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# PostgreSQL download
# ---------------------------------------------------------------------------

function Get-PostgresInstaller {
    <#
      Returns a cached PostgreSQL installer from $DestinationDirectory if one
      is already present, downloading it only when missing - same caching
      contract as Get-NodeInstaller. See the download-URL caveat on
      $Script:PostgresDownloadUrl above and docs/06-deployment-risks.md -
      EDB does not guarantee this URL the way nodejs.org guarantees its
      dist server.
    #>
    param([Parameter(Mandatory)][string]$DestinationDirectory)

    if (-not (Test-Path -Path $DestinationDirectory)) {
        New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null
    }

    $installerPath = Join-Path -Path $DestinationDirectory -ChildPath "postgresql-$($Script:RequiredPostgresVersion)-$($Script:RequiredPostgresBuild)-windows-x64.exe"

    if (Test-Path -Path $installerPath) {
        Write-Step 'Using cached PostgreSQL installer...'
        Write-Detail "Cache: $installerPath"
        return $installerPath
    }

    Write-Step "Downloading PostgreSQL $($Script:RequiredPostgresVersion) installer..."
    Write-Detail "Source: $($Script:PostgresDownloadUrl)"
    Write-Detail "Target: $installerPath"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Script:PostgresDownloadUrl -OutFile $installerPath -UseBasicParsing
    }
    catch {
        $downloadFailureDetail = 'EnterpriseDB does not publish a permanently stable download URL for this file (see docs/06-deployment-risks.md). Confirm the current filename at https://www.enterprisedb.com/downloads/postgres-postgresql-downloads and update the RequiredPostgresVersion/RequiredPostgresBuild values in this script if it has changed.'
        Stop-Setup "Failed to download the PostgreSQL installer from $($Script:PostgresDownloadUrl): $($_.Exception.Message). $downloadFailureDetail"
    }

    if (-not (Test-Path -Path $installerPath) -or (Get-Item -Path $installerPath).Length -eq 0) {
        Stop-Setup "Download reported success but the installer file is missing or empty: $installerPath"
    }

    Write-Success '    Download complete.'
    return $installerPath
}

# ---------------------------------------------------------------------------
# PostgreSQL install
# ---------------------------------------------------------------------------

function New-ServiceAccountPassword {
    <#
      Generates a random password that satisfies Windows local account
      complexity requirements (upper, lower, digit, symbol; 20+ characters),
      for the Windows service account PostgreSQL runs under. Deliberately
      independent of the operator-entered superuser password - EDB's
      installer otherwise defaults --servicepassword to reusing
      --superpassword, which fails account creation if that value doesn't
      satisfy this machine's password policy. See docs/06-deployment-risks.md
      ("EDB installer default superuser password").
    #>
    param([int]$Length = 24)

    $charSets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ'   # upper, no I/O (visual ambiguity)
        'abcdefghijkmnpqrstuvwxyz'   # lower, no l/o
        '23456789'                  # digits, no 0/1
        '!@#$%^&*-_=+'               # symbols
    )
    $allChars = -join $charSets

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] $Length
        $rng.GetBytes($bytes)

        $passwordChars = New-Object System.Collections.Generic.List[char]
        # Guarantee at least one character from each required class first.
        for ($i = 0; $i -lt $charSets.Length; $i++) {
            $passwordChars.Add($charSets[$i][$bytes[$i] % $charSets[$i].Length])
        }
        for ($i = $charSets.Length; $i -lt $Length; $i++) {
            $passwordChars.Add($allChars[$bytes[$i] % $allChars.Length])
        }

        # Fisher-Yates shuffle so the guaranteed-class characters aren't
        # always in the first four positions.
        $shuffleBytes = New-Object byte[] $passwordChars.Count
        $rng.GetBytes($shuffleBytes)
        for ($i = $passwordChars.Count - 1; $i -gt 0; $i--) {
            $j = $shuffleBytes[$i] % ($i + 1)
            $tmp = $passwordChars[$i]
            $passwordChars[$i] = $passwordChars[$j]
            $passwordChars[$j] = $tmp
        }

        return -join $passwordChars
    }
    finally {
        $rng.Dispose()
    }
}

function Test-PostgresPort {
    <#
      Reports whether $Port is free to listen on and, if not, a
      human-readable description (process name + PID) of whatever
      already owns it, for display to the operator. Uses
      Get-NetTCPConnection (built into Windows Server's NetTCPIP module)
      rather than a raw socket bind, since it also identifies the owner.
    #>
    param([Parameter(Mandatory)][int]$Port)

    $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $connection) {
        return [PSCustomObject]@{ Available = $true; OwnerDescription = $null }
    }

    $owner = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
    $description = if ($owner) { "$($owner.ProcessName).exe (PID $($owner.Id))" } else { "PID $($connection.OwningProcess)" }
    return [PSCustomObject]@{ Available = $false; OwnerDescription = $description }
}

function Resolve-PostgresPort {
    <#
      Picks the port PostgreSQL will actually listen on. Prefers
      $Script:PostgresPort (5432) when it's free. If occupied - e.g. by
      wslrelay.exe, which is how this was originally found, see
      docs/06-deployment-risks.md - reports the owning process and
      prompts the operator for an alternative, defaulting to 5433 (EDB's
      own installer default) on a bare Enter, and re-prompts until a free
      port is entered. 5433 is only a suggested default here, never a
      forced or globally hardcoded value - the preferred port is always
      5432 unless this function finds it taken.
    #>
    $preferredPort = $Script:PostgresPort
    $check = Test-PostgresPort -Port $preferredPort
    if ($check.Available) {
        return $preferredPort
    }

    Write-Host ''
    Write-Host "Port $preferredPort is already in use." -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'The default PostgreSQL port is currently occupied by another application or service.'
    Write-Host ''
    Write-Host 'Owning process:'
    Write-Host $check.OwnerDescription
    Write-Host ''
    Write-Host 'The process name is shown for diagnostic purposes only and helps identify what is currently using the port.'
    Write-Host ''
    Write-Host 'Please choose another available port to continue the installation.'

    $suggestedPort = '5433'
    while ($true) {
        $entered = Read-Host -Prompt "Enter PostgreSQL port [$suggestedPort]"
        $candidate = if ([string]::IsNullOrWhiteSpace($entered)) { $suggestedPort } else { $entered.Trim() }

        $portNumber = 0
        if (-not [int]::TryParse($candidate, [ref]$portNumber) -or $portNumber -lt 1 -or $portNumber -gt 65535) {
            Write-Host "'$candidate' is not a valid port number (1-65535). Try again." -ForegroundColor Yellow
            continue
        }

        $recheck = Test-PostgresPort -Port $portNumber
        if ($recheck.Available) {
            return $portNumber
        }

        Write-Host ''
        Write-Host "Port $portNumber is also already in use." -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Owning process:'
        Write-Host $recheck.OwnerDescription
        Write-Host ''
        Write-Host 'Please choose another available port to continue the installation.'
    }
}

function Read-ManualPostgresPort {
    <#
      Prompts the operator to enter the PostgreSQL port directly - the
      last resort in Resolve-ExistingPostgresPort's detection chain, only
      reached once config-file parsing, live-socket detection, and a
      direct server query have all failed to produce an answer. Unlike
      Resolve-PostgresPort's "port already in use" prompt, no default is
      offered here: that prompt suggests 5433 because it KNOWS 5432 is
      occupied and 5433 is a reasonable next guess for a fresh install,
      but here every automated method has already failed and there is no
      safe guess left to fall back to - a confirmed real bug (see
      Get-PostgresListeningPort's own docstring) was caused by exactly
      that kind of guess. The operator must supply a real answer.
    #>
    while ($true) {
        Write-Host ''
        $entered = Read-Host -Prompt 'Enter the PostgreSQL port'

        $portNumber = 0
        if (-not [int]::TryParse($entered.Trim(), [ref]$portNumber) -or $portNumber -lt 1 -or $portNumber -gt 65535) {
            Write-Host "'$entered' is not a valid port number (1-65535). Try again." -ForegroundColor Yellow
            continue
        }

        return $portNumber
    }
}

function Resolve-ExistingPostgresPort {
    <#
      Determines the port an existing, already-running PostgreSQL
      instance is actually listening on, trying progressively more
      indirect/expensive methods before ever asking the operator - the
      goal, and the direct lesson from a confirmed prior bug (see
      Get-PostgresListeningPort's own docstring), is that a normal
      installation should never require the operator to already know the
      port:

        1. Parse postgresql.conf/postgresql.auto.conf directly
           (Get-PostgresPortFromConfigFile) - cheapest, usually enough on
           its own.
        2. Ask the OS what the service's own process is actually bound to
           (Get-PostgresListeningPort, via Get-NetTCPConnection) - catches
           an effective port that differs from anything on disk (e.g. a
           command-line override).
        3. Query the server directly on the well-known candidate ports
           this installer itself ever suggests (5432, 5433) - a real
           Postgres-protocol connection attempt
           (Test-PostgresServerRespondingOnPort), not just OS bookkeeping
           again.
        4. Only if all three come back empty, prompt the operator
           (Read-ManualPostgresPort) - and say so explicitly, rather than
           silently guessing a default.

      Each method returns a value it can stand behind or nothing at all -
      never a guess - so whichever one succeeds becomes the confirmed
      port for the rest of the run. Which method actually answered is
      logged (Write-Detail), so a future "why did it ask me for the
      port" question is answerable from the transcript instead of a
      repeat investigation.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Existing)

    $fromConfig = Get-PostgresPortFromConfigFile -Existing $Existing
    if ($fromConfig) {
        Write-Detail "Port detected from postgresql.conf: $fromConfig"
        return $fromConfig
    }

    $fromService = if ($Existing.ServiceName) { Get-PostgresListeningPort -ServiceName $Existing.ServiceName } else { $null }
    if ($fromService) {
        Write-Detail "Port detected from the running service's listening socket: $fromService"
        return $fromService
    }

    foreach ($candidate in @('5432', '5433')) {
        if (Test-PostgresServerRespondingOnPort -PostgresHost $Script:PostgresHost -Port $candidate -Username $Script:PostgresSuperuser) {
            Write-Detail "Port confirmed by querying the server directly: $candidate"
            return $candidate
        }
    }

    Write-Host ''
    Write-Host 'Unable to determine PostgreSQL listening port automatically.' -ForegroundColor Yellow
    Write-Host 'Please enter the PostgreSQL port.' -ForegroundColor Yellow
    return Read-ManualPostgresPort
}

function Install-PostgresServer {
    <#
      Runs the EDB installer's own documented unattended mode. Every flag
      here is drawn from EDB's published command-line parameter reference
      (docs/08-development-roadmap.md has the research summary with
      sources) - nothing here is a guessed or undocumented switch.

      This is a BitRock/InstallBuilder executable, not an MSI: msiexec
      conventions from Install-NodeMsi do not apply. In particular, EDB
      documents no exit-code table beyond "0 = success" and no
      reboot-required code equivalent to msiexec's 3010 - any non-zero
      exit code is therefore treated as an unconditional failure here.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][SecureString]$SuperuserPassword
    )

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to install PostgreSQL. Re-run this script from an elevated PowerShell session.'
    }

    Write-Step 'Installing PostgreSQL (silent, unattended install)...'

    # Resolves to $Script:PostgresPort (5432) unchanged when it's free, so
    # this is a no-op on the common path. Updates the script-scoped value
    # itself (not a local variable) so every later reference to
    # $Script:PostgresPort - the --serverport argument below, and any
    # future phase building a connection string - sees whatever port was
    # actually selected.
    $Script:PostgresPort = Resolve-PostgresPort

    $logPath        = Join-Path -Path $Script:WorkingDirectory -ChildPath 'postgres-install.log'
    $errorTracePath = Join-Path -Path $Script:WorkingDirectory -ChildPath 'postgres-errortrace.log'

    Write-Detail "Log: $logPath"
    Write-Detail "Error trace: $errorTracePath"
    Write-Detail "Install directory: $($Script:PostgresInstallPrefix)"
    Write-Detail "Data directory: $($Script:PostgresDataDirectory)"
    Write-Detail "Port: $($Script:PostgresPort)"
    Write-Detail "Service name: $($Script:PostgresServiceName)"
    Write-Detail 'This may take several minutes.'

    $plainPassword   = ConvertTo-PlainText -SecureString $SuperuserPassword
    $servicePassword = New-ServiceAccountPassword
    $argumentString  = $null
    $process         = $null
    try {
        $argumentString = @(
            '--mode unattended'
            '--unattendedmodeui none'
            "--prefix `"$($Script:PostgresInstallPrefix)`""
            "--datadir `"$($Script:PostgresDataDirectory)`""
            "--serverport $($Script:PostgresPort)"
            "--servicename `"$($Script:PostgresServiceName)`""
            "--superaccount $($Script:PostgresSuperuser)"
            "--superpassword `"$plainPassword`""
            "--servicepassword `"$servicePassword`""
            '--enable-components server,commandlinetools'
            "--debugtrace `"$logPath`""
            "--errortrace `"$errorTracePath`""
        ) -join ' '

        $process = Start-ProcessWithActivityIndicator -FilePath $InstallerPath -ArgumentList $argumentString -ActivityName 'Installing PostgreSQL'
    }
    finally {
        # Best-effort clearing of the in-memory plaintext passwords. .NET
        # strings are immutable and this is not a guaranteed wipe, but it
        # avoids holding an extra live reference any longer than needed.
        $plainPassword   = $null
        $servicePassword = $null
        $argumentString  = $null
    }

    if ($process.ExitCode -ne 0) {
        Stop-Setup "The PostgreSQL installer returned exit code $($process.ExitCode). EDB does not publish a documented meaning for non-zero exit codes beyond 0 = success, so this is treated as a failure. See the installer log for details: $logPath"
    }

    Write-Success '    Installer reported success (exit code 0).'
}

function Get-CachedPostgresSuperuserPassword {
    <#
      Returns the PostgreSQL superuser password collected earlier in this
      run, prompting (via the shared Read-PostgresSuperuserPassword) and
      caching it only if nothing has been collected yet. The single
      mechanism by which every phase in the same setup.ps1 invocation
      reuses one credential instead of re-prompting - closes the "the
      password doesn't survive past Phase 2A/2B" gap identified in the
      database/environment workflow assessment (Part E). Phase 2A,
      Phase 2B, and the database stage all call this instead of
      Read-PostgresSuperuserPassword directly.
    #>
    if (-not $Script:PostgresSuperuserPassword) {
        $Script:PostgresSuperuserPassword = Read-PostgresSuperuserPassword
    }
    return $Script:PostgresSuperuserPassword
}

# ---------------------------------------------------------------------------
# Existing PostgreSQL reuse
# ---------------------------------------------------------------------------

function Read-ExistingPostgresChoice {
    <#
      Displays the existing-installation summary (version, service
      status, host, port) and asks whether to reuse it or install a
      fresh instance alongside it. Bare Enter defaults to "Reuse" - the
      recommended option per the installer's own design goals (avoid
      forcing an operator to give up a perfectly usable PostgreSQL
      instance just because setup.ps1 doesn't know about it yet).
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Existing,
        [Parameter(Mandatory)]$DisplayPort
    )

    Write-Host ''
    Write-Host 'An existing PostgreSQL installation was detected.'
    Write-Host ''
    Write-Host 'Version:'
    Write-Host $Existing.Version
    Write-Host ''
    Write-Host 'Service status:'
    Write-Host $Existing.ServiceStatus
    Write-Host ''
    Write-Host 'Host:'
    Write-Host $Script:PostgresHost
    Write-Host ''
    Write-Host 'Port:'
    Write-Host $DisplayPort
    Write-Host ''
    Write-Host '1) Reuse the existing PostgreSQL installation (recommended)'
    Write-Host '2) Install a new PostgreSQL instance'
    Write-Host ''

    while ($true) {
        $choice = Read-Host -Prompt 'Choose an option [1]'
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }

        switch ($choice.Trim()) {
            '1' { return 'Reuse' }
            '2' { return 'InstallNew' }
        }
        Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow
    }
}

function Resolve-ExistingPostgresCredentials {
    <#
      Prompts for and validates the superuser password when reusing an
      already-installed, already-running PostgreSQL instance - unlike a
      fresh install (where this script itself just set the password and
      therefore already knows it's correct), a reused instance's
      password is only an operator-supplied guess until it's actually
      checked against the live server via Test-PostgresCredentials.

      A failed check does not abort the installer: it offers to retry,
      to reset the password outright (Reset-PostgresSuperuserPassword),
      or to cancel - see the Authentication Failure Workflow in this
      feature's design notes. On success, caches the validated password
      into $Script:PostgresSuperuserPassword so every later phase
      (Get-CachedPostgresSuperuserPassword) reuses it without
      re-prompting or re-validating.

      Confirmed root cause of a real bug: this used to print a fixed
      "Authentication failed." message for ANY failure, including a
      wrong port (connection refused) - which misled the operator into
      choosing "Reset the PostgreSQL superuser password" for a problem a
      password reset could never fix, and which then failed the same
      way for the same reason. The actual psql error is now classified
      (Get-PostgresConnectionFailureReason) and shown instead, so a wrong
      port, a wrong password, and a missing database are no longer
      indistinguishable to the operator.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Existing)

    while ($true) {
        $password = Read-Host -Prompt 'Enter the PostgreSQL superuser password' -AsSecureString
        Write-Step 'Validating credentials...'
        $check = Test-PostgresCredentials -PostgresHost $Script:PostgresHost -Port $Script:PostgresPort `
            -Username $Script:PostgresSuperuser -Password $password

        if ($check.Success) {
            Write-Success '    Authentication succeeded.'
            $Script:PostgresSuperuserPassword = $password
            return
        }

        $failureReason = Get-PostgresConnectionFailureReason -ErrorMessage $check.ErrorMessage

        $retryPassword = $false
        while (-not $retryPassword) {
            Write-Host ''
            Write-Host "Connection failed: $failureReason" -ForegroundColor Red
            Write-Host ''
            Write-Host '1) Try again'
            Write-Host '2) Reset the PostgreSQL superuser password'
            Write-Host '3) Cancel installation'
            Write-Host ''
            $choice = Read-Host -Prompt 'Choose an option [1]'
            if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }

            switch ($choice.Trim()) {
                '1' {
                    $retryPassword = $true
                }
                '2' {
                    $resetPassword = Reset-PostgresSuperuserPassword -Existing $Existing `
                        -PostgresHost $Script:PostgresHost -Port $Script:PostgresPort -Username $Script:PostgresSuperuser
                    if ($resetPassword) {
                        $Script:PostgresSuperuserPassword = $resetPassword
                        return
                    }
                    # Declined the confirmation warning - re-show this same menu.
                }
                '3' {
                    Stop-Setup 'Installation canceled by user.'
                }
                default {
                    Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow
                }
            }
        }
        # $retryPassword -eq $true falls through to the outer loop, which
        # re-prompts for the password from the top.
    }
}

# ---------------------------------------------------------------------------
# Phase 2A entry point
# ---------------------------------------------------------------------------

function Install-PostgreSql {
    <#
      Phase 2A of the DELTA installer: PostgreSQL server only. Idempotent:
      if a PostgreSQL installation matching the required MAJOR version is
      already present and running, the operator is offered a choice
      (Read-ExistingPostgresChoice) between reusing it and installing a
      fresh instance alongside it - see Resolve-ExistingPostgresCredentials
      for what "reuse" actually validates before the rest of the
      installer proceeds.

      Deliberately matches on major version only, not exact version, unlike
      Install-NodeJs's exact-match rule - DELTA's schema is minor-version
      tolerant within PostgreSQL 16.x (docs/04-database.md), so requiring
      an exact patch match would force needless reinstalls on every routine
      PostgreSQL security update.

      Does NOT install PostGIS or initialize DELTA's database - those are
      separate phases (2B, the database stage below).
    #>

    Write-PhaseBanner 'Phase 2A - PostgreSQL'
    Write-Step 'Checking for an existing PostgreSQL installation...'
    $existing = Find-PostgresInstallation

    if ($existing.Found) {
        if ($existing.MajorVersion -eq $Script:RequiredPostgresMajorVersion) {
            if ($existing.ServiceStatus -eq 'Running') {
                $displayPort = Resolve-ExistingPostgresPort -Existing $existing

                $decision = Read-ExistingPostgresChoice -Existing $existing -DisplayPort $displayPort

                if ($decision -eq 'Reuse') {
                    $Script:PostgresPort = $displayPort
                    Resolve-ExistingPostgresCredentials -Existing $existing
                    $Script:PostgresReuseMode = $true

                    Write-Host ''
                    Write-Success 'Reusing the existing PostgreSQL installation.'
                    return
                }

                Write-Detail 'Proceeding with a new PostgreSQL installation alongside the existing one.'
            }
            else {
                Write-Host ''
                Write-Host 'PostgreSQL detected.'
                Write-Host ''
                Write-Host 'Version:'
                Write-Host $existing.Version
                Write-Host ''
                Write-Host 'Status:'
                Write-Host 'Already installed.'
                Write-Host ''
                Write-Host 'Skipping installation.'
                return
            }
        }
        else {
            Write-Host ''
            Write-Host 'PostgreSQL detected.'
            Write-Host ''
            Write-Host 'Installed:'
            Write-Host $(if ($existing.Version) { $existing.Version } else { '(unknown version)' })
            Write-Host ''
            Write-Host 'Required:'
            Write-Host "$($Script:RequiredPostgresMajorVersion).x"
            Write-Host ''
            Write-Host "A different PostgreSQL major version is installed. PostgreSQL major versions install side by side rather than in place, so PostgreSQL $($Script:RequiredPostgresMajorVersion) will be installed alongside the existing instance."
        }
    }
    else {
        Write-Detail 'PostgreSQL was not found on this system.'
    }

    Write-Host ''
    $superuserPassword = Get-CachedPostgresSuperuserPassword
    $installerPath = Get-PostgresInstaller -DestinationDirectory $Script:InstallersDirectory
    Install-PostgresServer -InstallerPath $installerPath -SuperuserPassword $superuserPassword

    Write-Step 'Refreshing environment variables for this session...'
    Update-SessionEnvironmentPath

    Write-Step 'Validating installation...'
    $confirmed = Find-PostgresInstallation

    if (-not $confirmed.Found -or -not $confirmed.PsqlPath) {
        Stop-Setup 'PostgreSQL installation appeared to succeed, but psql.exe could not be located afterward.'
    }
    if ($confirmed.MajorVersion -ne $Script:RequiredPostgresMajorVersion) {
        Stop-Setup "Version mismatch after installation. Expected major version $($Script:RequiredPostgresMajorVersion).x but found $(if ($confirmed.Version) { $confirmed.Version } else { 'no reported version' })."
    }
    if (-not $confirmed.PostgresExePath) {
        Stop-Setup 'postgres.exe was not found alongside psql.exe after installation.'
    }
    if (-not $confirmed.ServiceName) {
        Stop-Setup 'No PostgreSQL Windows service was found after installation.'
    }
    if ($confirmed.ServiceStatus -ne 'Running') {
        Stop-Setup "The PostgreSQL service ('$($confirmed.ServiceName)') exists but is not running (status: $($confirmed.ServiceStatus))."
    }

    Write-Host ''
    Write-Success 'PostgreSQL successfully installed.'
    Write-Host ''
    Write-Host 'Version:'
    Write-Host $confirmed.Version
    Write-Host ''
    Write-Host 'Service:'
    Write-Host $confirmed.ServiceStatus
    Write-Host ''
    Write-Host 'psql:'
    Write-Host 'Available'
}

# ---------------------------------------------------------------------------
# PostGIS detection and validation
# ---------------------------------------------------------------------------

function Get-PostGISFailureReason {
    <#
      Classifies why Test-PostGISAvailable's psql invocation didn't
      confirm PostGIS as available, into one of a small set of short,
      stable category labels - diagnostic-only, purely for the log.
      Never called by anything that changes behavior based on the
      result; it only makes the existing pass/fail outcome easier to
      read in the installer's own output. Mirrors the classification
      approach Get-PostgresConnectionFailureReason
      (lib\DeltaInstaller.Common.ps1) already uses for the credential-
      validation path - full-sentence explanations there, short category
      labels here - and adds an "Extension missing" category specific to
      this function's own CREATE EXTENSION postgis call.
    #>
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyString()][string]$OutputText
    )

    if ($ExitCode -eq 0) {
        # psql itself reported success (exit 0) but the expected POSTGIS=
        # marker wasn't found in its output - not one of the normal,
        # anticipated failure shapes below.
        return 'Unexpected PostgreSQL error'
    }
    if ([string]::IsNullOrWhiteSpace($OutputText)) {
        return 'Unknown'
    }
    if ($OutputText -match '(?i)connection refused') {
        return 'Connection refused'
    }
    if ($OutputText -match '(?i)(timed out|timeout expired)') {
        return 'Connection timeout'
    }
    if ($OutputText -match '(?i)authentication failed') {
        return 'Authentication failure'
    }
    if ($OutputText -match 'database "[^"]*" does not exist') {
        return 'Database not found'
    }
    if ($OutputText -match '(?i)(extension "postgis" is not available|could not open extension control file)') {
        return 'Extension missing'
    }
    if ($OutputText -match '(?i)error:') {
        return 'Unexpected PostgreSQL error'
    }
    return 'Unknown'
}

function Test-PostGISAvailable {
    <#
      The functional definition of "PostGIS is installed" for this phase:
      CREATE EXTENSION IF NOT EXISTS postgis; followed by
      SELECT PostGIS_Full_Version(); against the instance's default
      postgres database, via psql, non-interactively. Deliberately the
      same function serves as both the idempotency check (called before
      installing anything) and the post-install validation (called
      after) - for PostGIS, "installed" only means something if it's
      actually usable, so there's no weaker file-existence signal worth
      trusting on its own. See docs/08-development-roadmap.md Phase 2B.

      Diagnostic logging (connection parameters, the exact psql command,
      exit code, stdout, stderr, and - on failure - a classified reason
      via Get-PostGISFailureReason) is unconditional, on every call,
      success or failure alike - added specifically so a future
      integration failure at either call site (the pre-install
      idempotency check or the post-install validation, Install-PostGIS
      above) leaves a complete, unambiguous record in the installer's
      own log instead of needing to be reconstructed after the fact.
      This is observability only: nothing below changes what this
      function returns or how any caller behaves - $output/$exitCode are
      captured exactly as before, and $stdoutLines/$stderrLines are
      derived from that same already-captured data purely for logging
      (PowerShell tags 2>&1-merged native stderr lines as ErrorRecord
      objects, which is what makes them separable from stdout after the
      fact without capturing the two streams differently).
    #>
    param(
        [Parameter(Mandatory)][string]$PsqlPath,
        [Parameter(Mandatory)][SecureString]$SuperuserPassword
    )

    Write-Detail 'Connection:'
    Write-Detail "  Host: $Script:PostgresHost"
    Write-Detail "  Port: $Script:PostgresPort"
    Write-Detail '  Database: postgres'
    Write-Detail "  Username: $Script:PostgresSuperuser"
    Write-Host ''

    $commandDisplay = "$PsqlPath -U $Script:PostgresSuperuser -h $Script:PostgresHost -p $Script:PostgresPort -d postgres --set ON_ERROR_STOP=on --tuples-only --no-align -c `"CREATE EXTENSION IF NOT EXISTS postgis;`" -c `"SELECT PostGIS_Full_Version();`""
    Write-Detail "Command: $commandDisplay"
    Write-Detail 'Password: supplied via PGPASSWORD environment variable (not shown, not part of the command line)'

    $plainPassword = ConvertTo-PlainText -SecureString $SuperuserPassword
    $previousPgPassword = $env:PGPASSWORD
    # psql writes routine NOTICE-level messages to stderr (e.g. "extension
    # postgis already exists, skipping" on every idempotent re-run) - under
    # this script's global $ErrorActionPreference = 'Stop', capturing
    # native stderr via 2>&1 would otherwise turn that routine notice into
    # a terminating error. Scope EAP down to 'Continue' for just this call
    # so the text is still captured (useful on real failures too) without
    # crashing the idempotency check on the common, expected path.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $env:PGPASSWORD = $plainPassword
        $output = & $PsqlPath -U $Script:PostgresSuperuser -h $Script:PostgresHost -p $Script:PostgresPort -d 'postgres' `
            --set ON_ERROR_STOP=on --tuples-only --no-align `
            -c 'CREATE EXTENSION IF NOT EXISTS postgis;' `
            -c 'SELECT PostGIS_Full_Version();' 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($null -eq $previousPgPassword) {
            Remove-Item -Path Env:\PGPASSWORD -ErrorAction SilentlyContinue
        }
        else {
            $env:PGPASSWORD = $previousPgPassword
        }
        $plainPassword = $null
    }

    # Derived purely for logging - see this function's own header. Native
    # stderr lines merged via 2>&1 arrive as ErrorRecord objects; plain
    # stdout lines arrive as strings. $output/$exitCode themselves (used
    # by every check below) are untouched by this.
    $stdoutLines = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $stderrLines = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })

    Write-Detail "Exit code: $exitCode"
    Write-Detail "Stdout: $(if ($stdoutLines.Count -gt 0) { ($stdoutLines -join ' | ') } else { '(empty)' })"
    Write-Detail "Stderr: $(if ($stderrLines.Count -gt 0) { ($stderrLines -join ' | ') } else { '(empty)' })"

    $outputText = ($output | Out-String).Trim()
    if ($exitCode -ne 0) {
        $failureReason = Get-PostGISFailureReason -ExitCode $exitCode -OutputText $outputText
        Write-Detail "Failure reason: $failureReason"
        return [PSCustomObject]@{ Available = $false; VersionString = $null; ErrorMessage = $outputText; FailureReason = $failureReason }
    }

    $versionLine = $output | Where-Object { $_ -match 'POSTGIS=' } | Select-Object -First 1
    if (-not $versionLine) {
        $failureReason = Get-PostGISFailureReason -ExitCode $exitCode -OutputText $outputText
        Write-Detail "Failure reason: $failureReason"
        return [PSCustomObject]@{ Available = $false; VersionString = $null; ErrorMessage = $outputText; FailureReason = $failureReason }
    }

    return [PSCustomObject]@{ Available = $true; VersionString = $versionLine.Trim(); ErrorMessage = $null; FailureReason = $null }
}

# ---------------------------------------------------------------------------
# PostGIS download
# ---------------------------------------------------------------------------

function Get-PostGISInstaller {
    <#
      Returns a cached PostGIS bundle installer from $DestinationDirectory
      if one is already present, downloading it only when missing - same
      caching contract as Get-NodeInstaller/Get-PostgresInstaller. The
      bundle is versioned per PostgreSQL major version; see
      $Script:PostGISDownloadUrl above.
    #>
    param([Parameter(Mandatory)][string]$DestinationDirectory)

    if (-not (Test-Path -Path $DestinationDirectory)) {
        New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null
    }

    $installerPath = Join-Path -Path $DestinationDirectory -ChildPath "postgis-bundle-pg$($Script:RequiredPostgresMajorVersion)x64-setup-$($Script:RequiredPostGISVersion)-$($Script:RequiredPostGISBuild).exe"

    if (Test-Path -Path $installerPath) {
        Write-Step 'Using cached PostGIS installer...'
        Write-Detail "Cache: $installerPath"
        return $installerPath
    }

    Write-Step "Downloading PostGIS $($Script:RequiredPostGISVersion) installer..."
    Write-Detail "Source: $($Script:PostGISDownloadUrl)"
    Write-Detail "Target: $installerPath"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Script:PostGISDownloadUrl -OutFile $installerPath -UseBasicParsing
    }
    catch {
        Stop-Setup "Failed to download the PostGIS installer from $($Script:PostGISDownloadUrl): $($_.Exception.Message)"
    }

    if (-not (Test-Path -Path $installerPath) -or (Get-Item -Path $installerPath).Length -eq 0) {
        Stop-Setup "Download reported success but the installer file is missing or empty: $installerPath"
    }

    Write-Success '    Download complete.'
    return $installerPath
}

function Test-PostGISInstallerIntegrity {
    <#
      Verifies the cached/downloaded installer against the official MD5
      checksum PostGIS publishes alongside each release - unlike the main
      PostgreSQL installer, which publishes none at all (see
      docs/06-deployment-risks.md). Missing checksum file: skipped, not a
      failure (matches requirement: verify "if official checksums are
      available"). A checksum that WAS fetched but doesn't match is
      always fatal - never execute a binary that fails a check that was
      actually performed.
    #>
    param([Parameter(Mandatory)][string]$InstallerPath)

    Write-Step 'Verifying installer checksum...'

    try {
        $response = Invoke-WebRequest -Uri $Script:PostGISChecksumUrl -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Detail "Checksum file not available at $($Script:PostGISChecksumUrl) - skipping integrity verification."
        return
    }

    # The .md5 file is served as application/octet-stream, which makes
    # Invoke-WebRequest's .Content a byte[] rather than a string, even with
    # -UseBasicParsing - decode explicitly rather than let -split coerce
    # the byte array into its (wrong) default string representation.
    $rawContent = $response.Content
    if ($rawContent -is [byte[]]) {
        $rawContent = [System.Text.Encoding]::UTF8.GetString($rawContent)
    }

    $expectedHash = (($rawContent -split '\s+') | Where-Object { $_ } | Select-Object -First 1).ToUpperInvariant()
    $actualHash = (Get-FileHash -Path $InstallerPath -Algorithm MD5).Hash.ToUpperInvariant()

    if ($expectedHash -ne $actualHash) {
        Stop-Setup "PostGIS installer checksum mismatch for $InstallerPath. Expected $expectedHash but computed $actualHash. Delete the cached file and re-run to force a fresh download."
    }

    Write-Success '    Checksum verified.'
}

# ---------------------------------------------------------------------------
# PostGIS install
# ---------------------------------------------------------------------------

function Install-PostGISBundle {
    <#
      Runs the standalone PostGIS bundle installer's NSIS silent mode
      (/S). A different installer technology from both Install-NodeMsi
      (MSI) and Install-PostgresServer (BitRock/InstallBuilder) - verified
      directly by running it during the Phase 2B review: no window
      appears, and it auto-detects the target PostgreSQL installation via
      registry rather than needing --prefix/--datadir-style arguments.
      Like the PostgreSQL installer, NSIS documents no exit-code table
      beyond "0 = success", so any non-zero code is an unconditional
      failure here.
    #>
    param([Parameter(Mandatory)][string]$InstallerPath)

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to install PostGIS. Re-run this script from an elevated PowerShell session.'
    }

    Write-Step 'Installing PostGIS (silent install)...'
    Write-Detail 'This may take several minutes.'

    $process = Start-ProcessWithActivityIndicator -FilePath $InstallerPath -ArgumentList '/S' -ActivityName 'Installing PostGIS'

    if ($process.ExitCode -ne 0) {
        Stop-Setup "The PostGIS installer returned exit code $($process.ExitCode)."
    }

    Write-Success '    Installer reported success (exit code 0).'
}

# ---------------------------------------------------------------------------
# Phase 2B entry point
# ---------------------------------------------------------------------------

function Install-PostGIS {
    <#
      Phase 2B of the DELTA installer: makes the PostGIS extension usable
      against the PostgreSQL instance installed in Phase 2A. Idempotent:
      if CREATE EXTENSION postgis already succeeds, this returns
      immediately without downloading or installing anything.

      Does NOT create or initialize DELTA's own database - that's
      Phase 2C, kept deliberately separate (see docs/08-development-
      roadmap.md for why 2A/2B/2C are split rather than one phase).
      Validation runs against the instance's default "postgres" database
      only, so this phase stays fully self-contained regardless of
      whether Phase 2C has ever run.
    #>

    Write-PhaseBanner 'Phase 2B - PostGIS'

    $existing = Find-PostgresInstallation
    if (-not $existing.Found -or -not $existing.PsqlPath) {
        Stop-Setup 'No usable PostgreSQL installation was found. Run Phase 2A (Install-PostgreSql) first.'
    }

    Write-Step 'Checking whether PostGIS is already usable...'
    $superuserPassword = Get-CachedPostgresSuperuserPassword
    $check = Test-PostGISAvailable -PsqlPath $existing.PsqlPath -SuperuserPassword $superuserPassword

    if ($check.Available) {
        Write-Host ''
        Write-Host 'PostGIS detected.'
        Write-Host ''
        Write-Host 'Version:'
        Write-Host $check.VersionString
        Write-Host ''
        Write-Host 'Status:'
        Write-Host 'Already installed and usable.'
        Write-Host ''
        Write-Host 'Skipping installation.'
        return
    }

    Write-Detail 'PostGIS is not yet usable on this instance.'
    Write-Host ''

    $installerPath = Get-PostGISInstaller -DestinationDirectory $Script:InstallersDirectory
    Test-PostGISInstallerIntegrity -InstallerPath $installerPath
    Install-PostGISBundle -InstallerPath $installerPath

    Write-Step 'Validating installation...'
    $confirmed = Test-PostGISAvailable -PsqlPath $existing.PsqlPath -SuperuserPassword $superuserPassword

    if (-not $confirmed.Available) {
        Stop-Setup "PostGIS installation appeared to succeed, but CREATE EXTENSION / PostGIS_Full_Version() still failed ($($confirmed.FailureReason)): $($confirmed.ErrorMessage)"
    }

    Write-Host ''
    Write-Success 'PostGIS successfully installed.'
    Write-Host ''
    Write-Host 'Version:'
    Write-Host $confirmed.VersionString
}

# ---------------------------------------------------------------------------
# DELTA runtime deployment
# ---------------------------------------------------------------------------

function Install-DeltaRuntime {
    <#
      Deploys the dts_shared_binary artifact - shipped inside this
      installer repository at $Script:DeltaRuntimeSourceDirectory - into
      $Script:DeltaRuntimeRoot (the operator-chosen application
      directory resolved by Resolve-DeltaAppRoot, C:\DELTA by default),
      the separate directory DELTA actually runs from. This is a
      deliberate split: the installer repository is installer code only,
      never the running application, so nothing downstream (the .env
      file, the database schema/upgrade SQL, a future Windows Service
      working directory) should ever point back inside the installer
      repository - see lib\DeltaInstaller.Common.ps1 for why the
      *default* is a fixed constant rather than derived from
      $PSScriptRoot, even though the actual value now comes from a
      prompt rather than being fixed itself.

      dts_shared_binary's contents become $Script:DeltaRuntimeRoot's
      contents directly (not nested under a further "dts_shared_binary"
      subfolder) - this matches how the artifact was always documented
      to be used: see docs/00-overview.md and docs/02-windows-
      installation.md, both of which treat "unpack dts_shared_binary" as
      producing the install root itself, not a subfolder of it.

      The *.sh files (init_db.sh, init_website.sh, start.sh,
      upgrade_database.sh) are deliberately excluded - see the runtime
      review in this refactor's validation notes: they cannot execute on
      Windows at all, and init_db.sh/upgrade_database.sh are fully
      replaced by this project's own init_db.ps1/upgrade_database.ps1.
      Everything else (dts_database\, the compiled build\, locales\,
      package.json, the .bat scripts) is still needed and is copied as-is.

      Idempotent by construction: dts_shared_binary never contains an
      "uploads" or "logs" directory, so re-running this (e.g. on a
      repeat setup.ps1 invocation) only ever overwrites files that also
      exist in the source artifact - it never touches runtime-generated
      state that may already exist in the target directory.

      dts_shared_binary IS confirmed to ship its own .env (a development
      example, committed upstream for local dev use - not this
      installer's deployment config) - a false assumption in an earlier
      version of this comment. That file is deliberately stripped from
      $Script:DeltaRuntimeRoot immediately after the copy below, the
      same way *.sh files already are: the runtime artifact is
      application code only and must never determine or override
      deployment configuration. <installer root>\.env.example
      ($Script:EnvTemplatePath) is the only template New-
      DeltaEnvironmentFile is ever meant to read - without this
      stripping step, that artifact-shipped .env would already exist at
      the target by the time New-DeltaEnvironmentFile runs (this
      function always runs first), so its own "does .env already exist"
      check would find it and preserve it instead of ever generating
      from the real template - confirmed as the actual root cause of a
      real reported bug.
    #>

    Write-PhaseBanner 'DELTA Runtime Deployment'

    if (-not (Test-Path -LiteralPath $Script:DeltaRuntimeSourceDirectory)) {
        Stop-Setup "DELTA artifact source not found: $($Script:DeltaRuntimeSourceDirectory)"
    }

    if (-not (Test-Path -LiteralPath $Script:DeltaRuntimeRoot)) {
        if (-not (Test-IsAdministrator)) {
            Stop-Setup "Administrator privileges are required to create $($Script:DeltaRuntimeRoot). Re-run this script from an elevated PowerShell session."
        }
        New-Item -Path $Script:DeltaRuntimeRoot -ItemType Directory -Force | Out-Null
    }

    Write-Step "Deploying DELTA runtime to $($Script:DeltaRuntimeRoot)..."

    # dts_shared_binary ships its own .env (application code's local-dev
    # example, not this installer's deployment config) - Copy-Item -Force
    # below would otherwise silently overwrite an operator's real,
    # already-generated .env with it (Force means "overwrite whatever's
    # already at the destination"), on every single re-run, not just a
    # fresh install. Moved aside first, and restored exactly afterward,
    # so the copy has nothing of the operator's to clobber at that path
    # in the first place - the runtime artifact must never determine or
    # override deployment configuration, fresh install or upgrade alike.
    $envTargetPath = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath '.env'
    $preservedEnvPath = $null
    if (Test-Path -LiteralPath $envTargetPath) {
        $preservedEnvPath = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath '.env.installer-preserved-tmp'
        Move-Item -LiteralPath $envTargetPath -Destination $preservedEnvPath -Force
    }

    Copy-Item -Path (Join-Path -Path $Script:DeltaRuntimeSourceDirectory -ChildPath '*') `
        -Destination $Script:DeltaRuntimeRoot -Recurse -Force

    Get-ChildItem -Path $Script:DeltaRuntimeRoot -Filter '*.sh' -Recurse -File |
        Remove-Item -Force

    # Whatever the copy just placed at these names is runtime-artifact
    # content (dts_shared_binary's own .env, and .env.example in case a
    # future release ships one) - never a legitimate deployment config,
    # so it's removed unconditionally. The operator's real .env, if any,
    # was already moved safely out of the way above and is restored next.
    foreach ($strayEnvFile in @('.env', '.env.example')) {
        $strayEnvPath = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath $strayEnvFile
        if (Test-Path -LiteralPath $strayEnvPath) {
            Remove-Item -LiteralPath $strayEnvPath -Force
        }
    }

    if ($preservedEnvPath) {
        Move-Item -LiteralPath $preservedEnvPath -Destination $envTargetPath -Force
    }

    $schemaFile = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'dts_database\dts_db_schema.sql'
    if (-not (Test-Path -LiteralPath $schemaFile)) {
        Stop-Setup "DELTA runtime deployment appeared to succeed, but the schema file was not found afterward: $schemaFile"
    }

    Write-Success '    DELTA runtime deployed.'
    Write-Detail "Location: $($Script:DeltaRuntimeRoot)"
}

# ---------------------------------------------------------------------------
# DELTA runtime directories
# ---------------------------------------------------------------------------

function New-DeltaRuntimeDirectory {
    <#
      Creates $DirectoryPath if it doesn't already exist - idempotent by
      construction (Test-Path guard), so a repeat setup.ps1 run never
      fails or resets anything just because uploads/logs already exist
      and already have real content in them from a previous run.
    #>
    param([Parameter(Mandatory)][string]$DirectoryPath)

    if (Test-Path -LiteralPath $DirectoryPath) {
        Write-Detail "Already exists: $DirectoryPath"
        return
    }

    New-Item -Path $DirectoryPath -ItemType Directory -Force | Out-Null
    Write-Detail "Created: $DirectoryPath"
}

function Grant-DeltaRuntimeDirectoryPermission {
    <#
      Grants Modify permission on $DirectoryPath, inherited to child
      files and folders ((OI)(CI) - Object Inherit, Container Inherit),
      to the account that will actually execute the DELTA Node.js
      runtime. Phase 5 (Windows Service) doesn't exist yet, so there is
      no dedicated service account configured anywhere in this installer
      today - per this feature's own design goal (never hardcode a
      specific account like Administrator), permissions are granted to
      whichever account is actually running this installer right now
      (WindowsIdentity.GetCurrent()), which is also the account that
      will run start.bat manually for this validation phase. Revisit
      once Phase 5 introduces an actual dedicated service account to
      grant this to instead - see docs/08 for the open item.

      /T re-applies recursively to anything already inside the
      directory (a no-op on a freshly created empty one, but keeps this
      correct if ever re-run against a directory that already has real
      uploads/log files in it) and /C continues past any individual
      file-level error rather than aborting the whole grant - the
      overall exit code is still checked afterward.
    #>
    param([Parameter(Mandatory)][string]$DirectoryPath)

    $account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    Write-Detail "Granting Modify permission to '$account' on $DirectoryPath (inherited to child items)..."
    $output = & icacls.exe $DirectoryPath /grant "${account}:(OI)(CI)M" /T /C 2>&1
    if ($LASTEXITCODE -ne 0) {
        Stop-Setup "Failed to grant permissions on $DirectoryPath for '$account': $(($output | Out-String).Trim())"
    }
}

function Test-DeltaRuntimeDirectoryWritable {
    <#
      Proves $DirectoryPath is actually writable by creating a real
      temporary file, writing to it, reading the content back, then
      deleting it - a functional check, not an ACL inspection, so a
      permission problem is caught here, during installation, rather
      than during the application's first upload or log write. Throws
      via Stop-Setup with a clear, specific message identifying exactly
      which directory failed, per this feature's own requirement.
    #>
    param([Parameter(Mandatory)][string]$DirectoryPath)

    $testFilePath = Join-Path -Path $DirectoryPath -ChildPath ".delta-write-test-$([guid]::NewGuid().ToString('N')).tmp"
    $testContent = 'delta-installer-write-check'

    try {
        Set-Content -LiteralPath $testFilePath -Value $testContent -ErrorAction Stop
        $readBack = Get-Content -LiteralPath $testFilePath -ErrorAction Stop
        if (($readBack | Select-Object -First 1) -ne $testContent) {
            Stop-Setup "Write validation failed for $DirectoryPath - a test file was created but its content could not be read back correctly."
        }
    }
    catch {
        Stop-Setup "Directory is not writable: $DirectoryPath. $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $testFilePath -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-DeltaRuntimeDirectories {
    <#
      Creates the runtime-writable directories the application resolves
      relative to its own working directory at runtime - uploads/ and
      logs/, confirmed by source code audit (the application never
      assumes a fixed C:\DELTA path; it resolves everything from
      process.cwd(), which is $Script:DeltaRuntimeRoot regardless of
      what the operator chose it to be). Grants write access to the
      account that will run it, then proves that access actually works
      before installation is considered complete, rather than
      discovering a permissions problem at the first real upload or log
      write.

      Deliberately does NOT create a "public" directory - see docs/01
      (Static asset serving) for why the application doesn't need one;
      the same source audit that identified uploads/logs/translations/
      markdown content as cwd-relative did not identify any requirement
      for one.
    #>
    Write-PhaseBanner 'DELTA Runtime Directories'

    $directories = @(
        (Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'uploads'),
        (Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'logs')
    )

    foreach ($directory in $directories) {
        Write-Step "Preparing $directory..."
        New-DeltaRuntimeDirectory -DirectoryPath $directory
        Grant-DeltaRuntimeDirectoryPermission -DirectoryPath $directory
        Test-DeltaRuntimeDirectoryWritable -DirectoryPath $directory
        Write-Success "    Ready and writable: $directory"
    }
}

# ---------------------------------------------------------------------------
# DELTA database + environment
# ---------------------------------------------------------------------------

function Read-DeltaDatabaseName {
    <#
      Prompts for the DELTA database name, defaulting to
      $Script:DefaultDeltaDatabaseName ("dts_db") on a bare Enter - same
      prompt-with-suggested-default shape as Resolve-PostgresPort.
    #>
    $entered = Read-Host -Prompt "Enter the DELTA database name [$($Script:DefaultDeltaDatabaseName)]"
    if ([string]::IsNullOrWhiteSpace($entered)) {
        return $Script:DefaultDeltaDatabaseName
    }
    return $entered.Trim()
}

function Resolve-DeltaEnvironmentTemplatePath {
    <#
      The priority order for which template New-DeltaEnvironmentFile
      reads when it needs to generate .env from scratch:

        1. <installer root>\.env.example ($Script:EnvTemplatePath) -
           the authoritative deployment template, always preferred when
           present.
        2. <dts_shared_binary source>\.env
           ($Script:DeltaRuntimeSourceDirectory\.env) - fallback only,
           for dts_shared_binary being used entirely outside this
           Windows installer (no .env.example shipped alongside it at
           all). This is the installer repository's own copy of the
           artifact, not the deployed copy under $Script:DeltaRuntimeRoot
           - Install-DeltaRuntime deliberately strips the runtime
           artifact's .env from the deployed copy on every run (see its
           own header) precisely so the runtime artifact can never
           silently determine deployment configuration there; this
           fallback is a distinct, explicit, last-resort case, not a
           reversal of that.

      Returns a PSCustomObject with Path and IsFallback, or stops the
      installer outright (Stop-Setup) with both checked paths named if
      neither template exists - never a silent, ambiguous default.
    #>
    if (Test-Path -LiteralPath $Script:EnvTemplatePath) {
        return [PSCustomObject]@{ Path = $Script:EnvTemplatePath; IsFallback = $false }
    }

    $fallbackTemplatePath = Join-Path -Path $Script:DeltaRuntimeSourceDirectory -ChildPath '.env'
    if (Test-Path -LiteralPath $fallbackTemplatePath) {
        return [PSCustomObject]@{ Path = $fallbackTemplatePath; IsFallback = $true }
    }

    Stop-Setup "No configuration template could be found. Checked the installer template ($($Script:EnvTemplatePath)) and the runtime artifact fallback ($fallbackTemplatePath). Cannot generate the environment file."
}

function New-DeltaEnvironmentFile {
    <#
      Generates <AppRoot>\.env (the deployed runtime directory - see
      Install-DeltaRuntime) from a template - resolved by Resolve-
      DeltaEnvironmentTemplatePath, .env.example preferred, the runtime
      artifact's own .env as a last-resort fallback, see that function's
      own header - or updates it in place if a .env already exists
      there, or, when -ForceRegenerateFromTemplate is set (Resolve-
      ExistingDeltaDeployment's "Recreate" lifecycle choice), always
      regenerates from that resolved template even though a .env
      already exists. An existing .env is always backed up (timestamped
      copy) before any write, in every one of those cases.

      Architecture: .env.example is the single source of truth for the
      application's default configuration - EMAIL_TRANSPORT, SMTP_*,
      SSO_*, AUTHENTICATION_SUPPORTED, SUPPORT_URL, SESSION_SECRET,
      every current and future default the application ships with. This
      installer's own job is narrower than "generate .env": it only ever
      overwrites the specific, named variables IT is actually
      responsible for supplying - $Script:DeltaManagedEnvironmentValues,
      built below from values this run collected or determined (right
      now: just DATABASE_URL, from the PostgreSQL connection info this
      script resolved). Every other line - regardless of what it is, or
      whether a future .env.example adds entirely new variables this
      installer has never heard of - passes through completely
      unmodified. That's what keeps .env.example authoritative for
      defaults: a new default added there shows up correctly in the
      next fresh install without this function needing to change at
      all, and this installer can never silently overwrite an
      application setting (feature flags, auth config, logging
      behavior, security settings, anything) it was never asked to
      manage.

      Adding a future installer-managed value (the parameter doc
      mentions PORT as a likely future example) means adding one more
      key to $managedValues below - never a new bespoke match/replace
      branch - since Update-ManagedEnvironmentLines already applies to
      every entry in that table generically.

      The "read the existing .env, else fall back to the template" dual
      source is orthogonal to that architecture, not an exception to
      it: once a real .env exists at the target, it - not .env.example
      - is this specific deployment's source of truth by default (it
      may already carry operator customizations: real SMTP credentials,
      a non-default SESSION_SECRET, SSO configuration), so re-running
      this installer against it must never silently reset those back to
      template defaults UNLESS the operator explicitly asked for that
      via the "Recreate" lifecycle choice (-ForceRegenerateFromTemplate)
      - an explicit, visible decision at that prompt, never an implicit
      side effect of merely re-running setup.ps1. Whichever path runs,
      the exact same managed-values table and the exact same generic
      replace mechanism apply - installer-managed variables get
      updated, everything else is left exactly as it already was in
      whichever file this run reads it from.

      The target path is computed here, from $Script:DeltaRuntimeRoot,
      rather than read from a precomputed module-level constant - by
      the time this runs, Resolve-DeltaAppRoot has already resolved the
      operator's actual choice, so reading it fresh here is what keeps
      this correct regardless of what that choice was.

      Never logs $DatabaseUrl or any part of it - only file paths are
      written to the console. $DatabaseUrl itself already came from
      New-DatabaseUrl, which only ever returns it as a value to be
      written to a file, never printed.
    #>
    param(
        [Parameter(Mandatory)][string]$DatabaseUrl,
        [switch]$ForceRegenerateFromTemplate
    )

    Write-Step 'Configuring application environment...'

    $envTargetPath = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath '.env'

    $targetDirectory = Split-Path -Path $envTargetPath -Parent
    if (-not (Test-Path -Path $targetDirectory)) {
        Stop-Setup "DELTA runtime directory not found: $targetDirectory. Run Install-DeltaRuntime first."
    }

    # A pre-existing .env is always backed up before this function writes
    # anything, regardless of which branch below actually reads it back
    # in - including when -ForceRegenerateFromTemplate means its content
    # won't be reused at all, since "backed up" and "reused as the
    # source" are two different guarantees and the Recreate lifecycle
    # choice explicitly asks for exactly that combination (Option 2:
    # "Backup existing .env" + "Generate a new .env from .env.example").
    $targetExists = Test-Path -LiteralPath $envTargetPath
    if ($targetExists) {
        $backupPath = "$envTargetPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $envTargetPath -Destination $backupPath -Force
        Write-Detail "Existing .env backed up to: $backupPath"
    }

    $sourceLines = $null
    if ($ForceRegenerateFromTemplate -or -not $targetExists) {
        $template = Resolve-DeltaEnvironmentTemplatePath

        Write-Host ''
        Write-Host $(if ($template.IsFallback) { 'Using fallback configuration template:' } else { 'Using configuration template:' })
        Write-Host $template.Path
        Write-Host ''

        $sourceLines = Get-Content -LiteralPath $template.Path
    }
    else {
        $sourceLines = Get-Content -LiteralPath $envTargetPath
    }

    # The complete, explicit set of variables this installer is allowed to
    # write - never anything else. Ordered so a freshly-appended variable
    # (one absent from the source file entirely) lands in a stable,
    # predictable sequence rather than whatever order a hashtable would
    # otherwise enumerate in.
    $managedValues = [ordered]@{
        DATABASE_URL = $DatabaseUrl
    }

    $updatedLines = Update-ManagedEnvironmentLines -SourceLines $sourceLines -ManagedValues $managedValues

    Set-Content -LiteralPath $envTargetPath -Value $updatedLines -Encoding utf8

    Write-Success '    Environment file ready.'
    Write-Detail "Location: $envTargetPath"
}

function Update-ManagedEnvironmentLines {
    <#
      The generic mechanism New-DeltaEnvironmentFile's architecture
      depends on: given the lines of a .env/.env.example file and an
      ordered table of installer-managed KEY = value pairs, returns the
      same lines with only those specific keys' lines replaced (or
      appended, for a key not already present in the source at all) -
      every other line passed through byte-for-byte unmodified,
      including its original quoting style, comments, and blank lines.
      Deliberately the only place in this installer that ever decides
      "which .env lines am I allowed to change" - New-DeltaEnvironmentFile
      never matches or replaces a variable itself, so there is exactly
      one mechanism to audit for that guarantee, not one per variable.
    #>
    param(
        [AllowEmptyCollection()][string[]]$SourceLines,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$ManagedValues
    )

    # Which managed keys were actually found (and replaced) in the source
    # file - tracked with a plain hashtable rather than removing from a
    # copy of $ManagedValues.Keys, since OrderedDictionary's Keys
    # collection is only a non-generic ICollection and isn't something
    # PowerShell can hand straight to a typed generic collection.
    $foundKeys = @{}

    $updatedLines = foreach ($line in $SourceLines) {
        $matchedKey = $null
        foreach ($key in $ManagedValues.Keys) {
            if ($line -match "^\s*$([regex]::Escape($key))\s*=") {
                $matchedKey = $key
                break
            }
        }

        if ($matchedKey) {
            $foundKeys[$matchedKey] = $true
            "$matchedKey=`"$($ManagedValues[$matchedKey])`""
        }
        else {
            $line
        }
    }

    # Any managed key never found in the source file at all (a brand new
    # installer-managed variable that .env.example doesn't define yet, or
    # an existing .env predating it) is appended rather than silently
    # dropped - matches the original single-variable behavior this
    # generalizes, just for however many managed keys there are now.
    # $ManagedValues.Keys (not $foundKeys) drives this loop so append
    # order always matches the table's own declared, stable order.
    foreach ($key in $ManagedValues.Keys) {
        if (-not $foundKeys.ContainsKey($key)) {
            $updatedLines = @($updatedLines) + "$key=`"$($ManagedValues[$key])`""
        }
    }

    return $updatedLines
}

function Invoke-DeltaDatabaseInit {
    <#
      Invokes init_db.ps1 as a sibling script via the call operator (&) -
      not Start-Process, and not dot-sourced. This keeps the SecureString
      password an in-memory object reference passed directly into the
      child script's own scope: never serialized to a command line,
      never written to disk, never a new OS process. Two things were
      verified empirically before choosing this design: a SecureString
      passed via & arrives in the child as a real System.Security.
      SecureString (not a plaintext string); and the child script's own
      `exit` terminates only its own execution, not this process - so
      init_db.ps1's own top-level try/catch/exit is fully independent of
      this one.

      init_db.ps1 owns all the actual database-initialization logic;
      this function only supplies the connection values setup.ps1
      already has, so nothing here duplicates what init_db.ps1 does.
    #>
    param(
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][SecureString]$SuperuserPassword
    )

    Write-Step 'Initializing the DELTA database...'

    $initScriptPath = Join-Path -Path $Script:ProjectRoot -ChildPath 'init_db.ps1'
    if (-not (Test-Path -LiteralPath $initScriptPath)) {
        Stop-Setup "init_db.ps1 not found at $initScriptPath."
    }

    & $initScriptPath `
        -PostgresHost $Script:PostgresHost `
        -Port $Script:PostgresPort `
        -Username $Script:PostgresSuperuser `
        -Password $SuperuserPassword `
        -DatabaseName $DatabaseName `
        -AppRoot $Script:DeltaRuntimeRoot

    if ($LASTEXITCODE -ne 0) {
        Stop-Setup "Database initialization failed (init_db.ps1 exited with code $LASTEXITCODE). See its output above for details."
    }

    Write-Success '    DELTA database initialized.'
}

function Invoke-DeltaDatabaseUpgrade {
    <#
      Invokes upgrade_database.ps1 as a sibling script - same design as
      Invoke-DeltaDatabaseInit (call operator, SecureString passed by
      reference, independent top-level try/catch/exit in the child).
      Supplying -Password here selects upgrade_database.ps1's own Mode 1
      (non-interactive): it skips the "back up your database first" Y/N
      prompt it would otherwise show, since choosing "Upgrade" from
      Read-ExistingDeltaDatabaseChoice already was that confirmation.
    #>
    param(
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][SecureString]$SuperuserPassword
    )

    Write-Step 'Upgrading the DELTA database...'

    $upgradeScriptPath = Join-Path -Path $Script:ProjectRoot -ChildPath 'upgrade_database.ps1'
    if (-not (Test-Path -LiteralPath $upgradeScriptPath)) {
        Stop-Setup "upgrade_database.ps1 not found at $upgradeScriptPath."
    }

    & $upgradeScriptPath `
        -PostgresHost $Script:PostgresHost `
        -Port $Script:PostgresPort `
        -Username $Script:PostgresSuperuser `
        -Password $SuperuserPassword `
        -DatabaseName $DatabaseName `
        -AppRoot $Script:DeltaRuntimeRoot

    if ($LASTEXITCODE -ne 0) {
        Stop-Setup "Database upgrade failed (upgrade_database.ps1 exited with code $LASTEXITCODE). See its output above for details."
    }

    Write-Success '    DELTA database upgraded.'
}

function Test-DeltaDatabaseExists {
    <#
      Checks whether $DatabaseName already exists on the reused
      PostgreSQL instance, via a pg_database lookup against the
      instance's default "postgres" database - the only reliable,
      OS-agnostic way to answer this without assuming anything about
      what else lives on the server. $DatabaseName is operator-typed
      (Read-DeltaDatabaseName), so single quotes are escaped before it's
      interpolated into the SQL literal, the same defensive standard
      applied anywhere else in this project a value is built into a
      command string rather than passed as a driver parameter.
    #>
    param(
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][SecureString]$SuperuserPassword
    )

    $bin = Get-PostgresBinDirectory
    $psqlExe = Join-Path -Path $bin -ChildPath 'psql.exe'

    $escapedName = $DatabaseName.Replace("'", "''")
    $plainPassword = ConvertTo-PlainText -SecureString $SuperuserPassword
    $previousPgPassword = $env:PGPASSWORD
    $previousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $env:PGPASSWORD = $plainPassword
        $output = & $psqlExe -h $Script:PostgresHost -p $Script:PostgresPort -U $Script:PostgresSuperuser -d 'postgres' `
            --set ON_ERROR_STOP=on --tuples-only --no-align `
            -c "SELECT 1 FROM pg_database WHERE datname = '$escapedName';" 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousEap
        if ($null -eq $previousPgPassword) {
            Remove-Item -Path Env:\PGPASSWORD -ErrorAction SilentlyContinue
        }
        else {
            $env:PGPASSWORD = $previousPgPassword
        }
        $plainPassword = $null
    }

    if ($exitCode -ne 0) {
        Stop-Setup "Failed to check whether database '$DatabaseName' exists: $(($output | Out-String).Trim())"
    }

    return (($output | Out-String).Trim() -eq '1')
}

function Remove-DeltaDatabase {
    <#
      Drops $DatabaseName via dropdb.exe (--if-exists, so a race against
      something else dropping it concurrently isn't a hard failure) -
      only ever called from the "Recreate" branch of
      Complete-DatabaseSetupForExistingPostgres, immediately before
      Invoke-DeltaDatabaseInit recreates it from scratch.
    #>
    param(
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][SecureString]$SuperuserPassword
    )

    Write-Step "Dropping existing database '$DatabaseName'..."

    $bin = Get-PostgresBinDirectory
    $dropdbExe = Join-Path -Path $bin -ChildPath 'dropdb.exe'
    if (-not (Test-Path -LiteralPath $dropdbExe)) {
        Stop-Setup "Required PostgreSQL executable not found: $dropdbExe"
    }

    $plainPassword = ConvertTo-PlainText -SecureString $SuperuserPassword
    $previousPgPassword = $env:PGPASSWORD
    $previousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $env:PGPASSWORD = $plainPassword
        $output = & $dropdbExe -h $Script:PostgresHost -p $Script:PostgresPort -U $Script:PostgresSuperuser --if-exists $DatabaseName 2>&1
        if ($LASTEXITCODE -ne 0) {
            Stop-Setup "Failed to drop database '$DatabaseName': $(($output | Out-String).Trim())"
        }
    }
    finally {
        $ErrorActionPreference = $previousEap
        if ($null -eq $previousPgPassword) {
            Remove-Item -Path Env:\PGPASSWORD -ErrorAction SilentlyContinue
        }
        else {
            $env:PGPASSWORD = $previousPgPassword
        }
        $plainPassword = $null
    }

    Write-Success "    Database '$DatabaseName' dropped."
}

function Read-ExistingDeltaDatabaseChoice {
    <#
      Presents the recreate/upgrade/keep menu once an existing DELTA
      database has been confirmed on the reused PostgreSQL instance.
      Bare Enter defaults to "Keep" - unlike the PostgreSQL reuse
      prompt's recommended default, the safest default here is the
      least destructive one: recreate drops real data, so it should
      never be what a bare Enter does by accident.
    #>
    param([Parameter(Mandatory)][string]$DatabaseName)

    Write-Host ''
    Write-Host "An existing DELTA database named '$DatabaseName' was found."
    Write-Host ''
    Write-Host '1) Recreate the DELTA database (drops and re-initializes it)'
    Write-Host '2) Upgrade the existing DELTA database'
    Write-Host '3) Keep the existing DELTA database (no changes)'
    Write-Host ''

    while ($true) {
        $choice = Read-Host -Prompt 'Choose an option [3]'
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '3' }

        switch ($choice.Trim()) {
            '1' { return 'Recreate' }
            '2' { return 'Upgrade' }
            '3' { return 'Keep' }
        }
        Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow
    }
}

function Complete-DatabaseSetupForExistingPostgres {
    <#
      The reuse-aware counterpart to Complete-DatabaseSetup's original
      "always create fresh" flow - only reached when Install-PostgreSql
      recorded $Script:PostgresReuseMode. Design goal from this feature's
      spec: C:\DELTA\.env is always regenerated with the final connection
      information no matter which branch runs below, so that line runs
      once, after the if/else, rather than being duplicated in each branch.
    #>
    param(
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][SecureString]$SuperuserPassword
    )

    Write-Step "Checking whether database '$DatabaseName' already exists..."
    $exists = Test-DeltaDatabaseExists -DatabaseName $DatabaseName -SuperuserPassword $SuperuserPassword

    if (-not $exists) {
        Write-Detail "Database '$DatabaseName' does not exist yet on this PostgreSQL instance."
        Invoke-DeltaDatabaseInit -DatabaseName $DatabaseName -SuperuserPassword $SuperuserPassword
    }
    else {
        $choice = Read-ExistingDeltaDatabaseChoice -DatabaseName $DatabaseName

        switch ($choice) {
            'Recreate' {
                Remove-DeltaDatabase -DatabaseName $DatabaseName -SuperuserPassword $SuperuserPassword
                Invoke-DeltaDatabaseInit -DatabaseName $DatabaseName -SuperuserPassword $SuperuserPassword
            }
            'Upgrade' {
                Invoke-DeltaDatabaseUpgrade -DatabaseName $DatabaseName -SuperuserPassword $SuperuserPassword
            }
            'Keep' {
                Write-Detail "Leaving database '$DatabaseName' untouched."
            }
        }
    }

    $databaseUrl = New-DatabaseUrl -PostgresHost $Script:PostgresHost -Port $Script:PostgresPort `
        -Username $Script:PostgresSuperuser -Password $SuperuserPassword -DatabaseName $DatabaseName
    New-DeltaEnvironmentFile -DatabaseUrl $databaseUrl -ForceRegenerateFromTemplate:($Script:DeltaDeploymentLifecycle -eq 'Recreate')
}

function Complete-DatabaseSetup {
    <#
      The "ask for DELTA database name -> generate .env -> invoke
      init_db.ps1" stage of the target installation flow. Owns none of
      the actual database logic itself - init_db.ps1/upgrade_database.ps1
      do, invoked as sibling scripts rather than duplicated here. Reuses
      the PostgreSQL host/port/username/password Phase 2A already
      resolved; the DELTA database name is the only new value asked for.

      Branches on $Script:PostgresReuseMode (set by Install-PostgreSql):
      a fresh install provably has no DELTA database yet, so the
      original unconditional create-and-restore flow still applies
      there unchanged; a reused instance might already have one, which
      is what Complete-DatabaseSetupForExistingPostgres's
      recreate/upgrade/keep decision exists to handle.
    #>
    Write-PhaseBanner 'DELTA Database Setup'

    $deltaDatabaseName = Read-DeltaDatabaseName
    $superuserPassword = Get-CachedPostgresSuperuserPassword

    if ($Script:PostgresReuseMode) {
        Complete-DatabaseSetupForExistingPostgres -DatabaseName $deltaDatabaseName -SuperuserPassword $superuserPassword
        return
    }

    $databaseUrl = New-DatabaseUrl -PostgresHost $Script:PostgresHost -Port $Script:PostgresPort `
        -Username $Script:PostgresSuperuser -Password $superuserPassword -DatabaseName $deltaDatabaseName
    New-DeltaEnvironmentFile -DatabaseUrl $databaseUrl -ForceRegenerateFromTemplate:($Script:DeltaDeploymentLifecycle -eq 'Recreate')

    Invoke-DeltaDatabaseInit -DatabaseName $deltaDatabaseName -SuperuserPassword $superuserPassword
}

# ---------------------------------------------------------------------------
# DELTA runtime dependencies (Phase 3)
# ---------------------------------------------------------------------------

function Test-YarnAvailable {
    return [bool](Get-Command -Name 'yarn.cmd' -ErrorAction SilentlyContinue)
}

function Get-YarnGlobalBinDirectory {
    <#
      Resolves Yarn Classic's own global bin directory via `yarn global
      bin` - a different location from npm's global bin (%APPDATA%\npm,
      where `yarn` itself lands via `npm install --global yarn`, and
      which Node's own Windows installer already puts on the User PATH).
      This distinction is the entire reason dotenv-cli isn't resolvable
      after init_website.bat completes even though yarn itself is - see
      docs/06 - Installation tooling gaps. Returns $null (never throws)
      if Yarn isn't available or the command fails; callers treat that
      as "can't determine this yet," not a hard error.
    #>
    if (-not (Test-YarnAvailable)) {
        return $null
    }

    try {
        $output = & yarn global bin 2>$null
    }
    catch {
        return $null
    }
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return $null
    }

    return ($output | Select-Object -First 1).ToString().Trim()
}

function Test-DotenvCliAvailable {
    <#
      Checks whether dotenv-cli is actually present in Yarn's own global
      bin directory - not whether `dotenv` currently resolves on PATH,
      since that's exactly the thing Add-YarnGlobalBinToPersistentPath
      fixes independently of whether a (re-)install is actually needed.
    #>
    $yarnGlobalBin = Get-YarnGlobalBinDirectory
    if (-not $yarnGlobalBin) {
        return $false
    }

    $dotenvCmd = Join-Path -Path $yarnGlobalBin -ChildPath 'dotenv.cmd'
    return (Test-Path -LiteralPath $dotenvCmd)
}

function Test-DeltaRuntimeDependenciesInstalled {
    <#
      The idempotency check for this phase: true only if Yarn is
      resolvable, the DELTA runtime's own node_modules exists and is
      non-empty, and dotenv-cli is present in Yarn's global bin. All
      three have to hold for init_website.bat to be safely skippable -
      any one missing means something in the chain didn't complete.
    #>
    if (-not (Test-YarnAvailable)) {
        return $false
    }

    $nodeModulesPath = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'node_modules'
    if (-not (Test-Path -LiteralPath $nodeModulesPath)) {
        return $false
    }
    if (-not (Get-ChildItem -Path $nodeModulesPath -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        return $false
    }

    if (-not (Test-DotenvCliAvailable)) {
        return $false
    }

    return $true
}

function Invoke-DeltaWebsiteInit {
    <#
      Runs dts_shared_binary's init_website.bat - unmodified, exactly as
      shipped, with its existing error handling intact (see docs/06 -
      Installation tooling gaps for its known, pre-existing quoting/PATH
      issues, none of which this function works around). Two
      accommodations are made purely so it can run as one step of an
      otherwise unattended installer, neither of which touches its
      actual install logic or exit code:

        - -WorkingDirectory $Script:DeltaRuntimeRoot: `yarn install` and
          `yarn global add` both act on the current working directory,
          and init_website.bat itself never `cd`s anywhere (it was
          always meant to be run from inside the unpacked artifact) - so
          this MUST run with C:\DELTA as the working directory, or
          node_modules would silently land in the wrong place entirely.
        - -RedirectStandardInput from an empty file: init_website.bat
          ends in a bare `pause`, which would otherwise block waiting
          for a keypress that never comes. Start-Process's
          -RedirectStandardInput requires an actual file path (the
          literal device name 'NUL' is not accepted - confirmed
          directly: it fails with FileNotFoundException rather than
          being treated as the NUL device the way cmd.exe's own `<`
          redirection would), so an empty, zero-byte file is created for
          this purpose instead. Reading it gives `pause` an immediate
          EOF, which is enough for it to fall through without an
          operator present - it does not change what the script
          actually installs or how it reports failure.
    #>
    Write-Step 'Installing Yarn and application dependencies (init_website.bat)...'

    $initWebsitePath = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'init_website.bat'
    if (-not (Test-Path -LiteralPath $initWebsitePath)) {
        Stop-Setup "init_website.bat not found at $initWebsitePath."
    }

    $emptyStdinPath = Join-Path -Path $Script:WorkingDirectory -ChildPath 'empty.stdin'
    if (-not (Test-Path -LiteralPath $emptyStdinPath)) {
        New-Item -Path $emptyStdinPath -ItemType File -Force | Out-Null
    }

    $process = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$initWebsitePath`"" `
        -WorkingDirectory $Script:DeltaRuntimeRoot -RedirectStandardInput $emptyStdinPath -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -ne 0) {
        Stop-Setup "init_website.bat failed with exit code $($process.ExitCode). See its output above for details."
    }

    Write-Success '    Runtime dependencies installed.'
}

function Add-YarnGlobalBinToPersistentPath {
    <#
      Permanent fix for a confirmed gap - see docs/06 (Installation
      tooling gaps). Confirmed during end-to-end Windows validation: on
      a clean machine, dotenv-cli lands in Yarn Classic's own global bin
      (`yarn global bin`), which is neither npm's global bin (already on
      PATH via Node's installer) nor anywhere else this installer adds
      to PATH - so without this fix, `dotenv` failed to resolve not just
      in a brand-new session but in *any* session after the one
      init_website.bat originally ran in, including after a reboot -
      which is exactly what start.bat depends on
      (`dotenv -e .env -- yarn start`). A prior version of this function
      only ever updated $env:Path for the current process, which is why
      that gap survived past the run that installed dotenv-cli in the
      first place.

      Appends the Yarn global bin directory to the persistent *User*
      PATH environment variable (via
      [Environment]::SetEnvironmentVariable(...,'User'), the registry-
      backed value - not a passing $env:Path assignment) rather than
      Machine PATH: this doesn't require Administrator, and only the
      account running DELTA needs to resolve `dotenv`. Idempotent by
      construction: reads the current User PATH first (trailing
      backslashes and case ignored, matching how Windows itself treats
      PATH entries) and does nothing if the directory is already present,
      so repeat runs never accumulate duplicate entries.

      Finishes by calling Update-SessionEnvironmentPath (the same
      Machine+User PATH refresh already used right after the Node.js MSI
      install) so this same console - both the remainder of this
      setup.ps1 run and anything typed afterward - can resolve `dotenv`
      immediately, without needing a new shell.
    #>
    $yarnGlobalBin = Get-YarnGlobalBinDirectory
    if (-not $yarnGlobalBin) {
        Write-Detail 'Could not determine the Yarn global bin directory - skipping the dotenv-cli PATH fix.'
        return
    }
    $yarnGlobalBin = $yarnGlobalBin.TrimEnd('\')

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $userPathEntries = if ($userPath) { $userPath -split ';' | Where-Object { $_ } } else { @() }
    $alreadyPresent = $userPathEntries | Where-Object { $_.TrimEnd('\') -ieq $yarnGlobalBin } | Select-Object -First 1

    if ($alreadyPresent) {
        Write-Detail "Yarn global bin already on the persistent User PATH: $yarnGlobalBin"
    }
    else {
        $newUserPath = if ($userPath) { "$userPath;$yarnGlobalBin" } else { $yarnGlobalBin }
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        Write-Detail "Added Yarn global bin to the persistent User PATH: $yarnGlobalBin"
    }

    Update-SessionEnvironmentPath
}

function Install-DeltaDependencies {
    <#
      Phase 3 of the DELTA installer: Yarn, the application's own
      production dependencies, and dotenv-cli. Idempotent: if everything
      required is already present (Test-DeltaRuntimeDependenciesInstalled),
      init_website.bat is skipped entirely rather than re-run
      unconditionally, so a repeat setup.ps1 run doesn't pay for a fresh
      dependency install every time.

      The dotenv-cli PATH fix always runs after this regardless of
      whether init_website.bat itself ran - a *new* PowerShell session
      (this run) has no reason to already have Yarn's global bin on
      PATH even when dependencies were installed by an earlier run, and
      the fix itself (Add-YarnGlobalBinToPersistentPath) is idempotent
      either way.
    #>
    Write-PhaseBanner 'Phase 3 - DELTA Runtime Dependencies'

    if (Test-DeltaRuntimeDependenciesInstalled) {
        Write-Host ''
        Write-Host 'Runtime dependencies detected.'
        Write-Host ''
        Write-Host 'Status:'
        Write-Host 'Already installed.'
        Write-Host ''
        Write-Host 'Skipping init_website.bat.'
    }
    else {
        Write-Detail 'Runtime dependencies not fully present - running init_website.bat.'
        Write-Host ''
        Invoke-DeltaWebsiteInit
    }

    Add-YarnGlobalBinToPersistentPath
}

# ---------------------------------------------------------------------------
# DELTA runtime process management
# ---------------------------------------------------------------------------

function Get-RunningDeltaProcesses {
    <#
      Identifies the actual DELTA server process(es) - node.exe invoked
      with build\server\index.js from this specific runtime directory -
      rather than every node.exe on the machine. Matches on the
      resolved, absolute path to C:\DELTA\build\server\index.js
      appearing in the process's own command line: that's the literal
      argument react-router-serve is invoked with (see docs/01 - Static
      asset serving, and the NSSM example in docs/02), so an unrelated
      node.exe running some other application never matches this.
    #>
    $markerPath = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'build\server\index.js'
    $escapedMarker = [regex]::Escape($markerPath)

    $candidates = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue
    if (-not $candidates) {
        return @()
    }

    return @($candidates | Where-Object { $_.CommandLine -and ($_.CommandLine -match $escapedMarker) })
}

function Wait-ForProcessExit {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [int]$TimeoutSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return -not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Stop-RunningDeltaInstance {
    <#
      Stops any DELTA server process already running from this specific
      installation directory (Get-RunningDeltaProcesses), so a repeat
      setup.ps1 run never leaves two instances bound to the same port.
      Never touches any other node.exe process on the machine.

      Attempts a graceful stop first (`taskkill` without /F, which sends
      a close request the process can react to) and only escalates to a
      forceful kill if it hasn't exited within the grace period -
      Windows has no native SIGTERM, and this project's own findings
      (docs/06 - Windows Service shutdown behavior) already note that a
      clean shutdown handshake isn't guaranteed here regardless of
      method, so this makes a real attempt rather than jumping straight
      to a forceful kill.
    #>
    $processes = Get-RunningDeltaProcesses
    if (-not $processes -or $processes.Count -eq 0) {
        Write-Detail 'No running DELTA instance detected.'
        return
    }

    foreach ($proc in $processes) {
        Write-Step "Stopping existing DELTA instance (PID $($proc.ProcessId))..."

        & taskkill.exe /PID $proc.ProcessId | Out-Null
        if (-not (Wait-ForProcessExit -ProcessId $proc.ProcessId -TimeoutSeconds 10)) {
            Write-Detail "PID $($proc.ProcessId) did not exit gracefully within 10 seconds - forcing termination."
            & taskkill.exe /PID $proc.ProcessId /F | Out-Null

            if (-not (Wait-ForProcessExit -ProcessId $proc.ProcessId -TimeoutSeconds 10)) {
                Stop-Setup "Failed to stop the existing DELTA instance (PID $($proc.ProcessId)) even after forceful termination."
            }
        }

        Write-Success "    Stopped PID $($proc.ProcessId)."
    }
}

function Confirm-DeltaRuntimeNotRunning {
    <#
      Ensures no DELTA instance from a previous run is still bound to
      the application port before this run finishes - deliberately does
      NOT restart it: start.bat remains a manual, operator-run step for
      this validation phase (see the orchestration block below), so
      automatically starting anything here would contradict that.
    #>
    Write-PhaseBanner 'DELTA Runtime Status'
    Write-Step 'Checking for an already-running DELTA instance...'
    Stop-RunningDeltaInstance
}

function Initialize-Setup {
    Write-SetupBanner -Title 'DELTA Setup' -Subtitle 'Windows Deployment Installer'

    # Install logs live under %TEMP% (ephemeral, per-run detail); cached
    # installer binaries live under .\installers (persistent, see
    # $Script:InstallersDirectory) - each phase's Get-*Installer function
    # creates that one when it's first needed.
    if (-not (Test-Path -Path $Script:WorkingDirectory)) {
        New-Item -Path $Script:WorkingDirectory -ItemType Directory -Force | Out-Null
    }
}

function Resolve-DeltaAppRoot {
    <#
      The first interactive step of installation: asks where DELTA
      should be deployed, defaulting to $Script:DefaultDeltaRuntimeRoot
      (C:\DELTA) on a bare Enter, and sets $Script:DeltaRuntimeRoot to
      the answer. Every later phase - runtime deployment, dependency
      install, .env generation, uploads/logs, the eventual Windows
      Service working directory - reads $Script:DeltaRuntimeRoot rather
      than a literal path, so this is the *only* thing that needs to
      change to install DELTA somewhere else.

      Must run before Install-DeltaRuntime (the first consumer) - see
      lib\DeltaInstaller.Common.ps1 for why the default itself is a
      separate, fixed constant rather than something computed from
      $PSScriptRoot, and why $Script:DeltaRuntimeRoot is never assumed
      to be a stable value the way that default is.
    #>
    $Script:DeltaRuntimeRoot = Read-DeltaAppRoot

    Write-Host ''
    Write-Host 'DELTA application directory:'
    Write-Host $Script:DeltaRuntimeRoot
}

# ---------------------------------------------------------------------------
# Existing DELTA deployment lifecycle
# ---------------------------------------------------------------------------

function Get-ExistingDeltaDeploymentItems {
    <#
      Reports which of the operator-meaningful deployment artifacts -
      .env, uploads\, logs\ - actually exist under $Script:DeltaRuntimeRoot
      right now. Purely a detection helper: Resolve-ExistingDeltaDeployment
      uses it both to decide whether an existing-deployment prompt is
      warranted at all, and to render the "what was found" checklist when
      it is. Deliberately checks for these specific artifacts rather than
      just "does the directory exist" - an empty directory an operator
      pre-created has nothing worth protecting, and should be treated
      exactly like "no existing deployment" rather than triggering a
      prompt about data that was never actually there.
    #>
    return [ordered]@{
        '.env'    = Test-Path -LiteralPath (Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath '.env')
        'uploads' = Test-Path -LiteralPath (Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'uploads')
        'logs'    = Test-Path -LiteralPath (Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'logs')
    }
}

function Read-DeltaDeploymentLifecycleChoice {
    <#
      Displays the existing-deployment summary and the three lifecycle
      options, returning 'Upgrade' | 'Recreate' | 'Fresh'. Bare Enter
      defaults to Upgrade (option 1, recommended) - the same "blank
      means the safe/recommended choice" convention Read-
      ExistingPostgresChoice already uses for the analogous PostgreSQL
      reuse decision.

      Deliberately plain ASCII markers ("[x]", "-"), not Unicode
      checkmark/bullet characters, matching every other console message
      in this installer - confirmed directly that a Unicode character
      here renders as mojibake (or drops entirely) once setup.ps1's
      output is piped/redirected rather than written straight to an
      interactive console host, which is a realistic way this script
      can be invoked, not just a theoretical edge case.
    #>
    param([Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$FoundItems)

    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth)
    Write-Host 'Existing DELTA deployment detected'
    Write-Host ('=' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Application directory:'
    Write-Host $Script:DeltaRuntimeRoot
    Write-Host ''
    Write-Host 'The following deployment data was found:'
    Write-Host ''
    foreach ($name in $FoundItems.Keys) {
        if ($FoundItems[$name]) {
            Write-Host "    [x] $name"
        }
    }
    Write-Host ''
    Write-Host 'Choose how you would like to continue:'
    Write-Host ''
    Write-Host '1) Upgrade existing deployment (Recommended)'
    Write-Host ''
    Write-Host '   - Preserve existing .env'
    Write-Host '   - Preserve uploads'
    Write-Host '   - Preserve logs'
    Write-Host '   - Replace DELTA application files'
    Write-Host '   - Update installer-managed environment variables only'
    Write-Host ''
    Write-Host '2) Recreate DELTA application'
    Write-Host ''
    Write-Host '   - Backup existing .env'
    Write-Host '   - Generate a new .env from .env.example'
    Write-Host '   - Replace DELTA application files'
    Write-Host '   - Preserve uploads'
    Write-Host '   - Preserve logs'
    Write-Host ''
    Write-Host '3) Completely fresh installation'
    Write-Host ''
    Write-Host '   WARNING' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '   This will recreate the DELTA application directory.'
    Write-Host ''
    Write-Host '   Existing application configuration will be backed up before removal.'
    Write-Host ''
    Write-Host '   The following will be removed:'
    Write-Host ''
    Write-Host '       - .env'
    Write-Host '       - uploads'
    Write-Host '       - logs'
    Write-Host '       - runtime files'
    Write-Host ''

    while ($true) {
        $choice = Read-Host -Prompt 'Choose an option [1]'
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }

        switch ($choice.Trim()) {
            '1' { return 'Upgrade' }
            '2' { return 'Recreate' }
            '3' { return 'Fresh' }
        }
        Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow
    }
}

function Confirm-DeltaFreshInstallation {
    <#
      The explicit confirmation gate for lifecycle option 3 (Completely
      fresh installation) - requires the operator to type the exact,
      case-sensitive word YES, deliberately a harder bar than the plain
      Y/N this installer uses everywhere else (Reset-
      PostgresSuperuserPassword's confirmation, Confirm-UninstallIntent
      in uninstall.ps1): every other yes/no prompt in this project
      protects a single value or a database; this is the only one that
      removes an entire application directory tree, even though - see
      Backup-ExistingDeltaDeployment - "removes" always really means
      "moves to a timestamped backup," never an actual delete.
    #>
    Write-Host ''
    Write-Host 'WARNING' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'You are about to perform a completely fresh DELTA installation.'
    Write-Host ''
    Write-Host 'This will remove the existing application directory.'
    Write-Host ''
    Write-Host 'Type YES to continue:'
    Write-Host ''
    $confirmation = Read-Host -Prompt '>'

    return ($confirmation -ceq 'YES')
}

function Backup-ExistingDeltaDeployment {
    <#
      Lifecycle option 3's actual "removal" mechanism - and it never
      actually deletes anything. Moves (not copies - a same-volume
      rename, not a slow tree copy) $Script:DeltaRuntimeRoot to a
      timestamped sibling path (e.g. C:\DELTA-backup-2026-07-31-104530),
      leaving every byte of the prior deployment (.env, uploads, logs,
      runtime files) fully recoverable at that path indefinitely - never
      permanently deleted automatically, per this feature's own
      requirement.

      Once this succeeds, $Script:DeltaRuntimeRoot genuinely does not
      exist on disk anymore, which is deliberately sufficient on its own
      to make every later phase (Install-DeltaRuntime's directory
      creation, Initialize-DeltaRuntimeDirectories, New-
      DeltaEnvironmentFile's template-fallback branch) behave exactly
      like a first-ever install, without any of them needing to know
      lifecycle option 3 was ever chosen.
    #>
    $backupPath = "$($Script:DeltaRuntimeRoot)-backup-$(Get-Date -Format 'yyyy-MM-dd-HHmmss')"
    if (Test-Path -LiteralPath $backupPath) {
        Stop-Setup "Cannot back up the existing DELTA deployment: a directory already exists at the backup destination ($backupPath). Remove or rename it and re-run setup.ps1."
    }

    Write-Step "Backing up existing DELTA deployment to $backupPath..."
    try {
        Move-Item -LiteralPath $Script:DeltaRuntimeRoot -Destination $backupPath -ErrorAction Stop
    }
    catch {
        Stop-Setup "Failed to back up the existing DELTA deployment to $backupPath - nothing was removed. $($_.Exception.Message)"
    }

    Write-Success "    Backup complete: $backupPath"
}

function Resolve-ExistingDeltaDeployment {
    <#
      Makes the lifecycle of an existing DELTA deployment explicit
      instead of silently assuming an upgrade. Runs once, immediately
      after Resolve-DeltaAppRoot has resolved $Script:DeltaRuntimeRoot
      and before anything (Install-DeltaRuntime first) ever touches it -
      deliberately before the Node.js/PostgreSQL/PostGIS phases too, so
      an operator who meant to decline lifecycle option 3 finds out
      immediately rather than after several minutes of unrelated
      installation work.

      If $Script:DeltaRuntimeRoot doesn't exist yet, or exists but has
      none of the operator-meaningful deployment artifacts Get-
      ExistingDeltaDeploymentItems checks for (e.g. an empty directory
      an operator pre-created), this does nothing at all and leaves
      $Script:DeltaDeploymentLifecycle at its default ('Upgrade') -
      every later phase already behaves correctly for a first-ever
      install, and this feature's own requirement is that that path
      stays completely unchanged.

      Otherwise, prompts for one of the three lifecycle choices
      (Read-DeltaDeploymentLifecycleChoice) and records the answer in
      $Script:DeltaDeploymentLifecycle:
        - Upgrade (default/recommended): no filesystem action here at
          all - every later phase's own existing idempotent behavior
          (Install-DeltaRuntime only overwrites its own files;
          Initialize-DeltaRuntimeDirectories and New-
          DeltaEnvironmentFile both already leave an existing
          uploads/logs/.env untouched) already does exactly this,
          unchanged, which is why this choice needed no new code
          anywhere else in the script.
        - Recreate: no filesystem action here either - only records the
          choice. New-DeltaEnvironmentFile reads
          $Script:DeltaDeploymentLifecycle later, at the point it
          actually runs (well after PostgreSQL is installed and
          DATABASE_URL is finally known - it cannot run any earlier
          than that), and backs up + regenerates .env from .env.example
          when it sees 'Recreate', via its own
          -ForceRegenerateFromTemplate parameter. uploads/logs are left
          alone the same idempotent way the Upgrade choice leaves them
          alone.
        - Fresh: the one choice that takes an immediate action right
          here - Confirm-DeltaFreshInstallation gates it behind an
          exact typed "YES", and Backup-ExistingDeltaDeployment moves
          the entire existing deployment out of the way before this
          returns. A declined confirmation re-shows the same
          three-option menu rather than aborting the installer outright.
    #>
    $foundItems = Get-ExistingDeltaDeploymentItems
    $anyFound = @($foundItems.Values | Where-Object { $_ }).Count -gt 0

    if (-not (Test-Path -LiteralPath $Script:DeltaRuntimeRoot) -or -not $anyFound) {
        return
    }

    while ($true) {
        $choice = Read-DeltaDeploymentLifecycleChoice -FoundItems $foundItems

        if ($choice -eq 'Fresh') {
            if (-not (Confirm-DeltaFreshInstallation)) {
                Write-Host ''
                Write-Detail 'Fresh installation canceled.'
                continue
            }
            Backup-ExistingDeltaDeployment
        }

        $Script:DeltaDeploymentLifecycle = $choice
        break
    }

    Write-Host ''
    Write-Host 'Deployment lifecycle:'
    Write-Host $Script:DeltaDeploymentLifecycle
}

# ---------------------------------------------------------------------------
# Orchestration
#
# Each phase is a single top-level function call, in dependency order.
# Add future phases here once they exist - nothing above this point needs
# to change to support them.
# ---------------------------------------------------------------------------

try {
    Initialize-Setup
    Update-DeltaRuntimeArtifact -RuntimeDirectory $Script:DeltaRuntimeSourceDirectory -ProjectRoot $Script:ProjectRoot
    Resolve-DeltaAppRoot
    Resolve-ExistingDeltaDeployment
    Install-NodeJs
    Install-PostgreSql
    Install-PostGIS
    Install-DeltaRuntime
    Initialize-DeltaRuntimeDirectories
    Complete-DatabaseSetup
    Install-DeltaDependencies
    Confirm-DeltaRuntimeNotRunning

    # Future phases (not yet implemented):
    # Install-WindowsService (Phase 5)
    # Validate-Deployment    (Phase 6)
    #
    # Application startup (start.bat) is intentionally NOT invoked here -
    # for this validation phase it remains a manual, operator-run step
    # (see the final message below), isolated from everything setup.ps1
    # itself is responsible for. Wiring it in is deferred to Phase 5
    # (Windows Service), once the app is meant to run unattended rather
    # than in a console the operator is watching.
    #
    # Database upgrade path (detect an existing DELTA installation ->
    # validate it -> update DATABASE_URL if required -> invoke
    # upgrade_database.ps1) is intentionally not wired in here yet -
    # upgrade_database.ps1 exists and is independently runnable today,
    # but the automatic fresh-vs-upgrade detection this orchestration
    # would need is deferred pending real operational experience with
    # the fresh-install path first. See docs/08-development-roadmap.md.

    $Script:PostgresSuperuserPassword = $null

    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth)
    Write-Host 'Setup complete: Node.js, PostgreSQL, PostGIS, and the DELTA runtime are ready.'
    Write-Host ('=' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'The DELTA application has not been started.'
    Write-Host 'To start it for validation, run:'
    Write-Host ''
    Write-Host "    $(Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'start.bat')"
    Write-Host ''

    exit 0
}
catch {
    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Red
    Write-Host 'DELTA Setup failed.' -ForegroundColor Red
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

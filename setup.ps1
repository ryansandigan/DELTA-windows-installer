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
    database stage then resolves the DELTA database name - prompting for
    it (default delta_db) only for a genuine Fresh Installation with no
    existing configuration to consult; an Update instead extracts it
    automatically from the existing .env's own DATABASE_URL, never
    prompting - and generates or updates <AppRoot>\.env from the
    repository's .env.example template. The canonical database flow
    always ends with a
    migration check (upgrade_database.ps1) - never just initialization
    alone, and never gated behind an operator prompt: on a fresh
    PostgreSQL install, or when an existing PostgreSQL instance was
    reused but has no DELTA database yet, this means init_db.ps1 followed
    unconditionally by upgrade_database.ps1; when a reused instance
    already has a DELTA database, Complete-DatabaseSetupForExistingPostgres
    runs upgrade_database.ps1 against it unconditionally instead - never
    initialization again, and never a choice to recreate it. Destructive
    database recreation is out of scope for this normal install/update
    path entirely; it is not offered here in any form. <AppRoot>\.env is
    regenerated with the final connection information in every case.

    Phase 3 (Install-DeltaDependencies) installs the DELTA runtime's own
    Node dependencies - Yarn, `yarn install --production`, dotenv-cli - by
    running dts_shared_binary's own init_website.bat, unconditionally,
    every run. There is deliberately no existence-based idempotency gate
    in front of it: Install-DeltaRuntime always redeploys the latest
    package.json immediately before this phase runs, so the only question
    worth asking is whether dependencies currently match that file - and
    init_website.bat's own commands (npm/yarn install) already answer
    that correctly and cheaply every time they run, without this script
    trying to predict the answer from node_modules' mere presence first.
    A confirmed gap found during Windows validation - dotenv-cli lands in
    Yarn's own global bin, which nothing else puts on PATH - is fixed
    permanently and idempotently by Add-YarnGlobalBinToPersistentPath,
    which appends that directory to the persistent User PATH (not just
    this session's $env:Path), so `dotenv` still resolves in a brand-new
    console or after a reboot, not only for the remainder of this one run.

    Next, Confirm-DeltaRuntimeNotRunning detects whether a DELTA instance
    from a previous run is still active (by process command line, matched
    specifically to this runtime directory - never a generic node.exe
    sweep) and stops it, so a repeat run never leaves two instances bound
    to the same port. Finally, Resolve-DeltaApplicationPort/Update-
    DeltaApplicationPortEnvironment determine and, if necessary,
    interactively resolve a port conflict for DELTA's own port, and
    Start-DeltaRuntimeForValidation/Confirm-DeltaRuntimeStarted start
    DELTA and verify it (process, then port, then a real HTTP response)
    before Register-DeltaInstallation ever runs - a failed start or
    failed verification stops the installer outright, before the registry
    claims a completed installation. This automatic startup is an interim
    installation-validation convenience, not a supervised service - see
    Start-DeltaRuntimeForValidation's own header for what it deliberately
    does not do (restart policy, crash supervision, watchdog behavior),
    all of which are deferred to Phase 5 (Windows Service).

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

# Single source of truth for this installer's own version - see that
# file's header. Dot-sourced separately from DeltaInstaller.Common.ps1
# so the version stays a plain, standalone piece of data rather than
# living inside the shared helper library.
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Version.ps1')

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
# existence-check-then-migrate flow (Complete-DatabaseSetupForExistingPostgres)
# - a fresh install never needs that decision, since the DELTA database
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
$Script:DefaultDeltaDatabaseName = 'delta_db'
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

# DELTA application startup validation (Start-DeltaRuntimeForValidation /
# Confirm-DeltaRuntimeStarted, below) - an interim convenience until Phase 5
# (Windows Service) supersedes it, see those functions' own headers. How
# long Confirm-DeltaRuntimeStarted waits for the just-started process to
# bind $Script:DeltaBackendPort, and then to answer an HTTP request, before
# treating startup as failed rather than merely slow.
$Script:DeltaStartupPortTimeoutSeconds = 60
$Script:DeltaStartupHttpTimeoutSeconds = 20

# Set by Resolve-DeltaApplicationPort only when the port conflict it found
# turned out to be the installer's own managed DELTA instance (per Get-
# RunningDeltaProcesses - never the registry, see Resolve-
# DeltaManagedInstanceRestartDecision) and the operator declined a
# restart, whether just now or via the remembered ManagedInstanceRestartPolicy
# registry preference (Get-/Set-DeltaManagedInstanceRestartPolicy, Registry
# Registration section below). Confirm-DeltaRuntimeNotRunning, Start-
# DeltaRuntimeForValidation, and Confirm-DeltaRuntimeStarted - all called
# unconditionally from the orchestration block - each become a no-op when
# this is $true, rather than any of them re-deciding or overriding that
# choice.
$Script:DeltaSkipManagedInstanceRestart = $false

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
# Presentation helpers (this script only)
#
# Purely cosmetic - none of these decide anything or perform any
# installation action. They exist so setup.ps1's own screens (the main
# menu, each phase's "component already present" check, and the final
# summary) share one consistent look instead of each call site hand-
# rolling its own sequence of blank-line-separated Write-Host calls.
#
# Deliberately kept local to this script rather than promoted into
# lib\DeltaInstaller.Common.ps1: Write-SetupBanner/Write-PhaseBanner/
# Write-Success there are still used unchanged by init_db.ps1,
# upgrade_database.ps1, and lib\DeltaRuntimeArtifact.ps1, and this
# refactor's scope is setup.ps1's own presentation only.
# ---------------------------------------------------------------------------

function Show-Section {
    <#
      The full-width '====' banner used for setup.ps1's own major
      screens - the installer banner, each phase, DELTA Runtime
      Deployment, Registry Registration, and the final summary.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle
    )
    $rule = '=' * $Script:BannerWidth
    Write-Host ''
    Write-Host $rule
    Write-Host $Title
    if ($Subtitle) {
        Write-Host $Subtitle
    }
    Write-Host $rule
    Write-Host ''
}

function Show-Warning {
    <#
      A standalone warning screen - "WARNING" followed by one or more
      message lines, each followed by a blank line, matching this
      installer's existing warning formatting (Confirm-
      DeltaFreshInstallation) exactly, just named and reusable.
    #>
    param([Parameter(Mandatory)][string[]]$Message)
    Write-Host ''
    Write-Host 'WARNING' -ForegroundColor Yellow
    Write-Host ''
    foreach ($line in $Message) {
        Write-Host $line
        Write-Host ''
    }
}

function Show-Success {
    <#
      Presentation-layer success line for this script's own new UI
      call sites (Show-InstallationSummary's checklist, phase
      completion messages) - functionally identical to the shared
      Write-Success, kept as a distinct name so this region doesn't
      reach back into the older vocabulary.
    #>
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Show-ComponentStatus {
    <#
      The consistent "a component was already found on this machine"
      screen each phase's detection branch prints - Node.js,
      PostgreSQL, PostGIS, and Phase 3's runtime-dependency check all
      funnel their "already installed" / "needs updating" / "different
      version present" messaging through this one layout instead of
      each hand-rolling its own sequence of Write-Host calls.

      $Fields is an ordered label/value list (e.g. Version/Status, or
      Installed/Required) so every caller's labels line up on the same
      colon column regardless of how many rows it has. $Message is the
      trailing line(s) explaining what happens next ("Skipping
      installation.", "Updating installation...").
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Fields,
        [string[]]$Message
    )

    $labelWidth = ($Fields.Keys | Measure-Object -Property Length -Maximum).Maximum
    $rowFormat  = "{0,-$labelWidth} : {1}"

    Write-Host ''
    Write-Host $Name
    Write-Host ''
    foreach ($label in $Fields.Keys) {
        Write-Host ($rowFormat -f $label, $Fields[$label])
    }
    if ($Message) {
        Write-Host ''
        foreach ($line in $Message) {
            Write-Host $line
        }
    }
}

function Show-MainMenu {
    <#
      The first screen shown after the installer banner (Initialize-
      Setup). Purely a presentation-layer front door: it does not
      decide *how* an existing DELTA deployment is handled -
      Resolve-ExistingDeltaDeployment still owns that, completely
      unchanged, once Resolve-DeltaAppRoot below knows the target
      directory. It only tells the operator up front whether a DELTA
      installation was found (via the existing, unmodified
      Get-DeltaInstallPath discovery helper - never re-implemented
      here) and gives them a chance to back out before anything below
      touches disk.

      Returns $true if the orchestration below should proceed, $false
      if the operator chose to stop here (bare-N on the fresh-install
      prompt, or "Exit" on the existing-install menu) - the caller
      exits immediately in that case, before any installation action
      has run.
    #>
    $existingInstallPath = Get-DeltaInstallPath

    if (-not $existingInstallPath) {
        Write-Host 'No existing DELTA installation was detected.'
        Write-Host ''
        Write-Host 'This installer will install:'
        Write-Host ''
        Write-Host '  - DELTA Application'
        Write-Host "  - Node.js v$($Script:RequiredNodeVersion)"
        Write-Host "  - PostgreSQL $($Script:RequiredPostgresVersion)"
        Write-Host "  - PostGIS $($Script:RequiredPostGISVersion)"
        Write-Host ''
        $choice = Read-Host -Prompt 'Continue? [Y/N]'
        Write-Host ''
        return ($choice.Trim() -in @('Y', 'y'))
    }

    while ($true) {
        Write-Host 'Existing DELTA installation detected.'
        Write-Host ''
        Write-Host 'Location:'
        Write-Host $existingInstallPath
        Write-Host ''
        Write-Host 'Choose an option:'
        Write-Host ''
        Write-Host '1. Update DELTA'
        Write-Host '2. Reinstall DELTA'
        Write-Host '3. Exit'
        Write-Host ''
        $choice = Read-Host -Prompt 'Selection'
        Write-Host ''

        switch ($choice.Trim()) {
            '1' { return $true }
            '2' { return $true }
            '3' { return $false }
        }

        Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow
        Write-Host ''
    }
}

function Show-InstallationSummary {
    <#
      The final "installation complete" screen. Every piece of state it
      prints (DeltaHome, EnvPath, StartBatPath, Port, Activated) is
      supplied by the orchestration block below, already established by
      the phases that ran before it - this performs no installation
      actions and reads no $Script: state of its own, purely reformatting
      the same information the previous inline Write-Host block printed.

      $Activated distinguishes two different successful outcomes that
      must never be reported identically - "the deployment completed"
      (files, dependencies, .env, database - all updated regardless of
      $Activated) is not the same fact as "the deployment is active" (the
      running process is actually serving the code/config just deployed,
      confirmed by Confirm-DeltaRuntimeStarted's real HTTP check):

        - $true - the normal path: DELTA was (re)started and verified
          this run. $Port is that already-running instance's actual
          port, and the "First Run" section below reports DELTA as
          already up with a URL to browse to.
        - $false - Resolve-DeltaApplicationPort found the configured
          port occupied by DELTA's own previous instance and the
          operator chose not to restart it (Resolve-
          DeltaManagedInstanceRestartDecision). Confirm-DeltaRuntimeStarted
          never ran its HTTP check, so this must never claim it did -
          the "First Run" section below reports the deployment as
          completed but not yet active, and points at the manual restart
          needed to activate it, with no browse-to URL implying
          otherwise.
    #>
    param(
        [Parameter(Mandatory)][string]$DeltaHome,
        [Parameter(Mandatory)][string]$EnvPath,
        [Parameter(Mandatory)][string]$StartBatPath,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][bool]$Activated
    )

    Show-Section -Title 'Installation Complete' -Subtitle 'Installation completed successfully.'

    Write-Host 'Installed Components'
    Write-Host ''
    Show-Success '[OK] DELTA Runtime'
    Show-Success '[OK] Node.js'
    Show-Success '[OK] PostgreSQL'
    Show-Success '[OK] PostGIS'

    Write-Host ''
    Write-Host 'Application'
    Write-Host ''
    Write-Host 'Location :'
    Write-Detail $DeltaHome
    Write-Host ''
    Write-Host 'Configuration :'
    Write-Detail $EnvPath

    Show-ComponentStatus -Name 'Deployment Status' -Fields ([ordered]@{
        'Deployment' = 'Completed'
        'Activation' = if ($Activated) { 'Active' } else { 'Pending (manual restart required)' }
    })

    Write-Host ''
    Write-Host 'First Run'
    Write-Host ''
    if ($Activated) {
        Show-Success 'DELTA has been started and verified successfully.'
        Write-Host ''
        Write-Host 'Browse to:'
        Write-Detail "http://localhost:$Port"
        Write-Host ''
        Write-Host 'This startup is an installation validation step, not a supervised service -'
        Write-Host 'see the Windows Service documentation for production deployment. To stop'
        Write-Host 'DELTA now, end its node.exe process (Task Manager, or taskkill); re-running'
        Write-Host 'this installer also stops it automatically before starting a fresh instance.'
        Write-Host ''
        Write-Host 'To start DELTA manually later (e.g. after a reboot):'
        Write-Detail $StartBatPath
    }
    else {
        Write-Host "The existing DELTA instance was left running, per the operator's choice above." -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Startup validation was skipped - HTTP validation did not run this time.'
        Write-Host ''
        Write-Host 'The currently running instance may still be serving the previous deployment,'
        Write-Host 'not the one just installed. Restart DELTA manually to activate it:'
        Write-Detail $StartBatPath
    }

    Write-Host ''
    Write-Host 'Configuration Notes'
    Write-Host ''
    Write-Host 'A default .env file has already been created. It is suitable for'
    Write-Host 'initial installation and local testing.'
    Write-Host ''
    Write-Host 'Before production deployment, review and update:'
    Write-Detail '- PUBLIC_URL'
    Write-Detail '- Database settings'
    Write-Detail '- SMTP configuration'
    Write-Detail '- Authentication settings'

    Write-Host ''
    Write-Host 'Optional: Reverse Proxy'
    Write-Host ''
    Write-Host "DELTA listens on port $Port for this installation. Production"
    Write-Host 'deployments typically place it behind a reverse proxy.'
    Write-Host ''
    Write-Host 'Example (NGINX):'
    Write-Host ''
    Write-Host '    server {'
    Write-Host '        listen 80;'
    Write-Host '        server_name delta.example.org;'
    Write-Host ''
    Write-Host '        location / {'
    Write-Host "            proxy_pass http://127.0.0.1:$Port;"
    Write-Host ''
    Write-Host '            proxy_set_header Host $host;'
    Write-Host '            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;'
    Write-Host '            proxy_set_header X-Forwarded-Proto $scheme;'
    Write-Host '            proxy_set_header X-Real-IP $remote_addr;'
    Write-Host '        }'
    Write-Host '    }'
    Write-Host ''
    Write-Host 'IIS and other reverse proxies are also supported - see the'
    Write-Host 'deployment documentation for detailed guidance.'

    Write-Host ''
    Write-Host 'Troubleshooting'
    Write-Host ''
    Write-Host "If a future manual start finds port $Port already in use, add or"
    Write-Host 'change the PORT line in .env to another available port, then start'
    Write-Host 'DELTA again:'
    Write-Detail $StartBatPath

    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth)
    Write-Host ''
}

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

    Show-Section -Title 'Phase 1 - Node.js'
    Write-Step 'Checking for an existing Node.js installation...'
    $nodePath = Find-NodeExecutable

    if ($nodePath) {
        $installedVersion = Get-InstalledNodeVersion -NodeExecutablePath $nodePath

        if ($installedVersion -eq $Script:RequiredNodeVersion) {
            Show-ComponentStatus -Name 'Node.js' -Fields ([ordered]@{
                'Version' = "v$installedVersion"
                'Status'  = 'Already installed'
            }) -Message @('Skipping installation.')
            return
        }

        Show-ComponentStatus -Name 'Node.js' -Fields ([ordered]@{
            'Installed' = $(if ($installedVersion) { "v$installedVersion" } else { '(unknown version)' })
            'Required'  = "v$($Script:RequiredNodeVersion)"
        }) -Message @('Updating installation...')
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
    Show-Success 'Node.js successfully installed.'
    Write-Host ''
    Write-Host "Node : v$finalVersion"
    Write-Host "npm  : $(($npmVersion | Select-Object -First 1).ToString().Trim())"
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

function Test-TcpPortAvailable {
    <#
      Reports whether $Port is free to listen on and, if not, a
      human-readable description (process name + PID) of whatever
      already owns it, for display to the operator, plus the raw owning
      process ID itself (OwningProcessId). Uses Get-NetTCPConnection
      (built into Windows Server's NetTCPIP module) rather than a raw
      socket bind, since it also identifies the owner.

      Originally Test-PostgresPort (Resolve-PostgresPort's own helper) -
      generalized and renamed once Resolve-DeltaApplicationPort needed the
      identical "is this port free, and who owns it if not" check for
      DELTA's own application port. Nothing about the implementation is
      PostgreSQL-specific; only the name was.

      OwningProcessId exists specifically for Resolve-DeltaApplicationPort's
      own use: cross-referencing it against Get-RunningDeltaProcesses'
      PIDs is how that function tells "this port is occupied by our own
      managed DELTA instance" apart from "this port is occupied by
      something else entirely" - process ownership is still determined
      exclusively by Get-RunningDeltaProcesses (command line, application
      root), never by this function or anything registry-based; this only
      supplies the PID being cross-referenced.
    #>
    param([Parameter(Mandatory)][int]$Port)

    $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $connection) {
        return [PSCustomObject]@{ Available = $true; OwnerDescription = $null; OwningProcessId = $null }
    }

    $owner = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
    $description = if ($owner) { "$($owner.ProcessName).exe (PID $($owner.Id))" } else { "PID $($connection.OwningProcess)" }
    return [PSCustomObject]@{ Available = $false; OwnerDescription = $description; OwningProcessId = $connection.OwningProcess }
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
    $check = Test-TcpPortAvailable -Port $preferredPort
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

        $recheck = Test-TcpPortAvailable -Port $portNumber
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

function Get-DeltaUpgradeDatabaseUrlComponents {
    <#
      Returns the parsed DATABASE_URL (ConvertFrom-DatabaseUrl, lib\
      DeltaInstaller.Common.ps1) from the DELTA deployment's EXISTING
      .env - but only when this run is a genuine Upgrade of a real prior
      deployment, never for a Fresh Installation. $null in every other
      case, which every caller here treats as "fall back to the normal,
      fully-interactive behavior" - never a reason to stop the installer.

      Two conditions, both required:

        1. $Script:DeltaDeploymentLifecycle -eq 'Upgrade'. Excludes
           'Recreate' and 'Fresh' - both explicit operator choices to
           NOT carry old configuration forward, even though 'Recreate'
           technically still has its old .env sitting on disk at the
           point this is called (New-DeltaEnvironmentFile's own backup+
           regenerate for that choice hasn't run yet) and 'Fresh' just
           moved theirs out of the way via Backup-ExistingDeltaDeployment.
           Reusing old credentials/database name is exactly what those
           two choices are asking NOT to happen.

        2. .env actually exists on disk at $Script:DeltaRuntimeRoot.
           Required IN ADDITION to check 1, not redundant with it:
           $Script:DeltaDeploymentLifecycle defaults to 'Upgrade' and
           stays there UNTOUCHED whenever Resolve-ExistingDeltaDeployment
           finds nothing at all at $Script:DeltaRuntimeRoot (see that
           function's own header) - a genuinely Fresh Installation never
           explicitly sets it to anything else, so the lifecycle flag
           ALONE cannot tell "nothing ever existed here" apart from "the
           operator explicitly chose to upgrade a real deployment". Only
           an .env that's actually, physically present proves the latter.

      Called independently (and cheaply - a file read plus a string
      parse, no live network/database call) from both Resolve-
      ExistingPostgresCredentials (password reuse) and Complete-
      DatabaseSetup (database name default) rather than computed once
      and cached in a new $Script: variable - no new persistent or
      cross-call state needed for something this cheap to just
      recompute.
    #>
    if ($Script:DeltaDeploymentLifecycle -ne 'Upgrade') {
        return $null
    }

    $envPath = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath '.env'
    if (-not (Test-Path -LiteralPath $envPath)) {
        return $null
    }

    $databaseUrl = Get-EnvFileValue -Path $envPath -Key 'DATABASE_URL'
    return ConvertFrom-DatabaseUrl -DatabaseUrl $databaseUrl
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

      Upgrade reuse: before ever prompting, tries the password already
      recorded in the existing DELTA .env's own DATABASE_URL (Get-
      DeltaUpgradeDatabaseUrlComponents - Upgrade lifecycle only, never
      Fresh Installation, see that function's own header for exactly
      what makes that distinction real) against this exact host/port/
      superuser, live, via the same Test-PostgresCredentials check the
      interactive prompt below uses. Only ever accepted on a genuine
      successful authentication - never merely because .env said so -
      so a stale or hand-edited password still falls straight through to
      the normal prompt, exactly as if nothing had been tried at all.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Existing)

    $existingUrlComponents = Get-DeltaUpgradeDatabaseUrlComponents
    if ($existingUrlComponents) {
        Write-Step 'Reading database configuration from .env...'
        Write-Detail 'Existing DATABASE_URL detected.'

        Write-Step "Checking whether the existing DELTA configuration's PostgreSQL credentials still work..."
        $existingCheck = Test-PostgresCredentials -PostgresHost $Script:PostgresHost -Port $Script:PostgresPort `
            -Username $Script:PostgresSuperuser -Password $existingUrlComponents.Password

        if ($existingCheck.Success) {
            Write-Success '    Authentication succeeded.'
            Write-Detail 'Reusing the existing PostgreSQL credentials.'
            $Script:PostgresSuperuserPassword = $existingUrlComponents.Password
            return
        }

        Write-Detail 'The stored credentials are no longer valid - prompting for the current password.'
    }

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

    Show-Section -Title 'Phase 2A - PostgreSQL'
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
                    Show-Success 'Reusing the existing PostgreSQL installation.'
                    return
                }

                Write-Detail 'Proceeding with a new PostgreSQL installation alongside the existing one.'
            }
            else {
                Show-ComponentStatus -Name 'PostgreSQL' -Fields ([ordered]@{
                    'Version' = $existing.Version
                    'Status'  = 'Already installed'
                }) -Message @('Skipping installation.')
                return
            }
        }
        else {
            Show-ComponentStatus -Name 'PostgreSQL' -Fields ([ordered]@{
                'Installed' = $(if ($existing.Version) { $existing.Version } else { '(unknown version)' })
                'Required'  = "$($Script:RequiredPostgresMajorVersion).x"
            }) -Message @("A different PostgreSQL major version is installed. PostgreSQL major versions install side by side rather than in place, so PostgreSQL $($Script:RequiredPostgresMajorVersion) will be installed alongside the existing instance.")
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
    Show-Success 'PostgreSQL successfully installed.'
    Write-Host ''
    Write-Host "Version : $($confirmed.Version)"
    Write-Host "Service : $($confirmed.ServiceStatus)"
    Write-Host 'psql    : Available'
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

    Show-Section -Title 'Phase 2B - PostGIS'

    $existing = Find-PostgresInstallation
    if (-not $existing.Found -or -not $existing.PsqlPath) {
        Stop-Setup 'No usable PostgreSQL installation was found. Run Phase 2A (Install-PostgreSql) first.'
    }

    Write-Step 'Checking whether PostGIS is already usable...'
    $superuserPassword = Get-CachedPostgresSuperuserPassword
    $check = Test-PostGISAvailable -PsqlPath $existing.PsqlPath -SuperuserPassword $superuserPassword

    if ($check.Available) {
        Show-ComponentStatus -Name 'PostGIS' -Fields ([ordered]@{
            'Version' = $check.VersionString
            'Status'  = 'Already installed and usable'
        }) -Message @('Skipping installation.')
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
    Show-Success 'PostGIS successfully installed.'
    Write-Host ''
    Write-Host "Version : $($confirmed.VersionString)"
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

    Show-Section -Title 'DELTA Runtime Deployment'

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
      Start-DeltaRuntimeForValidation later starts DELTA as for this
      validation phase. Revisit once Phase 5 introduces an actual
      dedicated service account to grant this to instead - see docs/08
      for the open item.

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
    Show-Section -Title 'DELTA Runtime Directories'

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
      Prompts for the DELTA database name, defaulting to $DefaultName on
      a bare Enter - same prompt-with-suggested-default shape as
      Resolve-PostgresPort.

      The DefaultName parameter is used only during the Fresh Installation
      workflow, where no existing DELTA configuration exists yet and the
      installer must ask which database should be created. The default
      suggestion is "delta_db" ($Script:DefaultDeltaDatabaseName).

      During an Update, the installer never prompts for the database name.
      Instead, it uses the database extracted from the existing
      DATABASE_URL, which is treated as the authoritative configuration -
      Complete-DatabaseSetup skips this function entirely in that case
      (Get-DeltaUpgradeDatabaseUrlComponents non-$null), so this function
      itself has no Update-path behavior to document beyond "never
      called."
    #>
    param([string]$DefaultName = $Script:DefaultDeltaDatabaseName)

    $entered = Read-Host -Prompt "Enter the DELTA database name [$DefaultName]"
    if ([string]::IsNullOrWhiteSpace($entered)) {
        return $DefaultName
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

function Backup-DeltaEnvironmentFile {
    <#
      Timestamped backup of an existing .env before this installer writes
      to it - shared by New-DeltaEnvironmentFile (DATABASE_URL, and any
      other template-driven regeneration) and Update-DeltaApplicationPortEnvironment
      (PORT) rather than each keeping its own copy of the same few lines.
      A no-op if $Path doesn't exist yet - there's nothing to protect.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $backupPath = "$Path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    Write-Detail "Existing .env backed up to: $backupPath"
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

      Adding a future installer-managed value means adding one more key
      to $managedValues below - never a new bespoke match/replace branch
      - since Update-ManagedEnvironmentLines already applies to every
      entry in that table generically. PORT itself deliberately did NOT
      end up here: its default (3000) is a plain, static line in
      .env.example now, like PUBLIC_URL or SESSION_SECRET, passed
      through completely unmanaged by this function exactly like every
      other application default - a fresh install gets it for free, no
      code change needed, precisely because of the architecture
      described above. Only the CONFLICT case - the operator being
      forced onto a different port - is genuinely installer-decided
      state, and that's handled by Update-DeltaApplicationPortEnvironment's
      own, separate, narrower $managedValues (below, in the DELTA
      application startup section) - never here, since this function has
      no idea yet whether the configured port is actually free.

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
        Backup-DeltaEnvironmentFile -Path $envTargetPath
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
      prompt it would otherwise show. That confirmation belongs to
      upgrade_database.ps1's own standalone (Mode 2) execution, not to
      this installer's normal install/update flow, which never prompts
      before running the migration check - see
      Complete-DatabaseSetupForExistingPostgres.

      Called unconditionally after every successful Invoke-DeltaDatabaseInit
      (fresh install) and unconditionally for every existing database
      (Update) - upgrade_database.ps1 itself, not this wrapper, owns
      deciding whether that means "nothing to do" (already current), "ran
      the migration chain", or a hard failure; see its own state
      classification. This wrapper only ever supplies connection values
      and surfaces a non-zero exit as a Stop-Setup, exactly like
      Invoke-DeltaDatabaseInit.

      -FollowingInitialization only changes the success message printed
      here - a freshly initialized database already seeds the latest
      schema version directly (dts_db_schema.sql), so upgrade_database.ps1
      will itself report "already current" for that case. This switch
      exists purely so the operator sees that positive confirmation
      framed as part of initialization ("initialized, then confirmed
      current") rather than as an unrelated, unexplained upgrade step -
      it carries no version knowledge of its own, only sequencing context
      only this caller has.
    #>
    param(
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][SecureString]$SuperuserPassword,
        [switch]$FollowingInitialization
    )

    Write-Step 'Checking DELTA database migration status...'

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
        Stop-Setup "Database migration check failed (upgrade_database.ps1 exited with code $LASTEXITCODE). See its output above for details. Setup is stopping before runtime activation and registry registration."
    }

    if ($FollowingInitialization) {
        Write-Success '    Database initialized, then confirmed current.'
    }
    else {
        Write-Success '    DELTA database migration check complete.'
    }
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

function Complete-DatabaseSetupForExistingPostgres {
    <#
      The reuse-aware counterpart to Complete-DatabaseSetup's original
      "always create fresh" flow - only reached when Install-PostgreSql
      recorded $Script:PostgresReuseMode. Design goal from this feature's
      spec: C:\DELTA\.env is always regenerated with the final connection
      information no matter which branch runs below, so that line runs
      once, after the if/else, rather than being duplicated in each branch.

      Canonical database flow (see also Complete-DatabaseSetup's fresh-
      PostgreSQL branch): initialization and the migration check are two
      separate responsibilities that always run together, never one
      without the other, and neither one is ever gated behind an
      operator prompt here.
        - No DELTA database yet -> Init, then Upgrade (Upgrade will find
          the freshly seeded schema already at the latest version and
          confirm that, not silently no-op). This is a fresh install of
          the database, with zero prompts.
        - An existing DELTA database -> Upgrade unconditionally. There
          is deliberately no recreate/drop option here at all -
          destructive database maintenance is out of scope for the
          normal install/update path entirely (not merely defaulted-off
          or reworded as a confirmation); if it's ever needed again it
          belongs in a separate, dedicated maintenance operation, never
          inside this function. An unattended update therefore never
          blocks on a console prompt it can't answer.
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
        Invoke-DeltaDatabaseUpgrade -DatabaseName $DatabaseName -SuperuserPassword $SuperuserPassword -FollowingInitialization
    }
    else {
        Write-Detail "Database '$DatabaseName' already exists - checking its migration status."
        Invoke-DeltaDatabaseUpgrade -DatabaseName $DatabaseName -SuperuserPassword $SuperuserPassword
    }

    $databaseUrl = New-DatabaseUrl -PostgresHost $Script:PostgresHost -Port $Script:PostgresPort `
        -Username $Script:PostgresSuperuser -Password $SuperuserPassword -DatabaseName $DatabaseName
    New-DeltaEnvironmentFile -DatabaseUrl $databaseUrl -ForceRegenerateFromTemplate:($Script:DeltaDeploymentLifecycle -eq 'Recreate')
}

function Complete-DatabaseSetup {
    <#
      The "ask for DELTA database name -> generate .env -> invoke
      init_db.ps1 -> invoke upgrade_database.ps1" stage of the target
      installation flow. Owns none of the actual database logic itself -
      init_db.ps1/upgrade_database.ps1 do, invoked as sibling scripts
      rather than duplicated here. Reuses the PostgreSQL host/port/
      username/password Phase 2A already resolved; the DELTA database
      name is the only new value asked for.

      Branches on $Script:PostgresReuseMode (set by Install-PostgreSql):
      a fresh PostgreSQL install provably has no DELTA database yet, so
      the flow below is Init then Upgrade unconditionally, exactly the
      same "always run the migration check after initialization" shape
      Complete-DatabaseSetupForExistingPostgres uses for its own
      no-database-yet branch; a reused instance might already have a
      DELTA database, which is what Complete-DatabaseSetupForExistingPostgres
      exists to handle - by running the migration check unconditionally
      against it, never by prompting whether to recreate it.

      Upgrade reuse: once Get-DeltaUpgradeDatabaseUrlComponents (Upgrade
      lifecycle only, never Fresh Installation - see that function's own
      header) has successfully parsed a database name out of the
      existing .env's DATABASE_URL, that name is treated as
      authoritative, not merely a suggested default - the whole point of
      Phase 2A already having parsed, authenticated, and accepted that
      same DATABASE_URL is that there is no remaining decision left for
      an operator to make here. The database name is used directly, with
      only an informational Write-Detail (no Read-DeltaDatabaseName
      call, no prompt, no confirmation) - unlike every other
      prompt-with-a-suggested-default in this script, this one specific
      value has already been established with certainty earlier in the
      same run. A Fresh Installation never has an existing .env to parse
      one out of, so Read-DeltaDatabaseName's interactive prompt remains
      completely unchanged for that case.
    #>
    Show-Section -Title 'DELTA Database Setup'

    $existingUrlComponents = Get-DeltaUpgradeDatabaseUrlComponents

    if ($existingUrlComponents) {
        Write-Host 'Existing DELTA database:'
        Write-Detail $existingUrlComponents.DatabaseName
        Write-Host ''
        Write-Detail 'Using database from the existing DELTA configuration.'
        $deltaDatabaseName = $existingUrlComponents.DatabaseName
    }
    else {
        $deltaDatabaseName = Read-DeltaDatabaseName -DefaultName $Script:DefaultDeltaDatabaseName
    }

    $superuserPassword = Get-CachedPostgresSuperuserPassword

    if ($Script:PostgresReuseMode) {
        Complete-DatabaseSetupForExistingPostgres -DatabaseName $deltaDatabaseName -SuperuserPassword $superuserPassword
        return
    }

    $databaseUrl = New-DatabaseUrl -PostgresHost $Script:PostgresHost -Port $Script:PostgresPort `
        -Username $Script:PostgresSuperuser -Password $superuserPassword -DatabaseName $deltaDatabaseName
    New-DeltaEnvironmentFile -DatabaseUrl $databaseUrl -ForceRegenerateFromTemplate:($Script:DeltaDeploymentLifecycle -eq 'Recreate')

    Invoke-DeltaDatabaseInit -DatabaseName $deltaDatabaseName -SuperuserPassword $superuserPassword
    Invoke-DeltaDatabaseUpgrade -DatabaseName $deltaDatabaseName -SuperuserPassword $superuserPassword -FollowingInitialization
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
      production dependencies, and dotenv-cli. Runs unconditionally,
      every time - Install-DeltaRuntime always redeploys the latest
      package.json immediately before this phase runs (fresh install,
      upgrade, or recreate alike), so init_website.bat's own npm/yarn
      install commands are the authoritative, always-correct answer to
      "does anything need installing," not a node_modules existence
      check performed here first. Those commands are themselves
      idempotent - a no-op re-run costs a quick resolution check, not a
      fresh install - so there is nothing to protect by gating them.

      The dotenv-cli PATH fix always runs after this - a *new*
      PowerShell session (this run) has no reason to already have
      Yarn's global bin on PATH even when dependencies were installed
      by an earlier run, and the fix itself
      (Add-YarnGlobalBinToPersistentPath) is idempotent either way.
    #>
    Show-Section -Title 'Phase 3 - DELTA Runtime Dependencies'

    Invoke-DeltaWebsiteInit
    Add-YarnGlobalBinToPersistentPath
}

# ---------------------------------------------------------------------------
# DELTA runtime process management
# ---------------------------------------------------------------------------

function Get-RunningDeltaProcesses {
    <#
      Identifies the actual DELTA server process(es) - node.exe running
      the deployed build\server\index.js entry point from THIS specific
      runtime directory - rather than every node.exe on the machine.
      Matching itself is Test-DeltaManagedProcessCommandLine's job (lib\
      DeltaInstaller.Common.ps1) - see that function's own header for the
      full two-signal algorithm (entry-point suffix + runtime root, both
      slash/case-normalized) and why a single absolute-path string match
      was confirmed unreliable and replaced. This function's only job is
      supplying the live candidate list (CIM) and this run's own
      $Script:DeltaRuntimeRoot to that predicate.

      Deliberately scoped to the CURRENT, non-service runtime only - see
      Test-DeltaManagedProcessCommandLine's own header for why a future
      Windows Service-managed instance (Phase 5) should be identified via
      the Service Control Manager instead of an extension of this
      heuristic.

      An ordinary PowerShell function, not array-guaranteed: like any
      command whose result count varies (0, 1, or many), a caller that
      needs collection semantics - .Count, a guaranteed-list foreach,
      indexing - is responsible for wrapping its own call, e.g. @(Get-
      RunningDeltaProcesses), rather than this function trying to force
      array-ness on every possible caller regardless of what it actually
      needs. (That would not even be reliable done here: PowerShell's
      implicit return/Write-Output re-enumerates whatever array it's
      given, so a bare `return @(...)` collapses right back to $null or
      a scalar for a 0- or 1-element result by the time a caller sees
      it - confirmed directly to throw "The property 'Count' cannot be
      found on this object", under this script's own Set-StrictMode
      -Version Latest, from exactly this shape. Forcing the guarantee
      through anyway needs an unusual `return ,@(...)` - correct, but a
      surprising thing to find in an ordinary function, and easy for a
      future edit to "simplify" back into the bug without realizing it.)
      Stop-RunningDeltaInstance is this function's one caller that
      actually needs array semantics, and wraps at its own call site
      accordingly; Resolve-DeltaApplicationPort (piped directly) and
      Confirm-DeltaRuntimeStarted (boolean context) don't need to, and
      deliberately don't.
    #>
    $candidates = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue
    if (-not $candidates) {
        return @()
    }

    return @($candidates | Where-Object { Test-DeltaManagedProcessCommandLine -CommandLine $_.CommandLine -DeltaRuntimeRoot $Script:DeltaRuntimeRoot })
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

function Invoke-DeltaTaskkill {
    <#
      Runs taskkill.exe for $ProcessId (plus $ExtraArguments, e.g. '/F'),
      without ever letting its own stderr reach the console or abort the
      script - confirmed directly that redirecting a failing native
      command's stderr through PowerShell (2>, in any form - merged with
      2>&1, or sent to a file - makes no difference) wraps each line in a
      terminating NativeCommandError under this script's own
      Set-StrictMode -Version Latest + $ErrorActionPreference = 'Stop',
      even though the exact same call with NO stderr redirection at all
      merely lets taskkill's raw text (e.g. "ERROR: The process with PID
      nnnn could not be terminated. Reason: This process can only be
      terminated forcefully...") print straight to the console instead.
      Neither behavior is acceptable here: that message describes the
      GRACEFUL attempt not having worked yet, which is a normal,
      expected, already-handled outcome (Stop-RunningDeltaInstance falls
      back to /F for exactly this reason) - not a real error, and
      definitely not something that should be allowed to throw.

      $ErrorActionPreference is relaxed to 'Continue' for only the
      duration of this one call (restored immediately after, even on a
      throw, via try/finally) so the redirected stderr can be captured
      instead of raised - Test-DeltaDatabaseExists already uses this
      exact pattern for the same class of problem, not a new technique
      introduced here.

      The captured text is never shown on the console - only handed to
      Write-Verbose, so an operator who wants to see exactly what
      Windows said can re-run with -Verbose, while the normal install
      output stays clean. This changes nothing about whether or how
      taskkill is invoked, its arguments, or its timeout/retry behavior
      - all of that still belongs entirely to Stop-RunningDeltaInstance.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [string[]]$ExtraArguments = @()
    )

    $argumentList = @('/PID', $ProcessId) + $ExtraArguments
    $previousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $captured = & taskkill.exe $argumentList 2>&1
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    $capturedText = ($captured | ForEach-Object { $_.ToString() } | Where-Object { $_ }) -join "`n"
    if ($capturedText) {
        Write-Verbose "taskkill.exe $($argumentList -join ' '): $capturedText"
    }
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

      The console only ever reports what actually happened: a quiet
      success line when the graceful attempt alone worked, one
      informational line when it didn't and the (designed, expected)
      force fallback took over, and an error only in the one case
      that's genuinely fatal - both attempts failing. Falling back to
      force is not itself a failure, so it's never reported as one - see
      Invoke-DeltaTaskkill for why Windows' own "could not be
      terminated" message specifically must never reach the console
      either, on top of that.
    #>
    # @() wraps the call, not just its result, so a single match is never
    # unwrapped to a bare object before .Count/foreach below treat it as
    # a list - see Get-RunningDeltaProcesses' own header for why that
    # guarantee belongs here, at the one call site that needs it, rather
    # than inside the function itself.
    $processes = @(Get-RunningDeltaProcesses)
    if (-not $processes -or $processes.Count -eq 0) {
        Write-Detail 'No running DELTA instance detected.'
        return
    }

    foreach ($proc in $processes) {
        Write-Step 'Stopping existing DELTA...'

        Invoke-DeltaTaskkill -ProcessId $proc.ProcessId
        if (-not (Wait-ForProcessExit -ProcessId $proc.ProcessId -TimeoutSeconds 10)) {
            Write-Host ''
            Write-Detail 'Graceful shutdown did not complete.'
            Write-Host ''
            Write-Step 'Forcing shutdown...'
            Invoke-DeltaTaskkill -ProcessId $proc.ProcessId -ExtraArguments @('/F')

            if (-not (Wait-ForProcessExit -ProcessId $proc.ProcessId -TimeoutSeconds 10)) {
                Stop-Setup @"
Unable to stop the existing DELTA instance.

PID:
$($proc.ProcessId)

The installer cannot safely continue while the previous DELTA instance is still running.
"@
            }
        }

        Write-Success '    DELTA stopped successfully.'
    }
}

function Confirm-DeltaRuntimeNotRunning {
    <#
      Ensures no DELTA instance from a previous run is still bound to the
      application port before this run starts a fresh one. Deliberately
      does not restart anything itself - Start-DeltaRuntimeForValidation
      (called right after this, from the orchestration block) owns that,
      so this function's only job is guaranteeing a clean start: nothing
      already bound to $Script:DeltaBackendPort when it runs.

      A no-op when Resolve-DeltaApplicationPort already recorded that the
      operator chose to leave the existing managed instance running
      ($Script:DeltaSkipManagedInstanceRestart) - stopping it here would
      silently override that explicit choice.
    #>
    Show-Section -Title 'DELTA Runtime Status'

    if ($Script:DeltaSkipManagedInstanceRestart) {
        Write-Detail "Leaving the existing DELTA instance running, per the operator's choice above."
        return
    }

    Write-Step 'Checking for an already-running DELTA instance...'
    Stop-RunningDeltaInstance
}

# ---------------------------------------------------------------------------
# DELTA application startup (installer validation step)
#
# An interim convenience until Phase 5 (Windows Service, see
# docs/08-development-roadmap.md) supersedes it: starts DELTA once, right
# after installation/upgrade, so the operator gets a working URL
# immediately instead of having to run start.bat by hand. Deliberately
# does none of what a real service would - no restart policy, no crash
# supervision, no watchdog - see Start-DeltaRuntimeForValidation's own
# header. Registration of the installation as complete
# (Register-DeltaInstallation) only happens after every function in this
# section has succeeded - a failed start or a failed verification stops
# the installer before the registry ever claims success.
# ---------------------------------------------------------------------------

function Resolve-DeltaApplicationPort {
    <#
      Determines the port DELTA will be started on for this run, reusing
      the exact same PORT-reading contract setup-nginx.ps1/setup-iis.ps1
      already rely on (Resolve-DeltaBackendPort, lib\DeltaInstaller.Common.ps1)
      instead of a second .env parser: PORT absent -> $Script:
      DefaultDeltaBackendPort (3000); present and valid -> used as-is;
      present and invalid -> Stop-Setup. That call sets $Script:
      DeltaBackendPort, which this function then treats only as a
      starting point - .env is never assumed to already describe a port
      that's actually free right now.

      The "absent" branch is a backward-compatibility path now, not the
      expected case: .env.example ships PORT="3000" explicitly (a plain
      default, like PUBLIC_URL - see New-DeltaEnvironmentFile), so every
      fresh install's .env already states its port outright, and every
      later run of this installer reads that same value back as the
      authoritative one - never re-inferring a default on an installation
      that already has one. "Absent" only remains reachable for a .env
      an operator hand-edited to remove PORT, or one from before this
      default existed - Resolve-DeltaBackendPort still needs to do
      something sane there, but a normal install never exercises it.

      If that port is available, nothing else happens: $Script:
      DeltaBackendPort is left exactly as Resolve-DeltaBackendPort set
      it, $Script:DeltaApplicationPortChanged stays $false, and Update-
      DeltaApplicationPortEnvironment (called later, unconditionally,
      from the orchestration block) becomes a no-op - this is what keeps
      an already-correct .env completely untouched by this feature.

      If it's occupied, the FIRST question is whose process this actually
      is - Get-RunningDeltaProcesses cross-referenced by PID against
      Test-TcpPortAvailable's own OwningProcessId, never anything read
      from the registry (that stays exclusively a preference store - see
      Resolve-DeltaManagedInstanceRestartDecision):

        - If it's this installer's own managed DELTA instance (the
          previous version, still running), this is not a port conflict
          at all - it's the exact instance this run is about to replace.
          Resolve-DeltaManagedInstanceRestartDecision decides whether to
          proceed with a stop+restart, and $Script:DeltaBackendPort is
          left completely alone either way. A declined restart sets
          $Script:DeltaSkipManagedInstanceRestart so Confirm-
          DeltaRuntimeNotRunning/Start-DeltaRuntimeForValidation/Confirm-
          DeltaRuntimeStarted (called later, unconditionally, from the
          orchestration block) each become a no-op rather than
          overriding that choice.
        - Otherwise, it's a genuine conflict: explained (owning process,
          via the same Test-TcpPortAvailable diagnostic Resolve-
          PostgresPort's analogous prompt already uses) and the operator
          is prompted for a replacement - re-prompting on an invalid port
          number (Test-ValidTcpPort) or another occupied one, exactly
          like Resolve-PostgresPort's own loop, until a valid, genuinely
          free port is entered. The port is never changed silently: only
          an explicit operator answer here can move $Script:
          DeltaBackendPort away from whatever Resolve-DeltaBackendPort
          first read, and only then does $Script:DeltaApplicationPortChanged
          become $true.
    #>
    $Script:DeltaEnvPath = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath '.env'
    $Script:DeltaSkipManagedInstanceRestart = $false

    Resolve-DeltaBackendPort
    $Script:DeltaApplicationPortChanged = $false

    $check = Test-TcpPortAvailable -Port $Script:DeltaBackendPort
    if ($check.Available) {
        Write-Success "    Port $($Script:DeltaBackendPort) is available."
        return
    }

    $managedProcess = Get-RunningDeltaProcesses | Where-Object { [int]$_.ProcessId -eq [int]$check.OwningProcessId } | Select-Object -First 1
    if ($managedProcess) {
        Write-Host ''
        Write-Host ('-' * $Script:BannerWidth)
        Write-Host 'DELTA Runtime'
        Write-Host ('-' * $Script:BannerWidth)
        Write-Host ''
        Write-Host 'Configured backend port:'
        Write-Host $Script:DeltaBackendPort
        Write-Host ''
        Write-Host 'Existing DELTA instance detected.'
        Write-Host ''
        Write-Host 'PID:'
        Write-Host $managedProcess.ProcessId

        if (Resolve-DeltaManagedInstanceRestartDecision) {
            Write-Host ''
            Write-Host 'Preparing to stop and restart DELTA...'
        }
        else {
            $Script:DeltaSkipManagedInstanceRestart = $true
            Write-Host ''
            Write-Host 'Leaving the existing DELTA instance running, untouched, as requested.'
        }
        return
    }

    Write-Host ''
    Write-Host 'Configured backend port:'
    Write-Host $Script:DeltaBackendPort
    Write-Host ''
    Write-Host 'Port conflict detected.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "Port $($Script:DeltaBackendPort) is currently used by:"
    Write-Host ''
    Write-Host $check.OwnerDescription
    Write-Host ''
    Write-Host 'Choose another available port.'

    while ($true) {
        $entered = Read-Host -Prompt 'Enter DELTA application port'
        $candidate = $entered.Trim()

        if (-not (Test-ValidTcpPort -Value $candidate)) {
            Write-Host "'$candidate' is not a valid port number (1-65535). Try again." -ForegroundColor Yellow
            continue
        }

        $portNumber = [int]$candidate
        $recheck = Test-TcpPortAvailable -Port $portNumber
        if ($recheck.Available) {
            $Script:DeltaBackendPort = $portNumber
            $Script:DeltaApplicationPortChanged = $true
            Write-Host ''
            Write-Success "    Port $portNumber is available. DELTA will use this port."
            return
        }

        Write-Host ''
        Write-Host 'Port conflict detected.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host "Port $portNumber is currently used by:"
        Write-Host ''
        Write-Host $recheck.OwnerDescription
        Write-Host ''
        Write-Host 'Choose another available port.'
    }
}

function Resolve-DeltaManagedInstanceRestartDecision {
    <#
      Decides whether to stop and restart an already-running, installer-
      managed DELTA instance that's occupying the configured port -
      called only once Resolve-DeltaApplicationPort has already confirmed
      (via Get-RunningDeltaProcesses, cross-referenced by PID - never via
      the registry) that the occupying process actually IS that managed
      instance. The ManagedInstanceRestartPolicy registry value this reads/
      writes (Get-/Set-DeltaManagedInstanceRestartPolicy - Registry Registration
      section, below) stores only the operator's remembered PREFERENCE;
      it plays no part in deciding whose process this is, which stays
      exclusively Get-RunningDeltaProcesses' job, unchanged.

      Three cases:
        - No preference recorded yet (Get-DeltaManagedInstanceRestartPolicy
          returns $null) - a brand new installation, or one from before
          this preference existed. Shows the one-time explanatory
          prompt below (bare Enter defaults to Yes/recommended - the same
          "blank means the recommended choice" convention Read-
          ExistingPostgresChoice's analogous reuse-instead-of-fresh-install
          prompt already uses, which is why this doesn't reuse the shared
          Read-DeltaYesNoConfirmation helper: that one's bare-Enter-means-
          No convention is for a different situation - an action with no
          particular recommended answer - not this one), persists
          whichever answer is given, and that same answer governs this
          run too - asking twice for the same decision in the same run
          would be exactly the repetitive UX this feature exists to
          remove.
        - Preference is 1 (always restart) - returns $true immediately,
          no prompt at all.
        - Preference is 0 (always ask) - asks every time via the shared
          Read-DeltaYesNoConfirmation helper (bare Enter means No here,
          correctly - unlike the one-time prompt above, this has no
          "recommended" framing, just a plain repeated confirmation, so
          the shared helper's own default fits as-is), but never
          re-persists a different value from a single answer - 0 means
          "keep asking me", not "downgrade to a different stored value by
          answering once".
    #>
    $preference = Get-DeltaManagedInstanceRestartPolicy

    if ($null -eq $preference) {
        Write-Host ''
        Write-Host ('-' * $Script:BannerWidth)
        Write-Host ''
        Write-Host 'Would you like future updates to automatically stop and restart this DELTA instance?'
        Write-Host ''
        Write-Host '[Y] Yes (recommended)'
        Write-Host '[N] No (always ask)'
        Write-Host ''
        Write-Host ('-' * $Script:BannerWidth)
        Write-Host ''

        while ($true) {
            $choice = Read-Host -Prompt 'Choice [Y]'
            if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 'Y' }

            switch ($choice.Trim().ToUpperInvariant()) {
                'Y' {
                    Set-DeltaManagedInstanceRestartPolicy -Value 1
                    return $true
                }
                'N' {
                    Set-DeltaManagedInstanceRestartPolicy -Value 0
                    return $false
                }
            }
            Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow
        }
    }

    if ($preference -eq 1) {
        Write-Host ''
        Write-Host 'Restart policy:'
        Write-Host 'Always restart automatically.'
        return $true
    }

    return Read-DeltaYesNoConfirmation -Body {
        Write-Host 'Stop and restart it now?'
    }
}

function Update-DeltaApplicationPortEnvironment {
    <#
      Writes the operator-selected DELTA application port back into .env
      via the exact same managed-values mechanism (Update-
      ManagedEnvironmentLines) New-DeltaEnvironmentFile already uses for
      DATABASE_URL - no second .env-writing mechanism. A no-op whenever
      Resolve-DeltaApplicationPort didn't have to change anything
      ($Script:DeltaApplicationPortChanged still $false): a correctly-
      configured .env - PORT absent and 3000 free, or PORT already set to
      whatever's actually free - is left completely untouched, never
      rewritten to the same value it already had.
    #>
    if (-not $Script:DeltaApplicationPortChanged) {
        Write-Detail '.env already reflects an available port - no change needed.'
        return
    }

    Write-Step 'Updating .env with the selected DELTA application port...'

    $envTargetPath = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath '.env'
    if (-not (Test-Path -LiteralPath $envTargetPath)) {
        Stop-Setup "DELTA environment file not found: $envTargetPath. Run the database setup phase first."
    }

    Backup-DeltaEnvironmentFile -Path $envTargetPath

    $sourceLines = Get-Content -LiteralPath $envTargetPath
    $managedValues = [ordered]@{ PORT = $Script:DeltaBackendPort }
    $updatedLines = Update-ManagedEnvironmentLines -SourceLines $sourceLines -ManagedValues $managedValues
    Set-Content -LiteralPath $envTargetPath -Value $updatedLines -Encoding utf8

    Write-Success "    .env updated (PORT=$($Script:DeltaBackendPort))."
}

function Get-DeltaStartupLogPaths {
    <#
      The two fixed log file paths Start-DeltaRuntimeForValidation
      redirects DELTA's stdout/stderr into, and Get-DeltaStartupFailureMessage
      reads back from on a verification failure - one place computing
      both so they can never drift apart between the two call sites.
      Lives under <AppRoot>\logs - already created and proven writable by
      Initialize-DeltaRuntimeDirectories earlier in this run, so nothing
      here needs to create or permission it again.
    #>
    $logsDirectory = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'logs'
    return [PSCustomObject]@{
        StdOut = Join-Path -Path $logsDirectory -ChildPath 'delta-startup-stdout.log'
        StdErr = Join-Path -Path $logsDirectory -ChildPath 'delta-startup-stderr.log'
    }
}

function Start-DeltaRuntimeForValidation {
    <#
      Starts DELTA so the installer can hand the operator a working URL
      immediately - an interim convenience for this validation phase,
      standing in for the eventual Windows Service (Phase 5, see
      docs/08-development-roadmap.md). Deliberately does none of what a
      real service would: no restart policy, no crash supervision, no
      watchdog. It starts the process once; Confirm-DeltaRuntimeStarted
      (called right after, from the orchestration block) either confirms
      it came up cleanly or stops the installer outright. Whichever
      happens, this function's own job ends the moment the process has
      been launched.

      Runs the exact command start.bat itself wraps - `dotenv -e .env --
      yarn start` - rather than invoking start.bat directly: start.bat's
      own trailing `pause` is documented (docs/02 - Windows Service
      installation) as something that hangs a non-interactive caller
      indefinitely, which is exactly why the NSSM example there already
      bypasses start.bat and invokes the underlying command directly
      instead of wrapping it. This reuses that same lesson rather than
      re-learning it.

      Launched detached (Start-Process, no -Wait) with its console window
      hidden and stdout/stderr redirected to <AppRoot>\logs\
      (Get-DeltaStartupLogPaths) - the only place this run's startup
      diagnostics go, reused as-is rather than standing up a separate
      logging mechanism. Confirm-DeltaRuntimeNotRunning must already have
      run before this - never called from here - so this is always a
      clean start, never a restart racing a not-yet-stopped previous
      instance.

      A no-op when $Script:DeltaSkipManagedInstanceRestart is set
      (Resolve-DeltaApplicationPort) - the operator chose to leave the
      existing managed instance running rather than restart it, so there
      is nothing to launch this run.
    #>
    Show-Section -Title 'Starting DELTA'

    if ($Script:DeltaSkipManagedInstanceRestart) {
        Write-Detail 'Skipping automatic startup - the existing DELTA instance was left running untouched.'
        return
    }

    Write-Step 'Starting DELTA for installation validation...'
    Write-Detail 'This is an interim step - DELTA is not yet running as a supervised Windows Service.'

    $logPaths = Get-DeltaStartupLogPaths
    Write-Detail "Standard output: $($logPaths.StdOut)"
    Write-Detail "Standard error : $($logPaths.StdErr)"

    try {
        Start-Process -FilePath 'cmd.exe' `
            -ArgumentList '/c dotenv -e .env -- yarn start' `
            -WorkingDirectory $Script:DeltaRuntimeRoot `
            -WindowStyle Hidden `
            -RedirectStandardOutput $logPaths.StdOut `
            -RedirectStandardError $logPaths.StdErr `
            | Out-Null
    }
    catch {
        Stop-Setup "Failed to launch DELTA: $($_.Exception.Message)"
    }

    Write-Success '    DELTA start requested.'
}

function Test-DeltaHttpEndpoint {
    <#
      A single HTTP probe against $Url - returns $true for any response
      the server actually sent (status < 500), $false for a connection-
      level failure (nothing listening yet, connection refused/reset) or
      a server error. Invoke-WebRequest throws on a non-2xx status in
      Windows PowerShell 5.1, so a thrown exception that still carries a
      real HTTP response is treated as "responded", not as a failure -
      DELTA answering with, say, a redirect or a 404 already proves the
      HTTP server itself is up, which is all this specific check is
      responsible for confirming.
    #>
    param([Parameter(Mandatory)][string]$Url)

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return ($response.StatusCode -lt 500)
    }
    catch {
        $webResponse = $_.Exception.Response
        if ($webResponse -and $webResponse.StatusCode) {
            return ([int]$webResponse.StatusCode -lt 500)
        }
        return $false
    }
}

function Get-DeltaStartupFailureMessage {
    <#
      Builds a Stop-Setup message that always points at the two startup
      log files (Get-DeltaStartupLogPaths) and, when the stderr log
      actually has content, includes its last few lines inline - so a
      failed verification is diagnosable straight from the console
      output that already stopped the installer, not just from a path
      the operator still has to go open themselves.
    #>
    param([Parameter(Mandatory)][string]$Reason)

    $logPaths = Get-DeltaStartupLogPaths
    $message = "$Reason`n`nStartup logs:`n$($logPaths.StdOut)`n$($logPaths.StdErr)"

    if (Test-Path -LiteralPath $logPaths.StdErr) {
        $tail = @(Get-Content -LiteralPath $logPaths.StdErr -Tail 15 -ErrorAction SilentlyContinue)
        if ($tail.Count -gt 0) {
            $message += "`n`nLast lines of stderr:`n$($tail -join "`n")"
        }
    }

    return $message
}

function Confirm-DeltaRuntimeStarted {
    <#
      Layered startup verification, in the order Test-DeltaNginxStartupHealth
      (setup-nginx.ps1) already established for the same problem: a
      running process alone is never reported as success, and neither is
      a bound port on its own - only escalating through process, then
      port, then a real HTTP round-trip proves DELTA actually came up.

      Each wait loop re-checks Get-RunningDeltaProcesses on every
      iteration, not just once at the start, so a process that starts and
      then crashes mid-wait (e.g. a bad DATABASE_URL) fails fast with a
      real diagnostic instead of running out the full timeout first.

      The port-wait loop specifically tracks whether it has EVER observed
      the managed process before treating "not found" as a failure -
      confirmed directly (real captured launch, dotenv-cli -> yarn.js ->
      the react-router-serve .bin shim -> the final node.exe actually
      running build/server/index.js) that this multi-hop chain takes
      real, measurable time to reach its last hop, which is the only one
      Get-RunningDeltaProcesses can ever match. On the loop's first
      iteration - which runs immediately, since Start-Process returns as
      soon as the top-level cmd.exe exists, not once the whole chain has
      - "not found yet" is the normal, expected state, not evidence of a
      crash; only a transition from "was found" to "no longer found"
      means it actually exited. Without this, a perfectly healthy
      startup that simply takes a moment to descend through that chain
      gets reported as failed while the real process goes on to start
      successfully in the background, unaware the installer already gave
      up on it.

      A no-op when $Script:DeltaSkipManagedInstanceRestart is set - there
      is nothing to verify this run, since Start-DeltaRuntimeForValidation
      didn't start anything either. Reports that plainly, in a dedicated
      banner, rather than letting the run end looking like a normal
      success: the runtime files, dependencies, .env, and database were
      all still updated by the phases before this one (a real, completed
      deployment - see Register-DeltaInstallation, still called
      unconditionally after this), but the deployment is not yet ACTIVE -
      the process actually serving traffic is still whatever was running
      before this install/update started. Those are two different facts,
      and this is the one place that draws the line between them, so
      nothing downstream (the final summary included) can imply HTTP
      validation succeeded when it never ran.
    #>
    Show-Section -Title 'Verifying DELTA Startup'

    if ($Script:DeltaSkipManagedInstanceRestart) {
        Write-Host ''
        Write-Host ('-' * $Script:BannerWidth)
        Write-Host ''
        Write-Host 'Deployment completed.'
        Write-Host ''
        Write-Host 'The existing DELTA instance was left running.'
        Write-Host ''
        Write-Host 'The updated deployment will become active after DELTA is restarted manually.'
        Write-Host ''
        Write-Host 'Current running instance may still be the previous deployment.'
        Write-Host ''
        Write-Host ('-' * $Script:BannerWidth)
        return
    }

    Write-Step 'Waiting for DELTA to start listening on its configured port...'
    $portDeadline = (Get-Date).AddSeconds($Script:DeltaStartupPortTimeoutSeconds)
    $isListening = $false
    $hasBeenObservedRunning = $false
    while ((Get-Date) -lt $portDeadline) {
        if (Get-RunningDeltaProcesses) {
            $hasBeenObservedRunning = $true
        }
        elseif ($hasBeenObservedRunning) {
            Stop-Setup (Get-DeltaStartupFailureMessage -Reason 'DELTA exited before it finished starting.')
        }
        if (-not (Test-TcpPortAvailable -Port $Script:DeltaBackendPort).Available) {
            $isListening = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $isListening) {
        Stop-Setup (Get-DeltaStartupFailureMessage -Reason "DELTA did not start listening on port $($Script:DeltaBackendPort) within $($Script:DeltaStartupPortTimeoutSeconds) seconds.")
    }
    Write-Success "    DELTA is listening on port $($Script:DeltaBackendPort)."

    Write-Step 'Confirming DELTA responds over HTTP...'
    $url = "http://localhost:$($Script:DeltaBackendPort)/"
    $httpDeadline = (Get-Date).AddSeconds($Script:DeltaStartupHttpTimeoutSeconds)
    $isResponding = $false
    while ((Get-Date) -lt $httpDeadline) {
        if (-not (Get-RunningDeltaProcesses)) {
            Stop-Setup (Get-DeltaStartupFailureMessage -Reason 'DELTA exited before it responded over HTTP.')
        }
        if (Test-DeltaHttpEndpoint -Url $url) {
            $isResponding = $true
            break
        }
        Start-Sleep -Milliseconds 1000
    }
    if (-not $isResponding) {
        Stop-Setup (Get-DeltaStartupFailureMessage -Reason "DELTA did not respond over HTTP at $url within $($Script:DeltaStartupHttpTimeoutSeconds) seconds.")
    }
    Write-Success "    DELTA responded successfully at $url."
}

function Initialize-Setup {
    Show-Section -Title 'DELTA Windows Installer' -Subtitle "Version $Script:DeltaInstallerVersion"

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
    Show-Warning -Message @(
        'You are about to perform a completely fresh DELTA installation.'
        'This will remove the existing application directory.'
    )
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
# Registry registration
# ---------------------------------------------------------------------------

# The single, authoritative location future DELTA utilities (setup-nginx.ps1,
# a future setup-iis.ps1, upgrade.ps1, uninstall.ps1) are meant to read to
# discover this installation, instead of each one separately assuming a fixed
# path the way this installer's own scripts historically have (see
# $Script:DefaultDeltaRuntimeRoot in lib\DeltaInstaller.Common.ps1 - that
# remains only a prompt default, never an assumption an installed copy
# actually lives there). Register-DeltaInstallation owns InstallPath/Version
# here; Get-/Set-DeltaManagedInstanceRestartPolicy (below) own a third,
# independent value on the same key, ManagedInstanceRestartPolicy - an
# operator PREFERENCE only, never used to identify which process is
# DELTA's (that stays exclusively Get-RunningDeltaProcesses' job, see
# Resolve-DeltaApplicationPort/Resolve-DeltaManagedInstanceRestartDecision).
$Script:DeltaRegistryKeyPath = 'HKLM:\SOFTWARE\PreventionWeb\DELTA'

function Register-DeltaInstallation {
    <#
      The last real phase of this installer - writes/updates
      $Script:DeltaRegistryKeyPath with where DELTA was installed
      (InstallPath, from $Script:DeltaRuntimeRoot - the actual resolved
      directory, per Resolve-DeltaAppRoot, never a hardcoded C:\DELTA) and
      which version of this installer put it there (Version, from
      $Script:DeltaInstallerVersion - lib\DeltaInstaller.Version.ps1 -
      never hand-duplicated here). Only InstallPath/Version exist at this
      stage; no other registry metadata is introduced.

      Called last in the orchestration block below, only once every real
      installation phase before it has already succeeded - a failed or
      canceled installation must never register itself as complete. Only
      the purely cosmetic final summary runs after this, so "this function
      ran" and "the installation succeeded" are the same fact.

      Still runs unconditionally even when $Script:DeltaSkipManagedInstanceRestart
      is set (the operator declined to restart an already-running managed
      instance - see Resolve-DeltaApplicationPort/Confirm-DeltaRuntimeStarted):
      "the deployment succeeded" (files, dependencies, .env, database -
      everything this registers) and "the deployment is active" (the
      running process actually reflects it) are different facts, and only
      the first one is this function's job. Show-InstallationSummary's own
      -Activated parameter is what reports the second one honestly -
      InstallPath/Version being current and accurate is true, and worth
      recording, regardless of which process happens to be listening on
      the configured port right now.

      Idempotent by construction, not by an explicit "does the key already
      exist" branch: Set-ItemProperty creates InstallPath/Version if
      they're missing and simply overwrites them if they're not, so the
      exact same two calls are correct whether this machine has never seen
      a DELTA installation before or is being upgraded/reinstalled over an
      existing one - confirmed directly that Set-ItemProperty does not
      throw the way New-ItemProperty (without -Force) does against a
      property that already exists.

      Requires Administrator privileges to write under HKLM - checked
      explicitly here (the same per-action pattern Install-NodeMsi/
      Install-PostgresServer already use above) rather than assumed,
      since a re-run against an already-fully-installed, unchanged
      environment can otherwise complete every phase above without ever
      needing to elevate.
    #>

    Show-Section -Title 'Registry Registration'
    Write-Step 'Registering the DELTA installation in the Windows Registry...'
    Write-Detail "Key: $($Script:DeltaRegistryKeyPath)"

    if (-not (Test-IsAdministrator)) {
        Stop-Setup "Administrator privileges are required to write to $($Script:DeltaRegistryKeyPath). Re-run this script from an elevated PowerShell session."
    }

    try {
        if (-not (Test-Path -LiteralPath $Script:DeltaRegistryKeyPath)) {
            New-Item -Path $Script:DeltaRegistryKeyPath -Force -ErrorAction Stop | Out-Null
        }

        Set-ItemProperty -LiteralPath $Script:DeltaRegistryKeyPath -Name 'InstallPath' -Value $Script:DeltaRuntimeRoot -Type String -ErrorAction Stop
        Set-ItemProperty -LiteralPath $Script:DeltaRegistryKeyPath -Name 'Version' -Value $Script:DeltaInstallerVersion -Type String -ErrorAction Stop
    }
    catch {
        Stop-Setup "Failed to register the DELTA installation in the Windows Registry ($($Script:DeltaRegistryKeyPath)): $($_.Exception.Message). This usually means Administrator privileges are required - re-run this script from an elevated PowerShell session."
    }

    Write-Success '    Registry key written.'
    Write-Detail "InstallPath: $($Script:DeltaRuntimeRoot)"
    Write-Detail "Version: $($Script:DeltaInstallerVersion)"
}

function Get-DeltaManagedInstanceRestartPolicy {
    <#
      Reads ManagedInstanceRestartPolicy from $Script:DeltaRegistryKeyPath -
      the operator's remembered answer to "should future runs
      automatically stop and restart an already-running, installer-
      managed DELTA instance without asking" (Resolve-
      DeltaManagedInstanceRestartDecision). Returns $null when the value
      has never been set (a brand new installation, or one from before
      this preference existed) - callers use $null specifically to mean
      "ask the first-time setup question", never confusing it with an
      explicit 0 ("always ask").

      Uses the same Get-RegistryPropertyValue helper (lib\
      DeltaInstaller.Common.ps1) Get-DeltaInstallPath already relies on
      for the identical "read a possibly-absent registry value safely
      under Set-StrictMode" problem, rather than a second copy of that
      pattern. Read-only: never creates the registry key - a missing key
      here just means "no preference recorded yet", already
      indistinguishable from, and handled identically to, a key that
      exists but lacks this one value.
    #>
    $entry = Get-ItemProperty -LiteralPath $Script:DeltaRegistryKeyPath -Name 'ManagedInstanceRestartPolicy' -ErrorAction SilentlyContinue
    $rawValue = Get-RegistryPropertyValue -InputObject $entry -Name 'ManagedInstanceRestartPolicy'
    if ($null -eq $rawValue) {
        return $null
    }
    return [int]$rawValue
}

function Set-DeltaManagedInstanceRestartPolicy {
    <#
      Persists the operator's ManagedInstanceRestartPolicy answer to
      $Script:DeltaRegistryKeyPath - the same registry key Register-
      DeltaInstallation already owns (InstallPath/Version), just a third,
      independent value on it, stored as a DWord (Windows' own convention
      for a small-integer registry value). Named as a "policy", not an
      "AutoRestart" flag, specifically so a future third option (e.g. a
      maintenance-window-only restart) could be added as a new accepted
      value under this same name later, without a second registry value
      or a migration from the old one - even though only 0 ("ask") and 1
      ("always restart") are actually accepted today
      (Resolve-DeltaManagedInstanceRestartDecision).

      Requires Administrator privileges, the same per-action check every
      other HKLM write in this script already uses - but this can run
      before Register-DeltaInstallation itself (a first-time restart
      decision can arise before this installer would otherwise touch the
      registry at all, on an ordinary "Update DELTA" run), so the key is
      created here too if it doesn't exist yet, exactly the way Register-
      DeltaInstallation does for the same key.
    #>
    param([Parameter(Mandatory)][ValidateSet(0, 1)][int]$Value)

    if (-not (Test-IsAdministrator)) {
        Stop-Setup "Administrator privileges are required to write to $($Script:DeltaRegistryKeyPath). Re-run this script from an elevated PowerShell session."
    }

    try {
        if (-not (Test-Path -LiteralPath $Script:DeltaRegistryKeyPath)) {
            New-Item -Path $Script:DeltaRegistryKeyPath -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -LiteralPath $Script:DeltaRegistryKeyPath -Name 'ManagedInstanceRestartPolicy' -Value $Value -Type DWord -ErrorAction Stop
    }
    catch {
        Stop-Setup "Failed to save the DELTA restart preference in the Windows Registry ($($Script:DeltaRegistryKeyPath)): $($_.Exception.Message). This usually means Administrator privileges are required - re-run this script from an elevated PowerShell session."
    }
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

    if (-not (Show-MainMenu)) {
        Write-Host ''
        Write-Host 'Installation canceled.'
        exit 0
    }

    Update-DeltaRuntimeArtifact -RuntimeDirectory $Script:DeltaRuntimeSourceDirectory -ProjectRoot $Script:ProjectRoot
    Resolve-DeltaAppRoot
    Resolve-ExistingDeltaDeployment
    Install-NodeJs
    Install-PostgreSql
    Install-PostGIS
    Install-DeltaRuntime
    Install-DeltaDependencies
    Initialize-DeltaRuntimeDirectories
    Complete-DatabaseSetup
    Resolve-DeltaApplicationPort
    Update-DeltaApplicationPortEnvironment
    Confirm-DeltaRuntimeNotRunning
    Start-DeltaRuntimeForValidation
    Confirm-DeltaRuntimeStarted
    Register-DeltaInstallation

    # Future phases (not yet implemented):
    # Install-WindowsService (Phase 5) - supersedes Start-DeltaRuntimeForValidation/
    #   Confirm-DeltaRuntimeStarted above, which exist only as an interim,
    #   installation-validation convenience (no restart policy, no crash
    #   supervision, no watchdog - see Start-DeltaRuntimeForValidation's own
    #   header) until a real supervised service takes over DELTA's lifecycle.
    # Validate-Deployment    (Phase 6)
    #
    # Database upgrade path (detect an existing DELTA installation ->
    # validate it -> update DATABASE_URL if required -> invoke
    # upgrade_database.ps1) is intentionally not wired in here yet -
    # upgrade_database.ps1 exists and is independently runnable today,
    # but the automatic fresh-vs-upgrade detection this orchestration
    # would need is deferred pending real operational experience with
    # the fresh-install path first. See docs/08-development-roadmap.md.

    $Script:PostgresSuperuserPassword = $null

    # Final installation summary - purely a console-output concern. Every
    # piece of state it prints (DeltaRuntimeRoot, the .env/start.bat paths
    # derived from it, the resolved application port, whether the
    # deployment is actually active) was already established by the
    # phases above; this section performs no installation actions of its
    # own, and reuses Show-InstallationSummary rather than inlining its
    # own formatting. Activated is the exact inverse of $Script:
    # DeltaSkipManagedInstanceRestart - "startup validation genuinely ran
    # and passed" is the only thing that flag ever gates.
    $deltaHome    = $Script:DeltaRuntimeRoot
    $envPath      = Join-Path -Path $deltaHome -ChildPath '.env'
    $startBatPath = Join-Path -Path $deltaHome -ChildPath 'start.bat'
    $activated    = -not $Script:DeltaSkipManagedInstanceRestart

    Show-InstallationSummary -DeltaHome $deltaHome -EnvPath $envPath -StartBatPath $startBatPath -Port $Script:DeltaBackendPort -Activated $activated

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

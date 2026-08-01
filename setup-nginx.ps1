#Requires -Version 5.1
<#
.SYNOPSIS
    Installs and configures NGINX as an optional reverse proxy for DELTA.

.DESCRIPTION
    Separate from setup.ps1 - DELTA runs standalone on http://localhost:3000
    without this script, and nothing here is a dependency of the main
    installer. Run this only when a native reverse proxy in front of DELTA
    is actually wanted (e.g. to serve DELTA on port 80, or as the future home
    of a real TLS certificate).

    Before anything else - even before checking for an existing NGINX
    installation - Resolve-DeltaInstallation confirms a DELTA installation
    actually exists on this machine, via Get-DeltaInstallPath
    (lib\DeltaInstaller.Common.ps1's shared discovery helper: the Windows
    Registry key setup.ps1's own Register-DeltaInstallation writes, falling
    back to the legacy C:\DELTA\.env convention for installations that
    predate it). This script is a CONSUMER of that discovery, never a
    second implementation of it, and never assumes DELTA lives at a fixed
    C:\DELTA path itself. No installation found means nothing else in this
    script runs.

    Conservative by design: installing a FRESH copy of NGINX is something
    this script is willing to automate; modifying an EXISTING one is not.
    Once a DELTA installation has been confirmed, the next thing this
    script does - before installing anything, before writing a single
    configuration file - is check whether C:\nginx\nginx.exe already
    exists. If it does, the script hands off to an interactive management
    menu (Show-DeltaNginxManagementMenu) instead of installing or
    reconfiguring anything - nothing here ever touches nginx.conf/
    delta.conf or installs anything, and the options offered depend on
    Get-DeltaNginxRuntimeState (see the "Runtime state" section below):
    Validate/Reload/Restart/Stop/Exit when actually Running, just Start/
    Exit when cleanly Stopped, and a specific explanation plus Force Stop/
    Exit when Broken (an inconsistency between the pid file and the
    process list - see that section's own header for why this exists and
    what it protects against). This installer must never assume it owns
    an existing NGINX installation - a real, hand-configured,
    already-running reverse proxy at this exact default path is a
    realistic thing to find on a real machine, not a hypothetical edge
    case, and overwriting it would be a production incident, not a
    convenience.

    Only once that check has passed (no existing installation found) does
    it ask for one more explicit confirmation - Read-DeltaNginxInstallConfirmation,
    a Y/N prompt (default No) naming the version to be installed and the
    installation directory - before proceeding, in seven phases:

      1. Install-Nginx - installs the one pinned version, $Script:NginxVersion
         (see the Configuration section below), from a local
         installers\nginx-<version>.zip if that exact file is present, or
         downloads the official Windows ZIP distribution from nginx.org
         otherwise - never a third-party installer or repackaging, and
         never any version other than the one pinned. Also ensures
         conf\conf.d\ exists, since the official ZIP distribution does not
         ship that directory itself.

      2. Install-DeltaSslCertificate - the SSL Certificate Wizard (see
         docs\todo\TODO-setup-nginx-enhancements.md, Phase 2), now also
         covering Existing Certificate Handling (Phase 6). If
         C:\nginx\certs\delta.crt and delta.key are BOTH already present,
         asks the administrator to Replace, Keep, or Cancel instead of the
         original "do you already have one?" question - Replace and the
         original "Yes" both hand off to the same Install-DeltaSslCertificateFiles
         (selects the certificate and private key via standard Windows
         file selection dialogs, validates both, copies them into
         C:\nginx\certs\), Keep leaves the existing files untouched but
         still configures HTTPS, and Cancel exits immediately (`exit 0`,
         bypassing this try/catch entirely) with nothing written or
         started. Either a fresh install or a kept existing certificate
         sets $Script:SslCertificateConfigured to $true. Answering "No" (no
         certificate at all, existing or new) is a complete no-op.

      3. Resolve-DeltaBackendPort - Automatic DELTA Backend Port Detection
         (docs\todo\TODO-setup-nginx-enhancements.md, Phase 4). Reads PORT
         from the resolved DELTA installation's own .env file
         ($Script:DeltaEnvPath) via the shared Get-EnvFileValue helper
         (lib\DeltaInstaller.Common.ps1), falling back to
         $Script:DefaultDeltaBackendPort (3000) when PORT isn't set at
         all - but stopping the installer outright if PORT is present and
         not a valid TCP port number, rather than silently falling back.
         Sets $Script:DeltaBackendPort, consumed by a later phase.

      4. Resolve-DeltaWebsiteDomain (lib\DeltaInstaller.Common.ps1) -
         Website Domain Configuration (docs\todo\TODO-setup-nginx-
         enhancements.md, Phase 5). Prompts for the public hostname the
         generated virtual host should answer to, defaulting to
         "localhost" on a bare Enter, re-prompting (with the specific
         reason) on anything Test-DeltaWebsiteDomain rejects - a scheme, a
         port, a path, a space, a wildcard, or a string that isn't a valid
         DNS hostname. Deliberately implemented in the shared lib file,
         not this script, since it has no NGINX-specific knowledge at all
         - see that function's own header. Sets $Script:DeltaWebsiteDomain,
         consumed by the next phase.

      5. New-DeltaNginxConfiguration - writes C:\nginx\conf\nginx.conf and
         C:\nginx\conf\conf.d\delta.conf from the canonical templates in
         templates\nginx\ (this repository), rather than generating either
         file line-by-line from PowerShell. This deliberately replaces the
         large block of commented sample configuration NGINX itself ships
         in conf\nginx.conf with a minimal, DELTA-specific file. No backup
         step here - by the time this runs, the existing-installation check
         above has already guaranteed there is nothing pre-existing worth
         protecting. Automatically picks the DELTA virtual host template -
         templates\nginx\delta-https.conf if phase 2 just installed a
         certificate, templates\nginx\delta-http.conf otherwise (see
         docs\todo\TODO-setup-nginx-enhancements.md, Phase 3) - the
         administrator never selects a template manually. Bakes
         $Script:DeltaBackendPort and $Script:DeltaWebsiteDomain into that
         template's proxy_pass/server_name directives as it writes it out.

      6. Test-DeltaNginxConfiguration - runs `nginx -t` against the
         configuration just written. A validation failure stops the script
         immediately, before NGINX is ever started, and before the
         administrator is ever asked whether to start it.

      7. Start-DeltaNginx - starts NGINX, but only if the administrator
         says so: Read-DeltaNginxStartConfirmation (Y/N, default No) is
         only ever reached once Test-DeltaNginxConfiguration has already
         succeeded, and answering No skips Start-DeltaNginx entirely
         (Show-DeltaNginxSummary still runs either way). Whenever it does
         run, this is always a fresh start, never a reload - the
         existing-installation check above guarantees nothing at
         $Script:NginxHome was already running. A running process alone
         is never reported as success - Test-DeltaNginxStartupHealth
         (Managed Runtime State, see the "Runtime state" section below)
         confirms the pid file exists and actually matches the running
         process, and that every port this configuration should be
         listening on actually is, before "NGINX started successfully."
         is ever printed.

    Finishes by printing a summary (Show-DeltaNginxSummary).

    Re-running this script after it has already installed NGINX once is
    safe in the sense that nothing gets corrupted - but it will simply
    detect the NGINX it just installed and hand off to the same
    management menu everything else does. This script installs and
    configures NGINX exactly once; it is not a repeatable reconciler.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See lib\DeltaInstaller.Common.ps1's own header for why $Script:ProjectRoot
# must be computed here, before dot-sourcing it, rather than inside it.
$Script:ProjectRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Common.ps1')

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$Script:NginxHome            = 'C:\nginx'
$Script:NginxExePath         = Join-Path -Path $Script:NginxHome -ChildPath 'nginx.exe'
$Script:NginxConfDirectory   = Join-Path -Path $Script:NginxHome -ChildPath 'conf'
$Script:NginxMainConfigPath  = Join-Path -Path $Script:NginxConfDirectory -ChildPath 'nginx.conf'
$Script:NginxConfDDirectory  = Join-Path -Path $Script:NginxConfDirectory -ChildPath 'conf.d'
$Script:DeltaVHostConfigPath = Join-Path -Path $Script:NginxConfDDirectory -ChildPath 'delta.conf'

# Managed Runtime State (docs\todo\TODO-setup-nginx-enhancements.md, Phase 7) -
# the pid file location this installer owns and asserts, rather than trusting
# nginx's own undocumented compiled-in default to agree with $Script:NginxHome.
# templates\nginx\nginx.conf pins an explicit `pid logs/nginx.pid;` directive
# to match this exactly (see that template's own header) - Get-DeltaNginxPidFilePath
# is the one place this script computes it, so nothing else re-derives it.
$Script:NginxLogsDirectory = Join-Path -Path $Script:NginxHome -ChildPath 'logs'
$Script:NginxPidFilePath   = Join-Path -Path $Script:NginxLogsDirectory -ChildPath 'nginx.pid'

# SSL Certificate Wizard (docs\todo\TODO-setup-nginx-enhancements.md, Phase
# 2) - NGINX's own dedicated certs directory, never the original file
# locations the administrator selected them from (Install-DeltaSslCertificate
# below copies into these two fixed destinations).
$Script:NginxCertsDirectory     = Join-Path -Path $Script:NginxHome -ChildPath 'certs'
$Script:NginxCertificatePath    = Join-Path -Path $Script:NginxCertsDirectory -ChildPath 'delta.crt'
$Script:NginxCertificateKeyPath = Join-Path -Path $Script:NginxCertsDirectory -ChildPath 'delta.key'

$Script:SupportedCertificateExtensions = @('.crt', '.cer', '.pem')
$Script:SupportedPrivateKeyExtensions  = @('.key', '.pem')

# Set by Install-DeltaSslCertificate/Install-DeltaSslCertificateFiles
# whenever HTTPS should be configured - a certificate was either just
# copied into place, or an already-existing one (Phase 6 - Existing
# Certificate Handling) was explicitly kept. Stays $false on the "No"
# (no-op) answer, or if that phase is never reached at all. Read by
# New-DeltaNginxConfiguration to pick the HTTP/HTTPS template and by
# Show-DeltaNginxSummary to decide whether to display the SSL Certificate
# section at all.
$Script:SslCertificateConfigured = $false

# 'New' once Install-DeltaSslCertificateFiles actually copies a
# certificate into place this run, 'Existing' once the operator chooses
# to keep an already-present one (Phase 6) instead - $null whenever
# $Script:SslCertificateConfigured is $false, since there is nothing to
# attribute a source to. Read only by Show-DeltaNginxSummary, purely for
# the audit-trail distinction this phase's own requirements call for
# ("Newly installed" vs "Existing certificate retained").
$Script:SslCertificateSource = $null

# The one NGINX version this installer ever installs - pinned, not "latest",
# so a run today and a run next year install byte-for-byte the same NGINX.
# Used consistently below wherever a version could otherwise vary: the local
# package filename, the download URL, and the installation summary. Official
# Windows ZIP distribution only - nginx.org publishes precompiled Windows
# binaries under this exact naming convention (confirmed live via a direct
# HTTP HEAD request at the time this was written - re-verify against
# https://nginx.org/en/download.html before bumping this version, the same
# caveat setup.ps1 carries for its own EDB/PostGIS download URLs).
$Script:NginxVersion     = '1.29.2'
$Script:NginxDownloadUrl = "https://nginx.org/download/nginx-$($Script:NginxVersion).zip"

# Downloaded packages are cached project-locally in .\installers (sibling to
# this script, gitignored), matching setup.ps1's own $Script:InstallersDirectory
# convention - installers\nginx-<version>.zip (see Get-NginxPackage), whether
# placed there manually by an operator (e.g. for an air-gapped install) or
# cached from this script's own prior download, is preferred over a fresh
# download when present.
$Script:InstallersDirectory = Join-Path -Path $Script:ProjectRoot -ChildPath 'installers'

# Canonical configuration templates (this repository) copied into place -
# see this file's own header for why these are maintained as real, readable
# files rather than generated via PowerShell string concatenation. Two
# dedicated DELTA virtual host templates, not one with conditional SSL
# directives (docs\todo\TODO-setup-nginx-enhancements.md, Phase 3) -
# New-DeltaNginxConfiguration picks exactly one of the two based on
# $Script:SslCertificateConfigured; both are written to the same
# destination, $Script:DeltaVHostConfigPath, so nothing downstream needs to
# know which template produced it.
$Script:NginxMainConfigTemplate       = Join-Path -Path $Script:ProjectRoot -ChildPath 'templates\nginx\nginx.conf'
$Script:DeltaHttpVHostConfigTemplate  = Join-Path -Path $Script:ProjectRoot -ChildPath 'templates\nginx\delta-http.conf'
$Script:DeltaHttpsVHostConfigTemplate = Join-Path -Path $Script:ProjectRoot -ChildPath 'templates\nginx\delta-https.conf'

# ---------------------------------------------------------------------------
# DELTA installation discovery
# ---------------------------------------------------------------------------
#
# Resolve-DeltaInstallation itself now lives in lib\DeltaInstaller.Common.ps1
# (dot-sourced above) - it has no NGINX-specific knowledge at all, and
# setup-iis.ps1 needs the identical behavior, so both consume the same
# shared implementation rather than carrying two copies that could drift
# apart. See that function's own header for the full behavior description.

# ---------------------------------------------------------------------------
# Port prerequisite check
# ---------------------------------------------------------------------------
#
# Operational safety enhancement (docs\todo\TODO-setup-nginx-enhancements.md,
# Phase 8). Runs immediately after Resolve-DeltaInstallation and BEFORE the
# orchestration block's own top-level "does nginx.exe already exist" branch -
# deliberately in front of BOTH the fresh-install workflow and the existing-
# installation management menu, not only the former. That placement is what
# lets this correctly tell "a required port is already owned by THIS
# installer's own managed NGINX instance" (never a conflict) apart from "a
# required port is owned by something else entirely" (a genuine, fail-fast
# prerequisite failure) - a distinction docs\todo's own "Managed NGINX
# Exception" requirement only matters at all once nginx.exe already exists,
# which is exactly the branch this section's placement keeps in scope.
#
# Nothing about the runtime-state management or the management menu itself
# (both from the prior phase) is touched here - this is purely an additional
# gate placed in front of both existing workflows, reusing Get-
# DeltaNginxVHostSummary/Get-DeltaNginxManagedProcesses/Get-DeltaProcessById
# rather than a second implementation of any of them.

function Get-DeltaNginxRequiredPorts {
    <#
      Determines the ports this run needs to check - deliberately NOT the
      same thing as Get-DeltaNginxExpectedPorts (Runtime state section,
      Phase 7's own Startup Validation), which decides based on
      $Script:SslCertificateConfigured - a flag this run's own SSL wizard
      sets, and the wizard has not run yet at the point this prerequisite
      check executes (it runs before installation confirmation, which
      itself runs before the wizard). Using Get-DeltaNginxVHostSummary
      instead reflects an EXISTING installation's real, already-generated
      deployment mode when there is one; a fresh install (no vhost file
      written yet - the administrator has not even been asked about a
      certificate) naturally falls back to port 80 alone, the one port
      required regardless of which mode the not-yet-run SSL wizard ends
      up choosing. Never assumes HTTPS.
    #>
    if ((Get-DeltaNginxVHostSummary).IsHttps) {
        return ,@(80, 443)
    }
    return ,@(80)
}

function Get-ListeningTcpPortOwner {
    <#
      For $Port, returns a [PSCustomObject] describing whoever is bound to
      it in the LISTEN state - ProcessId, ProcessName, ExecutablePath, and
      (diagnostic only) ServiceName - or $null if nothing is listening on
      it at all. Get-NetTCPConnection (the same NetTCPIP-module primitive
      Test-DeltaNginxPortListening already uses) supplies the owning PID;
      Get-DeltaProcessById (Runtime state section) resolves the process
      itself without throwing if it has already exited; the Windows
      Service Name, if any, is resolved via CIM (Win32_Service) purely for
      the administrator's own diagnosis - never consulted to decide
      whether a port is actually free.
    #>
    param([Parameter(Mandatory)][int]$Port)

    $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $connection) {
        return $null
    }

    $ownerProcessId = $connection.OwningProcess
    $process        = Get-DeltaProcessById -ProcessId $ownerProcessId

    $executablePath = $null
    if ($process) {
        try { $executablePath = $process.Path } catch { $executablePath = $null }
    }

    $serviceName = $null
    try {
        $service = Get-CimInstance -ClassName Win32_Service -Filter "ProcessId = $ownerProcessId" -ErrorAction Stop | Select-Object -First 1
        if ($service) { $serviceName = $service.Name }
    }
    catch {
        $serviceName = $null
    }

    return [PSCustomObject]@{
        Port           = $Port
        ProcessId      = $ownerProcessId
        ProcessName    = if ($process) { $process.ProcessName } else { $null }
        ExecutablePath = $executablePath
        ServiceName    = $serviceName
    }
}

function Test-RequiredPortAvailability {
    <#
      Reports whether $Port is safe to proceed with for this run - a
      [PSCustomObject] with Port, Available, and Owner (the
      Get-ListeningTcpPortOwner result, $null when the port is genuinely
      free - diagnostic only, never itself consulted below beyond the
      executable-path comparison). Available is $true when the port is
      free OR already owned by THIS installer's own managed NGINX
      instance - matched by exact executable path against
      $Script:NginxExePath, the same standard Test-DeltaManagedNginx and
      Get-DeltaNginxManagedProcesses already hold throughout the Runtime
      state section, never a process-name-only check. Anything else
      owning the port is a genuine conflict.
    #>
    param([Parameter(Mandatory)][int]$Port)

    $owner = Get-ListeningTcpPortOwner -Port $Port
    if (-not $owner) {
        return [PSCustomObject]@{ Port = $Port; Available = $true; Owner = $null }
    }

    if ($owner.ExecutablePath -and ($owner.ExecutablePath -eq $Script:NginxExePath)) {
        return [PSCustomObject]@{ Port = $Port; Available = $true; Owner = $owner }
    }

    return [PSCustomObject]@{ Port = $Port; Available = $false; Owner = $owner }
}

function Show-DeltaNginxPortConflictNotice {
    <#
      Conflict Handling (docs\todo\...) - the entire response to a
      required port already being owned by something other than this
      installer's own managed NGINX instance. A genuine prerequisite
      FAILURE, not the "administrator declined"/"nothing to do" shape
      every other clean-exit notice in this script uses (those all exit
      0) - this exits 1, while still using its own dedicated, calm notice
      here rather than the generic red try/catch failure banner, exactly
      matching this feature's own specified output. Reached before
      installation confirmation, before anything is downloaded,
      extracted, or configured, and before the existing-installation
      management menu ever runs either - "No changes have been made." is
      always accurate here.
    #>
    param([Parameter(Mandatory)]$PortCheck)

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Prerequisite Check'
    Write-Host ''
    Write-Host 'Port'
    Write-Host ''
    Write-Detail "$($PortCheck.Port)"
    Write-Host ''
    Write-Host 'Status'
    Write-Host ''
    Write-Detail 'In Use'
    Write-Host ''
    Write-Host 'Process'
    Write-Host ''
    Write-Detail $(if ($PortCheck.Owner.ProcessName) { $PortCheck.Owner.ProcessName } else { 'Unknown' })
    Write-Host ''
    Write-Host 'PID'
    Write-Host ''
    Write-Detail "$($PortCheck.Owner.ProcessId)"
    Write-Host ''
    Write-Host 'Executable'
    Write-Host ''
    Write-Detail $(if ($PortCheck.Owner.ExecutablePath) { $PortCheck.Owner.ExecutablePath } else { 'Unknown' })
    if ($PortCheck.Owner.ServiceName) {
        Write-Host ''
        Write-Host 'Service'
        Write-Host ''
        Write-Detail $PortCheck.Owner.ServiceName
    }
    Write-Host ''
    Write-Host 'NGINX requires exclusive access to this port.'
    Write-Host ''
    Write-Host 'Stop the application using this port and rerun setup-nginx.ps1.'
    Write-Host ''
    Write-Host 'No changes have been made.'
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
}

function Show-DeltaNginxPortsAvailableNotice {
    <#
      Available Ports (docs\todo\...) - the happy-path banner, shown only
      on the fresh-install side of Test-DeltaNginxPortPrerequisites (see
      that function's own header for why): an already-existing managed
      installation continues silently into Show-DeltaNginxManagementMenu
      exactly as before, since that screen already conveys its own
      Status and this feature is not meant to add noise ahead of it.
    #>
    param([Parameter(Mandatory)][array]$RequiredPorts)

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Prerequisite Check'
    Write-Host ''
    foreach ($port in $RequiredPorts) {
        Write-Host "Port $port"
        Write-Host ''
        Write-Detail 'Available'
        Write-Host ''
    }
    Write-Host ('-' * $Script:BannerWidth)
}

function Test-DeltaNginxPortPrerequisites {
    <#
      The orchestrator for this whole section - see the section header
      above for the full placement rationale. Determines the required
      ports (Get-DeltaNginxRequiredPorts), checks each one
      (Test-RequiredPortAvailability), and:

        - Exits (1) immediately on the first genuine conflict found
          (Show-DeltaNginxPortConflictNotice) - before installation
          confirmation, before anything is downloaded, extracted, or
          configured, and before the existing-installation management
          menu ever runs.
        - Otherwise, prints the "Available" success banner
          (Show-DeltaNginxPortsAvailableNotice) ONLY when nginx.exe does
          not yet exist (the fresh-install path) - an existing managed
          installation proceeds straight into
          Show-DeltaNginxManagementMenu without it, unchanged from the
          prior UX pass.
    #>

    Write-Step 'Checking required NGINX ports...'

    $requiredPorts = Get-DeltaNginxRequiredPorts
    $results       = @(foreach ($port in $requiredPorts) { Test-RequiredPortAvailability -Port $port })

    $conflict = $results | Where-Object { -not $_.Available } | Select-Object -First 1
    if ($conflict) {
        Show-DeltaNginxPortConflictNotice -PortCheck $conflict
        exit 1
    }

    if (-not (Test-Path -LiteralPath $Script:NginxExePath)) {
        Show-DeltaNginxPortsAvailableNotice -RequiredPorts $requiredPorts
    }
}

# ---------------------------------------------------------------------------
# DELTA backend port detection
# ---------------------------------------------------------------------------
#
# Resolve-DeltaBackendPort/Test-ValidTcpPort/$Script:DefaultDeltaBackendPort
# now live in lib\DeltaInstaller.Common.ps1 (dot-sourced above) - they have
# no NGINX-specific knowledge at all, and setup-iis.ps1 needs the identical
# behavior (docs\todo\TODO-setup-iis-enhancements.md, Phase 5), so both
# scripts consume the same shared implementation rather than carrying two
# copies that could drift apart. See that function's own header for the
# full behavior description.

# ---------------------------------------------------------------------------
# Native command output helper
# ---------------------------------------------------------------------------

function ConvertTo-NativeCommandOutputText {
    <#
      Joins a native command's captured output (as returned by a call using
      2>&1, one array element per line) back into plain, readable text.

      Deliberately NOT "($Output | Out-String).Trim()": a stderr line
      merged via 2>&1 arrives as an ErrorRecord, not a plain string, and
      Out-String renders an ErrorRecord through PowerShell's own default
      error format view - "At line X char Y", "+ CategoryInfo", etc. -
      rather than the line of text nginx.exe actually printed. Confirmed
      directly: a completely successful `nginx -t` (exit code 0) otherwise
      displays with that full diagnostic frame around it, indistinguishable
      at a glance from a real failure. Calling .ToString() on each element
      individually first (which for an ErrorRecord returns just its
      message) avoids that, for both success and failure output alike.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Output)

    $lines = @($Output | ForEach-Object { $_.ToString() })
    return ($lines -join [Environment]::NewLine).Trim()
}

# ---------------------------------------------------------------------------
# Installation confirmation
# ---------------------------------------------------------------------------

function Read-DeltaNginxInstallConfirmation {
    <#
      Installation Confirmation - the gate before Install-Nginx ever
      runs for a brand-new install (the existing-NGINX check in the
      orchestration block, which runs before this, has already
      confirmed nothing is installed at $Script:NginxExePath yet).
      Bare Enter (or anything other than Y/y) defaults to No, the same
      "blank means the safe choice" convention as uninstall.ps1's own
      "(y/N)" data-directory-deletion prompt - an administrator who
      presses Enter without reading closely should land on the option
      that installs nothing, not the one that does. The rule/prompt/rule
      frame itself is Read-DeltaYesNoConfirmation (lib\DeltaInstaller.Common.ps1)
      - only the NGINX-specific body text below belongs to this script.
    #>

    return Read-DeltaYesNoConfirmation -Body {
        Write-Host "NGINX $($Script:NginxVersion) will be installed."
        Write-Host ''
        Write-Host 'Installation Directory'
        Write-Host ''
        Write-Detail $Script:NginxHome
        Write-Host ''
        Write-Host 'Continue?'
    }
}

function Show-DeltaNginxInstallCancelledNotice {
    <#
      The entire response to Read-DeltaNginxInstallConfirmation
      returning $false - mirrors Show-SslCertificateCancelledNotice's
      own philosophy of spelling out that nothing was touched, rather
      than leaving the administrator to wonder whether the script did
      nothing or just failed silently. Always accurate: reached before
      Install-Nginx ever runs, so no file has been written and nothing
      exists at $Script:NginxHome that wasn't already there.
    #>

    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Setup canceled.'
    Write-Host ''
    Write-Host 'No changes have been made.'
    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Yellow
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Download / install
# ---------------------------------------------------------------------------

function Get-NginxPackage {
    <#
      Returns the path to the NGINX Windows ZIP package for the pinned
      $Script:NginxVersion - and only that version, never any other.

      Deliberately an EXACT filename match against
      installers\nginx-<version>.zip, not an installers\nginx-*.zip
      wildcard: the entire point of pinning $Script:NginxVersion is that
      this installer always installs that one version, and a wildcard match
      could silently pick up a differently-versioned package an operator
      happened to leave in the same directory. The same exact path serves
      both an operator-supplied local package (e.g. for an air-gapped
      install) and this function's own cached download from a prior run -
      there is no meaningful difference between the two once the filename
      matches the pin, so both are handled by the same Test-Path check
      rather than two separate code paths.
    #>

    $packagePath = Join-Path -Path $Script:InstallersDirectory -ChildPath "nginx-$($Script:NginxVersion).zip"

    if (Test-Path -LiteralPath $packagePath) {
        Write-Step 'Using local NGINX package...'
        Write-Detail "Package: $packagePath"
        return $packagePath
    }

    if (-not (Test-Path -Path $Script:InstallersDirectory)) {
        New-Item -Path $Script:InstallersDirectory -ItemType Directory -Force | Out-Null
    }

    Write-Step "Downloading NGINX $($Script:NginxVersion) (official Windows ZIP distribution)..."
    Write-Detail "Source: $($Script:NginxDownloadUrl)"
    Write-Detail "Target: $packagePath"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Script:NginxDownloadUrl -OutFile $packagePath -UseBasicParsing
    }
    catch {
        Stop-Setup "Failed to download NGINX from $($Script:NginxDownloadUrl): $($_.Exception.Message)"
    }

    if (-not (Test-Path -Path $packagePath) -or (Get-Item -Path $packagePath).Length -eq 0) {
        Stop-Setup "Download reported success but the package file is missing or empty: $packagePath"
    }

    Write-Success '    Download complete.'
    return $packagePath
}

function Install-NginxFromZip {
    <#
      Extracts $ZipPath into a temporary staging directory and moves its
      contents into $Script:NginxHome. The official ZIP distribution wraps
      everything in a single top-level nginx-<version>\ directory
      (nginx.exe, conf\, html\, logs\, temp\, contrib\, docs\) - that inner
      directory's CONTENTS are what belongs at $Script:NginxHome, never the
      version-named directory itself, so this always detects and unwraps
      it rather than assuming a fixed folder name (a locally-supplied
      installers\nginx-*.zip is not guaranteed to use nginx.org's own naming).
    #>
    param([Parameter(Mandatory)][string]$ZipPath)

    Write-Step 'Extracting NGINX...'
    Write-Detail "Package: $ZipPath"
    Write-Detail "Target: $($Script:NginxHome)"

    $stagingDirectory = Join-Path -Path $env:TEMP -ChildPath "delta-nginx-extract-$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $stagingDirectory -ItemType Directory -Force | Out-Null

    try {
        try {
            Expand-Archive -LiteralPath $ZipPath -DestinationPath $stagingDirectory -Force
        }
        catch {
            Stop-Setup "Failed to extract the NGINX package ($ZipPath): $($_.Exception.Message)"
        }

        # @(...) here is deliberate, not decorative - Get-ChildItem returns
        # a bare (non-array) DirectoryInfo, not a one-element array, when
        # exactly one subdirectory matches, and PowerShell's own pipeline
        # unwrapping means an un-guarded ".Count" or index on that result
        # would behave inconsistently depending on how many entries came
        # back. Forcing it into a real array here first is what makes
        # ".Count -eq 1" and "[0]" below trustworthy either way.
        $extractedEntries = @(Get-ChildItem -Path $stagingDirectory -Directory)
        $sourceDirectory = if ($extractedEntries.Count -eq 1) { $extractedEntries[0].FullName } else { $stagingDirectory }

        if (-not (Test-Path -Path $Script:NginxHome)) {
            New-Item -Path $Script:NginxHome -ItemType Directory -Force | Out-Null
        }

        Get-ChildItem -Path $sourceDirectory -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Script:NginxHome -Recurse -Force
        }
    }
    finally {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Success '    Extraction complete.'
}

function Install-Nginx {
    <#
      Phase 1. Callers MUST have already confirmed nginx.exe does not exist
      at $Script:NginxExePath (see the orchestration block's own
      existing-installation check, which runs before this is ever called) -
      this function always installs, unconditionally, and never re-checks
      that guarantee itself. It never attempts to detect or reconcile a
      different NGINX version the way setup.ps1's Node.js/PostgreSQL phases
      do either, since there is nothing to reconcile: the pinned
      $Script:NginxVersion is the only version this ever installs.

      Also ensures conf\conf.d\ and logs\ exist once extraction finishes -
      the official ZIP distribution does not ship conf\conf.d\ itself, and
      conf\nginx.conf's `include conf.d/*.conf;` (see
      templates\nginx\nginx.conf) depends on it being there; logs\ is where
      that same template's explicit `pid logs/nginx.pid;` directive writes
      the pid file Get-DeltaNginxRuntimeState depends on, so a missing
      logs\ directory should be caught here as a clear, immediate error
      rather than surfacing later as a confusing Startup Validation failure.
    #>

    Write-PhaseBanner 'NGINX Installation'
    Write-Step "NGINX was not found at $($Script:NginxExePath) - installing version $($Script:NginxVersion)..."

    if (-not (Test-IsAdministrator)) {
        Stop-Setup "Administrator privileges are required to install NGINX to $($Script:NginxHome). Re-run this script from an elevated PowerShell session."
    }

    $packagePath = Get-NginxPackage
    Install-NginxFromZip -ZipPath $packagePath

    Write-Step 'Validating installation...'
    if (-not (Test-Path -LiteralPath $Script:NginxExePath)) {
        Stop-Setup "NGINX installation appeared to succeed, but nginx.exe was not found afterward at $($Script:NginxExePath)."
    }

    Write-Step 'Ensuring required directories exist...'
    foreach ($requiredDirectory in @($Script:NginxConfDDirectory, $Script:NginxLogsDirectory)) {
        if (-not (Test-Path -LiteralPath $requiredDirectory)) {
            New-Item -Path $requiredDirectory -ItemType Directory -Force | Out-Null
            Write-Detail "Created: $requiredDirectory"
        }
        else {
            Write-Detail "Already exists: $requiredDirectory"
        }
    }

    Write-Host ''
    Write-Success 'NGINX successfully installed.'
    Write-Host ''
    Write-Host 'Version:'
    Write-Host $Script:NginxVersion
    Write-Host ''
    Write-Host 'Location:'
    Write-Host $Script:NginxHome
}

# ---------------------------------------------------------------------------
# SSL Certificate Wizard
# ---------------------------------------------------------------------------

function Read-SslCertificateChoice {
    <#
      Asks whether the administrator already has an SSL certificate ready
      to install - the same numbered-choice, bare-Enter-picks-a-default
      shape as Read-ExistingPostgresChoice/Read-DeltaDeploymentLifecycleChoice
      in setup.ps1. Defaults to "No" on a bare Enter: an administrator who
      presses Enter without reading closely should land on the option that
      does nothing (no file dialogs pop up unexpectedly), not the one that
      launches two of them.
    #>

    Write-Host ''
    Write-Host 'Do you already have an SSL certificate?'
    Write-Host ''
    Write-Host '1) Yes'
    Write-Host '2) No'
    Write-Host ''

    while ($true) {
        $choice = Read-Host -Prompt 'Choose an option [2]'
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '2' }

        switch ($choice.Trim()) {
            '1' { return 'Yes' }
            '2' { return 'No' }
        }
        Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow
    }
}

# Select-DeltaSslFile/Test-DeltaSslFileExtension now live in
# lib\DeltaInstaller.Common.ps1 (dot-sourced above) - they have no
# NGINX-specific knowledge at all, and setup-iis.ps1 needs the identical
# file-picker/extension-check behavior for its own Phase 7 (Windows SSL
# Certificate), so both scripts consume the same shared implementation
# rather than carrying two copies that could drift apart.

function Test-DeltaSslCertificateFilesExist {
    <#
      Phase 6 (docs\todo\TODO-setup-nginx-enhancements.md, "Existing
      Certificate Handling"). Reports whether a certificate is already
      installed at $Script:NginxCertificatePath/$Script:NginxCertificateKeyPath
      - and ONLY when BOTH files are present, per this phase's own
      requirement: a certificate with no matching key (or vice versa)
      isn't something this installer could actually serve HTTPS with
      anyway, so a half-present pair is treated exactly like "nothing
      existing" rather than as a third, special case Install-DeltaSslCertificate
      would otherwise have to handle.
    #>
    return (Test-Path -LiteralPath $Script:NginxCertificatePath) -and (Test-Path -LiteralPath $Script:NginxCertificateKeyPath)
}

function Read-ExistingSslCertificateChoice {
    <#
      Phase 6. Presents the three actions available once
      Test-DeltaSslCertificateFilesExist has already confirmed a
      certificate is sitting at the fixed installed location - Replace,
      Keep, or Cancel. No bare-Enter default (unlike
      Read-SslCertificateChoice's "[2]") - a decision this consequential
      (silently keeping vs. silently discarding a possibly-production
      certificate) is deliberately never made by a stray Enter keypress.
    #>

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Existing SSL certificate detected.'
    Write-Host ''
    Write-Host 'Certificate'
    Write-Host ''
    Write-Detail $Script:NginxCertificatePath
    Write-Host ''
    Write-Host 'Private Key'
    Write-Host ''
    Write-Detail $Script:NginxCertificateKeyPath
    Write-Host ''
    Write-Host 'Choose an option:'
    Write-Host ''
    Write-Host '1) Replace existing certificate'
    Write-Host '2) Keep existing certificate'
    Write-Host '3) Cancel setup'
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''

    while ($true) {
        $choice = Read-Host -Prompt 'Selection'

        switch ($choice.Trim()) {
            '1' { return 'Replace' }
            '2' { return 'Keep' }
            '3' { return 'Cancel' }
        }
        Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow
    }
}

function Show-SslCertificateCancelledNotice {
    <#
      Phase 6. The entire response to the operator choosing "Cancel
      setup" from Read-ExistingSslCertificateChoice - mirrors
      Show-ExistingNginxNotice's own philosophy of spelling out that this
      is intentional, expected behavior (not an error this installer
      stumbled into), so the operator walks away confident nothing was
      touched rather than wondering whether something went wrong.

      Note this can only be reached after Install-Nginx has already
      extracted a fresh NGINX to $Script:NginxHome (see the orchestration
      block below - the top-level existing-NGINX check already refused to
      proceed at all if that wasn't true) - "no files were modified" here
      refers to the certificate files and NGINX configuration this phase
      itself is responsible for, not to undoing that already-completed,
      unrelated installation step.
    #>

    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Setup canceled.'
    Write-Host ''
    Write-Host 'An existing SSL certificate was found and no changes were made to it.'
    Write-Host ''
    Write-Host 'Certificate'
    Write-Host ''
    Write-Detail $Script:NginxCertificatePath
    Write-Host ''
    Write-Host 'Private Key'
    Write-Host ''
    Write-Detail $Script:NginxCertificateKeyPath
    Write-Host ''
    Write-Host 'NGINX configuration was not written, and NGINX was not started or reloaded.'
    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Yellow
    Write-Host ''
}

function Install-DeltaSslCertificateFiles {
    <#
      The actual "select a certificate and key, validate both, copy them
      into place" implementation - Phase 2's original SSL Certificate
      Wizard body, factored out into its own function so Phase 6's own
      "Replace existing certificate" choice can invoke the IDENTICAL
      workflow rather than growing a second, divergent copy of it. Per
      Phase 6's own requirement ("Reuse the existing helper functions...
      Avoid duplicating Phase 2 logic... This phase should only determine
      whether that workflow needs to run"), this is deliberately the ONLY
      place in this script that selects, validates, or copies SSL
      certificate files - both Install-DeltaSslCertificate's "Yes, I have
      a certificate" path (no existing certificate found) and its
      "Replace existing certificate" path (Phase 6) call straight through
      here, unconditionally overwriting whatever, if anything, is already
      at $Script:NginxCertificatePath/$Script:NginxCertificateKeyPath.

      Sets $Script:SslCertificateConfigured = $true and
      $Script:SslCertificateSource = 'New' on success - Show-DeltaNginxSummary
      reads both to report "Newly installed" rather than "Existing
      certificate retained" for whatever this function just did.

      Validation failures (missing selection, missing file, unsupported
      extension) all stop the installer outright (Stop-Setup) with a clear
      message, per this feature's own requirement - never a silent skip.
    #>

    Write-Step 'Selecting the SSL certificate file...'
    $certificatePath = Select-DeltaSslFile -Title 'Select the SSL certificate file' `
        -Filter 'Certificate Files (*.crt;*.cer;*.pem)|*.crt;*.cer;*.pem|All Files (*.*)|*.*'

    Write-Step 'Selecting the SSL private key file...'
    $privateKeyPath = Select-DeltaSslFile -Title 'Select the SSL private key file' `
        -Filter 'Private Key Files (*.key;*.pem)|*.key;*.pem|All Files (*.*)|*.*'

    if (-not $certificatePath -or -not $privateKeyPath) {
        Stop-Setup 'SSL certificate setup was canceled - both the certificate and private key files must be selected.'
    }
    if (-not (Test-Path -LiteralPath $certificatePath)) {
        Stop-Setup "The selected SSL certificate file does not exist: $certificatePath"
    }
    if (-not (Test-Path -LiteralPath $privateKeyPath)) {
        Stop-Setup "The selected SSL private key file does not exist: $privateKeyPath"
    }
    if (-not (Test-DeltaSslFileExtension -Path $certificatePath -AllowedExtensions $Script:SupportedCertificateExtensions)) {
        Stop-Setup "Unsupported SSL certificate file extension ($([System.IO.Path]::GetExtension($certificatePath))). Supported extensions: $($Script:SupportedCertificateExtensions -join ', ')."
    }
    if (-not (Test-DeltaSslFileExtension -Path $privateKeyPath -AllowedExtensions $Script:SupportedPrivateKeyExtensions)) {
        Stop-Setup "Unsupported SSL private key file extension ($([System.IO.Path]::GetExtension($privateKeyPath))). Supported extensions: $($Script:SupportedPrivateKeyExtensions -join ', ')."
    }

    Write-Step 'Installing the SSL certificate...'
    if (-not (Test-Path -LiteralPath $Script:NginxCertsDirectory)) {
        New-Item -Path $Script:NginxCertsDirectory -ItemType Directory -Force | Out-Null
    }

    Copy-Item -LiteralPath $certificatePath -Destination $Script:NginxCertificatePath -Force
    Copy-Item -LiteralPath $privateKeyPath -Destination $Script:NginxCertificateKeyPath -Force

    $Script:SslCertificateConfigured = $true
    $Script:SslCertificateSource     = 'New'

    Write-Success '    SSL certificate installed.'
    Write-Host ''
    Write-Host 'Certificate:'
    Write-Detail $Script:NginxCertificatePath
    Write-Host ''
    Write-Host 'Private key:'
    Write-Detail $Script:NginxCertificateKeyPath
}

function Install-DeltaSslCertificate {
    <#
      SSL Certificate phase - now covers both Phase 2 ("SSL Certificate
      Wizard") and Phase 6 ("Existing Certificate Handling") from
      docs\todo\TODO-setup-nginx-enhancements.md. First checks whether a
      certificate is already sitting at the fixed installed location
      (Test-DeltaSslCertificateFilesExist) and, if so, branches into the
      Phase 6 Replace/Keep/Cancel prompt (Read-ExistingSslCertificateChoice)
      instead of the original Phase 2 "do you already have one?" Yes/No
      prompt - the answer to "does one already exist" is already known at
      that point, so there's nothing to ask.

      No existing certificate found: behavior is completely unchanged
      from Phase 2 - Read-SslCertificateChoice, and "Yes" hands off to
      Install-DeltaSslCertificateFiles for the actual selection/
      validation/copy work. Answering "No" is a complete no-op: nothing
      is prompted for, created, or copied.

      Existing certificate found:
        - Replace: hands off to the SAME Install-DeltaSslCertificateFiles
          used by the no-existing-certificate path - see that function's
          own header for why this is deliberately the only place file
          selection/validation/copying happens at all.
        - Keep: no file picker, no overwrite. Sets
          $Script:SslCertificateConfigured = $true and
          $Script:SslCertificateSource = 'Existing' directly (the existing
          files themselves are left completely untouched) so
          New-DeltaNginxConfiguration still picks the HTTPS template and
          Show-DeltaNginxSummary reports "Existing certificate retained".
        - Cancel: Show-SslCertificateCancelledNotice followed by `exit 0`
          right here, not a return - confirmed directly that `exit` from
          a nested function call bypasses the orchestration block's own
          try/catch entirely (the same mechanism the top-level existing-
          NGINX check already relies on for its own Show-ExistingNginxNotice
          + exit 0), so this exits cleanly with no failure banner and
          none of New-DeltaNginxConfiguration/Test-DeltaNginxConfiguration/
          Start-DeltaNginx/Show-DeltaNginxSummary ever run.
    #>

    Write-PhaseBanner 'SSL Certificate'

    if (Test-DeltaSslCertificateFilesExist) {
        $existingChoice = Read-ExistingSslCertificateChoice

        switch ($existingChoice) {
            'Replace' {
                Install-DeltaSslCertificateFiles
                return
            }
            'Keep' {
                $Script:SslCertificateConfigured = $true
                $Script:SslCertificateSource     = 'Existing'

                Write-Host ''
                Write-Success '    Existing SSL certificate retained.'
                Write-Host ''
                Write-Host 'Certificate:'
                Write-Detail $Script:NginxCertificatePath
                Write-Host ''
                Write-Host 'Private key:'
                Write-Detail $Script:NginxCertificateKeyPath
                return
            }
            'Cancel' {
                Show-SslCertificateCancelledNotice
                exit 0
            }
        }
    }

    $choice = Read-SslCertificateChoice
    if ($choice -eq 'No') {
        Write-Host ''
        Write-Detail 'No SSL certificate will be configured at this time.'
        return
    }

    Install-DeltaSslCertificateFiles
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function New-DeltaNginxConfiguration {
    <#
      Phase 3 (docs\todo\TODO-setup-nginx-enhancements.md, "Separate HTTP
      and HTTPS Templates"). Writes both canonical configuration files from
      the templates under templates\nginx\ (this repository) - never
      generated inline as PowerShell string concatenation, so they stay
      readable and version-controlled on their own. See this script's own
      header for why conf\nginx.conf itself is replaced outright rather
      than left as NGINX's own heavily-commented sample file, and why no
      backup step is needed here (Write-DeltaTemplateFile,
      lib\DeltaInstaller.Common.ps1 - the engine-agnostic template writer
      this function bakes the port/domain tokens into).

      Automatically picks the DELTA virtual host template based on
      $Script:SslCertificateConfigured (set by Install-DeltaSslCertificate,
      which always runs before this) - $Script:DeltaHttpsVHostConfigTemplate
      if a certificate was actually installed, $Script:DeltaHttpVHostConfigTemplate
      otherwise. The administrator never chooses a template manually: this
      is the one place that decision gets made, driven entirely by whether
      Phase 2 actually installed a certificate. Both templates write to the
      exact same destination, $Script:DeltaVHostConfigPath - nothing
      downstream (Test-DeltaNginxConfiguration, Start-DeltaNginx) needs to
      know or care which one produced it.

      Bakes the Phase 4 backend port detection (Resolve-DeltaBackendPort)
      and the Phase 5 website domain (Resolve-DeltaWebsiteDomain,
      lib\DeltaInstaller.Common.ps1) - both of which must already have set
      $Script:DeltaBackendPort/$Script:DeltaWebsiteDomain by the time this
      runs - into the vhost template via $vHostReplacements. The
      template's own __DELTA_BACKEND_PORT__/__DELTA_ENV_PATH__/
      __DELTA_SERVER_NAME__ tokens are the only things that differ between
      two runs against the same template, so nothing else here needs to
      change to keep proxy_pass and server_name in sync with the DELTA
      installation's actual runtime configuration and the administrator's
      chosen public hostname.
    #>

    Write-PhaseBanner 'NGINX Configuration'

    $deltaVHostTemplate = if ($Script:SslCertificateConfigured) { $Script:DeltaHttpsVHostConfigTemplate } else { $Script:DeltaHttpVHostConfigTemplate }
    $deltaVHostMode     = if ($Script:SslCertificateConfigured) { 'HTTPS' } else { 'HTTP' }

    foreach ($template in @($Script:NginxMainConfigTemplate, $deltaVHostTemplate)) {
        if (-not (Test-Path -LiteralPath $template)) {
            Stop-Setup "Required configuration template not found: $template"
        }
    }

    Write-Step 'Writing main NGINX configuration...'
    Write-DeltaTemplateFile -TemplatePath $Script:NginxMainConfigTemplate -DestinationPath $Script:NginxMainConfigPath -Description 'Main configuration'

    $vHostReplacements = @{
        '__DELTA_BACKEND_PORT__' = $Script:DeltaBackendPort
        '__DELTA_ENV_PATH__'     = $Script:DeltaEnvPath
        '__DELTA_SERVER_NAME__'  = $Script:DeltaWebsiteDomain
    }

    Write-Step "Writing DELTA reverse proxy configuration ($deltaVHostMode)..."
    Write-DeltaTemplateFile -TemplatePath $deltaVHostTemplate -DestinationPath $Script:DeltaVHostConfigPath -Description "DELTA virtual host configuration ($deltaVHostMode)" -Replacements $vHostReplacements
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

function Test-DeltaNginxConfiguration {
    <#
      Phase 3. Runs `nginx -t` against the configuration just written -
      -p/-c are passed explicitly (rather than relying on nginx.exe's own
      default prefix resolution, which depends on the current working
      directory) so this behaves identically no matter where this script is
      invoked from. A non-zero exit stops the script immediately, before
      Start-DeltaNginx ever runs - an already-running NGINX is deliberately
      never touched by a configuration that fails to validate.

      Confirmed directly against a real installation while building the
      Managed Runtime State redesign: on this Windows build, `nginx -t`
      creates an empty pid file as a side effect whenever no managed
      process is currently running - even though it only ever tests the
      configuration and never actually becomes a running master. Left in
      place, that stray file would make Get-DeltaNginxRuntimeState report
      a false 'Broken' verdict immediately after a routine validation this
      call itself just confirmed was fine - on the fresh-install path,
      every single install (New-DeltaNginxConfiguration always runs this
      right before Start-DeltaNginx) and on the "Validate configuration"
      management menu action alike. Snapshotting the runtime state before
      the `nginx -t` call and cleaning up ONLY the exact side effect this
      call itself just caused (never a pid file/process inconsistency that
      already existed beforehand - that is left for the administrator, per
      this redesign's own "never silently repair" principle) is what
      keeps this call side-effect-free from Get-DeltaNginxRuntimeState's
      point of view. Confirmed separately that an ALREADY-running
      instance's own valid pid file is untouched by this - nginx -t does
      not overwrite a pid file already held by a live master, so the
      cleanup guard below (requiring zero managed processes) never
      triggers in that case regardless.
    #>

    Write-PhaseBanner 'NGINX Configuration Validation'
    Write-Step 'Validating configuration (nginx -t)...'

    $stateBeforeTest = Get-DeltaNginxRuntimeState

    $previousEap = $ErrorActionPreference
    try {
        # nginx -t writes its result to stderr even on success - under this
        # script's global $ErrorActionPreference = 'Stop', capturing native
        # stderr via 2>&1 would otherwise turn that routine output into a
        # terminating error (the same fix applied around psql calls
        # elsewhere in this project - see Test-PostGISAvailable).
        $ErrorActionPreference = 'Continue'
        $output = & $Script:NginxExePath '-t' '-p' $Script:NginxHome '-c' 'conf\nginx.conf' 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    if ($stateBeforeTest.State -eq 'Stopped') {
        $stateAfterTest = Get-DeltaNginxRuntimeState
        if ($stateAfterTest.State -eq 'Broken' -and $stateAfterTest.ManagedProcesses.Count -eq 0) {
            Remove-Item -LiteralPath (Get-DeltaNginxPidFilePath) -Force -ErrorAction SilentlyContinue
        }
    }

    $outputText = ConvertTo-NativeCommandOutputText -Output $output

    if ($exitCode -ne 0) {
        Write-Host ''
        Write-Host $outputText -ForegroundColor Red
        Stop-Setup 'NGINX configuration validation failed. NGINX was not started or reloaded - fix the error above and re-run this script.'
    }

    Write-Detail $outputText
    Write-Success '    Configuration is valid.'
}

function Read-DeltaNginxStartConfirmation {
    <#
      Configuration Validation Before Startup - only ever reached after
      Test-DeltaNginxConfiguration has already succeeded: a validation
      failure calls Stop-Setup, which throws out to the orchestration
      block's own try/catch before this function is ever called, so
      there is no path where NGINX fails validation and this still asks
      whether to start it. Bare Enter (or anything other than Y/y)
      defaults to No, the same convention as
      Read-DeltaNginxInstallConfirmation - both share the same
      Read-DeltaYesNoConfirmation frame (lib\DeltaInstaller.Common.ps1).
    #>

    return Read-DeltaYesNoConfirmation -Body {
        Write-Host 'NGINX configuration validation succeeded.'
        Write-Host ''
        Write-Host 'Start NGINX now?'
    }
}

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
#
# Phase 7 (docs\todo\TODO-setup-nginx-enhancements.md, "Managed Runtime
# State"). A prior investigation into a "Status: Running, but Stop fails
# with CreateFile() nginx.pid failed" report found the root cause: this
# script used to treat "a process named nginx.exe exists at this path" as
# proof of a healthy, controllable instance, while nginx.exe's own `-s
# <signal>` mechanism on Windows has no relationship to Get-Process
# whatsoever - it locates its target exclusively by reading the pid file.
# Those are two independent facts that can disagree (an externally deleted
# pid file, an incomplete prior shutdown, an instance started outside this
# script's control, etc.), and the old code had no way to notice.
#
# This section makes the pid file the primary source of truth, exactly
# the way nginx itself decides who its master process is - process
# enumeration (Get-DeltaNginxManagedProcesses) is used only to (a) tell a
# genuinely clean Stopped state apart from a stale pid file with nothing
# actually running, and (b) supply the Force Stop recovery action's
# target. It is never used, by itself, to decide "Running".

function Get-DeltaNginxPidFilePath {
    <#
      The one place this script computes the expected pid file location -
      $Script:NginxPidFilePath, matching the explicit `pid logs/nginx.pid;`
      directive Phase 7 pinned into templates\nginx\nginx.conf (see that
      template's own header) rather than nginx's undocumented compiled-in
      default.
    #>
    return $Script:NginxPidFilePath
}

function Read-DeltaNginxPid {
    <#
      Reads and parses the pid file, returning the parsed process ID as
      an [int], or $null if the file is missing, unreadable, or its
      content isn't a valid integer - never throws, since
      Get-DeltaNginxRuntimeState needs to treat every one of those as
      just another data point toward a Broken verdict, not a terminating
      error.
    #>
    $pidFilePath = Get-DeltaNginxPidFilePath
    if (-not (Test-Path -LiteralPath $pidFilePath)) {
        return $null
    }

    try {
        $rawPid = (Get-Content -LiteralPath $pidFilePath -Raw -ErrorAction Stop).Trim()
    }
    catch {
        return $null
    }

    $parsedPid = 0
    if (-not [int]::TryParse($rawPid, [ref]$parsedPid)) {
        return $null
    }

    return $parsedPid
}

function Get-DeltaProcessById {
    <#
      A safe Get-Process -Id wrapper that returns $null instead of
      throwing for any invalid, negative, or nonexistent ID - needed
      because every PID handled in this section ultimately comes from a
      pid file this script does not control the contents of. A corrupted
      file could contain anything, including a negative number, which
      Get-Process's own parameter validation rejects as a terminating
      error regardless of -ErrorAction - exactly the kind of crash this
      redesign's own "never silently repair, but never crash on a
      corrupt/inconsistent state either" goal rules out.
    #>
    param([Parameter(Mandatory)][int]$ProcessId)

    try {
        return Get-Process -Id $ProcessId -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Test-DeltaManagedNginx {
    <#
      Validates that $ProcessId is a live process whose executable path
      is $Script:NginxExePath - never a process-name-only check. A PID
      can be silently reused by a completely unrelated program once the
      original process exits, so "some process with this ID exists" is
      not the same claim as "NGINX's own managed process is still
      alive" - this is the one check that turns a pid file's mere
      existence into an actual, verified claim about a specific live
      process.
    #>
    param([Parameter(Mandatory)][int]$ProcessId)

    $process = Get-DeltaProcessById -ProcessId $ProcessId
    if (-not $process) {
        return $false
    }

    try {
        return [bool]($process.Path -and ($process.Path -eq $Script:NginxExePath))
    }
    catch {
        return $false
    }
}

function Get-DeltaNginxManagedProcesses {
    <#
      Raw enumeration only - every nginx.exe process actually running
      FROM $Script:NginxExePath, matched by executable path, never by
      process name alone (a machine can easily run a separate, unrelated
      NGINX instance from a different directory, and a name-only match
      would falsely attribute it to this installation). Returns ALL
      matches (master AND every worker share this same path on Windows),
      not just one - Invoke-DeltaNginxForceStop needs the complete set to
      terminate, and Get-DeltaNginxRuntimeState needs it to tell a clean
      Stopped state apart from a Broken one.

      Deliberately never used by itself to decide "is NGINX running" -
      that is the pid file's job. This is strictly a validation/
      enumeration primitive: process enumeration only ever validates or
      recovers here, it never originates the runtime state verdict.
    #>
    # The leading comma is load-bearing, not decorative - PowerShell
    # unwraps a 0- or 1-element array crossing a `return` boundary back
    # into $null/a bare scalar regardless of the @() wrapper, and every
    # caller here depends on always getting a real array back (an empty
    # match set must stay a genuine empty array, never $null, or a
    # caller's own ".Count" throws under Set-StrictMode).
    return ,@(Get-Process -Name 'nginx' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and ($_.Path -eq $Script:NginxExePath) } catch { $false }
    })
}

function Get-DeltaNginxRuntimeState {
    <#
      The one function everything else in this script (the management
      menu, Start-DeltaNginx, Invoke-DeltaNginxReload/Stop/Restart) calls
      to decide what state NGINX is actually in. Returns a
      [PSCustomObject]:

        State             - 'NotInstalled' | 'Stopped' | 'Running' | 'Broken'
        Reason            - a specific, human-readable explanation, set
                             only when State is 'Broken'
        ProcessId         - the PID read from the pid file, if any
                             (whether or not it turned out to be valid)
        ManagedProcesses  - every nginx.exe process actually running from
                             $Script:NginxExePath (Get-DeltaNginxManagedProcesses)
                             - may be empty

      NotInstalled: nginx.exe itself does not exist.

      Stopped: nginx.exe exists, there is no pid file, AND no managed
      process is running - a genuinely clean state, not merely "no
      process right now" (see Broken below for why that distinction
      matters).

      Running: the pid file exists, parses to a real process ID, and
      Test-DeltaManagedNginx confirms that ID is a live process whose
      executable path matches $Script:NginxExePath. This is the ONLY
      path to "Running" - a process existing is never sufficient by
      itself.

      Broken: everything else - a stale pid file left behind with
      nothing actually running, a process running with no pid file at
      all (the exact bug this phase was written to catch), a pid file
      whose PID has been silently reused by an unrelated program, etc.
      Never silently normalized to Stopped or Running - always reported
      with a specific Reason instead.
    #>

    if (-not (Test-Path -LiteralPath $Script:NginxExePath)) {
        return [PSCustomObject]@{
            State            = 'NotInstalled'
            Reason           = $null
            ProcessId        = $null
            ManagedProcesses = @()
        }
    }

    $managedProcesses = Get-DeltaNginxManagedProcesses
    $pidFilePath      = Get-DeltaNginxPidFilePath
    $pidFileExists    = Test-Path -LiteralPath $pidFilePath
    $parsedPid        = if ($pidFileExists) { Read-DeltaNginxPid } else { $null }

    if (-not $pidFileExists -and $managedProcesses.Count -eq 0) {
        return [PSCustomObject]@{
            State            = 'Stopped'
            Reason           = $null
            ProcessId        = $null
            ManagedProcesses = @()
        }
    }

    if ($pidFileExists -and $parsedPid -and (Test-DeltaManagedNginx -ProcessId $parsedPid)) {
        return [PSCustomObject]@{
            State            = 'Running'
            Reason           = $null
            ProcessId        = $parsedPid
            ManagedProcesses = $managedProcesses
        }
    }

    $reason =
        if (-not $pidFileExists) {
            "The PID file ($pidFilePath) is missing, but $($managedProcesses.Count) NGINX process(es) are still running from $($Script:NginxExePath)."
        }
        elseif (-not $parsedPid) {
            "The PID file ($pidFilePath) exists but does not contain a valid process ID."
        }
        elseif (-not (Get-DeltaProcessById -ProcessId $parsedPid)) {
            "The PID file ($pidFilePath) references process ID $parsedPid, which is not running."
        }
        else {
            "The PID file ($pidFilePath) references process ID $parsedPid, which belongs to a different executable, not $($Script:NginxExePath)."
        }

    return [PSCustomObject]@{
        State            = 'Broken'
        Reason           = $reason
        ProcessId        = $parsedPid
        ManagedProcesses = $managedProcesses
    }
}

function Get-DeltaNginxExpectedPorts {
    <#
      The TCP ports this configuration's generated vhost should be
      listening on once NGINX is actually running - port 80 always (the
      HTTP template's only listener, and the HTTPS template's own
      redirect-to-443 listener), plus 443 as well whenever a certificate
      was configured (delta-https.conf's "listen 443 ssl" server block).
      Read by Test-DeltaNginxStartupHealth's Startup Validation check
      (docs\todo\TODO-setup-nginx-enhancements.md, Phase 7) - so a start
      that merely spawns a process without ever successfully binding its
      configured port(s) is never reported as a success.
    #>
    # ,@(...) rather than @(...) - see Get-DeltaNginxManagedProcesses's own
    # header for why: the single-port HTTP case would otherwise unwrap to
    # a bare [int] on return, and while every current caller only ever
    # foreach's this result (which tolerates a bare scalar fine), pinning
    # the same safe pattern here removes the foot-gun for any future
    # caller that expects a real array.
    if ($Script:SslCertificateConfigured) {
        return ,@(80, 443)
    }
    return ,@(80)
}

function Test-DeltaNginxPortListening {
    <#
      Reports whether $Port has a socket in the LISTEN state anywhere on
      this machine - Get-NetTCPConnection (the NetTCPIP module, present
      on every Windows Server version this installer targets) rather
      than a raw TCP connect attempt, since a successful connect from
      localhost would not by itself confirm NGINX's own bind succeeded -
      it could just as easily hit an unrelated listener already using
      that port.
    #>
    param([Parameter(Mandatory)][int]$Port)

    return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Test-DeltaNginxStartupHealth {
    <#
      Startup Validation (docs\todo\TODO-setup-nginx-enhancements.md,
      Phase 7). After Start-DeltaNginx's fresh-start Start-Process call,
      ALL of the following must hold before this script is willing to
      report a successful start: a live process at the managed path, a
      pid file that exists, that pid file's own PID actually matching
      that live process (not just "some process is running" - the exact
      gap the runtime-state redesign closes), and the ports this
      configuration is actually supposed to be listening on -
      Get-DeltaNginxRuntimeState's own 'Running' verdict already covers
      the first three; this adds the fourth.

      Returns every failing check at once (an array of human-readable
      reasons, empty when everything holds) rather than stopping at the
      first failure, so a failed start can be explained completely
      rather than with just its first symptom.
    #>

    $failures = [System.Collections.Generic.List[string]]::new()

    $state = Get-DeltaNginxRuntimeState
    if ($state.State -eq 'Broken') {
        $failures.Add($state.Reason)
    }
    elseif ($state.State -ne 'Running') {
        $failures.Add("No nginx.exe process is running from $($Script:NginxExePath).")
    }

    foreach ($port in (Get-DeltaNginxExpectedPorts)) {
        if (-not (Test-DeltaNginxPortListening -Port $port)) {
            $failures.Add("Port $port is not listening.")
        }
    }

    # ,$failures.ToArray() - see Get-DeltaNginxManagedProcesses's own
    # header for why this matters here specifically: the zero-failure
    # (successful) case is exactly a 0-element array, and without the
    # leading comma it would unwrap to $null on return - breaking
    # Start-DeltaNginx's own "(Test-DeltaNginxStartupHealth).Count -eq 0"
    # check on precisely the success path this function exists to confirm.
    return ,$failures.ToArray()
}

# ---------------------------------------------------------------------------
# Start / reload
# ---------------------------------------------------------------------------

function Invoke-DeltaNginxSignal {
    <#
      Sends an `-s <Signal>` control signal (reload/quit/...) to the
      NGINX instance at $Script:NginxHome - factored out of
      Start-DeltaNginx's own reload branch so the Existing Installation
      management menu's Reload/Stop/Restart actions (below) call the
      IDENTICAL code path instead of growing a second copy of it, per
      this script's own "reuse existing helper functions... do not
      duplicate code" convention.

      Requires Administrator privileges, the same as Start-DeltaNginx's
      own fresh-start path - both ultimately act on a process bound to
      port 80, so the same guard applies regardless of which specific
      action is being performed.
    #>
    param([Parameter(Mandatory)][string]$Signal)

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to control NGINX. Re-run this script from an elevated PowerShell session.'
    }

    $previousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Script:NginxExePath '-s' $Signal '-p' $Script:NginxHome '-c' 'conf\nginx.conf' 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    if ($exitCode -ne 0) {
        Stop-Setup "Failed to send '$Signal' to NGINX: $(ConvertTo-NativeCommandOutputText -Output $output)"
    }
}

function Start-DeltaNginx {
    <#
      Phase 7. Starts NGINX, gated on Get-DeltaNginxRuntimeState rather
      than raw process detection - see this file's own "Runtime state"
      section header for why that distinction matters. Given the
      existing-installation check in the orchestration block below, this
      always takes the fresh-start path in practice on that call -
      Install-Nginx has just extracted a brand-new NGINX with nothing
      running and no pid file, i.e. a clean 'Stopped' state. The reload
      branch (`nginx -s reload`) is kept as a defensive fallback rather
      than removed: harmless if unreachable in the normal install flow,
      and correct if it is ever reached - it is also exactly what the
      Existing Installation management menu's own "Restart NGINX" action
      falls through to once the process it just stopped is confirmed
      gone (Invoke-DeltaNginxRestart, below).

      Refuses outright (Stop-Setup) if the runtime state is already
      'Broken' - starting on top of an inconsistent state (e.g. a stale
      pid file, or a process running under a mismatched PID) would only
      compound the confusion; the administrator needs to resolve that via
      the management menu's Force Stop action first.

      Binding to port 80 (this configuration's default) requires
      Administrator privileges on Windows, so that's checked here
      specifically rather than relying solely on Install-Nginx's own check.
    #>

    Write-PhaseBanner 'NGINX Start / Reload'

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to start or reload NGINX (binding port 80 requires it). Re-run this script from an elevated PowerShell session.'
    }

    $state = Get-DeltaNginxRuntimeState

    if ($state.State -eq 'Running') {
        Write-Step 'Reloading NGINX configuration...'
        Invoke-DeltaNginxSignal -Signal 'reload'
        Write-Success '    NGINX reloaded.'
        return
    }

    if ($state.State -eq 'Broken') {
        Stop-Setup @"
NGINX is in an inconsistent runtime state and cannot be started safely.

$($state.Reason)

Resolve this from the existing-installation management menu (Force Stop Managed Process) before starting NGINX again.
"@
    }

    Write-Step 'Starting NGINX...'
    Start-Process -FilePath $Script:NginxExePath -ArgumentList @('-p', $Script:NginxHome, '-c', 'conf\nginx.conf') `
        -WorkingDirectory $Script:NginxHome -WindowStyle Hidden | Out-Null

    # Startup Validation (docs\todo\TODO-setup-nginx-enhancements.md, Phase
    # 7) - a running process alone is never reported as success; all four
    # checks in Test-DeltaNginxStartupHealth must hold first.
    $healthy = Wait-Until -Condition { (Test-DeltaNginxStartupHealth).Count -eq 0 } -TimeoutSeconds 10
    if (-not $healthy) {
        $failures = Test-DeltaNginxStartupHealth
        Stop-Setup @"
NGINX did not start successfully within 10 seconds.

$($failures -join [Environment]::NewLine)
"@
    }

    Write-Success '    NGINX started successfully.'
}

# ---------------------------------------------------------------------------
# Installation summary
# ---------------------------------------------------------------------------

function Show-DeltaNginxSummary {
    <#
      Purely a console-output concern, reusing the existing
      Write-SetupBanner/Write-PhaseBanner/Write-Detail vocabulary
      (lib\DeltaInstaller.Common.ps1) rather than introducing new
      formatting primitives - the same approach setup.ps1's own final
      summary takes. Deliberately plain ASCII markers ("[OK]"), not a
      Unicode checkmark - matches every other console message in this
      project (confirmed elsewhere that a Unicode character here mojibakes
      or drops once output is piped/redirected rather than written straight
      to an interactive console host).
    #>

    Write-SetupBanner -Title 'DELTA NGINX Setup Complete' -Subtitle 'Installation completed successfully.'

    Write-Success "    [OK] NGINX $($Script:NginxVersion) installed"

    Write-PhaseBanner 'Detected DELTA Backend'
    Write-Host 'Installation:'
    Write-Detail $Script:DeltaInstallPath
    Write-Host ''
    Write-Host 'Environment:'
    Write-Detail $Script:DeltaEnvPath
    Write-Host ''
    Write-Host 'Backend Port:'
    Write-Detail "$($Script:DeltaBackendPort)"

    $deltaVHostMode = if ($Script:SslCertificateConfigured) { 'HTTPS' } else { 'HTTP' }

    Write-PhaseBanner 'Configuration'
    Write-Host 'NGINX Home:'
    Write-Detail $Script:NginxHome
    Write-Host ''
    Write-Host 'Main Configuration:'
    Write-Detail $Script:NginxMainConfigPath
    Write-Host ''
    Write-Host "DELTA Virtual Host ($deltaVHostMode):"
    Write-Detail $Script:DeltaVHostConfigPath

    Write-PhaseBanner 'Generated NGINX Proxy'
    Write-Detail "proxy_pass http://localhost:$($Script:DeltaBackendPort);"

    Write-PhaseBanner 'Public Website'
    Write-Detail $Script:DeltaWebsiteDomain

    Write-PhaseBanner 'Frontend'
    Write-Detail $(if ($Script:SslCertificateConfigured) { "https://$($Script:DeltaWebsiteDomain)" } else { "http://$($Script:DeltaWebsiteDomain)" })

    Write-PhaseBanner 'Useful Commands'
    Write-Detail "(run from $($Script:NginxHome))"
    Write-Host ''
    Write-Host 'nginx -t'
    Write-Detail 'Validate configuration'
    Write-Host ''
    Write-Host 'nginx -s reload'
    Write-Detail 'Reload configuration'
    Write-Host ''
    Write-Host 'nginx -s quit'
    Write-Detail 'Stop NGINX'

    if ($Script:SslCertificateConfigured) {
        # Phase 6 - clear audit information on whether this run copied a
        # new certificate into place or reused one already sitting at the
        # fixed installed location untouched.
        Write-PhaseBanner 'SSL Certificate'
        Write-Detail $(if ($Script:SslCertificateSource -eq 'Existing') { 'Existing certificate retained' } else { 'Newly installed' })
        Write-Host ''
        Write-Host 'Certificate:'
        Write-Detail $Script:NginxCertificatePath
        Write-Host ''
        Write-Host 'Private Key:'
        Write-Detail $Script:NginxCertificateKeyPath
    }

    Write-PhaseBanner 'HTTPS'
    if ($Script:SslCertificateConfigured) {
        Write-Host 'HTTPS is enabled.'
        Write-Host ''
        Write-Host 'Plain HTTP requests on port 80 are redirected to HTTPS.'
    }
    else {
        Write-Host 'HTTPS is not enabled.'
        Write-Host ''
        Write-Host 'No SSL certificate was installed for this deployment.'
    }

    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth)
    Write-Host ''
}

function Get-DeltaNginxVHostSummary {
    <#
      Best-effort read of the already-generated DELTA virtual host
      ($Script:DeltaVHostConfigPath) for the Existing Installation
      management menu below - never re-prompts for the website domain
      or backend port the way a fresh install's own
      Resolve-DeltaWebsiteDomain/Resolve-DeltaBackendPort do, since an
      existing installation's configuration is exactly what should be
      displayed as-is, not re-derived or re-asked for. Returns $null
      ServerName/BackendUrl when delta.conf is missing or doesn't match
      either template's expected shape (e.g. an NGINX installation this
      script never generated a vhost for) rather than throwing - this
      menu is read-only and must degrade gracefully, not block the
      administrator from reaching Validate/Reload/Restart/Stop/Exit.
    #>

    $result = [PSCustomObject]@{
        ServerName = $null
        BackendUrl = $null
        IsHttps    = $false
    }

    if (-not (Test-Path -LiteralPath $Script:DeltaVHostConfigPath)) {
        return $result
    }

    $content = Get-Content -LiteralPath $Script:DeltaVHostConfigPath -Raw

    $serverNameMatch = [regex]::Match($content, 'server_name\s+([^\s;]+);')
    if ($serverNameMatch.Success) {
        $result.ServerName = $serverNameMatch.Groups[1].Value
    }

    $portMatch = [regex]::Match($content, 'proxy_pass\s+http://localhost:(\d+);')
    if ($portMatch.Success) {
        $result.BackendUrl = "http://localhost:$($portMatch.Groups[1].Value)"
    }

    $result.IsHttps = [bool]([regex]::Match($content, 'listen\s+443\s+ssl').Success)

    return $result
}

function Invoke-DeltaNginxReload {
    <#
      Existing Installation management menu action 2 ("Reload
      configuration") - calls straight through to the same
      Invoke-DeltaNginxSignal helper Start-DeltaNginx's own reload
      branch uses, rather than a second implementation. Re-checks
      Get-DeltaNginxRuntimeState itself rather than trusting a
      snapshot the menu took a moment earlier (state could have
      changed between the menu displaying it and the administrator's
      keystroke); reloading anything other than a confirmed-Running
      instance is meaningless, so this reports that plainly instead of
      attempting the signal and surfacing nginx.exe's own confusing
      failure text.
    #>

    $state = Get-DeltaNginxRuntimeState
    if ($state.State -ne 'Running') {
        Write-Host ''
        Write-Detail 'NGINX is not running - nothing to reload.'
        return
    }

    Write-Step 'Reloading NGINX configuration...'
    Invoke-DeltaNginxSignal -Signal 'reload'
    Write-Success '    NGINX reloaded.'
}

function Invoke-DeltaNginxStop {
    <#
      Existing Installation management menu action 4 ("Stop NGINX").
      Sends a graceful `-s quit` (matching the "Stop NGINX" command
      Show-DeltaNginxSummary's own Useful Commands section already
      documents) via the shared Invoke-DeltaNginxSignal helper, then
      polls (Wait-Until) until Get-DeltaNginxRuntimeState confirms a
      genuinely clean 'Stopped' state - not merely "no process", which
      would also be true of the exact Broken state (a process gone but
      the pid file left behind) the runtime-state redesign exists to
      catch. A timeout that lands on 'Broken' instead of 'Stopped' is
      reported as exactly that inconsistency, not a generic timeout.
      A no-op, reported plainly rather than attempting the signal, if
      nothing is running to begin with.
    #>

    $state = Get-DeltaNginxRuntimeState
    if ($state.State -ne 'Running') {
        Write-Host ''
        Write-Detail 'NGINX is not running - nothing to stop.'
        return
    }

    Write-Step 'Stopping NGINX...'
    Invoke-DeltaNginxSignal -Signal 'quit'

    $stopped = Wait-Until -Condition { (Get-DeltaNginxRuntimeState).State -eq 'Stopped' } -TimeoutSeconds 10
    if (-not $stopped) {
        $finalState = Get-DeltaNginxRuntimeState
        if ($finalState.State -eq 'Broken') {
            Stop-Setup "NGINX did not stop cleanly within 10 seconds: $($finalState.Reason)"
        }
        Stop-Setup 'NGINX did not stop within 10 seconds.'
    }

    Write-Success '    NGINX stopped.'
}

function Invoke-DeltaNginxRestart {
    <#
      Existing Installation management menu action 3 ("Restart
      NGINX"). NGINX has no single built-in "restart" signal, so this
      composes the other two actions already defined here: stop it if
      it's currently running (Invoke-DeltaNginxStop, waiting until the
      runtime state is confirmed 'Stopped'), then hand off to
      Start-DeltaNginx - which, finding a clean 'Stopped' state at that
      point, always takes its own fresh-start path rather than this
      needing to duplicate that Start-Process/Wait-Until logic itself.
      If NGINX was already stopped, this is simply equivalent to
      starting it.
    #>

    if ((Get-DeltaNginxRuntimeState).State -eq 'Running') {
        Invoke-DeltaNginxStop
    }

    Start-DeltaNginx
}

function Read-DeltaNginxForceStopConfirmation {
    <#
      The explicit confirmation gate for the Broken-state management
      menu's "Force Stop Managed Process" recovery action - Force Stop
      terminates a process without giving NGINX any chance to shut down
      gracefully, so per this feature's own requirement ("do not
      silently perform this action"), it is never run without the
      administrator explicitly confirming it first. Bare Enter (or
      anything other than Y/y) defaults to No, the same convention as
      every other confirmation in this script - Read-DeltaYesNoConfirmation
      (lib\DeltaInstaller.Common.ps1) provides that shared frame.
    #>
    param([Parameter(Mandatory)][array]$Targets)

    return Read-DeltaYesNoConfirmation -Body {
        Write-Host 'The following managed NGINX process(es) will be forcefully terminated:'
        Write-Host ''
        foreach ($targetProcess in $Targets) {
            Write-Detail "PID $($targetProcess.Id)"
        }
        Write-Host ''
        Write-Host 'This is not a graceful shutdown and may drop active connections.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Continue?'
    }
}

function Invoke-DeltaNginxForceStop {
    <#
      The Broken-state management menu's "Force Stop Managed Process"
      recovery action. Terminates ONLY $RuntimeState.ManagedProcesses -
      every nginx.exe process matched by exact executable path
      (Get-DeltaNginxManagedProcesses, captured at the moment the
      Broken verdict was diagnosed) - never a name-only match, and
      never anything else running on the machine. Deliberately does
      NOT touch the pid file itself: per this redesign's own "do not
      silently repair anything" principle, this action's job is exactly
      what its name says (terminate the process), not to paper over
      whatever inconsistency caused the Broken verdict in the first
      place. If that verdict was a stale pid file with nothing actually
      running (ManagedProcesses empty), there is nothing to terminate,
      and this reports that rather than pretending to act.
    #>
    param([Parameter(Mandatory)]$RuntimeState)

    $targets = @($RuntimeState.ManagedProcesses)
    if ($targets.Count -eq 0) {
        Write-Host ''
        Write-Detail 'No managed NGINX process was found to stop.'
        return
    }

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to force-stop NGINX. Re-run this script from an elevated PowerShell session.'
    }

    if (-not (Read-DeltaNginxForceStopConfirmation -Targets $targets)) {
        Write-Host ''
        Write-Detail 'Force stop canceled. No process was terminated.'
        return
    }

    Write-Step 'Force-stopping the managed NGINX process(es)...'
    foreach ($targetProcess in $targets) {
        Stop-Process -Id $targetProcess.Id -Force -ErrorAction SilentlyContinue
    }

    $stopped = Wait-Until -Condition { (Get-DeltaNginxManagedProcesses).Count -eq 0 } -TimeoutSeconds 10
    if (-not $stopped) {
        Stop-Setup 'NGINX did not stop within 10 seconds after a forced termination attempt.'
    }

    Write-Success '    Managed NGINX process(es) terminated.'
}

function Show-DeltaNginxManagementMenu {
    <#
      Replaces the old informational-only notice shown when
      $Script:NginxExePath already exists with an interactive menu
      driven entirely by Get-DeltaNginxRuntimeState - per this script's
      own design philosophy (see its header, and the "Runtime state"
      section above), an existing NGINX installation is still never
      reconfigured automatically: nothing here writes nginx.conf/
      delta.conf, installs anything, or runs unless the administrator
      explicitly selects it, and every action reuses an existing helper
      rather than duplicating it.

      The options offered change with the runtime state instead of
      always showing the same five:
        Running - the full Validate/Reload/Restart/Stop/Exit menu.
        Stopped - just Start NGINX / Exit; there is nothing to
                  reload/restart/stop.
        Broken  - an explanation of exactly what is inconsistent
                  (Get-DeltaNginxRuntimeState's own Reason) plus Force
                  Stop Managed Process / Exit - no Start/Reload/Restart
                  is offered here, since acting on an already-
                  inconsistent state would only compound the confusion.
        NotInstalled - a defensive fallback only (nginx.exe cannot
                  vanish mid-loop in any normal scenario reachable from
                  the orchestration block, which only calls this
                  function once it has already confirmed nginx.exe
                  exists); reports it and exits the menu rather than
                  looping forever on an impossible state.

      Loops until the administrator chooses Exit (bare Enter also
      exits - the same "blank means the safe choice" default used
      everywhere else in this script), re-reading
      Get-DeltaNginxRuntimeState/Get-DeltaNginxVHostSummary at the top
      of every iteration so the displayed Status/Public Website/Backend
      reflect whatever the just-run action actually changed, rather
      than a stale snapshot from before the menu was first shown.

      A configuration validation failure (the Running menu's option 1)
      still calls Stop-Setup exactly like the fresh-install path's own
      Test-DeltaNginxConfiguration does - it throws out to the
      orchestration block's own top-level try/catch, which is the same
      error-handling convention this script uses everywhere else.
    #>

    while ($true) {
        $state = Get-DeltaNginxRuntimeState
        $vhost = Get-DeltaNginxVHostSummary

        Write-Host ''
        Write-Host ('=' * $Script:BannerWidth)
        Write-Host ''
        Write-Host 'Existing NGINX installation detected.'
        Write-Host ''
        Write-Host 'NGINX Home'
        Write-Host ''
        Write-Detail $Script:NginxHome
        Write-Host ''
        Write-Host 'Configuration'
        Write-Host ''
        Write-Detail $Script:NginxConfDirectory
        Write-Host ''
        Write-Host 'Public Website'
        Write-Host ''
        if ($vhost.ServerName) {
            Write-Detail "$(if ($vhost.IsHttps) { 'https' } else { 'http' })://$($vhost.ServerName)"
        }
        else {
            Write-Detail 'Unknown (no DELTA virtual host configuration found)'
        }
        Write-Host ''
        Write-Host 'Backend'
        Write-Host ''
        Write-Detail $(if ($vhost.BackendUrl) { $vhost.BackendUrl } else { 'Unknown' })
        Write-Host ''
        Write-Host 'Status'
        Write-Host ''
        Write-Detail $state.State
        Write-Host ''

        if ($state.State -eq 'NotInstalled') {
            Write-Detail 'NGINX no longer appears to be installed at this location.'
            return
        }

        if ($state.State -eq 'Broken') {
            Write-Host 'NGINX appears to be in an inconsistent runtime state.' -ForegroundColor Yellow
            Write-Host ''
            Write-Detail $state.Reason
            Write-Host ''
        }

        Write-Host ('-' * $Script:BannerWidth)
        Write-Host ''

        switch ($state.State) {
            'Running' {
                Write-Host '1) Validate configuration'
                Write-Host '2) Reload configuration'
                Write-Host '3) Restart NGINX'
                Write-Host '4) Stop NGINX'
                Write-Host '5) Exit'
                Write-Host ''

                $choice = Read-Host -Prompt 'Choose an option [5]'
                if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '5' }

                switch ($choice.Trim()) {
                    '1' { Test-DeltaNginxConfiguration }
                    '2' { Invoke-DeltaNginxReload }
                    '3' { Invoke-DeltaNginxRestart }
                    '4' { Invoke-DeltaNginxStop }
                    '5' { return }
                    default { Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow }
                }
            }
            'Stopped' {
                Write-Host '1) Start NGINX'
                Write-Host '2) Exit'
                Write-Host ''

                $choice = Read-Host -Prompt 'Choose an option [2]'
                if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '2' }

                switch ($choice.Trim()) {
                    '1' { Start-DeltaNginx }
                    '2' { return }
                    default { Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow }
                }
            }
            'Broken' {
                Write-Host '1) Force Stop Managed Process'
                Write-Host '2) Exit'
                Write-Host ''

                $choice = Read-Host -Prompt 'Choose an option [2]'
                if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '2' }

                switch ($choice.Trim()) {
                    '1' { Invoke-DeltaNginxForceStop -RuntimeState $state }
                    '2' { return }
                    default { Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow }
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

try {
    Write-SetupBanner -Title 'DELTA NGINX Setup' -Subtitle 'Optional reverse proxy for DELTA'

    # Must happen before anything else, including the existing-NGINX check
    # below - see Resolve-DeltaInstallation's own header. Nothing above this
    # point has touched the filesystem.
    Resolve-DeltaInstallation

    # Operational safety enhancement - see this function's own section
    # header for why this runs here specifically: before the existing-vs-
    # fresh-install branch immediately below, not only on the fresh-install
    # side of it, so a required port already owned by something other than
    # this installer's own managed NGINX is caught regardless of which of
    # the two workflows is about to run. Exits (1) immediately on a genuine
    # conflict - nothing below this point is reachable in that case either.
    Test-DeltaNginxPortPrerequisites

    # The next check that must happen before any NGINX-specific action -
    # see this script's own header and Show-DeltaNginxManagementMenu.
    # Nothing below this point is reachable if NGINX is already installed.
    if (Test-Path -LiteralPath $Script:NginxExePath) {
        Show-DeltaNginxManagementMenu
        exit 0
    }

    # Installation Confirmation - the last chance to back out before
    # anything is written to disk. Nothing above this point has touched
    # the filesystem (Resolve-DeltaInstallation only reads the registry/
    # legacy .env, and the existing-NGINX check above is a Test-Path).
    if (-not (Read-DeltaNginxInstallConfirmation)) {
        Show-DeltaNginxInstallCancelledNotice
        exit 0
    }

    Install-Nginx
    Install-DeltaSslCertificate

    # Phase 4 - must run before New-DeltaNginxConfiguration, which needs
    # $Script:DeltaBackendPort to already be set.
    Resolve-DeltaBackendPort

    # Phase 5 - must run before New-DeltaNginxConfiguration, which needs
    # $Script:DeltaWebsiteDomain to already be set. Resolve-DeltaWebsiteDomain
    # itself lives in lib\DeltaInstaller.Common.ps1, not this script - see
    # its own header for why.
    Write-PhaseBanner 'Public Website Domain'
    $Script:DeltaWebsiteDomain = Resolve-DeltaWebsiteDomain
    Write-Success "    Website domain: $($Script:DeltaWebsiteDomain)"

    New-DeltaNginxConfiguration
    Test-DeltaNginxConfiguration

    # Test-DeltaNginxConfiguration above already stopped the script
    # (Stop-Setup) before this point if validation failed - reaching
    # here means it succeeded, which is the only time this should ask.
    if (Read-DeltaNginxStartConfirmation) {
        Start-DeltaNginx
    }
    else {
        Write-Host ''
        Write-Detail 'NGINX was not started.'
    }

    Show-DeltaNginxSummary

    exit 0
}
catch {
    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Red
    Write-Host 'DELTA NGINX setup failed.' -ForegroundColor Red
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

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

    ARCHITECTURE CORRECTION: immediately once DELTA is confirmed, Doctor's
    own Reverse Proxy Detection (Invoke-DeltaReverseProxyDetection,
    lib\DeltaDoctor.ReverseProxy.ps1) runs - answering "what is DELTA's
    current reverse proxy state" (which providers exist, which are
    actually DELTA-managed, which one is currently active) before this
    script makes ANY workflow decision of its own. This script never
    independently re-derives that answer from raw TCP ports/processes -
    see this file's own Orchestration section header, and
    lib\DeltaDoctor.ReverseProxy.ps1's own header, for the full principle.

    Low-level checks stay lazy, never a blanket front gate: Doctor's own
    report is what this script consumes to decide what to do next - it
    never re-opens a diagnostic sequence Doctor has already run.
    Test-DeltaNginxPortPrerequisites (Operational safety enhancement,
    below) does NOT run the moment this script starts - it runs only
    immediately before an operation that actually needs to bind those
    ports (a fresh install, or explicitly starting/restarting an existing
    managed NGINX from the management menu). Simply running this script
    to inspect an existing installation, or to Validate/Reload one that's
    already running, never requires port 80 to be free, and no longer
    fails as though it did.

    Conservative by design: installing a FRESH copy of NGINX is something
    this script is willing to automate; modifying an EXISTING one is not.
    Once a DELTA installation has been confirmed, the next thing this
    script does - before installing anything, before writing a single
    configuration file - is check whether C:\nginx\nginx.exe already
    exists. If it does, the script prints a one-line, Doctor-derived
    summary of NGINX's own role in the current deployment (Active/Standby/
    neither) and hands off to an interactive management menu
    (Show-DeltaNginxManagementMenu) instead of installing or
    reconfiguring anything - nothing here ever touches nginx.conf/
    delta.conf or installs anything, and the options offered depend on
    Get-DeltaNginxRuntimeState (lib\DeltaDoctor.NGINX.ps1's own Managed
    Runtime State machine): Validate/Reload/Restart/Stop/Exit when
    actually Running, just Start/Exit when cleanly Stopped, and a specific
    explanation plus Force Stop/Exit when Broken (an inconsistency between
    the pid file and the process list - see that file's own header for
    why this exists and what it protects against). This installer must
    never assume it owns an existing NGINX installation - a real,
    hand-configured, already-running reverse proxy at this exact default
    path is a realistic thing to find on a real machine, not a
    hypothetical edge case, and overwriting it would be a production
    incident, not a convenience.

    If, instead, NGINX does NOT exist yet, Doctor's own reverse proxy
    state decides what happens next before anything else does: if another
    provider (IIS) is already DELTA's active reverse proxy, this is
    recognized as an attempt to configure a SECOND, competing reverse
    proxy - Read-DeltaNginxSecondReverseProxyConfirmation explains the
    situation plainly and asks whether to proceed anyway (default No,
    since this script has no migration capability of its own). Only once
    that has passed (or didn't apply at all) does the script ask for one
    more explicit confirmation - Read-DeltaNginxInstallConfirmation, a Y/N
    prompt (default No) naming the version to be installed and the
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

# Pinned NGINX version, installer filename, and download URL - see that
# file's own header. Dot-sourced immediately after
# DeltaInstaller.Common.ps1 since its own fail-fast error path uses
# Stop-Setup, defined there.
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Configuration.ps1')

# lib\DeltaDoctor.ReverseProxy.ps1 dot-sources lib\DeltaDoctor.NGINX.ps1
# (which owns NGINX's installation location, the DELTA virtual host's own
# fixed identity, and its pid-file-based Managed Runtime State machine) AND
# lib\DeltaDoctor.IIS.ps1 - this script needs both now: NGINX's own
# functions/constants for the reasons it always has
# ($Script:NginxHome/$Script:NginxExePath/etc., all defined there, not
# here), and lib\DeltaDoctor.ReverseProxy.ps1's own
# Invoke-DeltaReverseProxyDetection/Get-DeltaReverseProxyConflictingProvider
# so this script's own workflow decisions are driven by Doctor's own
# cross-provider DELTA-ownership answer, never independently re-derived
# from raw ports/processes - see that file's own header, and this script's
# own Orchestration section below, for the full architecture.
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaDoctor.ReverseProxy.ps1')

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

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
# package filename, the download URL, and the installation summary. Comes
# from .env.installer (NGINX_VERSION/NGINX_URL - see
# lib\DeltaInstaller.Configuration.ps1), not a literal here. Official
# Windows ZIP distribution only - nginx.org publishes precompiled Windows
# binaries under this exact naming convention (confirmed live via a direct
# HTTP HEAD request at the time this was pinned - re-verify against
# https://nginx.org/en/download.html before bumping NGINX_VERSION/
# NGINX_INSTALLER/NGINX_URL in .env.installer, the same caveat setup.ps1
# carries for its own EDB/PostGIS download URLs).
$Script:NginxVersion     = $Script:InstallerConfig.NGINX_VERSION
$Script:NginxDownloadUrl = $Script:InstallerConfig.NGINX_URL

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
# Phase 8), now Doctor-informed (see the "ARCHITECTURE CORRECTION" this
# script's own Orchestration section header describes). Deliberately LAZY:
# this never runs as a blanket gate the moment the script starts, and never
# runs merely to display the existing-installation management menu - only
# immediately before an operation that actually needs to bind these ports
# (Install-Nginx on a fresh install, or Start-DeltaNginx's own fresh-start
# branch when the operator chooses Start/Restart from the management menu).
# Doctor's own Reverse Proxy Detection (Invoke-DeltaReverseProxyDetection,
# lib\DeltaDoctor.ReverseProxy.ps1) and, for a genuinely fresh install, the
# "am I about to configure a second reverse proxy" gate both still run
# first - this remains the low-level validation step underneath that
# higher-level decision, never the primary one.
#
# Manual Reverse Proxy Handover: what used to be a hard, unconditional
# abort the moment a required port turned out to be owned by another
# DELTA-managed, active provider is now an offer to stop it instead
# (Invoke-DeltaReverseProxyHandover, lib\DeltaInstaller.Common.ps1) - the
# administrator remains fully in control (a decline is a clean, reported
# no-op, never a forced action), and this is NOT automatic migration. See
# Test-DeltaNginxPortPrerequisites's own header for the exact ordering:
# Doctor is asked before any raw TCP probe runs at all - Get-DeltaReverseProxyHandoverPlan
# (lib\DeltaDoctor.ReverseProxy.ps1) consults every DELTA-managed provider by
# ownership alone, never by whether Doctor considers it Active (see that
# function's own "SECOND ARCHITECTURE CORRECTION" for why: a DELTA-managed
# IIS site can be Stopped while its own stock Default Web Site still holds
# the port). The raw Get-ListeningTcpPortOwner-based check below now only ever fires for
# a conflict Doctor genuinely cannot attribute to a DELTA-managed provider
# at all - that case is unchanged, a genuine, fail-fast prerequisite
# failure (Show-DeltaNginxPortConflictNotice).
#
# Nothing about the runtime-state management or the management menu itself
# (both from the prior phase) is touched here - this is purely an additional
# gate placed in front of both existing workflows, reusing Get-
# DeltaNginxVHostSummary/Get-DeltaNginxManagedProcesses (lib\DeltaDoctor.NGINX.ps1's
# own) and Get-ListeningTcpPortOwner (lib\DeltaInstaller.Common.ps1's own,
# generic - promoted out of this file once setup-iis.ps1 needed the
# identical primitive for its own port-prerequisite check, the Manual
# Reverse Proxy Handover feature) rather than a second implementation of
# any of them.

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
      installer's own managed NGINX instance, that Doctor ALSO cannot
      attribute to another DELTA-managed, active provider (a conflict
      Doctor CAN attribute is no longer reached here at all - see
      Test-DeltaNginxPortPrerequisites's own header: it is offered a
      Manual Reverse Proxy Handover instead, via
      Invoke-DeltaReverseProxyHandover, before this raw safety-net check
      ever runs). A genuine prerequisite FAILURE, not the "administrator
      declined"/"nothing to do" shape every other clean-exit notice in
      this script uses (those all exit 0) - this exits 1, while still
      using its own dedicated, calm notice here rather than the generic
      red try/catch failure banner. Reached before installation
      confirmation, before anything is downloaded, extracted, or
      configured, and before the existing-installation management menu
      ever runs either - "No changes have been made." is always accurate
      here.
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

function Show-DeltaNginxForeignIisConflictNotice {
    <#
      A friendlier alternative to Show-DeltaNginxPortConflictNotice's own
      hard prerequisite failure, shown only when the conflicting owner
      looks like IIS but Doctor already established (Get-DeltaReverseProxyHandoverPlan
      returning $null - see Test-DeltaNginxPortPrerequisites's own header)
      that it is NOT a DELTA-managed provider, so automatic handover was
      never even offered. Purely better guidance before asking to stop it -
      never a widening of the Manual Reverse Proxy Handover feature's own
      DELTA-managed-only ownership rule; this function itself only asks,
      it never stops anything (Stop-DeltaForeignIis, below, does that,
      and only once this returns $true).

      $RequiredPorts is used only for the narrative "port(s) X" line
      (ConvertTo-DeltaEnglishList, lib\DeltaDoctor.ReverseProxy.ps1).

      Reuses Read-DeltaYesNoConfirmation (lib\DeltaInstaller.Common.ps1) -
      the exact same Y/N confirmation shape Invoke-DeltaReverseProxyHandover's
      own "Stop the current active reverse proxy?" prompt already uses for
      the DELTA-managed case - rather than a second confirmation mechanism
      for the same kind of question. The "[Y] Yes .../[N] No ..." lines
      are plain narrative text inside $Body (that function's own compact
      trailing "[y/N]" prompt is unchanged) so the operator still sees
      exactly what each choice does before answering.

      Returns [bool] - $true if the operator confirmed stopping IIS,
      $false to decline.
    #>
    param([Parameter(Mandatory)][array]$RequiredPorts)

    $portsPhrase = ConvertTo-DeltaEnglishList -Items ($RequiredPorts | ForEach-Object { "$_" })
    $portWord    = if ($RequiredPorts.Count -gt 1) { 'ports' } else { 'port' }

    return Read-DeltaYesNoConfirmation -Body {
        Write-Host 'IIS is currently using one or more ports required by NGINX.'
        Write-Host ''
        Write-Host "NGINX requires exclusive access to $portWord $portsPhrase."
        Write-Host ''
        Write-Host 'The detected IIS instance is NOT managed by DELTA.'
        Write-Host ''
        Write-Host 'Stopping IIS may temporarily interrupt websites or applications currently hosted by this server.'
        Write-Host ''
        Write-Host 'If this server is dedicated to DELTA, it is generally safe to stop IIS before continuing.'
        Write-Host ''
        Write-Host 'Would you like DELTA to stop IIS now and continue?'
        Write-Host ''
        Write-Host '[Y] Yes - Stop IIS and continue'
        Write-Host '[N] No  - Exit without making changes'
    }
}

function Stop-DeltaForeignIis {
    <#
      Stops IIS in its entirety (iisreset.exe /stop) so a non-DELTA-managed
      IIS instance releases whatever ports it holds - only ever called
      after Show-DeltaNginxForeignIisConflictNotice's own explicit Y/N
      confirmation, never automatically.

      Deliberately `iisreset /stop`, not a narrower Stop-Service on W3SVC
      alone - setup-iis.ps1's own Restart-DeltaIisForArrConfiguration
      already notes a narrower service-level stop/start was never
      verified and would be an unproven assumption; iisreset is the one
      tool actually confirmed to reliably control IIS as a whole. No
      /noforce here, unlike that function's own graceful restart - the
      operator has already explicitly accepted the interruption via the
      notice's own warning text, and the goal is the ports actually being
      free by the time Wait-DeltaPortsReleased below gives up, not
      draining in-flight requests.

      Reuses Wait-DeltaPortsReleased (lib\DeltaInstaller.Common.ps1) - the
      same "confirm ports actually let go" primitive
      Invoke-DeltaReverseProxyHandover already relies on for the
      DELTA-managed case. Deliberately does NOT itself decide
      success/failure if ports remain occupied (unlike
      Invoke-DeltaReverseProxyHandover's own Stop-Setup in that case) -
      the caller (Test-DeltaNginxPortPrerequisites) re-runs its own normal
      port check afterward and falls through to the existing hard-failure
      notice if anything is still occupied, per this feature's own
      explicit "if the ports remain unavailable, display the existing
      prerequisite failure" requirement - never a second, bespoke error
      path of its own.
    #>
    param([Parameter(Mandatory)][int[]]$RequiredPorts)

    Write-Step 'Stopping IIS...'
    $process = Start-ProcessWithActivityIndicator -FilePath 'iisreset.exe' -ArgumentList '/stop' -ActivityName 'Stopping IIS'
    if ($process.ExitCode -ne 0) {
        Stop-Setup "iisreset.exe /stop returned exit code $($process.ExitCode)."
    }

    Write-Step 'Verifying required ports were released...'
    $stillOccupied = Wait-DeltaPortsReleased -Ports $RequiredPorts
    if ($stillOccupied.Count -eq 0) {
        Write-Success '    IIS stopped; ports released.'
    }
}

function Show-DeltaNginxPortsAvailableNotice {
    <#
      Available Ports (docs\todo\...) - the happy-path banner. Always
      printed on success now that Test-DeltaNginxPortPrerequisites itself
      is only ever called immediately before an operation that actually
      needs to bind these ports (see that function's own header) - there
      is no longer a "silent" case to special-case around, since this is
      never invoked just to display the management menu.
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
      above for the full placement rationale, in particular why callers
      only ever reach this function immediately before an operation that
      actually needs to bind these ports (Install-Nginx on a fresh
      install; Start-DeltaNginx's own fresh-start branch otherwise) -
      never as a blanket gate run just to inspect an installation or
      display the management menu.

      Doctor first, per the Manual Reverse Proxy Handover feature's own
      design principle ("no reverse proxy ownership detection outside
      Doctor"): $ReverseProxyState (the orchestration block's own
      already-computed Get-DeltaReverseProxyState result - never
      re-detected here) is asked, via Get-DeltaReverseProxyHandoverPlan
      (lib\DeltaDoctor.ReverseProxy.ps1), what would actually need to
      happen for NGINX to safely take ownership of its required ports -
      $null when there is no conflict at all. ARCHITECTURE CORRECTION:
      this no longer assumes stopping IIS's own DELTA-managed website is
      sufficient by itself (confirmed false on a real machine - IIS's own
      stock "Default Web Site" can independently hold the same port) -
      Doctor's own plan already accounts for that, and may refuse
      automatic handover outright if something it cannot safely stop is
      in the way. Invoke-DeltaReverseProxyHandover
      (lib\DeltaInstaller.Common.ps1) presents whatever plan Doctor built
      and, only on explicit confirmation, executes it - a decline OR an
      unsafe plan is a complete, reported no-op (`exit 0`, matching every
      other "administrator declined" clean-exit notice in this script),
      never a hard failure, since nothing this script owns has been
      touched either way.

      Only once that's resolved (or never applied at all) does the raw,
      low-level safety net run - the direct Get-DeltaNginxRequiredPorts/
      Test-RequiredPortAvailability check this function has always used.
      A conflict here Doctor cannot attribute to a DELTA-managed provider
      at all falls into one of two shapes: it looks like IIS itself (the
      owning PID is 4/"System", the way HTTP.sys-owned listeners are
      always attributed - see the $iisInstalled comment below) and IIS is
      genuinely installed, in which case Show-DeltaNginxForeignIisConflictNotice
      explains the situation and asks explicit Y/N permission to run
      Stop-DeltaForeignIis before re-checking once more (still fully
      operator-confirmed, never automatic - a decline is the same clean
      `exit 0` no-op every other declined prompt in this script uses); or
      it's anything else (an unrelated application, or IIS not installed
      at all), which remains the original hard, unexplained conflict,
      reported via Show-DeltaNginxPortConflictNotice and `exit 1`. A
      successful DELTA-managed handover, or a successful foreign-IIS
      stop, both leave nothing for this check to find, so it simply
      prints the same "Available" success banner
      (Show-DeltaNginxPortsAvailableNotice) either way.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$ReverseProxyState)

    Write-Step 'Checking required NGINX ports...'
    $requiredPorts = Get-DeltaNginxRequiredPorts

    $handoverPlan = Get-DeltaReverseProxyHandoverPlan -ReverseProxyState $ReverseProxyState -RequestingProviderName 'NGINX'
    if ($handoverPlan) {
        $handedOver = Invoke-DeltaReverseProxyHandover -Plan $handoverPlan

        if (-not $handedOver) {
            exit 0
        }
    }

    # IIS Installed (Doctor-reported, not re-detected here) alone isn't
    # enough to blame this specific conflict on it - HTTP.sys-owned
    # listeners are always attributed to PID 4 ("System") by Windows
    # (confirmed directly - see setup-iis.ps1's own
    # Test-DeltaIisRequiredPortAvailability header for the identical
    # finding on its own side), so that PID is the actual signal; IIS
    # being installed just rules out coincidentally matching PID 4 for
    # some unrelated reason. Only used to choose which notice to show
    # below - the DELTA-managed handover path above already fully owns
    # the case where this same IIS is DELTA-managed.
    $iisInstalled = [bool](($ReverseProxyState.ProviderStates | Where-Object { $_.Name -eq 'IIS' } | Select-Object -First 1).Installed)

    $results  = @(foreach ($port in $requiredPorts) { Test-RequiredPortAvailability -Port $port })
    $conflict = $results | Where-Object { -not $_.Available } | Select-Object -First 1

    if ($conflict) {
        $looksLikeIis = $iisInstalled -and $conflict.Owner -and ($conflict.Owner.ProcessId -eq 4)
        if ($looksLikeIis) {
            $wantsStop = Show-DeltaNginxForeignIisConflictNotice -RequiredPorts $requiredPorts
            if (-not $wantsStop) {
                Write-Host ''
                Write-Detail 'No changes have been made.'
                Write-Host ''
                exit 0
            }

            Stop-DeltaForeignIis -RequiredPorts $requiredPorts

            # Re-run the same check once more - success or failure from
            # here on is decided exactly as if this had been the first
            # attempt (still-occupied falls straight through to the
            # existing hard-failure notice below, per this feature's own
            # "if the ports remain unavailable, display the existing
            # prerequisite failure" requirement).
            $results  = @(foreach ($port in $requiredPorts) { Test-RequiredPortAvailability -Port $port })
            $conflict = $results | Where-Object { -not $_.Available } | Select-Object -First 1
        }
    }

    if ($conflict) {
        Show-DeltaNginxPortConflictNotice -PortCheck $conflict
        exit 1
    }

    Show-DeltaNginxPortsAvailableNotice -RequiredPorts $requiredPorts
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

function Read-DeltaNginxSecondReverseProxyConfirmation {
    <#
      Shown only when Doctor's own Reverse Proxy Detection
      (lib\DeltaDoctor.ReverseProxy.ps1, Get-DeltaReverseProxyConflictingProvider)
      reports that another provider is already DELTA's active reverse
      proxy AND nginx.exe does not exist yet on this machine - i.e. this
      run would be configuring a SECOND, competing DELTA-managed reverse
      proxy, not managing or replacing the existing one (an nginx.exe that
      already exists is always a management scenario, never a "second
      install" question - see the orchestration block's own placement of
      this check). setup-nginx.ps1 has no migration capability of its own
      (that remains a future reverse-proxy.ps1's own job - see
      lib\DeltaDoctor.ReverseProxy.ps1's own header) - this only ever
      explains the situation, per this feature's own "ARCHITECTURE
      CORRECTION" design principle ("offer migration or explain the
      situation"), and asks whether to proceed anyway. Defaults to No,
      the same "blank means the safe choice" convention every
      confirmation in this project follows - an administrator who did not
      intend to run two reverse proxies at once should land on the option
      that changes nothing.
    #>
    param([Parameter(Mandatory)][string]$ActiveProviderName)

    return Read-DeltaYesNoConfirmation -Body {
        Write-Host "$ActiveProviderName is currently DELTA's active reverse proxy."
        Write-Host ''
        Write-Host 'Installing NGINX now would configure a second, competing reverse'
        Write-Host 'proxy for the same DELTA deployment, rather than replacing the'
        Write-Host "existing one - this script has no migration capability; $ActiveProviderName"
        Write-Host 'would need to be stopped/reconfigured by hand for NGINX to serve'
        Write-Host 'DELTA traffic instead.'
        Write-Host ''
        Write-Host 'Continue installing NGINX anyway?'
    }
}

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

    $packagePath = Join-Path -Path $Script:InstallersDirectory -ChildPath $Script:InstallerConfig.NGINX_INSTALLER

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
# Startup Validation
# ---------------------------------------------------------------------------
#
# The pid-file-based Managed Runtime State machine itself
# (Get-DeltaNginxRuntimeState and everything it depends on) now lives in
# lib\DeltaDoctor.NGINX.ps1 - see that file's own header. What remains here
# is specific to THIS script's own fresh-start flow: which ports a just-
# written configuration should be listening on, and confirming a process
# Start-DeltaNginx just launched is genuinely healthy before reporting
# success.

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
        if (-not (Test-DeltaTcpPortListening -Port $port)) {
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

# Send-DeltaNginxSignal (the `-s <Signal>` control-signal sender every
# action below builds on) now lives in lib\DeltaDoctor.NGINX.ps1, promoted
# there alongside Stop-DeltaManagedNginx once setup-iis.ps1 needed the
# identical NGINX stop action for its own side of the Manual Reverse Proxy
# Handover feature - see that file's own header.

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

      Manual Reverse Proxy Handover - AFTER START: once NGINX is
      confirmed healthy, if $Script:DeltaReverseProxyHandoverOccurred is
      set (Invoke-DeltaReverseProxyHandover, lib\DeltaInstaller.Common.ps1,
      already marked it earlier in this same run - see
      Test-DeltaNginxPortPrerequisites), this runs Doctor's own Reverse
      Proxy Detection one more time and prints it, per this feature's own
      explicit "run Doctor again" final-validation requirement - the
      administrator sees NGINX confirmed Active/Healthy from the same
      authoritative source that reported IIS active a moment earlier,
      not just this script's own "started successfully" claim. Skipped
      entirely on an ordinary start/reload with no handover involved, to
      avoid adding a second report where nothing changed that Doctor
      needs to re-explain.
    #>

    Write-PhaseBanner 'NGINX Start / Reload'

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to start or reload NGINX (binding port 80 requires it). Re-run this script from an elevated PowerShell session.'
    }

    $state = Get-DeltaNginxRuntimeState

    if ($state.State -eq 'Running') {
        Write-Step 'Reloading NGINX configuration...'
        Send-DeltaNginxSignal -Signal 'reload'
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

    if ($Script:DeltaReverseProxyHandoverOccurred) {
        $Script:DeltaReverseProxyHandoverOccurred = $false
        Write-Host ''
        Write-PhaseBanner 'Deployment Validation'
        Invoke-DeltaReverseProxyDetection | Out-Null
    }
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

function Invoke-DeltaNginxReload {
    <#
      Existing Installation management menu action 2 ("Reload
      configuration") - calls straight through to the same shared
      Send-DeltaNginxSignal helper (lib\DeltaDoctor.NGINX.ps1)
      Start-DeltaNginx's own reload branch uses, rather than a second
      implementation. Re-checks Get-DeltaNginxRuntimeState itself rather
      than trusting a snapshot the menu took a moment earlier (state
      could have changed between the menu displaying it and the
      administrator's keystroke); reloading anything other than a
      confirmed-Running instance is meaningless, so this reports that
      plainly instead of attempting the signal and surfacing nginx.exe's
      own confusing failure text.
    #>

    $state = Get-DeltaNginxRuntimeState
    if ($state.State -ne 'Running') {
        Write-Host ''
        Write-Detail 'NGINX is not running - nothing to reload.'
        return
    }

    Write-Step 'Reloading NGINX configuration...'
    Send-DeltaNginxSignal -Signal 'reload'
    Write-Success '    NGINX reloaded.'
}

# Invoke-DeltaNginxStop (management menu action 4, "Stop NGINX") is now
# Stop-DeltaManagedNginx, lib\DeltaDoctor.NGINX.ps1 - promoted there once
# setup-iis.ps1 needed the identical action for its own side of the Manual
# Reverse Proxy Handover feature (stopping NGINX so IIS can bind the port
# instead), rather than this menu carrying its own copy of the exact same
# stop-and-wait sequence. See that function's own header.

function Invoke-DeltaNginxRestart {
    <#
      Existing Installation management menu action 3 ("Restart
      NGINX"). NGINX has no single built-in "restart" signal, so this
      composes Stop-DeltaManagedNginx (lib\DeltaDoctor.NGINX.ps1) with
      Start-DeltaNginx, below - which, finding a clean 'Stopped' state at
      that point, always takes its own fresh-start path rather than this
      needing to duplicate that Start-Process/Wait-Until logic itself.
      If NGINX was already stopped, this is simply equivalent to
      starting it.

      Re-checks the port prerequisite (Test-DeltaNginxPortPrerequisites)
      immediately before that fresh start - the one point in this whole
      action that actually needs port 80 free again, per this file's own
      "port checks only run right before an operation that needs to bind
      them" principle (see that function's own section header). Stopping
      NGINX itself just freed the port; this re-check exists purely to
      catch the unlikely case something else grabbed it in the interim,
      rather than trusting that gap blindly.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$ReverseProxyState)

    if ((Get-DeltaNginxRuntimeState).State -eq 'Running') {
        Stop-DeltaManagedNginx
    }

    Test-DeltaNginxPortPrerequisites -ReverseProxyState $ReverseProxyState
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

# ---------------------------------------------------------------------------
# PUBLIC_URL synchronization (existing installation)
# ---------------------------------------------------------------------------
#
# After initial installation, NGINX - not .env.example/setup.ps1 - is the
# source of truth for the deployed PUBLIC_URL (lib\DeltaInstaller.Common.ps1's
# own Sync-DeltaPublicUrlEnvironment header). Runs once, before the
# management menu is ever shown, so every successful re-run of this script
# against an already-configured installation keeps .env in sync with
# whatever NGINX is actually serving - never only on a fresh install. This
# section only ever writes .env - it deliberately never restarts DELTA
# itself; the management menu's own "Restart DELTA backend" option
# (Restart-DeltaRuntimeForReverseProxy, lib\DeltaInstaller.Common.ps1) is
# the one place that does, and only when the administrator explicitly
# chooses it.

function Show-DeltaNginxPublicUrlMismatchNotice {
    <#
      The "do these disagree" notice this feature's own requirements
      describe - shown once, immediately before re-prompting for the
      domain, so the administrator understands why they're being asked
      again on a re-run of a script that otherwise never re-prompts for
      an already-configured installation (see Show-DeltaNginxManagementMenu's
      own header for that general rule).
    #>
    param(
        [Parameter(Mandatory)][string]$ConfiguredUrl,
        [Parameter(Mandatory)][string]$EnvUrl
    )

    Write-Host ''
    Write-Host 'The configured NGINX domain and PUBLIC_URL do not match.'
    Write-Host ''
    Write-Host 'NGINX:'
    Write-Detail $ConfiguredUrl
    Write-Host ''
    Write-Host '.env:'
    Write-Detail $EnvUrl
    Write-Host ''
}

function Resolve-DeltaNginxPublicUrlSync {
    <#
      Reads the already-generated DELTA vhost's own server_name/scheme
      (Get-DeltaNginxVHostSummary, lib\DeltaDoctor.NGINX.ps1 - the same
      read-only source the management menu's own display already trusts),
      compares it against PUBLIC_URL in .env (Test-DeltaPublicUrlsMatch),
      and only acts on a genuine disagreement:

        - No DELTA-owned vhost found at all (IsDeltaOwned $false, or no
          ServerName parsed) - nothing to compare against yet; leaves
          .env untouched, exactly like every other read-only check in
          this file's own ownership discipline (Get-DeltaNginxVHostSummary's
          own header).
        - PUBLIC_URL absent from .env entirely - backfilled silently via
          Sync-DeltaPublicUrlEnvironment; there is nothing to conflict
          with, so there is nothing to ask the operator about. DELTA
          itself is never restarted here - see this section's own header.
        - PUBLIC_URL present and already matching (normalized) - a silent
          no-op; continues straight to the management menu exactly as
          before this feature existed.
        - PUBLIC_URL present and NOT matching - shows
          Show-DeltaNginxPublicUrlMismatchNotice, then re-prompts for the
          domain (Resolve-DeltaWebsiteDomain -DefaultDomain, defaulting a
          bare Enter to the domain NGINX is already configured with, not
          "localhost" - see that function's own header), regenerates and
          re-validates the configuration exactly like a fresh install
          (New-DeltaNginxConfiguration/Test-DeltaNginxConfiguration), and
          only writes the new PUBLIC_URL once Start-DeltaNginx - which
          itself reloads a Running instance or starts a Stopped one, no
          separate branch needed here - actually confirms it healthy,
          matching this feature's own "written, validated, and started/
          reloaded successfully" gate. Still never restarts DELTA itself.

      $Script:SslCertificateConfigured is set from the vhost's own
      already-configured HTTPS state (IsHttps) rather than re-running the
      SSL Certificate Wizard - only the domain is being resynchronized
      here, never the certificate.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$ReverseProxyState)

    $vhost = Get-DeltaNginxVHostSummary
    if (-not $vhost.IsDeltaOwned -or -not $vhost.ServerName) {
        return
    }

    $configuredUrl = Get-DeltaPublicUrl -Domain $vhost.ServerName -Https $vhost.IsHttps
    $envUrl = Get-EnvFileValue -Path $Script:DeltaEnvPath -Key 'PUBLIC_URL'

    if (-not $envUrl) {
        Sync-DeltaPublicUrlEnvironment -Domain $vhost.ServerName -Https:$vhost.IsHttps
        return
    }

    if (Test-DeltaPublicUrlsMatch -First $configuredUrl -Second $envUrl) {
        return
    }

    Show-DeltaNginxPublicUrlMismatchNotice -ConfiguredUrl $configuredUrl -EnvUrl $envUrl

    Write-PhaseBanner 'Public Website Domain'
    $Script:DeltaWebsiteDomain = Resolve-DeltaWebsiteDomain -DefaultDomain $vhost.ServerName
    Write-Success "    Website domain: $($Script:DeltaWebsiteDomain)"

    $Script:SslCertificateConfigured = $vhost.IsHttps
    Resolve-DeltaBackendPort

    New-DeltaNginxConfiguration
    Test-DeltaNginxConfiguration

    if (Read-DeltaNginxStartConfirmation) {
        # Only when Stopped - see Test-DeltaNginxPortPrerequisites's own
        # header for why this check only ever runs immediately before an
        # operation that actually needs to bind these ports: a Running
        # instance already owns them (Start-DeltaNginx's own reload
        # branch needs nothing rebound), so checking here too would
        # misreport NGINX's own already-held ports as a conflict against
        # itself.
        if ((Get-DeltaNginxRuntimeState).State -eq 'Stopped') {
            Test-DeltaNginxPortPrerequisites -ReverseProxyState $ReverseProxyState
        }

        Start-DeltaNginx
        Sync-DeltaPublicUrlEnvironment -Domain $Script:DeltaWebsiteDomain -Https:$Script:SslCertificateConfigured
    }
    else {
        Write-Host ''
        Write-Detail 'NGINX was not reloaded. PUBLIC_URL has not been updated.'
    }
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
      always showing the same set:
        Running - the full Validate/Reload/Restart NGINX/Restart DELTA
                  backend/Stop/Exit menu. "Restart DELTA backend"
                  (Restart-DeltaRuntimeForReverseProxy,
                  lib\DeltaInstaller.Common.ps1) is the only option here
                  that touches the DELTA (Node.js) process rather than
                  NGINX itself - kept as its own explicit, administrator-
                  triggered choice rather than something any other action
                  here (in particular Reload, which only ever reloads
                  NGINX's own configuration) does automatically. This is
                  also the one place an administrator picks after a
                  PUBLIC_URL synchronization (the section above) to
                  actually make DELTA pick up the new value - that sync
                  itself never restarts DELTA on its own.
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

      $ReverseProxyState is Doctor's own already-computed
      Get-DeltaReverseProxyState result (the orchestration block's own -
      never re-detected here) - consumed for two things, per this file's
      own "consume Doctor before low-level checks, never re-derive what
      it already answered" principle (see the file header's ARCHITECTURE
      CORRECTION): a one-line, Doctor-derived summary of NGINX's own
      ownership printed once, before the loop starts (never recomputed
      per iteration - it's a fact about configuration ownership, not
      runtime status, so it can't change while this menu is open), and
      threaded through to Test-DeltaNginxPortPrerequisites at the two
      points inside this menu that actually attempt to bind a port
      (Start NGINX, Restart NGINX) - see that function's own section
      header for why the check itself belongs there and nowhere earlier.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$ReverseProxyState)

    $nginxProviderState = $ReverseProxyState.ProviderStates | Where-Object { $_.Name -eq 'NGINX' } | Select-Object -First 1
    if ($nginxProviderState -and $nginxProviderState.ManagedByDelta) {
        Write-Detail 'A DELTA-managed NGINX deployment already exists. No provisioning is required.'
    }
    else {
        Write-Detail 'An NGINX installation exists at this location, but it is not managed by DELTA.'
    }

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
                Write-Host '4) Restart DELTA backend'
                Write-Host '5) Stop NGINX'
                Write-Host '6) Exit'
                Write-Host ''

                $choice = Read-Host -Prompt 'Choose an option [6]'
                if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '6' }

                switch ($choice.Trim()) {
                    '1' { Test-DeltaNginxConfiguration }
                    '2' { Invoke-DeltaNginxReload }
                    '3' { Invoke-DeltaNginxRestart -ReverseProxyState $ReverseProxyState }
                    '4' { Restart-DeltaRuntimeForReverseProxy }
                    '5' { Stop-DeltaManagedNginx }
                    '6' { return }
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
                    '1' { Test-DeltaNginxPortPrerequisites -ReverseProxyState $ReverseProxyState; Start-DeltaNginx }
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
#
# ARCHITECTURE CORRECTION: this script no longer opens by independently
# re-deriving system state from raw TCP ports. Doctor's own Reverse Proxy
# Detection (Invoke-DeltaReverseProxyDetection, lib\DeltaDoctor.ReverseProxy.ps1)
# is the first thing that runs after DELTA installation discovery - it
# answers "what is the current DELTA reverse proxy state" (which providers
# exist, which are DELTA-managed, which one is active); this script only
# ever answers "what should I do next" from that already-computed answer,
# and consumes it directly rather than re-opening an independent
# diagnostic sequence of its own (see Show-DeltaNginxManagementMenu's own
# header). Concretely: an existing NGINX installation hands off straight
# to the management menu the moment Doctor's report and the existence
# check below are known - no low-level port check runs first, since
# merely inspecting or managing an already-configured NGINX never needs to
# bind anything (see the "Port prerequisite check" section header further
# up for the full "checks only run right before a real bind attempt"
# principle). A fresh install (nginx.exe does not exist yet) while another
# provider is already DELTA's active reverse proxy is recognized and
# explained AS a "you are about to configure a second reverse proxy"
# situation, with an explicit confirmation gate - the low-level port check
# itself still runs, but only once that and the installation confirmation
# have both passed, immediately before Install-Nginx, the first step that
# actually needs the port free (and now attributes any conflict it finds
# back to a known DELTA-managed provider when Doctor can explain it).

try {
    Write-SetupBanner -Title 'DELTA NGINX Setup' -Subtitle 'Optional reverse proxy for DELTA'

    # Must happen before anything else, including Reverse Proxy Detection
    # below - see Resolve-DeltaInstallation's own header. Nothing above this
    # point has touched the filesystem.
    Resolve-DeltaInstallation

    # Doctor's own Reverse Proxy Detection - runs unconditionally, before
    # ANY workflow decision below, so this script's own choices are driven
    # by Doctor's already-computed, DELTA-ownership-based answer, never
    # independently re-derived from raw ports/processes. See this section's
    # own header above.
    $reverseProxyState = Invoke-DeltaReverseProxyDetection
    Write-Host ''

    $nginxAlreadyInstalled = Test-Path -LiteralPath $Script:NginxExePath

    # An existing installation is always a management scenario - hand off
    # immediately, with no low-level port check in front of it (see this
    # section's own header). Nothing below this point is reachable in
    # that case.
    if ($nginxAlreadyInstalled) {
        Resolve-DeltaNginxPublicUrlSync -ReverseProxyState $reverseProxyState
        Show-DeltaNginxManagementMenu -ReverseProxyState $reverseProxyState
        exit 0
    }

    # A fresh install is only ever "a second reverse proxy" question when
    # NGINX itself doesn't exist yet - the existing-installation case,
    # handled above, is always a management scenario, never a competing
    # second install.
    $conflictingProvider = Get-DeltaReverseProxyConflictingProvider -ReverseProxyState $reverseProxyState -RequestingProviderName 'NGINX'
    if ($conflictingProvider) {
        if (-not (Read-DeltaNginxSecondReverseProxyConfirmation -ActiveProviderName $conflictingProvider)) {
            Show-DeltaNginxInstallCancelledNotice
            exit 0
        }
    }

    # Installation Confirmation - the last chance to back out before
    # anything is written to disk. Nothing above this point has touched
    # the filesystem (Resolve-DeltaInstallation only reads the registry/
    # legacy .env, and every check above is read-only).
    if (-not (Read-DeltaNginxInstallConfirmation)) {
        Show-DeltaNginxInstallCancelledNotice
        exit 0
    }

    # Operational safety enhancement - see this function's own section
    # header for why this runs here specifically: only now, immediately
    # before Install-Nginx, the first step that actually needs these
    # ports free - never as an earlier blanket gate. Exits (1) immediately
    # on a genuine conflict - nothing below this point is reachable in
    # that case either.
    Test-DeltaNginxPortPrerequisites -ReverseProxyState $reverseProxyState

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
        Sync-DeltaPublicUrlEnvironment -Domain $Script:DeltaWebsiteDomain -Https:$Script:SslCertificateConfigured
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

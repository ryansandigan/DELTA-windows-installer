#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses and repairs an existing IIS-based DELTA deployment.

.DESCRIPTION
    This is NOT an installer and NOT an uninstaller - its sole job is to
    look at an existing DELTA installation, tell the administrator exactly
    what is wrong with it, and (optionally) fix what it can, without ever
    requiring an uninstall/reinstall cycle.

    Two feature areas so far:

      - Reverse Proxy Detection (read-only, both providers): which
        supported reverse proxy providers (IIS, NGINX) are installed,
        which are actually managed by DELTA (decided ONLY from
        configuration DELTA itself generated - never from a TCP port,
        process, PID, registry key, or service status alone - see
        lib\DeltaDoctor.ReverseProxy.ps1's own header for why), which one
        is currently active, whether more than one DELTA-managed provider
        exists at once (a warning, not an error - only one should normally
        be active), and a plain-language recommendation. Never modifies
        anything. Exposes both a human-readable report and a structured
        result object future components can consume directly.

      - IIS diagnostics/repair (the original feature): IIS/ARR/URL Rewrite
        prerequisites, the managed DELTA website's own configuration
        (application pool, bindings, web.config, its reverse-proxy rule),
        and whether the configured backend port is actually being listened
        on - with an offered, confirmed repair for anything wrong at the
        website-configuration level. NGINX repair, PostgreSQL, Node.js, the
        Windows Service, and any runtime validation beyond "is something
        listening on the backend port" remain out of scope for now.

    Architecture: this file is nothing more than a command-line entry
    point - every check/detection and every repair action it runs lives in
    lib\DeltaDoctor.ReverseProxy.ps1 (which itself dot-sources
    lib\DeltaDoctor.IIS.ps1 and lib\DeltaDoctor.NGINX.ps1), dot-sourced
    below. setup-iis.ps1 and setup-nginx.ps1 both consume the identical
    shared functions directly for their own provisioning/lifecycle needs -
    there is only ONE implementation of this diagnostic logic in this
    project, and no setup-*.ps1 script is ever dot-sourced by this file (or
    the reverse). See lib\DeltaDoctor.ReverseProxy.ps1's own header for the
    full architecture.

    Flow: Detect (is DELTA installed at all) -> Reverse Proxy Detection
    (read-only, both providers, always runs once DELTA is found) -> IIS
    prerequisites -> Diagnose/Report/Offer Repair/Validate Again (the
    managed IIS website's own configuration and backend connectivity -
    Invoke-DeltaIisConfigurationCheckup, the same shared cycle
    setup-iis.ps1 itself now calls). A DELTA installation that can't be
    found stops this script before anything else runs; IIS prerequisites
    that aren't ready stop it before the IIS-specific checkup specifically
    (Reverse Proxy Detection itself never depends on IIS being ready at
    all - a pure-NGINX deployment must still get a meaningful report).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See lib\DeltaInstaller.Common.ps1's own header for why $Script:ProjectRoot
# must be computed here, before dot-sourcing anything - $PSScriptRoot inside
# a dot-sourced file always refers to THAT file's own location, never the
# caller's.
$Script:ProjectRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# lib\DeltaDoctor.ReverseProxy.ps1 dot-sources lib\DeltaDoctor.IIS.ps1 and
# lib\DeltaDoctor.NGINX.ps1, each of which dot-sources
# lib\DeltaInstaller.Common.ps1 itself - so this one dot-source is
# sufficient to pull in every function this script uses, from
# Write-Step/Get-DeltaInstallPath (Common.ps1) through
# Get-DeltaDoctorWebsiteChecks/Invoke-DeltaIisConfigurationCheckup
# (DeltaDoctor.IIS.ps1) and Invoke-DeltaReverseProxyDetection
# (DeltaDoctor.ReverseProxy.ps1 itself).
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaDoctor.ReverseProxy.ps1')

# ---------------------------------------------------------------------------
# Orchestration - Detect -> Diagnose -> Report -> Offer Repair -> Validate Again
# ---------------------------------------------------------------------------

try {
    Write-SetupBanner -Title 'DELTA Doctor' -Subtitle 'IIS Configuration Diagnostics'

    # ---- Detect: DELTA installation ----
    Write-Step 'Detecting DELTA installation...'
    $installation = Get-DeltaDoctorInstallationChecks
    Show-DeltaDoctorChecks -Checks $installation.Checks
    Write-Host ''

    if (-not $installation.Found) {
        Write-Host 'Cannot continue - no DELTA installation was found.' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }

    # Every function below reads these from script scope rather than
    # taking them as parameters - see e.g. Get-DeltaIisManagedWebsiteResult's
    # own header - so they must be set here, exactly as
    # Resolve-DeltaInstallation itself would, before ANY detection below
    # (Reverse Proxy Detection included) runs.
    $Script:DeltaInstallPath = $installation.InstallPath
    $Script:DeltaEnvPath = $installation.EnvPath

    # ---- Reverse Proxy Detection (read-only, both providers) ----
    # Deliberately runs before the IIS-specific prerequisite gate below -
    # this section never depends on IIS being installed/ready at all (a
    # pure-NGINX deployment must still get a meaningful report), and is the
    # one shared cycle (lib\DeltaDoctor.ReverseProxy.ps1) any future
    # component (reverse-proxy.ps1, uninstall.ps1, ...) will consume too -
    # see that function's own header.
    $reverseProxyState = Invoke-DeltaReverseProxyDetection
    Write-Host ''

    # ---- Diagnose: IIS prerequisites (independent of DELTA's own state) ----
    Write-Step 'Checking IIS prerequisites...'
    $prereqs = Get-DeltaDoctorIisPrerequisiteChecks
    Show-DeltaDoctorChecks -Checks $prereqs.Checks
    Write-Host ''

    if (-not $prereqs.Ready) {
        Write-Host 'Cannot continue - IIS prerequisites are not ready. Run setup-iis.ps1 first.' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }

    # ---- Diagnose -> Report -> Offer Repair -> Validate Again ----
    # The one shared cycle (lib\DeltaDoctor.IIS.ps1) setup-iis.ps1 itself
    # now calls too - see that function's own header.
    $checkup = Invoke-DeltaIisConfigurationCheckup

    exit $(if ($checkup.Healthy) { 0 } else { 1 })
}
catch {
    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Red
    Write-Host 'DELTA Doctor failed.' -ForegroundColor Red
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

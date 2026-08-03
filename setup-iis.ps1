#Requires -Version 5.1
<#
.SYNOPSIS
    Installs and configures Microsoft IIS as an optional reverse proxy for DELTA.

.DESCRIPTION
    The sibling of setup-nginx.ps1 for administrators who standardize on
    Microsoft IIS instead of NGINX - see docs\todo\TODO-setup-iis-enhancements.md
    for the full phased roadmap this script is built against. Phases are
    implemented one at a time, in order; only Phase 1 (Shared DELTA
    Installation Discovery), Phase 2 (Microsoft IIS Detection), Phase 3
    (IIS Installation), Phase 4 (Application Request Routing), and Phase 7
    (Windows SSL Certificate) exist as this script's own phases now. What
    were originally this script's own Phase 5 (Website Discovery) and
    Phase 6 (Website Configuration) - detecting/creating/reconciling the
    managed DELTA website itself - have since been promoted out to
    lib\DeltaDoctor.IIS.ps1 and are owned by doctor.ps1 as the DELTA
    Windows Installer's authoritative IIS diagnostic/repair utility; this
    script now consumes that shared implementation (Invoke-DeltaIisConfigurationCheckup)
    rather than carrying its own copy - see that file's own header for the
    full architecture and why. The roadmap's original, separately-numbered
    Phase 7 (Website Domain) was merged into what was Phase 6 once that
    phase was actually implemented, and what is now Phase 7 here combines
    what the roadmap originally split into SSL Certificate and Existing
    Certificate Handling.

    Phase 1: before anything IIS-specific can ever run, confirm a real
    DELTA installation actually exists on this machine, via the shared
    Resolve-DeltaInstallation helper (lib\DeltaInstaller.Common.ps1) -
    already promoted out of setup-nginx.ps1 specifically so this script
    could consume the identical implementation rather than growing a
    second copy of it. This script is a CONSUMER of that discovery, never
    a second implementation of it, and never assumes DELTA lives at a
    fixed C:\DELTA path itself. No installation found means Resolve-
    DeltaInstallation stops the script outright (Stop-Setup) before any
    IIS detection is ever attempted.

    Phase 2: once DELTA is confirmed, determines the current Microsoft
    IIS environment - whether IIS is installed at all, its version, which
    of the two Windows Feature APIs applies (ServerManager/Get-WindowsFeature
    on Windows Server, DISM/Get-WindowsOptionalFeature on Windows 11/10
    client SKUs - detected, never assumed), the installed/missing state of
    every IIS role service/feature later phases depend on, and whether
    Microsoft.Web.Administration - the assembly every later phase manages
    sites/bindings/application pools through - can actually be loaded.
    Detection only: nothing in this
    phase installs, enables, or configures IIS in any way, regardless of
    what it finds. Displays a detailed summary and exits successfully
    either way - IIS not being installed is not an error, it is simply a
    fact this phase reports before Phase 3 acts on it.

    Phase 3: installs exactly the Windows IIS role services/features
    Phase 2's own detection identified as missing - never a broader
    install, and never a second, independent feature list. Prompts for
    confirmation first (default No) unless nothing is missing at all, in
    which case nothing is installed and no prompt is shown. Uses
    Install-WindowsFeature on Windows Server and Enable-WindowsOptionalFeature
    -Online on Windows 10/11 client SKUs - whichever Phase 2 already
    determined applies - and never the other platform's API. Requires
    Administrator privileges before installing anything, and never
    restarts Windows automatically: if either API reports a restart is
    needed, this script says so plainly and exits without attempting
    Post-Installation Verification or any later phase, since IIS cannot
    be trusted to be fully ready until after that reboot. Otherwise,
    re-runs Phase 2's own detection after installing and treats THAT
    result - never the installation command's own reported success - as
    authoritative, stopping with a specific list of anything still
    missing rather than reporting success prematurely. Does not implement
    ARR, URL Rewrite, website/application pool creation, bindings,
    certificates, or runtime management - those remain later phases.

    Phase 4: prepares IIS for reverse-proxy usage - detects URL Rewrite
    and Application Request Routing (ARR), neither of which is a Windows
    Feature (standalone Microsoft redistributables instead), installs
    whichever is missing (after confirmation) via the same silent-MSI
    convention setup.ps1 already uses for Node.js, re-verifies afterward
    rather than trusting msiexec's own exit code alone, then enables the
    machine-wide system.webServer/proxy setting and verifies that too.
    Stops cleanly - without ever reaching Phase 5 - if the administrator
    declines, if installation/verification fails, or if Windows reports a
    restart is required. Never creates a website, application pool,
    binding, or certificate.

    IIS Configuration Checkup: once Phase 4 has reported ready, this
    script determines whether a managed DELTA IIS website already exists
    (Get-DeltaIisManagedWebsiteResult, lib\DeltaDoctor.IIS.ps1 - a fixed
    site identity, $Script:DeltaIisSiteName/'DELTA', cross-validated
    against the resolved DELTA installation path, never inferred from the
    name alone), then hands off to that same file's own
    Invoke-DeltaIisConfigurationCheckup for everything else: diagnosing
    the site's own configuration (application pool, web.config, its
    reverse-proxy rule, HTTP/HTTPS bindings, backend connectivity),
    reporting the result, and - only with the administrator's explicit
    confirmation - repairing whatever it finds wrong, whether that means
    creating the dedicated application pool/website/web.config/binding for
    the very first time or reconciling an existing site missing one of
    those pieces. A genuine site-name collision (the fixed site name
    already claimed by an unrelated website) is reported by that same
    checkup as a non-repairable error, never a second, separate collision
    check here. This script itself owns none of that logic anymore - see
    lib\DeltaDoctor.IIS.ps1's own header for why, and for the full list of
    what it owns instead.

    Phase 7: configures HTTPS for the managed DELTA website using the
    Windows Certificate Store - never a file-path reference the way
    setup-nginx.ps1 uses for NGINX. Certificates are imported into
    Cert:\LocalMachine\My via Import-PfxCertificate; the returned
    certificate object's own Thumbprint is the only source of truth ever
    consumed afterward (never searched for again by friendly name). A
    Yes/No wizard mirrors setup-nginx.ps1's own SSL Certificate Wizard
    shape; an already-configured certificate instead offers Replace/Keep/
    Cancel, mirroring setup-nginx.ps1's own Existing Certificate Handling
    (both were originally separate roadmap phases, now combined into this
    one, the same way setup-nginx.ps1's own Install-DeltaSslCertificate
    already combines them for NGINX). Declining, keeping, or canceling
    are all clean, successful outcomes - HTTPS not being configured is
    never treated as an error.

    Once configuring HTTPS at all is confirmed, a second question decides
    HOW the certificate is supplied: a PKCS#12 (.pfx) directly (the
    original, unchanged implementation), or a certificate + private key
    pair (.crt/.cer/.pem + .key/.pem, matching setup-nginx.ps1's own
    always-used input shape) - the default, since it matches the
    administrator experience `setup-nginx.ps1` already established. The
    certificate + key path never touches the Windows Certificate Store or
    IIS directly - it converts the pair into a temporary PKCS#12 (a
    cryptographically random filename and password, both unseen by the
    administrator, always deleted afterward - even on failure - via a
    secure overwrite-then-remove) using BouncyCastle.Cryptography
    (vendored under lib\BouncyCastle\, MIT licensed) as the parsing/
    encoding engine, then hands that temporary file to the EXACT SAME,
    unmodified Import-PfxCertificate step the .pfx path already uses.
    BouncyCastle was chosen deliberately over a hand-written ASN.1 parser
    because .NET Framework 4.8 (this project's own PowerShell 5.1
    runtime) lacks the PEM/DER convenience methods needed to parse
    encrypted keys or the legacy OpenSSL PKCS#1 encryption scheme safely
    - see docs\todo\TODO-setup-iis-enhancements.md's own Phase 7
    investigation/validation notes for the full empirical findings.

    The HTTPS binding this phase owns is matched by protocol+port, never
    by replacing the site's entire bindings collection, so any other
    HTTPS binding an administrator added by hand is left untouched. Every
    claim this phase makes (certificate presence, binding existence,
    thumbprint, host header, SNI) is independently re-verified by reading
    the certificate store and IIS back afterward, never assumed from
    Import-PfxCertificate/New-WebBinding's own lack of a thrown error -
    unchanged by this enhancement. The installation summary never reveals
    which supply method was actually used - the final installed state is
    identical either way. Does not implement runtime management or
    port/binding conflict validation - those remain later phases.

    Management Mode: once a managed DELTA website already exists AND the
    IIS Configuration Checkup above reports it healthy (or an accepted
    repair just made it so), this script never falls through to the
    Certificate Wizard at all - it hands off instead to
    Show-DeltaIisManagementMenu and exits once the administrator chooses
    Exit. Nothing is re-prompted (website domain, backend port, ARR/URL
    Rewrite/Reverse Proxy, website/application pool creation) - the
    existing IIS configuration is the source of truth, and every value
    the menu displays is read back from it directly. The menu offers
    Start/Stop/Restart Website, Restart Application Pool, Browse Website,
    Validate Configuration, and Exit - the direct IIS analogue of
    setup-nginx.ps1's own Show-DeltaNginxManagementMenu, adapted to IIS's
    native website/application-pool cmdlets rather than NGINX's process-
    and-pid-file model. Validate Configuration itself is, like everything
    else diagnostic in this script now, a direct call into
    lib\DeltaDoctor.IIS.ps1's own Get-DeltaDoctorWebsiteChecks - not an
    independent check of its own. This is a narrower, UX/orchestration-only
    precursor to the full three-signal (service/website/app pool)
    Broken-state runtime model docs\todo\TODO-setup-iis-enhancements.md's
    own Phase 8 still describes - that fuller model remains a later,
    separate enhancement.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See lib\DeltaInstaller.Common.ps1's own header for why $Script:ProjectRoot
# must be computed here, before dot-sourcing it, rather than inside it.
$Script:ProjectRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Common.ps1')

# lib\DeltaDoctor.ReverseProxy.ps1 dot-sources both lib\DeltaDoctor.IIS.ps1
# (IIS/ARR detection, the DELTA website's own discovery/repair/lifecycle
# functions, and the Doctor's shared checkup cycle -
# Invoke-DeltaIisConfigurationCheckup - see that file's own header for the
# full architecture) AND lib\DeltaDoctor.NGINX.ps1 - this script needs both
# now: IIS's own functions/constants for the reasons it always has
# ($Script:DeltaIisSiteName/$Script:DeltaIisAppPoolName/
# $Script:DeltaIisWebConfigTemplate/$Script:UrlRewriteDownloadUrl/
# $Script:ArrDownloadUrl, all defined there, not here), and
# lib\DeltaDoctor.ReverseProxy.ps1's own
# Invoke-DeltaReverseProxyDetection/Get-DeltaReverseProxyConflictingProvider
# so this script's own workflow decisions are driven by Doctor's own
# cross-provider DELTA-ownership answer, never independently re-derived -
# see setup-nginx.ps1's own identical dot-source for precedent, and this
# script's own Orchestration section below for the Manual Reverse Proxy
# Handover feature this now enables.
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaDoctor.ReverseProxy.ps1')

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Downloaded ARR/URL Rewrite packages are cached project-locally in
# .\installers (sibling to this script, gitignored) - the same convention
# setup-nginx.ps1's own $Script:InstallersDirectory already uses for its
# NGINX ZIP download, so an operator-supplied local package (e.g. for an
# air-gapped install) or a prior run's own cached download is preferred
# over a fresh download either way.
$Script:InstallersDirectory = Join-Path -Path $Script:ProjectRoot -ChildPath 'installers'

# Where msiexec install logs are written - a dedicated temp directory
# (distinct from setup.ps1's own $Script:WorkingDirectory, 'delta-setup',
# so the two installers never contend over the same log files) rather
# than the project directory itself, matching setup.ps1's own
# Install-NodeMsi convention of keeping installer logs out of source
# control entirely.
$Script:WorkingDirectory = Join-Path -Path $env:TEMP -ChildPath 'delta-setup-iis'

# ---------------------------------------------------------------------------
# DELTA installation discovery
# ---------------------------------------------------------------------------
#
# Resolve-DeltaInstallation itself lives in lib\DeltaInstaller.Common.ps1
# (dot-sourced above) - it has no NGINX/IIS-specific knowledge at all, so
# this script consumes the exact same implementation setup-nginx.ps1 does
# rather than carrying a second copy that could drift apart. See that
# function's own header for the full behavior description.

# ---------------------------------------------------------------------------
# Microsoft IIS Installation (docs\todo\TODO-setup-iis-enhancements.md,
# Phase 3)
# ---------------------------------------------------------------------------
#
# Installs ONLY the specific role services/features lib\DeltaDoctor.IIS.ps1's
# own Get-DeltaIisDetectionResult identifies as missing from its fixed
# nine-feature table - never a broader install, and never a second,
# independent feature list. Prompts for confirmation first (default No)
# unless nothing is missing at all, in which case nothing is installed and
# no prompt is shown. Detection itself (Get-DeltaIisDetectionResult,
# Get-DeltaIisMissingFeatures's own input) lives in the shared lib now -
# this section only ever installs, never detects.

function Show-DeltaIisDetectionSummary {
    <#
      The dedicated IIS Detection section (docs\todo\TODO-setup-iis-enhancements.md,
      Phase 2's own "Detection Summary" example) - purely a read-only
      report of $Detection (Get-DeltaIisDetectionResult); this function
      itself never queries anything live, so what's displayed is
      guaranteed to be exactly what was detected, not a second, possibly
      inconsistent live re-check. Feature rows are padded to a fixed
      column width so the Installed/Missing column lines up vertically
      regardless of label length, matching the roadmap's own example
      layout.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Detection)

    $labelColumnWidth = (($Detection.Features | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum) + 4

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Microsoft IIS'
    Write-Host ''
    Write-Host 'Status'
    Write-Host ''
    Write-Detail $(if ($Detection.Installed) { 'Installed' } else { 'Not Installed' })
    Write-Host ''
    Write-Host 'Version'
    Write-Host ''
    Write-Detail $(if ($Detection.Version) { $Detection.Version } else { 'Not Installed' })
    Write-Host ''
    Write-Host 'Operating System'
    Write-Host ''
    Write-Detail "Windows $($Detection.OperatingSystemType)"
    if ($Detection.OperatingSystemCaption) {
        Write-Detail $Detection.OperatingSystemCaption
    }
    Write-Host ''
    Write-Host 'Detection Mechanism'
    Write-Host ''
    Write-Detail $Detection.DetectionMechanism
    Write-Host ''
    Write-Host 'Management Module'
    Write-Host ''
    Write-Detail $(if ($Detection.ManagementAssemblyAvailable) { 'Available' } else { 'Missing' })
    Write-Host ''
    Write-Host 'Required Features'
    Write-Host ''
    foreach ($feature in $Detection.Features) {
        $status = if ($feature.Installed) { 'Installed' } else { 'Missing' }
        Write-Detail ("{0,-$labelColumnWidth}{1}" -f $feature.Label, $status)
    }
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
}

# ---------------------------------------------------------------------------
# Microsoft IIS Installation (docs\todo\TODO-setup-iis-enhancements.md, Phase 3)
# ---------------------------------------------------------------------------
#
# Installs ONLY the specific role services/features Phase 2's own detection
# (Get-DeltaIisDetectionResult) identified as missing from its fixed
# nine-feature table - never a broader "install everything IIS might ever
# need" pass, and never a second, independent feature list of its own.
# Nothing here touches ARR/URL Rewrite, websites, app pools, bindings, or
# certificates - those are later phases (4 onward), explicitly out of scope
# here.

function Get-DeltaIisMissingFeatures {
    <#
      The subset of $Detection.Features (Get-DeltaIisDetectionResult) not
      currently installed - the exact list both the installation
      confirmation prompt and Install-DeltaIisFeatures itself act on, and
      the same shape Confirm-DeltaIisPostInstallState re-checks against a
      freshly re-run detection afterward.

      The leading comma on the return is deliberate, not decorative - see
      Get-DeltaNginxManagedProcesses in setup-nginx.ps1 for the full
      explanation: PowerShell unwraps a 0- or 1-element array crossing a
      `return` boundary back into $null/a bare scalar regardless of the
      @() wrapper, and every caller here depends on a real array back
      (a zero-length "nothing missing" result must stay a genuine empty
      array, never $null, or a caller's own ".Count" throws under
      Set-StrictMode).
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Detection)

    return ,@($Detection.Features | Where-Object { -not $_.Installed })
}

function Read-DeltaIisInstallConfirmation {
    <#
      Installation Confirmation (Phase 3, section 1) - the gate before
      Install-DeltaIisFeatures ever runs. Reuses the shared
      Read-DeltaYesNoConfirmation frame (lib\DeltaInstaller.Common.ps1) -
      the same rule/body/prompt/rule shape and "[y/N]" bare-Enter-means-No
      default setup-nginx.ps1's own Read-DeltaNginxInstallConfirmation
      already uses - rather than introducing a second, IIS-specific Y/N
      prompt implementation, per this phase's own explicit requirement.
    #>
    param([Parameter(Mandatory)][array]$MissingFeatures)

    return Read-DeltaYesNoConfirmation -Body {
        Write-Host 'Microsoft IIS components are missing.'
        Write-Host ''
        Write-Host 'The following features will be installed:'
        Write-Host ''
        foreach ($feature in $MissingFeatures) {
            Write-Detail $feature.Label
        }
        Write-Host ''
        Write-Host 'Continue with IIS installation?'
    }
}

function Show-DeltaIisInstallCancelledNotice {
    <#
      The entire response to Read-DeltaIisInstallConfirmation returning
      $false - mirrors Show-DeltaNginxInstallCancelledNotice's own
      philosophy of spelling out that nothing was touched. Always
      accurate here: reached before Install-DeltaIisFeatures ever runs,
      so no Windows Feature/optional feature has been installed or
      enabled and nothing on the machine has changed.
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

function Install-DeltaIisFeatures {
    <#
      Phase 3, sections 2-5. Installs exactly $MissingFeatures - never
      "every feature in the table" - using the correct platform API:
      Install-WindowsFeature (-IncludeManagementTools, so any management
      sub-tool a specified role service itself depends on comes along
      too) on Server, Enable-WindowsOptionalFeature -Online (-All, so any
      parent feature a specified leaf optional feature depends on is
      pulled in too; -NoRestart, so Windows never reboots on its own
      regardless of what either API decides is needed) on Client. Never
      calls ServerManager cmdlets on a Client OS or vice versa - the
      caller's own $OperatingSystemType (Get-DeltaIisOperatingSystemInfo,
      Phase 2) decides the branch, exactly as detection already did.

      Administrative Privileges (section 4): checked here, before either
      installation cmdlet is ever invoked - Stop-Setup refuses outright
      rather than attempting a partial install if elevation is missing,
      so this function never installs some features and then fails
      partway through for a reason that was already knowable up front.

      Returns a [PSCustomObject] with RestartNeeded - both APIs' own
      restart signal (Install-WindowsFeature's $result.RestartNeeded,
      Enable-WindowsOptionalFeature's $result.RestartNeeded despite
      -NoRestart suppressing the automatic reboot itself) - which the
      orchestration block uses to decide whether it is safe to continue
      into Post-Installation Verification at all (section 5: "do not
      continue into future IIS phases" while a restart is still owed).
      Deliberately does NOT treat the installation cmdlet's own result as
      proof of success beyond a hard failure (a non-zero/unsuccessful
      result, or a thrown exception) - per section 6's own "do not trust
      the feature-installation command result alone", the authoritative
      check is Confirm-DeltaIisPostInstallState re-running detection
      afterward, not this function's return value.
    #>
    param(
        [Parameter(Mandatory)][string]$OperatingSystemType,
        [Parameter(Mandatory)][array]$MissingFeatures
    )

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to install Microsoft IIS features. Re-run this script from an elevated PowerShell session.'
    }

    Write-Step 'Installing Microsoft IIS features...'
    foreach ($feature in $MissingFeatures) {
        Write-Detail $feature.Label
    }

    if ($OperatingSystemType -eq 'Server') {
        $featureNames = @($MissingFeatures | ForEach-Object { $_.ServerFeatureName })

        try {
            $result = Install-WindowsFeature -Name $featureNames -IncludeManagementTools -ErrorAction Stop
        }
        catch {
            Stop-Setup "Failed to install required IIS role services: $($_.Exception.Message)"
        }

        if (-not $result.Success) {
            Stop-Setup "Install-WindowsFeature reported failure (ExitCode: $($result.ExitCode)). No further IIS setup will be attempted."
        }

        Write-Success '    Install-WindowsFeature completed.'
        return [PSCustomObject]@{ RestartNeeded = [bool]$result.RestartNeeded }
    }

    $featureNames = @($MissingFeatures | ForEach-Object { $_.ClientFeatureName })

    try {
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $featureNames -All -NoRestart -ErrorAction Stop
    }
    catch {
        Stop-Setup "Failed to enable required IIS optional features: $($_.Exception.Message)"
    }

    Write-Success '    Enable-WindowsOptionalFeature completed.'
    return [PSCustomObject]@{ RestartNeeded = [bool]($result -and $result.RestartNeeded) }
}

function Show-DeltaIisRestartRequiredNotice {
    <#
      Restart Handling (Phase 3, section 5). Shown ONLY when the
      installation API just reported a restart is needed - per this
      phase's own requirement, the orchestration block exits (0) right
      after this, without ever reaching Confirm-DeltaIisPostInstallState
      or Show-DeltaIisInstallationSummary: querying Microsoft.Web.
      Administration/role service state before the pending restart
      completes could report a false failure (or a false success) for an
      assembly that genuinely does not finish registering until reboot,
      and this phase must never
      claim IIS is fully ready in that state. Windows is never restarted
      automatically here or anywhere else in this script - the
      administrator always does that themselves.
    #>

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Microsoft IIS features were installed successfully.'
    Write-Host ''
    Write-Host 'Windows must be restarted before IIS setup can continue.'
    Write-Host ''
    Write-Host 'Restart the server, then run:'
    Write-Host ''
    Write-Detail '.\setup-iis.ps1'
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
}

function Confirm-DeltaIisPostInstallState {
    <#
      Post-Installation Verification (Phase 3, section 6) - the
      authoritative check, run against a FRESH Get-DeltaIisDetectionResult
      call taken after Install-DeltaIisFeatures returns (the caller's
      responsibility - this function only ever inspects $Detection, it
      never re-detects itself), never against the installation cmdlet's
      own reported result. Only ever reached once
      Install-DeltaIisFeatures has already confirmed no restart is
      pending - see Show-DeltaIisRestartRequiredNotice's own header for
      why a restart-pending state skips this entirely.

      Two independent failures, each reported with its own specific
      Stop-Setup message rather than one generic "installation failed":
        - Any required feature still reporting Missing - listed by name,
          per this phase's own "list the features still missing"
          requirement, never summarized as a single count.
        - Microsoft.Web.Administration still unable to load even though
          every required feature (including the two that ship IIS's own
          management assemblies, Web-Scripting-Tools/
          IIS-ManagementScriptingTools) now reports Installed - a real,
          observed Windows behavior where the assembly does not always
          finish registering until a reboot even when neither
          installation API flagged one as required.
          Test-DeltaIisManagementAssemblyAvailable (lib\DeltaDoctor.IIS.ps1)
          is the same check Get-DeltaIisDetectionResult itself already
          used to populate $Detection.ManagementAssemblyAvailable.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Detection)

    $stillMissing = Get-DeltaIisMissingFeatures -Detection $Detection
    if ($stillMissing.Count -gt 0) {
        $missingList = ($stillMissing | ForEach-Object { "    $($_.Label)" }) -join [Environment]::NewLine
        Stop-Setup @"
Microsoft IIS feature installation did not complete successfully.

The following required features still report Missing:

$missingList

No further IIS setup will be attempted. Review any errors above and re-run this script.
"@
    }

    if (-not $Detection.ManagementAssemblyAvailable) {
        Stop-Setup @'
Every required Microsoft IIS role service/feature now reports Installed, but Microsoft.Web.Administration could not be loaded.

If Windows reported that a restart was required, restart the server and re-run this script - the management assemblies can fail to register until after reboot even when the role service itself already shows Installed.

If no restart was reported, verify the Web-Scripting-Tools (Server) / IIS-ManagementScriptingTools (Client) role service manually before proceeding to a later phase.
'@
    }
}

function Show-DeltaIisInstallationSummary {
    <#
      Installation Summary (Phase 3, section 7) - deliberately a
      DIFFERENT function from Phase 2's own Show-DeltaIisDetectionSummary,
      not a re-skin of it, since this one reports on an install this run
      either performed or found unnecessary, not merely on point-in-time
      detection. $AlreadyInstalled is the one thing that changes the
      Status line's wording ("Already Installed" vs "Installed") - per
      this phase's own explicit requirement not to "pretend the script
      installed them again" when nothing was actually missing to begin
      with. Restart Required always reports "No" here: a restart-pending
      result is reported by Show-DeltaIisRestartRequiredNotice instead,
      which exits before this function is ever reached (see that
      function's own header) - the parameter still exists so this
      function's own output stays self-documenting rather than silently
      hardcoding an assumption a future caller could violate unnoticed.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Detection,
        [Parameter(Mandatory)][bool]$AlreadyInstalled,
        [Parameter(Mandatory)][bool]$RestartNeeded
    )

    $labelColumnWidth = (($Detection.Features | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum) + 4

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Microsoft IIS Installation'
    Write-Host ''
    Write-Host 'Operating System'
    Write-Host ''
    Write-Detail "Windows $($Detection.OperatingSystemType)"
    Write-Host ''
    Write-Host 'Status'
    Write-Host ''
    Write-Detail $(if ($AlreadyInstalled) { 'Already Installed' } else { 'Installed' })
    Write-Host ''
    Write-Host 'IIS Version'
    Write-Host ''
    Write-Detail $(if ($Detection.Version) { $Detection.Version } else { 'Not Installed' })
    Write-Host ''
    Write-Host 'Required Features'
    Write-Host ''
    foreach ($feature in $Detection.Features) {
        $status = if ($feature.Installed) { 'Installed' } else { 'Missing' }
        Write-Detail ("{0,-$labelColumnWidth}{1}" -f $feature.Label, $status)
    }
    Write-Host ''
    Write-Host 'Management Module'
    Write-Host ''
    Write-Detail $(if ($Detection.ManagementAssemblyAvailable) { 'Microsoft.Web.Administration available' } else { 'Microsoft.Web.Administration unavailable' })
    Write-Host ''
    Write-Host 'Restart Required'
    Write-Host ''
    Write-Detail $(if ($RestartNeeded) { 'Yes' } else { 'No' })
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
}

# ---------------------------------------------------------------------------
# Application Request Routing (docs\todo\TODO-setup-iis-enhancements.md, Phase 4)
# ---------------------------------------------------------------------------
#
# Prepares IIS for reverse-proxy usage: ensures URL Rewrite and Application
# Request Routing (ARR) are installed, then enables the machine-wide
# system.webServer/proxy setting via Microsoft.Web.Administration
# (lib\DeltaDoctor.IIS.ps1's own Get-DeltaIisServerManager/
# Get-DeltaIisApplicationHostConfiguration/Get-DeltaIisConfigurationSection/
# Save-DeltaIisConfiguration) - never the WebAdministration module, which
# this project no longer has any runtime dependency on anywhere. Still
# never creates, modifies, or deletes any IIS website, application pool,
# binding, or certificate - those remain later phases.

function Show-DeltaArrDetectionSummary {
    <#
      A compact detection summary, reusing the existing dash-rule/
      Write-Detail formatting vocabulary rather than introducing a new
      style - mirrors Show-DeltaIisDetectionSummary's own layout
      philosophy (Phase 2) scaled down to this phase's own two components
      plus the machine-wide proxy settings. Each component's own Version
      (Get-DeltaArrDetectionResult) is shown when known, purely
      informational - never part of any Installed/Missing decision.

      Enabled and Preserve Host Header are two separate rows, not one
      merged "reverse proxy configured" line - the same padded-label
      layout Show-DeltaIisDetectionSummary/Show-DeltaIisInstallationSummary
      already use for their own feature tables, reused here rather than
      inventing a new format.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Detection)

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Application Request Routing'
    Write-Host ''
    foreach ($component in $Detection.Components) {
        Write-Host $component.Name
        Write-Host ''
        Write-Detail $(if ($component.Installed) { 'Installed' } else { 'Missing' })
        if ($component.Installed -and $component.Version) {
            Write-Detail "Version: $($component.Version)"
        }
        Write-Host ''
    }
    Write-Host 'Reverse Proxy (system.webServer/proxy)'
    Write-Host ''
    $reverseProxyLabels = @('Enabled', 'Preserve Host Header', 'Forwarded Headers Allowed')
    $reverseProxyLabelWidth = (($reverseProxyLabels | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum) + 4
    Write-Detail ("{0,-$reverseProxyLabelWidth}{1}" -f 'Enabled', $(if ($Detection.ProxyEnabled) { 'Yes' } else { 'No' }))
    Write-Detail ("{0,-$reverseProxyLabelWidth}{1}" -f 'Preserve Host Header', $(if ($Detection.PreserveHostHeaderEnabled) { 'Yes' } else { 'No' }))
    Write-Detail ("{0,-$reverseProxyLabelWidth}{1}" -f 'Forwarded Headers Allowed', $(if ($Detection.ForwardedServerVariablesAllowed) { 'Yes' } else { 'No' }))
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
}

function Get-DeltaArrMissingComponents {
    <#
      The subset of $Detection.Components not currently installed - see
      Get-DeltaIisMissingFeatures's own header (Phase 3) for why the
      leading comma on the return is required, not decorative: the same
      0-/1-element array unwrapping gotcha applies here identically.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Detection)

    return ,@($Detection.Components | Where-Object { -not $_.Installed })
}

function Read-DeltaArrInstallConfirmation {
    <#
      Reuses the shared Read-DeltaYesNoConfirmation frame
      (lib\DeltaInstaller.Common.ps1) - the same rule/body/prompt/rule
      shape and bare-Enter-means-No default every other confirmation in
      this script already uses, rather than a second Y/N implementation.
      Lists every kind of pending change explicitly (missing components
      to install, and/or any of the three machine-wide proxy settings to
      enable) - any combination, or - if nothing is missing at all - none,
      can be true when this is called. $MissingComponents can legitimately
      be a genuinely empty array (only a proxy setting needs enabling) -
      [AllowEmptyCollection()] is required here: confirmed directly that
      [Parameter(Mandatory)] alone rejects an empty array with "Cannot
      bind argument... because it is an empty collection" even though an
      empty array is not $null.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$MissingComponents,
        [Parameter(Mandatory)][bool]$ProxyNeedsEnabling,
        [Parameter(Mandatory)][bool]$PreserveHostHeaderNeedsEnabling,
        [Parameter(Mandatory)][bool]$ForwardedServerVariablesNeedAllowing
    )

    return Read-DeltaYesNoConfirmation -Body {
        Write-Host 'Microsoft IIS reverse-proxy prerequisites are incomplete.'
        Write-Host ''
        if ($MissingComponents.Count -gt 0) {
            Write-Host 'The following components will be installed:'
            Write-Host ''
            foreach ($component in $MissingComponents) {
                Write-Detail $component.Name
            }
            Write-Host ''
        }
        if ($ProxyNeedsEnabling -or $PreserveHostHeaderNeedsEnabling -or $ForwardedServerVariablesNeedAllowing) {
            Write-Host 'The following configuration change(s) will be made:'
            Write-Host ''
            if ($ProxyNeedsEnabling) {
                Write-Detail 'Enable system.webServer/proxy (machine-wide)'
            }
            if ($PreserveHostHeaderNeedsEnabling) {
                Write-Detail 'Enable system.webServer/proxy preserveHostHeader (machine-wide)'
            }
            if ($ForwardedServerVariablesNeedAllowing) {
                Write-Detail 'Permit X-Forwarded-Proto/Host/Port server variables (machine-wide)'
            }
            Write-Host ''
        }
        Write-Host 'Continue with IIS reverse-proxy setup?'
    }
}

function Get-DeltaArrComponentPackage {
    <#
      Returns the path to $Definition's MSI package - an operator-supplied
      local file under .\installers takes precedence over a fresh
      download, exactly mirroring Get-NginxPackage's own "exact filename
      match preferred over a wildcard, local cache preferred over a
      redownload" behavior (setup-nginx.ps1) rather than a third,
      ARR/URL-Rewrite-specific copy of that logic.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Definition)

    $packagePath = Join-Path -Path $Script:InstallersDirectory -ChildPath $Definition.PackageFileName

    if (Test-Path -LiteralPath $packagePath) {
        Write-Step "Using local $($Definition.Name) package..."
        Write-Detail "Package: $packagePath"
        return $packagePath
    }

    if (-not (Test-Path -Path $Script:InstallersDirectory)) {
        New-Item -Path $Script:InstallersDirectory -ItemType Directory -Force | Out-Null
    }

    Write-Step "Downloading $($Definition.Name)..."
    Write-Detail "Source: $($Definition.DownloadUrl)"
    Write-Detail "Target: $packagePath"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Definition.DownloadUrl -OutFile $packagePath -UseBasicParsing
    }
    catch {
        Stop-Setup "Failed to download $($Definition.Name) from $($Definition.DownloadUrl): $($_.Exception.Message)"
    }

    if (-not (Test-Path -Path $packagePath) -or (Get-Item -Path $packagePath).Length -eq 0) {
        Stop-Setup "Download reported success but the package file is missing or empty: $packagePath"
    }

    Write-Success '    Download complete.'
    return $packagePath
}

function Install-DeltaArrComponent {
    <#
      Runs $Definition's MSI silently via msiexec, reusing the shared
      Start-ProcessWithActivityIndicator (lib\DeltaInstaller.Common.ps1) -
      the same activity-indicator/ExitCode-reliability wrapper setup.ps1's
      own Install-NodeMsi already uses - rather than a bare Start-Process
      call. Exit code 0 = success; 3010 = success, but Windows reports a
      restart is required - unlike Install-NodeMsi's own "3010 is merely
      recommended, not required to continue" stance for Node.js, THIS
      phase's own requirement is stricter: a restart-required result here
      must stop the script cleanly before Phase 5, since
      system.webServer/proxy cannot reliably be configured until after
      that reboot completes (see this phase's own "A restart may be
      required after ARR installation specifically" research finding).
      Any other exit code is an unconditional failure.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Definition)

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to install Microsoft IIS reverse-proxy components. Re-run this script from an elevated PowerShell session.'
    }

    if (-not (Test-Path -Path $Script:WorkingDirectory)) {
        New-Item -Path $Script:WorkingDirectory -ItemType Directory -Force | Out-Null
    }

    $packagePath = Get-DeltaArrComponentPackage -Definition $Definition
    $logPath = Join-Path -Path $Script:WorkingDirectory -ChildPath $Definition.LogFileName

    Write-Step "Installing $($Definition.Name) (silent MSI install)..."
    Write-Detail "Log: $logPath"

    $argumentString = "/i `"$packagePath`" /qn /norestart /log `"$logPath`""
    $process = Start-ProcessWithActivityIndicator -FilePath 'msiexec.exe' -ArgumentList $argumentString -ActivityName "Installing $($Definition.Name)"

    switch ($process.ExitCode) {
        0 {
            Write-Success "    $($Definition.Name) installed successfully."
            return [PSCustomObject]@{ RestartNeeded = $false }
        }
        3010 {
            Write-Success "    $($Definition.Name) installed successfully."
            return [PSCustomObject]@{ RestartNeeded = $true }
        }
        default {
            Stop-Setup "The $($Definition.Name) installer returned exit code $($process.ExitCode). See the log for details: $logPath"
        }
    }
}

function Restart-DeltaIisForArrConfiguration {
    <#
      Restarts IIS (`iisreset.exe /noforce`) - only ever called by
      Confirm-DeltaArrPostInstallState, and only once it has already
      determined at least one of the three machine-wide settings
      (`enabled`/`preserveHostHeader`/the allowedServerVariables
      allow-list) actually needed to change this run. Never called on an
      idempotent rerun where all three already read back correctly - see
      this project's own "maintain idempotent installation steps" rule
      (CLAUDE.md); a machine that's already fully configured must never
      pay for a restart (and its brief availability blip) on every rerun.

      Required because system.webServer/proxy and
      system.webServer/rewrite/allowedServerVariables are both
      MACHINE-WIDE applicationHost.config settings, not scoped to any
      single application pool - confirmed directly (real IIS testing)
      that IIS's normal per-app-pool configuration-change recycling does
      not reliably pick up a change to these properties, unlike a
      site/app-pool-scoped setting would. `/noforce` (graceful - waits
      for in-flight requests to drain) rather than a narrower
      Stop-Service/Start-Service on W3SVC alone: a full iisreset is the
      one restart actually confirmed, via real testing, to make the
      change take effect - a narrower service restart was not verified
      and would be an unproven assumption to bake into an unattended
      installer.

      Uses the shared Start-ProcessWithActivityIndicator
      (lib\DeltaInstaller.Common.ps1) - the same activity-indicator/
      ExitCode-reliability wrapper this phase's own Install-DeltaArrComponent
      already uses for msiexec - rather than a bare Start-Process call.
    #>

    Write-Step 'Restarting IIS to apply the reverse-proxy configuration change...'
    $process = Start-ProcessWithActivityIndicator -FilePath 'iisreset.exe' -ArgumentList '/noforce' -ActivityName 'Restarting IIS'

    if ($process.ExitCode -ne 0) {
        Stop-Setup "iisreset.exe /noforce returned exit code $($process.ExitCode). No further IIS setup will be attempted."
    }

    Write-Success '    IIS restarted.'
}

function Confirm-DeltaArrPostInstallState {
    <#
      Post-installation verification - never trusts msiexec's own exit
      code alone as proof anything actually works, the same "do not trust
      the feature-installation command result alone" discipline Phase 3's
      own Confirm-DeltaIisPostInstallState already holds. Re-checks a
      FRESH Get-DeltaArrDetectionResult (the caller's responsibility to
      have taken after installation) rather than re-deriving state itself.

      `enabled`, `preserveHostHeader`, and the allowedServerVariables
      allow-list are evaluated INDEPENDENTLY, not via a single "is the
      proxy already configured" early return - a machine with
      `enabled=True` but `preserveHostHeader=False` (a real, confirmed
      cause of a DELTA login failure) must not be treated as already
      configured just because `enabled` already reads True, and the same
      goes for a machine missing only one of the three required
      allowedServerVariables entries. Only what actually reads wrong is
      set this run ($propertiesToSet/$missingServerVariableNames), and
      Restart-DeltaIisForArrConfiguration (above) is skipped entirely
      when nothing needed changing - never run unconditionally.

      Two independent, separately-worded failures:
        - Any required component still reporting Missing - listed by
          name, never summarized as a count.
        - `enabled`/`preserveHostHeader`/the allow-list still reporting
          incorrect after this function itself just attempted to set
          them AND restarted IIS - stopped rather than silently retried,
          per this phase's own "do not continue if ARR installation or
          verification fails" requirement. This re-check is a FRESH
          Get-DeltaArrDetectionResult taken after the restart, never a
          re-read of $Detection or a bare trust in
          Save-DeltaIisConfiguration's own lack of a thrown error.

      Writes go through Microsoft.Web.Administration
      (Get-DeltaIisServerManager/Get-DeltaIisApplicationHostConfiguration/
      Get-DeltaIisConfigurationSection/Save-DeltaIisConfiguration,
      lib\DeltaDoctor.IIS.ps1), never the WebAdministration module's own
      Set-WebConfigurationProperty/Add-WebConfigurationProperty - see that
      file's own "Microsoft.Web.Administration configuration backend"
      section header for why.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Detection)

    $stillMissing = Get-DeltaArrMissingComponents -Detection $Detection
    if ($stillMissing.Count -gt 0) {
        $missingList = ($stillMissing | ForEach-Object { "    $($_.Name)" }) -join [Environment]::NewLine
        Stop-Setup @"
Microsoft IIS reverse-proxy component installation did not complete successfully.

The following required components still report Missing:

$missingList

No further IIS setup will be attempted. Review any errors above and re-run this script.
"@
    }

    $propertiesToSet = [System.Collections.Generic.List[string]]::new()
    if (-not $Detection.ProxyEnabled) { $propertiesToSet.Add('enabled') }
    if (-not $Detection.PreserveHostHeaderEnabled) { $propertiesToSet.Add('preserveHostHeader') }

    # Only the specific names still missing from the machine-wide
    # allowedServerVariables collection - never re-adds a name already
    # present. Duplicates are avoided by construction (only names
    # Get-DeltaIisAllowedServerVariableNames doesn't already report ever
    # reach the collection.Add() call below), not by relying on
    # Microsoft.Web.Administration itself to reject a duplicate add.
    $missingServerVariableNames = @()
    if (-not $Detection.ForwardedServerVariablesAllowed) {
        $configuredNames = Get-DeltaIisAllowedServerVariableNames
        $missingServerVariableNames = @($Script:DeltaIisRequiredForwardedServerVariables | Where-Object { $configuredNames -notcontains $_ })
    }

    if ($propertiesToSet.Count -eq 0 -and $missingServerVariableNames.Count -eq 0) {
        return
    }

    if (-not (Test-DeltaIisManagementAssemblyAvailable)) {
        Stop-Setup 'Microsoft.Web.Administration is unavailable, so system.webServer/proxy cannot be configured. Re-run Phase 3 (Microsoft IIS Installation) first.'
    }

    Write-Step 'Configuring the IIS reverse proxy (system.webServer/proxy)...'

    $changedProperties = [System.Collections.Generic.List[string]]::new()
    $changedProperties.AddRange([string[]]$propertiesToSet)
    foreach ($name in $missingServerVariableNames) {
        $changedProperties.Add("allowedServerVariables:$name")
    }
    $propertyDescription = $changedProperties -join ', '

    try {
        $serverManager = Get-DeltaIisServerManager
        $configuration = Get-DeltaIisApplicationHostConfiguration -ServerManager $serverManager

        if ($propertiesToSet.Count -gt 0) {
            $proxySection = Get-DeltaIisConfigurationSection -Configuration $configuration -SectionPath 'system.webServer/proxy'

            if ($propertiesToSet.Contains('enabled')) {
                $proxySection.SetAttributeValue('enabled', $true)
                Write-Detail 'enabled -> True'
            }
            if ($propertiesToSet.Contains('preserveHostHeader')) {
                $proxySection.SetAttributeValue('preserveHostHeader', $true)
                Write-Detail 'preserveHostHeader -> True'
            }
        }

        if ($missingServerVariableNames.Count -gt 0) {
            # allowedServerVariables, not templates\iis\web.config's own
            # site-level rewrite rule - confirmed directly (real IIS
            # testing) that this section is locked (overrideModeDefault=
            # "Deny") at the server level by default, so a site-level
            # declaration fails EVERY request with HTTP 500.52 instead of
            # merely omitting the header. See
            # Test-DeltaIisForwardedServerVariablesAllowed's own header.
            $allowedServerVariablesSection = Get-DeltaIisConfigurationSection -Configuration $configuration -SectionPath 'system.webServer/rewrite/allowedServerVariables'
            $allowedServerVariablesCollection = $allowedServerVariablesSection.GetCollection()
            foreach ($name in $missingServerVariableNames) {
                $addElement = $allowedServerVariablesCollection.CreateElement('add')
                $addElement.SetAttributeValue('name', $name)
                $allowedServerVariablesCollection.Add($addElement) | Out-Null
                Write-Detail "allowedServerVariables += $name"
            }
        }

        Save-DeltaIisConfiguration -ServerManager $serverManager -SectionName 'system.webServer/proxy, system.webServer/rewrite/allowedServerVariables' -PropertyDescription $propertyDescription
    }
    catch {
        Stop-Setup "Failed to configure system.webServer/proxy: $($_.Exception.Message)"
    }

    Restart-DeltaIisForArrConfiguration

    $postRestartDetection = Get-DeltaArrDetectionResult
    if (-not $postRestartDetection.ProxyEnabled -or -not $postRestartDetection.PreserveHostHeaderEnabled -or -not $postRestartDetection.ForwardedServerVariablesAllowed) {
        Stop-Setup 'system.webServer/proxy was configured, but a fresh check after restarting IIS still reports it as incomplete. No further IIS setup will be attempted.'
    }

    Write-Success '    Reverse proxy configured.'
}

function Invoke-DeltaArrSetup {
    <#
      The Phase 4 top-level orchestrator - detect, confirm, install,
      re-verify, enable/verify proxy - returning a [PSCustomObject] with
      Ready (bool) rather than exiting itself, so the caller (the
      orchestration block) decides the actual exit code/timing. Ready is
      $false in exactly two cases, each having already shown its own
      notice before returning: the administrator declined
      (Show-DeltaIisInstallCancelledNotice - reused verbatim from Phase 3,
      its wording is completely generic) or a restart is required
      (Show-DeltaIisRestartRequiredNotice - also reused verbatim, its own
      wording already covers "Microsoft IIS features were installed").
      Phase 5 must never run when Ready is $false - see this phase's own
      "do not continue if ARR installation or verification fails" and "do
      not continue into Phase 5" requirements.
    #>

    $detection = Get-DeltaArrDetectionResult
    Show-DeltaArrDetectionSummary -Detection $detection

    $missingComponents = Get-DeltaArrMissingComponents -Detection $detection
    $proxyNeedsEnabling = -not $detection.ProxyEnabled
    $preserveHostHeaderNeedsEnabling = -not $detection.PreserveHostHeaderEnabled
    $forwardedServerVariablesNeedAllowing = -not $detection.ForwardedServerVariablesAllowed

    if ($missingComponents.Count -eq 0 -and -not $proxyNeedsEnabling -and -not $preserveHostHeaderNeedsEnabling -and -not $forwardedServerVariablesNeedAllowing) {
        Write-Host ''
        Write-Detail 'Microsoft IIS reverse-proxy prerequisites are already fully configured.'
        return [PSCustomObject]@{ Ready = $true }
    }

    if (-not (Read-DeltaArrInstallConfirmation -MissingComponents $missingComponents -ProxyNeedsEnabling $proxyNeedsEnabling -PreserveHostHeaderNeedsEnabling $preserveHostHeaderNeedsEnabling -ForwardedServerVariablesNeedAllowing $forwardedServerVariablesNeedAllowing)) {
        Show-DeltaIisInstallCancelledNotice
        return [PSCustomObject]@{ Ready = $false }
    }

    $restartNeeded = $false
    foreach ($component in $missingComponents) {
        $definition = Get-DeltaArrRequiredComponents | Where-Object { $_.Name -eq $component.Name } | Select-Object -First 1
        $installResult = Install-DeltaArrComponent -Definition $definition
        if ($installResult.RestartNeeded) {
            $restartNeeded = $true
        }
    }

    if ($restartNeeded) {
        Show-DeltaIisRestartRequiredNotice
        return [PSCustomObject]@{ Ready = $false }
    }

    $postInstallDetection = Get-DeltaArrDetectionResult
    Confirm-DeltaArrPostInstallState -Detection $postInstallDetection

    return [PSCustomObject]@{ Ready = $true }
}

# ---------------------------------------------------------------------------
# Windows SSL Certificate (docs\todo\TODO-setup-iis-enhancements.md, Phase 7)
# ---------------------------------------------------------------------------
#
# Configures HTTPS for the managed DELTA IIS website using the Windows
# Certificate Store - unlike setup-nginx.ps1, IIS never references
# certificate files directly. Certificates are imported into
# Cert:\LocalMachine\My and HTTPS bindings reference the imported
# certificate by THUMBPRINT only - never searched for afterward by
# friendly name. Combines what the roadmap originally split into two
# phases (SSL Certificate, Existing Certificate Handling) into one, the
# same way setup-nginx.ps1's own Install-DeltaSslCertificate already
# does for NGINX. Does not implement runtime management or port/binding
# conflict validation - those remain later phases.

function Show-DeltaIisOrphanedCertificateBindingNotice {
    <#
      Shown only when an HTTPS binding exists but its own referenced
      thumbprint no longer resolves to a real certificate in the store -
      the IIS analogue of a `Broken` runtime state, per this phase's own
      roadmap text ("closer to setup-nginx.ps1's own Broken state concept
      than to an existing certificate"). Never silently normalized to
      either "no certificate" or "existing certificate" - reported
      plainly, then treated as no certificate configured (the caller
      falls through to the fresh Yes/No wizard immediately afterward).
    #>
    param([Parameter(Mandatory)]$ExistingState)

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'An HTTPS binding already exists for this website, but its certificate'
    Write-Host 'is no longer present in the certificate store.'
    Write-Host ''
    Write-Host 'Binding'
    Write-Host ''
    Write-Detail $ExistingState.Binding.bindingInformation
    Write-Host ''
    Write-Host 'Referenced Thumbprint'
    Write-Host ''
    Write-Detail $(if ($ExistingState.Thumbprint) { $ExistingState.Thumbprint } else { 'None' })
    Write-Host ''
    Write-Host 'This will be treated as no certificate configured.'
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
}

function Read-DeltaIisSslCertificateChoice {
    <#
      The Certificate Wizard's own opening question, mirroring
      setup-nginx.ps1's own Read-SslCertificateChoice shape exactly
      (numbered choice, bare-Enter-picks-a-default) with this phase's own
      required wording. Defaults to "No" on a bare Enter - an
      administrator who presses Enter without reading closely should land
      on the option that imports nothing.
    #>

    Write-Host ''
    Write-Host 'Do you already have an SSL certificate (.pfx)?'
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

function Read-DeltaIisExistingCertificateChoice {
    <#
      Existing Certificate (this phase's own section) - the three actions
      available once Get-DeltaIisExistingHttpsCertificateState has already
      confirmed a certificate is genuinely associated with the managed
      website's HTTPS binding. No bare-Enter default (unlike
      Read-DeltaIisSslCertificateChoice's "[2]") - mirrors setup-nginx.ps1's
      own Read-ExistingSslCertificateChoice: a decision this consequential
      (silently keeping vs. silently discarding a possibly-production
      certificate) is never made by a stray Enter keypress.
    #>
    param([Parameter(Mandatory)]$ExistingState)

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'An SSL certificate is already configured for this website.'
    Write-Host ''
    Write-Host 'Thumbprint'
    Write-Host ''
    Write-Detail $ExistingState.Thumbprint
    Write-Host ''
    Write-Host 'Choose an option:'
    Write-Host ''
    Write-Host '1) Replace existing certificate'
    Write-Host '2) Keep existing certificate'
    Write-Host '3) Cancel'
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

function Select-DeltaIisPfxFile {
    <#
      Selects and validates a .pfx file via the shared Select-DeltaSslFile
      (lib\DeltaInstaller.Common.ps1, promoted from setup-nginx.ps1 for
      this exact reuse) - the standard Windows file selection dialog,
      never a manually-typed path. Stop-Setup on cancellation, a missing
      file, or any extension other than .pfx - per this phase's own
      explicit "Supported format: .pfx only. Reject every other format."
      requirement.
    #>

    $pfxPath = Select-DeltaSslFile -Title 'Select the SSL certificate file (.pfx)' -Filter 'PFX Files (*.pfx)|*.pfx|All Files (*.*)|*.*'

    if (-not $pfxPath) {
        Stop-Setup 'SSL certificate setup was canceled - a .pfx file must be selected.'
    }
    if (-not (Test-Path -LiteralPath $pfxPath)) {
        Stop-Setup "The selected certificate file does not exist: $pfxPath"
    }
    if (-not (Test-DeltaSslFileExtension -Path $pfxPath -AllowedExtensions @('.pfx'))) {
        Stop-Setup "Unsupported SSL certificate file extension ($([System.IO.Path]::GetExtension($pfxPath))). Only .pfx files are supported."
    }

    return $pfxPath
}

function Read-DeltaIisCertificateSupplyMethod {
    <#
      The Certificate Wizard's own second question - only ever reached
      after Read-DeltaIisSslCertificateChoice's "Yes" (or an existing
      certificate's own "Replace" choice), deciding HOW the certificate
      will be supplied. Defaults to "2) Certificate + Private Key" on a
      bare Enter - per this enhancement's own explicit reasoning: this
      matches the workflow `setup-nginx.ps1` has always used (a .crt/.key
      pair, never a .pfx), so the administrator coming from that
      installer's own conventions lands on the familiar path by default.
      Deliberately a SECOND question, not a replacement for
      Read-DeltaIisSslCertificateChoice - the original "do you want to
      configure HTTPS at all" Yes/No gate (and its "No" -> HTTP-only
      outcome) is completely unchanged; this only decides how, once the
      answer to "at all" is already yes.
    #>

    Write-Host ''
    Write-Host 'How would you like to provide your certificate?'
    Write-Host ''
    Write-Host '1) PKCS#12 (.pfx)'
    Write-Host ''
    Write-Host '2) Certificate + Private Key'
    Write-Host ''

    while ($true) {
        $choice = Read-Host -Prompt 'Choose an option [2]'
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '2' }

        switch ($choice.Trim()) {
            '1' { return 'Pfx' }
            '2' { return 'CrtKey' }
        }
        Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow
    }
}

function Select-DeltaIisCertificateFile {
    <#
      Certificate + Private Key (this enhancement's own section) - the
      certificate half of the pair. Reuses the shared Select-DeltaSslFile
      file picker exactly like Select-DeltaIisPfxFile already does for
      the .pfx path, restricted to .crt/.cer/.pem per this enhancement's
      own "Supported: .crt .cer .pem" requirement.
    #>

    $certPath = Select-DeltaSslFile -Title 'Select the SSL certificate file (.crt/.cer/.pem)' -Filter 'Certificate Files (*.crt;*.cer;*.pem)|*.crt;*.cer;*.pem|All Files (*.*)|*.*'

    if (-not $certPath) {
        Stop-Setup 'SSL certificate setup was canceled - a certificate file must be selected.'
    }
    if (-not (Test-Path -LiteralPath $certPath)) {
        Stop-Setup "The selected certificate file does not exist: $certPath"
    }
    if (-not (Test-DeltaSslFileExtension -Path $certPath -AllowedExtensions @('.crt', '.cer', '.pem'))) {
        Stop-Setup "Unsupported certificate file extension ($([System.IO.Path]::GetExtension($certPath))). Supported extensions: .crt, .cer, .pem."
    }

    return $certPath
}

function Select-DeltaIisPrivateKeyFile {
    <#
      Certificate + Private Key (this enhancement's own section) - the
      private key half of the pair. Restricted to .key/.pem per this
      enhancement's own "Supported: .key .pem" requirement.
    #>

    $keyPath = Select-DeltaSslFile -Title 'Select the private key file (.key/.pem)' -Filter 'Private Key Files (*.key;*.pem)|*.key;*.pem|All Files (*.*)|*.*'

    if (-not $keyPath) {
        Stop-Setup 'SSL certificate setup was canceled - a private key file must be selected.'
    }
    if (-not (Test-Path -LiteralPath $keyPath)) {
        Stop-Setup "The selected private key file does not exist: $keyPath"
    }
    if (-not (Test-DeltaSslFileExtension -Path $keyPath -AllowedExtensions @('.key', '.pem'))) {
        Stop-Setup "Unsupported private key file extension ($([System.IO.Path]::GetExtension($keyPath))). Supported extensions: .key, .pem."
    }

    return $keyPath
}

function New-DeltaIisTemporaryPfxFromCertificateAndKey {
    <#
      Certificate + Private Key (this enhancement's own section) -
      selects the certificate and private key files, prompts for the
      key's own passphrase ONLY if Test-DeltaPrivateKeyEncrypted
      (lib\DeltaInstaller.Common.ps1) reports the key is actually
      encrypted - per this enhancement's own explicit "If the key is not
      encrypted: Do not prompt" requirement - then converts the pair into
      a temporary PKCS#12 via the shared
      ConvertTo-DeltaPfxFromCertificateAndKey. No conversion logic lives
      here or anywhere else in setup-iis.ps1 - this function only
      orchestrates (prompts, picks files, hands the paths to the shared
      helper), per this enhancement's own "the IIS installer should
      orchestrate the workflow rather than own the certificate
      conversion logic" requirement.

      The temporary file gets a cryptographically random filename
      ([System.IO.Path]::GetRandomFileName(), never a predictable name)
      under the system temp directory, and is protected by a
      cryptographically random password (the shared New-DeltaRandomPassword)
      the administrator never sees or is asked for - both exist only to
      satisfy Import-PfxCertificate's own required parameters for a file
      that exists for the few moments between this function returning
      and Import-DeltaIisSslCertificate's own cleanup running immediately
      afterward. This function only ever creates the temporary file; the
      caller (Import-DeltaIisSslCertificate) owns deleting it - except on
      a conversion failure, where cleanup happens right here before
      re-throwing, since the caller's own $temporaryPfxPath tracking
      variable is never set for a file that never successfully finished
      being created.
    #>

    $certPath = Select-DeltaIisCertificateFile
    $keyPath = Select-DeltaIisPrivateKeyFile

    $keyPassphrase = $null
    if (Test-DeltaPrivateKeyEncrypted -Path $keyPath) {
        Write-Host ''
        Write-Host 'Enter the private key passphrase.'
        $keyPassphrase = Read-Host -Prompt 'Private key passphrase' -AsSecureString
    }

    $temporaryFileName = [System.IO.Path]::GetRandomFileName() + '.pfx'
    $temporaryPfxPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath $temporaryFileName
    $securePfxPassword = ConvertTo-SecureString -String (New-DeltaRandomPassword) -Force -AsPlainText

    Write-Step 'Converting the certificate and private key...'
    try {
        ConvertTo-DeltaPfxFromCertificateAndKey -CertificatePath $certPath -PrivateKeyPath $keyPath -KeyPassphrase $keyPassphrase -PfxPassword $securePfxPassword -DestinationPfxPath $temporaryPfxPath
    }
    catch {
        Remove-DeltaTemporaryFileSecurely -Path $temporaryPfxPath
        throw
    }
    Write-Success '    Certificate and private key combined successfully.'

    return [PSCustomObject]@{ Path = $temporaryPfxPath; Password = $securePfxPassword }
}

function Import-DeltaIisSslCertificate {
    <#
      Certificate Import (this phase's own section) - asks HOW the
      certificate will be supplied (Read-DeltaIisCertificateSupplyMethod,
      default "Certificate + Private Key" per this enhancement's own
      requirement), then either selects a .pfx directly (Select-DeltaIisPfxFile
      - completely unchanged from before this enhancement, per its own
      "Preserve the existing implementation exactly" requirement) or
      builds one temporarily from a certificate + private key pair
      (New-DeltaIisTemporaryPfxFromCertificateAndKey). Either way, the
      exact same, unmodified Import-PfxCertificate call below is what
      actually imports it into Cert:\LocalMachine\My - never a
      file-path-based reference the way setup-nginx.ps1 uses for NGINX.
      Returns the imported certificate object; its own .Thumbprint is the
      ONLY source of truth this installer ever consumes afterward, per
      this phase's own explicit "Do not search the certificate store
      afterwards by friendly name" requirement. An incorrect password, or
      any other import failure, stops the installer outright (no retry
      loop) - the same "clear error, stop, let the administrator re-run"
      convention setup-nginx.ps1's own SSL wizard already follows for
      validation failures.

      A temporary PKCS#12 (the Certificate + Private Key path only) is
      always removed via the shared Remove-DeltaTemporaryFileSecurely
      before this function returns OR throws - the `finally` block runs
      either way, per this enhancement's own "remove it even if the
      import fails" / "leave no temporary certificate artifacts behind"
      requirements. The .pfx path never sets $temporaryPfxPath at all, so
      this cleanup is a complete no-op for it - Option 1 genuinely has no
      behavioral change.

      Import-PfxCertificate can, in principle, return more than one
      certificate for a .pfx containing a full chain - confirmed directly
      that a typical single-certificate .pfx returns exactly one object,
      but the leaf/end-entity certificate (the one with an actual private
      key - chain intermediates never carry one) is selected explicitly
      in case a chain-bundling .pfx is ever supplied, rather than
      assuming array position.
    #>

    $supplyMethod = Read-DeltaIisCertificateSupplyMethod

    $temporaryPfxPath = $null
    try {
        if ($supplyMethod -eq 'Pfx') {
            $pfxPath = Select-DeltaIisPfxFile

            Write-Step 'Enter the certificate password.'
            $securePassword = Read-Host -Prompt 'Certificate password' -AsSecureString
        }
        else {
            $conversionResult = New-DeltaIisTemporaryPfxFromCertificateAndKey
            $pfxPath = $conversionResult.Path
            $securePassword = $conversionResult.Password
            $temporaryPfxPath = $pfxPath
        }

        Write-Step 'Importing the SSL certificate...'
        try {
            $importResult = @(Import-PfxCertificate -FilePath $pfxPath -CertStoreLocation Cert:\LocalMachine\My -Password $securePassword -ErrorAction Stop)
        }
        catch {
            Stop-Setup "Failed to import the SSL certificate: $($_.Exception.Message)"
        }

        $importedCert = $importResult | Where-Object { $_.HasPrivateKey } | Select-Object -First 1
        if (-not $importedCert) {
            $importedCert = $importResult | Select-Object -First 1
        }
        if (-not $importedCert -or -not $importedCert.Thumbprint) {
            Stop-Setup 'Certificate import reported success but no usable certificate was returned.'
        }

        Write-Success "    Certificate imported. Thumbprint: $($importedCert.Thumbprint)"
        return $importedCert
    }
    finally {
        if ($temporaryPfxPath) {
            Remove-DeltaTemporaryFileSecurely -Path $temporaryPfxPath
        }
    }
}

function Confirm-DeltaIisHttpsBinding {
    <#
      HTTPS Binding (this phase's own section) - creates or reconciles
      ONLY this installer's own single HTTPS:443 binding (matched by
      protocol and port, never by replacing the site's entire bindings
      collection - the identical discipline Phase 6's own
      Confirm-DeltaIisWebsiteBinding already established for the HTTP
      binding), so any OTHER HTTPS binding an administrator added by hand
      is left completely untouched, per this phase's own "Do not disturb
      unrelated HTTPS bindings" / "Do not remove administrator-created
      bindings" requirements. SNI (sslFlags = 1) is always enabled -
      required for a host-header-based HTTPS binding to coexist with any
      other HTTPS site already on the same IP/port.

      Uses lib\DeltaDoctor.IIS.ps1's own Microsoft.Web.Administration
      site/binding primitives (Get-DeltaIisServerManager/
      Get-DeltaIisSiteByName/Get-DeltaIisSiteBindingByProtocolAndPort/
      Save-DeltaIisConfiguration/Add-DeltaIisCertificateToBinding), never
      WebAdministration - the binding must actually be COMMITTED before
      the certificate can be associated with it, so this creates/updates
      the binding and commits first, then gets a completely FRESH
      ServerManager to re-resolve the binding before calling
      Add-DeltaIisCertificateToBinding - mirroring the original
      WebAdministration-era "re-fetch via Get-WebBinding before
      AddSslCertificate" step exactly, just with a fresh ServerManager
      instead of a fresh cmdlet call.

      The certificate is associated by thumbprint via
      Add-DeltaIisCertificateToBinding (which wraps the binding object's
      own native AddSslCertificate method) - confirmed directly against a
      real IIS binding that calling it again on an already-bound binding
      with a DIFFERENT thumbprint correctly replaces the association in
      place (certificateHash updates, no duplicate binding created), so
      this same call handles both "no certificate yet" and "replace the
      existing certificate" without needing to branch on which case this
      run is in.
    #>
    param([Parameter(Mandatory)][string]$Thumbprint)

    Write-Step 'Configuring the HTTPS binding...'

    $desiredBindingInformation = "*:443:$($Script:DeltaWebsiteDomain)"

    $serverManager = Get-DeltaIisServerManager
    $site = Get-DeltaIisSiteByName -ServerManager $serverManager -Name $Script:DeltaIisSiteName
    $existingHttpsBinding = Get-DeltaIisSiteBindingByProtocolAndPort -Site $site -Protocol 'https' -Port 443

    if (-not $existingHttpsBinding) {
        $newBinding = $site.Bindings.Add($desiredBindingInformation, 'https')
        $newBinding.SetAttributeValue('sslFlags', 1)
        Save-DeltaIisConfiguration -ServerManager $serverManager -SectionName 'Sites' -PropertyDescription "create HTTPS binding for '$($Script:DeltaIisSiteName)'"
        Write-Detail "Binding created: $desiredBindingInformation"
    }
    elseif ($existingHttpsBinding.BindingInformation -ne $desiredBindingInformation) {
        $existingHttpsBinding.BindingInformation = $desiredBindingInformation
        Save-DeltaIisConfiguration -ServerManager $serverManager -SectionName 'Sites' -PropertyDescription "update HTTPS binding for '$($Script:DeltaIisSiteName)'"
        Write-Detail "Binding updated: $($existingHttpsBinding.BindingInformation) -> $desiredBindingInformation"
    }
    else {
        Write-Detail "Binding already correct: $desiredBindingInformation"
    }

    # A brand new ServerManager - never the one used to create/update the
    # binding above - so the certificate is associated against a binding
    # freshly re-read from applicationHost.config, never an in-memory
    # object whose own commit might not have taken effect.
    $verifyServerManager = Get-DeltaIisServerManager
    $verifySite = Get-DeltaIisSiteByName -ServerManager $verifyServerManager -Name $Script:DeltaIisSiteName
    $binding = Get-DeltaIisSiteBindingByProtocolAndPort -Site $verifySite -Protocol 'https' -Port 443
    if (-not $binding -or $binding.BindingInformation -ne $desiredBindingInformation) {
        Stop-Setup 'Failed to configure the HTTPS binding - the binding could not be found immediately after creation/update.'
    }

    try {
        Add-DeltaIisCertificateToBinding -Binding $binding -Thumbprint $Thumbprint -StoreName 'my'
        Save-DeltaIisConfiguration -ServerManager $verifyServerManager -SectionName 'Sites' -PropertyDescription "associate certificate with HTTPS binding for '$($Script:DeltaIisSiteName)'"
    }
    catch {
        Stop-Setup "Failed to associate the certificate with the HTTPS binding: $($_.Exception.Message)"
    }

    Write-Success '    HTTPS binding configured.'
}

function Confirm-DeltaIisSslConfigurationResult {
    <#
      Verification (this phase's own dedicated section) - never trusts
      Import-PfxCertificate/Confirm-DeltaIisHttpsBinding's own lack of a
      thrown error as proof of anything; re-reads the certificate store
      and IIS from scratch (a brand new ServerManager, never one already
      used elsewhere in this phase) and independently checks every fact
      this phase claims to have configured, collecting every failure at
      once (the same shape Confirm-DeltaIisWebsiteConfigurationResult,
      Phase 6, already established) rather than stopping at the first.
    #>
    param([Parameter(Mandatory)][string]$ExpectedThumbprint)

    Write-Step 'Verifying SSL certificate configuration...'

    $failures = [System.Collections.Generic.List[string]]::new()

    if (-not (Get-Item -LiteralPath "Cert:\LocalMachine\My\$ExpectedThumbprint" -ErrorAction SilentlyContinue)) {
        $failures.Add("No certificate with thumbprint $ExpectedThumbprint exists in Cert:\LocalMachine\My.")
    }

    $serverManager = Get-DeltaIisServerManager
    $site = Get-DeltaIisSiteByName -ServerManager $serverManager -Name $Script:DeltaIisSiteName
    $binding = if ($site) { Get-DeltaIisSiteBindingByProtocolAndPort -Site $site -Protocol 'https' -Port 443 } else { $null }

    if (-not $binding) {
        $failures.Add("No HTTPS binding exists for '$($Script:DeltaWebsiteDomain)' on port 443.")
    }
    else {
        $bindingThumbprint = Get-DeltaIisBindingCertificateThumbprint -Binding $binding
        if ($bindingThumbprint -ne $ExpectedThumbprint) {
            $failures.Add("The HTTPS binding references thumbprint '$bindingThumbprint', expected '$ExpectedThumbprint'.")
        }
        if (-not ([int]$binding.GetAttributeValue('sslFlags') -band 1)) {
            $failures.Add('SNI (Server Name Indication) is not enabled on the HTTPS binding.')
        }

        $hostHeaderPart = ($binding.BindingInformation -split ':')[2]
        if ($hostHeaderPart -ne $Script:DeltaWebsiteDomain) {
            $failures.Add("HTTPS binding host header is '$hostHeaderPart', expected '$($Script:DeltaWebsiteDomain)'.")
        }
    }

    if ($failures.Count -gt 0) {
        $failureList = ($failures | ForEach-Object { "    $_" }) -join [Environment]::NewLine
        Stop-Setup @"
SSL certificate configuration verification failed.

$failureList

No further IIS setup will be attempted. Review the errors above and re-run this script.
"@
    }

    Write-Success '    SSL certificate configuration verified.'
}

function Show-DeltaIisSslSummary {
    <#
      This phase's own "Summary" example, verbatim - "Imported"/"Existing
      certificate retained" distinguished the same way Phase 3/4/6's own
      summaries never claim to have "just installed" something that was
      actually already there, or "Not Configured" when the administrator
      chose HTTP only. Never mentions runtime management or binding-
      conflict validation - those remain later phases.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$SslResult)

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''

    if (-not $SslResult.HttpsConfigured) {
        Write-Host 'HTTPS'
        Write-Host ''
        Write-Detail 'Not Configured'
        Write-Host ''
        Write-Host ('-' * $Script:BannerWidth)
        return
    }

    Write-Host 'SSL Certificate'
    Write-Host ''
    Write-Detail $(if ($SslResult.Source -eq 'Existing') { 'Existing certificate retained' } else { 'Imported' })
    Write-Host ''
    Write-Host 'Certificate Store'
    Write-Host ''
    Write-Detail 'LocalMachine\My'
    Write-Host ''
    Write-Host 'Thumbprint'
    Write-Host ''
    Write-Detail $SslResult.Thumbprint
    Write-Host ''
    Write-Host 'HTTPS'
    Write-Host ''
    Write-Detail 'Enabled'
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
}

function Invoke-DeltaIisSslCertificateSetup {
    <#
      The Phase 7 top-level orchestrator - the Certificate Wizard.
      Checks Get-DeltaIisExistingHttpsCertificateState first: a genuinely
      existing certificate branches into Replace/Keep/Cancel
      (Read-DeltaIisExistingCertificateChoice); an orphaned binding shows
      its own distinct notice and falls through to the fresh wizard;
      nothing at all goes straight to the fresh Yes/No wizard
      (Read-DeltaIisSslCertificateChoice). "No"/"Keep"/"Cancel" all return
      without ever calling Import-DeltaIisSslCertificate - only "Yes" or
      "Replace" reach the import/binding/verification steps. Reuses
      Show-DeltaIisInstallCancelledNotice (Phase 3) verbatim for the
      Cancel case - its wording is already completely generic.
    #>

    if (-not (Test-DeltaIisManagementAssemblyAvailable)) {
        Stop-Setup 'Microsoft.Web.Administration is unavailable, so SSL certificate setup cannot proceed. Re-run Phase 3 (Microsoft IIS Installation) first.'
    }

    Write-PhaseBanner 'SSL Certificate'

    $existingState = Get-DeltaIisExistingHttpsCertificateState

    if ($existingState -and $existingState.CertificateExists) {
        $choice = Read-DeltaIisExistingCertificateChoice -ExistingState $existingState

        if ($choice -eq 'Keep') {
            Write-Host ''
            Write-Success '    Existing SSL certificate retained.'
            return [PSCustomObject]@{ HttpsConfigured = $true; Thumbprint = $existingState.Thumbprint; Source = 'Existing'; Cancelled = $false }
        }
        if ($choice -eq 'Cancel') {
            Show-DeltaIisInstallCancelledNotice
            return [PSCustomObject]@{ HttpsConfigured = $false; Thumbprint = $null; Source = $null; Cancelled = $true }
        }
        # 'Replace' falls through to the import flow below.
    }
    else {
        if ($existingState -and -not $existingState.CertificateExists) {
            Show-DeltaIisOrphanedCertificateBindingNotice -ExistingState $existingState
        }

        $wantsHttps = Read-DeltaIisSslCertificateChoice
        if ($wantsHttps -eq 'No') {
            Write-Host ''
            Write-Detail 'HTTPS has not been configured. The website remains HTTP only.'
            return [PSCustomObject]@{ HttpsConfigured = $false; Thumbprint = $null; Source = $null; Cancelled = $false }
        }
        # 'Yes' falls through to the import flow below.
    }

    $importedCert = Import-DeltaIisSslCertificate
    Confirm-DeltaIisHttpsBinding -Thumbprint $importedCert.Thumbprint
    Confirm-DeltaIisSslConfigurationResult -ExpectedThumbprint $importedCert.Thumbprint

    return [PSCustomObject]@{ HttpsConfigured = $true; Thumbprint = $importedCert.Thumbprint; Source = 'New'; Cancelled = $false }
}

# ---------------------------------------------------------------------------
# Phase 1 summary
# ---------------------------------------------------------------------------

function Show-DeltaIisDiscoverySummary {
    <#
      A minimal, Phase-1-only summary confirming the shared discovery
      layer is functioning - deliberately nothing IIS-specific here yet
      (no version, no site, no binding), since none of that exists until
      later phases. Mirrors the dash-rule/section shape setup-nginx.ps1's
      own Show-DeltaNginxPortsAvailableNotice already uses, rather than
      introducing a new console formatting style.
    #>

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'DELTA Installation'
    Write-Host ''
    Write-Host 'Location'
    Write-Host ''
    Write-Detail $Script:DeltaInstallPath
    Write-Host ''
    Write-Host 'Environment'
    Write-Host ''
    Write-Detail $Script:DeltaEnvPath
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
}

# ---------------------------------------------------------------------------
# Port prerequisite check (Manual Reverse Proxy Handover)
# ---------------------------------------------------------------------------
#
# The IIS-side counterpart to setup-nginx.ps1's own "Port prerequisite
# check" section - see that section's own header for the full design this
# mirrors. Doctor first: an ACTIVE, DELTA-managed provider (NGINX) IS, by
# definition, already bound to whatever ports it needs, so
# Get-DeltaReverseProxyHandoverPlan (lib\DeltaDoctor.ReverseProxy.ps1) is
# asked before any raw TCP probe runs at all - Doctor's own answer to
# "what would actually need to be stopped, and is that even safe" (the
# Reverse Proxy Handover Plan architecture correction), never a hardcoded
# "just stop NGINX" assumption. A genuine conflict there is no longer a
# hard abort - Invoke-DeltaReverseProxyHandover
# (lib\DeltaInstaller.Common.ps1) presents and, on confirmation, executes
# whatever plan Doctor built, exactly mirroring setup-nginx.ps1's own side
# of this feature. The administrator remains fully in control - this is
# NOT automatic migration, and a decline (or an unsafe plan Doctor itself
# refused) is a complete, reported no-op.
#
# Only once that's resolved (or never applied at all) does the raw,
# low-level safety net run - Get-ListeningTcpPortOwner
# (lib\DeltaInstaller.Common.ps1, generic) still supplies the raw
# TCP-listener signal setup-nginx.ps1's own Test-RequiredPortAvailability
# uses, but IIS's own "is this port already mine" question is answered by
# Get-DeltaIisPortBindingOwnership (lib\DeltaDoctor.IIS.ps1) instead, never
# by the raw owner's ServiceName - confirmed directly (real IIS testing)
# that HTTP.sys-owned listeners are always attributed to PID 4 ("System")
# by Windows, which resolves to no Win32_Service entry at all, so a
# ServiceName-based "is this W3SVC" check can never actually match on a
# real machine. IIS's own binding configuration is the only authoritative
# source for "does IIS itself already own this port," regardless of which
# PID/process the OS attributes the underlying kernel-mode listener to.
# This only ever catches a port Doctor genuinely cannot attribute to
# IIS's own bindings or a DELTA-managed provider at all.
#
# Deliberately called ONLY on the fresh-install path (this script's own
# Orchestration section, below) - Invoke-DeltaIisConfigurationCheckup is
# the shared cycle doctor.ps1 ALSO calls, and must never gain this
# feature's own interactive handover prompt (Doctor stays read-only,
# doctor.ps1 stays a diagnostic tool - see lib\DeltaDoctor.ReverseProxy.ps1's
# own header), so this check runs BEFORE that shared cycle is ever
# invoked, never inside it.

function Test-DeltaIisRequiredPortAvailability {
    <#
      The IIS analogue of setup-nginx.ps1's own Test-RequiredPortAvailability -
      see this section's own header for why "available" means free OR
      already owned by an IIS website IIS itself is safe to co-exist with
      (Get-DeltaIisPortBindingOwnership, lib\DeltaDoctor.IIS.ps1) here,
      never an exact executable-path match, and never the raw TCP owner's
      ServiceName (a real, confirmed-broken signal for IIS - see this
      section's own header).

      Order matters: the raw listener check runs first (a completely free
      port is trivially available, no need to ask IIS anything), and only
      once something IS listening does this consult IIS's own binding
      data - 'Delta' (the DELTA-managed site itself) and 'DefaultWebSite'
      (a verified stock Default Web Site) are both IIS's own normal
      operation, never a conflict with itself; 'Other' (a real, unrelated
      IIS website) and no IIS binding at all (some non-IIS process) both
      remain genuine conflicts, reported via $Owner exactly as before -
      $IisSiteName is populated only for the 'Other' case, so
      Show-DeltaIisPortConflictNotice can name the actual offending IIS
      website instead of a bare PID 4/"System".
    #>
    param([Parameter(Mandatory)][int]$Port)

    $owner = Get-ListeningTcpPortOwner -Port $Port
    if (-not $owner) {
        return [PSCustomObject]@{ Port = $Port; Available = $true; Owner = $null; IisSiteName = $null }
    }

    $binding = Get-DeltaIisPortBindingOwnership -Port $Port
    if ($binding -and $binding.Classification -in @('Delta', 'DefaultWebSite')) {
        return [PSCustomObject]@{ Port = $Port; Available = $true; Owner = $owner; IisSiteName = $null }
    }

    $iisSiteName = if ($binding -and $binding.Classification -eq 'Other') { $binding.SiteName } else { $null }
    return [PSCustomObject]@{ Port = $Port; Available = $false; Owner = $owner; IisSiteName = $iisSiteName }
}

function Show-DeltaIisPortConflictNotice {
    <#
      The IIS analogue of setup-nginx.ps1's own
      Show-DeltaNginxPortConflictNotice - reached only for a conflict
      Doctor cannot attribute to a DELTA-managed provider at all (see
      this section's own header). A genuine prerequisite FAILURE - exits
      1, before anything is created or reconfigured.
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
    if ($PortCheck.IisSiteName) {
        # A real, unrelated IIS website (Get-DeltaIisPortBindingOwnership's
        # own 'Other' classification) - named specifically here rather than
        # left to the raw TCP owner's own PID 4/"System" (HTTP.sys-owned
        # listeners are always attributed that way, never to a
        # per-site-identifiable process - see Test-DeltaIisRequiredPortAvailability's
        # own header).
        Write-Host 'IIS Website'
        Write-Host ''
        Write-Detail $PortCheck.IisSiteName
        Write-Host ''
    }
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
    Write-Host 'IIS requires this port to be free to bind the DELTA website.'
    Write-Host ''
    if ($PortCheck.IisSiteName) {
        Write-Host "Stop the '$($PortCheck.IisSiteName)' website (or free this port by hand) and rerun setup-iis.ps1."
    }
    else {
        Write-Host 'Stop the application using this port and rerun setup-iis.ps1.'
    }

    Write-Host ''
    Write-Host 'No changes have been made.'
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
}

function Show-DeltaIisForeignNginxConflictNotice {
    <#
      IIS-side mirror of setup-nginx.ps1's own
      Show-DeltaNginxForeignIisConflictNotice - see that function's own
      header for the full rationale. Shown only when the conflicting
      owner looks like NGINX but Doctor already established
      (Get-DeltaReverseProxyHandoverPlan returning $null - see
      Test-DeltaIisPortPrerequisites's own header) that it is NOT a
      DELTA-managed provider, so automatic handover was never offered.
      Purely better guidance before asking to stop it - never a widening
      of the Manual Reverse Proxy Handover feature's own DELTA-managed-only
      ownership rule; this function itself only asks, it never stops
      anything (Stop-DeltaForeignNginx, below, does that, and only once
      this returns $true).

      NGINX runs as a real user-mode process (nginx.exe), unlike IIS's
      own HTTP.sys-owned listeners (always attributed to PID 4/"System" -
      see Test-DeltaIisRequiredPortAvailability's own header) - so "looks
      like NGINX" is a plain ProcessName check on the calling side, no
      PID special-case needed.

      Reuses Read-DeltaYesNoConfirmation (lib\DeltaInstaller.Common.ps1) -
      see Show-DeltaNginxForeignIisConflictNotice's own header
      (setup-nginx.ps1) for why, rather than a second confirmation
      mechanism for the same kind of question.

      Returns [bool] - $true if the operator confirmed stopping NGINX,
      $false to decline.
    #>
    param([Parameter(Mandatory)][array]$RequiredPorts)

    $portsPhrase = ConvertTo-DeltaEnglishList -Items ($RequiredPorts | ForEach-Object { "$_" })
    $portWord    = if ($RequiredPorts.Count -gt 1) { 'ports' } else { 'port' }

    return Read-DeltaYesNoConfirmation -Body {
        Write-Host 'NGINX is currently using one or more ports required by IIS.'
        Write-Host ''
        Write-Host "IIS requires exclusive access to $portWord $portsPhrase."
        Write-Host ''
        Write-Host 'The detected NGINX instance is NOT managed by DELTA.'
        Write-Host ''
        Write-Host 'Stopping NGINX may temporarily interrupt websites or applications currently being served.'
        Write-Host ''
        Write-Host 'If this server is dedicated to DELTA, it is generally safe to stop NGINX before continuing.'
        Write-Host ''
        Write-Host 'Would you like DELTA to stop NGINX now and continue?'
        Write-Host ''
        Write-Host '[Y] Yes - Stop NGINX and continue'
        Write-Host '[N] No  - Exit without making changes'
    }
}

function Stop-DeltaForeignNginx {
    <#
      Stops a non-DELTA-managed NGINX instance so IIS can bind its
      required ports - only ever called after
      Show-DeltaIisForeignNginxConflictNotice's own explicit Y/N
      confirmation, never automatically.

      Deliberately separate from lib\DeltaDoctor.NGINX.ps1's own
      Stop-DeltaManagedNginx, which is hardcoded to
      $Script:NginxExePath/$Script:NginxHome and explicitly documented to
      "never terminate an unrelated nginx.exe process" - repurposing it
      here would silently violate that guarantee for every other caller
      of it. Uses the same control mechanism NGINX itself documents for
      stopping any instance - `nginx.exe -s stop`, run against the actual
      conflicting binary's own path ($Owner.ExecutablePath, resolved by
      Test-DeltaIisRequiredPortAvailability's own Get-ListeningTcpPortOwner
      call), letting nginx resolve its own default prefix/pid file
      exactly as it would if an administrator ran the identical command
      by hand from that binary's own directory - never
      $Script:NginxExePath, DELTA's own instance. Falls back to
      Stop-Process -Force against the raw PID only when no executable
      path could be resolved at all (Get-ListeningTcpPortOwner's own
      header - a process that has already exited, or one
      Get-DeltaProcessById could not read) - `-s stop` requires a real
      path to invoke.

      Reuses Wait-DeltaPortsReleased (lib\DeltaInstaller.Common.ps1) - see
      setup-nginx.ps1's own Stop-DeltaForeignIis for why this does not
      itself decide success/failure if ports remain occupied; the caller
      (Test-DeltaIisPortPrerequisites) re-runs its own normal port check
      afterward and falls through to the existing hard-failure notice in
      that case, per this feature's own explicit "if the ports remain
      unavailable, display the existing prerequisite failure" requirement.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Owner,
        [Parameter(Mandatory)][int[]]$RequiredPorts
    )

    Write-Step 'Stopping NGINX...'

    if ($Owner.ExecutablePath) {
        $previousEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $Owner.ExecutablePath '-s' 'stop' 2>&1 | Out-Null
        }
        finally {
            $ErrorActionPreference = $previousEap
        }
    }
    else {
        Stop-Process -Id $Owner.ProcessId -Force -ErrorAction SilentlyContinue
    }

    Write-Step 'Verifying required ports were released...'
    $stillOccupied = Wait-DeltaPortsReleased -Ports $RequiredPorts
    if ($stillOccupied.Count -eq 0) {
        Write-Success '    NGINX stopped; ports released.'
    }
}

function Show-DeltaIisPortsAvailableNotice {
    <#
      The IIS analogue of setup-nginx.ps1's own
      Show-DeltaNginxPortsAvailableNotice - the happy-path banner.
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

function Test-DeltaIisPortPrerequisites {
    <#
      The orchestrator for this whole section - see the section header
      above for the full placement/ordering rationale (Doctor first, raw
      probe second; fresh-install path only). $ReverseProxyState is the
      orchestration block's own already-computed
      Get-DeltaReverseProxyState result - never re-detected here.

      ARCHITECTURE CORRECTION: Doctor first means Doctor's own Handover
      Plan (Get-DeltaReverseProxyHandoverPlan, lib\DeltaDoctor.ReverseProxy.ps1)
      now, not a hardcoded "just stop NGINX" assumption - the NGINX side
      of this feature happens to be simple (a single managed instance is
      always its own entire occupant), but this function has no opinion
      on that either way; it only ever presents and executes whatever
      plan Doctor built (Invoke-DeltaReverseProxyHandover,
      lib\DeltaInstaller.Common.ps1). See that function's own header, and
      setup-nginx.ps1's own identical Test-DeltaNginxPortPrerequisites,
      for the full rationale.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$ReverseProxyState)

    Write-Step 'Checking required IIS ports...'
    $requiredPorts = Get-DeltaIisRequiredPorts

    $handoverPlan = Get-DeltaReverseProxyHandoverPlan -ReverseProxyState $ReverseProxyState -RequestingProviderName 'IIS'
    if ($handoverPlan) {
        $handedOver = Invoke-DeltaReverseProxyHandover -Plan $handoverPlan

        if (-not $handedOver) {
            exit 0
        }
    }

    # NGINX Installed (Doctor-reported, not re-detected here) is the
    # signal here - see Show-DeltaIisForeignNginxConflictNotice's own
    # header for why NGINX, unlike IIS, needs no PID special-case on top
    # of it. Only used to choose which notice to show below - the
    # DELTA-managed handover path above already fully owns the case
    # where this same NGINX is DELTA-managed.
    $nginxInstalled = [bool](($ReverseProxyState.ProviderStates | Where-Object { $_.Name -eq 'NGINX' } | Select-Object -First 1).Installed)

    $results  = @(foreach ($port in $requiredPorts) { Test-DeltaIisRequiredPortAvailability -Port $port })
    $conflict = $results | Where-Object { -not $_.Available } | Select-Object -First 1

    if ($conflict) {
        $looksLikeNginx = $nginxInstalled -and $conflict.Owner -and ($conflict.Owner.ProcessName -eq 'nginx')
        if ($looksLikeNginx) {
            $wantsStop = Show-DeltaIisForeignNginxConflictNotice -RequiredPorts $requiredPorts
            if (-not $wantsStop) {
                Write-Host ''
                Write-Detail 'No changes have been made.'
                Write-Host ''
                exit 0
            }

            Stop-DeltaForeignNginx -Owner $conflict.Owner -RequiredPorts $requiredPorts

            # Re-run the same check once more - success or failure from
            # here on is decided exactly as if this had been the first
            # attempt (still-occupied falls straight through to the
            # existing hard-failure notice below, per this feature's own
            # "if the ports remain unavailable, display the existing
            # prerequisite failure" requirement).
            $results  = @(foreach ($port in $requiredPorts) { Test-DeltaIisRequiredPortAvailability -Port $port })
            $conflict = $results | Where-Object { -not $_.Available } | Select-Object -First 1
        }
    }

    if ($conflict) {
        Show-DeltaIisPortConflictNotice -PortCheck $conflict
        exit 1
    }

    Show-DeltaIisPortsAvailableNotice -RequiredPorts $requiredPorts
}

function Show-DeltaIisPostHandoverValidation {
    <#
      Manual Reverse Proxy Handover - AFTER START. If
      $Script:DeltaReverseProxyHandoverOccurred is set
      (Invoke-DeltaReverseProxyHandover, lib\DeltaInstaller.Common.ps1,
      already marked it earlier in this same run - see
      Test-DeltaIisPortPrerequisites, above), this runs Doctor's own
      Reverse Proxy Detection one more time and prints it, per this
      feature's own explicit "run Doctor again" final-validation
      requirement - the administrator sees IIS confirmed Active/Healthy
      from the same authoritative source that reported NGINX active a
      moment earlier, not just this script's own success claim. The
      direct IIS-side counterpart of setup-nginx.ps1's own identical
      check inside Start-DeltaNginx. Skipped entirely when no handover
      was involved.
    #>

    if ($Script:DeltaReverseProxyHandoverOccurred) {
        $Script:DeltaReverseProxyHandoverOccurred = $false
        Write-Host ''
        Write-PhaseBanner 'Deployment Validation'
        Invoke-DeltaReverseProxyDetection | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Management Mode (docs\todo\TODO-setup-iis-enhancements.md, Phase 8 - a
# narrower, UX/orchestration-only precursor to that phase's own full
# three-signal runtime state model)
# ---------------------------------------------------------------------------
#
# Once Get-DeltaIisManagedWebsiteResult confirms a genuinely managed DELTA
# website already exists, this script stops behaving like a first-time
# installer - Phase 6 (Website Configuration) and Phase 7 (SSL Certificate)
# never run against an existing site, and Public Website Domain/Backend
# Port/ARR/URL Rewrite/Reverse Proxy/website/application pool are never
# re-prompted for or recreated. Instead, control hands off to
# Show-DeltaIisManagementMenu below - the direct IIS analogue of
# setup-nginx.ps1's own Show-DeltaNginxManagementMenu: loop until Exit,
# re-read live state every iteration, delegate every action to an existing
# or narrowly-scoped new helper, never reconfigure anything automatically.
# Every displayed value is read back from the site's own live,
# already-configured state - never recomputed from .env or re-prompted for -
# the same "an existing installation's configuration is exactly what should
# be displayed as-is" precedent Get-DeltaNginxVHostSummary already
# established for NGINX.

# Start-DeltaIisManagedWebsite/Stop-DeltaIisManagedWebsite/
# Restart-DeltaIisManagedWebsite now live in lib\DeltaDoctor.IIS.ps1 (dot-
# sourced above via lib\DeltaDoctor.ReverseProxy.ps1) - promoted there once
# setup-nginx.ps1 needed the identical "stop the DELTA-managed website"
# action for its own side of the Manual Reverse Proxy Handover feature. See
# that file's own header for the full rationale.

function Restart-DeltaIisManagedAppPool {
    <#
      Management menu action ("Restart Application Pool") - unlike
      website restart, IIS genuinely does provide a single, direct
      primitive for this (ApplicationPool.Recycle(), wrapped by
      Restart-DeltaIisApplicationPool), so no composition is needed.
      Recycles the DELTA application pool's own worker process(es)
      without affecting the website's own started/stopped state.

      Unlike the original WebAdministration-based Restart-WebAppPool
      call, this reports a clear failure (rather than letting an
      exception propagate uncaught to the top-level orchestration catch
      block) both when the pool cannot be found at all and when
      Recycle() itself throws.
    #>

    $serverManager = Get-DeltaIisServerManager
    $pool = Get-DeltaIisApplicationPoolByName -ServerManager $serverManager -Name $Script:DeltaIisAppPoolName
    if (-not $pool) {
        Stop-Setup "Application pool '$($Script:DeltaIisAppPoolName)' does not exist - it cannot be restarted."
    }

    Write-Step 'Restarting the application pool...'
    try {
        Restart-DeltaIisApplicationPool -Pool $pool
    }
    catch {
        Stop-Setup "Failed to restart the application pool '$($Script:DeltaIisAppPoolName)': $($_.Exception.Message)"
    }
    Write-Success '    Application pool restarted.'
}

function Open-DeltaIisManagedWebsite {
    <#
      Management menu action ("Browse Website") - not present in
      setup-nginx.ps1's own menu, but explicitly sanctioned by this
      feature's own "the exact options may differ if IIS exposes better
      native operations" allowance. Opens $Scheme://$HostHeader in the
      default browser. Reports plainly rather than guessing a URL if no
      host header could be read.
    #>
    param([string]$Scheme, [string]$HostHeader)

    if (-not $HostHeader) {
        Write-Host ''
        Write-Detail 'Cannot browse to this website - no host header is configured.'
        return
    }

    $url = "$($Scheme)://$($HostHeader)"
    Write-Step "Opening $url ..."
    Start-Process -FilePath $url | Out-Null
}

function Test-DeltaIisManagedWebsiteConfiguration {
    <#
      Management menu action ("Validate Configuration") - the IIS analogue
      of setup-nginx.ps1's own "Validate configuration" menu action
      (Test-DeltaNginxConfiguration, which runs `nginx -t`). No longer an
      independent implementation: per this project's own "there must be
      only ONE authoritative implementation of IIS diagnostics" principle,
      this simply calls the exact same Get-DeltaDoctorWebsiteChecks
      (lib\DeltaDoctor.IIS.ps1) the Doctor's own report uses and displays
      its result the Doctor's own way (Show-DeltaDoctorChecks) - read-only,
      never offers or performs repair here (that is what re-running this
      script, which now runs the full checkup before ever reaching this
      menu, is for).
    #>

    $portInfo = Resolve-DeltaDoctorBackendPortInfo -EnvPath $Script:DeltaEnvPath
    $expectedPort = if ($portInfo.Valid) { $portInfo.Port } else { -1 }

    Write-Step 'Validating configuration...'
    $result = Get-DeltaDoctorWebsiteChecks -ExpectedBackendPort $expectedPort
    Show-DeltaDoctorChecks -Checks $result.Checks
}

# ---------------------------------------------------------------------------
# PUBLIC_URL synchronization (existing installation)
# ---------------------------------------------------------------------------
#
# After initial installation, IIS - not .env.example/setup.ps1 - is the
# source of truth for the deployed PUBLIC_URL
# (lib\DeltaInstaller.Common.ps1's own Sync-DeltaPublicUrlEnvironment
# header). Runs once, before the management menu is ever shown, so every
# successful re-run of this script against an already-configured
# installation keeps .env in sync with whatever IIS is actually serving -
# never only on a fresh install. The direct IIS analogue of
# setup-nginx.ps1's own identical Resolve-DeltaNginxPublicUrlSync. This
# section only ever writes .env - it deliberately never restarts DELTA
# itself; the management menu's own "Restart DELTA backend" option
# (Restart-DeltaRuntimeForReverseProxy, lib\DeltaInstaller.Common.ps1) is
# the one place that does, and only when the administrator explicitly
# chooses it.

function Show-DeltaIisPublicUrlMismatchNotice {
    <#
      The IIS analogue of setup-nginx.ps1's own
      Show-DeltaNginxPublicUrlMismatchNotice - see that function's own
      header for the full rationale.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfiguredUrl,
        [Parameter(Mandatory)][string]$EnvUrl
    )

    Write-Host ''
    Write-Host 'The configured IIS domain and PUBLIC_URL do not match.'
    Write-Host ''
    Write-Host 'IIS:'
    Write-Detail $ConfiguredUrl
    Write-Host ''
    Write-Host '.env:'
    Write-Detail $EnvUrl
    Write-Host ''
}

function Resolve-DeltaIisPublicUrlSync {
    <#
      Reads the managed site's own already-configured host header
      (Get-DeltaIisSiteHostHeader) and HTTPS state
      (Get-DeltaIisExistingHttpsCertificateState) - the same read-only
      sources the management menu's own display already trusts - compares
      the resulting URL against PUBLIC_URL in .env
      (Test-DeltaPublicUrlsMatch), and only acts on a genuine
      disagreement. See setup-nginx.ps1's own Resolve-DeltaNginxPublicUrlSync
      for the full four-outcome breakdown (no host header yet / PUBLIC_URL
      absent / already matching / genuine mismatch) - identical here,
      just against IIS's own site/binding state instead of a vhost file.

      A genuine mismatch re-prompts for the domain
      (Resolve-DeltaWebsiteDomain -DefaultDomain, defaulting a bare Enter
      to the domain IIS is already configured with, not "localhost" - the
      same footgun Repair-DeltaIisManagedWebsite's own header already
      calls out), then reconciles ONLY the artifacts this installer owns -
      Confirm-DeltaIisAppPool/New-DeltaIisWebConfig/Confirm-DeltaIisWebsite
      (which updates the HTTP:80 binding's host header via
      Confirm-DeltaIisWebsiteBinding) and, only when HTTPS is already
      configured, Confirm-DeltaIisHttpsBinding with the SAME thumbprint
      already in place - only the domain is being resynchronized here,
      never the certificate itself. Mirrors Repair-DeltaIisManagedWebsite's
      own composition rather than duplicating it, except for domain
      resolution: that function reads the EXISTING domain and never
      prompts, which is exactly wrong for a call site that got here
      because the domain needs to change.

      DELTA itself is never restarted here, in any of the four outcomes -
      see this section's own header for why.

      Does NOT itself ensure the website ends up Active/Started - the
      orchestration block's own caller does that exactly once, via
      Start-DeltaIisManagedWebsite, immediately after this function
      returns (see that call site's own comment), regardless of which of
      the four outcomes above actually ran. Ensuring "the site is running
      by the time the management menu opens" is that ONE call's job,
      not this function's - duplicating it into just one of the four
      branches here previously left the other three (in particular the
      overwhelmingly common "already matching, nothing to do" case) with
      no such guarantee at all.
    #>
    param([Parameter(Mandatory)]$ManagedSite)

    $hostHeader = Get-DeltaIisSiteHostHeader -Site $ManagedSite
    if (-not $hostHeader) {
        return
    }

    $httpsState = Get-DeltaIisExistingHttpsCertificateState
    $isHttps = [bool]($httpsState -and $httpsState.CertificateExists)

    $configuredUrl = Get-DeltaPublicUrl -Domain $hostHeader -Https $isHttps
    $envUrl = Get-EnvFileValue -Path $Script:DeltaEnvPath -Key 'PUBLIC_URL'

    if (-not $envUrl) {
        Sync-DeltaPublicUrlEnvironment -Domain $hostHeader -Https:$isHttps
        return
    }

    if (Test-DeltaPublicUrlsMatch -First $configuredUrl -Second $envUrl) {
        return
    }

    Show-DeltaIisPublicUrlMismatchNotice -ConfiguredUrl $configuredUrl -EnvUrl $envUrl

    Write-PhaseBanner 'Public Website Domain'
    $Script:DeltaWebsiteDomain = Resolve-DeltaWebsiteDomain -DefaultDomain $hostHeader
    Write-Success "    Website domain: $($Script:DeltaWebsiteDomain)"

    Resolve-DeltaBackendPort

    Confirm-DeltaIisAppPool
    New-DeltaIisWebConfig
    Confirm-DeltaIisWebsite -ManagedSite $ManagedSite

    if ($isHttps -and $httpsState.Thumbprint) {
        Confirm-DeltaIisHttpsBinding -Thumbprint $httpsState.Thumbprint
    }

    Confirm-DeltaIisWebsiteConfigurationResult | Out-Null

    Sync-DeltaPublicUrlEnvironment -Domain $Script:DeltaWebsiteDomain -Https:$isHttps
}

function Show-DeltaIisManagementMenu {
    <#
      The Phase 5/8 hand-off point - replaces the old "Website
      configuration is owned by a later development phase" notice with an
      interactive menu, the direct IIS analogue of
      Show-DeltaNginxManagementMenu in setup-nginx.ps1. Per this feature's
      own requirements, an existing DELTA IIS website is never
      reconfigured automatically: nothing here re-prompts for the website
      domain, backend port, ARR/URL Rewrite/Reverse Proxy setup, or
      website/application pool creation - the existing IIS configuration
      is the source of truth, and every displayed value is read back from
      it directly (Get-DeltaIisSiteHostHeader, Get-DeltaIisSiteBackendPort,
      Get-DeltaIisExistingHttpsCertificateState), never recomputed from
      .env or re-derived.

      Unlike setup-nginx.ps1's own Running/Stopped/Broken/NotInstalled
      branching menu, this always offers the same eight options - Site.
      Start()/Site.Stop()/ApplicationPool.Recycle() (via
      lib\DeltaDoctor.IIS.ps1's own Start-DeltaIisSite/Stop-DeltaIisSite/
      Restart-DeltaIisApplicationPool) are idempotent no-ops to call
      against an already-matching state (and
      Start-DeltaIisManagedWebsite/Stop-DeltaIisManagedWebsite each still
      check first and report a no-op plainly rather than calling them
      needlessly), so there is no meaningful "wrong state to offer this
      action in" the way NGINX's own signal-based reload/stop genuinely
      have. The full three-signal Broken-state model setup-nginx.ps1 uses
      belongs to Phase 8's own later, separate runtime-management
      redesign - out of scope for this UX/orchestration-only adjustment.

      "Restart DELTA backend" (Restart-DeltaRuntimeForReverseProxy,
      lib\DeltaInstaller.Common.ps1) is the one option here that touches
      the DELTA (Node.js) process rather than IIS itself - the direct IIS
      analogue of setup-nginx.ps1's own identical menu option. Kept as
      its own explicit, administrator-triggered choice: the PUBLIC_URL
      synchronization section above never restarts DELTA automatically,
      so this is where an administrator goes to actually make DELTA pick
      up a newly-synchronized .env value.

      Loops until the administrator chooses Exit (bare Enter also exits),
      re-reading the site fresh at the top of every iteration so
      Status/Binding/Backend/Application Pool reflect whatever the
      just-run action actually changed, rather than a stale snapshot.

      Reverse-proxy state gets the exact same "never a stale snapshot"
      treatment now, not just the site's own facts: a real, confirmed bug
      had this menu accept a single Get-DeltaReverseProxyState result
      from its caller (the orchestration block, computed once before the
      menu was ever entered) and reuse that SAME object at both points
      that actually attempt to bind a port (Start Website, Restart
      Website), even though this menu can stay open indefinitely and
      another provider's own runtime state can genuinely change while it
      does. Start Website/Restart Website now each call
      Get-DeltaReverseProxyState (lib\DeltaDoctor.ReverseProxy.ps1) fresh,
      immediately before Test-DeltaIisPortPrerequisites - the same
      read-only, non-printing detection primitive Invoke-DeltaReverseProxyDetection
      itself calls internally, never a second/independent detection of
      its own. No `-ReverseProxyState` parameter exists on this function
      anymore for exactly this reason: an initial snapshot threaded in
      from outside is the shape that caused the bug, so there is
      deliberately nothing here for a future caller to mistakenly reuse.
    #>
    param()

    if (-not (Test-DeltaIisManagementAssemblyAvailable)) {
        Stop-Setup 'Microsoft.Web.Administration is unavailable, so website management cannot proceed. Re-run Phase 3 (Microsoft IIS Installation) first.'
    }

    while ($true) {
        # A fresh ServerManager every iteration, not just a fresh site
        # lookup - see this function's own header for the real bug this
        # fixes (a stale snapshot reused across menu actions).
        $serverManager = Get-DeltaIisServerManager
        $currentSite = Get-DeltaIisSiteByName -ServerManager $serverManager -Name $Script:DeltaIisSiteName
        if (-not $currentSite) {
            Write-Host ''
            Write-Detail 'The DELTA website no longer appears to exist.'
            return
        }

        $hostHeader = Get-DeltaIisSiteHostHeader -Site $currentSite
        $backendPort = Get-DeltaIisSiteBackendPort -Site $currentSite
        $httpsState = Get-DeltaIisExistingHttpsCertificateState
        $scheme = if ($httpsState -and $httpsState.CertificateExists) { 'https' } else { 'http' }

        Write-Host ''
        Write-Host ('=' * $Script:BannerWidth)
        Write-Host ''
        Write-Host 'Existing DELTA IIS Website'
        Write-Host ''
        Write-Host 'Website'
        Write-Host ''
        Write-Detail $currentSite.Name
        Write-Host ''
        Write-Host 'Status'
        Write-Host ''
        # Reading .State on a Microsoft.Web.Administration Site can THROW
        # while W3SVC isn't running, unlike Name/PhysicalPath/the root
        # application's own ApplicationPoolName, which read straight from
        # applicationHost.config regardless of service state -
        # Get-DeltaIisSiteState (lib\DeltaDoctor.IIS.ps1) wraps that in a
        # try/catch and reports 'Unknown' rather than letting this menu
        # crash. Start-DeltaIisManagedWebsite (the orchestration block's
        # own caller, and this menu's own "Start Website"/"Restart
        # Website" actions) is what actually keeps W3SVC/the site
        # running; this only ever keeps the display itself from crashing
        # if it somehow isn't, for whatever reason, right now.
        Write-Detail (Get-DeltaIisSiteState -Site $currentSite)
        Write-Host ''
        Write-Host 'Binding'
        Write-Host ''
        Write-Detail $(if ($hostHeader) { "$($scheme)://$($hostHeader)" } else { 'Unknown' })
        Write-Host ''
        Write-Host 'Backend'
        Write-Host ''
        Write-Detail $(if ($backendPort) { "http://localhost:$($backendPort)" } else { 'Unknown' })
        Write-Host ''
        Write-Host 'Application Pool'
        Write-Host ''
        Write-Detail (Get-DeltaIisSiteApplicationPoolName -Site $currentSite)
        Write-Host ''
        Write-Host ('=' * $Script:BannerWidth)
        Write-Host ''

        Write-Host '1) Start Website'
        Write-Host '2) Stop Website'
        Write-Host '3) Restart Website'
        Write-Host '4) Restart Application Pool'
        Write-Host '5) Restart DELTA backend'
        Write-Host '6) Browse Website'
        Write-Host '7) Validate Configuration'
        Write-Host '8) Exit'
        Write-Host ''

        $choice = Read-Host -Prompt 'Choose an option [8]'
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '8' }

        switch ($choice.Trim()) {
            '1' {
                # Fresh, never the menu-entry snapshot - see this
                # function's own header for the real bug this fixes.
                Test-DeltaIisPortPrerequisites -ReverseProxyState (Get-DeltaReverseProxyState)
                Start-DeltaIisManagedWebsite
                Show-DeltaIisPostHandoverValidation
            }
            '2' { Stop-DeltaIisManagedWebsite }
            '3' {
                Test-DeltaIisPortPrerequisites -ReverseProxyState (Get-DeltaReverseProxyState)
                Restart-DeltaIisManagedWebsite
                Show-DeltaIisPostHandoverValidation
            }
            '4' { Restart-DeltaIisManagedAppPool }
            '5' { Restart-DeltaRuntimeForReverseProxy }
            '6' { Open-DeltaIisManagedWebsite -Scheme $scheme -HostHeader $hostHeader }
            '7' { Test-DeltaIisManagedWebsiteConfiguration }
            '8' { return }
            default { Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow }
        }
    }
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

try {
    Write-SetupBanner -Title 'DELTA IIS Setup' -Subtitle 'Optional reverse proxy for DELTA'

    # Must happen before anything else - see Resolve-DeltaInstallation's own
    # header. Nothing above this point has touched the filesystem, and
    # nothing below this point runs at all if no DELTA installation is found.
    Resolve-DeltaInstallation

    # Doctor's own Reverse Proxy Detection - runs unconditionally, before
    # ANY workflow decision below, so this script's own choices (in
    # particular the Manual Reverse Proxy Handover feature's own port
    # prerequisite check, further down) are driven by Doctor's
    # already-computed, DELTA-ownership-based answer, never independently
    # re-derived from raw ports/processes. Mirrors setup-nginx.ps1's own
    # identical placement - see that script's own Orchestration section
    # header for the full principle.
    $reverseProxyState = Invoke-DeltaReverseProxyDetection
    Write-Host ''

    Show-DeltaIisDiscoverySummary

    # Phase 2 - detection only, see that section's own header. Never
    # installs, enables, or configures anything.
    $Script:DeltaIisDetection = Get-DeltaIisDetectionResult
    Show-DeltaIisDetectionSummary -Detection $Script:DeltaIisDetection

    # Phase 3 - installs only whatever Phase 2 just found missing. See
    # that section's own header for the full behavior; nothing below this
    # point runs at all if the administrator declines the confirmation
    # prompt or if a required restart is still pending.
    $missingFeatures = Get-DeltaIisMissingFeatures -Detection $Script:DeltaIisDetection

    if ($missingFeatures.Count -eq 0) {
        Write-Host ''
        Write-Detail 'All required Microsoft IIS features are already installed.'
        Show-DeltaIisInstallationSummary -Detection $Script:DeltaIisDetection -AlreadyInstalled $true -RestartNeeded $false
    }
    else {
        if (-not (Read-DeltaIisInstallConfirmation -MissingFeatures $missingFeatures)) {
            Show-DeltaIisInstallCancelledNotice
            exit 0
        }

        $installResult = Install-DeltaIisFeatures -OperatingSystemType $Script:DeltaIisDetection.OperatingSystemType -MissingFeatures $missingFeatures

        if ($installResult.RestartNeeded) {
            Show-DeltaIisRestartRequiredNotice
            exit 0
        }

        # Post-Installation Verification - re-runs Phase 2's own detection
        # rather than trusting Install-DeltaIisFeatures's own result; see
        # Confirm-DeltaIisPostInstallState's own header for why.
        $Script:DeltaIisDetection = Get-DeltaIisDetectionResult
        Confirm-DeltaIisPostInstallState -Detection $Script:DeltaIisDetection

        Show-DeltaIisInstallationSummary -Detection $Script:DeltaIisDetection -AlreadyInstalled $false -RestartNeeded $false
    }

    # Phase 4 - ARR/URL Rewrite prerequisites. Reached whether Phase 3 just
    # installed something or found everything already in place - both are
    # equally valid "IIS is ready" states. Nothing below this point runs at
    # all if the administrator declines, installation/verification fails,
    # or a restart is still pending.
    $arrResult = Invoke-DeltaArrSetup
    if (-not $arrResult.Ready) {
        exit 0
    }

    # Whether a managed DELTA website already exists decides which of the
    # two flows below this script follows - read once, here, purely for
    # that branch decision (lib\DeltaDoctor.IIS.ps1's own
    # Invoke-DeltaIisConfigurationCheckup, called identically in both
    # branches, re-derives this same fact itself when it actually needs
    # it - the same "cheap, read-only, called more than once" precedent
    # this script has always used for Get-DeltaIisManagedWebsiteResult).
    $websiteResult = Get-DeltaIisManagedWebsiteResult

    # The Doctor's own shared Detect -> Diagnose -> Report -> Offer Repair
    # -> Validate Again cycle (lib\DeltaDoctor.IIS.ps1) is the ONE
    # authoritative implementation of "is the DELTA website itself
    # correctly configured" - this script no longer has its own copy of
    # that logic, whether the site is being created for the very first
    # time (every check below simply reports failing, and the offered
    # repair creates it) or being reconciled because something about an
    # existing site broke.
    # Manual Reverse Proxy Handover - only on the fresh-install path (no
    # managed site exists yet, so this checkup is about to CREATE and bind
    # the website for the first time): if NGINX is DELTA's active reverse
    # proxy, offer to stop it before the checkup ever runs. Deliberately
    # NOT run ahead of the existing-managed-site path below - an existing,
    # already-active site isn't about to bind anything new, and that
    # path's own handover point is the management menu's own Start/Restart
    # actions instead (see Show-DeltaIisManagementMenu's own header). Also
    # deliberately kept OUTSIDE Invoke-DeltaIisConfigurationCheckup itself -
    # that shared cycle is also called by doctor.ps1, which must never gain
    # this feature's own interactive prompt (see this section's own header
    # further up this file).
    if (-not $websiteResult.ManagedSite) {
        Test-DeltaIisPortPrerequisites -ReverseProxyState $reverseProxyState
    }

    Write-PhaseBanner 'IIS Configuration Checkup'
    $checkup = Invoke-DeltaIisConfigurationCheckup

    if ($websiteResult.ManagedSite) {
        # Existing Managed Site - hands off to the interactive management
        # menu only once the checkup above reports the site healthy (or an
        # accepted repair just made it so). A still-unhealthy site (the
        # administrator declined the repair, or a problem needs manual
        # attention) is reported by the checkup itself; the menu is not
        # shown in that case, matching doctor.ps1's own standalone "no
        # changes have been made" / "these problems require manual
        # attention" posture rather than presenting a menu for a site this
        # script cannot yet vouch for.
        if ($checkup.Healthy) {
            Resolve-DeltaIisPublicUrlSync -ManagedSite $websiteResult.ManagedSite

            # Start the managed reverse proxy - the exact same call, in
            # the exact same "Repair/Configure -> Start -> hand off" order,
            # as the fresh-install path below (see that call site's own
            # comment for the full rationale). Invoke-DeltaIisConfigurationCheckup
            # above only ever validates/repairs CONFIGURATION (application
            # pool settings, web.config, the HTTP binding) - it has no
            # opinion on whether the site is actually Started, so an
            # existing site reported Healthy is not the same thing as one
            # that is Active. Previously this was only reached from inside
            # Resolve-DeltaIisPublicUrlSync's own PUBLIC_URL-mismatch
            # branch, leaving every other, far more common outcome of that
            # function (in particular "already in sync, nothing to do") to
            # reach the management menu below with no such guarantee -
            # exactly the gap that let the menu open, and then crash on an
            # empty Status, while W3SVC was not actually running. Calling
            # it once here, unconditionally, closes that gap for every
            # path into this branch, not just the mismatch one.
            Start-DeltaIisManagedWebsite

            Show-DeltaIisManagementMenu
        }
        exit 0
    }

    # Fresh Installation (or an unresolved site-name collision, which the
    # checkup above already reported as a non-repairable error) - continue
    # into the Certificate Wizard only once the website itself is healthy.
    if (-not $checkup.Healthy) {
        exit 1
    }

    # Start the managed reverse proxy - the direct IIS analogue of
    # setup-nginx.ps1's own Start-DeltaNginx call, in the same position in
    # the lifecycle (Repair/Configure -> Start -> Validate deployment).
    # Invoke-DeltaIisConfigurationCheckup above only ever creates/reconciles
    # the site's own configuration (application pool, web.config, HTTP
    # binding) - it never starts it, so without this call the website could
    # be left Healthy but never Active (Doctor's own
    # Get-DeltaIisReverseProxyProviderState reads Active straight from the
    # site's own state (Get-DeltaIisSiteState -eq 'Started'), a genuine
    # runtime fact site creation does not always leave true on its own).
    # Start-DeltaIisManagedWebsite
    # (lib\DeltaDoctor.IIS.ps1) is the same idempotent, ownership-checked
    # primitive the management menu's own "Start Website" action already
    # uses - a no-op, reported plainly, if the site is already running -
    # so calling it unconditionally here is always safe, never a
    # duplicate/second implementation of "start the site."
    Start-DeltaIisManagedWebsite

    # Deployment Validation - only ever prints Doctor's own re-detection
    # when a Manual Reverse Proxy Handover actually occurred earlier in
    # this run (see this function's own header) - identical, in both
    # placement (immediately after the reverse proxy actually starts) and
    # behavior, to setup-nginx.ps1's own equivalent check inside
    # Start-DeltaNginx.
    Show-DeltaIisPostHandoverValidation

    # The Certificate Wizard. Cancel exits immediately here, before the
    # summary, mirroring setup-nginx.ps1's own Cancel path
    # (Show-SslCertificateCancelledNotice + exit 0, bypassing the summary
    # entirely). Decline ("No") and Keep both fall through to the summary
    # normally, since both are complete, successful outcomes.
    $sslResult = Invoke-DeltaIisSslCertificateSetup
    if ($sslResult.Cancelled) {
        exit 0
    }

    Sync-DeltaPublicUrlEnvironment -Domain $Script:DeltaWebsiteDomain -Https:$sslResult.HttpsConfigured

    Show-DeltaIisSslSummary -SslResult $sslResult

    exit 0
}
catch {
    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Red
    Write-Host 'DELTA IIS setup failed.' -ForegroundColor Red
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

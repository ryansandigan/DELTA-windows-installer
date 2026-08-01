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
    (IIS Installation), Phase 4 (Application Request Routing), Phase 5
    (Website Discovery), Phase 6 (Website Configuration), and Phase 7
    (Windows SSL Certificate) exist so far. The roadmap's original,
    separately-numbered Phase 7 (Website Domain) was merged into Phase 6
    once Phase 6 was actually implemented - see
    docs\todo\TODO-setup-iis-enhancements.md's own renumbering note - and
    what is now Phase 7 here combines what the roadmap originally split
    into SSL Certificate and Existing Certificate Handling.

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
    every IIS role service/feature later phases depend on, and whether the
    WebAdministration PowerShell module is available (never imported here -
    only its availability is reported). Detection only: nothing in this
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

    Phase 5: only runs once Phase 4 has reported ready. Determines
    whether a managed DELTA IIS website already exists, using a fixed
    site identity ($Script:DeltaIisSiteName, 'DELTA') cross-validated
    against the resolved DELTA installation path - never inferred from
    the name alone. An existing managed site is reported in a read-only
    summary; no managed site found reports that the IIS platform is ready
    and defers configuration to the next phase. Never creates, modifies,
    or deletes any IIS website in either case.

    Phase 6: creates or updates the managed DELTA IIS website itself -
    the dedicated application pool (No Managed Code, Integrated
    pipeline), the website (physical path = the DELTA installation
    directory itself, never a second application directory), its
    generated web.config (templates\iis\web.config, rendered via the
    shared Write-DeltaTemplateFile - never PowerShell string
    concatenation), and its single HTTP:80 binding. Reuses Phase 5's own
    managed-site discovery: a genuine collision (the fixed site name
    already claimed by an unrelated website) stops the script outright;
    an existing managed site has only its own web.config/application
    pool settings/binding reconciled, never recreated, and any unrelated
    IIS configuration is left untouched. Resolve-DeltaWebsiteDomain and
    Resolve-DeltaBackendPort both run on every invocation, so a changed
    domain or backend port regenerates the configuration correctly on a
    plain rerun. Every claim this phase makes is independently
    re-verified by reading IIS back afterward, never assumed from
    New-Website/New-WebAppPool's own lack of a thrown error. Does not
    implement runtime management or port/binding conflict validation -
    those remain later phases.

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

    Management Mode: once Phase 5's own discovery confirms a managed
    DELTA website already exists, this script never falls through to
    Phase 6/Phase 7 at all - it hands off immediately to
    Show-DeltaIisManagementMenu and exits once the administrator chooses
    Exit. Nothing is re-prompted (website domain, backend port, ARR/URL
    Rewrite/Reverse Proxy, website/application pool creation) - the
    existing IIS configuration is the source of truth, and every value
    the menu displays is read back from it directly. The menu offers
    Start/Stop/Restart Website, Restart Application Pool, Browse Website,
    Validate Configuration, and Exit - the direct IIS analogue of
    setup-nginx.ps1's own Show-DeltaNginxManagementMenu, adapted to IIS's
    native website/application-pool cmdlets rather than NGINX's process-
    and-pid-file model. This is a narrower, UX/orchestration-only
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

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The fixed, well-known DELTA IIS site identity (docs\todo\TODO-setup-iis-
# enhancements.md, Phase 5's own "Managed vs. unrelated" section) - the
# administrator never gets to name this site something else, and Phase 5
# never scans for "a site that looks like it might be DELTA." Matches
# NGINX's own fixed $Script:NginxHome (C:\nginx) convention: a single,
# hardcoded identity this installer always uses, never inferred.
$Script:DeltaIisSiteName = 'DELTA'

# The dedicated DELTA application pool name (docs\todo\TODO-setup-iis-
# enhancements.md, Phase 6's own "Application Pool" example) - kept as
# its own named constant, distinct from $Script:DeltaIisSiteName, even
# though both currently use the literal value 'DELTA', since nothing
# requires the two to stay identical and a future phase may need to tell
# them apart explicitly.
$Script:DeltaIisAppPoolName = 'DELTA'

# The canonical web.config template (Phase 6) - templates\iis\, sibling
# to templates\nginx\, following the exact same "canonical, readable,
# version-controlled template file, never PowerShell string
# concatenation" philosophy setup-nginx.ps1's own header documents for
# its NGINX templates.
$Script:DeltaIisWebConfigTemplate = Join-Path -Path $Script:ProjectRoot -ChildPath 'templates\iis\web.config'

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

# Application Request Routing (docs\todo\TODO-setup-iis-enhancements.md,
# Phase 4) - ARR and URL Rewrite are standalone Microsoft redistributables,
# not Windows Features, historically distributed through the now-retired
# Web Platform Installer. These are the versions/URLs current when this
# phase was implemented - re-verify against Microsoft's own Download
# Center/IIS.net pages before bumping either, the same caveat
# setup-nginx.ps1's own header carries for its nginx.org download URL, and
# setup.ps1's own header carries for its EDB/PostGIS download URLs. Both
# are ordinary MSI packages once obtained directly (not through WebPI),
# installable silently via the same msiexec convention setup.ps1's own
# Install-NodeMsi already uses.
# Confirmed reachable via a live HEAD request at the time this was written
# (200, ~6.1MB for URL Rewrite / ~2.4MB for ARR - both plausible MSI sizes)
# - re-verify before bumping either if either ever starts 404ing again, the
# same caveat nginx.org/EDB's own download URLs already carry elsewhere in
# this project. An earlier pinned URL Rewrite URL sourced from this
# project's own roadmap document was confirmed DEAD (404) during Phase 4
# implementation and replaced with this one.
$Script:UrlRewriteDownloadUrl = 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi'
$Script:ArrDownloadUrl        = 'https://download.microsoft.com/download/E/9/8/E9849D6A-020E-47E4-9FD0-A023E99B54EB/requestRouter_amd64.msi'

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
# Microsoft IIS Detection (docs\todo\TODO-setup-iis-enhancements.md, Phase 2)
# ---------------------------------------------------------------------------
#
# Detection only - nothing in this section ever installs, enables, or
# configures anything. Get-WindowsFeature/Get-WindowsOptionalFeature -Online
# only ever query current state, Get-ItemProperty reads the IIS version
# straight out of the registry, and Get-Module -ListAvailable never imports
# WebAdministration - it only reports whether it COULD be imported. Phase 3
# (IIS Installation) is the first phase allowed to change anything on this
# machine.

function Test-DeltaServerManagerAvailable {
    <#
      Whether the ServerManager module (Get-WindowsFeature's own module -
      Windows Server only) is available on this machine - the same
      "simply Test-Path for the presence of the ServerManager module"
      check this phase's own roadmap calls out as the way to decide which
      of the two Windows Feature APIs applies, rather than assuming
      Windows Server the way the rest of this project's documentation
      otherwise does (CLAUDE.md's own "Windows Server 2025" objective).
      Get-Module -ListAvailable never imports anything - this only
      reports whether the module COULD be imported.
    #>
    return [bool](Get-Module -ListAvailable -Name 'ServerManager' -ErrorAction SilentlyContinue)
}

function Get-DeltaIisOperatingSystemInfo {
    <#
      Determines which of the two Windows Feature / role-service APIs
      applies on this machine - ServerManager/Get-WindowsFeature on
      Windows Server, DISM/Get-WindowsOptionalFeature -Online on Windows
      11/10 client SKUs, where the ServerManager module does not exist at
      all. Test-DeltaServerManagerAvailable is the actual gate (the fact
      that decides which API is callable) - Win32_OperatingSystem's own
      Caption is read only for the administrator-facing display string
      ("Microsoft Windows Server 2025 Standard", "Microsoft Windows 11
      Pro", etc.), never to decide the branch itself: the two could
      disagree on an unusual SKU, and the module's own actual availability
      is the one fact this script cannot afford to get wrong, since every
      feature-state check below depends on having picked the right API.
    #>

    $isServer = Test-DeltaServerManagerAvailable

    $caption = $null
    try {
        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $caption = $osInfo.Caption
    }
    catch {
        $caption = $null
    }

    return [PSCustomObject]@{
        Type               = if ($isServer) { 'Server' } else { 'Client' }
        Caption            = $caption
        DetectionMechanism = if ($isServer) { 'ServerManager (Get-WindowsFeature)' } else { 'DISM (Get-WindowsOptionalFeature)' }
    }
}

function Get-DeltaIisRequiredFeatureDefinitions {
    <#
      The IIS role services/optional features every later phase of this
      installer depends on (docs\todo\TODO-setup-iis-enhancements.md,
      Phase 2's own "Required IIS Features" list) - detection only, never
      installed here (that is Phase 3's Install-WindowsFeature/Enable-
      WindowsOptionalFeature call, not this one). Server role service
      names (Get-WindowsFeature -Name) and client optional feature names
      (Get-WindowsOptionalFeature -FeatureName) genuinely differ for the
      same underlying capability - this table is the explicit mapping
      Phase 2's own roadmap warns must be maintained by hand, never
      assumed to be a mechanical prefix substitution.
    #>
    return @(
        [PSCustomObject]@{ Category = 'Core IIS';   Label = 'Web Server';                 ServerFeatureName = 'Web-Server';          ClientFeatureName = 'IIS-WebServerRole' }
        [PSCustomObject]@{ Category = 'Management'; Label = 'Management Console';         ServerFeatureName = 'Web-Mgmt-Console';    ClientFeatureName = 'IIS-ManagementConsole' }
        [PSCustomObject]@{ Category = 'Management'; Label = 'Management Scripting Tools'; ServerFeatureName = 'Web-Scripting-Tools'; ClientFeatureName = 'IIS-ManagementScriptingTools' }
        [PSCustomObject]@{ Category = 'HTTP';       Label = 'Static Content';             ServerFeatureName = 'Web-Static-Content';  ClientFeatureName = 'IIS-StaticContent' }
        [PSCustomObject]@{ Category = 'HTTP';       Label = 'Default Document';           ServerFeatureName = 'Web-Default-Doc';     ClientFeatureName = 'IIS-DefaultDocument' }
        [PSCustomObject]@{ Category = 'HTTP';       Label = 'HTTP Errors';                ServerFeatureName = 'Web-Http-Errors';     ClientFeatureName = 'IIS-HttpErrors' }
        [PSCustomObject]@{ Category = 'HTTP';       Label = 'HTTP Redirect';              ServerFeatureName = 'Web-Http-Redirect';   ClientFeatureName = 'IIS-HttpRedirect' }
        [PSCustomObject]@{ Category = 'HTTP';       Label = 'HTTP Logging';               ServerFeatureName = 'Web-Http-Logging';    ClientFeatureName = 'IIS-HttpLogging' }
        [PSCustomObject]@{ Category = 'HTTP';       Label = 'Request Monitor';            ServerFeatureName = 'Web-Request-Monitor'; ClientFeatureName = 'IIS-RequestMonitor' }
    )
}

function Test-DeltaIisFeatureInstalled {
    <#
      Whether a single required feature ($Definition, from
      Get-DeltaIisRequiredFeatureDefinitions) is currently installed -
      branches on $OperatingSystemType exactly as
      Get-DeltaIisOperatingSystemInfo decided, using Get-WindowsFeature on
      Server and Get-WindowsOptionalFeature -Online on Client. Never
      throws and never installs anything: an unrecognized feature name, a
      cmdlet that itself isn't available, or any other query failure is
      simply reported as not installed (Missing) - a query that fails is
      exactly as actionable to a later phase as a feature that is
      genuinely absent, and this phase's own requirement is a clean
      Installed/Missing report, not a third "unknown" state.
    #>
    param(
        [Parameter(Mandatory)][string]$OperatingSystemType,
        [Parameter(Mandatory)][PSCustomObject]$Definition
    )

    try {
        if ($OperatingSystemType -eq 'Server') {
            $feature = Get-WindowsFeature -Name $Definition.ServerFeatureName -ErrorAction Stop
            return [bool]($feature -and $feature.Installed)
        }

        $feature = Get-WindowsOptionalFeature -Online -FeatureName $Definition.ClientFeatureName -ErrorAction Stop
        return [bool]($feature -and $feature.State -eq 'Enabled')
    }
    catch {
        return $false
    }
}

function Get-DeltaIisVersion {
    <#
      The preferred, module-independent way to read an installed IIS
      instance's version (docs\todo\TODO-setup-iis-enhancements.md, Phase
      2's own "Preferred PowerShell APIs" section) -
      HKLM:\SOFTWARE\Microsoft\InetStp's own VersionString value, which
      works whether or not WebAdministration/IISAdministration/ServerManager
      is even installed. Returns $null (never throws) if IIS has never
      been installed on this machine - the key itself does not exist in
      that case. VersionString reads e.g. "Version 10.0" - the leading
      "Version " label is stripped so callers/the summary display just
      the bare number ("10.0"), matching this phase's own example output.
    #>
    $inetStpKeyPath = 'HKLM:\SOFTWARE\Microsoft\InetStp'
    if (-not (Test-Path -LiteralPath $inetStpKeyPath)) {
        return $null
    }

    $inetStpProperties = Get-ItemProperty -LiteralPath $inetStpKeyPath -Name 'VersionString' -ErrorAction SilentlyContinue
    $versionString = Get-RegistryPropertyValue -InputObject $inetStpProperties -Name 'VersionString'
    if (-not $versionString) {
        return $null
    }

    return ($versionString -replace '^Version\s+', '').Trim()
}

function Test-DeltaWebAdministrationModuleAvailable {
    <#
      Whether the WebAdministration PowerShell module - the prerequisite
      every later phase's own New-Website/New-WebBinding/Get-Website/etc.
      calls depend on (docs\todo\TODO-setup-iis-enhancements.md, Phase 2's
      own "Preferred PowerShell APIs" recommendation) - is available to be
      imported. Get-Module -ListAvailable never actually imports it: per
      this phase's own explicit "do not import it unless it exists"
      requirement, nothing here (or anywhere else in this phase) ever
      calls Import-Module.
    #>
    return [bool](Get-Module -ListAvailable -Name 'WebAdministration' -ErrorAction SilentlyContinue)
}

function Get-DeltaIisDetectionResult {
    <#
      The orchestrator for this whole section - collects every fact
      Phase 2 requires into one [PSCustomObject], so both the console
      summary below and any future phase that needs to reuse this exact
      detection (Phase 3's own "if some required role service is missing,
      install it" logic) read from a single source of truth rather than
      each re-deriving it independently.

      Installed is decided from TWO independent signals, deliberately not
      one: Get-DeltaIisVersion (the InetStp registry key, written once
      IIS has ever been installed) OR the "Web Server" role service/
      feature itself reporting Installed/Enabled. Matches this project's
      own "never trust one signal alone" discipline (see
      Get-DeltaNginxRuntimeState in setup-nginx.ps1) - an IIS installation
      that was only partially removed (the registry key lingering with
      the role service actually gone, or vice versa) is exactly the kind
      of disagreement a single signal would silently paper over.
    #>

    $osInfo  = Get-DeltaIisOperatingSystemInfo
    $version = Get-DeltaIisVersion

    # ServerFeatureName/ClientFeatureName are carried through onto each
    # result entry (not just Category/Label) so Phase 3's own
    # Install-DeltaIisFeatures can install exactly the missing ones
    # directly off this result - reusing this exact mapping rather than
    # re-deriving it a second time from Get-DeltaIisRequiredFeatureDefinitions.
    $featureDefinitions = Get-DeltaIisRequiredFeatureDefinitions
    $features = @(foreach ($definition in $featureDefinitions) {
        [PSCustomObject]@{
            Category          = $definition.Category
            Label             = $definition.Label
            ServerFeatureName = $definition.ServerFeatureName
            ClientFeatureName = $definition.ClientFeatureName
            Installed         = Test-DeltaIisFeatureInstalled -OperatingSystemType $osInfo.Type -Definition $definition
        }
    })

    $webServerFeatureInstalled = [bool](($features | Where-Object { $_.Label -eq 'Web Server' } | Select-Object -First 1).Installed)

    return [PSCustomObject]@{
        Installed                  = [bool]($version -or $webServerFeatureInstalled)
        Version                    = $version
        OperatingSystemType        = $osInfo.Type
        OperatingSystemCaption     = $osInfo.Caption
        DetectionMechanism         = $osInfo.DetectionMechanism
        WebAdministrationAvailable = Test-DeltaWebAdministrationModuleAvailable
        Features                   = $features
    }
}

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
    Write-Detail $(if ($Detection.WebAdministrationAvailable) { 'Available' } else { 'Missing' })
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
      or Show-DeltaIisInstallationSummary: querying WebAdministration/role
      service state before the pending restart completes could report a
      false failure (or a false success) for a module that genuinely does
      not finish registering until reboot, and this phase must never
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
        - WebAdministration still unavailable even though every required
          feature (including the two that ship it,
          Web-Scripting-Tools/IIS-ManagementScriptingTools) now reports
          Installed - a real, observed Windows behavior where the module
          does not always finish registering until a reboot even when
          neither installation API flagged one as required. Never imports
          WebAdministration here to check this more directly - per this
          phase's own "do not import WebAdministration yet unless needed
          strictly for verification" instruction, Get-Module -ListAvailable
          (Test-DeltaWebAdministrationModuleAvailable, Phase 2) is already
          sufficient and never imports anything either.
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

    if (-not $Detection.WebAdministrationAvailable) {
        Stop-Setup @'
Every required Microsoft IIS role service/feature now reports Installed, but the WebAdministration PowerShell module is still unavailable.

If Windows reported that a restart was required, restart the server and re-run this script - the module can fail to register until after reboot even when the role service itself already shows Installed.

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
    Write-Detail $(if ($Detection.WebAdministrationAvailable) { 'WebAdministration available' } else { 'WebAdministration unavailable' })
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
# system.webServer/proxy setting. Unlike Phase 2/3, this section DOES
# import WebAdministration - Phase 2/3's own "do not import it unless
# needed strictly for verification" guidance stops applying once a phase
# actually needs to configure something, and enabling server-wide proxying
# is exactly that. Still never creates, modifies, or deletes any IIS
# website, application pool, binding, or certificate - those remain later
# phases.

function Get-DeltaArrRequiredComponents {
    <#
      The two standalone Microsoft redistributables this installer's
      reverse-proxy setup depends on - detection only here, installed
      further down in this same section, never Windows Features
      (Get-WindowsFeature/Get-WindowsOptionalFeature do not know either
      of these exist, per this phase's own "Unlike every role service in
      Phase 3" objective). $DisplayNamePattern feeds the existing shared
      Get-InstalledProgramInfo (lib\DeltaInstaller.Common.ps1, the same
      registry-based Programs-and-Features lookup this project already
      uses for PostgreSQL detection, deliberately never Win32_Product) -
      no new detection mechanism invented for this phase.
    #>
    return @(
        [PSCustomObject]@{
            Name            = 'URL Rewrite'
            DisplayNamePattern = '*URL Rewrite*'
            # Confirmed directly on a real machine after installing this
            # MSI: URL Rewrite's native module lands in the shared
            # System32\inetsrv directory alongside IIS's own binaries.
            ModuleFilePath  = Join-Path -Path $env:WINDIR -ChildPath 'System32\inetsrv\rewrite.dll'
            PackageFileName = 'rewrite_amd64_en-US.msi'
            DownloadUrl     = $Script:UrlRewriteDownloadUrl
            LogFileName     = 'url-rewrite-install.log'
        }
        [PSCustomObject]@{
            Name            = 'Application Request Routing'
            DisplayNamePattern = '*Application Request Routing*'
            # NOT under System32\inetsrv, unlike URL Rewrite - confirmed
            # directly on a real machine after installing this MSI: ARR
            # ships its own separate installation directory under Program
            # Files. Getting this wrong was caught live during Phase 4's
            # own real-installation validation: Confirm-DeltaArrPostInstallState
            # correctly stopped the script rather than reporting a false
            # success, exactly the "never trust one signal/one path
            # assumption" outcome this project's own conservative
            # verification discipline exists to produce.
            ModuleFilePath  = Join-Path -Path ${env:ProgramFiles} -ChildPath 'IIS\Application Request Routing\requestRouter.dll'
            PackageFileName = 'requestRouter_amd64.msi'
            DownloadUrl     = $Script:ArrDownloadUrl
            LogFileName     = 'arr-install.log'
        }
    )
}

function Test-DeltaArrComponentInstalled {
    <#
      Whether a single component ($Definition, from
      Get-DeltaArrRequiredComponents) is currently installed - checked
      from TWO independent signals, but combined with AND, not OR, and
      deliberately the opposite combination from Phase 2's own
      Get-DeltaIisDetectionResult ("Installed" there is version-key OR
      feature-check). The two cases are not symmetric: Get-WindowsFeature
      is a live, authoritative query against Windows Feature state with
      no plausible "stale" reading, so either signal agreeing is already
      strong proof. A Programs-and-Features registry entry for an
      external MSI product is not that reliable on its own - this
      project has already hit exactly this failure mode for another
      BitRock/MSI-style installer (see the EDB/PostgreSQL uninstaller
      investigation: an uninstall can leave its registry entry behind
      without the product actually being usable). Requiring BOTH the
      registry entry AND the module DLL (Definition.ModuleFilePath - a
      per-component, fully-resolved path, NOT a shared directory assumed
      the same for both: confirmed directly on a real machine that URL
      Rewrite and ARR do not actually install to the same location at
      all, see Get-DeltaArrRequiredComponents's own per-entry comments)
      to agree avoids the worse failure mode here: a stale leftover
      registry entry alone silently convincing this phase to skip
      installing a reverse-proxy prerequisite Phase 6 will actually
      depend on. The opposite mistake (attempting to reinstall something
      already genuinely present) is comparatively harmless - msiexec's
      own repair/reinstall behavior is idempotent - so this phase
      deliberately biases toward that side.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Definition)

    $registryMatches = @(Get-InstalledProgramInfo -DisplayNamePattern $Definition.DisplayNamePattern)

    return [bool](($registryMatches.Count -gt 0) -and (Test-Path -LiteralPath $Definition.ModuleFilePath))
}

function Test-DeltaIisProxyEnabled {
    <#
      Whether system.webServer/proxy is currently enabled machine-wide
      (MACHINE/WEBROOT/APPHOST - applicationHost.config, not any single
      site's own web.config). Returns $false (never throws) if
      WebAdministration is unavailable or the property can't be read -
      matching Test-DeltaIisFeatureInstalled's own "a query failure
      reports the safe/negative state, not an exception" convention.
      Safe to call before ARR is even installed: system.webServer/proxy
      is a real, queryable configuration section regardless of whether
      ARR's own proxy engine is present to act on it, and reading a
      config property never modifies anything.
    #>
    if (-not (Test-DeltaWebAdministrationModuleAvailable)) {
        return $false
    }

    try {
        Import-Module WebAdministration -ErrorAction Stop
        $property = Get-WebConfigurationProperty -Filter 'system.webServer/proxy' -Name 'enabled' -PSPath 'MACHINE/WEBROOT/APPHOST' -ErrorAction Stop
        return [bool]$property.Value
    }
    catch {
        return $false
    }
}

function Get-DeltaArrDetectionResult {
    <#
      The Phase 4 orchestrator - mirrors Get-DeltaIisDetectionResult's own
      shape (Phase 2): collects every fact this phase needs into one
      [PSCustomObject], so the console summary, the confirmation prompt,
      the installer, and post-install verification all read from a single
      source of truth.
    #>
    $components = @(foreach ($definition in Get-DeltaArrRequiredComponents) {
        [PSCustomObject]@{
            Name      = $definition.Name
            Installed = Test-DeltaArrComponentInstalled -Definition $definition
        }
    })

    return [PSCustomObject]@{
        Components   = $components
        ProxyEnabled = Test-DeltaIisProxyEnabled
    }
}

function Show-DeltaArrDetectionSummary {
    <#
      A compact detection summary, reusing the existing dash-rule/
      Write-Detail formatting vocabulary rather than introducing a new
      style - mirrors Show-DeltaIisDetectionSummary's own layout
      philosophy (Phase 2) scaled down to this phase's own two components
      plus the proxy setting.
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
        Write-Host ''
    }
    Write-Host 'Reverse Proxy (system.webServer/proxy)'
    Write-Host ''
    Write-Detail $(if ($Detection.ProxyEnabled) { 'Enabled' } else { 'Disabled' })
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
      Lists both kinds of pending change explicitly (missing components
      to install, and/or the machine-wide proxy setting to enable) since
      either, both, or - if nothing is missing at all - neither can be
      true when this is called. $MissingComponents can legitimately be a
      genuinely empty array (proxy alone needs enabling) -
      [AllowEmptyCollection()] is required here: confirmed directly that
      [Parameter(Mandatory)] alone rejects an empty array with "Cannot
      bind argument... because it is an empty collection" even though an
      empty array is not $null.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$MissingComponents,
        [Parameter(Mandatory)][bool]$ProxyNeedsEnabling
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
        if ($ProxyNeedsEnabling) {
            Write-Host 'The following configuration change will be made:'
            Write-Host ''
            Write-Detail 'Enable system.webServer/proxy (machine-wide)'
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

function Confirm-DeltaArrPostInstallState {
    <#
      Post-installation verification - never trusts msiexec's own exit
      code alone as proof anything actually works, the same "do not trust
      the feature-installation command result alone" discipline Phase 3's
      own Confirm-DeltaIisPostInstallState already holds. Re-checks a
      FRESH Get-DeltaArrDetectionResult (the caller's responsibility to
      have taken after installation) rather than re-deriving state itself.

      Two independent, separately-worded failures:
        - Any required component still reporting Missing - listed by
          name, never summarized as a count.
        - system.webServer/proxy still reporting disabled after this
          function itself just attempted to enable it - stopped rather
          than silently retried, per this phase's own "do not continue
          if ARR installation or verification fails" requirement.
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

    if ($Detection.ProxyEnabled) {
        return
    }

    Write-Step 'Enabling the IIS reverse proxy (system.webServer/proxy)...'
    if (-not (Test-DeltaWebAdministrationModuleAvailable)) {
        Stop-Setup 'The WebAdministration PowerShell module is unavailable, so system.webServer/proxy cannot be enabled. Re-run Phase 3 (Microsoft IIS Installation) first.'
    }

    try {
        Import-Module WebAdministration -ErrorAction Stop
        Set-WebConfigurationProperty -Filter 'system.webServer/proxy' -Name 'enabled' -Value 'True' -PSPath 'MACHINE/WEBROOT/APPHOST' -ErrorAction Stop
    }
    catch {
        Stop-Setup "Failed to enable system.webServer/proxy: $($_.Exception.Message)"
    }

    if (-not (Test-DeltaIisProxyEnabled)) {
        Stop-Setup 'system.webServer/proxy was set, but verification still reports it as disabled. No further IIS setup will be attempted.'
    }

    Write-Success '    Reverse proxy enabled.'
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

    if ($missingComponents.Count -eq 0 -and -not $proxyNeedsEnabling) {
        Write-Host ''
        Write-Detail 'Microsoft IIS reverse-proxy prerequisites are already fully configured.'
        return [PSCustomObject]@{ Ready = $true }
    }

    if (-not (Read-DeltaArrInstallConfirmation -MissingComponents $missingComponents -ProxyNeedsEnabling $proxyNeedsEnabling)) {
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
# Website Discovery (docs\todo\TODO-setup-iis-enhancements.md, Phase 5)
# ---------------------------------------------------------------------------
#
# Only ever reached once Phase 4 has already reported Ready - see the
# orchestration block below. Read-only: never creates, modifies, or
# deletes any IIS website, application pool, binding, or certificate.
# Website/application pool creation is Phase 6's own responsibility, not
# this one.

function Get-DeltaIisSiteHostHeader {
    <#
      Reads the host header off $Site's own first binding
      (bindingInformation, e.g. "*:80:delta.example.org" -> the third
      colon-delimited segment) - the actual, already-configured value,
      never re-prompted (Resolve-DeltaWebsiteDomain is deliberately NOT
      called anywhere in this phase; see this section's own header for
      why). Returns $null (never throws) if the site has no binding, or a
      binding with an empty host header segment (e.g. "*:80:") - reported
      as "Unknown" by the caller, the same shape
      Get-DeltaNginxVHostSummary's own $result.ServerName uses in
      setup-nginx.ps1 for a vhost file that doesn't match its expected
      shape.
    #>
    param([Parameter(Mandatory)]$Site)

    try {
        $binding = Get-WebBinding -Name $Site.Name -ErrorAction Stop | Select-Object -First 1
    }
    catch {
        return $null
    }

    if (-not $binding -or -not $binding.bindingInformation) {
        return $null
    }

    $bindingParts = $binding.bindingInformation -split ':'
    if ($bindingParts.Count -ge 3 -and $bindingParts[2]) {
        return $bindingParts[2]
    }

    return $null
}

function Get-DeltaIisManagedWebsiteResult {
    <#
      Phase 5's own "match by an owned identifier, never by name alone"
      requirement - the direct IIS analogue of setup-nginx.ps1's own
      Get-DeltaNginxManagedProcesses (which matches by executable path,
      never by process name alone). Primary signal: a site named exactly
      $Script:DeltaIisSiteName exists at all (Get-Website). Secondary,
      defense-in-depth signal: that site's own PhysicalPath matches the
      DELTA installation path Phase 1 already resolved
      ($Script:DeltaInstallPath) - per this phase's own roadmap text,
      "cross-validate its physical path... against the resolved DELTA
      installation path from Phase 1." PhysicalPath is compared after
      expanding any environment-variable tokens IIS may have stored it
      with (confirmed directly: IIS's own Default Web Site stores
      "%SystemDrive%\inetpub\wwwroot" unexpanded) and trimming a trailing
      backslash, so formatting differences alone never cause a false
      negative.

      A name collision with something an administrator happened to
      independently name "DELTA" is unlikely but not impossible, and this
      installer must never assume ownership from the name alone - see
      this phase's own "Do not infer ownership" requirement. Returns a
      [PSCustomObject]: ManagedSite (the site, only once BOTH checks
      agree - $null otherwise) and CollidingSite (the name-matched site
      that failed the physical-path check, so the caller can warn about
      it specifically rather than silently treating it as "nothing
      found").
    #>

    try {
        $siteByName = Get-Website -Name $Script:DeltaIisSiteName -ErrorAction Stop
    }
    catch {
        $siteByName = $null
    }

    if (-not $siteByName) {
        return [PSCustomObject]@{ ManagedSite = $null; CollidingSite = $null }
    }

    $expandedPhysicalPath = [System.Environment]::ExpandEnvironmentVariables($siteByName.physicalPath).TrimEnd('\')
    $expectedInstallPath  = $Script:DeltaInstallPath.TrimEnd('\')

    if ($expandedPhysicalPath -eq $expectedInstallPath) {
        return [PSCustomObject]@{ ManagedSite = $siteByName; CollidingSite = $null }
    }

    return [PSCustomObject]@{ ManagedSite = $null; CollidingSite = $siteByName }
}

function Show-DeltaIisExistingWebsiteSummary {
    <#
      The "Existing DELTA IIS Website" management-style summary
      (docs\todo\TODO-setup-iis-enhancements.md, Phase 5's own example) -
      purely read-only reporting, exactly like Show-DeltaNginxManagementMenu's
      own status display in setup-nginx.ps1 (this function itself stays
      read-only; Show-DeltaIisManagementMenu, called immediately afterward
      from the orchestration block once a managed site is confirmed, is
      what actually offers an interactive menu of actions). Host Header/Application Pool/Status/Physical
      Path are all read from the SITE ITSELF (already-configured, live
      values), never re-prompted. Backend is the one field this phase's
      own roadmap explicitly calls out reusing Resolve-DeltaBackendPort
      for - reading the DELTA installation's current .env PORT value,
      since there is no generated web.config yet for this phase to read
      an actual proxy target back out of (that artifact does not exist
      until Phase 6).
    #>
    param([Parameter(Mandatory)]$Site)

    $hostHeader = Get-DeltaIisSiteHostHeader -Site $Site
    Resolve-DeltaBackendPort

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Existing DELTA IIS Website'
    Write-Host ''
    Write-Host 'Website'
    Write-Host ''
    Write-Detail $Site.name
    Write-Host ''
    Write-Host 'Status'
    Write-Host ''
    Write-Detail "$($Site.state)"
    Write-Host ''
    Write-Host 'Physical Path'
    Write-Host ''
    Write-Detail $Site.physicalPath
    Write-Host ''
    Write-Host 'Host Header'
    Write-Host ''
    Write-Detail $(if ($hostHeader) { $hostHeader } else { 'Unknown' })
    Write-Host ''
    Write-Host 'Backend'
    Write-Host ''
    Write-Detail "http://localhost:$($Script:DeltaBackendPort)"
    Write-Host ''
    Write-Host 'Application Pool'
    Write-Host ''
    Write-Detail $Site.applicationPool
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
}

function Show-DeltaIisSiteNameCollisionNotice {
    <#
      Shown only when a site literally named $Script:DeltaIisSiteName
      exists but its PhysicalPath disagrees with the resolved DELTA
      installation path - a real, if unlikely, name collision with an
      administrator's own unrelated site. Deliberately a distinct,
      specific notice rather than silently falling through to the generic
      "no managed site found" message, so the administrator understands
      exactly why this installer will not touch that site (and knows a
      later phase will refuse to reuse this name until the collision is
      resolved by hand).
    #>
    param([Parameter(Mandatory)]$Site)

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host "A website named '$($Script:DeltaIisSiteName)' already exists, but it does not appear to belong to this DELTA installation."
    Write-Host ''
    Write-Host 'Physical Path'
    Write-Host ''
    Write-Detail $Site.physicalPath
    Write-Host ''
    Write-Host 'Expected'
    Write-Host ''
    Write-Detail $Script:DeltaInstallPath
    Write-Host ''
    Write-Host 'This installer will not modify or remove this website.'
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
}

function Show-DeltaIisNoManagedWebsiteNotice {
    <#
      Fresh Installation (Phase 5's own example) - shown once no
      genuinely-managed DELTA site was found (whether because none exists
      at all, or because a name collision was already reported
      separately). Expected, successful completion, not an error -
      Website configuration itself is explicitly Phase 6's own
      responsibility, not this one.
    #>

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'No managed DELTA IIS website was found.'
    Write-Host ''
    Write-Host 'The IIS platform is ready.'
    Write-Host ''
    Write-Host 'Website configuration will be implemented'
    Write-Host 'in the next development phase.'
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
}

function Invoke-DeltaIisWebsiteDiscovery {
    <#
      The Phase 5 top-level orchestrator. Imports WebAdministration
      (guarded by Test-DeltaWebAdministrationModuleAvailable, exactly
      like Confirm-DeltaArrPostInstallState's own guard - Phase 4 having
      already reported Ready is what guarantees this succeeds in
      practice) since Get-Website/Get-WebBinding both require it - this
      is the one, single import for the whole phase, not repeated per
      helper function.
    #>

    if (-not (Test-DeltaWebAdministrationModuleAvailable)) {
        Stop-Setup 'The WebAdministration PowerShell module is unavailable, so IIS website discovery cannot proceed. Re-run Phase 3 (Microsoft IIS Installation) first.'
    }
    Import-Module WebAdministration -ErrorAction Stop

    $websiteResult = Get-DeltaIisManagedWebsiteResult

    if ($websiteResult.ManagedSite) {
        Show-DeltaIisExistingWebsiteSummary -Site $websiteResult.ManagedSite
        return
    }

    if ($websiteResult.CollidingSite) {
        Show-DeltaIisSiteNameCollisionNotice -Site $websiteResult.CollidingSite
    }

    Show-DeltaIisNoManagedWebsiteNotice
}

# ---------------------------------------------------------------------------
# Website Configuration (docs\todo\TODO-setup-iis-enhancements.md, Phase 6)
# ---------------------------------------------------------------------------
#
# Creates (or, once Get-DeltaIisManagedWebsiteResult confirms it is
# genuinely ours, updates) the managed DELTA IIS website - the direct IIS
# analogue of setup-nginx.ps1's own New-DeltaNginxConfiguration. Owns
# exactly: the DELTA application pool, the DELTA website, its physical
# path, the generated web.config, the ARR reverse-proxy rule inside it,
# and the HTTP binding. Does NOT own SSL/HTTPS/certificate import/runtime
# management/port-binding-conflict validation - those are later phases.
# An existing managed site is never deleted and recreated - only the
# artifacts this installer itself owns (web.config, application pool
# settings, its own single HTTP binding) are reconciled, and any
# unrelated IIS configuration (other bindings, other settings an
# administrator added by hand) is left completely untouched.

function Get-DeltaIisAppPoolAttributeValue {
    <#
      A single scalar Application Pool attribute, read via the IIS:\
      provider (Get-ItemProperty "IIS:\AppPools\<name>" -Name <attr>), can
      come back two different shapes depending on the attribute's own IIS
      schema type - confirmed directly against a real machine: string-
      enum-backed attributes like managedPipelineMode come back as a
      plain System.String, while managedRuntimeVersion/autoStart come
      back wrapped in a Microsoft.IIs.PowerShell.Framework.ConfigurationAttribute
      object whose actual value is under its own .Value property. Rather
      than hardcode which attributes need unwrapping (fragile if a future
      caller reads a different attribute this project hasn't tested yet),
      this checks for a .Value property generically and falls back to the
      raw result otherwise - the same defensive shape
      Get-RegistryPropertyValue already uses for the analogous "sometimes
      wrapped, sometimes not" problem with registry results.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Result)

    if ($null -eq $Result) {
        return $null
    }

    $valueProperty = $Result.PSObject.Properties['Value']
    if ($valueProperty) {
        return $valueProperty.Value
    }

    return $Result
}

function Confirm-DeltaIisAppPool {
    <#
      Application Pool (Phase 6's own section) - creates the dedicated
      DELTA application pool if it does not already exist, or reconciles
      just the three settings this installer owns
      (managedRuntimeVersion/managedPipelineMode/autoStart) if it does -
      never recreated, per this phase's own explicit "Do not recreate it"
      requirement. "No Managed Code" (an empty managedRuntimeVersion) is
      correct here since this pool only ever proxies to the Node.js
      backend via ARR, never runs managed application code itself - the
      same rationale this phase's own roadmap text gives for this exact
      choice, mirroring setup-nginx.ps1's own equivalent reasoning for why
      NGINX needs no application-level runtime of its own either.
    #>

    Write-Step "Configuring application pool '$($Script:DeltaIisAppPoolName)'..."

    $appPoolPath = "IIS:\AppPools\$($Script:DeltaIisAppPoolName)"

    if (-not (Test-Path -LiteralPath $appPoolPath)) {
        New-WebAppPool -Name $Script:DeltaIisAppPoolName | Out-Null
        Write-Detail "Created: $($Script:DeltaIisAppPoolName)"
    }
    else {
        Write-Detail "Already exists: $($Script:DeltaIisAppPoolName)"
    }

    # Ordered so console output (when something needs correcting) always
    # reports in the same sequence run to run, rather than whatever order
    # a hashtable happens to enumerate in.
    $desiredSettings = [ordered]@{
        managedRuntimeVersion = ''
        managedPipelineMode   = 'Integrated'
        autoStart             = $true
    }

    foreach ($settingName in $desiredSettings.Keys) {
        $desiredValue = $desiredSettings[$settingName]
        $currentValue = Get-DeltaIisAppPoolAttributeValue -Result (Get-ItemProperty -Path $appPoolPath -Name $settingName)

        if ("$currentValue" -ne "$desiredValue") {
            Set-ItemProperty -Path $appPoolPath -Name $settingName -Value $desiredValue
            Write-Detail "Updated $settingName -> '$desiredValue'"
        }
    }

    Write-Success '    Application pool configured.'
}

function New-DeltaIisWebConfig {
    <#
      web.config (Phase 6's own section) - writes $Script:DeltaInstallPath\
      web.config from the canonical templates\iis\web.config template via
      the shared Write-DeltaTemplateFile (lib\DeltaInstaller.Common.ps1) -
      never PowerShell string concatenation, per this phase's own explicit
      requirement, and never a second template-rendering implementation
      (Write-DeltaTemplateFile is exactly the function
      setup-nginx.ps1's own New-DeltaNginxConfiguration already calls for
      the identical load/substitute/write mechanics).

      The physical path is the DELTA installation directory itself
      ($Script:DeltaInstallPath) - not a second, IIS-specific application
      directory - per this phase's own "Do not create a second
      application directory. Reuse the existing installation."
      requirement, and exactly what Phase 5's own
      Get-DeltaIisManagedWebsiteResult already cross-validates a managed
      site's PhysicalPath against.

      Unconditionally overwrites whatever web.config might already be
      there - the same "no backup, no diff" posture
      New-DeltaNginxConfiguration already takes for delta.conf, since a
      hand-edited web.config would be silently discarded on the very next
      rerun regardless, and this phase's own design philosophy requires
      the generated configuration to be deterministic and idempotent, not
      preserved-if-customized.
    #>

    if (-not (Test-Path -LiteralPath $Script:DeltaIisWebConfigTemplate)) {
        Stop-Setup "Required configuration template not found: $($Script:DeltaIisWebConfigTemplate)"
    }

    $webConfigPath = Join-Path -Path $Script:DeltaInstallPath -ChildPath 'web.config'
    $replacements = @{
        '__DELTA_BACKEND_PORT__' = $Script:DeltaBackendPort
        '__DELTA_SERVER_NAME__'  = $Script:DeltaWebsiteDomain
    }

    Write-Step 'Writing DELTA reverse proxy configuration (web.config)...'
    Write-DeltaTemplateFile -TemplatePath $Script:DeltaIisWebConfigTemplate -DestinationPath $webConfigPath -Description 'DELTA web.config' -Replacements $replacements
}

function Confirm-DeltaIisWebsiteBinding {
    <#
      Creates or updates ONLY this installer's own single HTTP binding on
      port 80 for $SiteName - matched by protocol and port (the fixed
      values this installer always uses), never by replacing the site's
      entire bindings collection. Confirmed directly (a throwaway test
      site with a second, unrelated binding added alongside this
      installer's own) that Set-WebBinding -BindingInformation <old>
      -PropertyName bindingInformation -Value <new> updates exactly the
      one matched binding object and leaves every other binding on the
      site completely untouched - the mechanism this phase's own "Do not
      remove custom bindings" requirement depends on.

      Only ever called for an EXISTING managed site (Confirm-DeltaIisWebsite
      below) - a fresh site's own initial binding is already created
      correctly by New-Website's own -Port/-HostHeader parameters in one
      step, so calling this again immediately afterward would be
      redundant, not incorrect, but is skipped anyway for clarity.
    #>
    param(
        [Parameter(Mandatory)][string]$SiteName,
        [Parameter(Mandatory)][string]$Domain
    )

    $desiredBindingInformation = "*:80:$Domain"
    $existingBinding = Get-WebBinding -Name $SiteName -Protocol 'http' -ErrorAction SilentlyContinue |
        Where-Object { $_.bindingInformation -match '^\*:80:' } | Select-Object -First 1

    if (-not $existingBinding) {
        New-WebBinding -Name $SiteName -Protocol 'http' -Port 80 -HostHeader $Domain | Out-Null
        Write-Detail "Binding created: $desiredBindingInformation"
        return
    }

    if ($existingBinding.bindingInformation -ne $desiredBindingInformation) {
        Set-WebBinding -Name $SiteName -BindingInformation $existingBinding.bindingInformation -PropertyName 'bindingInformation' -Value $desiredBindingInformation | Out-Null
        Write-Detail "Binding updated: $($existingBinding.bindingInformation) -> $desiredBindingInformation"
    }
    else {
        Write-Detail "Binding already correct: $desiredBindingInformation"
    }
}

function Confirm-DeltaIisWebsite {
    <#
      Website Creation / Existing Website (Phase 6's own sections) - the
      one place this installer ever calls New-Website, and only when
      $ManagedSite is $null (Get-DeltaIisManagedWebsiteResult found
      nothing genuinely ours - a fresh install from this installer's own
      point of view). An existing managed site has its Application Pool
      association and its own single HTTP binding reconciled - never
      recreated, and no other site setting is ever touched.
    #>
    param([Parameter(Mandatory)][AllowNull()]$ManagedSite)

    Write-Step "Configuring website '$($Script:DeltaIisSiteName)'..."

    if (-not $ManagedSite) {
        New-Website -Name $Script:DeltaIisSiteName -PhysicalPath $Script:DeltaInstallPath `
            -ApplicationPool $Script:DeltaIisAppPoolName -Port 80 -HostHeader $Script:DeltaWebsiteDomain | Out-Null
        Write-Detail "Created: $($Script:DeltaIisSiteName)"
        return
    }

    Write-Detail "Already exists: $($Script:DeltaIisSiteName)"

    if ($ManagedSite.applicationPool -ne $Script:DeltaIisAppPoolName) {
        Set-ItemProperty -Path "IIS:\Sites\$($Script:DeltaIisSiteName)" -Name applicationPool -Value $Script:DeltaIisAppPoolName
        Write-Detail "Application pool association updated -> $($Script:DeltaIisAppPoolName)"
    }

    Confirm-DeltaIisWebsiteBinding -SiteName $Script:DeltaIisSiteName -Domain $Script:DeltaWebsiteDomain
}

function Confirm-DeltaIisWebsiteConfigurationResult {
    <#
      Verification (Phase 6's own dedicated section) - never trusts
      New-WebAppPool/New-Website/Set-WebBinding's own lack of a thrown
      error as proof of anything; re-reads IIS from scratch via a fresh
      Get-Website call and independently checks every fact this phase
      claims to have configured. Collects every failure at once rather
      than stopping at the first, the same shape
      Test-DeltaNginxStartupHealth already uses in setup-nginx.ps1, so a
      failed configuration is explained completely rather than with just
      its first symptom.

      Checks, all independently re-read from IIS (or the file system) -
      never assumed from what this run itself just tried to set:
        - The application pool exists.
        - The website itself exists (a hard Stop-Setup, not merely a
          collected failure - nothing else below is even meaningful to
          check against a site that isn't there at all).
        - Physical path matches $Script:DeltaInstallPath.
        - Application pool association matches.
        - web.config exists, and its own reverse-proxy rule's URL
          literally contains the CURRENT $Script:DeltaBackendPort - not
          merely "some port", so a stale value left over from a template
          write that silently failed to substitute correctly would be
          caught, not just "a file exists."
        - The host header (Get-DeltaIisSiteHostHeader, reused from
          Phase 5) matches the resolved website domain.
    #>

    Write-Step 'Verifying website configuration...'

    $site = Get-Website -Name $Script:DeltaIisSiteName -ErrorAction SilentlyContinue
    if (-not $site) {
        Stop-Setup "Verification failed: website '$($Script:DeltaIisSiteName)' does not exist after configuration."
    }

    $failures = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath "IIS:\AppPools\$($Script:DeltaIisAppPoolName)")) {
        $failures.Add("Application pool '$($Script:DeltaIisAppPoolName)' does not exist.")
    }

    $expandedPhysicalPath = [System.Environment]::ExpandEnvironmentVariables($site.physicalPath).TrimEnd('\')
    if ($expandedPhysicalPath -ne $Script:DeltaInstallPath.TrimEnd('\')) {
        $failures.Add("Physical path is '$($site.physicalPath)', expected '$($Script:DeltaInstallPath)'.")
    }

    if ($site.applicationPool -ne $Script:DeltaIisAppPoolName) {
        $failures.Add("Application pool is '$($site.applicationPool)', expected '$($Script:DeltaIisAppPoolName)'.")
    }

    $webConfigPath = Join-Path -Path $Script:DeltaInstallPath -ChildPath 'web.config'
    if (-not (Test-Path -LiteralPath $webConfigPath)) {
        $failures.Add("web.config does not exist at $webConfigPath.")
    }
    else {
        $webConfigContent = Get-Content -LiteralPath $webConfigPath -Raw
        $expectedProxyTarget = "http://localhost:$($Script:DeltaBackendPort)/"
        if (-not $webConfigContent.Contains($expectedProxyTarget)) {
            $failures.Add("web.config's reverse-proxy rule does not reference the resolved backend port ($($Script:DeltaBackendPort)).")
        }
    }

    $hostHeader = Get-DeltaIisSiteHostHeader -Site $site
    if ($hostHeader -ne $Script:DeltaWebsiteDomain) {
        $failures.Add("Host header is '$(if ($hostHeader) { $hostHeader } else { 'Unknown' })', expected '$($Script:DeltaWebsiteDomain)'.")
    }

    if ($failures.Count -gt 0) {
        $failureList = ($failures | ForEach-Object { "    $_" }) -join [Environment]::NewLine
        Stop-Setup @"
Website configuration verification failed.

$failureList

No further IIS setup will be attempted. Review the errors above and re-run this script.
"@
    }

    Write-Success '    Website configuration verified.'
    return $site
}

function Show-DeltaIisWebsiteConfigurationSummary {
    <#
      The Phase 6 summary (this phase's own "Summary" example) - reads
      every value from $Site (the freshly re-verified object
      Confirm-DeltaIisWebsiteConfigurationResult just returned) or the
      script-scoped values this same run just resolved
      ($Script:DeltaWebsiteDomain/$Script:DeltaBackendPort), never
      queried a third time. Deliberately says nothing about HTTPS - per
      this phase's own explicit "Do not mention HTTPS yet. That belongs
      to Phase 8." requirement.
    #>
    param([Parameter(Mandatory)]$Site)

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'DELTA IIS Website'
    Write-Host ''
    Write-Host 'Website'
    Write-Host ''
    Write-Detail $Site.name
    Write-Host ''
    Write-Host 'Application Pool'
    Write-Host ''
    Write-Detail $Site.applicationPool
    Write-Host ''
    Write-Host 'Host Header'
    Write-Host ''
    Write-Detail $Script:DeltaWebsiteDomain
    Write-Host ''
    Write-Host 'Backend'
    Write-Host ''
    Write-Detail "http://localhost:$($Script:DeltaBackendPort)"
    Write-Host ''
    Write-Host 'Physical Path'
    Write-Host ''
    Write-Detail $Site.physicalPath
    Write-Host ''
    Write-Host 'Configuration'
    Write-Host ''
    Write-Detail 'web.config generated'
    Write-Host ''
    Write-Host 'Status'
    Write-Host ''
    Write-Detail 'Ready for HTTP'
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
}

function Invoke-DeltaIisWebsiteConfiguration {
    <#
      The Phase 6 top-level orchestrator. Reuses
      Get-DeltaIisManagedWebsiteResult (Phase 5) again directly rather
      than threading Phase 5's own display-only orchestrator's result
      through - Phase 5 stays exactly as already implemented and
      validated (purely informational), and this is simply a second,
      independent, equally cheap read-only call to the same existing
      discovery logic, per this phase's own "Reuse the existing
      managed-site discovery logic" requirement.

      A CollidingSite (a website named $Script:DeltaIisSiteName that does
      NOT belong to this DELTA installation) is a hard stop here, not
      merely the informational notice Phase 5's own orchestrator already
      showed - the fixed site name this installer always uses is already
      claimed by something else, and per this phase's own "Do not infer
      ownership"/conservative posture, there is no safe way to proceed
      without an administrator resolving that collision by hand first.

      Resolve-DeltaWebsiteDomain and Resolve-DeltaBackendPort both run on
      EVERY invocation of this function, fresh or rerun alike - this
      phase has no separate "management menu" concept yet (that begins in
      a later Runtime Management phase), so unlike setup-nginx.ps1's own
      existing-installation branch (which skips domain/port resolution
      entirely in favor of reading its own already-generated vhost file
      back), this phase's own design is "always resolve fresh inputs, then
      reconcile IIS state to match them" - exactly what lets validation
      scenarios like a changed backend port or a changed website domain
      regenerate the configuration correctly on a plain rerun, with no
      separate "update" code path required.
    #>

    if (-not (Test-DeltaWebAdministrationModuleAvailable)) {
        Stop-Setup 'The WebAdministration PowerShell module is unavailable, so website configuration cannot proceed. Re-run Phase 3 (Microsoft IIS Installation) first.'
    }
    Import-Module WebAdministration -ErrorAction Stop

    $websiteResult = Get-DeltaIisManagedWebsiteResult

    if ($websiteResult.CollidingSite) {
        Stop-Setup @"
A website named '$($Script:DeltaIisSiteName)' already exists, but its physical path does not match this DELTA installation.

Existing Physical Path: $($websiteResult.CollidingSite.physicalPath)
Expected: $($Script:DeltaInstallPath)

Resolve this collision by hand (rename or remove the unrelated website) before re-running this script - website configuration will not proceed while the fixed '$($Script:DeltaIisSiteName)' site name is already claimed by something else.
"@
    }

    Write-PhaseBanner 'Public Website Domain'
    $Script:DeltaWebsiteDomain = Resolve-DeltaWebsiteDomain
    Write-Success "    Website domain: $($Script:DeltaWebsiteDomain)"

    Resolve-DeltaBackendPort

    Write-PhaseBanner 'Website Configuration'

    Confirm-DeltaIisAppPool

    if (-not (Test-Path -LiteralPath $Script:DeltaInstallPath)) {
        Stop-Setup "The DELTA installation directory no longer exists: $($Script:DeltaInstallPath)"
    }

    New-DeltaIisWebConfig
    Confirm-DeltaIisWebsite -ManagedSite $websiteResult.ManagedSite

    $verifiedSite = Confirm-DeltaIisWebsiteConfigurationResult
    Show-DeltaIisWebsiteConfigurationSummary -Site $verifiedSite
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

function Get-DeltaIisExistingHttpsCertificateState {
    <#
      Existing Certificate (this phase's own "Before importing" section) -
      whether the managed DELTA website already has an HTTPS binding, and
      whether the certificate store still has a resolvable certificate
      behind that binding's own thumbprint. A deliberate two-part check,
      mirroring Test-DeltaSslCertificateFilesExist's own "only treat this
      as existing when BOTH halves are genuinely present" requirement
      (there, both the .crt and .key file; here, both the binding AND a
      resolvable certificate behind it) - a binding whose thumbprint no
      longer resolves in the store is a distinct, `Broken`-like state
      (see Show-DeltaIisOrphanedCertificateBindingNotice), never silently
      folded into either "nothing configured" or "genuinely existing."

      Returns $null if there is no HTTPS binding at all. Otherwise a
      [PSCustomObject]: Binding (the raw Get-WebBinding result),
      Thumbprint (from the binding's own certificateHash - may be
      $null/empty), CertificateExists (bool, true only once both halves
      agree).
    #>

    $httpsBinding = Get-WebBinding -Name $Script:DeltaIisSiteName -Protocol 'https' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $httpsBinding) {
        return $null
    }

    $thumbprint = $httpsBinding.certificateHash
    $certificateExists = $false
    if ($thumbprint) {
        $certificateExists = [bool](Get-Item -LiteralPath "Cert:\LocalMachine\My\$thumbprint" -ErrorAction SilentlyContinue)
    }

    return [PSCustomObject]@{
        Binding           = $httpsBinding
        Thumbprint        = $thumbprint
        CertificateExists = $certificateExists
    }
}

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
      bindings" requirements. SNI (-SslFlags 1) is always enabled -
      required for a host-header-based HTTPS binding to coexist with any
      other HTTPS site already on the same IP/port.

      The certificate is associated by thumbprint via the binding
      object's own AddSslCertificate method - confirmed directly against
      a real IIS binding that calling it again on an already-bound
      binding with a DIFFERENT thumbprint correctly replaces the
      association in place (certificateHash updates, no duplicate
      binding created), so this same call handles both "no certificate
      yet" and "replace the existing certificate" without needing to
      branch on which case this run is in.
    #>
    param([Parameter(Mandatory)][string]$Thumbprint)

    Write-Step 'Configuring the HTTPS binding...'

    $desiredBindingInformation = "*:443:$($Script:DeltaWebsiteDomain)"
    $existingHttpsBinding = Get-WebBinding -Name $Script:DeltaIisSiteName -Protocol 'https' -ErrorAction SilentlyContinue |
        Where-Object { $_.bindingInformation -match '^\*:443:' } | Select-Object -First 1

    if (-not $existingHttpsBinding) {
        New-WebBinding -Name $Script:DeltaIisSiteName -Protocol 'https' -Port 443 -HostHeader $Script:DeltaWebsiteDomain -SslFlags 1 | Out-Null
        Write-Detail "Binding created: $desiredBindingInformation"
    }
    elseif ($existingHttpsBinding.bindingInformation -ne $desiredBindingInformation) {
        Set-WebBinding -Name $Script:DeltaIisSiteName -BindingInformation $existingHttpsBinding.bindingInformation -PropertyName 'bindingInformation' -Value $desiredBindingInformation | Out-Null
        Write-Detail "Binding updated: $($existingHttpsBinding.bindingInformation) -> $desiredBindingInformation"
    }
    else {
        Write-Detail "Binding already correct: $desiredBindingInformation"
    }

    $binding = Get-WebBinding -Name $Script:DeltaIisSiteName -Protocol 'https' -ErrorAction SilentlyContinue |
        Where-Object { $_.bindingInformation -eq $desiredBindingInformation } | Select-Object -First 1
    if (-not $binding) {
        Stop-Setup 'Failed to configure the HTTPS binding - the binding could not be found immediately after creation/update.'
    }

    try {
        # [void], not | Out-Null - confirmed directly this .NET method call's
        # own return value (even when $null) is exactly what leaked into
        # this function's caller's output stream when left unsuppressed,
        # silently corrupting Invoke-DeltaIisSslCertificateSetup's own
        # returned PSCustomObject into a multi-element array further up
        # the call chain (caught during real validation: "$result" ended
        # up not being the plain object it should have been).
        [void]$binding.AddSslCertificate($Thumbprint, 'my')
    }
    catch {
        Stop-Setup "Failed to associate the certificate with the HTTPS binding: $($_.Exception.Message)"
    }

    Write-Success '    HTTPS binding configured.'
}

function Confirm-DeltaIisSslConfigurationResult {
    <#
      Verification (this phase's own dedicated section) - never trusts
      Import-PfxCertificate/New-WebBinding/AddSslCertificate's own lack of
      a thrown error as proof of anything; re-reads the certificate store
      and IIS from scratch and independently checks every fact this phase
      claims to have configured, collecting every failure at once (the
      same shape Confirm-DeltaIisWebsiteConfigurationResult, Phase 6,
      already established) rather than stopping at the first.
    #>
    param([Parameter(Mandatory)][string]$ExpectedThumbprint)

    Write-Step 'Verifying SSL certificate configuration...'

    $failures = [System.Collections.Generic.List[string]]::new()

    if (-not (Get-Item -LiteralPath "Cert:\LocalMachine\My\$ExpectedThumbprint" -ErrorAction SilentlyContinue)) {
        $failures.Add("No certificate with thumbprint $ExpectedThumbprint exists in Cert:\LocalMachine\My.")
    }

    $binding = Get-WebBinding -Name $Script:DeltaIisSiteName -Protocol 'https' -ErrorAction SilentlyContinue |
        Where-Object { $_.bindingInformation -eq "*:443:$($Script:DeltaWebsiteDomain)" } | Select-Object -First 1

    if (-not $binding) {
        $failures.Add("No HTTPS binding exists for '$($Script:DeltaWebsiteDomain)' on port 443.")
    }
    else {
        if ($binding.certificateHash -ne $ExpectedThumbprint) {
            $failures.Add("The HTTPS binding references thumbprint '$($binding.certificateHash)', expected '$ExpectedThumbprint'.")
        }
        if (-not ([int]$binding.sslFlags -band 1)) {
            $failures.Add('SNI (Server Name Indication) is not enabled on the HTTPS binding.')
        }

        $hostHeaderPart = ($binding.bindingInformation -split ':')[2]
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

    if (-not (Test-DeltaWebAdministrationModuleAvailable)) {
        Stop-Setup 'The WebAdministration PowerShell module is unavailable, so SSL certificate setup cannot proceed. Re-run Phase 3 (Microsoft IIS Installation) first.'
    }
    Import-Module WebAdministration -ErrorAction Stop

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

function Get-DeltaIisSiteBackendPort {
    <#
      Best-effort read of the ACTUAL backend port from the site's own
      already-generated web.config (templates\iis\web.config's own
      <action type="Rewrite" url="http://localhost:__DELTA_BACKEND_PORT__/{R:1}" />
      shape, substituted by New-DeltaIisWebConfig) - the direct IIS
      analogue of Get-DeltaNginxVHostSummary's own proxy_pass regex against
      delta.conf in setup-nginx.ps1. Deliberately does NOT call
      Resolve-DeltaBackendPort (which re-reads the DELTA installation's
      current .env PORT value) - a management-mode display must show what
      IIS is actually configured to proxy to right now, which is not
      guaranteed to still match .env if it changed after the last
      configuration run. Returns $null (never throws) if web.config is
      missing or does not match the expected shape.
    #>
    param([Parameter(Mandatory)]$Site)

    $webConfigPath = Join-Path -Path $Site.physicalPath -ChildPath 'web.config'
    if (-not (Test-Path -LiteralPath $webConfigPath)) {
        return $null
    }

    $content = Get-Content -LiteralPath $webConfigPath -Raw
    $portMatch = [regex]::Match($content, 'http://localhost:(\d+)/')
    if ($portMatch.Success) {
        return [int]$portMatch.Groups[1].Value
    }

    return $null
}

function Start-DeltaIisManagedWebsite {
    <#
      Management menu action ("Start Website"). A no-op, reported plainly
      rather than calling Start-Website unnecessarily, if the site is
      already running - the same "check first, act only if needed" shape
      Invoke-DeltaNginxReload's own Running-state guard uses in
      setup-nginx.ps1.
    #>

    $site = Get-Website -Name $Script:DeltaIisSiteName -ErrorAction Stop
    if ($site.state -eq 'Started') {
        Write-Host ''
        Write-Detail 'The website is already running.'
        return
    }

    Write-Step 'Starting the website...'
    Start-Website -Name $Script:DeltaIisSiteName
    Write-Success '    Website started.'
}

function Stop-DeltaIisManagedWebsite {
    <#
      Management menu action ("Stop Website"). A no-op, reported plainly,
      if the site is already stopped.
    #>

    $site = Get-Website -Name $Script:DeltaIisSiteName -ErrorAction Stop
    if ($site.state -eq 'Stopped') {
        Write-Host ''
        Write-Detail 'The website is already stopped.'
        return
    }

    Write-Step 'Stopping the website...'
    Stop-Website -Name $Script:DeltaIisSiteName
    Write-Success '    Website stopped.'
}

function Restart-DeltaIisManagedWebsite {
    <#
      Management menu action ("Restart Website"). IIS has no single
      built-in "restart a website" cmdlet, so this composes
      Stop-DeltaIisManagedWebsite and Start-DeltaIisManagedWebsite -
      exactly the same composition Invoke-DeltaNginxRestart already uses
      in setup-nginx.ps1 for the same reason (NGINX has no single restart
      signal either). If the site was already stopped, this is simply
      equivalent to starting it.
    #>

    Stop-DeltaIisManagedWebsite
    Start-DeltaIisManagedWebsite
}

function Restart-DeltaIisManagedAppPool {
    <#
      Management menu action ("Restart Application Pool") - unlike
      website restart, IIS genuinely does provide a single, direct
      cmdlet for this (Restart-WebAppPool), so no composition is needed.
      Recycles the DELTA application pool's own worker process(es)
      without affecting the website's own started/stopped state.
    #>

    Write-Step 'Restarting the application pool...'
    Restart-WebAppPool -Name $Script:DeltaIisAppPoolName
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
      Management menu action ("Validate Configuration") - the IIS
      analogue of setup-nginx.ps1's own "Validate configuration" menu
      action (Test-DeltaNginxConfiguration, which runs `nginx -t`). Unlike
      Confirm-DeltaIisWebsiteConfigurationResult (Phase 6's own
      verification, which checks the live site against a freshly resolved
      $Script:DeltaWebsiteDomain/$Script:DeltaBackendPort that management
      mode deliberately never resolves - see this section's own header),
      this is a self-contained structural/integrity check of whatever is
      CURRENTLY deployed: does the application pool exist, does
      web.config exist and parse as well-formed XML and reference a
      recognizable backend port, does the site have at least one binding,
      and - if an HTTPS binding exists - does its referenced certificate
      still resolve in the store. Collects every problem found rather
      than stopping at the first, the same shape
      Confirm-DeltaIisWebsiteConfigurationResult already uses.
    #>

    Write-Step 'Validating configuration...'

    $site = Get-Website -Name $Script:DeltaIisSiteName -ErrorAction SilentlyContinue
    if (-not $site) {
        Write-Host ''
        Write-Host 'The DELTA website does not exist.' -ForegroundColor Red
        return
    }

    $problems = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath "IIS:\AppPools\$($site.applicationPool)")) {
        $problems.Add("Application pool '$($site.applicationPool)' does not exist.")
    }

    $webConfigPath = Join-Path -Path $site.physicalPath -ChildPath 'web.config'
    if (-not (Test-Path -LiteralPath $webConfigPath)) {
        $problems.Add("web.config does not exist at $webConfigPath.")
    }
    else {
        try {
            [xml](Get-Content -LiteralPath $webConfigPath -Raw) | Out-Null
        }
        catch {
            $problems.Add("web.config is not well-formed XML: $($_.Exception.Message)")
        }

        if (-not (Get-DeltaIisSiteBackendPort -Site $site)) {
            $problems.Add('web.config does not reference a recognizable backend port.')
        }
    }

    $bindings = @(Get-WebBinding -Name $Script:DeltaIisSiteName -ErrorAction SilentlyContinue)
    if ($bindings.Count -eq 0) {
        $problems.Add('The website has no bindings.')
    }

    $httpsState = Get-DeltaIisExistingHttpsCertificateState
    if ($httpsState -and -not $httpsState.CertificateExists) {
        $problems.Add("The HTTPS binding's certificate (thumbprint '$($httpsState.Thumbprint)') is no longer present in the certificate store.")
    }

    if ($problems.Count -eq 0) {
        Write-Success '    Configuration is valid.'
        return
    }

    Write-Host ''
    Write-Host 'Configuration problems found:' -ForegroundColor Red
    Write-Host ''
    foreach ($problem in $problems) {
        Write-Detail $problem
    }
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
      branching menu, this always offers the same seven options - IIS's
      own Start-Website/Stop-Website/Restart-WebAppPool cmdlets are
      idempotent no-ops to call against an already-matching state (and
      Start-DeltaIisManagedWebsite/Stop-DeltaIisManagedWebsite each still
      check first and report a no-op plainly rather than calling them
      needlessly), so there is no meaningful "wrong state to offer this
      action in" the way NGINX's own signal-based reload/stop genuinely
      have. The full three-signal Broken-state model setup-nginx.ps1 uses
      belongs to Phase 8's own later, separate runtime-management
      redesign - out of scope for this UX/orchestration-only adjustment.

      Loops until the administrator chooses Exit (bare Enter also exits),
      re-reading the site fresh at the top of every iteration so
      Status/Binding/Backend/Application Pool reflect whatever the
      just-run action actually changed, rather than a stale snapshot.
    #>

    if (-not (Test-DeltaWebAdministrationModuleAvailable)) {
        Stop-Setup 'The WebAdministration PowerShell module is unavailable, so website management cannot proceed. Re-run Phase 3 (Microsoft IIS Installation) first.'
    }
    Import-Module WebAdministration -ErrorAction Stop

    while ($true) {
        $currentSite = Get-Website -Name $Script:DeltaIisSiteName -ErrorAction SilentlyContinue
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
        Write-Detail $currentSite.name
        Write-Host ''
        Write-Host 'Status'
        Write-Host ''
        Write-Detail "$($currentSite.state)"
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
        Write-Detail $currentSite.applicationPool
        Write-Host ''
        Write-Host ('=' * $Script:BannerWidth)
        Write-Host ''

        Write-Host '1) Start Website'
        Write-Host '2) Stop Website'
        Write-Host '3) Restart Website'
        Write-Host '4) Restart Application Pool'
        Write-Host '5) Browse Website'
        Write-Host '6) Validate Configuration'
        Write-Host '7) Exit'
        Write-Host ''

        $choice = Read-Host -Prompt 'Choose an option [7]'
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '7' }

        switch ($choice.Trim()) {
            '1' { Start-DeltaIisManagedWebsite }
            '2' { Stop-DeltaIisManagedWebsite }
            '3' { Restart-DeltaIisManagedWebsite }
            '4' { Restart-DeltaIisManagedAppPool }
            '5' { Open-DeltaIisManagedWebsite -Scheme $scheme -HostHeader $hostHeader }
            '6' { Test-DeltaIisManagedWebsiteConfiguration }
            '7' { return }
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

    # Phase 4 - ARR/URL Rewrite prerequisites, then Phase 5 - website
    # discovery. Reached whether Phase 3 just installed something or found
    # everything already in place - both are equally valid "IIS is ready"
    # states. See each section's own header; nothing below this point runs
    # at all if the administrator declines, installation/verification
    # fails, or a restart is still pending.
    $arrResult = Invoke-DeltaArrSetup
    if (-not $arrResult.Ready) {
        exit 0
    }

    Invoke-DeltaIisWebsiteDiscovery

    # Management Mode - once a genuinely managed DELTA website already
    # exists, this script stops behaving like a first-time installer and
    # hands off to an interactive menu instead. See that section's own
    # header; reuses Get-DeltaIisManagedWebsiteResult again directly
    # rather than threading Phase 5's own result through - the same
    # established precedent Phase 6 below already follows. Nothing below
    # this point runs at all once a managed website exists.
    if ((Get-DeltaIisManagedWebsiteResult).ManagedSite) {
        Show-DeltaIisManagementMenu
        exit 0
    }

    # Phase 6 - creates the managed DELTA website itself. Reached only
    # when no managed website exists yet (fresh installs only - see
    # Management Mode above). Reuses Get-DeltaIisManagedWebsiteResult
    # again directly rather than threading Phase 5's own result through.
    Invoke-DeltaIisWebsiteConfiguration

    # Phase 7 - the Certificate Wizard. Cancel exits immediately here,
    # before the summary, mirroring setup-nginx.ps1's own Cancel path
    # (Show-SslCertificateCancelledNotice + exit 0, bypassing the summary
    # entirely). Decline ("No") and Keep both fall through to the summary
    # normally, since both are complete, successful outcomes.
    $sslResult = Invoke-DeltaIisSslCertificateSetup
    if ($sslResult.Cancelled) {
        exit 0
    }

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

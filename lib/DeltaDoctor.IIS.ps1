<#
.SYNOPSIS
    The single, authoritative implementation of IIS diagnostics/repair for
    DELTA - detection, the Doctor's own pass/fail check model, and the
    website-level repair actions, all in one place so doctor.ps1 (the CLI
    entry point) and setup-iis.ps1 (provisioning/lifecycle) consume the
    exact same functions rather than each carrying their own copy.

.DESCRIPTION
    This is a plain dot-sourced file, matching lib\DeltaInstaller.Common.ps1's
    own "no manifest, no Export-ModuleMember" philosophy - see that file's
    own header. Dot-sources lib\DeltaInstaller.Common.ps1 itself (a sibling
    file, resolved off this file's own $PSScriptRoot, never the caller's -
    see DeltaInstaller.Common.ps1's own header for why that distinction
    matters), so anything that dot-sources THIS file automatically gets
    every Common.ps1 helper too, without needing to dot-source it a second
    time itself.

    Architecture (the reason this file exists at all): originally, every
    function below lived in setup-iis.ps1 itself, and doctor.ps1 dot-sourced
    that entire script (behind a guard preventing its own orchestration
    block from running) purely to reach these functions. That worked, but
    left setup-iis.ps1 as the de facto owner of "is the DELTA IIS website
    correctly configured" even though doctor.ps1 was supposed to be the
    authoritative diagnostic utility. Promoting the functions themselves out
    to this shared file - rather than doctor.ps1 depending on setup-iis.ps1,
    or setup-iis.ps1 depending on doctor.ps1 - lets both depend on the same
    shared implementation instead:

        lib\DeltaDoctor.IIS.ps1
              ^              ^
              |              |
        doctor.ps1     setup-iis.ps1

    Owns, in order:
      - IIS/ARR/URL Rewrite detection (originally setup-iis.ps1's own Phase
        2/Phase 4 detection) - read-only, installs nothing.
      - DELTA website discovery (originally Phase 5) - read-only.
      - DELTA website repair/reconciliation (originally Phase 6's own
        Confirm-DeltaIisAppPool/New-DeltaIisWebConfig/Confirm-DeltaIisWebsite/
        Confirm-DeltaIisWebsiteBinding/Confirm-DeltaIisWebsiteConfigurationResult) -
        the only functions in this file that change anything on the
        machine, and even these only ever reconcile what's actually wrong
        (see each function's own header), never blindly recreate.
      - The HTTPS certificate state read (originally Phase 7's own
        "Existing Certificate" check) and the management-mode backend-port
        reader (Get-DeltaIisSiteBackendPort) - both read-only.
      - The Doctor's own check model (New-DeltaDoctorCheck/Show-DeltaDoctorCheck),
        the check-builder functions that turn the detection above into
        pass/fail rows, and Invoke-DeltaIisConfigurationCheckup - the single
        Detect -> Diagnose -> Report -> Offer Repair -> Validate Again cycle
        both doctor.ps1's own standalone run and setup-iis.ps1's own
        fresh-install/existing-site flows call identically.

    Explicitly NOT owned here (stays in setup-iis.ps1, since it is
    provisioning, not diagnosis/repair): installing missing IIS Windows
    Features, downloading/installing the ARR and URL Rewrite MSIs, the SSL
    Certificate Wizard (importing a certificate needs a file this Doctor is
    never handed), and the interactive management menu itself.

    Also owns, as of the Manual Reverse Proxy Handover feature: starting
    and stopping the DELTA-managed website itself (Start-DeltaIisManagedWebsite/
    Stop-DeltaIisManagedWebsite/Restart-DeltaIisManagedWebsite) and
    Get-DeltaIisRequiredPorts - promoted here, out of setup-iis.ps1's own
    original management-menu actions, once setup-nginx.ps1 needed the
    identical "stop the DELTA-managed website" action for its own side of
    that feature (stopping IIS so NGINX can bind the port instead). These
    are the only functions in this file, alongside the repair section
    above, that change live IIS state rather than only reading it - still
    consistent with "Doctor stays read-only" (see
    lib\DeltaDoctor.ReverseProxy.ps1's own header): this file has always
    housed repair/lifecycle actions, never only detection - see this
    file's own architecture note above.

    ARCHITECTURE CORRECTION (Reverse Proxy Handover Plan): stopping the
    DELTA-managed website alone does not guarantee a required port is
    actually released - IIS/http.sys reserves a port at the SITE level,
    and any OTHER started site with its own binding on that port (most
    commonly IIS's own stock "Default Web Site") keeps the reservation
    alive regardless. Get-DeltaIisReverseProxyHandoverPlan (this file's
    own Reverse Proxy Handover Plan section, further down) is Doctor's
    own answer to "what must actually be stopped, and is doing so even
    safe" - read-only planning, never execution - with
    Invoke-DeltaIisReverseProxyHandoverPlan as the one function that
    carries out an already-confirmed plan. See that section's own header
    for the full design.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeltaInstaller.Common.ps1')

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
#
# The fixed, well-known DELTA IIS site/application-pool identity and the
# canonical web.config template - originally setup-iis.ps1's own top-of-file
# constants, moved here because every function that reads them now lives in
# this file. $PSScriptRoot here is this file's own location (lib\), so the
# template path is resolved relative to the project root (this file's own
# parent directory) - never relative to whichever script happens to dot-
# source this file, matching lib\DeltaInstaller.Common.ps1's own
# $PSScriptRoot discipline.

$Script:DeltaIisSiteName = 'DELTA'
$Script:DeltaIisAppPoolName = 'DELTA'
$Script:DeltaIisWebConfigTemplate = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'templates\iis\web.config'

# Application Request Routing/URL Rewrite download URLs - moved here
# alongside Get-DeltaArrRequiredComponents (the only function that reads
# them directly; setup-iis.ps1's own Get-DeltaArrComponentPackage/
# Install-DeltaArrComponent only ever see them already resolved onto a
# component Definition object, never these variables themselves). These
# are the versions/URLs current when this detection was first implemented -
# re-verify against Microsoft's own Download Center/IIS.net pages before
# bumping either, the same caveat setup-nginx.ps1's own nginx.org download
# URL and setup.ps1's own EDB/PostGIS download URLs carry.
$Script:UrlRewriteDownloadUrl = 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi'
$Script:ArrDownloadUrl        = 'https://download.microsoft.com/download/E/9/8/E9849D6A-020E-47E4-9FD0-A023E99B54EB/requestRouter_amd64.msi'

# ---------------------------------------------------------------------------
# Microsoft IIS Detection
# ---------------------------------------------------------------------------
#
# Detection only - nothing in this section ever installs, enables, or
# configures anything. Get-WindowsFeature/Get-WindowsOptionalFeature -Online
# only ever query current state, Get-ItemProperty reads the IIS version
# straight out of the registry, and Get-Module -ListAvailable never imports
# WebAdministration - it only reports whether it COULD be imported. Actually
# installing anything IIS reports missing here remains setup-iis.ps1's own
# job (Install-DeltaIisFeatures) - this file only ever diagnoses.

function Test-DeltaServerManagerAvailable {
    <#
      Whether the ServerManager module (Get-WindowsFeature's own module -
      Windows Server only) is available on this machine - the same
      "simply Test-Path for the presence of the ServerManager module"
      check this project's own roadmap calls out as the way to decide which
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
      The IIS role services/optional features every later phase of the
      installer depends on - detection only, never installed here (that is
      setup-iis.ps1's own Install-WindowsFeature/Enable-WindowsOptionalFeature
      call, not this one). Server role service names (Get-WindowsFeature
      -Name) and client optional feature names (Get-WindowsOptionalFeature
      -FeatureName) genuinely differ for the same underlying capability -
      this table is the explicit mapping that must be maintained by hand,
      never assumed to be a mechanical prefix substitution.
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
      instance's version - HKLM:\SOFTWARE\Microsoft\InetStp's own
      VersionString value, which works whether or not WebAdministration/
      IISAdministration/ServerManager is even installed. Returns $null
      (never throws) if IIS has never been installed on this machine - the
      key itself does not exist in that case. VersionString reads e.g.
      "Version 10.0" - the leading "Version " label is stripped so
      callers/the summary display just the bare number ("10.0").
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
      every New-Website/New-WebBinding/Get-Website/etc. call in this file
      depends on - is available to be imported. Get-Module -ListAvailable
      never actually imports it: nothing here (or anywhere else in this
      section) ever calls Import-Module on its own initiative.
    #>
    return [bool](Get-Module -ListAvailable -Name 'WebAdministration' -ErrorAction SilentlyContinue)
}

function Get-DeltaIisDetectionResult {
    <#
      The orchestrator for this whole section - collects every fact IIS
      detection requires into one [PSCustomObject], so both setup-iis.ps1's
      own console summary and doctor.ps1's own IIS-prerequisite checklist
      read from a single source of truth rather than each re-deriving it
      independently.

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
    # result entry (not just Category/Label) so setup-iis.ps1's own
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

# ---------------------------------------------------------------------------
# Application Request Routing Detection
# ---------------------------------------------------------------------------
#
# Detection only, mirroring the IIS detection section above - installing
# whatever is found missing remains setup-iis.ps1's own job
# (Install-DeltaArrComponent).

function Get-DeltaArrRequiredComponents {
    <#
      The two standalone Microsoft redistributables this installer's
      reverse-proxy setup depends on - detection only here, installed by
      setup-iis.ps1, never Windows Features (Get-WindowsFeature/
      Get-WindowsOptionalFeature do not know either of these exist).
      $DisplayNamePattern feeds the existing shared Get-InstalledProgramInfo
      (lib\DeltaInstaller.Common.ps1, the same registry-based Programs-and-
      Features lookup this project already uses for PostgreSQL detection,
      deliberately never Win32_Product) - no new detection mechanism
      invented for this phase.
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
            # Files.
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
      from TWO independent signals, combined with AND, not OR: a
      Programs-and-Features registry entry for an external MSI product is
      not reliable on its own - this project has already hit exactly this
      failure mode for another BitRock/MSI-style installer (see the
      EDB/PostgreSQL uninstaller investigation: an uninstall can leave its
      registry entry behind without the product actually being usable).
      Requiring BOTH the registry entry AND the module DLL
      (Definition.ModuleFilePath - a per-component, fully-resolved path,
      confirmed directly that URL Rewrite and ARR do not actually install
      to the same location at all) to agree avoids a stale leftover
      registry entry alone silently convincing this phase to skip
      installing a reverse-proxy prerequisite the website configuration
      will actually depend on.
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
      The ARR/URL Rewrite detection orchestrator - mirrors
      Get-DeltaIisDetectionResult's own shape: collects every fact this
      phase needs into one [PSCustomObject], so setup-iis.ps1's own console
      summary, confirmation prompt, installer, and post-install
      verification, and doctor.ps1's own checklist, all read from a single
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

# ---------------------------------------------------------------------------
# DELTA Website Discovery
# ---------------------------------------------------------------------------
#
# Read-only: never creates, modifies, or deletes any IIS website,
# application pool, binding, or certificate.

function Get-DeltaIisSiteHostHeader {
    <#
      Reads the host header off $Site's own first binding
      (bindingInformation, e.g. "*:80:delta.example.org" -> the third
      colon-delimited segment) - the actual, already-configured value,
      never re-prompted. Returns $null (never throws) if the site has no
      binding, or a binding with an empty host header segment (e.g.
      "*:80:") - reported as "Unknown" by callers, the same shape
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
      "Match by an owned identifier, never by name alone" - the direct IIS
      analogue of setup-nginx.ps1's own Get-DeltaNginxManagedProcesses
      (which matches by executable path, never by process name alone).
      Primary signal: a site named exactly $Script:DeltaIisSiteName exists
      at all (Get-Website). Secondary, defense-in-depth signal: that
      site's own PhysicalPath matches the DELTA installation path already
      resolved ($Script:DeltaInstallPath). PhysicalPath is compared after
      expanding any environment-variable tokens IIS may have stored it
      with (confirmed directly: IIS's own Default Web Site stores
      "%SystemDrive%\inetpub\wwwroot" unexpanded) and trimming a trailing
      backslash, so formatting differences alone never cause a false
      negative.

      A name collision with something an administrator happened to
      independently name "DELTA" is unlikely but not impossible, and this
      installer must never assume ownership from the name alone. Returns
      a [PSCustomObject]: ManagedSite (the site, only once BOTH checks
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

function Get-DeltaIisSiteBackendPort {
    <#
      Best-effort read of the ACTUAL backend port from the site's own
      already-generated web.config (templates\iis\web.config's own
      <action type="Rewrite" url="http://localhost:__DELTA_BACKEND_PORT__/{R:1}" />
      shape, substituted by New-DeltaIisWebConfig) - the direct IIS
      analogue of Get-DeltaNginxVHostSummary's own proxy_pass regex against
      delta.conf in setup-nginx.ps1. Deliberately does NOT call
      Resolve-DeltaBackendPort (which re-reads the DELTA installation's
      current .env PORT value) - a management-mode/diagnostic display must
      show what IIS is actually configured to proxy to right now, which is
      not guaranteed to still match .env if it changed after the last
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

function Get-DeltaIisExistingHttpsCertificateState {
    <#
      Whether the managed DELTA website already has an HTTPS binding, and
      whether the certificate store still has a resolvable certificate
      behind that binding's own thumbprint. A deliberate two-part check,
      mirroring Test-DeltaSslCertificateFilesExist's own "only treat this
      as existing when BOTH halves are genuinely present" requirement
      (there, both the .crt and .key file; here, both the binding AND a
      resolvable certificate behind it) - a binding whose thumbprint no
      longer resolves in the store is a distinct, `Broken`-like state,
      never silently folded into either "nothing configured" or
      "genuinely existing."

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

# ---------------------------------------------------------------------------
# DELTA Website Repair/Reconciliation
# ---------------------------------------------------------------------------
#
# The only functions in this file that ever change IIS state - creates (or,
# once Get-DeltaIisManagedWebsiteResult confirms it is genuinely ours,
# updates) the managed DELTA IIS website: the dedicated application pool (No
# Managed Code, Integrated pipeline), the website (physical path = the
# DELTA installation directory itself, never a second application
# directory), its generated web.config (templates\iis\web.config, rendered
# via the shared Write-DeltaTemplateFile - never PowerShell string
# concatenation), and its single HTTP:80 binding. An existing managed site
# is never deleted and recreated - only the artifacts this installer itself
# owns (web.config, application pool settings, its own single HTTP binding)
# are reconciled, and any unrelated IIS configuration (other bindings,
# other settings an administrator added by hand) is left completely
# untouched.

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
      Creates the dedicated DELTA application pool if it does not already
      exist, or reconciles just the three settings this installer owns
      (managedRuntimeVersion/managedPipelineMode/autoStart) if it does -
      never recreated. "No Managed Code" (an empty managedRuntimeVersion)
      is correct here since this pool only ever proxies to the Node.js
      backend via ARR, never runs managed application code itself -
      mirroring setup-nginx.ps1's own equivalent reasoning for why NGINX
      needs no application-level runtime of its own either.
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
      Writes $Script:DeltaInstallPath\web.config from the canonical
      templates\iis\web.config template via the shared Write-DeltaTemplateFile
      (lib\DeltaInstaller.Common.ps1) - never PowerShell string
      concatenation, and never a second template-rendering implementation
      (Write-DeltaTemplateFile is exactly the function setup-nginx.ps1's
      own New-DeltaNginxConfiguration already calls for the identical
      load/substitute/write mechanics).

      The physical path is the DELTA installation directory itself
      ($Script:DeltaInstallPath) - not a second, IIS-specific application
      directory - exactly what Get-DeltaIisManagedWebsiteResult already
      cross-validates a managed site's PhysicalPath against.

      Unconditionally overwrites whatever web.config might already be
      there - the same "no backup, no diff" posture
      New-DeltaNginxConfiguration already takes for delta.conf, since a
      hand-edited web.config would be silently discarded on the very next
      rerun regardless, and the generated configuration is meant to be
      deterministic and idempotent, not preserved-if-customized.
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
      site completely untouched.

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
      The one place this file ever calls New-Website, and only when
      $ManagedSite is $null (Get-DeltaIisManagedWebsiteResult found
      nothing genuinely ours). An existing managed site has its
      Application Pool association and its own single HTTP binding
      reconciled - never recreated, and no other site setting is ever
      touched.
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
      Never trusts New-WebAppPool/New-Website/Set-WebBinding's own lack of
      a thrown error as proof of anything; re-reads IIS from scratch via a
      fresh Get-Website call and independently checks every fact this
      repair claims to have configured. Collects every failure at once
      rather than stopping at the first, the same shape
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
        - The host header (Get-DeltaIisSiteHostHeader) matches the
          resolved website domain.
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

function Repair-DeltaIisManagedWebsite {
    <#
      Composes Confirm-DeltaIisAppPool, New-DeltaIisWebConfig,
      Confirm-DeltaIisWebsite (which itself calls
      Confirm-DeltaIisWebsiteBinding for an existing site), and
      Confirm-DeltaIisWebsiteConfigurationResult - the single, shared "make
      the DELTA website match desired state" action both a genuinely fresh
      site (nothing configured yet) and an existing, partially-broken site
      go through identically. Every one of the functions it composes is
      idempotent and only changes what's actually wrong (see each
      function's own header) so calling them here, even when most of the
      site is already fine, is always safe.

      Domain resolution deliberately does NOT always call
      Resolve-DeltaWebsiteDomain (which prompts and defaults to
      $Script:DefaultDeltaWebsiteDomain, "localhost", on a bare Enter):
      that would be correct for a genuinely brand new site, but wrong for
      repairing one that already exists and already has a real, working
      domain - a careless Enter would silently rewrite that domain back to
      "localhost". Instead, this reads the domain the site is already
      configured with (Get-DeltaIisSiteHostHeader) whenever a managed site
      exists at all, and only prompts for the one case where there is
      truly no existing binding to read a domain from - a website that
      doesn't exist yet at all.

      Returns the freshly re-verified site (Confirm-DeltaIisWebsiteConfigurationResult
      itself throws via Stop-Setup if anything still doesn't check out) so
      the caller has a live object to report from, never this function's
      own unverified assumptions about what it just did.
    #>
    param([Parameter(Mandatory)][AllowNull()]$ManagedSite)

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to repair the DELTA IIS configuration. Re-run this script from an elevated PowerShell session.'
    }

    if (-not (Test-Path -LiteralPath $Script:DeltaInstallPath)) {
        Stop-Setup "The DELTA installation directory no longer exists: $($Script:DeltaInstallPath)"
    }

    $existingDomain = if ($ManagedSite) { Get-DeltaIisSiteHostHeader -Site $ManagedSite } else { $null }
    $Script:DeltaWebsiteDomain = if ($existingDomain) { $existingDomain } else { Resolve-DeltaWebsiteDomain }

    Resolve-DeltaBackendPort

    Confirm-DeltaIisAppPool
    New-DeltaIisWebConfig
    Confirm-DeltaIisWebsite -ManagedSite $ManagedSite

    return Confirm-DeltaIisWebsiteConfigurationResult
}

# ---------------------------------------------------------------------------
# DELTA Website Lifecycle - Start/Stop (Manual Reverse Proxy Handover)
# ---------------------------------------------------------------------------
#
# Alongside the repair section above, the other functions in this file that
# change live IIS state - promoted here from setup-iis.ps1's own original
# management-menu actions once setup-nginx.ps1 needed the identical "stop
# the DELTA-managed website" action for its own side of the Manual Reverse
# Proxy Handover feature (stopping IIS so NGINX can bind the port instead).
# Hardened in the process: the original versions matched by the fixed site
# name alone (Get-Website -Name $Script:DeltaIisSiteName), safe there only
# because setup-iis.ps1's own orchestration had already confirmed genuine
# DELTA ownership before ever reaching its menu; a caller with no such
# guarantee (setup-nginx.ps1) needs the same "match by an owned identifier,
# never by name alone" discipline this whole file is built around, so both
# functions now re-verify ownership themselves via
# Get-DeltaIisManagedWebsiteResult. Never touches W3SVC, IIS Management,
# ARR/URL Rewrite, or any other website - only ever the one DELTA-managed
# site.

function Start-DeltaIisManagedWebsite {
    <#
      Starts the DELTA-managed website only - never any other site, and
      never W3SVC/IIS itself. A no-op, reported plainly, if the site is
      already running, or if no DELTA-managed website exists at all right
      now (nothing to start). Shared lifecycle primitive - consumed by
      setup-iis.ps1's own management menu ("Start Website", "Restart
      Website"), and available to any future caller (uninstall.ps1, a
      future reverse-proxy.ps1) that needs the identical action.
    #>

    $websiteResult = Get-DeltaIisManagedWebsiteResult
    if (-not $websiteResult.ManagedSite) {
        Write-Host ''
        Write-Detail 'No DELTA-managed IIS website was found to start.'
        return
    }

    if ($websiteResult.ManagedSite.state -eq 'Started') {
        Write-Host ''
        Write-Detail 'The website is already running.'
        return
    }

    Write-Step 'Starting the website...'
    Start-Website -Name $websiteResult.ManagedSite.name
    Write-Success '    Website started.'
}

function Stop-DeltaIisManagedWebsite {
    <#
      The direct counterpart to Start-DeltaIisManagedWebsite, above - see
      that function's own header for the full rationale (promotion,
      ownership hardening, shared use). Stops ONLY the DELTA-managed
      website via Stop-Website -Name <site> - never Stop-Service W3SVC,
      never IIS Management, never ARR/URL Rewrite, and never any other
      site on the box. This is the exact function the Manual Reverse
      Proxy Handover feature's own setup-nginx.ps1 side calls when the
      administrator opts to stop IIS so NGINX can bind its ports instead.
    #>

    $websiteResult = Get-DeltaIisManagedWebsiteResult
    if (-not $websiteResult.ManagedSite) {
        Write-Host ''
        Write-Detail 'No DELTA-managed IIS website was found to stop.'
        return
    }

    if ($websiteResult.ManagedSite.state -eq 'Stopped') {
        Write-Host ''
        Write-Detail 'The website is already stopped.'
        return
    }

    Write-Step 'Stopping the website...'
    Stop-Website -Name $websiteResult.ManagedSite.name
    Write-Success '    Website stopped.'
}

function Restart-DeltaIisManagedWebsite {
    <#
      Management menu action ("Restart Website"). IIS has no single
      built-in "restart a website" cmdlet, so this composes
      Stop-DeltaIisManagedWebsite and Start-DeltaIisManagedWebsite -
      exactly the same composition Stop-DeltaManagedNginx's own caller
      (Invoke-DeltaNginxRestart) uses in setup-nginx.ps1 for the same
      reason (NGINX has no single restart signal either). If the site
      was already stopped, this is simply equivalent to starting it.
    #>

    Stop-DeltaIisManagedWebsite
    Start-DeltaIisManagedWebsite
}

function Get-DeltaIisRequiredPorts {
    <#
      The ports the DELTA-managed website should be listening on -
      the direct IIS analogue of lib\DeltaDoctor.NGINX.ps1's own
      Get-DeltaNginxRequiredPorts (see that function's own header for
      the full rationale): reflects an EXISTING site's real,
      already-configured bindings, never an in-memory flag from a live
      setup-iis.ps1 run. Port 80 always; 443 as well whenever
      Get-DeltaIisExistingHttpsCertificateState reports an HTTPS binding
      already exists on the managed site - regardless of whether that
      binding's own certificate still resolves, since the binding itself
      is what actually reserves the port. A site with no HTTPS binding
      (or no managed site at all yet) falls back to port 80 alone. Never
      assumes HTTPS.
    #>
    if (Get-DeltaIisExistingHttpsCertificateState) {
        return ,@(80, 443)
    }
    return ,@(80)
}

# ---------------------------------------------------------------------------
# Reverse Proxy Handover Plan
# ---------------------------------------------------------------------------
#
# ARCHITECTURE CORRECTION: stopping the DELTA-managed website alone does NOT
# guarantee a required port is actually released - IIS/http.sys reserves a
# port at the SITE level, and any OTHER started site with its own binding on
# that port (most commonly IIS's own stock "Default Web Site", which every
# fresh IIS installation creates bound to port 80 by default) keeps the
# reservation alive regardless of what happens to DELTA's own site. This
# section is what lets Doctor answer the real question - "what must
# actually be stopped for another provider to safely take ownership of
# these ports" - rather than every provider being asked to blindly "please
# stop yourself" and having that turn out not to be enough.
#
# Planning only - nothing here stops anything. Get-DeltaIisReverseProxyHandoverPlan
# returns a plain data object describing what WOULD need to happen and
# whether doing so automatically is even safe; Invoke-DeltaIisReverseProxyHandoverPlan
# (the one function here that actually calls Stop-Website) only ever runs
# when a provisioning script's own Invoke-DeltaReverseProxyHandover
# (lib\DeltaInstaller.Common.ps1) has already shown the plan to the
# administrator and received explicit confirmation - this file never
# decides on its own that stopping a site is warranted.

function Get-DeltaIisSiteBoundPorts {
    <#
      Every port $Site is bound to, parsed from its own live
      bindingInformation (e.g. "*:80:delta.example.org" -> 80) - the
      second colon-delimited segment, mirroring
      Get-DeltaIisSiteHostHeader's own parsing of the third. Protocol-
      agnostic (an http OR https binding on a given port both count) -
      the handover plan cares only about which ports are reserved, not
      which scheme reserved them. Returns a real, possibly-empty [int[]]
      array, never $null.
    #>
    param([Parameter(Mandatory)]$Site)

    $ports = [System.Collections.Generic.List[int]]::new()
    foreach ($binding in @(Get-WebBinding -Name $Site.name -ErrorAction SilentlyContinue)) {
        if (-not $binding.bindingInformation) { continue }
        $parts = $binding.bindingInformation -split ':'
        if ($parts.Count -ge 2) {
            $parsedPort = 0
            if ([int]::TryParse($parts[1], [ref]$parsedPort)) {
                $ports.Add($parsedPort)
            }
        }
    }
    return ,@($ports)
}

function Test-DeltaIisStockDefaultWebSite {
    <#
      Whether $Site is verifiably IIS's own untouched, out-of-the-box
      "Default Web Site" - name AND physical path both matching IIS's
      own stock identity, never the name alone. This is
      Get-DeltaIisManagedWebsiteResult's own "match by an owned
      identifier, never by name alone" discipline applied in reverse:
      that function verifies a site belongs to DELTA before trusting it;
      this one verifies a DIFFERENT site is safe to stop automatically
      before including it in a handover plan.

      A stock, never-customized Default Web Site commonly sits unused on
      a dedicated DELTA server, silently bound to port 80 by IIS's own
      installer default - safe to stop, since nothing depends on it. A
      site merely NAMED "Default Web Site" whose physical path was
      repointed at real content is no longer that placeholder - an
      administrator clearly repurposed it - so it is never treated as
      safe to stop automatically, and neither is any other site with a
      different name entirely (a shared IIS server's own real
      application, e.g. a corporate portal) - see this file's own
      Reverse Proxy Handover Plan section header for why that distinction
      is the entire point of this function.
    #>
    param([Parameter(Mandatory)]$Site)

    if ($Site.name -ne 'Default Web Site') {
        return $false
    }

    $expandedPhysicalPath = [System.Environment]::ExpandEnvironmentVariables($Site.physicalPath).TrimEnd('\')
    $stockPhysicalPath = [System.Environment]::ExpandEnvironmentVariables('%SystemDrive%\inetpub\wwwroot').TrimEnd('\')

    return $expandedPhysicalPath -eq $stockPhysicalPath
}

function Get-DeltaIisReverseProxyHandoverPlan {
    <#
      Doctor's own IIS-side answer to "what must actually be stopped for
      another provider to safely take ownership of $RequiredPorts" - see
      this file's own Reverse Proxy Handover Plan section header for the
      full architecture. $RequiredPorts is supplied by the caller (via
      lib\DeltaDoctor.ReverseProxy.ps1's own Get-DeltaReverseProxyHandoverPlan
      dispatcher) - the REQUESTING provider's own required ports (e.g.
      NGINX's), never IIS's own Get-DeltaIisRequiredPorts: what matters
      here is what the OTHER provider needs freed, not what IIS itself
      happens to be configured for.

      Enumerates every currently-Started IIS website with any binding on
      any of $RequiredPorts (Get-DeltaIisSiteBoundPorts) - a Stopped
      site's own binding is configuration only, not an active
      reservation, so it is never an occupant. For each occupant,
      classifies it as safe (the DELTA-managed site itself
      (Get-DeltaIisManagedWebsiteResult), or a verified-stock Default Web
      Site (Test-DeltaIisStockDefaultWebSite)) or unsafe (anything else -
      a real, independently-owned site this installer has no business
      touching).

      IsSafe is $true ONLY when every single occupant is safe - a single
      unsafe occupant (the "shared IIS server" scenario this feature's
      own design explicitly calls out - e.g. a corporate portal also
      bound to port 80) refuses the ENTIRE plan rather than offering to
      stop just the safe subset, since a partial stop would neither
      release the required ports nor be a decision this Doctor should
      make unilaterally. Reason explains which site(s) blocked it. Never
      includes W3SVC, WAS, or any other IIS platform service or process -
      this plan only ever names IIS WEBSITES, and only ever the specific
      ones enumerated above.

      Execute carries a scriptblock reference to
      Invoke-DeltaIisReverseProxyHandoverPlan (this file, below) - the
      only function that actually calls Stop-Website - so a caller
      (Invoke-DeltaReverseProxyHandover, lib\DeltaInstaller.Common.ps1)
      can carry out an already-confirmed plan without needing any
      IIS-specific knowledge of its own.
    #>
    param([Parameter(Mandatory)][int[]]$RequiredPorts)

    $websiteResult = Get-DeltaIisManagedWebsiteResult

    $occupyingSites = @(Get-Website | Where-Object {
        $boundPorts    = Get-DeltaIisSiteBoundPorts -Site $_
        $matchingPorts = @($boundPorts | Where-Object { $RequiredPorts -contains $_ })
        $_.state -eq 'Started' -and $matchingPorts.Count -gt 0
    })

    $safeSiteNames   = [System.Collections.Generic.List[string]]::new()
    $unsafeSiteNames = [System.Collections.Generic.List[string]]::new()

    foreach ($site in $occupyingSites) {
        $isDeltaManaged = $websiteResult.ManagedSite -and ($site.name -eq $websiteResult.ManagedSite.name)
        if ($isDeltaManaged -or (Test-DeltaIisStockDefaultWebSite -Site $site)) {
            $safeSiteNames.Add($site.name)
        }
        else {
            $unsafeSiteNames.Add($site.name)
        }
    }

    if ($unsafeSiteNames.Count -gt 0) {
        return [PSCustomObject]@{
            Provider       = 'IIS'
            Actions        = @()
            RequiredPorts  = $RequiredPorts
            ExpectedResult = 'Ports released'
            IsSafe         = $false
            Reason         = "$($unsafeSiteNames -join ', ') also occupies a required port and is not a DELTA-managed or recognized default IIS resource."
            SiteNames      = @()
            Execute        = ${function:Invoke-DeltaIisReverseProxyHandoverPlan}
        }
    }

    return [PSCustomObject]@{
        Provider       = 'IIS'
        Actions        = @($safeSiteNames | ForEach-Object { "Stop Website: $_" })
        RequiredPorts  = $RequiredPorts
        ExpectedResult = 'Ports released'
        IsSafe         = $true
        Reason         = $null
        SiteNames      = @($safeSiteNames)
        Execute        = ${function:Invoke-DeltaIisReverseProxyHandoverPlan}
    }
}

function Invoke-DeltaIisReverseProxyHandoverPlan {
    <#
      The only function in this section that changes anything - executes
      an ALREADY-CONFIRMED Handover Plan (Get-DeltaIisReverseProxyHandoverPlan,
      above) by stopping exactly $Plan.SiteNames, nothing else. Never
      called directly by a provisioning script - reached only via
      $Plan.Execute, invoked by Invoke-DeltaReverseProxyHandover
      (lib\DeltaInstaller.Common.ps1) after the administrator has already
      seen $Plan.Actions and confirmed. A no-op per site, reported
      plainly, if that site no longer exists or is already stopped by the
      time this actually runs (state can change between planning and
      execution) - never an error, since the end goal (that site not
      occupying the port) is already satisfied either way.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Plan)

    foreach ($siteName in $Plan.SiteNames) {
        $site = Get-Website -Name $siteName -ErrorAction SilentlyContinue
        if (-not $site) {
            continue
        }
        if ($site.state -eq 'Stopped') {
            Write-Host ''
            Write-Detail "Website '$siteName' is already stopped."
            continue
        }
        Write-Step "Stopping website '$siteName'..."
        Stop-Website -Name $siteName
        Write-Success "    Website '$siteName' stopped."
    }
}

# ---------------------------------------------------------------------------
# Doctor - check result model
# ---------------------------------------------------------------------------
#
# One small, generic shape every check below returns, so the report phase
# has exactly one way to render a check (Show-DeltaDoctorCheck) rather than
# each section formatting its own pass/fail output inline. Severity is
# 'Error' by default - only checks the Doctor genuinely cannot act on
# itself (backend connectivity, HTTPS certificate state) are ever marked
# 'Warning', so they're reported plainly without ever gating the repair
# prompt or the exit code the way a real configuration defect does.
#
# ASCII-only tags ([OK]/[FAIL]/[WARN]), not Unicode glyphs - this project's
# console output is deliberately ASCII-only end to end (setup.ps1,
# setup-nginx.ps1, setup-iis.ps1 never use anything else), so this follows
# that same convention rather than introducing the first Unicode-dependent
# output in the project.

function New-DeltaDoctorCheck {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][bool]$Passed,
        [ValidateSet('Error', 'Warning')][string]$Severity = 'Error',
        [string]$Detail
    )

    return [PSCustomObject]@{
        Label    = $Label
        Passed   = $Passed
        Severity = $Severity
        Detail   = $Detail
    }
}

function Show-DeltaDoctorCheck {
    param([Parameter(Mandatory)][PSCustomObject]$Check)

    if ($Check.Passed) {
        Write-Host "    [OK]   $($Check.Label)" -ForegroundColor Green
    }
    elseif ($Check.Severity -eq 'Warning') {
        Write-Host "    [WARN] $($Check.Label)" -ForegroundColor Yellow
    }
    else {
        Write-Host "    [FAIL] $($Check.Label)" -ForegroundColor Red
    }

    if ($Check.Detail) {
        Write-Host "           $($Check.Detail)" -ForegroundColor DarkGray
    }
}

function Show-DeltaDoctorChecks {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Checks)

    foreach ($check in $Checks) {
        Show-DeltaDoctorCheck -Check $check
    }
}

# ---------------------------------------------------------------------------
# Doctor - Detect: DELTA installation
# ---------------------------------------------------------------------------

function Get-DeltaDoctorInstallationChecks {
    <#
      Reuses Get-DeltaInstallPath (lib\DeltaInstaller.Common.ps1) directly -
      the exact same registry/legacy-path discovery Resolve-DeltaInstallation
      itself calls - rather than Resolve-DeltaInstallation, which Stop-Setups
      (throws) the instant nothing is found. A doctor's whole job is
      reporting what's wrong, not stopping at the first problem, so
      "installation not found" has to be a reportable, non-fatal result
      here, never a thrown error.
    #>

    $checks = [System.Collections.Generic.List[PSCustomObject]]::new()

    $installPath = Get-DeltaInstallPath
    $found = [bool]$installPath
    $checks.Add((New-DeltaDoctorCheck -Label 'DELTA installation found.' -Passed $found))

    if (-not $found) {
        return [PSCustomObject]@{ Found = $false; InstallPath = $null; EnvPath = $null; Checks = $checks }
    }

    $checks.Add((New-DeltaDoctorCheck -Label "Path: $installPath" -Passed $true))

    $envPath = Join-Path -Path $installPath -ChildPath '.env'
    $envExists = Test-Path -LiteralPath $envPath
    $checks.Add((New-DeltaDoctorCheck -Label '.env file found.' -Passed $envExists -Detail $(if (-not $envExists) { "Expected: $envPath" })))

    return [PSCustomObject]@{ Found = $true; InstallPath = $installPath; EnvPath = $envPath; Checks = $checks }
}

# ---------------------------------------------------------------------------
# Doctor - Diagnose: IIS prerequisites
# ---------------------------------------------------------------------------

function Get-DeltaDoctorIisPrerequisiteChecks {
    <#
      Pure reuse - Get-DeltaIisDetectionResult and Get-DeltaArrDetectionResult
      above are exactly the same detection setup-iis.ps1's own installation
      phases already run; this only reshapes their output into
      New-DeltaDoctorCheck rows. Never installs anything itself - a missing
      prerequisite here is reported, never auto-repaired: fixing it means
      re-running setup-iis.ps1, not the Doctor.
    #>

    $checks = [System.Collections.Generic.List[PSCustomObject]]::new()

    $iisDetection = Get-DeltaIisDetectionResult
    $checks.Add((New-DeltaDoctorCheck -Label 'IIS installed.' -Passed $iisDetection.Installed))

    $arrDetection = Get-DeltaArrDetectionResult
    foreach ($component in $arrDetection.Components) {
        $checks.Add((New-DeltaDoctorCheck -Label "$($component.Name) installed." -Passed $component.Installed))
    }
    $checks.Add((New-DeltaDoctorCheck -Label 'ARR proxy enabled.' -Passed $arrDetection.ProxyEnabled))

    $ready = $iisDetection.Installed -and
             (@($arrDetection.Components | Where-Object { -not $_.Installed }).Count -eq 0) -and
             $arrDetection.ProxyEnabled

    return [PSCustomObject]@{ Ready = $ready; Checks = $checks }
}

# ---------------------------------------------------------------------------
# Doctor - Diagnose: DELTA IIS website configuration
# ---------------------------------------------------------------------------

function Get-DeltaDoctorWebsiteChecks {
    <#
      The granular, per-fact checklist behind "Inspecting DELTA IIS
      configuration..." - built entirely from the read-only discovery
      functions above (Get-DeltaIisManagedWebsiteResult,
      Get-DeltaIisSiteHostHeader, Get-DeltaIisSiteBackendPort,
      Get-DeltaIisExistingHttpsCertificateState), never a second
      implementation of "what does this site currently look like."

      Distinct from setup-iis.ps1's own "Validate Configuration" management-
      menu action, which now simply calls this same function and displays
      its result - see that function's own header. This function returns
      one row PER FACT (website/app pool/binding/web.config/rewrite
      rule/backend port), matching the Doctor's own worked report example.

      Sets $CanRepair false only for the two situations
      Repair-DeltaIisManagedWebsite genuinely cannot act on safely: the
      fixed site name already belongs to an unrelated website (a real
      collision, never silently touched - see
      Get-DeltaIisManagedWebsiteResult's own header), or WebAdministration
      itself isn't available (IIS installation is not this function's job
      to fix). $NeedsRepair is true whenever at least one Error-severity
      check below actually failed - HTTPS state is always Warning-severity
      (see Get-DeltaIisExistingHttpsCertificateState's own header for why
      an orphaned certificate is reported, not auto-replaced: doing so
      needs a certificate file the Doctor is never handed).
    #>
    param([Parameter(Mandatory)][int]$ExpectedBackendPort)

    $checks = [System.Collections.Generic.List[PSCustomObject]]::new()

    if (-not (Test-DeltaWebAdministrationModuleAvailable)) {
        $checks.Add((New-DeltaDoctorCheck -Label 'Website exists.' -Passed $false -Detail 'The WebAdministration PowerShell module is unavailable. Run setup-iis.ps1 to install IIS first.'))
        return [PSCustomObject]@{ ManagedSite = $null; CanRepair = $false; NeedsRepair = $false; Checks = $checks }
    }
    Import-Module WebAdministration -ErrorAction Stop

    $websiteResult = Get-DeltaIisManagedWebsiteResult

    if ($websiteResult.CollidingSite) {
        $checks.Add((New-DeltaDoctorCheck -Label 'Website exists.' -Passed $false -Detail "A website named '$($Script:DeltaIisSiteName)' already exists, but its physical path ($($websiteResult.CollidingSite.physicalPath)) does not match this DELTA installation. Resolve this by hand before re-running the Doctor."))
        return [PSCustomObject]@{ ManagedSite = $null; CanRepair = $false; NeedsRepair = $false; Checks = $checks }
    }

    $site = $websiteResult.ManagedSite
    $checks.Add((New-DeltaDoctorCheck -Label 'Website exists.' -Passed ([bool]$site)))

    if (-not $site) {
        return [PSCustomObject]@{ ManagedSite = $null; CanRepair = $true; NeedsRepair = $true; Checks = $checks }
    }

    $appPoolExists = Test-Path -LiteralPath "IIS:\AppPools\$($site.applicationPool)"
    $checks.Add((New-DeltaDoctorCheck -Label 'Application Pool exists.' -Passed $appPoolExists))

    $httpBinding = Get-WebBinding -Name $site.name -Protocol 'http' -ErrorAction SilentlyContinue |
        Where-Object { $_.bindingInformation -match '^\*:80:' } | Select-Object -First 1
    $checks.Add((New-DeltaDoctorCheck -Label 'HTTP binding.' -Passed ([bool]$httpBinding)))

    $httpsState = Get-DeltaIisExistingHttpsCertificateState
    if (-not $httpsState) {
        $checks.Add((New-DeltaDoctorCheck -Label 'HTTPS binding.' -Passed $true -Severity 'Warning' -Detail 'Not configured (HTTP only).'))
    }
    elseif ($httpsState.CertificateExists) {
        $checks.Add((New-DeltaDoctorCheck -Label 'HTTPS binding.' -Passed $true))
    }
    else {
        $checks.Add((New-DeltaDoctorCheck -Label 'HTTPS binding.' -Passed $false -Severity 'Warning' -Detail "The certificate for thumbprint '$($httpsState.Thumbprint)' is no longer present in the certificate store. Run setup-iis.ps1 to reconfigure SSL."))
    }

    $webConfigPath = Join-Path -Path $site.physicalPath -ChildPath 'web.config'
    $webConfigExists = Test-Path -LiteralPath $webConfigPath
    $checks.Add((New-DeltaDoctorCheck -Label 'web.config exists.' -Passed $webConfigExists -Detail $(if (-not $webConfigExists) { "Expected: $webConfigPath" })))

    $rewriteRulePresent = $false
    $backendPortMatches = $false
    $configuredPort = $null
    if ($webConfigExists) {
        $webConfigContent = Get-Content -LiteralPath $webConfigPath -Raw
        $rewriteRulePresent = $webConfigContent -match '<rule\s+name="DELTA Reverse Proxy"'
        $configuredPort = Get-DeltaIisSiteBackendPort -Site $site
        $backendPortMatches = ($configuredPort -eq $ExpectedBackendPort)
    }
    $checks.Add((New-DeltaDoctorCheck -Label 'Rewrite rule present.' -Passed $rewriteRulePresent))
    $checks.Add((New-DeltaDoctorCheck -Label 'Backend rewrite target matches configured port.' -Passed $backendPortMatches `
        -Detail $(if ($webConfigExists -and -not $backendPortMatches) { "web.config targets $(if ($configuredPort) { $configuredPort } else { 'no recognizable port' }), expected $ExpectedBackendPort." })))

    $needsRepair = -not ($appPoolExists -and $httpBinding -and $webConfigExists -and $rewriteRulePresent -and $backendPortMatches)

    return [PSCustomObject]@{ ManagedSite = $site; CanRepair = $true; NeedsRepair = $needsRepair; Checks = $checks }
}

# ---------------------------------------------------------------------------
# Doctor - Diagnose: Backend connectivity
# ---------------------------------------------------------------------------

function Resolve-DeltaDoctorBackendPortInfo {
    <#
      A non-throwing counterpart to Resolve-DeltaBackendPort
      (lib\DeltaInstaller.Common.ps1): reuses the exact same primitives that
      function is itself built from (Get-EnvFileValue, Test-ValidTcpPort,
      $Script:DefaultDeltaBackendPort), but returns an invalid-value result
      instead of calling Stop-Setup - the Doctor reports a bad PORT value
      as a failed check, it doesn't abort the run because of one.
    #>
    param([Parameter(Mandatory)][string]$EnvPath)

    $rawPort = Get-EnvFileValue -Path $EnvPath -Key 'PORT'

    if ([string]::IsNullOrWhiteSpace($rawPort)) {
        return [PSCustomObject]@{ Valid = $true; Port = $Script:DefaultDeltaBackendPort; IsDefault = $true; RawValue = $null }
    }

    if (-not (Test-ValidTcpPort -Value $rawPort)) {
        return [PSCustomObject]@{ Valid = $false; Port = $null; IsDefault = $false; RawValue = $rawPort }
    }

    return [PSCustomObject]@{ Valid = $true; Port = [int]$rawPort; IsDefault = $false; RawValue = $rawPort }
}

function Get-DeltaDoctorBackendChecks {
    param([Parameter(Mandatory)][PSCustomObject]$PortInfo)

    $checks = [System.Collections.Generic.List[PSCustomObject]]::new()

    if (-not $PortInfo.Valid) {
        $checks.Add((New-DeltaDoctorCheck -Label "Backend port: invalid value '$($PortInfo.RawValue)' in .env." -Passed $false))
        return $checks
    }

    $portLabel = if ($PortInfo.IsDefault) { "Backend port: $($PortInfo.Port) (default)." } else { "Backend port: $($PortInfo.Port)." }
    $checks.Add((New-DeltaDoctorCheck -Label $portLabel -Passed $true))

    $responding = Test-DeltaTcpPortListening -Port $PortInfo.Port
    $checks.Add((New-DeltaDoctorCheck -Label 'Backend is responding.' -Passed $responding -Severity 'Warning' `
        -Detail $(if (-not $responding) { 'Nothing is listening on this port. Start DELTA before relying on the reverse proxy.' })))

    return $checks
}

# ---------------------------------------------------------------------------
# Doctor - the shared checkup cycle
# ---------------------------------------------------------------------------

function Invoke-DeltaIisConfigurationCheckup {
    <#
      The single, shared Detect(website) -> Diagnose -> Report -> Offer
      Repair -> Repair -> Validate Again cycle for the DELTA IIS website's
      OWN configuration - called identically by doctor.ps1's own standalone
      CLI and by setup-iis.ps1, for both a genuinely fresh site (nothing
      configured yet - every check below simply reports failing, and the
      offered repair creates it) and an existing site missing one or more
      of its own pieces (web.config, rewrite rule, binding, application
      pool). This is the one function that makes "there must be only ONE
      authoritative implementation of IIS diagnostics/repair" concrete:
      neither caller has its own copy of this cycle.

      Requires $Script:DeltaInstallPath/$Script:DeltaEnvPath already
      resolved (Resolve-DeltaInstallation) and IIS/ARR prerequisites
      already confirmed ready by the caller - this function only ever
      diagnoses/repairs the DELTA website's OWN configuration, never IIS
      installation or ARR/URL Rewrite (installing those remains
      setup-iis.ps1's own job, never this file's).

      Always interactive - prompts (Read-DeltaYesNoConfirmation) before
      repairing, exactly like every other confirmation in this project,
      whether the site is being created for the first time or repaired.
      Never silently modifies IIS. Returns a [PSCustomObject]: Healthy
      (bool - the FINAL state, after any repair attempt) and Site (the
      last-known site object, possibly $null).
    #>

    $portInfo = Resolve-DeltaDoctorBackendPortInfo -EnvPath $Script:DeltaEnvPath
    $expectedPort = if ($portInfo.Valid) { $portInfo.Port } else { -1 }

    Write-Step 'Inspecting DELTA IIS configuration...'
    $websiteResult = Get-DeltaDoctorWebsiteChecks -ExpectedBackendPort $expectedPort
    Show-DeltaDoctorChecks -Checks $websiteResult.Checks
    Write-Host ''

    Write-Step 'Checking backend connectivity...'
    $backendChecks = Get-DeltaDoctorBackendChecks -PortInfo $portInfo
    Show-DeltaDoctorChecks -Checks $backendChecks
    Write-Host ''

    $allChecks = @($websiteResult.Checks) + @($backendChecks)
    $errorCount = @($allChecks | Where-Object { -not $_.Passed -and $_.Severity -eq 'Error' }).Count
    $warningCount = @($allChecks | Where-Object { -not $_.Passed -and $_.Severity -eq 'Warning' }).Count

    Write-Host ('-' * $Script:BannerWidth)
    Write-Host "Errors   : $errorCount"
    Write-Host "Warnings : $warningCount"
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''

    if ($errorCount -eq 0) {
        Write-Success 'No problems found.'
        Write-Host ''
        return [PSCustomObject]@{ Healthy = $true; Site = $websiteResult.ManagedSite }
    }

    if (-not ($websiteResult.CanRepair -and $websiteResult.NeedsRepair)) {
        Write-Host 'These problems require manual attention (see above).' -ForegroundColor Yellow
        Write-Host ''
        return [PSCustomObject]@{ Healthy = $false; Site = $websiteResult.ManagedSite }
    }

    Write-Host 'Automatic repair is available.'
    $wantsRepair = Read-DeltaYesNoConfirmation -Body { Write-Host 'Repair now?' }

    if (-not $wantsRepair) {
        Write-Host ''
        Write-Detail 'No changes have been made.'
        Write-Host ''
        return [PSCustomObject]@{ Healthy = $false; Site = $websiteResult.ManagedSite }
    }

    Write-Host ''
    Write-PhaseBanner 'Repair'
    Repair-DeltaIisManagedWebsite -ManagedSite $websiteResult.ManagedSite | Out-Null

    Write-Host ''
    Write-Step 'Re-validating DELTA IIS configuration...'
    $revalidationPortInfo = Resolve-DeltaDoctorBackendPortInfo -EnvPath $Script:DeltaEnvPath
    $revalidationExpectedPort = if ($revalidationPortInfo.Valid) { $revalidationPortInfo.Port } else { -1 }
    $revalidation = Get-DeltaDoctorWebsiteChecks -ExpectedBackendPort $revalidationExpectedPort
    Show-DeltaDoctorChecks -Checks $revalidation.Checks
    Write-Host ''

    $remainingErrors = @($revalidation.Checks | Where-Object { -not $_.Passed -and $_.Severity -eq 'Error' }).Count
    if ($remainingErrors -eq 0) {
        Write-Success 'Repair complete. All checks passed.'
        Write-Host ''
        return [PSCustomObject]@{ Healthy = $true; Site = $revalidation.ManagedSite }
    }

    Write-Host 'Repair completed, but some problems remain (see above).' -ForegroundColor Yellow
    Write-Host ''
    return [PSCustomObject]@{ Healthy = $false; Site = $revalidation.ManagedSite }
}

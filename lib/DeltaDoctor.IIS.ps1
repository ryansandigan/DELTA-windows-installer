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
        ManagementAssemblyAvailable = Test-DeltaIisManagementAssemblyAvailable
        Features                   = $features
    }
}

# ---------------------------------------------------------------------------
# Microsoft.Web.Administration configuration backend
# ---------------------------------------------------------------------------
#
# The WebAdministration PowerShell module's own configuration cmdlets
# (Get/Set/Add/Remove/Clear-WebConfiguration*) go through a COM class that
# has been observed, on an otherwise fully updated and functional IIS
# installation (Windows Server 2022, Build 20348.5386 - IIS/URL Rewrite/ARR
# all installed, appcmd.exe working), to fail EVERY call with a COMException
# (REGDB_E_CLASSNOTREG, 0x80040154) - a broken WebAdministration PowerShell
# provider registration, not a broken IIS. Microsoft.Web.Administration.dll
# (the same .NET API appcmd.exe itself is built on) was confirmed working on
# that same machine - ServerManager, GetApplicationHostConfiguration,
# GetSection, and CommitChanges all succeed. Every configuration WRITE this
# project makes to system.webServer/proxy (enabled/preserveHostHeader) and
# system.webServer/rewrite/allowedServerVariables - all machine-wide
# (MACHINE/WEBROOT/APPHOST) settings, never scoped to a single site - goes
# through Microsoft.Web.Administration via the four helpers below instead of
# the WebAdministration module's own configuration cmdlets, and reads of
# those same three settings (immediately below) do too, so a single
# ServerManager transaction's own writes are never re-verified through a
# different, still-broken backend. Website/application-pool/binding
# management (New-Website, Get-WebBinding, Restart-WebAppPool, etc.) was
# initially left on the WebAdministration module, on the assumption that
# only the *-WebConfiguration* cmdlet family was affected - that assumption
# was wrong: every WebAdministration cmdlet goes through the same broken
# provider registration, so website/application-pool/binding management
# was later ported to Microsoft.Web.Administration too (see the "site/
# binding/application-pool primitives" section further below,
# Get-DeltaIisSiteByName/New-DeltaIisSite/etc.) - there is no remaining
# WebAdministration dependency anywhere in this project.

function Import-DeltaIisManagementAssembly {
    <#
      Loads Microsoft.Web.Administration.dll exactly once per session.
      Add-Type -AssemblyName resolves it from the GAC on a normal IIS
      installation; the explicit System32\inetsrv\ fallback covers a
      machine where it is present but not GAC-registered. Safe to call
      repeatedly - Add-Type against an already-loaded assembly is a no-op,
      never a duplicate-type error.
    #>
    try {
        Add-Type -AssemblyName 'Microsoft.Web.Administration' -ErrorAction Stop
        return
    }
    catch {
        # Fall through to the explicit path below.
    }

    $assemblyPath = Join-Path -Path $env:WINDIR -ChildPath 'System32\inetsrv\Microsoft.Web.Administration.dll'
    if (-not (Test-Path -LiteralPath $assemblyPath)) {
        throw "Microsoft.Web.Administration.dll could not be loaded and was not found at '$assemblyPath'. Verify Microsoft IIS is installed."
    }

    try {
        Add-Type -Path $assemblyPath -ErrorAction Stop
    }
    catch {
        throw "Failed to load Microsoft.Web.Administration.dll from '$assemblyPath': $($_.Exception.Message)"
    }
}

function Test-DeltaIisManagementAssemblyAvailable {
    <#
      Whether Microsoft.Web.Administration.dll can actually be loaded - the
      prerequisite every read/write in this section depends on now, the
      same "never throws, reports the safe/negative state" convention
      Test-DeltaWebAdministrationModuleAvailable itself established for the
      module it replaces here.
    #>
    try {
        Import-DeltaIisManagementAssembly
        return $true
    }
    catch {
        return $false
    }
}

function Get-DeltaIisServerManager {
    <#
      A fresh Microsoft.Web.Administration.ServerManager - never cached or
      reused across calls. A ServerManager instance does not observe
      configuration changes made by a DIFFERENT instance (including ones
      already committed by this same process moments earlier) until it is
      recreated, so every read/write in this section starts from its own
      new instance rather than risking a stale in-memory config tree.
    #>
    Import-DeltaIisManagementAssembly
    return New-Object -TypeName 'Microsoft.Web.Administration.ServerManager'
}

function Get-DeltaIisApplicationHostConfiguration {
    <#
      applicationHost.config - the machine-wide configuration root every
      section this project reads/writes here lives under, equivalent to
      the WebAdministration cmdlets' own MACHINE/WEBROOT/APPHOST -PSPath.
    #>
    param([Parameter(Mandatory)]$ServerManager)

    return $ServerManager.GetApplicationHostConfiguration()
}

function Get-DeltaIisConfigurationSection {
    <#
      $Configuration.GetSection($SectionPath) - equivalent to the
      WebAdministration cmdlets' own -Filter parameter. Never scoped to a
      specific site/location: every call site here only ever reads/writes
      the machine-wide section (no $Location argument to GetSection),
      matching the MACHINE/WEBROOT/APPHOST scope the cmdlets this replaces
      were always called with.
    #>
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][string]$SectionPath
    )

    return $Configuration.GetSection($SectionPath)
}

function Save-DeltaIisConfiguration {
    <#
      $ServerManager.CommitChanges() - equivalent to a WebAdministration
      configuration cmdlet returning without throwing. On failure, wraps
      the original exception (and its own InnerException, when present -
      CommitChanges failures are frequently a wrapped COMException) with
      exactly which section/property this caller was trying to change,
      rather than letting a bare "Exception calling CommitChanges" surface
      with no indication of which of possibly several in-memory changes on
      $ServerManager actually caused it.
    #>
    param(
        [Parameter(Mandatory)]$ServerManager,
        [Parameter(Mandatory)][string]$SectionName,
        [Parameter(Mandatory)][string]$PropertyDescription
    )

    try {
        $ServerManager.CommitChanges()
    }
    catch {
        $originalException = $_.Exception
        $innerException = $originalException.InnerException
        $innerText = if ($innerException) {
            " Inner exception ($($innerException.GetType().FullName)): $($innerException.Message)"
        }
        else {
            ''
        }
        throw "Failed to commit IIS configuration changes to section '$SectionName' (property: $PropertyDescription). Original exception ($($originalException.GetType().FullName)): $($originalException.Message).$innerText"
    }
}

# ---------------------------------------------------------------------------
# Microsoft.Web.Administration - site/binding/application-pool primitives
# ---------------------------------------------------------------------------
#
# The direct Microsoft.Web.Administration replacement for every remaining
# WebAdministration module cmdlet this project used to depend on
# (Get-Website/New-Website/Start-Website/Stop-Website/Get-WebBinding/
# New-WebBinding/Set-WebBinding/New-WebAppPool/Restart-WebAppPool/
# Remove-Website/Remove-WebAppPool) and the IIS:\ provider
# (Get-ItemProperty/Set-ItemProperty/Test-Path against IIS:\AppPools/
# IIS:\Sites) - see this project's own CLAUDE.md-adjacent history: the exact
# same REGDB_E_CLASSNOTREG COM failure that broke the *-WebConfiguration*
# cmdlets (see the section above) is not actually scoped to configuration
# cmdlets alone; every WebAdministration cmdlet goes through the identical
# broken provider registration. These helpers are the ONLY way any function
# in this project now touches a site, binding, or application pool.
#
# A ServerManager instance's own Sites/ApplicationPools collections only
# ever reflect what existed at the moment it was created - it does not
# observe changes committed by a DIFFERENT ServerManager instance,
# including ones this same process just committed moments earlier. Every
# helper below that MUTATES something therefore takes an already-created
# $ServerManager from its caller (so a single repair/removal pass shares
# one instance across its own several mutations, then commits once) rather
# than creating its own - but no function anywhere in this project ever
# reuses a Site/ApplicationPool object obtained from one ServerManager
# after a DIFFERENT ServerManager has since committed a change; the correct
# pattern is always: commit, then get a brand new ServerManager, then
# re-resolve by name before reading or mutating again.

function Get-DeltaIisSiteByName {
    <#
      $ServerManager.Sites[$Name] - the direct replacement for
      Get-Website -Name <name> -ErrorAction SilentlyContinue. The
      SiteCollection's own string-keyed indexer returns $null when no site
      by that name exists; it does not throw, so no try/catch is needed
      here (unlike Get-DeltaIisSiteState below, which reads a different,
      genuinely throwing property).
    #>
    param(
        [Parameter(Mandatory)]$ServerManager,
        [Parameter(Mandatory)][string]$Name
    )

    return $ServerManager.Sites[$Name]
}

function Get-DeltaIisAllSites {
    <#
      Every site currently known to $ServerManager - the direct replacement
      for a bare Get-Website (no -Name) call. Comma-protected so a
      zero- or one-site result crossing the return boundary stays a real
      array, never unwrapped to $null/a bare scalar (this project's own
      established return-boundary discipline - see
      Get-DeltaIisMissingFeatures in setup-iis.ps1 for the canonical
      explanation of why).
    #>
    param([Parameter(Mandatory)]$ServerManager)

    return ,@($ServerManager.Sites)
}

function Get-DeltaIisApplicationPoolByName {
    <#
      $ServerManager.ApplicationPools[$Name] - the direct replacement for
      Test-Path/Get-ItemProperty against IIS:\AppPools\<name>. Same
      null-on-miss, never-throws indexer behavior as Get-DeltaIisSiteByName.
    #>
    param(
        [Parameter(Mandatory)]$ServerManager,
        [Parameter(Mandatory)][string]$Name
    )

    return $ServerManager.ApplicationPools[$Name]
}

function Get-DeltaIisSiteState {
    <#
      $Site.State, defensively - confirmed directly that reading .State on
      a Microsoft.Web.Administration Site can THROW (a COMException) while
      the World Wide Web Publishing Service (W3SVC)/WAS isn't running,
      unlike the WebAdministration module's own .state convenience
      property, which simply reads back an empty string in that case and
      never throws. Every caller that used to do a plain
      $(if ($site.state) {...} else {'Unknown'}) falsy-check now goes
      through this instead - the one place that defensive fallback lives.
      Never throws; returns 'Unknown' (not $null) on any failure, matching
      what every caller already displayed for a blank WebAdministration
      .state.
    #>
    param([Parameter(Mandatory)]$Site)

    try {
        return "$($Site.State)"
    }
    catch {
        return 'Unknown'
    }
}

function Get-DeltaIisSitePhysicalPath {
    <#
      A site's own physical path, read the CORRECT Microsoft.Web.Administration
      way - unlike WebAdministration's Get-Website, which flattens this
      onto the site object directly as .physicalPath, the native Site
      object has no such property at all: physical path genuinely lives on
      the root application's own root virtual directory. Confirmed
      directly against Microsoft.Web.Administration's own object model -
      every site this project ever creates or inspects has exactly one
      application ("/") with exactly one virtual directory ("/"), the same
      assumption Confirm-DeltaIisWebsite's own New-DeltaIisSite call below
      always creates.
    #>
    param([Parameter(Mandatory)]$Site)

    return $Site.Applications['/'].VirtualDirectories['/'].PhysicalPath
}

function Get-DeltaIisSiteApplicationPoolName {
    <#
      A site's own associated application pool name - like
      Get-DeltaIisSitePhysicalPath immediately above, WebAdministration's
      Get-Website flattens this onto the site object as .applicationPool,
      but the native Site object has no such property: it genuinely lives
      on the root application, not the site itself.
    #>
    param([Parameter(Mandatory)]$Site)

    return $Site.Applications['/'].ApplicationPoolName
}

function Set-DeltaIisSiteApplicationPoolName {
    <#
      The corresponding setter - the direct replacement for
      Set-ItemProperty -Path "IIS:\Sites\<name>" -Name applicationPool
      -Value <pool>. Does not itself call CommitChanges - callers batch
      this alongside whatever else a single repair pass is changing and
      commit once via Save-DeltaIisConfiguration.
    #>
    param(
        [Parameter(Mandatory)]$Site,
        [Parameter(Mandatory)][string]$Name
    )

    $Site.Applications['/'].ApplicationPoolName = $Name
}

function Get-DeltaIisBindingCertificateThumbprint {
    <#
      A binding's own associated certificate thumbprint, as an uppercase
      hex string - the direct replacement for WebAdministration's
      Get-WebBinding, whose .certificateHash convenience property already
      comes back as a hex string. The native Microsoft.Web.Administration
      Binding.CertificateHash property is instead a raw byte[], so this is
      the one place that byte[] -> hex-string conversion happens; every
      other function in this project that needs a binding's own
      thumbprint goes through this rather than re-implementing the
      conversion. Returns $null (never throws) if the binding has no
      certificate hash at all (an HTTP binding, or an HTTPS binding never
      associated with a certificate).
    #>
    param([Parameter(Mandatory)]$Binding)

    $hashBytes = $Binding.CertificateHash
    if (-not $hashBytes -or $hashBytes.Length -eq 0) {
        return $null
    }

    return -join ($hashBytes | ForEach-Object { $_.ToString('X2') })
}

function Get-DeltaIisSiteBindingByProtocolAndPort {
    <#
      Finds a single binding on $Site matching $Protocol and $Port,
      parsed from the binding's own BindingInformation
      ("*:80:delta.example.org" -> port 80) - the direct replacement for
      every Get-WebBinding -Name <site> -Protocol <protocol> |
      Where-Object { bindingInformation -match/-eq ... } | Select-Object
      -First 1 call this project used to make. $Port is optional -
      omitted, this returns the first binding matching $Protocol alone
      (matching Get-DeltaIisExistingHttpsCertificateState's own original
      "first HTTPS binding, regardless of port" behavior). Returns $null
      if nothing matches.
    #>
    param(
        [Parameter(Mandatory)]$Site,
        [Parameter(Mandatory)][string]$Protocol,
        [int]$Port
    )

    foreach ($binding in $Site.Bindings) {
        if ($binding.Protocol -ne $Protocol) { continue }
        if (-not $PSBoundParameters.ContainsKey('Port')) { return $binding }

        $parts = $binding.BindingInformation -split ':'
        if ($parts.Count -ge 2) {
            $parsedPort = 0
            if ([int]::TryParse($parts[1], [ref]$parsedPort) -and $parsedPort -eq $Port) {
                return $binding
            }
        }
    }

    return $null
}

function New-DeltaIisSite {
    <#
      $ServerManager.Sites.Add(...) - the direct replacement for
      New-Website -Name -PhysicalPath -ApplicationPool -Port -HostHeader.
      Sites.Add's own 4-argument overload (name/protocol/bindingInformation/
      physicalPath) creates the site with exactly one binding and one
      application ("/"); the application pool association is set
      immediately afterward on that same root application, exactly the
      shape Get-DeltaIisSiteApplicationPoolName/Get-DeltaIisSitePhysicalPath
      above always assume every site this project manages has. Does not
      itself call CommitChanges - the caller commits once after this and
      any other change in the same repair pass.
    #>
    param(
        [Parameter(Mandatory)]$ServerManager,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$PhysicalPath,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$HostHeader,
        [Parameter(Mandatory)][string]$ApplicationPoolName
    )

    $bindingInformation = "*:${Port}:${HostHeader}"
    $site = $ServerManager.Sites.Add($Name, 'http', $bindingInformation, $PhysicalPath)
    $site.Applications['/'].ApplicationPoolName = $ApplicationPoolName

    return $site
}

function New-DeltaIisApplicationPool {
    <#
      $ServerManager.ApplicationPools.Add($Name) - the direct replacement
      for New-WebAppPool -Name <name>. Does not itself call
      CommitChanges - see New-DeltaIisSite's own header for why.
    #>
    param(
        [Parameter(Mandatory)]$ServerManager,
        [Parameter(Mandatory)][string]$Name
    )

    return $ServerManager.ApplicationPools.Add($Name)
}

function Start-DeltaIisSite {
    <#
      $Site.Start() - the direct replacement for Start-Website -Name
      <name>. A live runtime action mediated by WAS, exactly like the
      WebAdministration cmdlet it replaces - never requires
      CommitChanges, and never touches applicationHost.config.
    #>
    param([Parameter(Mandatory)]$Site)

    $Site.Start() | Out-Null
}

function Stop-DeltaIisSite {
    <#
      $Site.Stop() - the direct counterpart to Start-DeltaIisSite, the
      direct replacement for Stop-Website -Name <name>.
    #>
    param([Parameter(Mandatory)]$Site)

    $Site.Stop() | Out-Null
}

function Restart-DeltaIisApplicationPool {
    <#
      $Pool.Recycle() - the direct replacement for Restart-WebAppPool
      -Name <name>. Like Start/Stop-DeltaIisSite, a live runtime action -
      never requires CommitChanges.
    #>
    param([Parameter(Mandatory)]$Pool)

    $Pool.Recycle() | Out-Null
}

function Add-DeltaIisCertificateToBinding {
    <#
      $Binding.AddSslCertificate($Thumbprint, $StoreName) - a native
      method on Microsoft.Web.Administration.Binding itself (added for IIS
      8's SNI support), not something WebAdministration's Get-WebBinding
      merely bolted on - so this carries over unchanged from
      setup-iis.ps1's own original call, now reached with a binding
      obtained via ServerManager instead. [void], never | Out-Null -
      confirmed directly (setup-iis.ps1's own Confirm-DeltaIisHttpsBinding,
      the only caller) that this method's own return value, left
      unsuppressed, leaks into and corrupts the caller's own returned
      object further up the call chain - see that call site's own comment
      for the full story. Requires the change to already be committed
      (the binding must genuinely exist in applicationHost.config) before
      this is called, exactly like the WebAdministration-based version
      always required a fresh Get-WebBinding re-fetch first.
    #>
    param(
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)][string]$Thumbprint,
        [Parameter(Mandatory)][string]$StoreName
    )

    [void]$Binding.AddSslCertificate($Thumbprint, $StoreName)
}

function Remove-DeltaIisSite {
    <#
      $ServerManager.Sites.Remove($Site) + commit - the direct replacement
      for Remove-Website -Name <name>. Removing a site this way also
      removes every one of its own bindings and its application's own
      pool ASSOCIATION in the same step (never the pool itself - a shared
      pool may still be legitimately used by another site, exactly the
      distinction uninstall.ps1's own Uninstall-DeltaIis already relies
      on), matching Remove-Website's own documented behavior.
    #>
    param(
        [Parameter(Mandatory)]$ServerManager,
        [Parameter(Mandatory)]$Site
    )

    $ServerManager.Sites.Remove($Site)
    Save-DeltaIisConfiguration -ServerManager $ServerManager -SectionName 'Sites' -PropertyDescription "remove site '$($Site.Name)'"
}

function Remove-DeltaIisApplicationPool {
    <#
      $ServerManager.ApplicationPools.Remove($Pool) + commit - the direct
      replacement for Remove-WebAppPool -Name <name>.
    #>
    param(
        [Parameter(Mandatory)]$ServerManager,
        [Parameter(Mandatory)]$Pool
    )

    $ServerManager.ApplicationPools.Remove($Pool)
    Save-DeltaIisConfiguration -ServerManager $ServerManager -SectionName 'ApplicationPools' -PropertyDescription "remove application pool '$($Pool.Name)'"
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
      site's own web.config), read via Microsoft.Web.Administration - see
      this section's own header for why, not the WebAdministration
      module's own Get-WebConfigurationProperty. Returns $false (never
      throws) if Microsoft.Web.Administration is unavailable or the
      property can't be read - matching Test-DeltaIisFeatureInstalled's
      own "a query failure reports the safe/negative state, not an
      exception" convention. Safe to call before ARR is even installed:
      system.webServer/proxy is a real, queryable configuration section
      regardless of whether ARR's own proxy engine is present to act on
      it, and reading a config property never modifies anything.
    #>
    if (-not (Test-DeltaIisManagementAssemblyAvailable)) {
        return $false
    }

    try {
        $serverManager = Get-DeltaIisServerManager
        $configuration = Get-DeltaIisApplicationHostConfiguration -ServerManager $serverManager
        $section = Get-DeltaIisConfigurationSection -Configuration $configuration -SectionPath 'system.webServer/proxy'
        return [bool]$section.GetAttributeValue('enabled')
    }
    catch {
        return $false
    }
}

function Test-DeltaIisPreserveHostHeaderEnabled {
    <#
      Whether system.webServer/proxy's own preserveHostHeader is currently
      enabled machine-wide - same MACHINE/WEBROOT/APPHOST scope,
      Microsoft.Web.Administration backend, and "never throws, reports the
      safe/negative state" convention Test-DeltaIisProxyEnabled
      (immediately above) already establishes, just reading a different
      property of the same configuration section. Required alongside
      ProxyEnabled, never merged into a single "reverse proxy enabled"
      boolean: ARR's own default for this property is False, and DELTA
      depends on the original Host header surviving the proxy hop
      (sessions, CSRF, Remix action routing) - a real, confirmed cause of
      a DELTA login failure on a machine where only `enabled` had been
      set.
    #>
    if (-not (Test-DeltaIisManagementAssemblyAvailable)) {
        return $false
    }

    try {
        $serverManager = Get-DeltaIisServerManager
        $configuration = Get-DeltaIisApplicationHostConfiguration -ServerManager $serverManager
        $section = Get-DeltaIisConfigurationSection -Configuration $configuration -SectionPath 'system.webServer/proxy'
        return [bool]$section.GetAttributeValue('preserveHostHeader')
    }
    catch {
        return $false
    }
}

# The three server variables templates\iis\web.config's own DELTA Reverse
# Proxy rule sets (X-Forwarded-Proto/Host/Port) - the one place this list
# is defined, consumed both by the machine-wide allow-list check below and
# by setup-iis.ps1's own Confirm-DeltaArrPostInstallState (which adds
# whichever of these three are still missing).
$Script:DeltaIisRequiredForwardedServerVariables = @('HTTP_X_FORWARDED_PROTO', 'HTTP_X_FORWARDED_HOST', 'HTTP_X_FORWARDED_PORT')

function Get-DeltaIisAllowedServerVariableNames {
    <#
      The names currently present in system.webServer/rewrite/allowedServerVariables
      machine-wide (MACHINE/WEBROOT/APPHOST), read via
      Microsoft.Web.Administration - see this section's own header for why,
      not the WebAdministration module's own Get-WebConfigurationProperty.
      Always a real array, never $null, matching this project's own
      established convention (see e.g. Get-DeltaIisMissingFeatures's own
      header for the return-boundary unwrapping gotcha this guards
      against). Returns an empty array (never throws) if
      Microsoft.Web.Administration is unavailable, the section can't be
      read, or nothing is configured yet.
    #>
    if (-not (Test-DeltaIisManagementAssemblyAvailable)) {
        return ,@()
    }

    try {
        $serverManager = Get-DeltaIisServerManager
        $configuration = Get-DeltaIisApplicationHostConfiguration -ServerManager $serverManager
        $section = Get-DeltaIisConfigurationSection -Configuration $configuration -SectionPath 'system.webServer/rewrite/allowedServerVariables'
        $collection = $section.GetCollection()
        return ,@($collection | ForEach-Object { [string]$_.GetAttributeValue('name') })
    }
    catch {
        return ,@()
    }
}

function Test-DeltaIisForwardedServerVariablesAllowed {
    <#
      Whether every name in $Script:DeltaIisRequiredForwardedServerVariables
      is already present in the machine-wide allowedServerVariables
      collection - required for the DELTA Reverse Proxy rule's own
      <serverVariables> block to work AT ALL, not merely to be "more
      correct": confirmed directly (real IIS testing on a default
      install) that allowedServerVariables is locked
      (overrideModeDefault="Deny") at the server level by default, so
      declaring these names in the site's own web.config instead - which
      an earlier version of this feature did - fails EVERY request to
      the site with HTTP 500.52 ("URL Rewrite Module Error"), not merely
      a missing header. This is why these three names are configured
      machine-wide by setup-iis.ps1's own Phase 4, the same place
      `enabled`/`preserveHostHeader` already are, rather than living in
      templates\iis\web.config at all.
    #>
    $configured = Get-DeltaIisAllowedServerVariableNames
    foreach ($name in $Script:DeltaIisRequiredForwardedServerVariables) {
        if ($configured -notcontains $name) {
            return $false
        }
    }
    return $true
}

function Get-DeltaArrDetectionResult {
    <#
      The ARR/URL Rewrite detection orchestrator - mirrors
      Get-DeltaIisDetectionResult's own shape: collects every fact this
      phase needs into one [PSCustomObject], so setup-iis.ps1's own console
      summary, confirmation prompt, installer, and post-install
      verification, and doctor.ps1's own checklist, all read from a single
      source of truth.

      Each component's own Version is read from the exact same
      Get-InstalledProgramInfo registry lookup Test-DeltaArrComponentInstalled
      already performs for its own AND-check (see that function's own
      header) - not a second, independent version-detection mechanism,
      just no longer discarding the DisplayVersion that lookup already
      returns.
    #>
    $components = @(foreach ($definition in Get-DeltaArrRequiredComponents) {
        $registryMatch = Get-InstalledProgramInfo -DisplayNamePattern $definition.DisplayNamePattern | Select-Object -First 1
        [PSCustomObject]@{
            Name      = $definition.Name
            Installed = Test-DeltaArrComponentInstalled -Definition $definition
            Version   = if ($registryMatch) { $registryMatch.DisplayVersion } else { $null }
        }
    })

    return [PSCustomObject]@{
        Components                      = $components
        ProxyEnabled                    = Test-DeltaIisProxyEnabled
        PreserveHostHeaderEnabled       = Test-DeltaIisPreserveHostHeaderEnabled
        ForwardedServerVariablesAllowed = Test-DeltaIisForwardedServerVariablesAllowed
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
      (BindingInformation, e.g. "*:80:delta.example.org" -> the third
      colon-delimited segment) - the actual, already-configured value,
      never re-prompted. $Site's own Bindings collection is read directly
      (it is already a live part of the same in-memory ServerManager tree
      $Site itself came from - no second fetch needed, unlike
      WebAdministration's Get-WebBinding, which had to re-query by name).
      Returns $null (never throws) if the site has no binding, or a
      binding with an empty host header segment (e.g. "*:80:") - reported
      as "Unknown" by callers, the same shape Get-DeltaNginxVHostSummary's
      own $result.ServerName uses in setup-nginx.ps1 for a vhost file that
      doesn't match its expected shape.
    #>
    param([Parameter(Mandatory)]$Site)

    $binding = $Site.Bindings | Select-Object -First 1
    if (-not $binding -or -not $binding.BindingInformation) {
        return $null
    }

    $bindingParts = $binding.BindingInformation -split ':'
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
      at all (Get-DeltaIisSiteByName, against a fresh ServerManager - never
      cached, per this file's own "Microsoft.Web.Administration - site/
      binding/application-pool primitives" section header). Secondary,
      defense-in-depth signal: that site's own physical path
      (Get-DeltaIisSitePhysicalPath) matches the DELTA installation path
      already resolved ($Script:DeltaInstallPath). Physical path is
      compared after expanding any environment-variable tokens IIS may
      have stored it with (confirmed directly: IIS's own Default Web Site
      stores "%SystemDrive%\inetpub\wwwroot" unexpanded) and trimming a
      trailing backslash, so formatting differences alone never cause a
      false negative.

      A name collision with something an administrator happened to
      independently name "DELTA" is unlikely but not impossible, and this
      installer must never assume ownership from the name alone. Returns
      a [PSCustomObject]: ManagedSite (the site, only once BOTH checks
      agree - $null otherwise) and CollidingSite (the name-matched site
      that failed the physical-path check, so the caller can warn about
      it specifically rather than silently treating it as "nothing
      found").
    #>

    $serverManager = Get-DeltaIisServerManager
    $siteByName = Get-DeltaIisSiteByName -ServerManager $serverManager -Name $Script:DeltaIisSiteName

    if (-not $siteByName) {
        return [PSCustomObject]@{ ManagedSite = $null; CollidingSite = $null }
    }

    $expandedPhysicalPath = [System.Environment]::ExpandEnvironmentVariables((Get-DeltaIisSitePhysicalPath -Site $siteByName)).TrimEnd('\')
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

    $webConfigPath = Join-Path -Path (Get-DeltaIisSitePhysicalPath -Site $Site) -ChildPath 'web.config'
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
      [PSCustomObject]: Binding (the raw Microsoft.Web.Administration
      Binding), Thumbprint (via Get-DeltaIisBindingCertificateThumbprint -
      may be $null/empty), CertificateExists (bool, true only once both
      halves agree).
    #>

    $serverManager = Get-DeltaIisServerManager
    $site = Get-DeltaIisSiteByName -ServerManager $serverManager -Name $Script:DeltaIisSiteName
    if (-not $site) {
        return $null
    }

    $httpsBinding = Get-DeltaIisSiteBindingByProtocolAndPort -Site $site -Protocol 'https'
    if (-not $httpsBinding) {
        return $null
    }

    $thumbprint = Get-DeltaIisBindingCertificateThumbprint -Binding $httpsBinding
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

function Confirm-DeltaIisAppPool {
    <#
      Creates the dedicated DELTA application pool if it does not already
      exist, or reconciles just the three settings this installer owns
      (ManagedRuntimeVersion/ManagedPipelineMode/AutoStart) if it does -
      never recreated. "No Managed Code" (an empty ManagedRuntimeVersion)
      is correct here since this pool only ever proxies to the Node.js
      backend via ARR, never runs managed application code itself -
      mirroring setup-nginx.ps1's own equivalent reasoning for why NGINX
      needs no application-level runtime of its own either.

      Unlike the IIS:\ provider's Get-ItemProperty (which could return
      either a plain value or a wrapped ConfigurationAttribute depending
      on the attribute's own schema type - see this project's own history
      for the unwrap helper that used to exist here), Microsoft.Web.
      Administration's ApplicationPool exposes these three settings as
      plain, strongly-typed properties - no unwrapping needed. A single
      ServerManager is used for both the create-if-missing step and the
      attribute reconciliation, and CommitChanges is only called once, at
      the end, and only if something actually changed - never
      unconditionally.
    #>

    Write-Step "Configuring application pool '$($Script:DeltaIisAppPoolName)'..."

    $serverManager = Get-DeltaIisServerManager
    $pool = Get-DeltaIisApplicationPoolByName -ServerManager $serverManager -Name $Script:DeltaIisAppPoolName
    $changed = $false

    if (-not $pool) {
        $pool = New-DeltaIisApplicationPool -ServerManager $serverManager -Name $Script:DeltaIisAppPoolName
        Write-Detail "Created: $($Script:DeltaIisAppPoolName)"
        $changed = $true
    }
    else {
        Write-Detail "Already exists: $($Script:DeltaIisAppPoolName)"
    }

    if ($pool.ManagedRuntimeVersion -ne '') {
        $pool.ManagedRuntimeVersion = ''
        Write-Detail "Updated managedRuntimeVersion -> ''"
        $changed = $true
    }

    if ($pool.ManagedPipelineMode -ne [Microsoft.Web.Administration.ManagedPipelineMode]::Integrated) {
        $pool.ManagedPipelineMode = [Microsoft.Web.Administration.ManagedPipelineMode]::Integrated
        Write-Detail "Updated managedPipelineMode -> 'Integrated'"
        $changed = $true
    }

    if (-not $pool.AutoStart) {
        $pool.AutoStart = $true
        Write-Detail "Updated autoStart -> 'True'"
        $changed = $true
    }

    if ($changed) {
        Save-DeltaIisConfiguration -ServerManager $serverManager -SectionName 'ApplicationPools' -PropertyDescription "application pool '$($Script:DeltaIisAppPoolName)'"
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
      port 80 for $Site - matched by protocol and port (the fixed values
      this installer always uses), never by replacing the site's entire
      bindings collection. Confirmed directly (a throwaway test site with
      a second, unrelated binding added alongside this installer's own)
      that updating just the matched Binding object's own
      BindingInformation property leaves every other binding on the site
      completely untouched - the direct Microsoft.Web.Administration
      equivalent of the WebAdministration-era Set-WebBinding
      -PropertyName bindingInformation call this replaces.

      Takes $ServerManager and the live $Site object explicitly (both from
      the SAME ServerManager instance the caller - Confirm-DeltaIisWebsite
      - is already using for its own single repair-pass commit) rather
      than resolving its own: this function has no external callers
      outside this file, so its signature is free to reflect that shared-
      transaction shape directly. Does not itself call CommitChanges - the
      caller commits once, after every change in the same pass.

      Only ever called for an EXISTING managed site (Confirm-DeltaIisWebsite
      below) - a fresh site's own initial binding is already created
      correctly by New-DeltaIisSite's own -Port/-HostHeader parameters in
      one step, so calling this again immediately afterward would be
      redundant, not incorrect, but is skipped anyway for clarity.

      Returns $true if the binding was created or updated, $false if it
      was already correct - so the caller (Confirm-DeltaIisWebsite) knows
      whether its own single CommitChanges at the end of the repair pass
      is actually needed, without having to independently re-derive
      "did anything change" itself.
    #>
    param(
        [Parameter(Mandatory)]$ServerManager,
        [Parameter(Mandatory)]$Site,
        [Parameter(Mandatory)][string]$Domain
    )

    $desiredBindingInformation = "*:80:$Domain"
    $existingBinding = Get-DeltaIisSiteBindingByProtocolAndPort -Site $Site -Protocol 'http' -Port 80

    if (-not $existingBinding) {
        $Site.Bindings.Add($desiredBindingInformation, 'http') | Out-Null
        Write-Detail "Binding created: $desiredBindingInformation"
        return $true
    }

    if ($existingBinding.BindingInformation -ne $desiredBindingInformation) {
        $existingBinding.BindingInformation = $desiredBindingInformation
        Write-Detail "Binding updated: $($existingBinding.BindingInformation) -> $desiredBindingInformation"
        return $true
    }

    Write-Detail "Binding already correct: $desiredBindingInformation"
    return $false
}

function Confirm-DeltaIisWebsite {
    <#
      The one place this file ever calls New-DeltaIisSite, and only when
      $ManagedSite is $null (Get-DeltaIisManagedWebsiteResult found
      nothing genuinely ours). An existing managed site has its
      Application Pool association and its own single HTTP binding
      reconciled - never recreated, and no other site setting is ever
      touched.

      $ManagedSite (as passed in by the caller, Repair-DeltaIisManagedWebsite)
      is used ONLY as a truthy "does a site already exist" signal - it is
      never itself read from or mutated, since it was resolved against a
      DIFFERENT, by-now-possibly-stale ServerManager instance (whatever
      Get-DeltaIisManagedWebsiteResult used when the caller first checked).
      This function opens its own single fresh ServerManager for the
      entire repair pass, re-resolves the site by name inside it when one
      already exists, performs every mutation (application pool
      association, binding) against that one instance, and commits once at
      the end - never mixing objects from two different ServerManager
      instances, per this file's own "site/binding/application-pool
      primitives" section header.
    #>
    param([Parameter(Mandatory)][AllowNull()]$ManagedSite)

    Write-Step "Configuring website '$($Script:DeltaIisSiteName)'..."

    $serverManager = Get-DeltaIisServerManager

    if (-not $ManagedSite) {
        New-DeltaIisSite -ServerManager $serverManager -Name $Script:DeltaIisSiteName -PhysicalPath $Script:DeltaInstallPath `
            -Port 80 -HostHeader $Script:DeltaWebsiteDomain -ApplicationPoolName $Script:DeltaIisAppPoolName | Out-Null
        Save-DeltaIisConfiguration -ServerManager $serverManager -SectionName 'Sites' -PropertyDescription "create site '$($Script:DeltaIisSiteName)'"
        Write-Detail "Created: $($Script:DeltaIisSiteName)"
        return
    }

    Write-Detail "Already exists: $($Script:DeltaIisSiteName)"

    $site = Get-DeltaIisSiteByName -ServerManager $serverManager -Name $Script:DeltaIisSiteName
    $changed = $false

    if ((Get-DeltaIisSiteApplicationPoolName -Site $site) -ne $Script:DeltaIisAppPoolName) {
        Set-DeltaIisSiteApplicationPoolName -Site $site -Name $Script:DeltaIisAppPoolName
        Write-Detail "Application pool association updated -> $($Script:DeltaIisAppPoolName)"
        $changed = $true
    }

    $bindingChanged = Confirm-DeltaIisWebsiteBinding -ServerManager $serverManager -Site $site -Domain $Script:DeltaWebsiteDomain
    $changed = $changed -or $bindingChanged

    if ($changed) {
        Save-DeltaIisConfiguration -ServerManager $serverManager -SectionName 'Sites' -PropertyDescription "reconcile site '$($Script:DeltaIisSiteName)'"
    }
}

function Confirm-DeltaIisWebsiteConfigurationResult {
    <#
      Never trusts Confirm-DeltaIisAppPool/Confirm-DeltaIisWebsite's own
      lack of a thrown error as proof of anything; re-reads IIS from
      scratch via a brand new ServerManager (never the one Confirm-
      DeltaIisWebsite itself just committed through) and independently
      checks every fact this repair claims to have configured. Collects
      every failure at once
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

    $serverManager = Get-DeltaIisServerManager
    $site = Get-DeltaIisSiteByName -ServerManager $serverManager -Name $Script:DeltaIisSiteName
    if (-not $site) {
        Stop-Setup "Verification failed: website '$($Script:DeltaIisSiteName)' does not exist after configuration."
    }

    $failures = [System.Collections.Generic.List[string]]::new()

    if (-not (Get-DeltaIisApplicationPoolByName -ServerManager $serverManager -Name $Script:DeltaIisAppPoolName)) {
        $failures.Add("Application pool '$($Script:DeltaIisAppPoolName)' does not exist.")
    }

    $sitePhysicalPath = Get-DeltaIisSitePhysicalPath -Site $site
    $expandedPhysicalPath = [System.Environment]::ExpandEnvironmentVariables($sitePhysicalPath).TrimEnd('\')
    if ($expandedPhysicalPath -ne $Script:DeltaInstallPath.TrimEnd('\')) {
        $failures.Add("Physical path is '$sitePhysicalPath', expected '$($Script:DeltaInstallPath)'.")
    }

    $siteApplicationPoolName = Get-DeltaIisSiteApplicationPoolName -Site $site
    if ($siteApplicationPoolName -ne $Script:DeltaIisAppPoolName) {
        $failures.Add("Application pool is '$siteApplicationPoolName', expected '$($Script:DeltaIisAppPoolName)'.")
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

    if ((Get-DeltaIisSiteState -Site $websiteResult.ManagedSite) -eq 'Started') {
        Write-Host ''
        Write-Detail 'The website is already running.'
        return
    }

    Write-Step 'Starting the website...'
    Start-DeltaIisSite -Site $websiteResult.ManagedSite
    Write-Success '    Website started.'
}

function Stop-DeltaIisManagedWebsite {
    <#
      The direct counterpart to Start-DeltaIisManagedWebsite, above - see
      that function's own header for the full rationale (promotion,
      ownership hardening, shared use). Stops ONLY the DELTA-managed
      website via Stop-DeltaIisSite - never Stop-Service W3SVC,
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

    if ((Get-DeltaIisSiteState -Site $websiteResult.ManagedSite) -eq 'Stopped') {
        Write-Host ''
        Write-Detail 'The website is already stopped.'
        return
    }

    Write-Step 'Stopping the website...'
    Stop-DeltaIisSite -Site $websiteResult.ManagedSite
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
# (the one function here that actually stops a site) only ever runs
# when a provisioning script's own Invoke-DeltaReverseProxyHandover
# (lib\DeltaInstaller.Common.ps1) has already shown the plan to the
# administrator and received explicit confirmation - this file never
# decides on its own that stopping a site is warranted.

function Get-DeltaIisSiteBoundPorts {
    <#
      Every port $Site is bound to, parsed from its own live
      BindingInformation (e.g. "*:80:delta.example.org" -> 80) - the
      second colon-delimited segment, mirroring
      Get-DeltaIisSiteHostHeader's own parsing of the third. Protocol-
      agnostic (an http OR https binding on a given port both count) -
      the handover plan cares only about which ports are reserved, not
      which scheme reserved them. Reads $Site's own Bindings collection
      directly (already live, part of the same ServerManager tree $Site
      itself came from). Returns a real, possibly-empty [int[]] array,
      never $null.
    #>
    param([Parameter(Mandatory)]$Site)

    $ports = [System.Collections.Generic.List[int]]::new()
    foreach ($binding in $Site.Bindings) {
        if (-not $binding.BindingInformation) { continue }
        $parts = $binding.BindingInformation -split ':'
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

    if ($Site.Name -ne 'Default Web Site') {
        return $false
    }

    $expandedPhysicalPath = [System.Environment]::ExpandEnvironmentVariables((Get-DeltaIisSitePhysicalPath -Site $Site)).TrimEnd('\')
    $stockPhysicalPath = [System.Environment]::ExpandEnvironmentVariables('%SystemDrive%\inetpub\wwwroot').TrimEnd('\')

    return $expandedPhysicalPath -eq $stockPhysicalPath
}

function Get-DeltaIisPortBindingOwnership {
    <#
      For $Port, determines whether an already-Started IIS website's own
      binding covers it - reusing the exact same primitives
      Get-DeltaIisReverseProxyHandoverPlan (below) already uses for the
      opposite direction (a DIFFERENT provider asking whether IIS occupies
      ITS required ports): Get-DeltaIisSiteBoundPorts for the binding scan,
      Get-DeltaIisManagedWebsiteResult/Test-DeltaIisStockDefaultWebSite for
      the same "Delta-owned or verified stock Default Web Site is safe,
      anything else is not" classification. Never a second, independent
      binding parser - this is the ONE place setup-iis.ps1's own
      Test-DeltaIisRequiredPortAvailability now consults for "is this port
      already IIS's own."

      Deliberately does NOT use the raw TCP-connection owner
      (Get-ListeningTcpPortOwner, lib\DeltaInstaller.Common.ps1) or its
      ServiceName field to answer this question - confirmed directly
      (real IIS testing) that HTTP.sys-owned listeners are always
      attributed to PID 4 ("System") by Windows, which resolves to no
      Win32_Service entry at all, so a `ServiceName -eq 'W3SVC'` check can
      never actually match on a real machine. IIS's own binding
      configuration (read via Get-DeltaIisSiteBoundPorts) is
      the only authoritative source for "does IIS itself already own this
      port," regardless of which PID or process name the OS attributes
      the underlying kernel-mode listener to.

      Returns $null if no Started IIS website has a binding on $Port at
      all (the caller falls back to the raw TCP-owner signal for a
      non-IIS occupant). Otherwise returns a [PSCustomObject] naming a
      site and classifying it exactly the same three ways
      Get-DeltaIisReverseProxyHandoverPlan already does: 'Delta' (the
      DELTA-managed site itself), 'DefaultWebSite' (a verified stock
      Default Web Site), or 'Other' (a real, unrelated IIS website this
      installer has no business touching or excusing - still a genuine
      conflict, just one the caller can now name specifically instead of
      reporting a useless PID 4/"System").

      A port can legitimately have MORE THAN ONE Started site bound to it
      at once (host-header-based multi-tenancy - two sites sharing port
      80 with two different host headers is normal, per this project's
      own docs\todo\TODO-setup-iis-enhancements.md, Phase 9), so this
      checks EVERY occupying site, never just the first one found -
      mirroring Get-DeltaIisReverseProxyHandoverPlan's own "IsSafe only
      when every single occupant is safe" discipline exactly. A real bug
      this guards against, caught directly on a real machine: taking only
      `Select-Object -First 1` off the occupant list picked "Default Web
      Site" over "DELTA" purely because of enumeration order on a port
      both legitimately share, which happened to still classify as safe
      here - but the same "just take the first one" approach would have
      SILENTLY MASKED a genuinely unrelated third site sharing the same
      port if it enumerated after either safe one, precisely the
      "silently ignore an unrelated site" failure mode this function
      exists to prevent. Any single unsafe/unrelated occupant now makes
      the WHOLE port 'Other', regardless of enumeration order or whether
      a safe site also happens to share it.
    #>
    param([Parameter(Mandatory)][int]$Port)

    $websiteResult = Get-DeltaIisManagedWebsiteResult
    $serverManager = Get-DeltaIisServerManager

    # Get-DeltaIisSiteBoundPorts's own return already crosses its own
    # comma-protected return boundary correctly shaped (see that
    # function's own header) - re-wrapping its result in a SECOND @(...)
    # here does not "double protect" it, it double-WRAPS it: confirmed
    # directly that doing so nests the already-correct array as the
    # single element of a new 1-element array (`[ [80, 443] ]`, not
    # `[80, 443]`), so `-contains $Port` could never match. Called
    # directly, with no extra @() at this call site.
    $occupyingSites = @((Get-DeltaIisAllSites -ServerManager $serverManager) | Where-Object {
        (Get-DeltaIisSiteState -Site $_) -eq 'Started' -and ((Get-DeltaIisSiteBoundPorts -Site $_) -contains $Port)
    })

    if ($occupyingSites.Count -eq 0) {
        return $null
    }

    $isSafeSite = {
        param($Site)
        ($websiteResult.ManagedSite -and $Site.Name -eq $websiteResult.ManagedSite.Name) -or (Test-DeltaIisStockDefaultWebSite -Site $Site)
    }

    $unsafeSite = $occupyingSites | Where-Object { -not (& $isSafeSite $_) } | Select-Object -First 1
    if ($unsafeSite) {
        return [PSCustomObject]@{ SiteName = $unsafeSite.Name; Classification = 'Other' }
    }

    # Every occupant is safe - prefer naming the DELTA site itself when
    # it's one of them (the more useful diagnostic identity), falling
    # back to whichever verified stock Default Web Site occupant matched
    # otherwise.
    $deltaSite = $occupyingSites | Where-Object { $websiteResult.ManagedSite -and $_.Name -eq $websiteResult.ManagedSite.Name } | Select-Object -First 1
    if ($deltaSite) {
        return [PSCustomObject]@{ SiteName = $deltaSite.Name; Classification = 'Delta' }
    }

    $defaultSite = $occupyingSites | Select-Object -First 1
    return [PSCustomObject]@{ SiteName = $defaultSite.Name; Classification = 'DefaultWebSite' }
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
      only function that actually stops a site - so a caller
      (Invoke-DeltaReverseProxyHandover, lib\DeltaInstaller.Common.ps1)
      can carry out an already-confirmed plan without needing any
      IIS-specific knowledge of its own.
    #>
    param([Parameter(Mandatory)][int[]]$RequiredPorts)

    $websiteResult = Get-DeltaIisManagedWebsiteResult
    $serverManager = Get-DeltaIisServerManager

    $occupyingSites = @((Get-DeltaIisAllSites -ServerManager $serverManager) | Where-Object {
        $boundPorts    = Get-DeltaIisSiteBoundPorts -Site $_
        $matchingPorts = @($boundPorts | Where-Object { $RequiredPorts -contains $_ })
        (Get-DeltaIisSiteState -Site $_) -eq 'Started' -and $matchingPorts.Count -gt 0
    })

    $safeSiteNames   = [System.Collections.Generic.List[string]]::new()
    $unsafeSiteNames = [System.Collections.Generic.List[string]]::new()

    foreach ($site in $occupyingSites) {
        $isDeltaManaged = $websiteResult.ManagedSite -and ($site.Name -eq $websiteResult.ManagedSite.Name)
        if ($isDeltaManaged -or (Test-DeltaIisStockDefaultWebSite -Site $site)) {
            $safeSiteNames.Add($site.Name)
        }
        else {
            $unsafeSiteNames.Add($site.Name)
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
        # A fresh ServerManager per site - state can genuinely change
        # between planning and execution, and between one site in this
        # same loop and the next, so each iteration re-resolves rather
        # than trusting an earlier snapshot.
        $serverManager = Get-DeltaIisServerManager
        $site = Get-DeltaIisSiteByName -ServerManager $serverManager -Name $siteName
        if (-not $site) {
            continue
        }
        if ((Get-DeltaIisSiteState -Site $site) -eq 'Stopped') {
            Write-Host ''
            Write-Detail "Website '$siteName' is already stopped."
            continue
        }
        Write-Step "Stopping website '$siteName'..."
        Stop-DeltaIisSite -Site $site
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
    # Error severity, not Warning - preserveHostHeader=False is a confirmed
    # cause of a DELTA login failure (the original Host header not
    # surviving the proxy hop), never merely cosmetic. Ready must not be
    # true unless both this and ProxyEnabled are true - see
    # Test-DeltaIisPreserveHostHeaderEnabled's own header.
    $checks.Add((New-DeltaDoctorCheck -Label 'ARR proxy preserves the original Host header.' -Passed $arrDetection.PreserveHostHeaderEnabled))
    # Also Error severity - required for the DELTA Reverse Proxy rule's own
    # X-Forwarded-Proto/Host/Port server variables to work AT ALL, not
    # merely to be "more correct" - see
    # Test-DeltaIisForwardedServerVariablesAllowed's own header for the
    # real, confirmed HTTP 500.52 failure mode this guards against.
    $checks.Add((New-DeltaDoctorCheck -Label 'Forwarded headers (X-Forwarded-Proto/Host/Port) permitted at the server level.' -Passed $arrDetection.ForwardedServerVariablesAllowed))

    $ready = $iisDetection.Installed -and
             (@($arrDetection.Components | Where-Object { -not $_.Installed }).Count -eq 0) -and
             $arrDetection.ProxyEnabled -and
             $arrDetection.PreserveHostHeaderEnabled -and
             $arrDetection.ForwardedServerVariablesAllowed

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
      rule/backend port/forwarded-header rules), matching the Doctor's own
      worked report example.

      Sets $CanRepair false only for the two situations
      Repair-DeltaIisManagedWebsite genuinely cannot act on safely: the
      fixed site name already belongs to an unrelated website (a real
      collision, never silently touched - see
      Get-DeltaIisManagedWebsiteResult's own header), or
      Microsoft.Web.Administration itself isn't available (IIS
      installation is not this function's job to fix). $NeedsRepair is
      true whenever at least one Error-severity check below actually
      failed - HTTPS state is always Warning-severity (see
      Get-DeltaIisExistingHttpsCertificateState's own header for why an
      orphaned certificate is reported, not auto-replaced: doing so needs
      a certificate file the Doctor is never handed).
    #>
    param([Parameter(Mandatory)][int]$ExpectedBackendPort)

    $checks = [System.Collections.Generic.List[PSCustomObject]]::new()

    if (-not (Test-DeltaIisManagementAssemblyAvailable)) {
        $checks.Add((New-DeltaDoctorCheck -Label 'Website exists.' -Passed $false -Detail 'Microsoft.Web.Administration is unavailable. Run setup-iis.ps1 to install IIS first.'))
        return [PSCustomObject]@{ ManagedSite = $null; CanRepair = $false; NeedsRepair = $false; Checks = $checks }
    }

    $websiteResult = Get-DeltaIisManagedWebsiteResult

    if ($websiteResult.CollidingSite) {
        $checks.Add((New-DeltaDoctorCheck -Label 'Website exists.' -Passed $false -Detail "A website named '$($Script:DeltaIisSiteName)' already exists, but its physical path ($(Get-DeltaIisSitePhysicalPath -Site $websiteResult.CollidingSite)) does not match this DELTA installation. Resolve this by hand before re-running the Doctor."))
        return [PSCustomObject]@{ ManagedSite = $null; CanRepair = $false; NeedsRepair = $false; Checks = $checks }
    }

    $site = $websiteResult.ManagedSite
    $checks.Add((New-DeltaDoctorCheck -Label 'Website exists.' -Passed ([bool]$site)))

    if (-not $site) {
        return [PSCustomObject]@{ ManagedSite = $null; CanRepair = $true; NeedsRepair = $true; Checks = $checks }
    }

    $serverManager = Get-DeltaIisServerManager
    $appPoolExists = [bool](Get-DeltaIisApplicationPoolByName -ServerManager $serverManager -Name (Get-DeltaIisSiteApplicationPoolName -Site $site))
    $checks.Add((New-DeltaDoctorCheck -Label 'Application Pool exists.' -Passed $appPoolExists))

    $httpBinding = Get-DeltaIisSiteBindingByProtocolAndPort -Site $site -Protocol 'http' -Port 80
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

    $webConfigPath = Join-Path -Path (Get-DeltaIisSitePhysicalPath -Site $site) -ChildPath 'web.config'
    $webConfigExists = Test-Path -LiteralPath $webConfigPath
    $checks.Add((New-DeltaDoctorCheck -Label 'web.config exists.' -Passed $webConfigExists -Detail $(if (-not $webConfigExists) { "Expected: $webConfigPath" })))

    $rewriteRulePresent = $false
    $backendPortMatches = $false
    $configuredPort = $null
    # X-Forwarded-Proto/Host/Port are per-site web.config facts - whether
    # THIS site's own rule sets them via <serverVariables> - matched the
    # same regex-against-live-file way Rewrite rule present already is,
    # just below. Deliberately NOT also checking for a matching
    # <allowedServerVariables> entry in this same file: confirmed
    # directly (real IIS testing) that allowedServerVariables is locked
    # at the server level by default, so templates\iis\web.config never
    # declares it here at all - whether these names are actually
    # PERMITTED is a separate, machine-wide fact
    # (Test-DeltaIisForwardedServerVariablesAllowed, checked in
    # Get-DeltaDoctorIisPrerequisiteChecks, the same place
    # preserveHostHeader already is), not a per-site one.
    $forwardedProtoConfigured = $false
    $forwardedHostConfigured  = $false
    $forwardedPortConfigured  = $false
    if ($webConfigExists) {
        $webConfigContent = Get-Content -LiteralPath $webConfigPath -Raw
        $rewriteRulePresent = $webConfigContent -match '<rule\s+name="DELTA Reverse Proxy"'
        $configuredPort = Get-DeltaIisSiteBackendPort -Site $site
        $backendPortMatches = ($configuredPort -eq $ExpectedBackendPort)

        $forwardedProtoConfigured = $webConfigContent -match '<set\s+name="HTTP_X_FORWARDED_PROTO"'
        $forwardedHostConfigured  = $webConfigContent -match '<set\s+name="HTTP_X_FORWARDED_HOST"'
        $forwardedPortConfigured  = $webConfigContent -match '<set\s+name="HTTP_X_FORWARDED_PORT"'
    }
    $checks.Add((New-DeltaDoctorCheck -Label 'Rewrite rule present.' -Passed $rewriteRulePresent))
    $checks.Add((New-DeltaDoctorCheck -Label 'Backend rewrite target matches configured port.' -Passed $backendPortMatches `
        -Detail $(if ($webConfigExists -and -not $backendPortMatches) { "web.config targets $(if ($configuredPort) { $configuredPort } else { 'no recognizable port' }), expected $ExpectedBackendPort." })))
    $checks.Add((New-DeltaDoctorCheck -Label 'X-Forwarded-Proto forwarding configured.' -Passed $forwardedProtoConfigured))
    $checks.Add((New-DeltaDoctorCheck -Label 'X-Forwarded-Host forwarding configured.' -Passed $forwardedHostConfigured))
    $checks.Add((New-DeltaDoctorCheck -Label 'X-Forwarded-Port forwarding configured.' -Passed $forwardedPortConfigured))

    $needsRepair = -not ($appPoolExists -and $httpBinding -and $webConfigExists -and $rewriteRulePresent -and $backendPortMatches `
        -and $forwardedProtoConfigured -and $forwardedHostConfigured -and $forwardedPortConfigured)

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

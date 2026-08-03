<#
.SYNOPSIS
    Read-only, multi-provider reverse proxy state detection for the Doctor
    framework - "which reverse proxy providers exist on this machine, which
    of them does DELTA actually own, which one is currently active, and is
    there a conflict?"

.DESCRIPTION
    This file is purely a detector. It never installs, starts, stops,
    reconfigures, or migrates anything - see Get-DeltaReverseProxyState's
    own header for the full read-only guarantee. Provisioning, repair, and
    lifecycle management for any one provider remain that provider's own
    lib\DeltaDoctor.<Provider>.ps1 (Confirm-DeltaIisAppPool etc.,
    lib\DeltaDoctor.IIS.ps1) or its corresponding setup-<provider>.ps1 -
    this file only ever reads what they already own.

    Ownership vs. activity - the central design principle this whole file
    is built around: "managed by DELTA" is answered ONLY from configuration
    DELTA itself generated (the managed IIS website's own physical
    path/application pool, the NGINX vhost's own DELTA header-comment
    marker) - never from a TCP port being bound, a process existing, a PID,
    a registry key, or a Windows service's status, any of which could
    belong to a completely unrelated deployment of the same software.
    "Active" is a deliberately separate question, asked only once ownership
    is already established, and IS allowed to use a live runtime signal
    (an IIS site's own .state, NGINX's own Get-DeltaNginxRuntimeState) -
    "is this specific, DELTA-owned configuration currently serving traffic"
    is inherently a runtime question, unlike "does this configuration
    belong to DELTA at all."

    Provider-based, extensible architecture: Get-DeltaReverseProxyProviderDefinitions
    is the one place a future provider (Apache, Caddy, Traefik, ...) needs
    to be registered - Get-DeltaReverseProxyState's own orchestration logic
    never changes to accommodate a new provider, it just iterates whatever
    the registry contains. Adding a provider means: implement its own
    Get-Delta<Provider>ReverseProxyProviderState function (ideally in that
    provider's own lib\DeltaDoctor.<Provider>.ps1, mirroring
    lib\DeltaDoctor.IIS.ps1/lib\DeltaDoctor.NGINX.ps1), returning the exact
    same shape every other provider's state function returns (Name/
    Installed/ManagedByDelta/ConfigurationHealthy/Active/Detail), then add
    one entry to the registry. Nothing else in this file needs to know that
    provider exists.

    Dot-sources both lib\DeltaDoctor.IIS.ps1 and lib\DeltaDoctor.NGINX.ps1
    (each of which dot-sources lib\DeltaInstaller.Common.ps1 itself) - so
    this one file, once dot-sourced, brings in every function this whole
    feature needs.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeltaDoctor.IIS.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'DeltaDoctor.NGINX.ps1')

# ---------------------------------------------------------------------------
# Provider state - IIS
# ---------------------------------------------------------------------------

function Get-DeltaIisReverseProxyProviderState {
    <#
      Reuses lib\DeltaDoctor.IIS.ps1's own existing detection wholesale -
      no independent IIS logic lives here. Installed comes from
      Get-DeltaIisDetectionResult (the same IIS-role-service detection
      setup-iis.ps1's own Phase 2/doctor.ps1's own IIS-prerequisite check
      already use). ManagedByDelta/ConfigurationHealthy both come from a
      single Get-DeltaDoctorWebsiteChecks call - the exact same function
      doctor.ps1's own "Inspecting DELTA IIS configuration" section and
      setup-iis.ps1's own "Validate Configuration" menu action already
      call; ManagedByDelta is true only once that function's own
      Get-DeltaIisManagedWebsiteResult call confirms BOTH the fixed site
      name AND the physical path belong to this DELTA installation (never
      the name alone - see that function's own header), and
      ConfigurationHealthy is true only once every one of its own
      Error-severity checks (application pool, web.config, rewrite rule,
      backend port) passes.

      Active is answered separately, and is the one place this function
      reads a live runtime signal (the site's own .state) rather than
      configuration - deliberately: ownership must never depend on
      runtime state, but "is the DELTA-owned site currently serving
      traffic" inherently is a runtime question. Not answered from a TCP
      port/process check - the site's own IIS-reported state is a direct,
      first-party signal, not an inference from something else that could
      belong to a different site entirely.
    #>

    $installed = (Get-DeltaIisDetectionResult).Installed

    if (-not $installed -or -not (Test-DeltaIisManagementAssemblyAvailable)) {
        return [PSCustomObject]@{
            Name                 = 'IIS'
            Installed            = $installed
            ManagedByDelta       = $false
            ConfigurationHealthy = $null
            Active               = $false
            Detail               = $null
        }
    }

    $portInfo = Resolve-DeltaDoctorBackendPortInfo -EnvPath $Script:DeltaEnvPath
    $expectedPort = if ($portInfo.Valid) { $portInfo.Port } else { -1 }
    $websiteChecks = Get-DeltaDoctorWebsiteChecks -ExpectedBackendPort $expectedPort

    $managedByDelta = [bool]$websiteChecks.ManagedSite
    $configurationHealthy = if (-not $managedByDelta) { $null } else { -not $websiteChecks.NeedsRepair }

    $detail = $null
    if ($managedByDelta -and $websiteChecks.NeedsRepair) {
        $failingLabels = @($websiteChecks.Checks | Where-Object { -not $_.Passed -and $_.Severity -eq 'Error' } | ForEach-Object { $_.Label })
        $detail = $failingLabels -join '; '
    }

    $active = [bool]($managedByDelta -and (Get-DeltaIisSiteState -Site $websiteChecks.ManagedSite) -eq 'Started')

    return [PSCustomObject]@{
        Name                 = 'IIS'
        Installed            = $installed
        ManagedByDelta       = $managedByDelta
        ConfigurationHealthy = $configurationHealthy
        Active               = $active
        Detail               = $detail
    }
}

# ---------------------------------------------------------------------------
# Provider state - NGINX
# ---------------------------------------------------------------------------

function Get-DeltaNginxReverseProxyProviderState {
    <#
      Reuses lib\DeltaDoctor.NGINX.ps1's own existing detection wholesale.
      Installed is the plain Test-Path $Script:NginxExePath check every
      NGINX-related function in that file already relies on. ManagedByDelta
      is Get-DeltaNginxVHostSummary's own IsDeltaOwned field - the
      DELTA-template header-comment marker, never mere file-path existence
      or shape-matching alone (see that function's own header for why this
      file's version of it is stronger than setup-nginx.ps1's original).

      ConfigurationHealthy (only ever meaningful once ManagedByDelta is
      true - $null otherwise, matching lib\DeltaDoctor.IIS.ps1's own
      convention) checks the same two facts
      Get-DeltaDoctorWebsiteChecks checks for IIS's own web.config: a
      recognizable server_name/backend directive present, and the
      configured backend port actually matching the DELTA installation's
      current .env PORT value - never merely "the file exists."

      Active, like the IIS provider's own version, is the one place this
      function reads a live runtime signal
      (Get-DeltaNginxRuntimeState.State -eq 'Running') rather than
      configuration - ownership (ManagedByDelta, above) never depends on
      it; "is the DELTA-owned vhost's own NGINX instance currently
      running" inherently is a runtime question.
    #>

    $installed = Test-Path -LiteralPath $Script:NginxExePath

    if (-not $installed) {
        return [PSCustomObject]@{
            Name                 = 'NGINX'
            Installed            = $false
            ManagedByDelta       = $false
            ConfigurationHealthy = $null
            Active               = $false
            Detail               = $null
        }
    }

    $vhost = Get-DeltaNginxVHostSummary
    $managedByDelta = $vhost.IsDeltaOwned

    $configurationHealthy = $null
    $detail = $null
    if ($managedByDelta) {
        $portInfo = Resolve-DeltaDoctorBackendPortInfo -EnvPath $Script:DeltaEnvPath
        $configuredPort = $null
        if ($vhost.BackendUrl) {
            $portMatch = [regex]::Match($vhost.BackendUrl, ':(\d+)$')
            if ($portMatch.Success) { $configuredPort = [int]$portMatch.Groups[1].Value }
        }

        if (-not $vhost.ServerName) {
            $configurationHealthy = $false
            $detail = 'delta.conf is missing a recognizable server_name directive.'
        }
        elseif (-not $configuredPort) {
            $configurationHealthy = $false
            $detail = 'delta.conf is missing a recognizable proxy_pass directive.'
        }
        elseif ($portInfo.Valid -and $configuredPort -ne $portInfo.Port) {
            $configurationHealthy = $false
            $detail = "delta.conf targets port $configuredPort, expected $($portInfo.Port)."
        }
        else {
            $configurationHealthy = $true
        }
    }

    $runtimeState = Get-DeltaNginxRuntimeState
    $active = [bool]($managedByDelta -and $runtimeState.State -eq 'Running')

    return [PSCustomObject]@{
        Name                 = 'NGINX'
        Installed            = $installed
        ManagedByDelta       = $managedByDelta
        ConfigurationHealthy = $configurationHealthy
        Active               = $active
        Detail               = $detail
    }
}

# ---------------------------------------------------------------------------
# Provider registry
# ---------------------------------------------------------------------------

function Get-DeltaReverseProxyProviderDefinitions {
    <#
      The one place a future provider needs to be registered - see this
      file's own header. GetState is a scriptblock reference (captured via
      ${function:Name}, not a bare string name) to that provider's own
      Get-Delta<Provider>ReverseProxyProviderState function, invoked below
      via `& $definition.GetState` - Get-DeltaReverseProxyState itself
      never has a per-provider switch/if branch to maintain.

      GetRequiredPorts/GetHandoverPlan (the Reverse Proxy Handover Plan
      architecture correction) are the identical pattern applied to that
      feature: scriptblock references to that provider's own
      Get-Delta<Provider>RequiredPorts and
      Get-Delta<Provider>ReverseProxyHandoverPlan functions, so
      Get-DeltaReverseProxyHandoverPlan (below) never has a per-provider
      branch either - adding a future provider means registering all
      three functions here, once, and nothing in this file's own
      orchestration logic changes.
    #>
    return @(
        [PSCustomObject]@{
            Name             = 'IIS'
            GetState         = ${function:Get-DeltaIisReverseProxyProviderState}
            GetRequiredPorts = ${function:Get-DeltaIisRequiredPorts}
            GetHandoverPlan  = ${function:Get-DeltaIisReverseProxyHandoverPlan}
        }
        [PSCustomObject]@{
            Name             = 'NGINX'
            GetState         = ${function:Get-DeltaNginxReverseProxyProviderState}
            GetRequiredPorts = ${function:Get-DeltaNginxRequiredPorts}
            GetHandoverPlan  = ${function:Get-DeltaNginxReverseProxyHandoverPlan}
        }
    )
}

# ---------------------------------------------------------------------------
# Orchestration - structured result
# ---------------------------------------------------------------------------

function ConvertTo-DeltaEnglishList {
    <#
      Joins provider names into a natural-language list ("IIS", "IIS and
      NGINX", "IIS, NGINX, and Apache") for the narrative recommendation
      text below - a pure string-formatting helper, no detection logic of
      its own, kept general enough to read naturally regardless of how
      many providers this feature ends up supporting.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Items)

    if ($Items.Count -eq 0) { return '' }
    if ($Items.Count -eq 1) { return $Items[0] }
    if ($Items.Count -eq 2) { return "$($Items[0]) and $($Items[1])" }
    return (($Items[0..($Items.Count - 2)] -join ', ') + ", and $($Items[-1])")
}

function Get-DeltaReverseProxyRecommendations {
    <#
      Informational only - per this feature's own explicit "recommendations
      remain informational only, Doctor must not automatically perform
      migration" requirement, this returns strings, never performs any
      action itself. Doctor DESCRIBES state here; it never PRESCRIBES a
      lifecycle action ("stop IIS and activate NGINX", "run setup-nginx.ps1
      to fix this", "start DELTA") - deciding what to do about a described
      state is a provisioning script's job (setup-iis.ps1, setup-nginx.ps1,
      and eventually reverse-proxy.ps1), never Doctor's own. Every
      recommendation below is additive (more than one can legitimately
      apply at once, e.g. a conflict AND a broken provider), except the
      trailing "No action required." fallback, which only appears when
      nothing else did.

      Explains before it flags (this feature's own UX refinement): a
      healthy staged/standby deployment (multiple DELTA-managed providers,
      all healthy, exactly one active - $Status already reflects this as
      'Healthy', not 'Warning') describes the actual situation in plain
      language ("X and Y are configured for DELTA. X is currently serving
      traffic. Y is fully configured and available as the standby reverse
      proxy.") and stops there, rather than opening with "Multiple ...
      detected" (alarming wording for a state that is often a deliberate,
      healthy staging/migration setup, not a problem) or going on to
      suggest a specific migration step. A genuinely ambiguous
      multiple-managed state (no provider active, or more than one active
      at once - $Status stays 'Warning' for these) still gets flagged,
      worded to explain WHY rather than just that it is - again, without
      telling the operator what to run next.

      Every array parameter below is explicitly [AllowEmptyCollection()] -
      matching ConvertTo-DeltaEnglishList's own precedent immediately
      above - because EVERY one of them is a legitimate, expected empty
      value in a real deployment, not an error state: $ManagedProviders/
      $ActiveProviders are empty in State A (nothing configured yet) and,
      as of the Manual Reverse Proxy Handover feature, $ActiveProviders is
      ALSO empty in State E (multiple providers installed and DELTA-
      managed, both stopped - the normal, expected gap between "the
      previous provider was just stopped" and "the target provider has
      started" mid-handover); $StandbyProviders is empty in the single-
      most-common healthy case of all (one managed provider, active, no
      second one configured at all). Without [AllowEmptyCollection()], a
      Mandatory array/collection-typed parameter rejects an empty
      (non-null) array outright - "Cannot bind argument to parameter 'X'
      because it is an empty collection" - a plain PowerShell parameter-
      binder behavior, confirmed directly, that has nothing to do with
      $Status/$HasConflict's own logic below ever being wrong; every
      branch in this function already correctly handles a zero-count
      array (see e.g. "$ActiveProviders.Count -eq 0" a few lines down) -
      the crash was purely in NEVER REACHING that logic, at the call
      boundary itself.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ProviderStates,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ManagedProviders,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ActiveProviders,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$StandbyProviders,
        [Parameter(Mandatory)][bool]$HasConflict,
        [Parameter(Mandatory)][string]$Status
    )

    $recommendations = [System.Collections.Generic.List[string]]::new()

    if ($ManagedProviders.Count -eq 0) {
        $recommendations.Add('No DELTA-managed reverse proxy is configured yet.')
    }

    foreach ($state in $ProviderStates) {
        if ($state.ManagedByDelta -and $state.ConfigurationHealthy -eq $false) {
            $recommendations.Add("$($state.Name) is configured for DELTA, but its configuration is incomplete.")
        }
    }

    if ($HasConflict -and $Status -eq 'Healthy') {
        # The clean staged/standby shape: every managed provider is
        # healthy and exactly one is active - describe the topology, then
        # stop. Migrating from one provider to the other is a lifecycle
        # decision for a provisioning tool to make, never Doctor's own.
        $recommendations.Add((ConvertTo-DeltaEnglishList $ManagedProviders) + ' are configured for DELTA.')
        $recommendations.Add("$($ActiveProviders[0]) is currently serving traffic.")
        foreach ($standbyName in $StandbyProviders) {
            $recommendations.Add("$standbyName is fully configured and available as the standby reverse proxy.")
        }
        $recommendations.Add('Lifecycle operations are handled by provisioning tools.')
    }
    elseif ($HasConflict) {
        # Still multiple managed providers, but not the clean shape above
        # (a broken provider already explained itself, above) - a
        # genuinely ambiguous activation state, worth flagging with a
        # reason, not just a bare "multiple detected."
        if ($ActiveProviders.Count -eq 0) {
            $recommendations.Add((ConvertTo-DeltaEnglishList $ManagedProviders) + ' are configured for DELTA, but none of them is currently active.')
        }
        elseif ($ActiveProviders.Count -gt 1) {
            $recommendations.Add((ConvertTo-DeltaEnglishList $ActiveProviders) + ' are all currently active at the same time. Only one reverse proxy should normally serve DELTA traffic at once.')
        }
    }
    else {
        # Exactly one managed provider - the single-provider "configured
        # but not started" case, described without instructing the
        # operator to start it.
        foreach ($state in $ProviderStates) {
            if ($state.ManagedByDelta -and $state.ConfigurationHealthy -and -not $state.Active) {
                $recommendations.Add("$($state.Name) is configured for DELTA but not currently active.")
            }
        }
    }

    $activeManagedHealthy = @($ProviderStates | Where-Object { $_.ManagedByDelta -and $_.ConfigurationHealthy -and $_.Active })
    if ($activeManagedHealthy.Count -gt 0 -and $Script:DeltaEnvPath) {
        $portInfo = Resolve-DeltaDoctorBackendPortInfo -EnvPath $Script:DeltaEnvPath
        if ($portInfo.Valid -and -not (Test-DeltaTcpPortListening -Port $portInfo.Port)) {
            $recommendations.Add('The DELTA backend does not appear to be running.')
        }
    }

    if ($recommendations.Count -eq 0) {
        $recommendations.Add('No action required.')
    }

    return ,@($recommendations)
}

function Get-DeltaReverseProxyState {
    <#
      The top-level, read-only orchestrator - answers every question this
      feature exists to answer:

        1. Which supported reverse proxy providers are installed?
           -> InstalledProviders
        2. Which providers are managed by DELTA?
           -> ManagedProviders
        3. Which reverse proxy provider is currently active?
           -> ActiveProvider (an array - see its own note below)
        4. Are multiple DELTA-managed reverse proxies present?
           -> HasConflict
        5. Does the current system contain conflicting configurations?
           -> HasConflict again, plus State ('MultipleManaged')
        6. What action is recommended?
           -> Recommendations

      Never modifies anything - every provider's own Get-State function is
      itself entirely read-only (see each one's own header), and this
      function only aggregates their results. Nothing about how
      Installed/ManagedByDelta/ConfigurationHealthy/Active are themselves
      computed lives here or changes here - this function only ever
      reshapes those already-computed per-provider facts.

      ActiveProvider is an array, not a bare string, even though the
      common case is 0 or 1 entries - matching this project's own "always
      a real, inspectable array, never a bare scalar a caller has to guess
      about" convention (see e.g. Get-DeltaNginxManagedProcesses's own
      header for the general rule). A machine-readable consumer should
      never need to special-case "is this a string or an array" depending
      on how many providers happen to be active.

      StandbyProviders is a derived, presentation-layer field (this
      feature's own UX refinement) - the subset of ManagedProviders that
      is also healthy but not active, i.e. a genuinely viable fallback.
      Deliberately excludes a managed-but-UNHEALTHY provider: a broken
      configuration is not a real standby, and calling it one would
      mislead an operator into thinking it's ready to activate - that
      case already speaks for itself via its own Configuration: Unhealthy
      state and its own Error-level recommendation instead.

      State is a coarse, human-and-machine-friendly classification of the
      scenarios this feature's own design calls out by letter:
      'NoProxyConfigured' (State A - no providers installed),
      'IisOnly' (State B - IIS active), 'NginxOnly' (State C - NGINX
      active), 'MultipleManaged' (both State D - both active - AND State E
      - both installed/DELTA-managed, NEITHER currently active) -
      descriptive strings rather than bare letters, since a
      machine-readable consumer should never need this file's own
      documentation open to know what 'B' means. State D and State E
      share 'MultipleManaged' because State alone only ever answers
      "which provider(s)", never "how many are active right now" - that
      second question is ActiveProviders.Count/Status/DeploymentMode's
      own job, not State's.

      State E - both providers installed and DELTA-managed, ConfigurationHealthy,
      and NEITHER currently Active - is a fully valid, expected lifecycle
      state, not an edge case to special-case away: it is exactly what
      the Manual Reverse Proxy Handover feature's own gap between "the
      previous provider was just stopped" and "the target provider has
      started" looks like from Doctor's own point of view. ActiveProviders
      is a genuinely empty (but never null) array in this state - see
      Get-DeltaReverseProxyRecommendations's own header for the
      [AllowEmptyCollection()] fix this required once real testing (not
      merely static parsing) actually exercised it; every array this
      function returns/passes downstream is a real, always-non-null
      array, empty or not, per this project's own established convention.

      DeploymentMode is a higher-level, presentation-facing classification
      layered on top of State/Status for a provisioning script deciding
      what kind of situation it's walking into - deliberately coarser than
      State (which cares which specific provider), remaining purely
      descriptive (this feature's own "Doctor describes, provisioning
      scripts decide" principle - see this file's own header): 'Unknown'
      (nothing DELTA-managed exists yet - there is no deployment topology
      to classify), 'Single Provider' (exactly one DELTA-managed provider),
      'Dual Provider' (more than one DELTA-managed provider, all healthy,
      with exactly one active - State D, the clean staged/standby shape,
      same condition Status already calls 'Healthy' despite HasConflict),
      and 'Migration' (more than one DELTA-managed provider where
      activation is genuinely ambiguous - none active (State E - see this
      function's own State field documentation above for why this is a
      normal, expected mid-handover gap, not an error), or more than one
      active at once - the same condition Status calls 'Warning' for this
      reason; named 'Migration' because that ambiguous, transitional
      shape is exactly what mid-switch between two providers looks like).

      Status ('NotConfigured'/'Healthy'/'Warning'/'Error') is NOT simply
      "HasConflict -> Warning" (this feature's own UX refinement, corrected
      from an earlier version that was exactly that): multiple
      DELTA-managed providers, all healthy, with EXACTLY one active is a
      legitimate staged/standby deployment (a deliberate migration or
      failover setup), not a problem, and is classified 'Healthy' - the
      Recommendation text (see Get-DeltaReverseProxyRecommendations) is
      what carries the informational "here's your current topology" note
      in that case, not the Status field. 'Warning' is reserved for
      states that are actually ambiguous: multiple managed providers where
      either none or more than one is simultaneously active, or a single
      managed, healthy provider that simply isn't running. 'Error' is
      reserved for an actually broken, DELTA-managed configuration -
      unaffected by this refinement.
    #>

    $providerStates = @(foreach ($definition in Get-DeltaReverseProxyProviderDefinitions) {
        & $definition.GetState
    })

    $installedProviders = @($providerStates | Where-Object { $_.Installed } | ForEach-Object { $_.Name })
    $managedProviders    = @($providerStates | Where-Object { $_.ManagedByDelta } | ForEach-Object { $_.Name })
    $activeProviders     = @($providerStates | Where-Object { $_.Active } | ForEach-Object { $_.Name })
    $standbyProviders    = @($providerStates | Where-Object { $_.ManagedByDelta -and $_.ConfigurationHealthy -and -not $_.Active } | ForEach-Object { $_.Name })

    $hasConflict = $managedProviders.Count -gt 1
    $allManagedHealthy = (@($providerStates | Where-Object { $_.ManagedByDelta -and $_.ConfigurationHealthy -eq $false }).Count -eq 0)

    $state =
        if ($managedProviders.Count -eq 0) { 'NoProxyConfigured' }
        elseif ($hasConflict) { 'MultipleManaged' }
        elseif ($managedProviders[0] -eq 'IIS') { 'IisOnly' }
        else { 'NginxOnly' }

    $status =
        if ($managedProviders.Count -eq 0) { 'NotConfigured' }
        elseif (-not $allManagedHealthy) { 'Error' }
        elseif ($hasConflict -and $activeProviders.Count -eq 1) { 'Healthy' }
        elseif ($hasConflict) { 'Warning' }
        elseif (@($providerStates | Where-Object { $_.ManagedByDelta -and $_.ConfigurationHealthy -and -not $_.Active }).Count -gt 0) { 'Warning' }
        else { 'Healthy' }

    # See this function's own header for the full rationale behind each
    # of these four values - deliberately derived from the same
    # managedProviders/activeProviders facts $status itself uses, never a
    # second, independent judgment call.
    $deploymentMode =
        if ($managedProviders.Count -eq 0) { 'Unknown' }
        elseif ($managedProviders.Count -eq 1) { 'Single Provider' }
        elseif ($activeProviders.Count -eq 1) { 'Dual Provider' }
        else { 'Migration' }

    $recommendations = Get-DeltaReverseProxyRecommendations -ProviderStates $providerStates -ManagedProviders $managedProviders `
        -ActiveProviders $activeProviders -StandbyProviders $standbyProviders -HasConflict $hasConflict -Status $status

    return [PSCustomObject]@{
        InstalledProviders = $installedProviders
        ManagedProviders    = $managedProviders
        ActiveProvider      = $activeProviders
        StandbyProviders    = $standbyProviders
        State               = $state
        Status              = $status
        DeploymentMode      = $deploymentMode
        HasConflict         = $hasConflict
        ProviderStates      = $providerStates
        Recommendations     = $recommendations
    }
}

# ---------------------------------------------------------------------------
# Human-readable report
# ---------------------------------------------------------------------------

function Show-DeltaReverseProxyReport {
    <#
      Purely a display concern over $Result (Get-DeltaReverseProxyState) -
      never queries anything live itself, so what's displayed is guaranteed
      to be exactly what was detected, not a second, possibly inconsistent
      live re-check. Mirrors this project's own established dash-rule/
      blank-line-separated-field summary style (lib\DeltaDoctor.IIS.ps1's
      own Show-DeltaIisDetectionSummary).

      Four concepts this feature's own UX refinement insists on never
      conflating: Installed (the software exists on this machine at all),
      Managed by DELTA (this specific installation's own configuration was
      generated by/belongs to DELTA), Configuration (Healthy/Unhealthy/
      Unknown - only meaningful once Managed by DELTA is Yes), and
      Active/Standby (currently serving traffic, or a healthy, viable
      fallback). Presented as a short flag list per provider ("Installed",
      "Managed by DELTA", "Healthy", "Active") rather than a dense
      Label/Yes-No column layout - a later UX pass's own explicit
      simplification, since only the flags that actually apply to a given
      provider are ever printed (a provider that isn't managed by DELTA at
      all never prints a Configuration or Active/Standby line - there is
      nothing meaningful to say about either yet). The Deployment section
      below restates the same already-computed Active/Standby facts as a
      single topology summary ("who's serving traffic, who's the
      fallback"), plus DeploymentMode - a coarser, single-word
      classification of the overall topology (see
      Get-DeltaReverseProxyState's own header) - easier to read at a
      glance than reconstructing either picture from each provider's own
      block.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Result)

    $statusLabels = @{
        NotConfigured = 'Not Configured'
        Healthy       = 'Healthy'
        Warning       = 'Warning'
        Error         = 'Error'
    }

    Write-Host ('=' * $Script:BannerWidth)
    Write-Host 'Reverse Proxy Detection'
    Write-Host ('=' * $Script:BannerWidth)
    Write-Host ''

    # "Installed Providers", not "Detected Providers" - this section
    # communicates software availability on this machine, never DELTA
    # ownership (that's the "Managed by DELTA" field below) or discovery
    # mechanics.
    Write-Host 'Installed Providers'
    Write-Host ''
    $nameColumnWidth = (($Result.ProviderStates | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum) + 4
    foreach ($providerState in $Result.ProviderStates) {
        $installedLabel = if ($providerState.Installed) { 'Installed' } else { 'Not Installed' }
        Write-Detail ("{0,-$nameColumnWidth}: {1}" -f $providerState.Name, $installedLabel)
        Write-Host ''
    }

    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Provider State'
    Write-Host ''
    for ($i = 0; $i -lt $Result.ProviderStates.Count; $i++) {
        $providerState = $Result.ProviderStates[$i]

        # Each provider's block is fully self-contained (Installed/Managed
        # by DELTA/Configuration/Active-or-Standby all together) so it can
        # be understood on its own, without cross-referencing another
        # section - this feature's own explicit UX goal. Only the flags
        # that actually apply are printed - see this function's own header
        # for why a provider that isn't Managed by DELTA never grows a
        # Configuration or Active/Standby line at all.
        Write-Host $providerState.Name
        Write-Host ''

        $flags = [System.Collections.Generic.List[string]]::new()
        if (-not $providerState.Installed) {
            $flags.Add('Not Installed')
        }
        else {
            $flags.Add('Installed')
            if ($providerState.ManagedByDelta) {
                $flags.Add('Managed by DELTA')
                $flags.Add($(
                    if ($null -eq $providerState.ConfigurationHealthy) { 'Configuration Unknown' }
                    elseif ($providerState.ConfigurationHealthy) { 'Healthy' }
                    else { 'Unhealthy' }
                ))
                if ($providerState.Active) {
                    $flags.Add('Active')
                }
                elseif ($providerState.ConfigurationHealthy) {
                    # Matches StandbyProviders' own definition below - a
                    # healthy, managed, inactive provider is a genuine
                    # standby; an unhealthy one is not (its own
                    # "Unhealthy" flag, just added above, already says so).
                    $flags.Add('Standby')
                }
            }
        }

        foreach ($flag in $flags) {
            Write-Detail $flag
        }
        Write-Host ''
        if ($providerState.Detail) {
            Write-Detail $providerState.Detail
            Write-Host ''
        }

        if ($i -lt $Result.ProviderStates.Count - 1) {
            Write-Host ('-' * $Script:BannerWidth)
            Write-Host ''
        }
    }

    # "Deployment" - replaces the old, narrower "Current Active Provider"
    # section: an operator understands a two-line "who's active, who's on
    # standby" topology summary far faster than re-deriving it from each
    # provider's own Active field. Standby Provider is omitted entirely
    # when none exists (this feature's own explicit "if no standby
    # provider exists, simply omit that field" requirement) rather than
    # printed as "None" - Active Provider always prints, "None" included,
    # since a deployment with no active provider at all is itself
    # important to see plainly.
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Deployment'
    Write-Host ''
    Write-Host '    Mode'
    Write-Host ''
    Write-Host "        $($Result.DeploymentMode)"
    Write-Host ''
    Write-Host '    Active Provider'
    Write-Host ''
    if ($Result.ActiveProvider.Count -gt 0) {
        foreach ($name in $Result.ActiveProvider) {
            Write-Host "        $name"
        }
    }
    else {
        Write-Host '        None'
    }
    if ($Result.StandbyProviders.Count -gt 0) {
        Write-Host ''
        Write-Host '    Standby Provider'
        Write-Host ''
        foreach ($name in $Result.StandbyProviders) {
            Write-Host "        $name"
        }
    }
    Write-Host ''

    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Status'
    Write-Host ''
    Write-Detail $statusLabels[$Result.Status]
    Write-Host ''

    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Recommendation'
    Write-Host ''
    foreach ($recommendation in $Result.Recommendations) {
        Write-Detail $recommendation
        Write-Host ''
    }

    Write-Host ('-' * $Script:BannerWidth)
}

function Invoke-DeltaReverseProxyDetection {
    <#
      The single entry point doctor.ps1 calls - Detect+Diagnose (Get-DeltaReverseProxyState)
      then Report (Show-DeltaReverseProxyReport), returning the same
      structured $result its own caller already has printed, so a future
      caller (a reverse-proxy.ps1 migration tool, uninstall.ps1, ...) can
      consume ReverseProxy state programmatically without parsing console
      output - see this file's own header for that future architecture.
    #>

    $result = Get-DeltaReverseProxyState
    Show-DeltaReverseProxyReport -Result $result
    return $result
}

# ---------------------------------------------------------------------------
# Decision support - for provisioning scripts consuming ReverseProxy state
# ---------------------------------------------------------------------------
#
# Doctor answers "what is the current DELTA reverse proxy state"; a
# provisioning script (setup-iis.ps1, setup-nginx.ps1) answers "what should
# I do next" - but that decision still needs Doctor's own answer reshaped
# into the specific question a provisioning script actually has ("am I
# about to configure a second, competing reverse proxy", "is this port
# conflict actually just DELTA's own other provider", "what would actually
# need to be stopped, and is that even safe"). Functions in this section
# exist so that reshaping happens exactly once, here, rather than each
# provisioning script re-deriving its own interpretation of
# Get-DeltaReverseProxyState's own result - or, per the Reverse Proxy
# Handover Plan architecture correction below, inventing its own
# assumptions about what stopping a provider actually requires.

function Get-DeltaReverseProxyConflictingProvider {
    <#
      Given $ReverseProxyState (Get-DeltaReverseProxyState) and the name of
      the provider currently asking (so it never attributes a conflict to
      itself), returns the name of another DELTA-managed, currently ACTIVE
      provider if one exists - or $null otherwise. This is what lets a
      provisioning script classify a port conflict, or an about-to-happen
      fresh install, as "Expected" (a known, DELTA-owned reverse proxy is
      already active - explain the situation, offer to continue anyway)
      rather than "Unexpected" (Doctor cannot attribute this to DELTA at
      all - the caller's own existing conflict handling, e.g. displaying
      the raw blocking process, remains exactly appropriate).

      Deliberately does NOT re-derive this from the port/process itself -
      it is purely a reshaping of Doctor's own already-computed ownership
      answer (ManagedByDelta/Active on each provider's own state), per
      this feature's own central "ownership must come from configuration,
      never from ports/processes/PID/registry/service status" principle.
      A provider that is merely ManagedByDelta but not Active is not
      returned here - an inactive, DELTA-owned provider does not explain a
      live port conflict.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$ReverseProxyState,
        [Parameter(Mandatory)][string]$RequestingProviderName
    )

    $conflicting = $ReverseProxyState.ProviderStates | Where-Object {
        $_.Name -ne $RequestingProviderName -and $_.ManagedByDelta -and $_.Active
    } | Select-Object -First 1

    if ($conflicting) {
        return $conflicting.Name
    }
    return $null
}

function Get-DeltaReverseProxyHandoverPlan {
    <#
      ARCHITECTURE CORRECTION (Manual Reverse Proxy Handover): the
      original version of this feature asked every provider to blindly
      "please stop yourself" - discovered, via real IIS testing, to be
      insufficient (stopping the DELTA-managed website does not release a
      port IIS's own stock "Default Web Site" is also bound to). Doctor
      now answers the real question instead: "what must actually be
      stopped for $RequestingProviderName to safely take ownership of the
      ports it needs, and is doing so automatically even safe" - this
      function is the one place that answer gets built, so a provisioning
      script never independently decides what to stop.

      SECOND ARCHITECTURE CORRECTION: which OTHER provider(s) even get
      asked is deliberately NOT decided via Get-DeltaReverseProxyConflictingProvider
      (above) - that function answers a genuinely different question
      ("is another DELTA-managed provider currently ACTIVE" - exactly
      right for setup-nginx.ps1's own "am I about to configure a second,
      competing reverse proxy" fresh-install gate, which only cares about
      a provider that is actually serving traffic right now). This
      function's own question is port occupancy, not activity: a
      DELTA-managed IIS site that is itself Stopped can still leave its
      OWN stock "Default Web Site" sitting on port 80 - a real machine
      confirmed this - so gating on Active here would silently skip
      asking IIS to plan at all in exactly the case its own
      GetHandoverPlan (Get-DeltaIisReverseProxyHandoverPlan,
      lib\DeltaDoctor.IIS.ps1) was written to handle: that function
      already scans real port bindings directly, never the DELTA-managed
      site's own .state, which is what makes it safe to consult
      regardless of Active. So: every OTHER provider this
      $ReverseProxyState reports as ManagedByDelta (ownership, never
      activity - see this file's own header) is a candidate; each
      candidate's own registered GetHandoverPlan is trusted completely
      to answer "does any of MY OWN real estate actually occupy a
      required port, and is stopping it safe" - this function never
      pre-filters that answer using Active, or any other runtime signal
      of its own.

      Purely a dispatcher, exactly like Get-DeltaReverseProxyState's own
      provider loop: resolves $RequestingProviderName's OWN required
      ports via that provider's own registered GetRequiredPorts
      (Get-DeltaReverseProxyProviderDefinitions - what matters is what
      the REQUESTING provider needs freed, never what the candidate one
      happens to think its own required ports are), then delegates
      entirely to the candidate provider's own registered GetHandoverPlan
      to actually build the plan
      (Get-DeltaIisReverseProxyHandoverPlan/Get-DeltaNginxReverseProxyHandoverPlan) -
      this function has no IIS/NGINX-specific knowledge of its own and
      never will, regardless of how many providers this feature ends up
      supporting.

      Returns $null only when there is no DELTA-managed candidate
      provider to even ask (nothing to consult at all) or the requesting
      provider itself isn't registered - never as a stand-in for "nothing
      to do". Once a candidate exists, its own GetHandoverPlan result is
      returned exactly as built, unsafe/refused (Plan.IsSafe -eq $false)
      or safe with an empty Plan.Actions (that candidate's own real
      estate simply isn't occupying anything right now) included - a
      provisioning script's own caller (Invoke-DeltaReverseProxyHandover,
      lib\DeltaInstaller.Common.ps1) is what distinguishes "nothing to
      do" from "actions to confirm and execute", via Plan.Actions.Count,
      never via this function returning $null. Still purely read-only:
      builds and returns a plain data object describing what WOULD need
      to happen - see each provider's own GetHandoverPlan for why neither
      this function nor they ever stop anything themselves.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$ReverseProxyState,
        [Parameter(Mandatory)][string]$RequestingProviderName
    )

    $definitions = Get-DeltaReverseProxyProviderDefinitions
    $requestingDefinition = $definitions | Where-Object { $_.Name -eq $RequestingProviderName } | Select-Object -First 1
    if (-not $requestingDefinition) {
        return $null
    }

    # A real, independently-confirmed bug this guards against: when the
    # Where-Object pipeline below matches nothing (e.g. a genuinely
    # IIS-only machine where NGINX was never installed at all -
    # ManagedByDelta is $false, never merely absent from the array;
    # Get-DeltaReverseProxyState's own provider loop always returns an
    # entry for every registered provider), Select-Object -First 1
    # returns $null, and accessing `.Name` directly on that (the
    # original, one-line form of this lookup) throws "The property
    # 'Name' cannot be found on this object" under this project's own
    # Set-StrictMode -Version Latest - silently contradicting this
    # function's own documented "returns $null only when there is no
    # DELTA-managed candidate provider to even ask" contract. Checking
    # the candidate STATE object's own truthiness first, before ever
    # touching a property on it, is what actually fulfills that contract.
    $candidateProviderState = $ReverseProxyState.ProviderStates | Where-Object {
        $_.Name -ne $RequestingProviderName -and $_.ManagedByDelta
    } | Select-Object -First 1

    if (-not $candidateProviderState) {
        return $null
    }

    $candidateProviderName = $candidateProviderState.Name

    $candidateDefinition = $definitions | Where-Object { $_.Name -eq $candidateProviderName } | Select-Object -First 1
    if (-not $candidateDefinition) {
        return $null
    }

    $requiredPorts = & $requestingDefinition.GetRequiredPorts
    return & $candidateDefinition.GetHandoverPlan -RequiredPorts $requiredPorts
}

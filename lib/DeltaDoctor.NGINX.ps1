<#
.SYNOPSIS
    Shared NGINX detection for the Doctor framework - installation location,
    the DELTA-managed virtual host, and the pid-file-based runtime state
    machine - consumed by both doctor.ps1 (via lib\DeltaDoctor.ReverseProxy.ps1)
    and setup-nginx.ps1.

.DESCRIPTION
    Mirrors lib\DeltaDoctor.IIS.ps1's own architecture exactly - see that
    file's own header for the full rationale. Originally every function and
    constant here lived in setup-nginx.ps1 itself; promoted out to this
    shared file once doctor.ps1's own Reverse Proxy Detection feature needed
    the identical "is NGINX installed, is there a DELTA-managed virtual
    host, what runtime state is it actually in" facts setup-nginx.ps1's own
    management menu already computes - rather than doctor.ps1 growing a
    second, private copy of any of it. setup-nginx.ps1 is a CONSUMER of this
    file now, never a second implementation of it.

    Owns, in order:
      - The fixed, well-known NGINX installation location and the DELTA
        virtual host's own fixed identity within it (the equivalent of
        lib\DeltaDoctor.IIS.ps1's $Script:DeltaIisSiteName).
      - The pid-file-based Managed Runtime State machine
        (Get-DeltaNginxRuntimeState: NotInstalled/Stopped/Running/Broken) -
        this project's own "never trust a single signal (a process existing,
        a pid file existing) alone" discipline, unchanged from its original
        setup-nginx.ps1 implementation.
      - Get-DeltaNginxVHostSummary - a best-effort, never-throws read of the
        already-generated DELTA virtual host, extended here with an
        IsDeltaOwned content-marker check (this file's own addition - see
        that function's own header for why) beyond what setup-nginx.ps1's
        original version needed for its own read-only management-menu
        display.
      - Get-DeltaNginxRequiredPorts - the ports a DELTA-managed vhost
        should be listening on, derived from the live config file rather
        than any in-memory, current-run-only flag.

    Explicitly NOT owned here (stays in setup-nginx.ps1, since it is
    provisioning/lifecycle, not detection): installing NGINX itself, the SSL
    Certificate Wizard, writing nginx.conf/delta.conf
    (New-DeltaNginxConfiguration), running `nginx -t`
    (Test-DeltaNginxConfiguration - a live subprocess invocation with a
    documented pid-file side effect, deliberately never called from the
    read-only Doctor), STARTING NGINX (Start-DeltaNginx - install-specific
    startup validation tied to setup-nginx.ps1's own in-memory SSL/port
    state), and the interactive management menu.

    Owns one lifecycle primitive as of the Manual Reverse Proxy Handover
    feature: STOPPING a managed, running NGINX instance
    (Stop-DeltaManagedNginx, and the Send-DeltaNginxSignal it's built on) -
    promoted here, out of setup-nginx.ps1's own original
    Invoke-DeltaNginxSignal/Invoke-DeltaNginxStop, once setup-iis.ps1
    needed the identical action for its own side of that feature (stopping
    NGINX so IIS can bind the port instead). This is the one function in
    this file that changes live process state rather than only reading
    it - see that function's own header for why this doesn't contradict
    "Doctor stays read-only" (it isn't Doctor; it's a shared lifecycle
    primitive Doctor's own consumers call, the same way
    lib\DeltaDoctor.IIS.ps1's Repair-DeltaIisManagedWebsite already does
    for IIS).

    Also owns Get-DeltaNginxReverseProxyHandoverPlan/
    Invoke-DeltaNginxReverseProxyHandoverPlan (this file's own Reverse
    Proxy Handover Plan section, further down) - the NGINX-side half of
    the Handover Plan architecture correction: Doctor now PLANS what must
    be stopped for another provider to safely take ownership of a port,
    rather than every provider being asked to blindly "please stop
    yourself" (see lib\DeltaDoctor.IIS.ps1's own header for the full
    rationale - NGINX's own version of this is simple by comparison,
    since a single managed instance is always the entire occupant of its
    own ports).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeltaInstaller.Common.ps1')

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
#
# The fixed, well-known NGINX installation location and the DELTA virtual
# host's own fixed identity within it - moved here verbatim from
# setup-nginx.ps1's own top-of-file Configuration section, since every
# function that reads them now lives in this file (or, for
# $Script:NginxMainConfigPath/$Script:NginxConfDDirectory specifically,
# setup-nginx.ps1's own provisioning code still reads them too - dot-
# sourcing this file is what makes them available there without a second,
# separate declaration).

$Script:NginxHome            = 'C:\nginx'
$Script:NginxExePath         = Join-Path -Path $Script:NginxHome -ChildPath 'nginx.exe'
$Script:NginxConfDirectory   = Join-Path -Path $Script:NginxHome -ChildPath 'conf'
$Script:NginxMainConfigPath  = Join-Path -Path $Script:NginxConfDirectory -ChildPath 'nginx.conf'
$Script:NginxConfDDirectory  = Join-Path -Path $Script:NginxConfDirectory -ChildPath 'conf.d'
$Script:DeltaVHostConfigPath = Join-Path -Path $Script:NginxConfDDirectory -ChildPath 'delta.conf'

# Managed Runtime State - the pid file location this installer owns and
# asserts, rather than trusting nginx's own undocumented compiled-in
# default to agree with $Script:NginxHome. templates\nginx\nginx.conf pins
# an explicit `pid logs/nginx.pid;` directive to match this exactly (see
# that template's own header) - Get-DeltaNginxPidFilePath is the one place
# this file computes it, so nothing else re-derives it.
$Script:NginxLogsDirectory = Join-Path -Path $Script:NginxHome -ChildPath 'logs'
$Script:NginxPidFilePath   = Join-Path -Path $Script:NginxLogsDirectory -ChildPath 'nginx.pid'

# The distinctive header comment both DELTA vhost templates
# (templates\nginx\delta-http.conf/delta-https.conf) carry as their very
# first line ("# DELTA - NGINX Reverse Proxy Configuration (HTTP/HTTPS)") -
# the direct NGINX analogue of templates\iis\web.config's own
# `<rule name="DELTA Reverse Proxy"` marker
# (lib\DeltaDoctor.IIS.ps1's Get-DeltaDoctorWebsiteChecks). Matched as a
# substring (both templates share this exact prefix, differing only in the
# trailing "(HTTP)"/"(HTTPS)") - see Get-DeltaNginxVHostSummary's own
# IsDeltaOwned field for why this is checked in addition to, not instead
# of, the ServerName/BackendUrl shape-matching setup-nginx.ps1's own
# original version of that function already did.
$Script:DeltaNginxVHostOwnershipMarker = 'DELTA - NGINX Reverse Proxy Configuration'

# ---------------------------------------------------------------------------
# Managed Runtime State
# ---------------------------------------------------------------------------
#
# Historical bug this section exists to fix: code that decided "is NGINX
# running" by checking ONLY for a live nginx.exe process, or ONLY for a pid
# file's existence. Those are two independent facts that can disagree (an
# externally deleted pid file, an incomplete prior shutdown, an instance
# started outside this script's control, etc.), and single-signal detection
# had no way to notice.
#
# This section makes the pid file the primary source of truth, exactly the
# way nginx itself decides who its master process is - process enumeration
# (Get-DeltaNginxManagedProcesses) is used only to (a) tell a genuinely
# clean Stopped state apart from a stale pid file with nothing actually
# running, and (b) supply setup-nginx.ps1's own Force Stop recovery
# action's target. It is never used, by itself, to decide "Running" - and
# per this project's own "ownership must come from configuration DELTA
# created, never from process/PID/port state alone" principle
# (doctor.ps1's own Reverse Proxy Detection feature), it is likewise never
# used to decide "managed by DELTA" either - that is Get-DeltaNginxVHostSummary's
# job, entirely independent of anything in this Runtime State section.

function Get-DeltaNginxPidFilePath {
    <#
      The one place this file computes the expected pid file location -
      $Script:NginxPidFilePath, matching the explicit `pid logs/nginx.pid;`
      directive templates\nginx\nginx.conf pins (see that template's own
      header) rather than nginx's undocumented compiled-in default.
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
      not just one - setup-nginx.ps1's own Invoke-DeltaNginxForceStop needs
      the complete set to terminate, and Get-DeltaNginxRuntimeState needs
      it to tell a clean Stopped state apart from a Broken one.

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
      The one function that decides what runtime state NGINX is actually
      in - consumed by setup-nginx.ps1's own management menu, Start/Reload/
      Stop/Restart actions, AND doctor.ps1's own Reverse Proxy Detection
      "Active" signal (never its "Managed by DELTA" signal - see this
      section's own header). Returns a [PSCustomObject]:

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
      all, a pid file whose PID has been silently reused by an unrelated
      program, etc. Never silently normalized to Stopped or Running -
      always reported with a specific Reason instead.
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

# ---------------------------------------------------------------------------
# DELTA Virtual Host Discovery
# ---------------------------------------------------------------------------
#
# Read-only: never creates, modifies, or deletes any NGINX configuration.

function Get-DeltaNginxVHostSummary {
    <#
      Best-effort read of the already-generated DELTA virtual host
      ($Script:DeltaVHostConfigPath) - never re-prompts for the website
      domain or backend port the way a fresh install's own
      Resolve-DeltaWebsiteDomain/Resolve-DeltaBackendPort do, since an
      existing installation's configuration is exactly what should be
      displayed as-is, not re-derived or re-asked for. Returns a result
      with every field at its default (ServerName/BackendUrl $null,
      IsHttps/IsDeltaOwned $false) when delta.conf is missing, rather than
      throwing - every caller (setup-nginx.ps1's own read-only management
      menu, doctor.ps1's own Reverse Proxy Detection) must degrade
      gracefully, never block on a missing or unrecognized file.

      IsDeltaOwned is this file's own addition beyond setup-nginx.ps1's
      original version of this function (which only ever needed
      ServerName/BackendUrl/IsHttps for its own read-only display, not an
      ownership verdict): whether the file's content contains
      $Script:DeltaNginxVHostOwnershipMarker, the distinctive header
      comment both DELTA vhost templates carry. Doctor's own "does this
      reverse proxy configuration belong to DELTA?" question
      (docs\todo's own Reverse Proxy Detection design principle - never
      decided from ports/processes/PID/registry/service status) needs a
      stronger signal than "a file happens to exist at this exact path and
      happens to contain parseable server_name/proxy_pass directives" -
      an administrator's own, unrelated nginx config could coincidentally
      satisfy that shape. ManagedByDelta, in every caller, is therefore
      IsDeltaOwned - never merely "the file exists" or "ServerName/BackendUrl
      parsed successfully" alone.
    #>

    $result = [PSCustomObject]@{
        ServerName   = $null
        BackendUrl   = $null
        IsHttps      = $false
        IsDeltaOwned = $false
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
    $result.IsDeltaOwned = $content.Contains($Script:DeltaNginxVHostOwnershipMarker)

    return $result
}

function Get-DeltaNginxRequiredPorts {
    <#
      Determines the ports a DELTA-managed vhost should be listening on -
      deliberately NOT the same thing as setup-nginx.ps1's own
      Get-DeltaNginxExpectedPorts (Startup Validation), which decides
      based on $Script:SslCertificateConfigured - an in-memory flag only
      ever set during a live setup-nginx.ps1 run, meaningless to a fresh
      doctor.ps1 process that never ran the SSL wizard. Using
      Get-DeltaNginxVHostSummary instead reflects an EXISTING
      installation's real, already-generated deployment mode - a fresh
      install with no vhost file written yet naturally falls back to port
      80 alone, the one port required regardless of which mode a
      not-yet-run SSL wizard ends up choosing. Never assumes HTTPS.
    #>
    if ((Get-DeltaNginxVHostSummary).IsHttps) {
        return ,@(80, 443)
    }
    return ,@(80)
}

# ---------------------------------------------------------------------------
# Managed Lifecycle - Stop (Manual Reverse Proxy Handover)
# ---------------------------------------------------------------------------
#
# The one section in this file that changes live process state - see this
# file's own header for why that's still consistent with "Doctor stays
# read-only" (this isn't Doctor - it's a shared lifecycle primitive Doctor's
# own consumers call). Starting NGINX remains setup-nginx.ps1's own job
# (Start-DeltaNginx) - only stopping an already-running, already-managed
# instance is reusable enough, and simple enough, to promote here.

function Send-DeltaNginxSignal {
    <#
      Sends an `-s <Signal>` control signal (reload/quit/...) to the
      NGINX instance at $Script:NginxHome. Promoted here from
      setup-nginx.ps1's own original Invoke-DeltaNginxSignal so
      Stop-DeltaManagedNginx (below) - and any future caller that needs
      to signal a running, managed NGINX instance (uninstall.ps1, a
      future reverse-proxy.ps1) - share the identical implementation,
      including its stderr-vs-$ErrorActionPreference workaround (`nginx
      -s ...` writes its result to stderr even on success - the same fix
      applied around `nginx -t` elsewhere in this project), rather than
      each carrying its own copy. Requires Administrator privileges -
      controlling a process bound to a privileged port always does,
      regardless of which specific signal is sent.
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
        $outputLines = @($output | ForEach-Object { $_.ToString() })
        Stop-Setup "Failed to send '$Signal' to NGINX: $(($outputLines -join [Environment]::NewLine).Trim())"
    }
}

function Stop-DeltaManagedNginx {
    <#
      Stops ONLY the DELTA-managed, currently-Running NGINX instance
      (Get-DeltaNginxRuntimeState's own 'Running' verdict - never a bare
      process-name match) via a graceful `-s quit`, then polls
      (Wait-Until, lib\DeltaInstaller.Common.ps1) until the runtime state
      confirms a genuinely clean 'Stopped' state - not merely "no
      process", which would also be true of 'Broken' (a process gone but
      the pid file left behind; see this file's own Managed Runtime
      State section header for why that distinction matters). Never
      terminates an unrelated nginx.exe process, never uninstalls NGINX,
      and never touches nginx.conf/delta.conf. A no-op, reported plainly,
      if NGINX is already stopped or not installed at all.

      Shared lifecycle primitive: the exact function the Manual Reverse
      Proxy Handover feature's own setup-iis.ps1 side calls when the
      administrator opts to stop NGINX so IIS can bind its ports instead
      (Invoke-DeltaReverseProxyHandover, lib\DeltaInstaller.Common.ps1),
      and the same one setup-nginx.ps1's own management menu ("Stop
      NGINX", "Restart NGINX") now calls too, rather than each carrying
      its own copy of this exact stop-and-wait sequence.
    #>

    $state = Get-DeltaNginxRuntimeState
    if ($state.State -eq 'NotInstalled' -or $state.State -eq 'Stopped') {
        Write-Host ''
        Write-Detail 'NGINX is not running - nothing to stop.'
        return
    }

    if ($state.State -eq 'Broken') {
        Stop-Setup @"
NGINX is in an inconsistent runtime state and cannot be stopped safely.

$($state.Reason)

Resolve this from setup-nginx.ps1's own management menu (Force Stop Managed Process) first.
"@
    }

    Write-Step 'Stopping NGINX...'
    Send-DeltaNginxSignal -Signal 'quit'

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

# ---------------------------------------------------------------------------
# Reverse Proxy Handover Plan
# ---------------------------------------------------------------------------
#
# The NGINX-side counterpart to lib\DeltaDoctor.IIS.ps1's own Reverse Proxy
# Handover Plan section - see that section's own header for the full
# architecture this mirrors. Much simpler here: unlike IIS (where multiple
# independent SITES can each hold their own url reservation on the same
# machine, only some of which DELTA owns), a single managed NGINX
# installation IS the entire occupant of its own required ports whenever
# it's actually Running (Get-DeltaNginxRuntimeState) - there is no NGINX
# equivalent of IIS's own "Default Web Site"/unrelated-site possibility, so
# this plan is always safe.

function Get-DeltaNginxReverseProxyHandoverPlan {
    <#
      Doctor's own NGINX-side answer to "what must actually be stopped for
      another provider to safely take ownership of $RequiredPorts" - see
      this file's own Reverse Proxy Handover Plan section header. Always
      IsSafe (the single managed NGINX instance is, by definition, either
      fully DELTA-owned or not running at all - there is no third-party
      occupant possibility the way an unrelated IIS site is). $RequiredPorts
      is supplied by the caller (the REQUESTING provider's own required
      ports - e.g. IIS's own), carried straight through onto the plan
      purely so Invoke-DeltaReverseProxyHandover (lib\DeltaInstaller.Common.ps1)
      knows what to verify released afterward - never used to decide
      anything here.
    #>
    param([Parameter(Mandatory)][int[]]$RequiredPorts)

    return [PSCustomObject]@{
        Provider       = 'NGINX'
        Actions        = @('Stop NGINX')
        RequiredPorts  = $RequiredPorts
        ExpectedResult = 'Ports released'
        IsSafe         = $true
        Reason         = $null
        SiteNames      = $null
        Execute        = ${function:Invoke-DeltaNginxReverseProxyHandoverPlan}
    }
}

function Invoke-DeltaNginxReverseProxyHandoverPlan {
    <#
      Executes an already-confirmed Handover Plan
      (Get-DeltaNginxReverseProxyHandoverPlan, above) - calls straight
      through to the existing Stop-DeltaManagedNginx, which already
      implements the full stop-and-verify sequence this plan's own single
      action requires. $Plan is accepted (not read) purely to keep the
      same -Plan interface every provider's own Invoke-Delta<Provider>ReverseProxyHandoverPlan
      shares, so Invoke-DeltaReverseProxyHandover can call any of them
      identically via $Plan.Execute.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Plan)

    Stop-DeltaManagedNginx
}

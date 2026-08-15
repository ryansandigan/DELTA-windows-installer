<#
.SYNOPSIS
    Shared helpers for the DELTA Windows installer scripts.

.DESCRIPTION
    Dot-sourced by setup.ps1, init_db.ps1, and upgrade_database.ps1 - the
    point at which three independent entry-point scripts need the same
    logic (console output vocabulary, error handling, PostgreSQL
    executable discovery, credential handling, DATABASE_URL construction)
    is exactly where this project's own established convention (extract
    only once duplication actually appears, not in anticipation of it -
    see docs/parked/docker-containerization-design.md's Design
    Principles) says to extract it, rather than let a third copy of
    Find-PostgresInstallation/Stop-Setup/etc. appear.

    This is a plain dot-sourced file, not a .psm1 module: these are
    installer scripts meant to be run directly, not components imported
    into a larger codebase, so there is no manifest, versioning, or
    Export-ModuleMember machinery to justify - just functions that need
    to exist in the caller's own scope before it uses them.

    IMPORTANT: because this file computes nothing from its own
    $PSScriptRoot, every script that dot-sources it must define
    $Script:ProjectRoot (from *its own* $PSScriptRoot) beforehand -
    $PSScriptRoot inside a dot-sourced file refers to the file's own
    location (this lib/ directory), never the caller's, so any
    project-root-relative logic has to live in the caller instead.
#>

$Script:BannerWidth = 40

# Manual Reverse Proxy Handover (see Invoke-DeltaReverseProxyHandover, further
# down this file) - set $true only once a handover actually ran and
# confirmed the other provider's ports released; a caller's own subsequent
# successful start checks and resets this to trigger the feature's own
# "run Doctor again" final validation. Initialized here, unconditionally,
# rather than left for its first read to discover - Set-StrictMode -Version
# Latest (every entry-point script in this project sets it) throws on a
# read of a $Script: variable that was never assigned at all, and a run
# with no handover involved must still be able to check this flag safely.
$Script:DeltaReverseProxyHandoverOccurred = $false

# Confirm-DeltaRuntimeNotRunning/Start-DeltaRuntimeForValidation/
# Confirm-DeltaRuntimeStarted (further down this file) all read this
# unconditionally - only ever set $true by setup.ps1's own
# Resolve-DeltaApplicationPort, when the operator declines to restart an
# already-running managed instance. setup-nginx.ps1/setup-iis.ps1 (via
# Restart-DeltaRuntimeForReverseProxy) never set it at all, so it must
# still be initialized here - same Set-StrictMode reasoning as
# $Script:DeltaReverseProxyHandoverOccurred just above - for their own
# restart to read it safely and always take the "not skipped" branch.
$Script:DeltaSkipManagedInstanceRestart = $false

# The DEFAULT DELTA *runtime* application directory - offered as the
# bare-Enter default when Read-DeltaAppRoot prompts for where DELTA
# should actually be deployed. Deliberately separate from
# $Script:ProjectRoot (each entry-point script's own $PSScriptRoot, i.e.
# the installer repository itself): the installer repository is installer
# code only, never the running application. This is only ever a
# fallback/default value now, not the actual runtime location - every
# script resolves the real location into its own $Script:DeltaRuntimeRoot
# (set by Resolve-DeltaAppRoot in setup.ps1, or by the -AppRoot parameter
# / Read-DeltaAppRoot prompt in init_db.ps1/upgrade_database.ps1), never
# by reading this constant directly. Defined once, in this shared file,
# so all three entry-point scripts offer the identical default rather
# than three separately-hardcoded copies of it.
$Script:DefaultDeltaRuntimeRoot = 'C:\DELTA'

# The single, authoritative registry location every DELTA installer utility
# reads and writes - setup.ps1 (Register-DeltaInstallation's InstallPath/
# Version, Get-/Set-DeltaManagedInstanceRestartPolicy's operator preference),
# Get-DeltaInstallPath below, and lib\DeltaInstaller.Service.ps1's
# intentional-disable marker (Set-/Clear-/Test-DeltaServiceDisabledByUninstall).
# Defined HERE, in the shared file every one of those loads, rather than
# separately in each - the path had already been written out by hand in two
# places before this, which is exactly the drift this constant removes.
$Script:DeltaRegistryKeyPath = 'HKLM:\SOFTWARE\PreventionWeb\DELTA'

# ---------------------------------------------------------------------------
# Console output vocabulary
# ---------------------------------------------------------------------------

function Write-SetupBanner {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Subtitle
    )
    $rule = '=' * $Script:BannerWidth
    Write-Host $rule
    Write-Host $Title
    Write-Host $Subtitle
    Write-Host $rule
    Write-Host ''
}

function Write-PhaseBanner {
    <#
      A lighter-weight separator than Write-SetupBanner, printed at the
      start of each phase/stage so console output stays readable once
      more than one runs in the same invocation.
    #>
    param([Parameter(Mandatory)][string]$PhaseLabel)
    Write-Host ''
    Write-Host "---- $PhaseLabel ----" -ForegroundColor DarkCyan
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Detail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    $Message"
}

function Write-Success {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Stop-Setup {
    <#
      Raises a terminating error with a clear, human-readable message.
      Every entry-point script (setup.ps1, init_db.ps1,
      upgrade_database.ps1) owns exactly one top-level try/catch that
      converts this into its own error banner and process exit code -
      functions never call exit directly, so the same function behaves
      identically whether it's running standalone or invoked as a
      sibling script by setup.ps1.
    #>
    param([Parameter(Mandatory)][string]$Message)
    throw $Message
}

function Read-DeltaYesNoConfirmation {
    <#
      The shared shape behind every Y/N confirmation prompt in this
      project (setup-nginx.ps1's own Read-DeltaNginxInstallConfirmation,
      Read-DeltaNginxStartConfirmation, Read-DeltaNginxForceStopConfirmation
      - three copies of the identical surrounding boilerplate before this
      was promoted here): a '-' rule, the caller-supplied body, a '[y/N]'
      prompt, and a closing rule. Bare Enter (or anything other than Y/y)
      always means No - the same "blank means the safe choice" convention
      every confirmation in this project follows.

      $Body is a scriptblock that writes whatever question-specific text
      belongs between the opening rule and the prompt (ending in whatever
      question line makes sense for that caller - "Continue?", "Start
      NGINX now?", etc.) - this function has no opinion on that content,
      only on the rule/prompt/rule frame around it. Invoked with `& $Body`
      exactly like Wait-Until invokes its own -Condition scriptblock above
      - PowerShell scriptblocks retain the scope they were lexically
      defined in, so a $Body written inline at a call site can still read
      that caller's own local variables (e.g. Read-DeltaNginxForceStopConfirmation's
      $Targets) without needing to pass them through this function
      explicitly.
    #>
    param([Parameter(Mandatory)][scriptblock]$Body)

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    & $Body
    Write-Host ''
    $choice = Read-Host -Prompt '[y/N]'
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)

    return ($choice.Trim() -in @('Y', 'y'))
}

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Long-running process activity indicator
# ---------------------------------------------------------------------------

function Start-ProcessWithActivityIndicator {
    <#
      Generic wrapper around Start-Process for long-running, silent child
      processes (installers, in particular) that otherwise give the
      operator no sign the installer is still alive for several minutes
      at a time. Purely a console UX layer: every caller still gets back
      the same System.Diagnostics.Process a plain Start-Process -PassThru
      -Wait would have returned (including its .ExitCode once the
      process has exited), so every existing exit-code check, log path,
      and Stop-Setup error message at each call site is completely
      unaffected - callers only replace their own Start-Process call
      with this one.

      Two ways to use it:
        - Pass -FilePath (and optionally -ArgumentList/-WorkingDirectory/
          -RedirectStandardInput) and this function starts the process
          itself.
        - Pass an already-started -Process (from Start-Process -PassThru,
          deliberately NOT -Wait) for a caller that needs Start-Process
          options this function doesn't expose directly.

      While the child process runs, a single console line is updated in
      place (carriage return, not repeated Write-Host calls) with a
      cycling dot trail and an elapsed mm:ss timer (e.g. "Installing
      PostgreSQL..... (02:14)"), polled via Process.WaitForExit(500) - no
      Start-Sleep racing the exit, and never more than one visible line
      per activity. The timer is measured from $Process.StartTime (the
      child process's own actual start time, not when this function
      happened to be called) and simply stops being displayed the
      instant the process exits, along with the rest of the line. If the
      console output is redirected (e.g. piped to a
      log file, where \r has no visible effect), the same 500ms poll
      instead emits a fresh line, but throttled to once every 2 seconds
      so a multi-minute install can't flood the log. Either way, the
      moment the process exits - success or failure alike - the line is
      cleared immediately, so whatever the caller prints next (its own
      success message, or Stop-Setup's error message on a non-zero exit
      code) appears cleanly on its own line, exactly as it does today.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Command')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Command')]
        [string]$FilePath,

        [Parameter(ParameterSetName = 'Command')]
        [string]$ArgumentList,

        [Parameter(ParameterSetName = 'Command')]
        [string]$WorkingDirectory,

        [Parameter(ParameterSetName = 'Command')]
        [string]$RedirectStandardInput,

        [Parameter(Mandatory, ParameterSetName = 'Process')]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory)]
        [string]$ActivityName
    )

    if ($PSCmdlet.ParameterSetName -eq 'Command') {
        # Built on System.Diagnostics.Process directly rather than the
        # Start-Process cmdlet: confirmed directly that Start-Process
        # -PassThru, when used WITHOUT -Wait (a requirement here, since
        # this function needs to poll the process itself to animate),
        # can return a Process object whose .ExitCode never becomes
        # readable (silently $null) even after WaitForExit() confirms
        # HasExited - a cmdlet-specific quirk, not present when driving
        # System.Diagnostics.Process directly. Every exit-code check at
        # every call site depends on ExitCode being trustworthy, so this
        # sidesteps the cmdlet entirely instead of working around it.
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        if ($ArgumentList)     { $startInfo.Arguments = $ArgumentList }
        if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
        if ($RedirectStandardInput) { $startInfo.RedirectStandardInput = $true }

        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $startInfo
        [void]$Process.Start()

        if ($RedirectStandardInput) {
            # Mirrors Start-Process -RedirectStandardInput <path>: feed the
            # file's bytes to the child's stdin, then close it so the
            # child sees EOF rather than blocking on further input.
            $stdinBytes = [System.IO.File]::ReadAllBytes($RedirectStandardInput)
            if ($stdinBytes.Length -gt 0) {
                $Process.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)
            }
            $Process.StandardInput.Close()
        }
    }

    $inPlace           = -not [Console]::IsOutputRedirected
    $dots              = 0
    $maxDots           = 6
    $lastLineLength    = 0
    $lastFallbackPrint = Get-Date

    # $Process.StartTime (not Get-Date here) so the timer reflects when the
    # child process itself actually started - matters for the -Process
    # parameter set, where the process may already have been running for a
    # moment before this function was ever called.
    $startTime = $Process.StartTime

    while (-not $Process.WaitForExit(500)) {
        $dots = if ($dots -ge $maxDots) { 1 } else { $dots + 1 }
        $elapsed = [TimeSpan]::FromSeconds([Math]::Floor(((Get-Date) - $startTime).TotalSeconds))
        $line = "    $ActivityName" + ('.' * $dots) + " ($($elapsed.ToString('mm\:ss')))"

        if ($inPlace) {
            Write-Host "`r$($line.PadRight($lastLineLength))" -NoNewline
            $lastLineLength = $line.Length
        }
        elseif (((Get-Date) - $lastFallbackPrint).TotalSeconds -ge 2) {
            Write-Host $line
            $lastFallbackPrint = Get-Date
        }
    }

    # WaitForExit(int) can return true a moment before the process's exit
    # code is actually available (a documented .NET race - see
    # Process.WaitForExit's own remarks on synchronizing after the
    # timeout overload). The parameterless overload blocks until that
    # synchronization is guaranteed to have completed - effectively
    # instant here, since the process has already exited - so callers can
    # trust $Process.ExitCode immediately on return.
    $Process.WaitForExit()

    if ($inPlace -and $lastLineLength -gt 0) {
        Write-Host "`r$(' ' * $lastLineLength)`r" -NoNewline
    }

    return $Process
}

# ---------------------------------------------------------------------------
# Bounded third-party installer retry orchestration
# ---------------------------------------------------------------------------

function Invoke-DeltaComponentInstallWithRetry {
    <#
      Owns the generic mechanics of "a third-party installer can fail
      transiently and succeed on a clean second attempt" for setup.ps1's
      component phases (Node.js MSI, PostgreSQL EDB installer, PostGIS
      bundle) - one shared, strictly bounded loop instead of three
      hand-copied ones. Observed motivating case: the EDB PostgreSQL
      installer returning a non-zero exit code during extraction and
      leaving an incomplete install directory with no service and no
      initialized data directory, where an immediately-repeated clean
      attempt succeeds.

      This function owns ONLY the retry mechanics: the attempt cap
      (default 2 - never unlimited), attempt numbering, the short
      settling delay, the retry console messaging, and the final
      Stop-Setup on exhausted attempts. Everything component-specific
      stays at the call site, supplied as scriptblocks:

        -InstallAction   Runs ONE installer attempt and RETURNS its exit
                         code (never calls Stop-Setup on a non-zero code
                         itself - that decision now lives here). Receives
                         the current attempt number as its first argument
                         (declare param($Attempt)), so a caller can keep
                         attempt-specific installer logs.
        -TestComponentUsable
                         The component's own existing validation logic,
                         returning $true/$false. Consulted after a
                         non-zero exit code: installers can exit non-zero
                         after having actually installed a working
                         component, and a working component is never
                         retried (and never cleaned up).
        -CleanupAction   Optional. Safe, component-specific recovery from
                         artifacts the CURRENT failed attempt created.
                         Runs only when the installer failed AND
                         validation failed AND another attempt remains.
                         The safety rules (never touch anything that
                         existed before this setup run; never delete
                         based on the exit code alone) are the call
                         site's responsibility - this function has no
                         knowledge of what is safe to remove, so it
                         never removes anything itself.

      Scriptblocks are invoked with & and resolve the call site's own
      local variables exactly like Read-DeltaYesNoConfirmation's -Body
      (see its header) - no explicit parameter plumbing needed.

      On success this simply returns (the caller's existing post-install
      validation still runs unchanged after it). On failure of every
      attempt it calls Stop-Setup with a message that names the attempt
      count and points at the installer logs - and never includes
      passwords or installer command lines ($FailureLogHint must follow
      the same rule).
    #>
    param(
        [Parameter(Mandatory)][string]$ComponentName,
        [Parameter(Mandatory)][scriptblock]$InstallAction,
        [Parameter(Mandatory)][scriptblock]$TestComponentUsable,
        [scriptblock]$CleanupAction,
        [int[]]$SuccessExitCodes = @(0),
        [int]$MaxAttempts = 2,
        [int]$RetryDelaySeconds = 5,
        [string]$FailureLogHint
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $exitCode = & $InstallAction $attempt

        if ($SuccessExitCodes -contains $exitCode) {
            if ($attempt -gt 1) {
                Write-Success '    Retry completed successfully.'
            }
            return
        }

        Write-Detail "Installer returned exit code $exitCode."
        Write-Step "$ComponentName installation did not complete successfully."

        Write-Detail "Checking whether $ComponentName is nevertheless installed and usable..."
        if (& $TestComponentUsable) {
            Write-Detail "$ComponentName validated successfully despite the installer exit code - continuing without retry."
            return
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Step 'Preparing for one automatic retry...'
            if ($CleanupAction) {
                & $CleanupAction
            }
            if ($RetryDelaySeconds -gt 0) {
                Write-Detail "Waiting $RetryDelaySeconds second(s) before retrying..."
                Start-Sleep -Seconds $RetryDelaySeconds
            }
            Write-Detail "Retrying $ComponentName installation (attempt $($attempt + 1) of $MaxAttempts)..."
        }
    }

    $failureMessage = "$ComponentName installation failed after $MaxAttempts attempts. See the installer logs for details."
    if ($FailureLogHint) {
        $failureMessage = "$failureMessage $FailureLogHint"
    }
    Stop-Setup $failureMessage
}

function Write-DeltaTemplateFile {
    <#
      Engine-agnostic template rendering, shared by setup-nginx.ps1's own
      New-DeltaNginxConfiguration and (per
      docs\todo\TODO-setup-iis-enhancements.md, Phase 6) setup-iis.ps1's
      future web.config generation - originally setup-nginx.ps1's own
      Install-NginxConfigFile, promoted here once it became clear the
      function itself has no NGINX-specific knowledge at all: it knows
      nothing about nginx.conf, web.config, or XML, it simply loads a
      template, applies token replacements, and writes the result out.

      Writes $TemplatePath to $DestinationPath, unconditionally - no
      diffing against, or backing up, whatever might already be there.
      That is a decision each caller's own pre-conditions justify (e.g.
      setup-nginx.ps1 only ever calls this immediately after Install-Nginx
      has just extracted a brand-new NGINX, so there is no pre-existing,
      operator-meaningful configuration here worth protecting) - this
      function itself has no opinion on when that's safe, it just writes.

      $Replacements (optional) is an ordered set of literal token -> value
      substitutions applied to the template's text before it's written
      out. Omitted (or empty) for templates that need no substitution at
      all, in which case this still just copies the file byte-for-byte.

      Deliberately NOT Set-Content -Encoding utf8 for the substituted
      case: confirmed directly that Windows PowerShell 5.1's "utf8"
      encoding always prepends a UTF-8 byte-order mark, and nginx does
      not skip it - a BOM-prefixed conf.d\delta.conf fails `nginx -t`
      outright with "unknown directive" pointing at the file's own first
      line. [System.IO.File]::WriteAllText with an explicit
      UTF8Encoding($false) writes the same bytes back out with no BOM at
      all, which is what every other template (copied verbatim via
      Copy-Item, and therefore already BOM-free) also produces. Nothing
      about this guarantee is NGINX-specific - any consumer's generated
      file benefits from staying BOM-free the same way.
    #>
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$Description,
        [System.Collections.IDictionary]$Replacements
    )

    $destinationDirectory = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path -Path $destinationDirectory)) {
        New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
    }

    if ($Replacements -and $Replacements.Count -gt 0) {
        $content = Get-Content -LiteralPath $TemplatePath -Raw
        foreach ($token in $Replacements.Keys) {
            $content = $content.Replace($token, [string]$Replacements[$token])
        }
        $noBomUtf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($DestinationPath, $content, $noBomUtf8)
    }
    else {
        Copy-Item -LiteralPath $TemplatePath -Destination $DestinationPath -Force
    }

    Write-Success "    $Description written: $DestinationPath"
}

function Wait-Until {
    <#
      Polls $Condition (a scriptblock returning truthy/falsy) every
      $IntervalMilliseconds until it returns true or $TimeoutSeconds
      elapses, then returns whatever the condition's own last evaluation
      was - never throws itself, so the caller decides what a timeout
      actually means. The same "poll for a state change instead of
      trusting the instant a process handle exits" shape as
      Wait-ForPostgresServiceRunning below, generalized: that function
      waits on a Windows service reaching Running; this one waits on any
      caller-supplied condition, which is what uninstall.ps1 needs to
      confirm a just-uninstalled program's registry entry is actually
      gone.

      Exists specifically because of a confirmed race: several
      installers (NSIS-based ones, in particular - PostGIS's own bundle
      uninstaller, verified directly on a real machine) copy themselves
      to a temporary location and re-launch that copy to perform the
      actual cleanup - including deleting the Add/Remove Programs
      registry entry - and the ORIGINAL process (the one Start-Process
      was ever able to wait on) exits and reports success before that
      detached copy has necessarily finished. A validation check run in
      the same instant the wait returns can therefore observe the
      registry entry still present for a program that has, in every way
      that matters, already been fully uninstalled - not a failed
      uninstall, and not a validation pattern-matching bug, just a
      normal completion lag this needs to tolerate rather than treat as
      instantaneous.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [int]$TimeoutSeconds = 10,
        [int]$IntervalMilliseconds = 500
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) {
            return $true
        }
        Start-Sleep -Milliseconds $IntervalMilliseconds
    } while ((Get-Date) -lt $deadline)

    return [bool](& $Condition)
}

# ---------------------------------------------------------------------------
# Windows Programs and Features (uninstall) helpers
# ---------------------------------------------------------------------------

function Get-RegistryPropertyValue {
    <#
      Safely reads a possibly-absent property from a Get-ItemProperty
      result, returning $null instead of throwing when it isn't there.

      Registry "objects" have no fixed schema the way a real class does:
      Get-ItemProperty only ever attaches the properties that actually
      exist as values under that specific key, so sibling keys under the
      same parent routinely expose different property sets from each
      other - confirmed directly against this machine's own Uninstall
      registry hive, where 5 of 13 subkeys had no DisplayName value at
      all. Under this project's Set-StrictMode -Version Latest,
      $obj.SomeMissingProperty throws ("The property '...' cannot be
      found on this object") rather than quietly returning $null - the
      confirmed root cause of a real Get-InstalledProgramInfo failure:
      dot-notation property access on entries that were missing the
      property being read. Going through $obj.PSObject.Properties[$Name]
      explicitly, rather than dot-notation, is the idiomatic way to read
      a possibly-absent property under strict mode - the members
      collection's indexer returns $null for a genuinely absent property
      instead of throwing, which is what every caller here actually
      wants. Generic and reusable beyond this one caller - anywhere a
      dynamically-shaped object (registry results, parsed config, JSON)
      needs a property read that may legitimately not be there.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if (-not $property) {
        return $null
    }
    return $property.Value
}

function Get-InstalledProgramInfo {
    <#
      Looks up a program's "Programs and Features" registration (the same
      data Control Panel / Settings > Apps reads) by DisplayName, via the
      registry directly - never the Win32_Product WMI class, which is a
      well-documented Windows footgun: merely querying it silently
      triggers a consistency-check MSI reconfigure of every installed MSI
      package on the machine. Scans both registry views a 64-bit Windows
      Server exposes - HKLM:\...\Uninstall (native 64-bit apps) and
      HKLM:\...\WOW6432Node\...\Uninstall (32-bit apps under WOW64) -
      since a given installer isn't guaranteed to register in only one.

      Every property read from a raw registry result goes through
      Get-RegistryPropertyValue rather than dot-notation - see that
      function's own comment for why: a meaningful fraction of real
      Uninstall subkeys (hotfixes, updates, and other non-"program"
      entries Windows registers in the same hive) lack DisplayName
      entirely, and some that do have it still lack one or more of the
      other fields read here (QuietUninstallString and InstallLocation,
      in particular, are commonly absent even on legitimate program
      entries). None of that is an error condition - it's the normal,
      expected shape of this registry hive - so nothing here should ever
      throw just because a given subkey doesn't happen to have every
      field.

      Returned objects also carry RegistryKeyPath (the matched subkey's own
      PSPath) alongside the registry values themselves - added for
      uninstall.ps1's own orphaned-uninstall-entry cleanup, which needs to
      reliably Remove-Item the EXACT subkey a caller just matched, never a
      name re-derived from DisplayName (not guaranteed to equal the
      subkey's own name).

      $DisplayNamePattern is a -like wildcard pattern (e.g. '*PostgreSQL*'),
      matched case-insensitively (the default for -like) against each
      entry's DisplayName. ALWAYS returns a real array - never $null, and
      never a bare (non-array) PSCustomObject - regardless of whether
      zero, exactly one, or several entries matched, so every caller can
      unconditionally use .Count / index into it / pipe it without first
      checking what kind of thing came back. This guarantee needs the
      explicit unary-comma on the return statement below (`return
      ,@($matches)`, not `return @($matches)`): confirmed directly that
      PowerShell's own pipeline-output unwrapping otherwise collapses a
      zero-element array return into $null, and a one-element array
      return into that single element as a bare scalar - only a
      two-or-more-element array survives a plain `return @($matches)`
      as an actual array. That inconsistency was a second, independent
      bug alongside the DisplayName strict-mode failure - one that
      hadn't yet caused visible failures only because every current
      caller happens to pipe the result through `Select-Object -First 1`
      (safe against all three shapes), not because the function itself
      was actually returning what its own contract promised.
    #>
    param([Parameter(Mandatory)][string]$DisplayNamePattern)

    $uninstallKeyPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $rawEntries = @(Get-ItemProperty -Path $uninstallKeyPaths -ErrorAction SilentlyContinue)

    $matches = @(foreach ($entry in $rawEntries) {
        $displayName = Get-RegistryPropertyValue -InputObject $entry -Name 'DisplayName'
        if (-not $displayName) {
            continue
        }
        if ($displayName -notlike $DisplayNamePattern) {
            continue
        }

        [PSCustomObject]@{
            DisplayName          = $displayName
            DisplayVersion       = Get-RegistryPropertyValue -InputObject $entry -Name 'DisplayVersion'
            UninstallString      = Get-RegistryPropertyValue -InputObject $entry -Name 'UninstallString'
            QuietUninstallString = Get-RegistryPropertyValue -InputObject $entry -Name 'QuietUninstallString'
            InstallLocation      = Get-RegistryPropertyValue -InputObject $entry -Name 'InstallLocation'
            # $entry.PSPath - unlike every property above, this is a
            # pseudo-property the registry provider itself always attaches
            # to every Get-ItemProperty result (never a value that could be
            # absent under this project's own Set-StrictMode, so dot-notation
            # is safe here, unlike the Get-RegistryPropertyValue reads above) -
            # the one thing a caller needs to reliably target THIS EXACT
            # subkey for removal later (uninstall.ps1's own orphaned-entry
            # cleanup), rather than re-deriving/guessing a subkey name from
            # DisplayName, which is not guaranteed to match the key's own
            # name.
            RegistryKeyPath      = $entry.PSPath
        }
    })

    return ,$matches
}

function Split-UninstallCommand {
    <#
      Splits a registered UninstallString (as read from
      Get-InstalledProgramInfo) into the executable path Start-Process
      needs and whatever arguments, if any, were already registered
      alongside it - e.g. '"C:\Program Files\PostgreSQL\16\uninstall-
      postgresql.exe"' or, quoted differently, an unquoted
      'C:\bin\uninst.exe /SOMEFLAG'. Handles the quoted-path case
      explicitly (the common one whenever the path itself contains a
      space, e.g. anything under "Program Files") rather than naively
      splitting on the first space, which would otherwise cut a quoted
      path in half.
    #>
    param([Parameter(Mandatory)][string]$UninstallString)

    $trimmed = $UninstallString.Trim()

    if ($trimmed.StartsWith('"')) {
        $closingQuoteIndex = $trimmed.IndexOf('"', 1)
        if ($closingQuoteIndex -gt 0) {
            return [PSCustomObject]@{
                FilePath  = $trimmed.Substring(1, $closingQuoteIndex - 1)
                Arguments = $trimmed.Substring($closingQuoteIndex + 1).Trim()
            }
        }
    }

    $firstSpaceIndex = $trimmed.IndexOf(' ')
    if ($firstSpaceIndex -lt 0) {
        return [PSCustomObject]@{ FilePath = $trimmed; Arguments = '' }
    }
    return [PSCustomObject]@{
        FilePath  = $trimmed.Substring(0, $firstSpaceIndex)
        Arguments = $trimmed.Substring($firstSpaceIndex + 1).Trim()
    }
}

# ---------------------------------------------------------------------------
# DELTA installation discovery
# ---------------------------------------------------------------------------

function Get-DeltaInstallPath {
    <#
      The single, shared way any Windows installer utility - today just
      setup.ps1 registering itself (Register-DeltaInstallation), tomorrow
      setup-nginx.ps1/setup-iis.ps1/upgrade.ps1/uninstall.ps1 consuming it -
      discovers where DELTA is actually installed, instead of each script
      separately hardcoding a path or re-implementing its own registry/
      filesystem detection. Deliberately placed here rather than inside any
      one of those scripts, so all of them share exactly one resolution
      order rather than each maintaining its own copy.

      Returns the resolved installation directory as a plain string, or
      $null if no valid installation could be found - never throws, since
      "DELTA isn't installed here" is a normal, expected outcome the caller
      needs to decide how to handle (contrast Get-PostgresBinDirectory
      above, where Stop-Setup IS appropriate - that function's callers
      already know they need a PostgreSQL installation to proceed; a
      caller of this one is often specifically trying to tell "missing"
      apart from "found" before deciding what to do next).

      Resolution order:

        1. HKLM:\SOFTWARE\PreventionWeb\DELTA's InstallPath value (written
           by setup.ps1's Register-DeltaInstallation as the last step of a
           successful install) - but only trusted if that directory still
           actually exists on disk right now. The registry is never
           trusted blindly: an installation could have been moved or
           deleted by hand after the key was written, and a stale registry
           value pointing at nothing is worse than no value at all, so
           this falls through to the legacy check below rather than
           returning a path that isn't really there.

        2. The legacy default install path, C:\DELTA - for installations
           created before Register-DeltaInstallation existed and therefore
           never registered themselves at all. Verified by the presence of
           C:\DELTA\.env specifically, not just the directory existing -
           .env is a real deployment artifact (New-DeltaEnvironmentFile in
           setup.ps1 only ever writes it once an installation has actually
           happened), whereas an empty C:\DELTA directory proves nothing
           and could exist for unrelated reasons.

        3. $null if neither of the above found anything real.
    #>

    $registryEntry = Get-ItemProperty -LiteralPath $Script:DeltaRegistryKeyPath -Name 'InstallPath' -ErrorAction SilentlyContinue
    $registryInstallPath = Get-RegistryPropertyValue -InputObject $registryEntry -Name 'InstallPath'
    if ($registryInstallPath -and (Test-Path -LiteralPath $registryInstallPath)) {
        return $registryInstallPath
    }

    $legacyInstallPath = 'C:\DELTA'
    $legacyEnvPath = Join-Path -Path $legacyInstallPath -ChildPath '.env'
    if (Test-Path -LiteralPath $legacyEnvPath) {
        return $legacyInstallPath
    }

    return $null
}

function Resolve-DeltaInstallation {
    <#
      The shared "confirm DELTA is actually installed before doing
      anything engine-specific" step - originally setup-nginx.ps1's own
      Resolve-DeltaInstallation, promoted here once setup-iis.ps1 needed
      the identical behavior (docs\todo\TODO-setup-iis-enhancements.md,
      Phase 1: "Resolve-DeltaInstallation itself is a strong candidate to
      promote... promoting it removes that risk [of the two copies
      diverging] entirely and is the preferred outcome"). Has no
      NGINX/IIS-specific knowledge at all - it only calls the shared
      Get-DeltaInstallPath discovery helper above, so both setup-nginx.ps1
      and setup-iis.ps1 consume this exact same implementation rather than
      each carrying their own copy.

      Stops immediately (Stop-Setup) if Get-DeltaInstallPath returns
      $null - a reverse proxy for a DELTA installation that doesn't exist
      makes no sense, so nothing else in either caller is allowed to run
      in that case.

      Sets $Script:DeltaInstallPath and $Script:DeltaEnvPath (via
      Join-Path, never string concatenation) in the CALLER's script scope
      - both are consumed downstream (e.g. Show-DeltaNginxSummary,
      Resolve-DeltaBackendPort) to report exactly which DELTA installation
      this run resolved.
    #>

    Write-PhaseBanner 'DELTA Installation Discovery'
    Write-Step 'Locating the DELTA installation...'

    $Script:DeltaInstallPath = Get-DeltaInstallPath
    if (-not $Script:DeltaInstallPath) {
        Stop-Setup @'
DELTA installation not found.

Please install DELTA using setup.ps1 before running setup-nginx.ps1.
'@
    }

    $Script:DeltaEnvPath = Join-Path -Path $Script:DeltaInstallPath -ChildPath '.env'

    Write-Success '    DELTA installation found.'
    Write-Host ''
    Write-Host 'Location:'
    Write-Host $Script:DeltaInstallPath
}

# ---------------------------------------------------------------------------
# DELTA managed process matching
# ---------------------------------------------------------------------------

function Test-DeltaManagedProcessCommandLine {
    <#
      The actual matching predicate behind setup.ps1's own Get-
      RunningDeltaProcesses - factored out into this shared, pure,
      side-effect-free function (no CIM query, no $Script: state read
      beyond its own parameters) specifically so it can be exercised
      directly against known command lines, real and adversarial,
      without a live process - see tools\test-delta-process-matching.ps1.

      Requires BOTH of the following - deliberately never either alone,
      since a single string match was confirmed unreliable (see history
      below):

        1. $CommandLine, slash/case-normalized, contains the DELTA entry
           point's relative SUFFIX - "build/server/index.js" - rather
           than any specific absolute or relative form of it. This is
           deliberately a suffix match: a live capture of the real
           `dotenv -e .env -- yarn start` invocation confirmed the actual
           argument is always the relative, forward-slashed
           "./build/server/index.js" from package.json's own "start"
           script (`react-router-serve ./build/server/index.js`), never
           an absolute path - regardless of whether some other part of
           the command line (e.g. an npm/yarn .bin shim's own resolved
           module path) happens to be absolute.
        2. The same normalized $CommandLine also contains
           $DeltaRuntimeRoot, normalized the same way. Signal 1 alone
           would also match a completely unrelated Node application
           elsewhere on the machine that happens to share the same
           build/server/index.js convention (a real risk with this
           specific application framework, not a hypothetical one) -
           this is what preserves Get-RunningDeltaProcesses' original
           guarantee of never matching an unrelated node.exe. Callers
           pass $DeltaRuntimeRoot fresh from $Script:DeltaRuntimeRoot on
           every call rather than this function caching or hardcoding
           it, so a later reinstall to a different directory is picked
           up automatically without this function needing to change.

      Normalization is one simple transform applied identically to both
      sides - collapse every run of \ or / into a single / - rather than
      a slash-tolerant regex character class repeated across multiple
      patterns, so there is exactly one place "what counts as the same
      path" is decided. Comparison is case-insensitive throughout (-match's
      own default), matching Windows' own path case-insensitivity.

      History: the original implementation matched a single absolute
      path string (Join-Path $Script:DeltaRuntimeRoot 'build\server\index.js')
      against the full command line. Confirmed by direct reproduction
      (a live capture of the actual react-router-serve invocation) that
      this NEVER matches a genuinely running DELTA instance, because the
      real command line only ever contains the relative form of that
      path - this function replaces that broken check, not merely
      patches it.

      Deliberately scoped to the CURRENT, non-service runtime only. Once
      Phase 5 (Windows Service) exists, a service-managed DELTA instance
      should be identified through the Service Control Manager and its
      own configured PID - not by extending this command-line heuristic
      indefinitely to also cover that case.
    #>
    param(
        [AllowNull()][string]$CommandLine,
        [Parameter(Mandatory)][string]$DeltaRuntimeRoot
    )

    if ([string]::IsNullOrEmpty($CommandLine)) {
        return $false
    }

    $normalizedCommandLine = $CommandLine -replace '[\\/]+', '/'
    $normalizedRuntimeRoot = ($DeltaRuntimeRoot.TrimEnd('\', '/')) -replace '[\\/]+', '/'

    if ([string]::IsNullOrEmpty($normalizedRuntimeRoot)) {
        return $false
    }

    $hasEntryPoint  = $normalizedCommandLine -match [regex]::Escape('build/server/index.js')
    $hasRuntimeRoot = $normalizedCommandLine -match [regex]::Escape($normalizedRuntimeRoot)

    return ($hasEntryPoint -and $hasRuntimeRoot)
}

# The exact, fixed ArgumentList Start-DeltaRuntimeForValidation (setup.ps1)
# passes to Start-Process when it launches DELTA - defined once, here, so
# the code that constructs the launcher and the code that has to recognize
# it again later (Test-DeltaLauncherProcessCommandLine, below - possibly
# from an entirely different script/run, e.g. uninstall.ps1) can never
# drift apart into two different literal strings.
$Script:DeltaLauncherCommandArguments = '/c dotenv -e .env -- yarn start'

function Test-DeltaLauncherProcessCommandLine {
    <#
      The launcher-process counterpart to Test-DeltaManagedProcessCommandLine
      above, for cmd.exe rather than node.exe. Root-cause finding
      (uninstalling Node.js while DELTA is running can kill node.exe
      without killing its own launcher, since Windows has no parent/child
      lifetime coupling): this cmd.exe (Start-DeltaRuntimeForValidation's
      `cmd.exe /c dotenv -e .env -- yarn start`) sits ABOVE the actual
      DELTA server process in the real process tree - dotenv-cli -> yarn
      -> react-router-serve -> node.exe, each hop its own separate
      process - so, unlike the server's own command line, this cmd.exe's
      command line never contains the DELTA runtime root or the
      build/server/index.js entry point; both only ever appear several
      hops further down. There is no second, independent signal available
      here the way there is for Test-DeltaManagedProcessCommandLine.

      The strongest signal actually available is therefore an exact match
      against the complete, fixed argument string this installer itself
      constructs ($Script:DeltaLauncherCommandArguments) - never a
      keyword/substring heuristic like "contains dotenv" or "contains
      yarn", which could also match some unrelated project's own,
      differently-configured dotenv-cli/yarn invocation elsewhere on the
      same machine. Whitespace is normalized (collapsed runs of spaces)
      before comparing, since Win32_Process.CommandLine reflects whatever
      literal spacing the process was actually created with, and the
      match is anchored at the end of the (normalized) command line - a
      real capture is `"C:\WINDOWS\system32\cmd.exe" /c dotenv -e .env --
      yarn start`, the argument string trailing the resolved cmd.exe path
      exactly.
    #>
    param([AllowNull()][string]$CommandLine)

    if ([string]::IsNullOrEmpty($CommandLine)) {
        return $false
    }

    $normalizedCommandLine = ($CommandLine -replace '\s+', ' ').Trim()
    return $normalizedCommandLine -match ([regex]::Escape($Script:DeltaLauncherCommandArguments) + '$')
}

# ---------------------------------------------------------------------------
# DELTA runtime process management
#
# Relocated here from setup.ps1 (Get-RunningDeltaProcesses/Wait-
# ForProcessExit/Invoke-DeltaTaskkill/Stop-RunningDeltaInstance) once
# uninstall.ps1 needed the exact same "find and stop only THIS
# installation's own DELTA runtime" behavior setup.ps1 already relies on
# before starting a fresh instance - the same promotion this file's own
# functions have already gone through more than once (see e.g. Resolve-
# DeltaInstallation's own header, promoted from setup-nginx.ps1 once
# setup-iis.ps1 needed it too). Extended here, not duplicated, to also
# stop the launcher process (Get-RunningDeltaLauncherProcesses) - see
# Test-DeltaLauncherProcessCommandLine above for why that needs a
# different matching strategy than the server process it wraps.
# ---------------------------------------------------------------------------

function Get-RunningDeltaProcesses {
    <#
      Identifies the actual DELTA server process(es) - node.exe running
      the deployed build\server\index.js entry point from THIS specific
      runtime directory - rather than every node.exe on the machine.
      Matching itself is Test-DeltaManagedProcessCommandLine's job above -
      see that function's own header for the full two-signal algorithm
      (entry-point suffix + runtime root, both slash/case-normalized) and
      why a single absolute-path string match was confirmed unreliable
      and replaced. This function's only job is supplying the live
      candidate list (CIM) and $DeltaRuntimeRoot to that predicate.

      $DeltaRuntimeRoot is an explicit, mandatory parameter rather than a
      $Script:DeltaRuntimeRoot read - matching Test-DeltaManagedProcessCommandLine's
      own convention, and required now that both setup.ps1 and
      uninstall.ps1 call this: they resolve "where is DELTA" completely
      differently (Resolve-DeltaAppRoot's interactive prompt vs.
      Get-DeltaInstallPath's registry/legacy-path lookup), so this
      function has no business assuming either one, or that a variable of
      this exact name even exists in the caller's scope.

      Deliberately scoped to the CURRENT, non-service runtime only - see
      Test-DeltaManagedProcessCommandLine's own header for why a future
      Windows Service-managed instance (Phase 5) should be identified via
      the Service Control Manager instead of an extension of this
      heuristic.

      An ordinary PowerShell function, not array-guaranteed: like any
      command whose result count varies (0, 1, or many), a caller that
      needs collection semantics - .Count, a guaranteed-list foreach,
      indexing - is responsible for wrapping its own call, e.g. @(Get-
      RunningDeltaProcesses ...), rather than this function trying to
      force array-ness on every possible caller regardless of what it
      actually needs. (That would not even be reliably done here:
      PowerShell's implicit return/Write-Output re-enumerates whatever
      array it's given, so a bare `return @(...)` collapses right back to
      $null or a scalar for a 0- or 1-element result by the time a caller
      sees it - confirmed directly to throw "The property 'Count' cannot
      be found on this object" under Set-StrictMode -Version Latest, from
      exactly this shape.) Stop-RunningDeltaInstance is this function's
      one caller that actually needs array semantics, and wraps at its
      own call site accordingly; setup.ps1's Resolve-DeltaApplicationPort
      (piped directly) and Confirm-DeltaRuntimeStarted (boolean context)
      don't need to, and deliberately don't.
    #>
    param([Parameter(Mandatory)][string]$DeltaRuntimeRoot)

    $candidates = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue
    if (-not $candidates) {
        return @()
    }

    return @($candidates | Where-Object { Test-DeltaManagedProcessCommandLine -CommandLine $_.CommandLine -DeltaRuntimeRoot $DeltaRuntimeRoot })
}

function Get-RunningDeltaLauncherProcesses {
    <#
      The launcher counterpart to Get-RunningDeltaProcesses above -
      supplies the live cmd.exe candidate list to
      Test-DeltaLauncherProcessCommandLine. Takes no $DeltaRuntimeRoot
      parameter, unlike Get-RunningDeltaProcesses - see that predicate's
      own header for why the runtime root isn't an available signal on
      this specific process's command line.

      Same non-array-guaranteed return convention as Get-RunningDeltaProcesses
      - callers needing collection semantics wrap their own call, e.g.
      @(Get-RunningDeltaLauncherProcesses).
    #>
    $candidates = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction SilentlyContinue
    if (-not $candidates) {
        return @()
    }

    return @($candidates | Where-Object { Test-DeltaLauncherProcessCommandLine -CommandLine $_.CommandLine })
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
      terminating NativeCommandError under this project's own
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
      instead of raised - Test-DeltaDatabaseExists uses this exact
      pattern for the same class of problem, not a new technique
      introduced here.

      The captured text is never shown on the console - only handed to
      Write-Verbose, so an operator who wants to see exactly what
      Windows said can re-run with -Verbose, while the normal
      install/uninstall output stays clean. This changes nothing about
      whether or how taskkill is invoked, its arguments, or its
      timeout/retry behavior - all of that still belongs entirely to
      Stop-RunningDeltaInstance.
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
      Stops any DELTA runtime already running for this specific
      installation - both the server process(es) (Get-RunningDeltaProcesses)
      and, since a normal graceful shutdown of the server does not
      guarantee its own launcher chain unwinds with it (root-cause
      finding: Windows has no parent/child lifetime coupling - see
      Test-DeltaLauncherProcessCommandLine's own header), the launcher
      process(es) too (Get-RunningDeltaLauncherProcesses). Never touches
      any other node.exe or cmd.exe process on the machine - both
      predicates require an exact, specific match, never a generic sweep
      by process name alone.

      Server processes are stopped first, launcher processes second - not
      an arbitrary order: array concatenation (@(...) + @(...)) below
      preserves left-to-right order, and stopping the actual listening
      server before its launcher avoids ever tearing down the launcher
      while the server it wraps is still bound to the application port.
      In the normal case (DELTA was already shutting down cleanly, not
      recovering from a previous Node.js removal that killed the server
      out from under an orphaned launcher), the launcher will typically
      already have exited on its own by the time this function gets to
      it, making that second stage a normal, harmless no-op.

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
    param([Parameter(Mandatory)][string]$DeltaRuntimeRoot)

    # @() wraps each call, not just the combined result, so a single
    # match from either source is never unwrapped to a bare object
    # before .Count/foreach below treat it as a list - see
    # Get-RunningDeltaProcesses' own header for why that guarantee
    # belongs here, at the one call site that needs it, rather than
    # inside either function itself.
    $processes = @(Get-RunningDeltaProcesses -DeltaRuntimeRoot $DeltaRuntimeRoot) + @(Get-RunningDeltaLauncherProcesses)
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

# ---------------------------------------------------------------------------
# DELTA runtime start / verify (Restart)
# ---------------------------------------------------------------------------
#
# Originally setup.ps1's own "installer validation step" (an interim
# convenience until Phase 5's Windows Service supersedes it - see
# Start-DeltaRuntimeForValidation's own header) - promoted here, alongside
# Stop-RunningDeltaInstance above, once setup-nginx.ps1/setup-iis.ps1
# needed the exact same stop -> start -> verify sequence for their own
# "Restart DELTA backend" management menu action (Restart-DeltaRuntimeForReverseProxy,
# below - the only new thing this section adds on top of setup.ps1's own
# unmodified functions). The DELTA (Node.js) process only ever reads .env
# at startup, so a PUBLIC_URL just synchronized into .env
# (Sync-DeltaPublicUrlEnvironment, above) has no effect on an
# already-running process until it is restarted - but that restart is a
# deliberate, administrator-triggered menu choice, never an automatic
# side effect of the sync itself (see Restart-DeltaRuntimeForReverseProxy's
# own header for why). Every function here below it is reused completely
# unmodified from setup.ps1's own implementation - none of it has any
# DELTA-installer-vs-reverse-proxy-script-specific knowledge, so there is
# exactly one implementation of "start DELTA and prove it actually came
# up," not two.
#
# All four still key off $Script:DeltaRuntimeRoot (setup.ps1's own name
# for the resolved DELTA application directory) exactly as before -
# setup-nginx.ps1/setup-iis.ps1 use $Script:DeltaInstallPath
# (Resolve-DeltaInstallation) for the identical value under a different
# name; Restart-DeltaRuntimeForReverseProxy is the one place that bridges
# the two names, so neither script's own menu action needs to set it
# manually before calling in.

function Show-Section {
    <#
      The full-width '====' banner used for setup.ps1's own major
      screens - the installer banner, each phase, DELTA Runtime
      Deployment, Registry Registration, and the final summary. Reused
      as-is by Start-DeltaRuntimeForValidation/Confirm-DeltaRuntimeStarted
      below for their own "Starting DELTA"/"Verifying DELTA Startup"
      screens - the identical banner style setup-nginx.ps1/setup-iis.ps1
      now show for the same two steps during a reverse proxy restart.
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

function Test-TcpPortAvailable {
    <#
      Reports whether $Port is free to listen on and, if not, a
      human-readable description (process name + PID) of whatever
      already owns it, for display to the operator, plus the raw owning
      process ID itself (OwningProcessId). Uses Get-NetTCPConnection
      (built into Windows Server's NetTCPIP module) rather than a raw
      socket bind, since it also identifies the owner.

      Originally Test-PostgresPort (Resolve-PostgresPort's own helper,
      setup.ps1) - generalized and renamed once Resolve-DeltaApplicationPort
      needed the identical "is this port free, and who owns it if not"
      check for DELTA's own application port; Confirm-DeltaRuntimeStarted
      below is its other caller.
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

# $Script:DeltaStartupPortTimeoutSeconds/DeltaStartupHttpTimeoutSeconds -
# how long Confirm-DeltaRuntimeStarted waits for the just-(re)started
# process to bind $Script:DeltaBackendPort, and then to answer an HTTP
# request, before treating startup as failed rather than merely slow.
# The HTTP allowance is deliberately the longer of the two: DELTA can
# bind its port and then keep performing first-run initialization for
# well over a minute before serving its first response, and a fresh
# install observed in the field kept initializing past the previous
# 20-second allowance - DELTA finished starting successfully after the
# installer had already given up and reported failure. The HTTP wait
# loop returns the moment DELTA responds (and fails early if the
# process exits), so this ceiling is only ever paid in full on a
# genuine startup failure, never on a normal fast startup.
$Script:DeltaStartupPortTimeoutSeconds = 60
$Script:DeltaStartupHttpTimeoutSeconds = 180

function Confirm-DeltaRuntimeNotRunning {
    <#
      Ensures no DELTA instance already running is still bound to the
      application port before (re)starting a fresh one. Deliberately does
      not start anything itself - Start-DeltaRuntimeForValidation (called
      right after this by every caller) owns that, so this function's
      only job is guaranteeing a clean start: nothing already bound to
      $Script:DeltaBackendPort when it runs.

      A no-op when $Script:DeltaSkipManagedInstanceRestart is set - only
      ever true in setup.ps1's own flow (Resolve-DeltaApplicationPort,
      recording that the operator chose to leave the existing managed
      instance running); setup-nginx.ps1/setup-iis.ps1 never set this
      variable, so for their own "Restart DELTA backend" menu action
      this check is always $false/unset and the stop always runs.

      After the stop, the application port itself is re-checked
      (Test-TcpPortAvailable): Stop-RunningDeltaInstance only ever stops
      processes confirmed to be this installation's own runtime, so
      anything STILL listening on $Script:DeltaBackendPort at this point
      is by definition an unrelated process - and starting DELTA anyway
      would both fail to bind and let Confirm-DeltaRuntimeStarted's own
      port probe false-positive against that unrelated listener (a
      listening port alone is its success signal for the port stage).
      The only safe response is to refuse (Stop-Setup) - never to stop
      or kill the owning process, which no code on this path is allowed
      to touch. setup.ps1's own full-install flow normally resolves such
      a conflict interactively well before this runs
      (Resolve-DeltaApplicationPort), so there this guard only catches a
      port grabbed between that resolution and the actual start; for the
      management-menu restart paths (setup.ps1's main menu,
      setup-nginx.ps1/setup-iis.ps1's "Restart DELTA backend"), which
      have no earlier interactive conflict step, it is the primary
      protection.
    #>
    Show-Section -Title 'DELTA Runtime Status'

    if ($Script:DeltaSkipManagedInstanceRestart) {
        Write-Detail "Leaving the existing DELTA instance running, per the operator's choice above."
        return
    }

    Write-Step 'Checking for an already-running DELTA instance...'

    # Service-managed installations are stopped through the Service Control
    # Manager FIRST, never by terminating the process. Killing a supervised
    # process would simply cause WinSW to restart it - the installer would
    # be fighting the supervisor it installed, and the "port is now free"
    # check below could pass or fail depending purely on timing.
    #
    # Direct termination is still attempted afterwards, but only ever as a
    # narrowly-scoped cleanup of what the SCM stop cannot reach: a legacy
    # instance from before this installation was service-managed, an
    # orphaned cmd.exe launcher, or a stop that genuinely timed out.
    # Stop-RunningDeltaInstance is a no-op when nothing matches, so this
    # stays correct for a service-managed installation that stopped cleanly.
    if (Test-DeltaServiceInstalled) {
        if (-not (Stop-DeltaWindowsService)) {
            Write-Detail 'The DELTA service did not stop within the timeout - falling back to direct process cleanup.'
        }
    }

    Stop-RunningDeltaInstance -DeltaRuntimeRoot $Script:DeltaRuntimeRoot

    $portCheck = Test-TcpPortAvailable -Port $Script:DeltaBackendPort
    if (-not $portCheck.Available) {
        Stop-Setup @"
Port $($Script:DeltaBackendPort) is configured as the DELTA application port, but it is currently in use by:

$($portCheck.OwnerDescription)

This process is not a DELTA instance managed by this installer, so it was left running untouched.

Free the port, or change PORT in the DELTA .env file, then try again.
"@
    }
}

function Get-DeltaStartupLogPaths {
    <#
      The two fixed log file paths Start-DeltaRuntimeForValidation
      redirects DELTA's stdout/stderr into, and Get-DeltaStartupFailureMessage
      reads back from on a verification failure - one place computing
      both so they can never drift apart between the two call sites.
      Lives under <AppRoot>\logs - already created and proven writable by
      setup.ps1's own Initialize-DeltaRuntimeDirectories during the
      original install, so nothing here needs to create or permission it
      again, on a restart triggered from setup-nginx.ps1/setup-iis.ps1 any
      more than on setup.ps1's own original call.
    #>
    # Once DELTA is service-managed, its stdout/stderr are captured by WinSW
    # under different names in the same directory - the legacy
    # delta-startup-*.log files are no longer written at all, so pointing a
    # failure diagnostic at them would send an operator to a stale file from
    # a previous, pre-service run. Resolved here, at the one place both the
    # writer and the reader agree on these paths.
    if (Test-DeltaServiceInstalled) {
        $serviceLogPaths = Get-DeltaServiceLogPaths -AppRoot $Script:DeltaRuntimeRoot
        return [PSCustomObject]@{
            StdOut = $serviceLogPaths.StdOut
            StdErr = $serviceLogPaths.StdErr
        }
    }

    $logsDirectory = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'logs'
    return [PSCustomObject]@{
        StdOut = Join-Path -Path $logsDirectory -ChildPath 'delta-startup-stdout.log'
        StdErr = Join-Path -Path $logsDirectory -ChildPath 'delta-startup-stderr.log'
    }
}

function Start-DeltaRuntimeForValidation {
    <#
      Starts DELTA so the caller can hand the operator a working URL
      immediately - an interim convenience standing in for the eventual
      Windows Service (Phase 5, see docs/08-development-roadmap.md).
      Deliberately does none of what a real service would: no restart
      policy, no crash supervision, no watchdog. It starts the process
      once; Confirm-DeltaRuntimeStarted (called right after, from the
      caller's own orchestration) either confirms it came up cleanly or
      stops the script outright. Whichever happens, this function's own
      job ends the moment the process has been launched.

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
      (Get-DeltaStartupLogPaths) - the only place a run's startup
      diagnostics go, reused as-is rather than standing up a separate
      logging mechanism. Confirm-DeltaRuntimeNotRunning must already have
      run before this - never called from here - so this is always a
      clean start, never a restart racing a not-yet-stopped previous
      instance.

      A no-op when $Script:DeltaSkipManagedInstanceRestart is set - see
      Confirm-DeltaRuntimeNotRunning's own header for why this is only
      ever true in setup.ps1's own flow, never setup-nginx.ps1/setup-iis.ps1's.
    #>
    Show-Section -Title 'Starting DELTA'

    if ($Script:DeltaSkipManagedInstanceRestart) {
        Write-Detail 'Skipping automatic startup - the existing DELTA instance was left running untouched.'
        return
    }

    Write-Step 'Starting DELTA...'

    $logPaths = Get-DeltaStartupLogPaths
    Write-Detail "Standard output: $($logPaths.StdOut)"
    Write-Detail "Standard error : $($logPaths.StdErr)"

    # Service-managed installations start through the Service Control
    # Manager. The detached Start-Process path below is retained ONLY for
    # installations that predate the Windows Service (and for the window
    # during migration before the service has been registered) - the two
    # must never both be trying to own DELTA's lifecycle, which is why this
    # is an either/or rather than an additional step.
    if (Test-DeltaServiceInstalled) {
        Write-Detail "Service: $($Script:DeltaServiceName)"
        Start-DeltaWindowsService
        Write-Success '    DELTA service started.'
        return
    }

    try {
        Start-Process -FilePath 'cmd.exe' `
            -ArgumentList $Script:DeltaLauncherCommandArguments `
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
      output that already stopped the script, not just from a path the
      operator still has to go open themselves.
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
      successfully in the background, unaware the caller already gave up
      on it.

      A no-op when $Script:DeltaSkipManagedInstanceRestart is set - see
      Confirm-DeltaRuntimeNotRunning's own header for why this is only
      ever true in setup.ps1's own flow. setup-nginx.ps1/setup-iis.ps1
      never set it, so for their own "Restart DELTA backend" menu action
      this always runs the full verification and calls Stop-Setup - the
      menu action fails outright, rather than silently claiming DELTA
      restarted successfully - if DELTA does not come all the way up.
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
        if (Get-RunningDeltaProcesses -DeltaRuntimeRoot $Script:DeltaRuntimeRoot) {
            $hasBeenObservedRunning = $true
        }
        elseif ($hasBeenObservedRunning) {
            # "Was running, now isn't" means the process died - but under a
            # supervisor that is not automatically fatal, because WinSW may
            # legitimately be restarting it (its configured restart delay is
            # 10 seconds, comfortably inside this wait). Failing here would
            # turn a successful recovery into a reported installation
            # failure. The service itself still being Running is what
            # distinguishes "being restarted" from "gave up": once the
            # restart policy is exhausted the SCM stops the service, and the
            # check below then fails exactly as it always did.
            if (-not (Test-DeltaSupervisedRestartInProgress)) {
                Stop-Setup (Get-DeltaStartupFailureMessage -Reason 'DELTA exited before it finished starting.')
            }
            $hasBeenObservedRunning = $false
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
        if (-not (Get-RunningDeltaProcesses -DeltaRuntimeRoot $Script:DeltaRuntimeRoot)) {
            # Same supervisor allowance as the port loop above - see there
            # for why a momentarily-absent process is not proof of failure
            # once something is actively restarting it.
            if (-not (Test-DeltaSupervisedRestartInProgress)) {
                Stop-Setup (Get-DeltaStartupFailureMessage -Reason 'DELTA exited before it responded over HTTP.')
            }
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

function Restart-DeltaRuntimeForReverseProxy {
    <#
      The single shared "restart DELTA and reload .env" action - the
      implementation behind setup-nginx.ps1's and setup-iis.ps1's own
      "Restart DELTA backend" management menu option, and behind
      setup.ps1's own main-menu "Start DELTA"/"Restart DELTA" actions
      (Show-MainMenu - which passes the already-discovered install path
      in via $Script:DeltaInstallPath/$Script:DeltaEnvPath, exactly the
      two variables Resolve-DeltaInstallation sets for the other two
      callers, rather than this function growing a second discovery
      path). Deliberately a
      standalone, operator-triggered action, not something either script
      calls automatically after writing PUBLIC_URL: reverse proxy
      configuration changes (reload NGINX, update IIS bindings) and
      restarting the DELTA (Node.js) process are two independent
      operations with two independent blast radii, and an administrator
      who only wants to validate or manage the reverse proxy should never
      pay for an unrequested DELTA restart as a side effect. Synchronizing
      PUBLIC_URL (Sync-DeltaPublicUrlEnvironment) still only ever writes
      .env - it never calls this function itself; the administrator picks
      this menu option explicitly, whenever they actually want the
      running DELTA process to pick up whatever is currently in .env.

      Composes the exact same three functions, in the exact same order,
      setup.ps1's own orchestration block already calls for its own
      post-install validation start (Confirm-DeltaRuntimeNotRunning ->
      Start-DeltaRuntimeForValidation -> Confirm-DeltaRuntimeStarted) -
      not a new implementation, and not a subset: a failed verification
      still calls Stop-Setup exactly as it does for setup.ps1, which
      throws out to the caller's own top-level try/catch, reporting a
      genuine failure rather than a successful restart.

      Resolves $Script:DeltaBackendPort itself (Resolve-DeltaBackendPort)
      before doing anything else - unlike setup.ps1's own three calls,
      which rely on Resolve-DeltaApplicationPort having already set it
      earlier in that script's own flow, this function's only callers are
      interactive management-menu actions with no equivalent earlier
      step, and the whole point of this action is to pick up whatever
      PORT is CURRENTLY in .env, not a stale value from whenever the menu
      was first entered.

      Also sets $Script:DeltaRuntimeRoot from $Script:DeltaInstallPath
      first - setup-nginx.ps1/setup-iis.ps1 resolve the DELTA installation
      into $Script:DeltaInstallPath (Resolve-DeltaInstallation), while
      every function below still keys off $Script:DeltaRuntimeRoot,
      setup.ps1's own name for the identical path. This is the one place
      that bridges the two names, so neither script needs to set it
      manually before calling here.
    #>
    $Script:DeltaRuntimeRoot = $Script:DeltaInstallPath
    Resolve-DeltaBackendPort

    Confirm-DeltaRuntimeNotRunning
    Start-DeltaRuntimeForValidation
    Confirm-DeltaRuntimeStarted
}

# ---------------------------------------------------------------------------
# .env file reading
# ---------------------------------------------------------------------------

function Get-EnvFileValue {
    <#
      Reads a single KEY=value out of a .env-style file - blank lines and
      full-line "#" comments are ignored, matched keys are looked up
      case-insensitively (PowerShell's default -eq already does this), and
      a value wrapped in matching single or double quotes has those quotes
      stripped, matching the quoting Update-ManagedEnvironmentLines
      (below) itself writes (KEY="value"). A trailing inline comment is
      excluded from the returned value - for a quoted value, everything
      after the closing quote; for an unquoted one, everything from the
      first whitespace-preceded '#' (never a '#' inside the quotes or
      glued to the value itself, so a quoted URL fragment or password
      containing '#' is returned intact) - the exact shapes .env.example
      itself ships (EMAIL_TRANSPORT="file" # file or smtp,
      SESSION_SECRET="..." # should be random...). Returns $null - never
      throws - both when $Path doesn't exist and when $Key isn't set in
      it, since "absent" is a normal, expected outcome every caller here
      needs to tell apart from "present but invalid" for itself (see
      Resolve-DeltaBackendPort in setup-nginx.ps1, the first caller: a
      missing PORT falls back to a default, but a PORT that's present and
      invalid stops the installer outright - two very different
      responses to what would otherwise look like the same $null).

      Deliberately generic - not "Get-DeltaBackendPort" or similar -
      since it reads exactly one key from exactly one file with no
      DELTA-specific knowledge at all, so any future .env value this
      project needs (across any script that dot-sources this file) can
      reuse it rather than growing its own copy.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmedLine = $line.Trim()
        if (-not $trimmedLine -or $trimmedLine.StartsWith('#')) {
            continue
        }

        $separatorIndex = $trimmedLine.IndexOf('=')
        if ($separatorIndex -lt 0) {
            continue
        }

        $lineKey = $trimmedLine.Substring(0, $separatorIndex).Trim()
        if ($lineKey -ne $Key) {
            continue
        }

        $value = $trimmedLine.Substring($separatorIndex + 1).Trim()
        if ($value.Length -ge 2 -and ($value[0] -eq '"' -or $value[0] -eq "'")) {
            $closingQuoteIndex = $value.IndexOf($value[0], 1)
            if ($closingQuoteIndex -gt 0) {
                return $value.Substring(1, $closingQuoteIndex - 1)
            }
            # Unterminated quote - returned as-is, the same thing the
            # previous strip-only-matching-outer-quotes logic did.
            return $value
        }
        $commentMatch = [regex]::Match($value, '\s#')
        if ($commentMatch.Success) {
            $value = $value.Substring(0, $commentMatch.Index).TrimEnd()
        }
        return $value
    }

    return $null
}

function Backup-DeltaEnvironmentFile {
    <#
      Timestamped backup of an existing .env before this installer writes
      to it - originally setup.ps1's own, promoted here once
      setup-nginx.ps1/setup-iis.ps1 needed the identical "back up before
      writing" behavior for PUBLIC_URL (Sync-DeltaPublicUrlEnvironment,
      below) that setup.ps1's own New-DeltaEnvironmentFile (DATABASE_URL)
      and Update-DeltaApplicationPortEnvironment (PORT) already relied on -
      rather than either script growing its own copy. A no-op if $Path
      doesn't exist yet - there's nothing to protect.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $backupPath = "$Path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force

    # The backup is a byte-for-byte copy of a file holding DATABASE_URL,
    # SESSION_SECRET and SMTP_PASS, and Copy-Item creates a NEW file, which
    # therefore inherits the application directory's own ACL rather than the
    # hardened one the source file carries. Without this the hardening
    # applied to .env would be trivially defeated by reading the .bak file
    # sitting next to it - so every backup is hardened the same way, at the
    # one place backups are actually created.
    Protect-DeltaSecretFile -Path $backupPath

    Write-Detail "Existing .env backed up to: $backupPath"
}

function Protect-DeltaSecretFile {
    <#
      Restricts $Path to Administrators + SYSTEM (+ any $ReadAccounts), so a
      file containing deployment secrets is not readable by every ordinary
      local user.

      Why this exists: a deployed .env inherits the application directory's
      ACL, which on a default installation grants BUILTIN\Users
      ReadAndExecute - confirmed directly against a real deployment, where
      DATABASE_URL (including the database password), SESSION_SECRET and
      SMTP_PASS were all readable by any local account on the machine. That
      predates the Windows Service work and is independent of it, but the
      service work is what introduces a dedicated, least-privileged identity
      that needs an explicit grant here anyway, which makes this the right
      place to close it.

      Mechanics, in order:
        1. /inheritance:d converts the inherited ACEs into explicit ones, so
           the entries that should survive (Administrators, SYSTEM) are
           preserved on the file itself before anything is removed. Removing
           an inherited ACE directly is not possible - it has to be
           materialized first.
        2. /remove:g drops the broad principals. Each is attempted
           independently and an absent principal is simply a no-op, so this
           is idempotent and safe to re-run on an already-hardened file.
        3. Administrators/SYSTEM are re-granted explicitly rather than
           merely assumed to have survived step 1 - a file whose owner had
           already stripped them would otherwise be left unmanageable by the
           installer itself, and by backup/update/reinstall tooling.

      $ReadAccounts receives Read (not Modify): the DELTA service account
      only ever needs to read .env, never write it - .env is installer- and
      operator-owned.

      Deliberately NON-FATAL on failure (a warning, never Stop-Setup). This
      hardens an existing file's permissions; it is not a precondition for a
      working installation, and aborting a complete, otherwise-successful
      install because icacls could not adjust an ACL (an unusual volume, a
      restrictive parent policy) would trade a real working deployment for a
      permissions nicety. The failure is reported loudly instead of being
      swallowed, so it is never invisible.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ReadAccounts = @()
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $broadPrincipals = @('BUILTIN\Users', 'Everyone', 'NT AUTHORITY\Authenticated Users')

    try {
        $output = & icacls.exe $Path /inheritance:d /C 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "icacls /inheritance:d failed: $(($output | Out-String).Trim())"
        }

        foreach ($principal in $broadPrincipals) {
            # An identity that isn't on the ACL at all is a normal, expected
            # outcome here (most files never carry an Everyone ACE), so a
            # non-zero exit from an individual removal is not treated as a
            # failure of the whole operation.
            $null = & icacls.exe $Path /remove:g $principal /C 2>&1
        }

        $grants = @('BUILTIN\Administrators:(F)', 'NT AUTHORITY\SYSTEM:(F)')
        foreach ($account in $ReadAccounts) {
            if ($account) { $grants += "${account}:(R)" }
        }

        foreach ($grant in $grants) {
            $output = & icacls.exe $Path /grant $grant /C 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "icacls /grant $grant failed: $(($output | Out-String).Trim())"
            }
        }

        Write-Detail "Restricted to Administrators/SYSTEM$(if ($ReadAccounts) { ' + ' + ($ReadAccounts -join ', ') }): $Path"
    }
    catch {
        Write-Host ''
        Write-Host 'WARNING' -ForegroundColor Yellow
        Write-Host ''
        Write-Host "Could not restrict permissions on a file containing secrets:" -ForegroundColor Yellow
        Write-Host "  $Path" -ForegroundColor Yellow
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Installation continues, but this file may be readable by ordinary local users.' -ForegroundColor Yellow
        Write-Host ''
    }
}

function Update-ManagedEnvironmentLines {
    <#
      The generic mechanism setup.ps1's own New-DeltaEnvironmentFile
      architecture depends on: given the lines of a .env/.env.example file
      and an ordered table of installer-managed KEY = value pairs, returns
      the same lines with only those specific keys' lines replaced (or
      appended, for a key not already present in the source at all) -
      every other line passed through byte-for-byte unmodified, including
      its original quoting style, comments, and blank lines. Deliberately
      the only place in this installer that ever decides "which .env
      lines am I allowed to change" - no caller matches or replaces a
      variable itself, so there is exactly one mechanism to audit for
      that guarantee, not one per variable.

      Originally setup.ps1's own, promoted here once
      setup-nginx.ps1/setup-iis.ps1 needed the identical mechanism for
      PUBLIC_URL (Sync-DeltaPublicUrlEnvironment, below) - both scripts
      already dot-source this file, so this is the one place a future
      installer-managed value can be added without a second .env
      parser/writer growing anywhere else.
    #>
    param(
        [AllowEmptyCollection()][string[]]$SourceLines,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$ManagedValues
    )

    # KEY="value" is the framing this writer has always produced; a value
    # that itself contains a double quote (EMAIL_FROM's
    # '"DELTA" <no-reply@undrr.org>' shape) would corrupt it, so such a
    # value is written single-quoted instead - the exact style
    # .env.example itself already uses for that variable. A value
    # containing BOTH quote characters cannot be represented in either
    # framing and is each caller's job to reject before it gets here
    # (Read-DeltaEmailSettingValue, setup.ps1, is the one interactive
    # caller that can currently receive one).
    function Format-ManagedEnvironmentAssignment {
        param([string]$Key, [string]$Value)
        $quote = if ($Value.Contains('"')) { "'" } else { '"' }
        return "$Key=$quote$Value$quote"
    }

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
            $newLine = Format-ManagedEnvironmentAssignment -Key $matchedKey -Value ([string]$ManagedValues[$matchedKey])
            # A trailing inline comment on the replaced line
            # (EMAIL_TRANSPORT="file" # file or smtp) is carried over to
            # the new one rather than silently dropped - located with the
            # same quoted/unquoted split Get-EnvFileValue reads values
            # with, so a '#' inside the old quoted value is never
            # mistaken for one.
            $oldValue = $line.Substring($line.IndexOf('=') + 1).Trim()
            $trailingText = ''
            if ($oldValue.Length -ge 2 -and ($oldValue[0] -eq '"' -or $oldValue[0] -eq "'")) {
                $closingQuoteIndex = $oldValue.IndexOf($oldValue[0], 1)
                if ($closingQuoteIndex -gt 0) {
                    $trailingText = $oldValue.Substring($closingQuoteIndex + 1).Trim()
                }
            }
            else {
                $commentMatch = [regex]::Match($oldValue, '\s#')
                if ($commentMatch.Success) {
                    $trailingText = $oldValue.Substring($commentMatch.Index).Trim()
                }
            }
            if ($trailingText.StartsWith('#')) {
                $newLine = "$newLine $trailingText"
            }
            $newLine
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
            $updatedLines = @($updatedLines) + (Format-ManagedEnvironmentAssignment -Key $key -Value ([string]$ManagedValues[$key]))
        }
    }

    return $updatedLines
}

# ---------------------------------------------------------------------------
# Session PATH refresh
# ---------------------------------------------------------------------------

function Update-SessionEnvironmentPath {
    <#
      An MSI install or uninstall updates the Machine/User PATH in the
      registry, but an already-running PowerShell process does not pick
      that up automatically. Rebuilding $env:Path from both scopes lets
      node/npm resolve (setup.ps1, right after installing) or stop
      resolving (uninstall.ps1, right after removing) later in this same
      session, without requiring a new shell.
    #>
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
}

# ---------------------------------------------------------------------------
# Node.js discovery
# ---------------------------------------------------------------------------

function Find-NodeExecutable {
    <#
      Locates node.exe without relying solely on PATH, in order of preference:
        1. PATH (covers the common case cheaply)
        2. The Node.js installer's own registry key
        3. Well-known Program Files install locations
      Returns the full path to node.exe, or $null if not found by any method.
      Shared by setup.ps1 (Phase 1 idempotency check) and uninstall.ps1
      (both its detection phase and its post-uninstall verification) -
      "is Node.js actually usable right now" needs to mean exactly the
      same thing in both directions.
    #>

    $fromPath = Get-Command -Name 'node.exe' -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }

    $registryKeys = @(
        'HKLM:\SOFTWARE\Node.js',
        'HKLM:\SOFTWARE\WOW6432Node\Node.js'
    )
    foreach ($key in $registryKeys) {
        if (Test-Path -Path $key) {
            # Get-RegistryPropertyValue, not dot-notation - see its own
            # comment: this key existing doesn't guarantee it has an
            # InstallPath value, and dot-notation on a genuinely absent
            # property throws under this project's Set-StrictMode
            # -Version Latest rather than returning $null.
            $registryItem = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            $installPath = Get-RegistryPropertyValue -InputObject $registryItem -Name 'InstallPath'
            if ($installPath) {
                $candidate = Join-Path -Path $installPath -ChildPath 'node.exe'
                if (Test-Path -Path $candidate) {
                    return $candidate
                }
            }
        }
    }

    $wellKnownPaths = @(
        (Join-Path -Path $env:ProgramFiles -ChildPath 'nodejs\node.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $wellKnownPaths += Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'nodejs\node.exe'
    }
    foreach ($candidate in $wellKnownPaths) {
        if (Test-Path -Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-InstalledNodeVersion {
    <#
      Runs node.exe -v directly rather than trusting registry metadata,
      since that's the one source guaranteed to reflect what actually runs.
      Returns the version without a leading "v", or $null on failure.
    #>
    param([Parameter(Mandatory)][string]$NodeExecutablePath)

    try {
        $rawVersion = & $NodeExecutablePath '-v' 2>$null
    }
    catch {
        return $null
    }

    if (-not $rawVersion) {
        return $null
    }

    return ($rawVersion | Select-Object -First 1).ToString().Trim().TrimStart('v')
}

# ---------------------------------------------------------------------------
# Credential handling
# ---------------------------------------------------------------------------

function ConvertTo-PlainText {
    <#
      Converts a SecureString to a plain .NET string at the point it's
      actually needed (e.g. building a process argument list or an
      env-var value), rather than handling plaintext passwords any
      earlier than necessary. Uses System.Net.NetworkCredential rather
      than manual Marshal calls - the standard, PS 5.1-compatible idiom.
    #>
    param([Parameter(Mandatory)][SecureString]$SecureString)
    return [System.Net.NetworkCredential]::new('', $SecureString).Password
}

function Read-PostgresSuperuserPassword {
    <#
      Prompts twice and requires a match, so a typo doesn't silently
      become the actual superuser password. Returned as a SecureString.
      Used both by setup.ps1 (Phase 2A, cached and reused for the rest
      of that run - see Get-CachedPostgresSuperuserPassword) and by
      init_db.ps1/upgrade_database.ps1 when run standalone with no
      password supplied.
    #>
    while ($true) {
        $first  = Read-Host -Prompt 'Enter the PostgreSQL superuser password' -AsSecureString
        $second = Read-Host -Prompt 'Confirm password' -AsSecureString

        $plainFirst  = ConvertTo-PlainText -SecureString $first
        $plainSecond = ConvertTo-PlainText -SecureString $second

        if ($plainFirst.Length -eq 0) {
            Write-Host 'Password cannot be empty. Try again.' -ForegroundColor Yellow
            continue
        }
        if ($plainFirst -cne $plainSecond) {
            Write-Host 'Passwords did not match. Try again.' -ForegroundColor Yellow
            continue
        }
        return $first
    }
}

function Read-DeltaAppRoot {
    <#
      Prompts for the DELTA application (runtime) root directory,
      defaulting to $Script:DefaultDeltaRuntimeRoot on a bare Enter.
      Shared verbatim by setup.ps1 (Resolve-DeltaAppRoot) and by
      init_db.ps1/upgrade_database.ps1 when run standalone with no
      -AppRoot supplied - a single place this prompt's text and
      default-handling live, rather than three separate copies of it.

      Rejects a non-absolute answer (re-prompting rather than silently
      accepting something Join-Path would later resolve relative to
      whatever the current directory happens to be) - everything
      downstream assumes this is a real, unambiguous root. Returns the
      path with any trailing backslash stripped, since every caller
      joins further path segments onto it with Join-Path.
    #>
    while ($true) {
        Write-Host ''
        Write-Host 'Enter DELTA application directory'
        Write-Host "(Default: $Script:DefaultDeltaRuntimeRoot)"
        Write-Host ''
        $entered = Read-Host -Prompt '>'

        if ([string]::IsNullOrWhiteSpace($entered)) {
            return $Script:DefaultDeltaRuntimeRoot
        }

        $candidate = $entered.Trim().TrimEnd('\')
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            Write-Host "'$candidate' is not an absolute path (e.g. $Script:DefaultDeltaRuntimeRoot). Try again." -ForegroundColor Yellow
            continue
        }

        return $candidate
    }
}

# ---------------------------------------------------------------------------
# Website domain configuration
# ---------------------------------------------------------------------------

# The bare-Enter default Resolve-DeltaWebsiteDomain offers - a public
# hostname is never assumed the way $Script:DefaultDeltaRuntimeRoot is a
# concrete default filesystem path; "localhost" is simply the safest thing
# to serve a virtual host as until an administrator supplies a real one.
$Script:DefaultDeltaWebsiteDomain = 'localhost'

function Test-DeltaWebsiteDomain {
    <#
      Validates a candidate public website domain (the value
      Resolve-DeltaWebsiteDomain below prompts for) against this feature's
      own requirements (docs\todo\TODO-setup-nginx-enhancements.md, "Website
      Domain Configuration") - accepts "localhost" and valid DNS hostnames,
      rejects a scheme (http://, https://, ftp://), a port, a path or
      trailing slash, spaces, and wildcard (*) entries.

      Returns a PSCustomObject with Valid (bool) and Reason (a specific,
      human-readable explanation of what's wrong, or $null when Valid is
      $true) - the same "structured result, not just a bool" shape as
      Test-PostgresCredentials, so a caller can show the operator exactly
      which rule tripped (e.g. "the domain name cannot include a port")
      rather than one generic "invalid domain" message that leaves them
      guessing which part of what they typed was the problem.

      Checked in a deliberate order: each of the explicitly-called-out
      rejections (scheme, spaces, wildcard, path, port) is checked before
      falling through to the generic DNS hostname shape check, since a
      string that trips one of those (e.g. "https://delta.example.org")
      would otherwise just fail the generic hostname regex too, but with a
      far less specific and less actionable message.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Domain)

    if ($Domain -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        return [PSCustomObject]@{ Valid = $false; Reason = 'Do not include a protocol (e.g. http:// or https://) - enter only the hostname.' }
    }
    if ($Domain -match '\s') {
        return [PSCustomObject]@{ Valid = $false; Reason = 'The domain name cannot contain spaces.' }
    }
    if ($Domain.Contains('*')) {
        return [PSCustomObject]@{ Valid = $false; Reason = 'Wildcard domain names (*) are not supported.' }
    }
    if ($Domain.Contains('/')) {
        return [PSCustomObject]@{ Valid = $false; Reason = 'The domain name cannot include a path or trailing slash - enter only the hostname.' }
    }
    if ($Domain.Contains(':')) {
        return [PSCustomObject]@{ Valid = $false; Reason = 'The domain name cannot include a port - enter only the hostname.' }
    }

    if ($Domain -eq 'localhost') {
        return [PSCustomObject]@{ Valid = $true; Reason = $null }
    }

    # Standard DNS hostname shape: dot-separated labels, each 1-63
    # characters, alphanumeric with interior hyphens only (never leading
    # or trailing one), at least two labels - a bare single-label name
    # other than "localhost" itself (already handled above) isn't a real
    # public domain. The overall 253-character ceiling is RFC 1035's own.
    $hostnamePattern = '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'
    if ($Domain.Length -gt 253 -or $Domain -notmatch $hostnamePattern) {
        return [PSCustomObject]@{ Valid = $false; Reason = "'$Domain' is not a valid DNS hostname (e.g. delta.example.org)." }
    }

    return [PSCustomObject]@{ Valid = $true; Reason = $null }
}

function Resolve-DeltaWebsiteDomain {
    <#
      Phase 5 (docs\todo\TODO-setup-nginx-enhancements.md, "Website Domain
      Configuration"). Prompts for the public hostname the generated
      virtual host should answer to - server_name in setup-nginx.ps1's own
      NGINX templates today, and whatever the equivalent binding is for a
      future setup-iis.ps1 - defaulting to $Script:DefaultDeltaWebsiteDomain
      ("localhost") on a bare Enter, the same bare-Enter-picks-a-default
      shape as Read-DeltaAppRoot above.

      Deliberately placed in this shared file, not setup-nginx.ps1: it has
      no NGINX-specific knowledge at all, so a future setup-iis.ps1 needing
      the identical prompt and validation rules (this phase's own
      requirements say as much) can call this directly instead of growing
      a second copy of the accepted/rejected examples to keep in sync.

      Re-prompts (never silently corrects) on anything Test-DeltaWebsiteDomain
      rejects, showing that function's own specific Reason - matches this
      feature's own requirement to display a clear validation error rather
      than silently modifying or falling back on invalid input. A blank
      entry is the one case NOT re-prompted: it's this function's own
      documented default, not an invalid answer.

      -DefaultDomain overrides the bare-Enter default (still
      $Script:DefaultDeltaWebsiteDomain, "localhost", when omitted) -
      added for setup-nginx.ps1/setup-iis.ps1's own PUBLIC_URL mismatch
      repair, which re-prompts for the domain on an ALREADY-configured
      installation: defaulting a careless Enter to "localhost" there
      would silently downgrade a real, working domain, exactly the
      footgun Repair-DeltaIisManagedWebsite (lib\DeltaDoctor.IIS.ps1)
      already avoids by not re-prompting at all when a domain exists.
      Passing the domain already configured on the reverse proxy as
      -DefaultDomain keeps this one shared prompt safe for that case too.
    #>
    param([string]$DefaultDomain = $Script:DefaultDeltaWebsiteDomain)

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Public Website Domain'
    Write-Host ''
    Write-Host 'This is the hostname users will use to access DELTA.'
    Write-Host ''
    Write-Host 'Examples:'
    Write-Host ''
    Write-Host '    delta.example.org'
    Write-Host '    delta.ncscm.gov.jo'
    Write-Host ''
    Write-Host "Leave blank to use $DefaultDomain."
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''

    while ($true) {
        $entered = Read-Host -Prompt "Domain [$DefaultDomain]"

        if ([string]::IsNullOrWhiteSpace($entered)) {
            return $DefaultDomain
        }

        $domain = $entered.Trim()
        $validation = Test-DeltaWebsiteDomain -Domain $domain
        if ($validation.Valid) {
            return $domain
        }

        Write-Host $validation.Reason -ForegroundColor Yellow
        Write-Host ''
    }
}

# ---------------------------------------------------------------------------
# DELTA backend port detection
# ---------------------------------------------------------------------------

# The fallback used when the DELTA .env file has no PORT entry at all -
# Resolve-DeltaBackendPort below sets $Script:DeltaBackendPort once it has
# actually read the DELTA installation's own .env file, never assumed up
# front. Originally setup-nginx.ps1's own constant, promoted here alongside
# Resolve-DeltaBackendPort itself once setup-iis.ps1 needed the identical
# behavior (docs\todo\TODO-setup-iis-enhancements.md, Phase 5's own "Reuse
# the shared: ... Resolve-DeltaBackendPort") - it has no NGINX-specific
# meaning at all, so both scripts share this one definition.
$Script:DefaultDeltaBackendPort = 3000

function Test-ValidTcpPort {
    <#
      Reports whether $Value is a valid TCP port number (1-65535) - not
      just "parses as an integer", since -1 and 70000 both parse fine but
      are exactly the invalid examples this phase's own requirements call
      out by name. [int]::TryParse rather than a regex first: it already
      rejects non-numeric input (PORT=abc) without this needing its own
      digits-only pattern, and this only needs the range check on top of
      that.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $parsedPort = 0
    if (-not [int]::TryParse($Value, [ref]$parsedPort)) {
        return $false
    }
    return ($parsedPort -ge 1 -and $parsedPort -le 65535)
}

function Resolve-DeltaBackendPort {
    <#
      Originally setup-nginx.ps1's own Resolve-DeltaBackendPort (Automatic
      DELTA Backend Port Detection), promoted here once setup-iis.ps1
      needed the identical behavior (docs\todo\TODO-setup-iis-enhancements.md,
      Phase 5) - it has no NGINX/IIS-specific knowledge at all, reading
      PORT from the resolved DELTA installation's own .env file
      ($Script:DeltaEnvPath - built by Resolve-DeltaInstallation above,
      never a hardcoded C:\DELTA assumption of either caller's own) via
      the shared Get-EnvFileValue helper, rather than a second,
      engine-specific .env parser.

      Three outcomes:
        - PORT absent entirely -> $Script:DefaultDeltaBackendPort (3000).
        - PORT present and a valid TCP port (Test-ValidTcpPort) -> that
          value, used as-is.
        - PORT present but NOT a valid TCP port (PORT=abc, PORT=-1,
          PORT=70000) -> Stop-Setup. Never silently falls back to the
          default in this case - an administrator who explicitly
          configured an invalid value needs to fix it themselves, not
          have this script quietly paper over it and generate a reverse
          proxy pointed at the wrong port.

      Sets $Script:DeltaBackendPort in the CALLER's script scope -
      consumed by setup-nginx.ps1 (New-DeltaNginxConfiguration,
      Show-DeltaNginxSummary), setup-iis.ps1 (Phase 5's own existing-
      website summary), and setup.ps1's own Resolve-DeltaApplicationPort
      (installation-time startup validation - see that function's own
      header), which layers an interactive "is it actually free, and if
      not, ask the operator" check on top of this read-only detection.
      The error message below deliberately does not name any specific
      caller script (unlike Resolve-DeltaInstallation's own still-
      outstanding "revisit this" note - see that function's own header) -
      "re-run this script" is accurate regardless of which of the three
      actually invoked it.
    #>

    Write-PhaseBanner 'DELTA Backend Port Detection'
    Write-Step "Reading PORT from $($Script:DeltaEnvPath)..."

    $rawPort = Get-EnvFileValue -Path $Script:DeltaEnvPath -Key 'PORT'

    if ([string]::IsNullOrWhiteSpace($rawPort)) {
        $Script:DeltaBackendPort = $Script:DefaultDeltaBackendPort
        Write-Detail "PORT is not set - using the default DELTA backend port ($($Script:DeltaBackendPort))."
    }
    else {
        if (-not (Test-ValidTcpPort -Value $rawPort)) {
            Stop-Setup @"
Invalid PORT value in $($Script:DeltaEnvPath): '$rawPort'

PORT must be a valid TCP port number (1-65535).

Correct the PORT value in the DELTA .env file, then re-run this script.
"@
        }

        $Script:DeltaBackendPort = [int]$rawPort
        Write-Success "    Backend port detected: $($Script:DeltaBackendPort)"
    }
}

# ---------------------------------------------------------------------------
# PUBLIC_URL synchronization
# ---------------------------------------------------------------------------
#
# After initial installation, setup-nginx.ps1/setup-iis.ps1 - not
# setup.ps1 - are the authoritative owners of the deployed PUBLIC_URL
# value: whichever reverse proxy is actually configured determines the
# real public URL, so every successful configuration run keeps .env in
# sync with it. Shared here, not duplicated between the two scripts,
# since neither the URL shape nor the comparison/write mechanics have any
# NGINX- or IIS-specific knowledge at all.

function Get-DeltaPublicUrl {
    <#
      Builds the canonical PUBLIC_URL string for a domain/scheme pair -
      "<scheme>://<domain>", deliberately never a trailing slash. The one
      place this construction happens, so Sync-DeltaPublicUrlEnvironment's
      own writes and each script's own "what does the reverse proxy
      actually say" mismatch check always agree on the exact same shape.
    #>
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][bool]$Https
    )

    $scheme = if ($Https) { 'https' } else { 'http' }
    return "$($scheme)://$($Domain)"
}

function Test-DeltaPublicUrlsMatch {
    <#
      Compares two PUBLIC_URL-shaped strings the way an operator would
      read them as "the same URL" - a trailing slash is ignored, the
      scheme is compared as-is, and the host is compared case-
      insensitively - rather than a byte-for-byte string comparison that
      would flag "https://Delta.Example.org/" and "https://delta.example.org"
      as a mismatch for no meaningful reason. Either side missing/blank is
      never a match - a caller with no PUBLIC_URL to compare against
      should treat that as "nothing to compare", not silently pass.
    #>
    param(
        [AllowNull()][string]$First,
        [AllowNull()][string]$Second
    )

    if ([string]::IsNullOrWhiteSpace($First) -or [string]::IsNullOrWhiteSpace($Second)) {
        return $false
    }

    $normalize = {
        param($url)
        $trimmed = $url.Trim().TrimEnd('/')
        if ($trimmed -match '^([a-zA-Z][a-zA-Z0-9+.-]*)://(.+)$') {
            return "$($Matches[1].ToLowerInvariant())://$($Matches[2].ToLowerInvariant())"
        }
        return $trimmed.ToLowerInvariant()
    }

    return (& $normalize $First) -eq (& $normalize $Second)
}

function Get-DeltaLocalhostPublicUrl {
    <#
      The installer-managed localhost PUBLIC_URL shape - the value
      .env.example itself ships (PUBLIC_URL="http://localhost:3000",
      matching its PORT="3000") and the only shape
      Resolve-DeltaLocalhostPublicUrlSync (below) will ever write.
      Built through Get-DeltaPublicUrl rather than string-formatted here
      so there stays exactly one place in this installer that decides
      what a PUBLIC_URL looks like - "localhost:<port>" is just a
      domain-with-port to that function, and http is correct here by
      construction: this is the direct Node listener, never a
      TLS-terminating reverse proxy.
    #>
    param([Parameter(Mandatory)][int]$Port)

    return Get-DeltaPublicUrl -Domain "localhost:$Port" -Https $false
}

function Test-DeltaInstallerManagedLocalhostPublicUrl {
    <#
      Reports whether $Value is still recognizably the installer's own
      generated localhost PUBLIC_URL for $Port - the ownership test that
      decides whether this installer is allowed to rewrite PUBLIC_URL at
      all when the backend port moves.

      Deliberately strict, because the cost of a false positive is
      silently destroying an operator's real public URL. Every one of
      these must hold:

        - scheme is exactly http (an https URL is a reverse-proxied
          public address, never this installer's direct-to-Node default);
        - host is exactly "localhost" (127.0.0.1, ::1, a machine name, or
          any real domain is somebody else's decision - this installer
          has never generated any of them);
        - the port is exactly $Port, the port PUBLIC_URL is being checked
          against (normally the port .env described before this run
          changed it);
        - there is no path beyond "/", and no query, fragment, or
          userinfo - "http://localhost:3000/delta" is a deliberate
          operator customization that happens to mention localhost, not
          something this installer wrote.

      Parsed with [System.Uri] rather than a regex so the host/port/path
      split is done by the same component parser the rest of the world
      uses, instead of a pattern that has to re-derive URL syntax.
      Anything that doesn't parse as an absolute URI at all is simply not
      ours - $false, never an error.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][int]$Port
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Value.Trim(), [System.UriKind]::Absolute, [ref]$uri)) {
        return $false
    }

    if ($uri.Scheme -ne 'http') { return $false }
    if ($uri.Host -ne 'localhost') { return $false }
    if ($uri.Port -ne $Port) { return $false }
    if ($uri.AbsolutePath -ne '/') { return $false }
    if ($uri.Query) { return $false }
    if ($uri.Fragment) { return $false }
    if ($uri.UserInfo) { return $false }

    return $true
}

function Resolve-DeltaLocalhostPublicUrlSync {
    <#
      Decides what PUBLIC_URL should become when the DELTA backend port
      moves from $PreviousPort to $NewPort, given the value $CurrentValue
      currently in .env. Returns the new URL to write, or $null for
      "leave PUBLIC_URL exactly as it is" - which is the answer in every
      case except the one this is for.

      PUBLIC_URL is synchronized only when it is still the installer's
      own localhost form for $PreviousPort
      (Test-DeltaInstallerManagedLocalhostPublicUrl above). That keeps
      the two variables' architectural roles intact rather than coupling
      them: PORT is the local TCP port the Node application listens on,
      while PUBLIC_URL is the externally meaningful base address, which
      starts out pointing at that local listener on a fresh install but
      becomes a public domain the moment a reverse proxy is configured
      (Sync-DeltaPublicUrlEnvironment above) or an operator edits it. In
      both of those cases PUBLIC_URL is no longer describing the Node
      listener at all - NGINX/IIS front it on 80/443 and forward to
      localhost:<PORT> - so moving the backend port must leave it
      completely alone. A customized "https://delta.example.org" survives
      a 3000 -> 3001 move untouched, and that is the intended
      relationship, not a gap.

      $null when nothing needs to change is what lets the caller keep
      PUBLIC_URL out of its managed-values table entirely in that case,
      so an untouched variable is genuinely never rewritten - not even to
      the value it already had, and not appended to a .env that never
      declared it.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$CurrentValue,
        [Parameter(Mandatory)][int]$PreviousPort,
        [Parameter(Mandatory)][int]$NewPort
    )

    if ($PreviousPort -eq $NewPort) {
        return $null
    }

    if (-not (Test-DeltaInstallerManagedLocalhostPublicUrl -Value $CurrentValue -Port $PreviousPort)) {
        return $null
    }

    return Get-DeltaLocalhostPublicUrl -Port $NewPort
}

function Update-DeltaBackendPortEnvironment {
    <#
      Writes a changed DELTA backend port into a .env file, carrying
      PUBLIC_URL along with it only when Resolve-DeltaLocalhostPublicUrlSync
      (above) says that value is still the installer's own localhost form
      for $PreviousPort. Both variables go into ONE
      Update-ManagedEnvironmentLines call - the same generic managed-keys
      mechanism every other .env write in this installer uses - so the
      file is never left momentarily describing a port and a URL that
      disagree, and every unmanaged line keeps its original quoting,
      comments, and position.

      Lives here rather than inside setup.ps1's own
      Update-DeltaApplicationPortEnvironment (its only production caller,
      which supplies the ports from $Script:DeltaApplicationPreviousPort/
      $Script:DeltaBackendPort and owns the console output) so the
      decision-plus-write is reachable as a plain function against a
      plain path - that is what lets tools\test-delta-public-url-port-sync.ps1
      exercise the real code rather than a second copy of the rule, and
      it matches how Backup-DeltaEnvironmentFile and
      Update-ManagedEnvironmentLines themselves ended up here.

      Returns what actually happened, for the caller to report:
      NewPort always, PublicUrl set only when PUBLIC_URL was
      synchronized ($null when it was deliberately left alone), and
      PreviousPublicUrl as it was found before the write.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$PreviousPort,
        [Parameter(Mandatory)][int]$NewPort
    )

    $currentPublicUrl = Get-EnvFileValue -Path $Path -Key 'PUBLIC_URL'
    $syncedPublicUrl = Resolve-DeltaLocalhostPublicUrlSync -CurrentValue $currentPublicUrl -PreviousPort $PreviousPort -NewPort $NewPort

    $managedValues = [ordered]@{ PORT = $NewPort }
    if ($syncedPublicUrl) {
        $managedValues['PUBLIC_URL'] = $syncedPublicUrl
    }

    Backup-DeltaEnvironmentFile -Path $Path

    $sourceLines = Get-Content -LiteralPath $Path
    $updatedLines = Update-ManagedEnvironmentLines -SourceLines $sourceLines -ManagedValues $managedValues
    Set-Content -LiteralPath $Path -Value $updatedLines -Encoding utf8

    return [PSCustomObject]@{
        NewPort           = $NewPort
        PublicUrl         = $syncedPublicUrl
        PreviousPublicUrl = $currentPublicUrl
    }
}

function Sync-DeltaPublicUrlEnvironment {
    <#
      Writes PUBLIC_URL = "<scheme>://<domain>" into the deployed .env
      ($Script:DeltaEnvPath) via the exact same Update-ManagedEnvironmentLines
      mechanism setup.ps1's own DATABASE_URL/PORT writers use - never a
      second .env parser/writer. The single call site both
      setup-nginx.ps1 and setup-iis.ps1 use once their own reverse proxy
      configuration is written, validated, and actually running -
      PUBLIC_URL is treated as installer-managed from here on, the same
      way PORT and DATABASE_URL already are, though an operator may still
      hand-edit it; rerunning either script simply synchronizes it back.

      A no-op (not an error) if $Script:DeltaEnvPath doesn't exist yet -
      neither script should ever be the reason a missing .env is reported,
      that belongs to setup.ps1's own earlier checks.
    #>
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][bool]$Https
    )

    if (-not (Test-Path -LiteralPath $Script:DeltaEnvPath)) {
        return
    }

    $publicUrl = Get-DeltaPublicUrl -Domain $Domain -Https $Https

    Write-Step 'Synchronizing PUBLIC_URL with the configured reverse proxy...'

    Backup-DeltaEnvironmentFile -Path $Script:DeltaEnvPath

    $sourceLines = Get-Content -LiteralPath $Script:DeltaEnvPath
    $managedValues = [ordered]@{ PUBLIC_URL = $publicUrl }
    $updatedLines = Update-ManagedEnvironmentLines -SourceLines $sourceLines -ManagedValues $managedValues
    Set-Content -LiteralPath $Script:DeltaEnvPath -Value $updatedLines -Encoding utf8

    Write-Success "    .env updated (PUBLIC_URL=`"$publicUrl`")."
}

function Test-DeltaTcpPortListening {
    <#
      Reports whether $Port has a socket in the LISTEN state anywhere on
      this machine - the same Get-NetTCPConnection check setup-nginx.ps1's
      own Test-DeltaNginxPortListening already uses, promoted here as a
      generic, DELTA/NGINX/IIS-agnostic primitive so doctor.ps1 can reuse
      it for its own "is the backend actually responding" check without
      growing a second copy of it. A successful connect from localhost
      would not by itself confirm the DELTA backend's own bind succeeded -
      it could just as easily hit an unrelated listener already using that
      port - so this checks LISTEN state directly rather than attempting a
      raw TCP connection, matching Test-DeltaNginxPortListening's own
      reasoning.
    #>
    param([Parameter(Mandatory)][int]$Port)

    return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Get-DeltaProcessById {
    <#
      A safe Get-Process -Id wrapper that returns $null instead of
      throwing for any invalid, negative, or nonexistent ID. Originally
      lib\DeltaDoctor.NGINX.ps1's own private helper (needed because
      every PID handled by its Managed Runtime State section ultimately
      comes from a pid file that file does not control the contents of -
      see that section's own header) - promoted here, generic and
      NGINX-agnostic in its own right, once Get-ListeningTcpPortOwner
      (below) needed the identical "resolve a PID without ever throwing"
      behavior for a completely different purpose (reverse proxy port
      conflict detection, not pid-file validation).
    #>
    param([Parameter(Mandatory)][int]$ProcessId)

    try {
        return Get-Process -Id $ProcessId -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-ListeningTcpPortOwner {
    <#
      For $Port, returns a [PSCustomObject] describing whoever is bound to
      it in the LISTEN state - ProcessId, ProcessName, ExecutablePath, and
      (diagnostic only) ServiceName - or $null if nothing is listening on
      it at all. Originally setup-nginx.ps1's own private helper behind
      its port-prerequisite check - promoted here, generic and
      DELTA/NGINX/IIS-agnostic in its own right (it has no opinion on
      WHO should own a port, only who currently does), once setup-iis.ps1
      needed the identical primitive for its own port-prerequisite check
      (the Manual Reverse Proxy Handover feature - see
      Invoke-DeltaReverseProxyHandover, below). Get-NetTCPConnection
      supplies the owning PID; Get-DeltaProcessById resolves the process
      itself without throwing if it has already exited; the Windows
      Service Name, if any, is resolved via CIM (Win32_Service) purely
      for a caller's own diagnosis or ownership heuristic (e.g. IIS's own
      W3SVC) - never consulted here to decide whether a port is free.
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

function Wait-DeltaPortsReleased {
    <#
      Polls (Wait-Until) until every port in $Ports reports free
      (Test-DeltaTcpPortListening), or $TimeoutSeconds elapses - the
      release-side counterpart to Test-DeltaTcpPortListening itself.
      Needed by the Manual Reverse Proxy Handover feature
      (Invoke-DeltaReverseProxyHandover, below) to confirm a just-stopped
      reverse proxy provider has actually let go of its ports before the
      other provider attempts to bind them - a stop signal returning is
      not the same guarantee as the socket actually closing. Returns the
      [int[]] of ports STILL occupied when it gives up - an empty array
      on success - so a caller can report exactly what didn't release
      rather than a bare failure. Generic, DELTA/NGINX/IIS-agnostic.
    #>
    param(
        [Parameter(Mandatory)][int[]]$Ports,
        [int]$TimeoutSeconds = 10
    )

    Wait-Until -Condition { @($Ports | Where-Object { Test-DeltaTcpPortListening -Port $_ }).Count -eq 0 } -TimeoutSeconds $TimeoutSeconds | Out-Null

    return ,@($Ports | Where-Object { Test-DeltaTcpPortListening -Port $_ })
}

# ---------------------------------------------------------------------------
# Manual Reverse Proxy Handover
# ---------------------------------------------------------------------------
#
# NOT automatic migration - the administrator remains fully in control.
# Doctor (lib\DeltaDoctor.ReverseProxy.ps1, plus each provider's own
# lib\DeltaDoctor.<Provider>.ps1) remains the sole source of truth for
# WHICH provider is active/DELTA-managed AND for what a handover actually
# requires (its own Handover Plan - Get-DeltaReverseProxyHandoverPlan); this
# section only ever presents an already-Doctor-built plan as a concise
# prompt, then executes it exactly as Doctor specified via the plan's own
# captured Execute reference. Deliberately lives here, not in
# lib\DeltaDoctor.ReverseProxy.ps1 - Doctor itself must stay completely
# read-only and never perform a lifecycle operation (see that file's own
# header); this is generic orchestration infrastructure (a confirmation
# prompt, a poll, an exit code), with zero provider-specific knowledge of
# its own, consumed identically by setup-iis.ps1 and setup-nginx.ps1.

function Invoke-DeltaReverseProxyHandover {
    <#
      The one shared "show Doctor's own Handover Plan, ask whether to
      execute it, execute it, and confirm its ports actually let go" flow -
      consumed identically by setup-iis.ps1 (when NGINX is DELTA's active
      reverse proxy and IIS is about to bind) and setup-nginx.ps1 (the
      reverse). $Plan is Doctor's own already-built
      Get-DeltaReverseProxyHandoverPlan result
      (lib\DeltaDoctor.ReverseProxy.ps1) - this function performs no
      ownership detection, port discovery, or "what needs to be stopped"
      reasoning of its own; it only ever presents and carries out a plan
      Doctor has already fully decided, per this feature's own "no reverse
      proxy ownership detection outside Doctor" requirement and its own
      "Doctor plans, provisioning scripts execute" architecture
      correction.

      ARCHITECTURE CORRECTION: an earlier version of this function took a
      single hardcoded $StopAction (e.g. "stop the DELTA website") and
      trusted that stopping it alone would release the required ports.
      Confirmed false on a real machine: IIS's own stock "Default Web
      Site" can independently hold the exact same port, and stopping only
      DELTA's own site left it fully occupied. $Plan.IsSafe/$Plan.Reason
      are what let this function refuse automatic handover outright,
      before ever prompting, when Doctor itself determined stopping
      everything necessary would not be safe (an unrecognized site/object
      also occupying the port - see each provider's own GetHandoverPlan
      for the full safety reasoning) - this function trusts that verdict
      completely rather than second-guessing it.

      Prompts concisely, per this feature's own explicit UX requirement -
      "The current active DELTA reverse proxy is: <Name>", the plan's own
      $Plan.Actions (e.g. "Stop Website: DELTA", "Stop Website: Default
      Web Site" - exactly what will happen, never hidden behind a vague
      per-provider label), then "Stop the current active reverse proxy?" -
      never re-explaining what a reverse proxy is or repeating detail
      Doctor's own report already showed. Defaults to No
      (Read-DeltaYesNoConfirmation's own "blank means the safe choice"
      convention) and, per this feature's own explicit requirement, asks
      EXACTLY ONCE - answering Yes runs $Plan.Execute immediately (a
      scriptblock reference to that provider's own
      Invoke-Delta<Provider>ReverseProxyHandoverPlan, captured by the plan
      itself when Doctor built it - this function has no per-provider
      knowledge of how to carry a plan out, only how to ask about and
      verify one), with no second confirmation.

      Returns [bool] - $true once $Plan.Execute has actually run AND every
      one of $Plan.RequiredPorts is confirmed released
      (Wait-DeltaPortsReleased), and marks
      $Script:DeltaReverseProxyHandoverOccurred so the caller's own
      subsequent successful start can trigger the "run Doctor again"
      final validation this feature's own design calls for. Also returns
      $true, immediately and without prompting, when $Plan.Actions is
      empty - Get-DeltaReverseProxyHandoverPlan (lib\DeltaDoctor.ReverseProxy.ps1)
      now consults every DELTA-managed candidate provider regardless of
      whether Doctor considers it Active, so a genuinely empty plan (that
      candidate's own real estate simply isn't occupying anything right
      now) is a legitimate, common result, not an edge case - asking the
      administrator to confirm an empty action list would be nothing but
      noise, and $Script:DeltaReverseProxyHandoverOccurred is deliberately
      left untouched here, since nothing was actually stopped for the
      "run Doctor again" validation to be worth re-checking. Returns
      $false both on a declined prompt AND on an unsafe plan (both a
      complete, reported no-op - nothing this function owns was ever
      touched) - a caller does not need to distinguish the two, since
      neither one leaves anything to clean up. If the ports remain
      occupied after $Plan.Execute completes, this stops the script
      outright (Stop-Setup) - a plan that ran but didn't actually free the
      port is not a state either caller should ever silently continue
      past.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Plan)

    if (-not $Plan.IsSafe) {
        Write-Host ''
        Write-Host ('-' * $Script:BannerWidth)
        Write-Host ''
        Write-Host 'Automatic handover is not possible.'
        Write-Host ''
        Write-Detail $Plan.Reason
        Write-Host ''
        Write-Host 'Resolve this by hand, then re-run this script.'
        Write-Host ''
        Write-Host ('-' * $Script:BannerWidth)
        Write-Host ''
        return $false
    }

    if ($Plan.Actions.Count -eq 0) {
        Write-Host ''
        Write-Detail "Nothing to hand over - $($Plan.Provider) is not occupying any required port."
        Write-Host ''
        return $true
    }

    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'The current active DELTA reverse proxy is:'
    Write-Host ''
    Write-Detail $Plan.Provider
    Write-Host ''
    Write-Host 'The following actions will be performed:'
    Write-Host ''
    foreach ($action in $Plan.Actions) {
        Write-Detail $action
    }
    Write-Host ''

    $wantsStop = Read-DeltaYesNoConfirmation -Body { Write-Host 'Stop the current active reverse proxy?' }

    if (-not $wantsStop) {
        Write-Host ''
        Write-Detail 'No changes have been made.'
        Write-Host ''
        return $false
    }

    & $Plan.Execute -Plan $Plan

    Write-Step 'Verifying required ports were released...'
    $stillOccupied = Wait-DeltaPortsReleased -Ports $Plan.RequiredPorts

    if ($stillOccupied.Count -gt 0) {
        Stop-Setup "$($Plan.Provider) handover actions completed, but the following port(s) are still occupied: $($stillOccupied -join ', '). Resolve this before re-running the script."
    }

    Write-Success '    Ports released.'
    $Script:DeltaReverseProxyHandoverOccurred = $true
    return $true
}

# ---------------------------------------------------------------------------
# SSL certificate file selection
# ---------------------------------------------------------------------------

function Select-DeltaSslFile {
    <#
      Opens a standard Windows file selection dialog
      (System.Windows.Forms.OpenFileDialog) and returns the selected file's
      full path, or $null if the administrator closed/canceled the dialog
      without choosing one - never a manually-typed path, per this
      feature's own requirement (locating a certificate or key file
      wherever it happens to live on disk is exactly what a file picker is
      for). Requires an STA thread, which is WinForms' own hard
      requirement, not something this function works around - powershell.exe
      (the Windows PowerShell 5.1 host this project's scripts target)
      defaults to STA, so this is not expected to be an issue in practice.

      Originally setup-nginx.ps1's own Select-DeltaSslFile, promoted here
      once setup-iis.ps1's own Phase 7 (Windows SSL Certificate) needed the
      identical file-picker behavior for selecting a .pfx - it has no
      NGINX-specific knowledge at all (the caller supplies the dialog
      title and filter), so both scripts share this one implementation
      rather than carrying two copies that could drift apart.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Filter
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    }
    catch {
        Stop-Setup "Unable to open a file selection dialog - System.Windows.Forms could not be loaded: $($_.Exception.Message)"
    }

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false

    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    return $dialog.FileName
}

function Test-DeltaSslFileExtension {
    <#
      Reports whether $Path's extension is one of $AllowedExtensions
      (case-insensitive - Windows filesystems already are, so a literal
      ".PFX"/".CRT" selected via the file dialog must be accepted the same
      as ".pfx"/".crt"). Originally setup-nginx.ps1's own
      Test-DeltaSslFileExtension, promoted alongside Select-DeltaSslFile
      for the identical reason - no certificate-format-specific knowledge
      at all, just an extension check against a caller-supplied list.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$AllowedExtensions
    )

    $extension = [System.IO.Path]::GetExtension($Path)
    return $AllowedExtensions -contains $extension.ToLowerInvariant()
}

# ---------------------------------------------------------------------------
# Certificate conversion (PEM certificate + private key -> PKCS#12)
# ---------------------------------------------------------------------------
#
# Generic certificate helpers - no IIS-specific knowledge at all. Added for
# setup-iis.ps1's own Phase 7 (Windows SSL Certificate) "Certificate +
# Private Key" input option, but deliberately placed here rather than in
# setup-iis.ps1 itself: converting a cert+key pair into an importable PFX
# is exactly the kind of engine-agnostic operation this project's own
# "shared, engine-agnostic logic lives in lib\DeltaInstaller.Common.ps1"
# principle already established for backend port/website domain
# resolution - a future setup-nginx.ps1 enhancement, or any other script
# in this project, could reuse this identically. setup-iis.ps1 itself only
# orchestrates (prompts, picks files, calls this, hands the result to its
# own already-existing Import-PfxCertificate step) - it does not own any
# of the actual conversion logic.
#
# Uses BouncyCastle.Cryptography (vendored under lib\BouncyCastle\, MIT
# licensed - see that directory's own README.md/LICENSE.md) as the
# conversion engine, per this phase's own explicit requirement: "Do not
# implement or maintain a custom ASN.1 parser. Do not implement custom
# PBES2 or OpenSSL-compatible decryption. Prefer the mature library."
# Confirmed directly (see docs\todo\TODO-setup-iis-enhancements.md's own
# Phase 7 investigation/validation notes) that .NET Framework 4.8's own
# RSA/ECDsa classes lack the PEM/DER convenience methods needed to do this
# natively, and that BouncyCastle's PemReader correctly and transparently
# handles unencrypted PKCS#1/PKCS#8, encrypted PKCS#8, and even the legacy
# OpenSSL "Proc-Type: 4,ENCRYPTED" PKCS#1 format - none of which a
# hand-written parser could safely or reasonably cover.

function Install-DeltaBouncyCastleTypes {
    <#
      Idempotently loads BouncyCastle.Cryptography.dll
      (lib\BouncyCastle\, vendored - see that directory's own README.md
      for exactly which package/version and why) via Add-Type, and
      registers a small compiled helper type,
      DeltaBouncyCastlePasswordFinder, implementing BouncyCastle's own
      Org.BouncyCastle.OpenSsl.IPasswordFinder interface - PowerShell
      cannot implement a .NET interface directly, so a tiny C# class
      compiled via Add-Type -TypeDefinition is the standard, minimal way
      to bridge a plain password into BouncyCastle's own PemReader
      decryption callback. Both checks are idempotent (safe to call every
      time a caller needs BouncyCastle - Add-Type throws if a type is
      redefined in the same process, so this always checks for the
      type's existence first rather than assuming it has/hasn't run yet).

      Requires $Script:ProjectRoot to already be set by the caller (see
      this file's own header for why) - the vendored DLL's path is
      resolved relative to it, never a hardcoded absolute path.
    #>

    if (-not ('Org.BouncyCastle.X509.X509Certificate' -as [type])) {
        $bouncyCastlePath = Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\BouncyCastle\BouncyCastle.Cryptography.dll'
        if (-not (Test-Path -LiteralPath $bouncyCastlePath)) {
            Stop-Setup "Required assembly not found: $bouncyCastlePath"
        }
        Add-Type -Path $bouncyCastlePath
    }

    if (-not ('DeltaBouncyCastlePasswordFinder' -as [type])) {
        $bouncyCastlePath = Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\BouncyCastle\BouncyCastle.Cryptography.dll'
        Add-Type -ReferencedAssemblies $bouncyCastlePath -TypeDefinition @'
using Org.BouncyCastle.OpenSsl;
public class DeltaBouncyCastlePasswordFinder : IPasswordFinder
{
    private readonly char[] _password;
    public DeltaBouncyCastlePasswordFinder(char[] password) { _password = (char[])password.Clone(); }
    public char[] GetPassword() { return (char[])_password.Clone(); }
}
'@
    }
}

function Test-DeltaPrivateKeyEncrypted {
    <#
      Whether $Path's PEM content is an encrypted private key - checked
      by looking for the two textual markers that unambiguously indicate
      encryption regardless of format, rather than attempting a blind
      decrypt first: "-----BEGIN ENCRYPTED PRIVATE KEY-----" (modern,
      PKCS#8/PBES2) or a "Proc-Type: 4,ENCRYPTED" header line (the legacy
      OpenSSL PKCS#1 convention, "-----BEGIN RSA PRIVATE KEY-----" plus a
      DEK-Info header). Both markers are always present in the PEM text
      itself for an encrypted key, by definition of the format - the same
      simple, reliable check real tooling (e.g. `openssl` itself) uses to
      decide whether a passphrase is even needed, per this phase's own
      "If the key is not encrypted: Do not prompt" requirement.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $content = Get-Content -LiteralPath $Path -Raw
    return [bool]($content -match 'BEGIN ENCRYPTED PRIVATE KEY' -or $content -match 'Proc-Type:\s*4\s*,\s*ENCRYPTED')
}

function ConvertTo-DeltaPfxFromCertificateAndKey {
    <#
      Combines a PEM-encoded certificate and its private key into a
      PKCS#12 (.pfx) file, using BouncyCastle as the parsing/encoding
      engine - never a custom ASN.1 parser, never custom PBES2/OpenSSL-
      compatible decryption, per this phase's own explicit requirement.

      Supports whatever BouncyCastle's own PemReader supports without
      this function needing to know the specifics itself: RSA or EC,
      PKCS#1 or PKCS#8, unencrypted or encrypted (including the legacy
      OpenSSL PKCS#1 scheme) - $KeyPassphrase is only ever needed for the
      encrypted cases and is passed straight through to BouncyCastle via
      DeltaBouncyCastlePasswordFinder, never inspected or parsed here.

      $PfxPassword protects the OUTPUT file this function writes - it has
      nothing to do with $KeyPassphrase (the INPUT key's own passphrase,
      if any). Converts each SecureString to plain text only transiently,
      for the narrowest possible scope, via the existing shared
      ConvertTo-PlainText helper, and clears the local variable
      immediately afterward - the same discipline this file's own
      Read-PostgresSuperuserPassword/New-DatabaseUrl already follow for
      credential material.

      Throws (via Stop-Setup) with a specific, human-readable message on
      any parse failure - a wrong passphrase, an unsupported/corrupt
      file, or a certificate/key file that doesn't actually contain what
      its name implies - rather than letting a raw BouncyCastle exception
      surface unexplained.
    #>
    param(
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [AllowNull()][SecureString]$KeyPassphrase,
        [Parameter(Mandatory)][SecureString]$PfxPassword,
        [Parameter(Mandatory)][string]$DestinationPfxPath
    )

    Install-DeltaBouncyCastleTypes

    Write-Detail "Certificate: $CertificatePath"
    Write-Detail "Private key: $PrivateKeyPath"

    try {
        $certReader = New-Object Org.BouncyCastle.OpenSsl.PemReader((New-Object System.IO.StringReader((Get-Content -LiteralPath $CertificatePath -Raw))))
        $bcCertificate = $certReader.ReadObject()
    }
    catch {
        Stop-Setup "Failed to read the certificate file ($CertificatePath): $($_.Exception.Message)"
    }
    if (-not ($bcCertificate -is [Org.BouncyCastle.X509.X509Certificate])) {
        Stop-Setup "The selected certificate file does not contain a valid X.509 certificate: $CertificatePath"
    }

    $keyReaderArgs = @((New-Object System.IO.StringReader((Get-Content -LiteralPath $PrivateKeyPath -Raw))))
    if ($KeyPassphrase) {
        $plainPassphrase = ConvertTo-PlainText -SecureString $KeyPassphrase
        try {
            $passwordFinder = New-Object DeltaBouncyCastlePasswordFinder(, $plainPassphrase.ToCharArray())
        }
        finally {
            $plainPassphrase = $null
        }
        $keyReaderArgs += $passwordFinder
    }

    try {
        $keyReader = New-Object Org.BouncyCastle.OpenSsl.PemReader($keyReaderArgs)
        $bcKeyObject = $keyReader.ReadObject()
    }
    catch {
        Stop-Setup "Failed to read the private key file ($PrivateKeyPath) - it may require a different passphrase, or use an unsupported format: $($_.Exception.Message)"
    }
    if (-not $bcKeyObject) {
        Stop-Setup "The selected private key file could not be parsed: $PrivateKeyPath"
    }

    $privateKeyParameter = if ($bcKeyObject -is [Org.BouncyCastle.Crypto.AsymmetricCipherKeyPair]) { $bcKeyObject.Private } else { $bcKeyObject }
    if (-not ($privateKeyParameter -is [Org.BouncyCastle.Crypto.AsymmetricKeyParameter]) -or -not $privateKeyParameter.IsPrivate) {
        Stop-Setup "The selected private key file does not contain a usable private key: $PrivateKeyPath"
    }

    $pkcs12Store = [Org.BouncyCastle.Pkcs.Pkcs12StoreBuilder]::new().Build()
    $alias = 'delta'
    $certificateEntry = New-Object Org.BouncyCastle.Pkcs.X509CertificateEntry($bcCertificate)
    $pkcs12Store.SetCertificateEntry($alias, $certificateEntry)
    $keyEntry = New-Object Org.BouncyCastle.Pkcs.AsymmetricKeyEntry($privateKeyParameter)
    $pkcs12Store.SetKeyEntry($alias, $keyEntry, [Org.BouncyCastle.Pkcs.X509CertificateEntry[]]@($certificateEntry))

    $plainPfxPassword = ConvertTo-PlainText -SecureString $PfxPassword
    try {
        $fileStream = New-Object System.IO.FileStream($DestinationPfxPath, [System.IO.FileMode]::Create)
        try {
            $pkcs12Store.Save($fileStream, $plainPfxPassword.ToCharArray(), (New-Object Org.BouncyCastle.Security.SecureRandom))
        }
        catch {
            Stop-Setup "Failed to build the PKCS#12 (.pfx) file: $($_.Exception.Message)"
        }
        finally {
            $fileStream.Close()
        }
    }
    finally {
        $plainPfxPassword = $null
    }
}

function New-DeltaRandomPassword {
    <#
      A cryptographically random password/token, for internal-only,
      immediately-discarded uses that never need to be memorable or
      typed by anyone - the throwaway PFX password
      New-DeltaIisTemporaryPfxFromCertificateAndKey (setup-iis.ps1)
      protects its own temporary .pfx with, per this phase's own
      "administrator never sees it" requirement. Uses
      RNGCryptoServiceProvider (a real CSPRNG), not [guid]::NewGuid() or
      Get-Random - GUIDs are not documented or guaranteed to be
      cryptographically unpredictable, and this value is standing in for
      a real credential (however short-lived), so it is generated to the
      same standard as one.
    #>
    param([int]$ByteLength = 32)

    $randomBytes = New-Object byte[] $ByteLength
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        $rng.GetBytes($randomBytes)
    }
    finally {
        $rng.Dispose()
    }
    return [Convert]::ToBase64String($randomBytes)
}

function Remove-DeltaTemporaryFileSecurely {
    <#
      Best-effort secure delete: overwrites $Path's own bytes with fresh
      cryptographically random data before removing it, so a temporary
      file that held private key material doesn't simply get unlinked
      (leaving the original bytes recoverable on disk until something
      else happens to reuse those blocks) - per this phase's own
      "securely delete afterward" requirement for the temporary PKCS#12
      this installer generates. The overwrite is best-effort (SSD wear-
      leveling means even this guarantee is inherently weaker than on a
      spinning disk - documented here rather than silently overstated);
      the file is always removed regardless of whether the overwrite
      itself succeeded, and this never throws - callers use it from
      `finally` blocks where a cleanup failure must never mask (or be
      masked by) the real error already in flight.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        $fileLength = (Get-Item -LiteralPath $Path).Length
        if ($fileLength -gt 0) {
            $randomBytes = New-Object byte[] $fileLength
            $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
            try {
                $rng.GetBytes($randomBytes)
            }
            finally {
                $rng.Dispose()
            }
            [System.IO.File]::WriteAllBytes($Path, $randomBytes)
        }
    }
    catch {
        # Best-effort overwrite only - still remove the file below
        # regardless of whether this succeeded.
    }

    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function New-DatabaseUrl {
    <#
      Builds a postgresql:// connection string with the username and
      password percent-encoded per RFC 3986 - and only those two
      components, never the surrounding URL structure (scheme, @, :, /
      delimiters). Encoding unconditionally, not per-character, is
      deliberate: verified directly against the WHATWG URL parser that
      pg's own connection-string parsing is built on (database/
      environment workflow assessment, Part A.7) - three characters
      (/, ?, #) outright break parsing, and the rest "work" only via
      parser leniency that isn't guaranteed everywhere (@, :, %, space,
      backslash - % specifically has a silent-corruption failure mode
      if followed by two hex digits). The PostgreSQL superuser password
      is operator-typed and unconstrained, so this isn't a theoretical
      concern.
    #>
    param(
        [Parameter(Mandatory)][string]$PostgresHost,
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][SecureString]$Password,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    $plainPassword = ConvertTo-PlainText -SecureString $Password
    try {
        $encodedUser     = [System.Uri]::EscapeDataString($Username)
        $encodedPassword = [System.Uri]::EscapeDataString($plainPassword)
        return "postgresql://${encodedUser}:${encodedPassword}@${PostgresHost}:${Port}/${DatabaseName}"
    }
    finally {
        $plainPassword = $null
    }
}

function ConvertFrom-DatabaseUrl {
    <#
      The reverse of New-DatabaseUrl: parses a postgresql:// connection
      string back into its components, so an installer-managed .env this
      script wrote on a PREVIOUS run can be read back on a later one
      (Upgrade lifecycle credential/database-name reuse - setup.ps1)
      instead of only ever being able to write DATABASE_URL, never read
      it back apart.

      Uses [System.Uri] rather than a hand-rolled regex - postgresql://
      URLs follow the same generic scheme://user:pass@host:port/path
      syntax .NET's own URI parser already handles correctly, confirmed
      directly against real values (including a password containing @,
      :, and / all percent-encoded, exactly the characters New-DatabaseUrl's
      own header documents encoding) round-tripping back to their
      original plaintext via UnescapeDataString. Only Username/Password
      are decoded - symmetric with New-DatabaseUrl only ever encoding
      those same two components.

      Returns $null - never throws - for anything that isn't a fully
      usable connection string: not a well-formed URI, or missing a
      username, password, host, or database name. Every caller here
      needs "couldn't parse" to be trivially distinguishable from a
      successful parse without a try/catch of its own, since "fall back
      to the normal fully-interactive behavior" is the only correct
      response to any of those, never a reason to stop the installer.

      Password is returned as a SecureString, not the plaintext
      .NET's own UnescapeDataString produces - converted immediately,
      matching how a password is handled everywhere else in this project
      (Read-PostgresSuperuserPassword, Test-PostgresCredentials) rather
      than introducing the one place a DATABASE_URL's password would
      otherwise sit in memory as a plain string for longer than
      necessary.
    #>
    param([AllowNull()][AllowEmptyString()][string]$DatabaseUrl)

    if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
        return $null
    }

    try {
        $uri = [System.Uri]$DatabaseUrl
    }
    catch {
        return $null
    }

    if (-not $uri.IsAbsoluteUri -or -not $uri.UserInfo -or -not $uri.Host -or $uri.Port -lt 0) {
        return $null
    }

    $userInfoParts = $uri.UserInfo.Split(':', 2)
    $username = [System.Uri]::UnescapeDataString($userInfoParts[0])
    $plainPassword = if ($userInfoParts.Count -gt 1) { [System.Uri]::UnescapeDataString($userInfoParts[1]) } else { '' }
    $databaseName = $uri.AbsolutePath.TrimStart('/')

    if (-not $username -or -not $plainPassword -or -not $databaseName) {
        return $null
    }

    try {
        $securePassword = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
        return [PSCustomObject]@{
            Username     = $username
            Password     = $securePassword
            PostgresHost = $uri.Host
            Port         = $uri.Port.ToString()
            DatabaseName = $databaseName
        }
    }
    finally {
        $plainPassword = $null
    }
}

# ---------------------------------------------------------------------------
# PostgreSQL discovery
# ---------------------------------------------------------------------------

function Find-PostgresInstallation {
    <#
      Locates an existing PostgreSQL server installation using multiple
      signals, never relying on PATH alone:
        1. PATH (psql.exe)
        2. Well-known install roots (C:\Program Files\PostgreSQL\<version>)
        3. The Windows service (name-pattern match, since a prior install
           may not use this project's preferred service name)
      This matters more than it might look: PostgreSQL's own installer
      never adds its bin directory to PATH at all (verified directly -
      neither Machine nor User scope, confirmed empirically in a clean
      shell during the database/environment workflow assessment), which
      is exactly why the original init_db.bat/upgrade_database.bat -
      calling bare `createdb`/`psql` - cannot run on a freshly
      provisioned machine. Every script in this project resolves the
      executable path through this function (or Get-PostgresBinDirectory
      below) instead.
      Returns a PSCustomObject describing what was found. $Found is
      $false only when psql.exe could not be located by any method -
      everything else on the object is best-effort detail on top of that.
    #>
    $result = [PSCustomObject]@{
        Found           = $false
        PsqlPath        = $null
        PostgresExePath = $null
        InstallDir      = $null
        Version         = $null
        MajorVersion    = $null
        ServiceName     = $null
        ServiceStatus   = $null
    }

    $psqlPath = $null
    $fromPath = Get-Command -Name 'psql.exe' -ErrorAction SilentlyContinue
    if ($fromPath) {
        $psqlPath = $fromPath.Source
    }

    if (-not $psqlPath) {
        $postgresRoot = Join-Path -Path $env:ProgramFiles -ChildPath 'PostgreSQL'
        $installRoots = Get-ChildItem -Path $postgresRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property Name -Descending
        foreach ($root in $installRoots) {
            $candidate = Join-Path -Path $root.FullName -ChildPath 'bin\psql.exe'
            if (Test-Path -Path $candidate) {
                $psqlPath = $candidate
                $result.InstallDir = $root.FullName
                break
            }
        }
    }

    if (-not $psqlPath) {
        return $result
    }

    $result.Found    = $true
    $result.PsqlPath = $psqlPath
    if (-not $result.InstallDir) {
        $result.InstallDir = Split-Path -Path (Split-Path -Path $psqlPath -Parent) -Parent
    }

    $postgresExe = Join-Path -Path (Split-Path -Path $psqlPath -Parent) -ChildPath 'postgres.exe'
    if (Test-Path -Path $postgresExe) {
        $result.PostgresExePath = $postgresExe
    }

    try {
        $rawVersion = & $psqlPath '--version' 2>$null
    }
    catch {
        $rawVersion = $null
    }
    if ($rawVersion) {
        $versionMatch = [regex]::Match(($rawVersion | Select-Object -First 1).ToString(), '(\d+)(\.\d+)*')
        if ($versionMatch.Success) {
            $result.Version      = $versionMatch.Value
            $result.MajorVersion = ($versionMatch.Value -split '\.')[0]
        }
    }

    $service = Get-Service -Name 'postgresql*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($service) {
        $result.ServiceName   = $service.Name
        $result.ServiceStatus = $service.Status.ToString()
    }

    return $result
}

function Test-PostgresServerPresent {
    <#
      Authoritative "is the PostgreSQL *server* here" check - the Windows
      service and postgres.exe itself - deliberately independent of
      Find-PostgresInstallation's Found above, which is gated on
      psql.exe/PATH first. That's the right question for "can this
      project run psql against something", but the wrong one for "has
      the server been uninstalled": confirmed directly on a real machine
      that EDB's own uninstaller can log "Command Line Tools
      uninstallation completed" while genuinely leaving psql.exe (a
      client tool, not the server) - plus the 2-3 runtime DLLs it loads -
      behind in bin\, even though postgres.exe, the service, and every
      other bin\ executable were all correctly removed in the same run.
      Treating that leftover client binary as "still installed" fails a
      genuinely successful server uninstall (see Uninstall-PostgreSql,
      uninstall.ps1, which uses this instead of Find-PostgresInstallation
      for exactly that reason).

      $ServiceName, if supplied, scopes the service check to that exact
      name instead of the broad 'postgresql*' wildcard. This matters
      post-uninstall: the wildcard also matches a second PostgreSQL
      version's service, an unrelated postgresql*-named service, or a
      stopped/stale registration left behind by something other than
      the installation actually being validated here - any of which
      would make this function report "still present" for an
      installation that was in fact fully removed. Callers that already
      captured a specific installation via Find-PostgresInstallation
      (e.g. Uninstall-PostgreSql, uninstall.ps1) should always pass
      $existing.ServiceName. Only when no specific name is available
      does this fall back to the wildcard, matching this function's
      prior (unscoped) behavior.

      $InstallDir is optional - the install directory a prior
      Find-PostgresInstallation call already resolved, if any - and is
      only used to check for postgres.exe; without it, the service check
      alone still runs.
    #>
    param(
        [string]$InstallDir,
        [string]$ServiceName
    )

    if ($ServiceName) {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($service) {
            return $true
        }
    }
    else {
        $service = Get-Service -Name 'postgresql*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($service) {
            return $true
        }
    }

    if ($InstallDir) {
        $postgresExe = Join-Path -Path $InstallDir -ChildPath 'bin\postgres.exe'
        if (Test-Path -LiteralPath $postgresExe) {
            return $true
        }
    }

    return $false
}

function Test-PostgresFreshInstallCleanupSafe {
    <#
      Pure decision predicate behind Install-PostgreSql's retry cleanup
      (setup.ps1, Invoke-DeltaComponentInstallWithRetry's -CleanupAction):
      is it provably safe to delete the target install prefix / data
      directory left behind by a failed EDB installer attempt?

      Returns $true ONLY when every signal agrees this was a fresh
      installation whose on-disk leftovers belong to the current, failed
      attempt:

        - Nothing at the target existed before this setup run: not the
          install prefix, not the data directory, not the Windows
          service. Anything that pre-existed - even an incomplete tree
          left by some EARLIER interrupted run (the repair path
          Install-PostgreSql already handles) - is never this run's to
          delete.
        - No PostgreSQL service is registered NOW: a registered service
          means the installer got far enough that "delete the directory"
          is no longer a clean undo of a partial extraction.
        - The data directory is not initialized NOW (no PG_VERSION): an
          initdb-completed cluster is never deleted here, even one this
          run's own failed attempt created - the retry installer handles
          an existing data directory itself, and a cluster is the one
          artifact whose loss can't be undone by re-running an installer.

      Deliberately takes plain booleans, not paths - the caller performs
      the actual filesystem/service probes - so this policy stays a pure,
      directly-testable function (tools\test-delta-install-retry.ps1),
      the same pattern as Test-DeltaManagedProcessCommandLine.
    #>
    param(
        [Parameter(Mandatory)][bool]$InstallPrefixExistedBeforeSetup,
        [Parameter(Mandatory)][bool]$DataDirectoryExistedBeforeSetup,
        [Parameter(Mandatory)][bool]$ServiceExistedBeforeSetup,
        [Parameter(Mandatory)][bool]$ServiceExistsNow,
        [Parameter(Mandatory)][bool]$DataDirectoryInitializedNow
    )

    if ($InstallPrefixExistedBeforeSetup -or $DataDirectoryExistedBeforeSetup -or $ServiceExistedBeforeSetup) {
        return $false
    }
    if ($ServiceExistsNow -or $DataDirectoryInitializedNow) {
        return $false
    }
    return $true
}

function Get-PostgresBinDirectory {
    <#
      Resolves the directory containing psql.exe/createdb.exe/dropdb.exe
      for the currently-installed PostgreSQL, via Find-PostgresInstallation
      - the single call site every script in this project uses instead of
      assuming PATH. Throws (via Stop-Setup) if no installation can be
      found at all, since every caller genuinely needs one to proceed.
    #>
    $found = Find-PostgresInstallation
    if (-not $found.Found -or -not $found.PsqlPath) {
        Stop-Setup 'No usable PostgreSQL installation was found (psql.exe could not be located). Install PostgreSQL first (setup.ps1, or run it standalone).'
    }
    return (Split-Path -Path $found.PsqlPath -Parent)
}

function Get-PostgresPortFromConfigFile {
    <#
      Port auto-detection, method 1 (cheapest, tried first): parses the
      data directory's config files directly for an explicit "port = N"
      setting. postgresql.auto.conf (ALTER SYSTEM overrides) is checked
      before postgresql.conf, since it takes precedence when both set a
      value - checking the base file only would risk returning a stale,
      overridden answer. A config line must start with "port" (only
      whitespace before it) to match, so a commented-out `# port = 5432`
      line is correctly ignored; a trailing inline comment after the
      value is fine, since the regex only needs to match the start of
      the line. Assumes the default EDB data directory layout (<install
      dir>\data) - the same assumption Reset-PostgresSuperuserPassword
      already makes for pg_hba.conf. Returns $null (never throws) if
      the data directory can't be found or neither file has an explicit
      setting - deliberately does NOT return PostgreSQL's own compiled-in
      default (5432) in that case, since "the setting is absent" and
      "the setting is 5432" are not the same fact, and only one of them
      is something this function actually knows.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Existing)

    if (-not $Existing.InstallDir) {
        return $null
    }

    $dataDirectory = Join-Path -Path $Existing.InstallDir -ChildPath 'data'
    $candidateFiles = @(
        (Join-Path -Path $dataDirectory -ChildPath 'postgresql.auto.conf')
        (Join-Path -Path $dataDirectory -ChildPath 'postgresql.conf')
    )

    foreach ($file in $candidateFiles) {
        if (-not (Test-Path -LiteralPath $file)) {
            continue
        }
        $lines = Get-Content -LiteralPath $file -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            if ($line -match "^\s*port\s*=\s*'?(\d+)'?") {
                return [int]$Matches[1]
            }
        }
    }

    return $null
}

function Get-PostgresListeningPort {
    <#
      Port auto-detection, method 2: determines the port an existing
      PostgreSQL Windows service is actually listening on, by resolving
      the service to its process ID (Win32_Service) and then looking at
      what that process has bound in LISTEN state (Get-NetTCPConnection)
      - the same underlying cmdlet Test-TcpPortAvailable (setup.ps1) already
      uses in the opposite direction. Tried after
      Get-PostgresPortFromConfigFile (method 1) specifically because it
      catches the case that method can't: an effective port that differs
      from anything on disk (e.g. a command-line --port override the
      service was registered with). Returns $null (never throws) if the
      port can't be determined this way.

      IMPORTANT: callers must NOT substitute a hardcoded/default port
      when this returns $null - a prior version of this installer did
      exactly that (silently falling back to 5432), which produced a
      confirmed real-world bug: an instance actually running on a
      non-default port (e.g. 5433, chosen during install because 5432
      was occupied) got silently mis-detected as 5432 on a later reuse
      run, and every downstream consumer of $Script:PostgresPort
      (.env generation, credential validation, password reset) then
      failed against the wrong port with no indication why. Callers must
      instead try further detection methods and, only once all of them
      are exhausted, prompt the operator explicitly - see
      Resolve-ExistingPostgresPort in setup.ps1, which orchestrates the
      full method 1 -> 2 -> 3 -> prompt chain.
    #>
    param([Parameter(Mandatory)][string]$ServiceName)

    try {
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
    }
    catch {
        return $null
    }
    if (-not $service -or -not $service.ProcessId) {
        return $null
    }

    $connection = Get-NetTCPConnection -OwningProcess $service.ProcessId -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($connection) {
        return $connection.LocalPort
    }
    return $null
}

function Test-PostgresCredentials {
    <#
      Validates a PostgreSQL host/port/username/password combination
      live, via `psql -c "SELECT 1;"` against the instance's default
      "postgres" database - the same functional-check philosophy as
      Test-PostGISAvailable (setup.ps1): a credential is only "valid" if
      it can actually authenticate, not because it was typed twice
      consistently (that's Read-PostgresSuperuserPassword's job, for
      values this installer is *setting*, not values it's testing
      against a live server).
    #>
    param(
        [Parameter(Mandatory)][string]$PostgresHost,
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][SecureString]$Password
    )

    $bin = Get-PostgresBinDirectory
    $psqlExe = Join-Path -Path $bin -ChildPath 'psql.exe'

    $plainPassword = ConvertTo-PlainText -SecureString $Password
    $previousPgPassword = $env:PGPASSWORD
    $previousEap = $ErrorActionPreference
    try {
        # Same reasoning as Test-PostGISAvailable/init_db.ps1: psql's
        # routine stderr output would otherwise become a terminating
        # error under this process's global $ErrorActionPreference = 'Stop'.
        $ErrorActionPreference = 'Continue'
        $env:PGPASSWORD = $plainPassword
        $output = & $psqlExe -h $PostgresHost -p $Port -U $Username -d 'postgres' --set ON_ERROR_STOP=on --tuples-only --no-align -c 'SELECT 1;' 2>&1
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

    if ($exitCode -eq 0) {
        return [PSCustomObject]@{ Success = $true; ErrorMessage = $null }
    }
    return [PSCustomObject]@{ Success = $false; ErrorMessage = ($output | Out-String).Trim() }
}

function Get-PostgresConnectionFailureReason {
    <#
      Classifies a psql failure's raw stderr text (Test-PostgresCredentials's
      $check.ErrorMessage) into a short, accurate, human-readable reason -
      confirmed root cause of a real bug otherwise: psql returns the same
      non-zero exit code for "wrong port" (connection refused) and "wrong
      password" (authentication failed), and a caller that only checks
      Success and prints a fixed "Authentication failed." message misleads
      the operator into "resetting the password" when the actual problem
      is that nothing is listening on the port that was tried - a
      password reset can never fix that. Falls back to the raw text
      itself (first non-empty line) if none of the known patterns match,
      rather than inventing a category that might be wrong.
    #>
    param([AllowEmptyString()][string]$ErrorMessage)

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
        return 'Unknown error (no output was captured).'
    }
    if ($ErrorMessage -match 'password authentication failed') {
        return 'Password authentication failed - the username/password is incorrect for this server.'
    }
    if ($ErrorMessage -match '(?i)connection refused') {
        return 'Connection refused - no PostgreSQL server is listening on this host/port. The configured port may be wrong.'
    }
    if ($ErrorMessage -match '(?i)(timed out|timeout expired)') {
        return 'Connection timed out - the host/port may be unreachable (e.g. blocked by a firewall).'
    }
    if ($ErrorMessage -match 'database "[^"]*" does not exist') {
        return 'Database does not exist.'
    }
    if ($ErrorMessage -match 'no password supplied') {
        return 'No password was supplied.'
    }

    $firstLine = $ErrorMessage -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1
    if ($firstLine) {
        return $firstLine.Trim()
    }
    return 'Unknown error.'
}

function Test-PostgresServerRespondingOnPort {
    <#
      Port auto-detection, method 3: queries the server directly rather
      than inspecting OS-level socket/process state again (that's method
      2) - attempts a real libpq/psql connection to $Port with a
      throwaway password. A genuine PostgreSQL server, even given the
      wrong password, only ever replies "password authentication
      failed" *after* a successful TCP handshake and protocol exchange;
      "Connection refused" or a timeout means nothing answered at all.
      That distinction proves "something is genuinely speaking the
      Postgres protocol on this port" without needing real credentials -
      reusing the same classification (Get-PostgresConnectionFailureReason)
      the credential-validation flow already relies on, rather than a
      second, separate way of telling success from failure apart.
    #>
    param(
        [Parameter(Mandatory)][string]$PostgresHost,
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$Username
    )

    $throwawayPassword = ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force
    $check = Test-PostgresCredentials -PostgresHost $PostgresHost -Port $Port -Username $Username -Password $throwawayPassword

    if ($check.Success) {
        # Extremely unlikely (would mean trust authentication, or the
        # random throwaway password somehow being correct) - but if it
        # happens, the port obviously works.
        return $true
    }

    $reason = Get-PostgresConnectionFailureReason -ErrorMessage $check.ErrorMessage
    return $reason -like 'Password authentication failed*'
}

function Wait-ForPostgresServiceRunning {
    <#
      Polls a Windows service until it reports Running or a timeout
      elapses. Used around the two service restarts Reset-
      PostgresSuperuserPassword performs, since Restart-Service -Wait
      isn't guaranteed to mean "already accepting connections" the
      instant it returns.
    #>
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') {
            return
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    Stop-Setup "PostgreSQL service '$ServiceName' did not reach the Running state within $TimeoutSeconds seconds."
}

function Reset-PostgresSuperuserPassword {
    <#
      Resets the PostgreSQL superuser password without needing to know
      the current one - this is the standard, documented "forgot the
      postgres password" recovery procedure, not something invented
      here: temporarily add a trust-authenticated rule to the top of
      pg_hba.conf (first match wins, so this overrides whatever stricter
      rule would otherwise apply), restart the service so it takes
      effect, connect without a password to set the new one, then
      restore the original pg_hba.conf and restart again so the
      instance's authentication policy ends up exactly as it was before
      - the only thing that changed is the password itself.

      Explicitly aimed at development/POC/test environments where the
      operator already has Administrator access to this machine (this
      function requires it) - anyone who can elevate here could perform
      this exact recovery by hand regardless, so this only saves the
      manual steps, it doesn't grant any capability the operator didn't
      already have.

      Restoring pg_hba.conf and restarting the service back happens in a
      finally block - if anything fails partway through (the ALTER USER
      itself, for instance), the instance is still put back to its
      original authentication configuration rather than left with a
      trust rule in place.

      Returns the new password as a SecureString on success, or $null if
      the operator declined the confirmation warning (the caller treats
      $null as "canceled, not failed" and re-offers its own menu).
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Existing,
        [Parameter(Mandatory)][string]$PostgresHost,
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$Username
    )

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to reset the PostgreSQL superuser password. Re-run this script from an elevated PowerShell session.'
    }
    if (-not $Existing.ServiceName) {
        Stop-Setup 'Cannot reset the PostgreSQL superuser password: no PostgreSQL Windows service was found.'
    }
    if (-not $Existing.InstallDir) {
        Stop-Setup 'Cannot reset the PostgreSQL superuser password: the PostgreSQL install directory could not be determined.'
    }

    Write-Host ''
    Write-Host 'WARNING: Resetting the PostgreSQL superuser password will change the' -ForegroundColor Yellow
    Write-Host 'credentials for the existing PostgreSQL server. Other applications using' -ForegroundColor Yellow
    Write-Host 'this PostgreSQL instance may also need to update their connection settings.' -ForegroundColor Yellow
    Write-Host ''
    $confirm = Read-Host -Prompt 'Continue with the password reset? (Y/N)'
    if ($confirm -notin @('Y', 'y')) {
        Write-Detail 'Password reset canceled.'
        return $null
    }

    $newPassword = Read-PostgresSuperuserPassword

    # This installer only ever installs PostgreSQL itself via the EDB
    # unattended installer, which uses <install dir>\data as the data
    # directory (see $Script:PostgresDataDirectory) - assumed here too
    # for an instance this installer didn't install itself. A custom
    # data directory is the one layout this can't discover automatically.
    $dataDirectory = Join-Path -Path $Existing.InstallDir -ChildPath 'data'
    $hbaPath = Join-Path -Path $dataDirectory -ChildPath 'pg_hba.conf'
    if (-not (Test-Path -LiteralPath $hbaPath)) {
        Stop-Setup "Cannot reset the PostgreSQL superuser password: pg_hba.conf not found at the expected location ($hbaPath). This assumes the default EDB data directory layout (<install dir>\data) - if this instance uses a custom data directory, reset the password manually instead."
    }

    Write-Step 'Temporarily enabling trusted local access to reset the password...'
    $backupPath = "$hbaPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $hbaPath -Destination $backupPath -Force
    Write-Detail "Original pg_hba.conf backed up to: $backupPath"

    $trustRules = @(
        '# --- Added temporarily by the DELTA installer for a superuser password reset ---'
        'host    all             all             127.0.0.1/32            trust'
        'host    all             all             ::1/128                 trust'
        '# --- End DELTA installer temporary rules ---'
    )
    $originalContent = Get-Content -LiteralPath $hbaPath
    Set-Content -LiteralPath $hbaPath -Value ($trustRules + $originalContent) -Encoding ascii

    try {
        Restart-Service -Name $Existing.ServiceName -Force -ErrorAction Stop
        Wait-ForPostgresServiceRunning -ServiceName $Existing.ServiceName

        Write-Step 'Setting the new password...'
        $bin = Get-PostgresBinDirectory
        $psqlExe = Join-Path -Path $bin -ChildPath 'psql.exe'
        $plainNewPassword = ConvertTo-PlainText -SecureString $newPassword
        $previousEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            # No PGPASSWORD needed here - the trust rule just added is what
            # allows this specific connection through without one.
            $escapedPassword = $plainNewPassword.Replace("'", "''")
            $output = & $psqlExe -h $PostgresHost -p $Port -U $Username -d 'postgres' --set ON_ERROR_STOP=on `
                -c "ALTER USER $Username WITH PASSWORD '$escapedPassword';" 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousEap
            $plainNewPassword = $null
            $escapedPassword = $null
        }

        if ($exitCode -ne 0) {
            Stop-Setup "Failed to reset the PostgreSQL superuser password: $(($output | Out-String).Trim())"
        }
    }
    finally {
        Write-Step 'Restoring original pg_hba.conf...'
        Copy-Item -LiteralPath $backupPath -Destination $hbaPath -Force
        Restart-Service -Name $Existing.ServiceName -Force -ErrorAction SilentlyContinue
        Wait-ForPostgresServiceRunning -ServiceName $Existing.ServiceName
    }

    Write-Step 'Validating new password...'
    $check = Test-PostgresCredentials -PostgresHost $PostgresHost -Port $Port -Username $Username -Password $newPassword
    if (-not $check.Success) {
        Stop-Setup "Password reset appeared to succeed, but authentication with the new password still failed: $($check.ErrorMessage)"
    }

    Write-Success '    PostgreSQL superuser password reset successfully.'
    return $newPassword
}

# ---------------------------------------------------------------------------
# DELTA database existence check
# ---------------------------------------------------------------------------

function Test-DeltaDatabaseExists {
    <#
      Checks whether $DatabaseName already exists on the target PostgreSQL
      instance, via a pg_database lookup against the instance's default
      "postgres" database - the only reliable, OS-agnostic way to answer
      this without assuming anything about what else lives on the server.
      $DatabaseName is operator-typed, so single quotes are escaped before
      it's interpolated into the SQL literal, the same defensive standard
      applied anywhere else in this project a value is built into a
      command string rather than passed as a driver parameter.

      Shared by setup.ps1 (Complete-DatabaseSetup/
      Complete-DatabaseSetupForExistingPostgres - deciding whether to
      create a database or route to the existing-database workflow) and
      init_db.ps1 (Initialize-DeltaDatabase's own defensive guard, so
      createdb.exe is never invoked against a database that already
      exists even when this script is run standalone, outside setup.ps1's
      own check). Takes PostgresHost/Port/Username explicitly rather than
      reading $Script:Postgres* globals - unlike setup.ps1, init_db.ps1
      has no such globals of its own, only local parameters - matching
      the same explicit-parameter convention Test-PostgresCredentials
      above already uses for exactly this reason.
    #>
    param(
        [Parameter(Mandatory)][string]$PostgresHost,
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$Username,
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
        $output = & $psqlExe -h $PostgresHost -p $Port -U $Username -d 'postgres' `
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

# ---------------------------------------------------------------------------
# DELTA Windows Service
# ---------------------------------------------------------------------------
#
# Loaded LAST, deliberately, and from here rather than from each entry-point
# script.
#
# Several functions above are now service-aware - Confirm-DeltaRuntimeNotRunning
# (stop through the Service Control Manager before ever terminating a
# process), Start-DeltaRuntimeForValidation (start the service instead of a
# detached cmd.exe), Confirm-DeltaRuntimeStarted (don't mistake a supervised
# restart for a crash), and Get-DeltaStartupLogPaths (point at WinSW's own
# capture). Restart-DeltaRuntimeForReverseProxy composes exactly those three
# and therefore became service-aware without changing a line of its own.
#
# That last point is what makes this the right place for the dot-source:
# setup-nginx.ps1, setup-iis.ps1, and doctor.ps1 all reach this file (directly
# or through lib\DeltaDoctor.*.ps1) and load nothing else, so pulling the
# service module in here gives every one of them correct service behaviour
# with no change to any of them - which is precisely the constraint that the
# reverse proxy scripts stay independent of DELTA process management.
#
# Loaded at the END of this file, not the top, because the service module
# calls back into the helpers defined above (Write-Step, Stop-Setup,
# Wait-Until, Get-EnvFileValue, ConvertFrom-DatabaseUrl, Test-TcpPortAvailable,
# Get-RunningDeltaProcesses, Protect-DeltaSecretFile). PowerShell resolves
# function calls at invocation time rather than at parse time, so the order
# only actually matters for the code the service module runs *while loading* -
# but keeping the dependency direction visible and one-way here is what stops
# this from becoming a dot-source cycle later.
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Service.ps1')

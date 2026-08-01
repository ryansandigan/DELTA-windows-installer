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

    $registryKeyPath = 'HKLM:\SOFTWARE\PreventionWeb\DELTA'
    $registryEntry = Get-ItemProperty -LiteralPath $registryKeyPath -Name 'InstallPath' -ErrorAction SilentlyContinue
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
      (setup.ps1) itself writes (KEY="value"). Returns $null - never
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
        $isDoubleQuoted = $value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')
        $isSingleQuoted = $value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")
        if ($isDoubleQuoted -or $isSingleQuoted) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        return $value
    }

    return $null
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
    #>

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
    Write-Host "Leave blank to use $Script:DefaultDeltaWebsiteDomain."
    Write-Host ''
    Write-Host ('-' * $Script:BannerWidth)
    Write-Host ''

    while ($true) {
        $entered = Read-Host -Prompt "Domain [$Script:DefaultDeltaWebsiteDomain]"

        if ([string]::IsNullOrWhiteSpace($entered)) {
            return $Script:DefaultDeltaWebsiteDomain
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

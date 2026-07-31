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
      - the same underlying cmdlet Test-PostgresPort (setup.ps1) already
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

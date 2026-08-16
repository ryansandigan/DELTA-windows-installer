<#
.SYNOPSIS
    The DELTA Windows Service (WinSW) - acquisition, configuration,
    registration, identity, lifecycle, and unified runtime state.

.DESCRIPTION
    Everything specific to running the DEPLOYED DELTA application as the
    "DeltaApp" Windows Service lives here, and only here. setup.ps1 and
    uninstall.ps1 call into these functions; neither of them (nor any
    setup-*.ps1 / doctor.ps1) contains a raw sc.exe or WinSW invocation of
    its own, so there is exactly one place that knows how the service is
    named, configured, registered, secured, started, stopped, and removed.

    WHAT THE SERVICE ACTUALLY RUNS

    node.exe, directly, with no intermediate shell:

        <node.exe> --env-file="<AppRoot>\.env" "<serve-cli>" ./build/server/index.js

    launched with <AppRoot> as its working directory. This deliberately
    replaces the legacy launch path (cmd.exe -> dotenv-cli -> yarn ->
    react-router-serve -> node.exe), for three independently sufficient
    reasons, each confirmed against a real deployment rather than assumed:

      1. Those four hops are four separate processes with no parent/child
         lifetime coupling on Windows - the documented root cause of the
         orphaned-launcher failure mode this installer already has to
         detect and clean up (Test-DeltaLauncherProcessCommandLine,
         lib\DeltaInstaller.Common.ps1). Under a supervisor the wrapper
         would be supervising cmd.exe rather than the process that actually
         holds the listening socket.
      2. dotenv and yarn resolve only through the *User* PATH of whichever
         account ran the installer (Add-YarnGlobalBinToPersistentPath in
         setup.ps1 is explicit that this is per-user by design). A service
         identity does not share that PATH, so the legacy command line
         cannot work under a service account at all.
      3. The compiled application bundle never loads .env itself - it only
         reads process.env.* - so something must load it. Node's own
         --env-file was verified to parse this project's real .env
         byte-identically to dotenv-cli (all keys, including
         quoted-value-plus-inline-comment and single-quoted values
         containing double quotes), which removes the dependency without
         moving any secret into the service configuration.

    WHAT THIS FILE DOES NOT DO

    It owns no process-ownership, port-ownership, or readiness logic of its
    own. Get-DeltaRuntimeState composes the EXISTING shared primitives
    (Get-RunningDeltaProcesses, Test-TcpPortAvailable,
    Test-DeltaTcpPortListening, Get-ListeningTcpPortOwner) and adds Service
    Control Manager state as one more input. "The service is Running" is
    never treated as "DELTA is ready" - those are different facts, and
    Confirm-DeltaRuntimeStarted remains the only thing that decides the
    second one.

.NOTES
    Follows the same conventions as the other lib\ files: a plain
    dot-sourced script (not a module), requiring the caller to have set
    $Script:ProjectRoot from its own $PSScriptRoot beforehand.
#>

# This file is dot-sourced BY lib\DeltaInstaller.Common.ps1 (at the end of
# that file), deliberately in that direction rather than the reverse.
#
# Common.ps1's own runtime functions - Confirm-DeltaRuntimeNotRunning,
# Start-DeltaRuntimeForValidation, Confirm-DeltaRuntimeStarted,
# Restart-DeltaRuntimeForReverseProxy - have to be service-aware, and
# Restart-DeltaRuntimeForReverseProxy is called by setup-nginx.ps1,
# setup-iis.ps1, and setup.ps1's own management menu. Those scripts load
# Common.ps1 (directly or via lib\DeltaDoctor.*.ps1) and nothing else, so
# having Common.ps1 pull this file in is what lets all of them become
# service-aware with zero changes to any of them. Loading it the other way
# round would either leave those callers without these functions or create
# a dot-source cycle.
#
# Configuration.ps1 IS loaded here, since $Script:InstallerConfig's WINSW_*
# keys are needed by Get-DeltaWinSwBinary - exactly the "a lib\ file that
# needs installer metadata dot-sources this itself" case that file's own
# header anticipates. It is idempotent, so loading it here costs nothing
# when an entry-point script already did.
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Configuration.ps1')

# ---------------------------------------------------------------------------
# Service identity constants
# ---------------------------------------------------------------------------

# The Windows Service name. Also determines the virtual service account
# name below, so these two can never drift apart.
$Script:DeltaServiceName = 'DeltaApp'

$Script:DeltaServiceDisplayName = 'DELTA Application'
$Script:DeltaServiceDescription = 'Runs the deployed DELTA application (Node.js). Managed by the DELTA Windows Installer.'

# The per-service virtual account. Windows creates and manages this
# automatically the moment a service named $Script:DeltaServiceName exists -
# there is no account to create, no password to generate, store, or rotate,
# and it carries a unique SID that ACLs can target without also granting
# every other service on the machine (which is exactly what LocalService or
# NetworkService would do). LocalSystem is deliberately NOT used: it is full
# machine authority for an HTTP-facing Node application, with no
# repository-specific justification.
$Script:DeltaServiceAccount = "NT SERVICE\$($Script:DeltaServiceName)"

# How long to wait for an SCM stop to actually complete before treating it
# as genuinely timed out (at which point, and only then, the caller may fall
# back to direct process termination). Deliberately generous relative to the
# observed stop time (well under a second): a stop that is merely slow must
# never be escalated into a forced kill.
$Script:DeltaServiceStopTimeoutSeconds = 90

# How long to wait for the SCM to report Running after a start request. This
# is NOT a readiness timeout - it only covers the wrapper process starting.
# DELTA's own readiness is Confirm-DeltaRuntimeStarted's job and keeps its
# existing, much longer budgets.
$Script:DeltaServiceStartTimeoutSeconds = 60

# WinSW's own stdout/stderr capture, written into <AppRoot>\logs alongside
# (but never colliding with) the application's Winston output, which uses
# date-stamped names of its own. Rolled by size so a crash-looping service
# cannot fill the disk.
$Script:DeltaServiceLogSizeThresholdKb = 10240
$Script:DeltaServiceLogKeepFiles       = 8
$Script:DeltaServiceResetFailure       = '1 hour'
$Script:DeltaServiceStopTimeoutSetting = '30 sec'

# ---------------------------------------------------------------------------
# Path helpers (pure)
# ---------------------------------------------------------------------------

function Get-DeltaServiceDirectory {
    <#
      <AppRoot>\service - the WinSW executable and its generated XML live
      beside the application they supervise, never inside the installer
      repository. Two consequences that are the whole point: the service
      keeps working after the installer repository is deleted or moved, and
      removing the application directory takes its service files with it
      rather than orphaning them somewhere else on the disk.
    #>
    param([Parameter(Mandatory)][string]$AppRoot)
    return Join-Path -Path $AppRoot -ChildPath 'service'
}

function Get-DeltaServiceExecutablePath {
    <#
      WinSW requires its configuration file to be the executable's own path
      with the extension swapped (DeltaApp.exe -> DeltaApp.xml), which is
      why the deployed copy is renamed to the service name rather than kept
      under the published asset name.
    #>
    param([Parameter(Mandatory)][string]$AppRoot)
    return Join-Path -Path (Get-DeltaServiceDirectory -AppRoot $AppRoot) -ChildPath "$($Script:DeltaServiceName).exe"
}

function Get-DeltaServiceDefinitionPath {
    param([Parameter(Mandatory)][string]$AppRoot)
    return Join-Path -Path (Get-DeltaServiceDirectory -AppRoot $AppRoot) -ChildPath "$($Script:DeltaServiceName).xml"
}

function Get-DeltaServiceLogDirectory {
    <#
      Deliberately <AppRoot>\logs - the directory setup.ps1's own
      Initialize-DeltaRuntimeDirectories already creates, permissions, and
      proves writable - rather than a second log location this file would
      have to create and secure separately. WinSW's own files are named
      after the service (DeltaApp.out.log / .err.log / .wrapper.log) and so
      never collide with Winston's date-stamped output.
    #>
    param([Parameter(Mandatory)][string]$AppRoot)
    return Join-Path -Path $AppRoot -ChildPath 'logs'
}

function Get-DeltaServiceLogPaths {
    param([Parameter(Mandatory)][string]$AppRoot)
    $logDirectory = Get-DeltaServiceLogDirectory -AppRoot $AppRoot
    return [PSCustomObject]@{
        StdOut  = Join-Path -Path $logDirectory -ChildPath "$($Script:DeltaServiceName).out.log"
        StdErr  = Join-Path -Path $logDirectory -ChildPath "$($Script:DeltaServiceName).err.log"
        Wrapper = Join-Path -Path $logDirectory -ChildPath "$($Script:DeltaServiceName).wrapper.log"
    }
}

# ---------------------------------------------------------------------------
# Runtime entry-point resolution
# ---------------------------------------------------------------------------

function Resolve-DeltaServeCliPath {
    <#
      Resolves the INSTALLED @react-router/serve CLI's real path by asking
      Node to resolve the package and then reading that package's own
      package.json "bin" field - never a hardcoded path.

      This is not defensive over-engineering: docs/02's original NSSM
      reference procedure named
      node_modules\@react-router\serve\dist\cli.js, and that file does not
      exist in the version actually deployed (7.18.2 ships bin.js). A
      hardcoded path would therefore have produced a service that fails to
      start, on the very first machine it ran on, with an error pointing at
      Node rather than at the installer. Reading the package's own metadata
      is the only form that stays correct across dependency upgrades.

      Returns the absolute path, or calls Stop-Setup with a diagnostic - a
      missing serve CLI means dependencies were never installed, which is a
      genuine, unrecoverable precondition failure for a service that is
      about to be registered to run it.

      -AllowMissing turns that fatal outcome into a plain $null return, for
      the one caller that is ASKING rather than requiring:
      Get-DeltaServicePrerequisiteReport, which surveys whether a deployment
      can be converted to the service-managed model at all and must be able
      to answer "no, dependencies are missing" without terminating the run.
      The default stays fatal, so the registration path itself is unchanged.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$NodeExecutable,
        [switch]$AllowMissing
    )

    # Written as a single expression passed via -e, with $AppRoot supplied as
    # an argument (process.argv[1]) rather than interpolated into the script
    # text, so an application directory containing quotes or backslash
    # sequences cannot corrupt the script itself.
    #
    # Every JavaScript string literal below uses SINGLE quotes, and that is
    # load-bearing rather than stylistic: Windows PowerShell 5.1 strips
    # double quotes out of arguments it passes to a native executable, so a
    # double-quoted version of this script arrives at node as
    # require(path) - an immediate SyntaxError. Confirmed directly; single
    # quotes pass through untouched.
    $resolver = @'
const p=require('path'),f=require('fs');const m=require.resolve('@react-router/serve/package.json',{paths:[process.argv[1]]});const k=JSON.parse(f.readFileSync(m,'utf8'));const b=typeof k.bin==='string'?k.bin:k.bin[Object.keys(k.bin)[0]];process.stdout.write(p.resolve(p.dirname(m),b));
'@

    $resolved = $null
    $previousEap = $ErrorActionPreference
    try {
        # Relaxed for this one call so a resolution failure surfaces as an
        # empty result plus a non-zero exit code (handled below) rather than
        # a NativeCommandError terminating the script - the same technique
        # Invoke-DeltaTaskkill already uses for the same class of problem.
        $ErrorActionPreference = 'Continue'
        $resolved = & $NodeExecutable -e $resolver $AppRoot 2>&1
    }
    catch {
        $resolved = $null
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    $resolvedPath = if ($resolved) { ($resolved | ForEach-Object { $_.ToString() }) -join '' } else { '' }
    $resolvedPath = $resolvedPath.Trim()

    if ([string]::IsNullOrWhiteSpace($resolvedPath) -or -not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        if ($AllowMissing) {
            return $null
        }

        Stop-Setup @"
Could not resolve the @react-router/serve CLI inside the DELTA application directory:

$AppRoot

The DELTA Windows Service runs this file directly, so it must exist before the service can be registered.

This normally means the application's dependencies were not installed successfully - re-run setup.ps1 so the dependency phase runs again.
"@
    }

    return $resolvedPath
}

function Get-DeltaPostgresServiceDependency {
    <#
      The PostgreSQL Windows Service name to declare as a service
      dependency, or $null when a dependency would be wrong.

      Declared ONLY when both are true:
        - a local PostgreSQL service actually exists on this machine, and
        - the deployed DATABASE_URL actually points at this machine.

      The second condition is what keeps this correct for a deployment whose
      database lives on another host: declaring a dependency on a local
      PostgreSQL service there would make DELTA's startup wait on (or be
      blocked by) a service that has nothing to do with its database. A
      dependency that is merely unnecessary is not harmless - it is a boot
      ordering constraint.

      Worth being explicit about what this dependency does and does not buy:
      the SCM only guarantees the dependency reached "Running", never that
      PostgreSQL is accepting connections yet. The bounded restart policy
      covers that remaining gap - a DELTA that starts a moment too early is
      retried, rather than the whole service being deferred on every boot to
      make the first attempt more likely to succeed. These two are the
      startup-ordering mechanism; neither is a complete answer alone.
    #>
    param([Parameter(Mandatory)][string]$EnvPath)

    $service = Get-Service -Name 'postgresql*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $service) {
        return $null
    }

    $databaseUrl = Get-EnvFileValue -Path $EnvPath -Key 'DATABASE_URL'
    if ([string]::IsNullOrWhiteSpace($databaseUrl)) {
        # No DATABASE_URL to inspect yet. A local PostgreSQL service exists,
        # and this installer's own normal flow puts the database there, so
        # the dependency is the better default.
        return $service.Name
    }

    $components = ConvertFrom-DatabaseUrl -DatabaseUrl $databaseUrl
    if (-not $components) {
        return $service.Name
    }

    $localHosts = @('localhost', '127.0.0.1', '::1', '.')
    if ($components.PostgresHost -and ($localHosts -contains $components.PostgresHost.ToLowerInvariant())) {
        return $service.Name
    }

    return $null
}

# ---------------------------------------------------------------------------
# Service definition rendering
# ---------------------------------------------------------------------------

function ConvertTo-DeltaServiceXmlText {
    <#
      Escapes the five XML predefined entities so a path or value containing
      & or < cannot produce a malformed service definition. Applied to every
      substituted value rather than only the ones that "should" be safe -
      an application directory is operator-chosen, and guessing which
      characters it will never contain is exactly the assumption that breaks
      on the one machine nobody tested.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return '' }

    return $Value.
        Replace('&', '&amp;').
        Replace('<', '&lt;').
        Replace('>', '&gt;').
        Replace('"', '&quot;').
        Replace("'", '&apos;')
}

function Get-DeltaServiceDefinitionContent {
    <#
      Renders templates\service\delta-service.xml into the finished service
      definition text and RETURNS it, without writing anything.

      Returning a string rather than writing the file is what makes the two
      things that matter possible: the content can be compared against
      what is already on disk (so an unchanged run rewrites nothing and the
      service is never needlessly bounced - see Save-DeltaServiceDefinition),
      and the rendering itself can be exercised directly by
      tools\test-delta-service-definition.ps1 against arbitrary application
      roots and ports with no service, no WinSW, and no deployment present.

      Every value is XML-escaped (ConvertTo-DeltaServiceXmlText) and every
      path token lands inside quotes in the template, so directories
      containing spaces work without any special-casing here.
    #>
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$NodeExecutable,
        [Parameter(Mandatory)][string]$ServeCliPath,
        [Parameter(Mandatory)][string]$EnvPath,
        [Parameter(Mandatory)][string]$LogDirectory,
        [AllowNull()][string]$PostgresServiceName
    )

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        Stop-Setup "DELTA service definition template not found: $TemplatePath"
    }

    # Rendered as a complete element (or nothing at all) rather than as a
    # bare service name inside a fixed <depend> element in the template -
    # "no dependency" has to mean no element, not an empty one, which WinSW
    # would reject.
    $dependencyElement = ''
    if ($PostgresServiceName) {
        $dependencyElement = "  <depend>$(ConvertTo-DeltaServiceXmlText -Value $PostgresServiceName)</depend>`r`n"
    }

    $replacements = [ordered]@{
        '__DELTA_SERVICE_ID__'              = (ConvertTo-DeltaServiceXmlText -Value $Script:DeltaServiceName)
        '__DELTA_SERVICE_DISPLAY_NAME__'    = (ConvertTo-DeltaServiceXmlText -Value $Script:DeltaServiceDisplayName)
        '__DELTA_SERVICE_DESCRIPTION__'     = (ConvertTo-DeltaServiceXmlText -Value $Script:DeltaServiceDescription)
        '__DELTA_NODE_EXECUTABLE__'         = (ConvertTo-DeltaServiceXmlText -Value $NodeExecutable)
        '__DELTA_ENV_PATH__'                = (ConvertTo-DeltaServiceXmlText -Value $EnvPath)
        '__DELTA_SERVE_CLI__'               = (ConvertTo-DeltaServiceXmlText -Value $ServeCliPath)
        '__DELTA_APP_ROOT__'                = (ConvertTo-DeltaServiceXmlText -Value $AppRoot)
        '__DELTA_LOG_DIRECTORY__'           = (ConvertTo-DeltaServiceXmlText -Value $LogDirectory)
        '__DELTA_LOG_SIZE_THRESHOLD_KB__'   = "$($Script:DeltaServiceLogSizeThresholdKb)"
        '__DELTA_LOG_KEEP_FILES__'          = "$($Script:DeltaServiceLogKeepFiles)"
        '__DELTA_RESET_FAILURE__'           = (ConvertTo-DeltaServiceXmlText -Value $Script:DeltaServiceResetFailure)
        '__DELTA_STOP_TIMEOUT__'            = (ConvertTo-DeltaServiceXmlText -Value $Script:DeltaServiceStopTimeoutSetting)
        '__DELTA_SERVICE_DEPENDENCY__'      = $dependencyElement
    }

    $content = Get-Content -LiteralPath $TemplatePath -Raw
    foreach ($token in $replacements.Keys) {
        $content = $content.Replace($token, [string]$replacements[$token])
    }

    # A token surviving rendering means the template gained a placeholder
    # this function does not supply - caught here, at generation time, with
    # the token named, rather than as a WinSW parse error at service start.
    if ($content -match '__DELTA_[A-Z0-9_]+__') {
        Stop-Setup "DELTA service definition template contains an unsubstituted token: $($Matches[0]) ($TemplatePath)"
    }

    return $content
}

function Save-DeltaServiceDefinition {
    <#
      Writes the rendered definition to <AppRoot>\service\DeltaApp.xml, but
      ONLY when its content actually differs from what is already there.

      This is the mechanism behind "a no-op setup.ps1 re-run must not
      restart a healthy service": the caller decides whether to restart
      based on whether anything changed, and an unchanged deployment
      produces an unchanged file and therefore no restart. Comparing
      rendered content is what makes that decision honest - a timestamp or
      an "always rewrite" would make every run look like a change.

      Returns $true when the file was written, $false when it was already
      identical.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$Content
    )

    $definitionPath = Get-DeltaServiceDefinitionPath -AppRoot $AppRoot
    $serviceDirectory = Split-Path -Path $definitionPath -Parent
    if (-not (Test-Path -LiteralPath $serviceDirectory)) {
        New-Item -Path $serviceDirectory -ItemType Directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $definitionPath) {
        $existing = Get-Content -LiteralPath $definitionPath -Raw -ErrorAction SilentlyContinue
        if ($null -ne $existing -and $existing -ceq $Content) {
            return $false
        }
    }

    # No BOM, for the same reason Write-DeltaTemplateFile avoids one: PowerShell
    # 5.1's "utf8" encoding always prepends one, and a BOM ahead of the XML
    # declaration is not something every XML reader tolerates.
    $noBomUtf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($definitionPath, $Content, $noBomUtf8)
    return $true
}

function Test-DeltaServiceDefinitionFile {
    <#
      Whether the file at $Path is usable AS a WinSW service definition -
      not merely present.

      Presence alone is what Get-DeltaServiceRegistration originally
      checked, and it is not enough: a truncated write, a half-restored
      backup, or a hand-edit that broke a tag all leave a file that exists
      and a service that cannot start, in a way no amount of starting will
      fix. That failure looks identical to "simply stopped" from the Service
      Control Manager, so it has to be detected from the file itself.

      Deliberately shallow - well-formed XML whose root element is <service>.
      Validating individual elements would duplicate WinSW's own schema here
      and would start failing on definitions a newer WinSW accepts; anything
      that parses and is a service document is repaired the same way in any
      case (regenerated from the template), so a deeper check would change
      nothing about the outcome.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $document = New-Object System.Xml.XmlDocument
        $document.Load($Path)

        # The root element is identified by XPath rather than by reading
        # $document.DocumentElement.Name, which does NOT return what it
        # appears to: PowerShell's XML adapter exposes child elements as
        # properties, and this very template has a <name> child, so that
        # expression yields the service's display name instead of the
        # element name. SelectSingleNode is a real method call and is not
        # intercepted that way.
        return ($null -ne $document.SelectSingleNode('/service'))
    }
    catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# WinSW acquisition
# ---------------------------------------------------------------------------

function Get-DeltaWinSwBinary {
    <#
      Returns a verified WinSW executable from the project-local installer
      cache, downloading it only when it is not already there - the exact
      shape Get-NodeInstaller/Get-PostgresInstaller already use, so WinSW is
      cached, reused, and pre-seedable for offline installs the same way
      every other downloaded component is. The cache directory is
      .gitignored, so the binary is never committed.

      SHA-256 verification is unconditional and a mismatch is FATAL, for both
      the freshly-downloaded and the cached file. Two distinct reasons:
        - WinSW's published binaries carry no Authenticode signature
          (verified directly), so this digest is the only integrity
          guarantee that exists for them; and
        - a cached file is exactly where a stale or tampered binary would
          persist across runs, so verifying only after download would check
          the one case that needs it least.
      A corrupt cached file is deleted and re-downloaded once before giving
      up, since a truncated earlier download is the overwhelmingly likely
      cause and silently failing forever on it would be unhelpful.
    #>
    param([Parameter(Mandatory)][string]$DestinationDirectory)

    $expectedSha256 = $Script:InstallerConfig.WINSW_SHA256
    $sourceUrl      = $Script:InstallerConfig.WINSW_URL
    $cacheFileName  = $Script:InstallerConfig.WINSW_INSTALLER

    if (-not (Test-Path -Path $DestinationDirectory)) {
        New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null
    }

    $cachedPath = Join-Path -Path $DestinationDirectory -ChildPath $cacheFileName

    $attempt = 0
    while ($true) {
        $attempt++

        if (Test-Path -LiteralPath $cachedPath) {
            Write-Step 'Using cached WinSW service wrapper...'
            Write-Detail "Cache: $cachedPath"
        }
        else {
            # A neighbouring installer directory's own cache may already hold
            # this exact binary (Copy-DeltaReusableInstaller,
            # lib\DeltaInstaller.Common.ps1). The SHA-256 requirement above is
            # not relaxed for that path in any way - the same expected digest
            # is checked against the copied file before it is accepted, and
            # again below with everything else. A neighbouring copy that fails
            # it is discarded and the download runs instead, which is also what
            # keeps the retry loop finite: a rejected candidate can never be
            # re-copied into an endless verify/re-copy cycle.
            $reusedPath = Copy-DeltaReusableInstaller -FileName $cacheFileName -DestinationDirectory $DestinationDirectory -Validate {
                param($CandidatePath)
                (Get-FileHash -Path $CandidatePath -Algorithm SHA256).Hash.ToUpperInvariant() -eq $expectedSha256.ToUpperInvariant()
            }

            if (-not $reusedPath) {
                Write-Step "Downloading WinSW $($Script:InstallerConfig.WINSW_VERSION)..."
                Write-Detail "Source: $sourceUrl"
                Write-Detail "Target: $cachedPath"
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                    $previousProgress = $ProgressPreference
                    try {
                        $ProgressPreference = 'SilentlyContinue'
                        Invoke-WebRequest -Uri $sourceUrl -OutFile $cachedPath -UseBasicParsing -ErrorAction Stop
                    }
                    finally {
                        $ProgressPreference = $previousProgress
                    }
                }
                catch {
                    Stop-Setup "Failed to download WinSW from $sourceUrl : $($_.Exception.Message)"
                }
            }
        }

        $actualSha256 = (Get-FileHash -Path $cachedPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualSha256 -eq $expectedSha256.ToUpperInvariant()) {
            Write-Success '    WinSW checksum verified.'
            return $cachedPath
        }

        Remove-Item -LiteralPath $cachedPath -Force -ErrorAction SilentlyContinue

        if ($attempt -ge 2) {
            Stop-Setup @"
WinSW failed SHA-256 verification.

Expected: $($expectedSha256.ToUpperInvariant())
Actual:   $actualSha256

Source: $sourceUrl

The DELTA Windows Service cannot be installed with an unverified service wrapper. This is not skippable - the published WinSW binaries are not code-signed, so this checksum is the only integrity guarantee available.
"@
        }

        Write-Host ''
        Write-Host 'Cached WinSW binary failed verification - re-downloading once.' -ForegroundColor Yellow
        Write-Host ''
    }
}

function Install-DeltaServiceBinary {
    <#
      Places the verified WinSW executable at
      <AppRoot>\service\DeltaApp.exe, copying it only when it is missing or
      differs from the cached, verified source. Returns $true when it was
      written.

      Compared by hash rather than by existence so a damaged, truncated, or
      version-mismatched deployed copy is repaired by an ordinary re-run
      rather than persisting until somebody notices.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$SourcePath
    )

    $targetPath = Get-DeltaServiceExecutablePath -AppRoot $AppRoot
    $serviceDirectory = Split-Path -Path $targetPath -Parent
    if (-not (Test-Path -LiteralPath $serviceDirectory)) {
        New-Item -Path $serviceDirectory -ItemType Directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $targetPath) {
        $existingHash = (Get-FileHash -Path $targetPath -Algorithm SHA256).Hash
        $sourceHash   = (Get-FileHash -Path $SourcePath -Algorithm SHA256).Hash
        if ($existingHash -eq $sourceHash) {
            return $false
        }
    }

    Copy-Item -LiteralPath $SourcePath -Destination $targetPath -Force
    return $true
}

# ---------------------------------------------------------------------------
# Registration and identity
# ---------------------------------------------------------------------------

function Test-DeltaServiceBinaryPathMatch {
    <#
      Whether the registration's own ImagePath actually points at the WinSW
      executable belonging to THIS deployment.

      They can legitimately disagree: a deployment moved to a new directory,
      a second application root installed over an older registration, or a
      registration left behind by an installation whose directory was
      deleted by hand. In every one of those the service is registered, its
      files exist where the registration says they do, and it may even start
      - supervising the WRONG application root. Nothing else in the
      registration reveals that, so it is checked explicitly.

      Both sides are normalised before comparison, because the SCM stores
      the path in a shape nobody wrote by hand: quoted (Win32_Service
      returns "C:\DELTA\service\DeltaApp.exe" with the quotes), possibly
      with arguments appended, and with whatever casing and trailing
      separators were used at registration time. A quoting or casing
      difference is not a mismatch and must never trigger a re-registration.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$BinaryPath,
        [AllowNull()][AllowEmptyString()][string]$ExpectedPath
    )

    if ([string]::IsNullOrWhiteSpace($BinaryPath) -or [string]::IsNullOrWhiteSpace($ExpectedPath)) {
        # Nothing to disagree with - an unreadable ImagePath is reported by
        # the other registration fields, and inventing a mismatch here would
        # trigger a re-registration on no evidence at all.
        return $true
    }

    $actual = $BinaryPath.Trim()
    if ($actual.StartsWith('"')) {
        # Quoted form: the executable is everything up to the closing quote,
        # and any arguments follow it.
        $closingQuote = $actual.IndexOf('"', 1)
        $actual = if ($closingQuote -gt 0) { $actual.Substring(1, $closingQuote - 1) } else { $actual.Trim('"') }
    }

    try {
        $actualFull   = [System.IO.Path]::GetFullPath($actual)
        $expectedFull = [System.IO.Path]::GetFullPath($ExpectedPath.Trim('"').Trim())
    }
    catch {
        # A path Windows itself cannot normalise is compared as written
        # rather than treated as a mismatch on a formatting technicality.
        return ($actual.TrimEnd('\') -ieq $ExpectedPath.Trim('"').Trim().TrimEnd('\'))
    }

    return ($actualFull.TrimEnd('\') -ieq $expectedFull.TrimEnd('\'))
}

# The registry value recording that the DeltaApp service was disabled
# DELIBERATELY, by uninstall.ps1, rather than by damage or by drift. Lives on
# $Script:DeltaRegistryKeyPath (lib\DeltaInstaller.Common.ps1) alongside
# InstallPath/Version/ManagedInstanceRestartPolicy - it is installation
# metadata, not service configuration, and Windows has nowhere in the service
# registration itself to record an intent.
#
# Without it, "Disabled" is ambiguous in the one way that matters: an
# administrator who disabled DELTA on purpose last week and an uninstall that
# retained the application directory produce byte-identical service
# configuration, and setup.ps1 must not treat those two the same way.
$Script:DeltaServiceDisabledMarkerValueName = 'ServiceDisabledByUninstall'

function Set-DeltaServiceDisabledByUninstall {
    <#
      Records that this uninstall is what disabled the service. Best-effort
      by design: failing to write a marker must never fail an uninstall, and
      its absence only makes the later repair prompt more cautious, never
      wrong.
    #>
    try {
        if (-not (Test-Path -LiteralPath $Script:DeltaRegistryKeyPath)) {
            New-Item -Path $Script:DeltaRegistryKeyPath -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -LiteralPath $Script:DeltaRegistryKeyPath `
            -Name $Script:DeltaServiceDisabledMarkerValueName -Value 1 -Type DWord -ErrorAction Stop
    }
    catch {
        Write-Verbose "Could not record the intentional service-disable marker: $($_.Exception.Message)"
    }
}

function Clear-DeltaServiceDisabledByUninstall {
    <#
      Removes the marker once the service is genuinely back under automatic
      startup. Called from Set-DeltaServiceStartMode - the single place that
      re-enables the service - so the marker cannot outlive the state it
      describes and mislead a later run into explaining a healthy service as
      "left disabled by an uninstall".
    #>
    try {
        Remove-ItemProperty -LiteralPath $Script:DeltaRegistryKeyPath `
            -Name $Script:DeltaServiceDisabledMarkerValueName -ErrorAction SilentlyContinue
    }
    catch {
        Write-Verbose "Could not clear the intentional service-disable marker: $($_.Exception.Message)"
    }
}

function Test-DeltaServiceDisabledByUninstall {
    $entry = Get-ItemProperty -LiteralPath $Script:DeltaRegistryKeyPath `
        -Name $Script:DeltaServiceDisabledMarkerValueName -ErrorAction SilentlyContinue
    return ((Get-RegistryPropertyValue -InputObject $entry -Name $Script:DeltaServiceDisabledMarkerValueName) -eq 1)
}

function Get-DeltaServiceRegistration {
    <#
      Everything knowable about the DeltaApp service registration itself,
      without any statement about whether DELTA is actually working -
      that composition happens in Get-DeltaRuntimeState.

      Damaged is the state that matters most here and has no equivalent in
      Get-Service on its own: a service that IS registered but whose WinSW
      executable or XML is missing from disk - or present but not parseable
      as a service definition at all (Test-DeltaServiceDefinitionFile). That
      registration can never start, will fail at every boot, and must be
      repaired (rewritten and re-registered) rather than merely started - so
      it has to be distinguishable from "registered and simply stopped".

      The individual facts behind Damaged are reported alongside it, not
      just the summary: "the wrapper is missing", "the definition is
      corrupt" and "the registration points at another directory" are three
      different things to tell an administrator, even though all three are
      repaired by the same regenerate-and-re-register sequence.
    #>
    param([AllowNull()][string]$AppRoot)

    $service = Get-Service -Name $Script:DeltaServiceName -ErrorAction SilentlyContinue

    $executablePresent = $false
    $definitionPresent = $false
    $definitionValid   = $false
    if ($AppRoot) {
        $executablePresent = Test-Path -LiteralPath (Get-DeltaServiceExecutablePath -AppRoot $AppRoot) -PathType Leaf
        $definitionPath    = Get-DeltaServiceDefinitionPath -AppRoot $AppRoot
        $definitionPresent = Test-Path -LiteralPath $definitionPath -PathType Leaf
        $definitionValid   = Test-DeltaServiceDefinitionFile -Path $definitionPath
    }

    $startName = $null
    $binaryPath = $null
    $delayedAutoStart = $false
    if ($service) {
        $cimService = Get-CimInstance -ClassName Win32_Service -Filter "Name = '$($Script:DeltaServiceName)'" -ErrorAction SilentlyContinue
        if ($cimService) {
            $startName  = $cimService.StartName
            $binaryPath = $cimService.PathName
        }
        # Delayed autostart is not exposed by Get-Service or Win32_Service at
        # all - it lives only in the service's own registry key.
        $registryKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$($Script:DeltaServiceName)"
        $entry = Get-ItemProperty -LiteralPath $registryKey -Name 'DelayedAutostart' -ErrorAction SilentlyContinue
        $delayedValue = Get-RegistryPropertyValue -InputObject $entry -Name 'DelayedAutostart'
        $delayedAutoStart = ($delayedValue -eq 1)
    }

    # Only meaningful for a registration that actually exists AND a known
    # application root to compare it against - with no $AppRoot there is no
    # expected path, and "matches" is the only answer that cannot cause a
    # pointless re-registration.
    $binaryPathMatches = $true
    if ($service -and $AppRoot) {
        $binaryPathMatches = Test-DeltaServiceBinaryPathMatch `
            -BinaryPath $binaryPath `
            -ExpectedPath (Get-DeltaServiceExecutablePath -AppRoot $AppRoot)
    }

    return [PSCustomObject]@{
        Exists             = [bool]$service
        Status             = if ($service) { "$($service.Status)" } else { $null }
        StartType          = if ($service) { "$($service.StartType)" } else { $null }
        StartName          = $startName
        BinaryPath         = $binaryPath
        BinaryPathMatches  = $binaryPathMatches
        DelayedAutoStart   = $delayedAutoStart
        ExecutablePresent  = $executablePresent
        DefinitionPresent  = $definitionPresent
        DefinitionValid    = $definitionValid
        DisabledByUninstall = ([bool]$service -and (Test-DeltaServiceDisabledByUninstall))
        Damaged            = ([bool]$service -and $AppRoot -and (-not ($executablePresent -and $definitionValid)))
    }
}

function Get-DeltaServiceStartModeDescription {
    <#
      The startup mode as an administrator would recognise it, derived from
      what the Service Control Manager actually reports rather than from
      what our own WinSW template asked for. A service whose start mode was
      changed by hand, or disabled by uninstall.ps1 when it retained an
      application directory, has to be described as it IS.

      Deliberately just the SCM's own StartType, with no delayed-start
      qualifier. DELTA is configured for plain Automatic, so the only reason
      DelayedAutostart could be set on a DeltaApp service now is drift from
      an older deployment - and drift is something the repair path corrects
      (Get-DeltaServiceRepairCondition), not something this line dresses up
      as a legitimate mode. Describing it here would present a state the
      installer is about to fix as though it were the supported one.
    #>
    param([AllowNull()][AllowEmptyString()][string]$StartType)

    if ([string]::IsNullOrWhiteSpace($StartType)) {
        return 'Unknown'
    }

    return $StartType
}

function Register-DeltaWindowsService {
    <#
      Registers (or re-registers) the service with the SCM by invoking
      WinSW's own `install`, then applies the identity and start-mode
      settings WinSW does not set for us.

      Idempotency is handled by uninstall-then-install when a registration
      already exists, rather than by attempting to detect and patch every
      individual property that might have drifted. That is deliberate: the
      set of properties involved (binary path, dependencies, start mode,
      delayed-autostart flag, failure actions, account) is large enough that
      a partial repair path would be its own source of subtle, hard-to-test
      divergence, and re-registration is fast, non-destructive to the
      application, and produces exactly the state the generated XML
      describes. The caller is responsible for having stopped the service
      first.
    #>
    param([Parameter(Mandatory)][string]$AppRoot)

    $executablePath = Get-DeltaServiceExecutablePath -AppRoot $AppRoot

    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        Stop-Setup "The DELTA service wrapper is missing: $executablePath"
    }

    $existing = Get-DeltaServiceRegistration -AppRoot $AppRoot
    if ($existing.Exists) {
        Write-Detail 'Re-registering the existing DELTA service so its configuration matches this deployment...'
        Invoke-DeltaServiceWrapper -ExecutablePath $executablePath -Action 'uninstall' -AllowFailure
        # The SCM can hold a deleted service in "marked for deletion" for a
        # moment after the handle is released; installing into that window
        # fails with a confusing error, so wait for it to actually go.
        Wait-Until -TimeoutSeconds 30 -Condition {
            -not (Get-Service -Name $Script:DeltaServiceName -ErrorAction SilentlyContinue)
        } | Out-Null
    }

    Invoke-DeltaServiceWrapper -ExecutablePath $executablePath -Action 'install'

    if (-not (Get-Service -Name $Script:DeltaServiceName -ErrorAction SilentlyContinue)) {
        Stop-Setup "The DELTA service was installed but is not registered with the Service Control Manager: $($Script:DeltaServiceName)"
    }

    Set-DeltaServiceIdentity
    Set-DeltaServiceStartMode
}

function Invoke-DeltaServiceWrapper {
    <#
      Runs a WinSW verb (install/uninstall/start/stop/status) without
      letting its own stderr abort the script under this project's
      Set-StrictMode + $ErrorActionPreference = 'Stop' - the same reasoning,
      and the same relax-and-restore pattern, Invoke-DeltaTaskkill already
      documents for taskkill.

      WinSW's normal, successful output is informational logging, so it is
      routed to Write-Verbose rather than the console; only a genuine
      failure (non-zero exit, without -AllowFailure) is surfaced, and then
      with WinSW's own text included so the operator sees what it actually
      said.
    #>
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][ValidateSet('install', 'uninstall', 'start', 'stop', 'status', 'refresh')][string]$Action,
        [switch]$AllowFailure
    )

    $previousEap = $ErrorActionPreference
    $captured = $null
    try {
        $ErrorActionPreference = 'Continue'
        $captured = & $ExecutablePath $Action 2>&1
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    $capturedText = ($captured | ForEach-Object { $_.ToString() } | Where-Object { $_ }) -join "`n"
    if ($capturedText) {
        Write-Verbose "WinSW $Action : $capturedText"
    }

    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        Stop-Setup "The DELTA service wrapper failed during '$Action' (exit code $LASTEXITCODE).`n`n$capturedText"
    }

    return $capturedText
}

function Set-DeltaServiceIdentity {
    <#
      Points the service at its per-service virtual account,
      NT SERVICE\DeltaApp.

      Applied through sc.exe rather than WinSW's own <serviceaccount>
      element: the virtual account needs no password, and sc.exe's
      `obj=` assignment is the form that was actually validated end to end
      (the service started, and the child node.exe was confirmed via
      Win32_Process.GetOwner to be running as NT SERVICE\DeltaApp).
      Windows creates and manages the account itself as a side effect of the
      service existing, so there is nothing to provision beforehand and no
      credential for this installer to generate, store, or rotate.

      Runs after registration, never before - the virtual account's SID does
      not exist until the service does, which is also why
      Grant-DeltaServiceFileSystemPermission has to run after this rather
      than alongside the other permission work in
      Initialize-DeltaRuntimeDirectories.
    #>
    Write-Step "Configuring the service to run as $($Script:DeltaServiceAccount)..."

    $previousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & sc.exe config $Script:DeltaServiceName obj= $Script:DeltaServiceAccount 2>&1
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    if ($LASTEXITCODE -ne 0) {
        Stop-Setup "Failed to configure the DELTA service to run as $($Script:DeltaServiceAccount): $(($output | Out-String).Trim())"
    }

    Write-Success "    Service identity: $($Script:DeltaServiceAccount)"
}

function Set-DeltaServiceStartMode {
    <#
      Plain Automatic - DELTA starts as soon as the Service Control Manager
      can start it, with no deliberate delay after boot.

      The generated XML already asks for <startmode>Automatic</startmode>;
      this re-asserts it through sc.exe afterwards so the mode is guaranteed
      regardless of how a given WinSW build applies that element, and so a
      service previously set to Disabled (exactly what uninstall.ps1 does
      when it retains an application directory whose prerequisites are being
      removed) or to Manual is returned to Automatic by an ordinary re-run
      rather than staying that way silently.

      DELAYED AUTOSTART IS VERIFIED CLEARED, not assumed cleared.

      The flag does not live in the service configuration sc.exe reports -
      it is a separate registry value (see Get-DeltaServiceRegistration) -
      and this installer previously SET it on every deployment it made, so
      every existing installation arrives here carrying it. `start= auto`
      does write that value back to 0, confirmed directly against a live
      DeltaApp service, and the read-back below is what turns that from an
      assumption into something this function has actually established. It
      is the difference between a service that reports Automatic and a
      service that genuinely starts without the delay; inferring it would be
      exactly the "changed the label, kept the behaviour" outcome this must
      not produce.

      The removal is therefore a rarely-taken safety net rather than the
      normal path, and it removes rather than writes 0 because an absent
      value and a 0 are equivalent to Windows - removing leaves the registry
      shape a service that never had delayed start would have.
    #>
    $previousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & sc.exe config $Script:DeltaServiceName start= auto 2>&1
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    if ($LASTEXITCODE -ne 0) {
        Stop-Setup "Failed to configure automatic startup for the DELTA service: $(($output | Out-String).Trim())"
    }

    $registryKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$($Script:DeltaServiceName)"
    $entry = Get-ItemProperty -LiteralPath $registryKey -Name 'DelayedAutostart' -ErrorAction SilentlyContinue
    if ((Get-RegistryPropertyValue -InputObject $entry -Name 'DelayedAutostart') -eq 1) {
        try {
            Remove-ItemProperty -LiteralPath $registryKey -Name 'DelayedAutostart' -ErrorAction Stop
            Write-Detail 'Delayed automatic start disabled.'
        }
        catch {
            Stop-Setup "Failed to disable delayed automatic start for the DELTA service: $($_.Exception.Message)"
        }
    }

    # The service is genuinely back on automatic startup, so any record that
    # an uninstall deliberately disabled it is now stale - and a stale marker
    # would make a later run explain a perfectly healthy service in terms of
    # an uninstall that no longer applies. Cleared here rather than at the
    # call sites because this is the one function that ends the disabled
    # state, whichever path reached it.
    Clear-DeltaServiceDisabledByUninstall

    Write-Success '    Startup type: Automatic'
}

function Grant-DeltaServiceFileSystemPermission {
    <#
      Grants the virtual service account exactly the access the running
      application actually needs, and nothing more:

        <AppRoot>            ReadAndExecute  - load the compiled bundle and
                                               node_modules, serve static
                                               assets from build\client
        <AppRoot>\.env       Read            - configuration and secrets;
                                               the application never writes
                                               it, so it never gets more
        <AppRoot>\logs       Modify          - Winston's rotating output,
                                               plus WinSW's own capture
        <AppRoot>\uploads    Modify          - user-submitted files
        <AppRoot>\service    Modify          - WinSW's own working state

      Deliberately NOT FullControl anywhere: FullControl additionally
      confers the right to change permissions and take ownership, which a
      web application process has no reason to hold over its own program
      files.

      No privileges beyond file access are granted, and none are needed: the
      configured application port is above 1024, so binding it requires
      nothing special, and outbound connections to PostgreSQL/SMTP need no
      machine identity because the application authenticates with its own
      credentials from .env.

      LOG_DIR is honoured when it points somewhere else entirely - the
      application defaults it to "logs" relative to its working directory,
      but an operator who redirected it would otherwise get a service that
      starts and then fails on its first log write, which is a genuinely
      confusing failure to diagnose after the fact.

      Inherited ACEs are added, never replaced: Administrators and SYSTEM
      keep their existing access untouched, so the installer, backup,
      update, and reinstall paths all keep working exactly as before.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$EnvPath
    )

    Write-Step 'Applying least-privilege permissions for the service account...'

    $modifyTargets = @(
        (Join-Path -Path $AppRoot -ChildPath 'logs'),
        (Join-Path -Path $AppRoot -ChildPath 'uploads'),
        (Get-DeltaServiceDirectory -AppRoot $AppRoot)
    )

    # A relocated LOG_DIR needs the same Modify access the default one gets.
    # Relative values already resolve inside $AppRoot\logs and are therefore
    # covered above.
    $configuredLogDir = Get-EnvFileValue -Path $EnvPath -Key 'LOG_DIR'
    if ($configuredLogDir -and [System.IO.Path]::IsPathRooted($configuredLogDir)) {
        $modifyTargets += $configuredLogDir
    }

    Grant-DeltaServiceAccountAccess -Path $AppRoot -Rights 'RX'

    foreach ($target in $modifyTargets) {
        if (Test-Path -LiteralPath $target) {
            Grant-DeltaServiceAccountAccess -Path $target -Rights 'M'
        }
    }

    # .env is hardened here as well as granted: this both removes the broad
    # BUILTIN\Users read access it inherits by default and adds the service
    # account's own Read in a single, consistent step.
    Protect-DeltaSecretFile -Path $EnvPath -ReadAccounts @($Script:DeltaServiceAccount)

    Write-Success '    Service account permissions applied.'
}

function Grant-DeltaServiceAccountAccess {
    <#
      One icacls grant for the service account, with (OI)(CI) so the right
      is inherited by files and folders created later - uploads and log
      files are created by the application at runtime, long after this runs,
      so a non-inheriting grant would work exactly once and then quietly
      stop applying to everything that matters.

      /T reapplies to existing children (a no-op on an empty directory, but
      correct when re-run against a deployment that already has real uploads
      and logs) and /C continues past individual per-file errors rather than
      abandoning the whole grant; the overall exit code is still checked.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('RX', 'M')][string]$Rights
    )

    $grant = "$($Script:DeltaServiceAccount):(OI)(CI)$Rights"

    $previousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & icacls.exe $Path /grant $grant /T /C 2>&1
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    if ($LASTEXITCODE -ne 0) {
        Stop-Setup "Failed to grant $Rights access on $Path to $($Script:DeltaServiceAccount): $(($output | Out-String).Trim())"
    }

    Write-Detail "$(if ($Rights -eq 'RX') { 'Read/Execute' } else { 'Modify' }): $Path"
}

# ---------------------------------------------------------------------------
# Service lifecycle
# ---------------------------------------------------------------------------

function Test-DeltaServiceInstalled {
    return [bool](Get-Service -Name $Script:DeltaServiceName -ErrorAction SilentlyContinue)
}

function Test-DeltaSupervisedRestartInProgress {
    <#
      Whether a momentarily-absent DELTA process might simply be one the
      supervisor is restarting, rather than one that has failed for good.

      Consumed only by Confirm-DeltaRuntimeStarted's two fast-fail checks.
      Those exist so a genuinely crashed startup fails immediately with a
      real diagnostic instead of burning the full timeout - valuable
      behaviour that must be kept - but their "the process disappeared"
      signal stops being conclusive once something is actively restarting
      it. WinSW's first restart delay is 10 seconds, well inside both
      startup budgets, so without this a perfectly successful automatic
      recovery would be reported as an installation failure.

      The service still being Running is the discriminator: the SCM stops
      the service once the bounded restart policy is exhausted, so a service
      that has truly given up returns $false here and the original fast-fail
      applies unchanged.
    #>
    if (-not (Test-DeltaServiceInstalled)) {
        return $false
    }

    $service = Get-Service -Name $Script:DeltaServiceName -ErrorAction SilentlyContinue
    return [bool]($service -and $service.Status -in @('Running', 'StartPending'))
}

function Start-DeltaWindowsService {
    <#
      Requests an SCM start and waits only for the SCM to acknowledge the
      service is Running. It deliberately does NOT wait for DELTA to be
      ready, and must never be mistaken for doing so - the wrapper being up
      says nothing about whether the application has bound its port or can
      answer a request. Confirm-DeltaRuntimeStarted remains the only thing
      that decides readiness, and callers run it immediately after this.
    #>
    $service = Get-Service -Name $Script:DeltaServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Stop-Setup "The DELTA service ($($Script:DeltaServiceName)) is not registered, so it cannot be started."
    }

    if ($service.Status -eq 'Running') {
        Write-Detail 'The DELTA service is already running.'
        return
    }

    try {
        Start-Service -Name $Script:DeltaServiceName -ErrorAction Stop
    }
    catch {
        Stop-Setup (Get-DeltaServiceStartFailureMessage -Reason "Failed to start the DELTA service: $($_.Exception.Message)")
    }

    $running = Wait-Until -TimeoutSeconds $Script:DeltaServiceStartTimeoutSeconds -Condition {
        $current = Get-Service -Name $Script:DeltaServiceName -ErrorAction SilentlyContinue
        $current -and $current.Status -eq 'Running'
    }

    if (-not $running) {
        Stop-Setup (Get-DeltaServiceStartFailureMessage -Reason "The DELTA service did not reach the Running state within $($Script:DeltaServiceStartTimeoutSeconds) seconds.")
    }
}

function Stop-DeltaWindowsService {
    <#
      Requests an SCM stop and waits for it to complete, returning $true on
      success and $false only if the service is genuinely still not Stopped
      after the full timeout.

      That boolean is the ONLY thing that authorizes a caller to fall back
      to direct process termination. A healthy, service-supervised DELTA
      must never be taskkill'd: the supervisor would simply restart what was
      killed, so the installer would be fighting the thing it just
      installed. Returning false rather than escalating here keeps that
      decision - and its narrow justification - at the call site.
    #>
    $service = Get-Service -Name $Script:DeltaServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        return $true
    }

    if ($service.Status -eq 'Stopped') {
        return $true
    }

    try {
        Stop-Service -Name $Script:DeltaServiceName -Force -ErrorAction Stop
    }
    catch {
        Write-Verbose "Stop-Service reported: $($_.Exception.Message)"
    }

    return [bool](Wait-Until -TimeoutSeconds $Script:DeltaServiceStopTimeoutSeconds -Condition {
        $current = Get-Service -Name $Script:DeltaServiceName -ErrorAction SilentlyContinue
        (-not $current) -or $current.Status -eq 'Stopped'
    })
}

function Set-DeltaServiceDisabled {
    <#
      Stops the service and sets it to Disabled, without unregistering it.

      Exists for exactly one situation, and it is not hypothetical:
      uninstall.ps1 removes Node.js unconditionally, but leaves the DELTA
      application directory in place unless the operator explicitly asks for
      it to be removed. An Automatic service pointed at a now-missing
      node.exe would then fail at every single boot, forever, with bounded
      restarts each time - noisy, alarming, and completely useless. Disabling
      it makes that state quiet and, importantly, reversible: re-running
      setup.ps1 re-registers and re-enables the service (Set-DeltaServiceStartMode
      resets the start type), so reinstall after uninstall stays clean.
    #>
    if (-not (Test-DeltaServiceInstalled)) {
        return
    }

    Stop-DeltaWindowsService | Out-Null

    $previousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & sc.exe config $Script:DeltaServiceName start= disabled 2>&1
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Detail "Could not disable the DELTA service: $(($output | Out-String).Trim())"
        return
    }

    # Records that THIS is a deliberate, uninstall-driven disable rather than
    # damage or drift. setup.ps1's repair path reads it back to explain the
    # state accurately, and still asks before undoing it - the marker changes
    # the wording and the confidence, never the fact that re-enabling a
    # disabled service is the operator's decision to make.
    Set-DeltaServiceDisabledByUninstall

    Write-Detail "The DELTA service was stopped and disabled (it will not start at boot)."
}

function Uninstall-DeltaWindowsService {
    <#
      Stops and unregisters the service.

      Ordering matters and is the reason this is a function rather than two
      lines at the call site: the WinSW executable and its XML live under
      the application directory, so the service must be unregistered BEFORE
      that directory is deleted. Deleting the files first leaves a
      registration pointing at a missing binary - a service that cannot
      start, cannot be repaired by re-running anything, and has to be
      removed by hand with sc.exe.

      Falls back to `sc.exe delete` when the WinSW executable is already
      gone (a partially-removed installation, or one whose directory was
      deleted by hand), so a stale registration is still cleaned up rather
      than left behind because the tool that created it no longer exists.
    #>
    param([AllowNull()][string]$AppRoot)

    if (-not (Test-DeltaServiceInstalled)) {
        return $false
    }

    Write-Step 'Removing the DELTA Windows Service...'

    if (-not (Stop-DeltaWindowsService)) {
        Write-Detail 'The service did not stop within the timeout - continuing with removal.'
    }

    $executablePath = if ($AppRoot) { Get-DeltaServiceExecutablePath -AppRoot $AppRoot } else { $null }

    if ($executablePath -and (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        Invoke-DeltaServiceWrapper -ExecutablePath $executablePath -Action 'uninstall' -AllowFailure | Out-Null
    }
    else {
        $previousEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $null = & sc.exe delete $Script:DeltaServiceName 2>&1
        }
        finally {
            $ErrorActionPreference = $previousEap
        }
    }

    $removed = Wait-Until -TimeoutSeconds 30 -Condition {
        -not (Get-Service -Name $Script:DeltaServiceName -ErrorAction SilentlyContinue)
    }

    if ($removed) {
        Write-Success '    DELTA Windows Service removed.'
    }
    else {
        Write-Host ''
        Write-Host 'WARNING' -ForegroundColor Yellow
        Write-Host ''
        Write-Host "The DELTA service registration ($($Script:DeltaServiceName)) is still present." -ForegroundColor Yellow
        Write-Host 'It is usually marked for deletion and disappears after a reboot.' -ForegroundColor Yellow
        Write-Host "If it does not, remove it manually (as Administrator): sc.exe delete $($Script:DeltaServiceName)" -ForegroundColor Yellow
        Write-Host ''
    }

    return $removed
}

function Get-DeltaServiceStartFailureMessage {
    <#
      A start failure diagnostic pointing at the service's own logs -
      the counterpart to Get-DeltaStartupFailureMessage's role for the
      legacy launch path, and the reason that function became service-aware
      rather than being duplicated here.
    #>
    param([Parameter(Mandatory)][string]$Reason)

    $message = $Reason

    if ($Script:DeltaRuntimeRoot) {
        $logPaths = Get-DeltaServiceLogPaths -AppRoot $Script:DeltaRuntimeRoot
        $message += "`n`nService logs:`n$($logPaths.StdOut)`n$($logPaths.StdErr)`n$($logPaths.Wrapper)"

        foreach ($logPath in @($logPaths.StdErr, $logPaths.Wrapper)) {
            if (Test-Path -LiteralPath $logPath) {
                $tail = @(Get-Content -LiteralPath $logPath -Tail 15 -ErrorAction SilentlyContinue)
                if ($tail.Count -gt 0) {
                    $message += "`n`nLast lines of $(Split-Path -Leaf $logPath):`n$($tail -join "`n")"
                    break
                }
            }
        }
    }

    return $message
}

# ---------------------------------------------------------------------------
# Unified runtime state
# ---------------------------------------------------------------------------

function Get-DeltaRuntimeState {
    <#
      The single answer to "what is DELTA actually doing right now",
      combining Service Control Manager state with the process-ownership and
      port-ownership evidence this installer already trusted before any
      service existed. Every input below is an EXISTING shared function -
      nothing here re-implements process matching, port detection, or
      readiness.

      The states, and why each is distinct rather than collapsed into a
      simpler running/stopped pair:

        NotInstalled - no service registered. A legacy, directly-launched
                       instance can still be Running in this state, which is
                       exactly what makes migration detectable.
        Damaged      - registered, but the WinSW executable or XML is
                       missing. Cannot start, and starting is not the fix.
        Conflicted   - the configured port is held by a process that is NOT
                       DELTA. Reported, never killed - this installer has
                       never been willing to terminate a process it does not
                       own, and a service does not change that.
        Broken       - the service is Running but no DELTA process exists,
                       or a DELTA process exists with no service supervising
                       it, or a legacy launcher survives with no server.
        Starting     - service Running, process present, port not yet bound.
                       A normal, expected state: cold start was measured at
                       ~38 seconds under the service.
        Running      - service Running, DELTA process present, and that
                       process owns the configured port.
        Stopped      - registered, not running, nothing listening.

      -IncludeHttpProbe is opt-in because an HTTP round trip is the one
      check here that can block for seconds; the interactive menu re-derives
      state on every keystroke-driven redraw and does not want it, whereas a
      post-start verification does.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [AllowNull()][System.Nullable[int]]$Port,
        [switch]$IncludeHttpProbe
    )

    $registration = Get-DeltaServiceRegistration -AppRoot $AppRoot

    $processes       = @(Get-RunningDeltaProcesses -DeltaRuntimeRoot $AppRoot)
    $launcherCount   = @(Get-RunningDeltaLauncherProcesses).Count
    $processCount    = $processes.Count

    $portListening      = $false
    $portOwnerPid       = $null
    $portOwnedByDelta   = $false
    $unrelatedPortOwner = $null

    if ($null -ne $Port) {
        $portCheck = Test-TcpPortAvailable -Port $Port
        $portListening = -not $portCheck.Available
        if ($portListening) {
            $portOwnerPid = $portCheck.OwningProcessId
            $portOwnedByDelta = @($processes | Where-Object { [int]$_.ProcessId -eq [int]$portOwnerPid }).Count -gt 0
            if (-not $portOwnedByDelta) {
                $unrelatedPortOwner = $portCheck.OwnerDescription
            }
        }
    }

    $httpResponding = $null
    if ($IncludeHttpProbe -and $portOwnedByDelta -and $null -ne $Port) {
        $httpResponding = Test-DeltaHttpEndpoint -Url "http://localhost:$Port/"
    }

    $serviceRunning = ($registration.Exists -and $registration.Status -eq 'Running')

    # Order matters: the more specific, more actionable diagnoses are
    # evaluated before the general ones, so (for example) a damaged
    # registration is never reported as merely "Stopped".
    $state = 'Stopped'
    if ($registration.Damaged) {
        $state = 'Damaged'
    }
    elseif ($unrelatedPortOwner -and $processCount -eq 0) {
        $state = 'Conflicted'
    }
    elseif ($serviceRunning -and $processCount -eq 0) {
        $state = 'Broken'
    }
    elseif ($processCount -gt 0 -and $registration.Exists -and -not $serviceRunning) {
        # A DELTA process running while its own service reports stopped is
        # an unsupervised orphan, not a healthy runtime.
        $state = 'Broken'
    }
    elseif ($processCount -eq 0 -and $launcherCount -gt 0) {
        $state = 'Broken'
    }
    elseif ($processCount -gt 0 -and $portOwnedByDelta) {
        $state = 'Running'
    }
    elseif ($processCount -gt 0) {
        $state = 'Starting'
    }
    elseif (-not $registration.Exists) {
        $state = 'NotInstalled'
    }

    # Presentation-only, and does not feed $state, which stays exactly what
    # the SCM and the process/port checks reported.
    $startTypeDescription = Get-DeltaServiceStartModeDescription -StartType $registration.StartType

    return [PSCustomObject]@{
        State              = $state
        IsServiceManaged   = $registration.Exists
        ServiceInstalled   = $registration.Exists
        ServiceStatus      = $registration.Status
        ServiceStartType   = $registration.StartType
        ServiceStartTypeDescription = $startTypeDescription
        ServiceAccount     = $registration.StartName
        ServiceDamaged     = $registration.Damaged
        # Passed through rather than re-derived: Get-DeltaServiceRepairCondition
        # is a pure function over exactly these facts, and every one of them
        # was already read here.
        ServiceExecutablePresent = $registration.ExecutablePresent
        ServiceDefinitionPresent = $registration.DefinitionPresent
        ServiceDefinitionValid   = $registration.DefinitionValid
        ServiceBinaryPathMatches = $registration.BinaryPathMatches
        ServiceDisabledByUninstall = $registration.DisabledByUninstall
        # Still surfaced, but now only as drift evidence for the repair
        # condition below - never as a startup mode to display.
        DelayedAutoStart   = $registration.DelayedAutoStart
        Processes          = $processes
        ProcessCount       = $processCount
        LegacyLauncherCount = $launcherCount
        Port               = $Port
        PortListening      = $portListening
        PortOwnerProcessId = $portOwnerPid
        PortOwnedByDelta   = $portOwnedByDelta
        UnrelatedPortOwner = $unrelatedPortOwner
        HttpResponding     = $httpResponding
    }
}

# ---------------------------------------------------------------------------
# Service-managed lifecycle repair
#
# Once the Windows Service is part of the supported DELTA architecture, a
# deployment WITHOUT a healthy DeltaApp registration is not a normal runtime
# state an administrator should have to reason about - it is a migration or a
# repair, and the installer should recognise and perform it.
#
# The three functions below are the decision half of that, deliberately
# separated from the doing half (setup.ps1's own
# Invoke-DeltaServiceLifecycleRepair): everything here is pure or read-only,
# takes plain values rather than reaching for script state, and is therefore
# testable case by case (tools\test-delta-service-definition.ps1) without a
# service, a deployment, or Administrator rights.
#
# The single rule they encode, and the reason they exist at all:
#
#     "the DeltaApp service is missing" is NOT "DELTA must be
#      updated or reinstalled".
#
# A deployment that already has everything a registration needs is converted
# in place - no runtime redeployment, no dependency install, no database work,
# no configuration rewriting. The full installation flow is reached only when
# a genuine prerequisite is missing, and then by handing off to the EXISTING
# flow rather than by duplicating any part of it here.
# ---------------------------------------------------------------------------

function Get-DeltaServicePrerequisiteReport {
    <#
      Whether an existing deployment already has everything
      Install-DeltaWindowsService needs, so it can be converted to the
      service-managed model directly instead of being redeployed.

      The list is derived from what that function and the generated
      definition actually consume, not from what a full installation happens
      to produce:

        .env                  embedded in the service arguments
                              (--env-file) and hardened by the ACL step
        DATABASE_URL          read to decide the PostgreSQL <depend>
        PORT                  must be valid if present; absent is fine and
                              means the default
        node.exe              the service's <executable>
        node_modules          where the serve CLI is resolved from
        @react-router/serve   the service's own argument, resolved from the
                              installed package's own metadata
        build\server\index.js what the serve CLI is pointed at
        logs\                 <logpath>, and granted Modify
        uploads\              granted Modify

      Everything here is a read - nothing is created, written, installed or
      repaired. A gap is REPORTED, never filled: creating a missing
      directory or reinstalling missing dependencies is existing
      installation work that already has a home, and duplicating any part of
      it here is precisely what this design exists to avoid.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [AllowNull()][AllowEmptyString()][string]$RawPort
    )

    if (-not (Test-Path -LiteralPath $AppRoot -PathType Container)) {
        return [PSCustomObject]@{
            Satisfied      = $false
            Missing        = @("the application directory ($AppRoot)")
            NodeExecutable = $null
            ServeCliPath   = $null
        }
    }

    $missing = @()

    $envPath = Join-Path -Path $AppRoot -ChildPath '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        # Never invented: .env carries the database credentials and every
        # other deployment secret, and a generated replacement would be a
        # different deployment wearing the same directory name.
        $missing += 'the .env configuration file'
    }
    elseif ([string]::IsNullOrWhiteSpace((Get-EnvFileValue -Path $envPath -Key 'DATABASE_URL'))) {
        $missing += 'DATABASE_URL in .env'
    }

    # An invalid PORT is a gap in its own right: the readiness check that
    # decides whether this repair actually succeeded has nothing to watch
    # without one. Absent is not a gap - that is what the default is for.
    if (-not [string]::IsNullOrWhiteSpace($RawPort) -and -not (Test-ValidTcpPort -Value $RawPort)) {
        $missing += "a valid PORT in .env (found '$RawPort')"
    }

    $nodeExecutable = Find-NodeExecutable
    if (-not $nodeExecutable) {
        $missing += 'Node.js (node.exe could not be located)'
    }

    if (-not (Test-Path -LiteralPath (Join-Path -Path $AppRoot -ChildPath 'node_modules') -PathType Container)) {
        $missing += 'the installed application dependencies (node_modules)'
    }

    if (-not (Test-Path -LiteralPath (Join-Path -Path $AppRoot -ChildPath 'build\server\index.js') -PathType Leaf)) {
        $missing += 'the built application entry point (build\server\index.js)'
    }

    foreach ($runtimeDirectory in @('logs', 'uploads')) {
        if (-not (Test-Path -LiteralPath (Join-Path -Path $AppRoot -ChildPath $runtimeDirectory) -PathType Container)) {
            $missing += "the $runtimeDirectory directory"
        }
    }

    # Resolved last, and only when everything it depends on is already
    # accounted for - this is the one check that spawns a process, and
    # running it against a deployment already known to be incomplete would
    # only add a second, redundant report of the same problem.
    $serveCliPath = $null
    if ($missing.Count -eq 0) {
        $serveCliPath = Resolve-DeltaServeCliPath -AppRoot $AppRoot -NodeExecutable $nodeExecutable -AllowMissing
        if (-not $serveCliPath) {
            $missing += 'the @react-router/serve runtime entry point'
        }
    }

    return [PSCustomObject]@{
        Satisfied      = ($missing.Count -eq 0)
        Missing        = $missing
        NodeExecutable = $nodeExecutable
        ServeCliPath   = $serveCliPath
    }
}

function Get-DeltaServiceRepairCondition {
    <#
      WHAT is wrong with the DeltaApp registration - one condition name, or
      'None'. Pure: every input is a plain value Get-DeltaRuntimeState has
      already gathered, so this costs nothing and can be evaluated on every
      menu redraw.

      Deliberately says nothing about what to DO. Whether a condition leads
      to an automatic repair, a prompt, a hand-off to the full installation
      flow, or a refusal also depends on prerequisites, on an unrelated
      process holding the port, and on operator intent - all of which
      Get-DeltaServiceRepairPlan weighs, separately, below.

      The conditions, in the order they are tested. That order is the
      design: the most fundamental problem is named first, so a service that
      is both damaged AND disabled is reported as damaged - repairing it
      re-registers it, which resolves the start type on the way past -
      rather than as a start-type question the operator would be asked
      about pointlessly.

        Missing             no registration at all. The migration case: an
                            installation from before the service existed, or
                            one whose registration was removed by hand.
        WrapperMissing      registered, but <AppRoot>\service\DeltaApp.exe
                            is gone.
        DefinitionMissing   registered, but DeltaApp.xml is gone.
        DefinitionInvalid   DeltaApp.xml exists but does not parse as a
                            service definition - a service that fails at
                            every start attempt, for a reason no restart can
                            fix.
        WrongExecutablePath registered against a different application root.
        WrongIdentity       not running as the per-service virtual account.
        Disabled            start type Disabled. The ONE condition that can
                            represent a deliberate decision, which is why it
                            is never treated as damage.
        StartTypeDrift      registered, enabled and intact, but not plain
                            Automatic - the supported startup mode. Covers
                            Manual, and equally an Automatic service that
                            still carries the delayed-autostart flag: DELTA
                            was configured that way by earlier versions of
                            this installer, so correcting it is a migration
                            every existing deployment needs.
        None                nothing about the registration needs attention.
                            Runtime problems (Broken, Starting, an unrelated
                            port owner) are NOT repair conditions: the
                            registration is correct, and the existing menu
                            already handles them.
    #>
    param(
        [bool]$ServiceInstalled,
        [AllowNull()][AllowEmptyString()][string]$ServiceStartType,
        [bool]$DelayedAutoStart,
        [bool]$ExecutablePresent,
        [bool]$DefinitionPresent,
        [bool]$DefinitionValid,
        [bool]$BinaryPathMatches,
        [AllowNull()][AllowEmptyString()][string]$ServiceAccount
    )

    if (-not $ServiceInstalled) {
        return 'Missing'
    }

    if (-not $ExecutablePresent) {
        return 'WrapperMissing'
    }

    if (-not $DefinitionPresent) {
        return 'DefinitionMissing'
    }

    if (-not $DefinitionValid) {
        return 'DefinitionInvalid'
    }

    if (-not $BinaryPathMatches) {
        return 'WrongExecutablePath'
    }

    # Compared case-insensitively: the SCM echoes back whatever casing the
    # account was configured with, and "nt service\DeltaApp" is the same
    # identity as "NT SERVICE\DeltaApp". An unreadable account is not
    # treated as wrong - only a different one is.
    if ($ServiceAccount -and ($ServiceAccount -ine $Script:DeltaServiceAccount)) {
        return 'WrongIdentity'
    }

    if ($ServiceStartType -eq 'Disabled') {
        return 'Disabled'
    }

    # Both halves matter. The StartType test catches Manual; the flag test
    # catches a service that reports Automatic while still being deferred by
    # Windows - which is exactly the shape every deployment made by an
    # earlier version of this installer is in, and is invisible in StartType.
    if ($ServiceStartType -ne 'Automatic' -or $DelayedAutoStart) {
        return 'StartTypeDrift'
    }

    return 'None'
}

function Get-DeltaServiceRepairPlan {
    <#
      WHAT TO DO about a repair condition - the single decision table behind
      setup.ps1's automatic migration/repair behaviour. Pure, so every row
      below is a test case rather than something only a live server can
      demonstrate.

      Actions:

        None      nothing to do. The normal management menu is shown exactly
                  as it always was.
        Configure the smallest possible fix: correct the startup mode, in
                  place. No re-registration, no rewritten definition, no
                  restart - so it cannot disturb a DELTA that is serving.
        Repair    convert this deployment to the service-managed model, or
                  repair a damaged registration: acquire and verify WinSW,
                  generate the definition, apply permissions, register,
                  start, and verify readiness. Explicitly NOT a
                  redeployment - no application files, dependencies,
                  configuration, or database are touched.
        Enable    a Repair whose real subject is a deliberately disabled
                  service. Always confirmed, never automatic.
        Update    hand off to the existing full installation flow, because a
                  genuine prerequisite for registering the service is
                  missing or invalid. The point of this action is that the
                  missing prerequisite gets installed by the code that
                  ALREADY owns it, rather than by a second implementation
                  living in the repair path.
        Blocked   refuse, and say why. Today: an unrelated process holds the
                  configured port, so the service could be registered but
                  could never pass the readiness check that decides whether
                  the repair worked. Reporting the conflict is the whole
                  response - nothing on this path may stop, kill, or
                  reconfigure a process this installer does not own.

      RequiresConfirmation is set wherever proceeding would interrupt
      something an operator can see: a running DELTA (any repair restarts it
      under the service), a deliberate Disabled state, or a hand-off to the
      longer full-installation flow. Everything else - converting a stopped
      deployment, repairing a registration that cannot start anyway - is
      announced and then simply done, which is the entire UX goal here.
    #>
    param(
        [Parameter(Mandatory)][string]$Condition,
        [bool]$PrerequisitesSatisfied,
        [string[]]$MissingPrerequisites = @(),
        [AllowNull()][AllowEmptyString()][string]$UnrelatedPortOwner,
        [bool]$RuntimeRunning,
        [bool]$DisabledByUninstall
    )

    if ($Condition -eq 'None') {
        return [PSCustomObject]@{
            Condition            = $Condition
            Action               = 'None'
            Headline             = $null
            Details              = @()
            RequiresConfirmation = $false
        }
    }

    # A startup-mode correction neither starts DELTA nor rewrites anything,
    # so it is decided before prerequisites and before the port: neither is
    # relevant to an sc.exe start-mode change, and making a healthy
    # installation's trivial drift depend on a full prerequisite survey
    # would be both slower and wrong.
    if ($Condition -eq 'StartTypeDrift') {
        return [PSCustomObject]@{
            Condition            = $Condition
            Action               = 'Configure'
            Headline             = 'The DELTA Windows Service is not set to start automatically with Windows.'
            Details              = @(
                'The installer will set it to Automatic, so DELTA starts as soon as',
                'Windows can start it.',
                '',
                'DELTA itself is not restarted and no files are modified.'
            )
            RequiresConfirmation = $false
        }
    }

    # Everything below ends in "start the service and verify DELTA answers",
    # so a port held by something else makes the whole operation
    # unverifiable. Registering a service that cannot bind would leave the
    # installation in a worse state than it was found in, and the owning
    # process is never a candidate for being stopped.
    if (-not [string]::IsNullOrWhiteSpace($UnrelatedPortOwner)) {
        return [PSCustomObject]@{
            Condition            = $Condition
            Action               = 'Blocked'
            Headline             = 'The DELTA Windows Service cannot be configured while another process holds the DELTA port.'
            Details              = @(
                "Port owner: $UnrelatedPortOwner",
                'This process does not belong to DELTA, so it was left running untouched.',
                'Free the port, or change PORT in the DELTA .env file, then run this installer again.'
            )
            RequiresConfirmation = $false
        }
    }

    if (-not $PrerequisitesSatisfied) {
        $details = @('Missing or invalid:', '')
        foreach ($item in $MissingPrerequisites) {
            $details += "  - $item"
        }
        $details += ''
        $details += 'The installer will run a normal DELTA update to restore these,'
        $details += 'and will then configure the Windows Service.'
        $details += ''
        $details += 'Your DELTA configuration, uploads and database are preserved.'

        return [PSCustomObject]@{
            Condition            = $Condition
            Action               = 'Update'
            Headline             = 'The DELTA Windows Service cannot be configured from the existing deployment as it stands.'
            Details              = $details
            RequiresConfirmation = $true
        }
    }

    if ($Condition -eq 'Disabled') {
        $details = if ($DisabledByUninstall) {
            @(
                'It was stopped and disabled by a previous uninstall that kept the',
                'DELTA application directory. The application, its configuration and',
                'its data were all preserved.',
                '',
                'Re-enabling it starts DELTA again from the existing deployment.'
            )
        }
        else {
            @(
                'It was set to Disabled outside this installer, which may have been',
                'deliberate. Nothing is changed unless you confirm below.',
                '',
                'Re-enabling it starts DELTA again from the existing deployment.'
            )
        }

        return [PSCustomObject]@{
            Condition            = $Condition
            Action               = 'Enable'
            Headline             = 'The DELTA Windows Service is registered but disabled.'
            Details              = $details
            # Always. A disabled service is the one state that can encode a
            # deliberate "DELTA must not run here", and an installer must not
            # overturn that silently - not even when it can see that its own
            # uninstall is what set it.
            RequiresConfirmation = $true
        }
    }

    $headline = switch ($Condition) {
        'Missing'             { 'The DELTA Windows Service is not configured.' }
        'WrapperMissing'      { 'The DELTA Windows Service is registered, but its service program is missing.' }
        'DefinitionMissing'   { 'The DELTA Windows Service is registered, but its configuration file is missing.' }
        'DefinitionInvalid'   { 'The DELTA Windows Service is registered, but its configuration file is not valid.' }
        'WrongExecutablePath' { 'The DELTA Windows Service is registered against a different application directory.' }
        'WrongIdentity'       { 'The DELTA Windows Service is not running under its own service account.' }
        default               { 'The DELTA Windows Service needs to be repaired.' }
    }

    $details = @(
        'The installer will configure the service so DELTA can start',
        'automatically with Windows.',
        '',
        'Your DELTA application, configuration, uploads and database are not modified.'
    )
    if ($RuntimeRunning) {
        $details += ''
        $details += 'DELTA is currently running and will be restarted under the service.'
    }

    return [PSCustomObject]@{
        Condition            = $Condition
        Action               = 'Repair'
        Headline             = $headline
        Details              = $details
        # Only when DELTA is actually serving: that restart is a visible
        # interruption and belongs to the operator. A stopped deployment has
        # nothing to interrupt, and asking would be exactly the pointless
        # ceremony this change exists to remove.
        RequiresConfirmation = $RuntimeRunning
    }
}

#Requires -Version 5.1
<#
.SYNOPSIS
    DELTA Windows Uninstaller - removes the prerequisites setup.ps1
    installs: Node.js, PostgreSQL, and PostGIS.

.DESCRIPTION
    The natural counterpart to setup.ps1: same architecture (Set-
    StrictMode, dot-sourced lib\DeltaInstaller.Common.ps1, Write-Step/
    Write-Detail/Write-Success/Write-PhaseBanner/Stop-Setup for every
    console message, Start-ProcessWithActivityIndicator for every
    long-running child process), applied in reverse to take the three
    prerequisites back off the machine instead of putting them on it.

    This script only ever removes what setup.ps1 itself installs -
    Node.js, PostgreSQL, and PostGIS. It does not touch the DELTA
    runtime deployment (dts_shared_binary's copy under whatever
    directory Resolve-DeltaAppRoot chose during setup.ps1), and does not
    delete the DELTA database unless the operator explicitly asks for
    the PostgreSQL data directory to be removed - see Uninstall-
    PostgreSql/Read-DeleteDataDirectoryChoice.

    Detection (Show-DetectionSummary) runs once, up front, immediately
    after the operator confirms the destructive-operation warning below,
    and its results ($Script:NodeStatus/$Script:PostgresStatus/
    $Script:PostGISStatus) are reused by every later phase rather than
    re-querying the registry/PATH/services a second time per component -
    the same "detect once, act on it" shape setup.ps1 itself uses within
    each individual phase, just hoisted one level up here since all
    three phases need to report a combined Detected/Not installed
    summary before any of them actually start removing anything.

    Uninstall order is PostGIS -> PostgreSQL -> Node.js - the exact
    reverse of setup.ps1's install order (Node.js -> PostgreSQL ->
    PostGIS), and not arbitrary: confirmed directly against a real
    installation that the PostGIS bundle's own uninstaller
    (uninstall-postgis-bundle-pg<major>x64-<version>.exe, an NSIS
    executable) lives INSIDE the PostgreSQL install directory itself,
    not somewhere independent of it - removing PostgreSQL first would
    delete the very executable PostGIS's own removal step needs to run.
    Node.js has no dependency relationship with either and is removed
    last purely to preserve the "reverse of install order" convention.

    Every component-specific uninstaller is looked up from Windows' own
    "Programs and Features" registration (Get-InstalledProgramInfo, in
    lib\DeltaInstaller.Common.ps1) rather than by deleting files or
    guessing a well-known path - the same "use the proper Windows
    mechanism" requirement setup.ps1's own installers already follow in
    the opposite direction (msiexec for the MSI-based Node.js install,
    the EDB BitRock installer's own unattended mode for PostgreSQL, the
    PostGIS bundle's own NSIS silent mode for PostGIS).

    Idempotent and safe to re-run: a component that's already absent is
    reported as "Not installed" and skipped without error, exactly like
    setup.ps1's own installers skip an already-satisfied phase. Never
    reboots automatically - if an uninstaller reports that a reboot is
    recommended (Node.js's MSI, exit code 3010), that's surfaced in the
    final summary instead of being acted on.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See setup.ps1's own header comment for the identical reasoning - this
# must be computed before lib\DeltaInstaller.Common.ps1 is dot-sourced
# below, since that file assumes $Script:ProjectRoot already exists.
$Script:ProjectRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Common.ps1')

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Uninstall logs live under their own %TEMP% subdirectory - deliberately
# not setup.ps1's own .\delta-setup (a separate, unrelated run) - so an
# uninstall log never overwrites or gets confused with an install log
# from the same machine.
$Script:WorkingDirectory = Join-Path -Path $env:TEMP -ChildPath 'delta-uninstall'

# Populated once by Show-DetectionSummary and read by every later phase -
# see this file's own header for why detection is hoisted up front
# rather than repeated per phase.
$Script:NodeStatus     = $null
$Script:PostgresStatus = $null
$Script:PostGISStatus  = $null

# Populated by each Uninstall-* phase; read by Write-UninstallSummary at
# the end. 'Not installed' is the starting assumption for each - a
# component that Show-DetectionSummary never found is never touched, so
# nothing later overwrites this default for it.
$Script:NodeJsResult        = 'Not installed'
$Script:PostgresResult      = 'Not installed'
$Script:PostGISResult       = 'Not installed'
$Script:DatabaseFilesResult = 'N/A'
$Script:RebootRecommended   = $false

# ---------------------------------------------------------------------------
# Warning and confirmation
# ---------------------------------------------------------------------------

function Confirm-UninstallIntent {
    <#
      The first thing this script does, before any detection or removal:
      makes the scope of the operation and its most serious consequence
      (PostgreSQL databases/data directories can be permanently deleted,
      depending on a later, separate choice - see Read-
      DeleteDataDirectoryChoice) explicit, and requires an affirmative
      Y before continuing. Any answer other than Y/y - including a bare
      Enter - cancels, the same "blank means decline" convention
      Reset-PostgresSuperuserPassword's own confirmation prompt already
      uses in setup.ps1's codebase, so a destructive default is never
      one accidental Enter away.
    #>
    Write-SetupBanner -Title 'DELTA Windows Uninstaller' -Subtitle 'Removes Node.js, PostgreSQL, and PostGIS'

    Write-Host 'This operation will uninstall:'
    Write-Host ''
    Write-Host '  - Node.js'
    Write-Host '  - PostgreSQL'
    Write-Host '  - PostGIS'
    Write-Host ''
    Write-Host 'This may permanently remove PostgreSQL databases and data directories.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Continue?'
    Write-Host ''
    Write-Host '[Y] Yes'
    Write-Host '[N] No'
    Write-Host ''

    $choice = Read-Host -Prompt 'Choose an option'
    if ($choice.Trim() -notin @('Y', 'y')) {
        Write-Host ''
        Write-Host 'Uninstall canceled. No changes were made.'
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

function Get-NodeJsStatus {
    <#
      "Installed" is true if either Find-NodeExecutable (the same
      functional detection setup.ps1's own Phase 1 idempotency check
      uses) or Windows' own Programs and Features registration sees it -
      either signal alone is enough to mean there's something here for
      Uninstall-NodeJs to deal with, even in the unlikely case they
      disagree (e.g. a registry entry survives a manually-deleted
      install, or vice versa).
    #>
    $nodePath    = Find-NodeExecutable
    $programInfo = Get-InstalledProgramInfo -DisplayNamePattern 'Node.js*' | Select-Object -First 1
    $version     = if ($nodePath) { Get-InstalledNodeVersion -NodeExecutablePath $nodePath } else { $null }

    return [PSCustomObject]@{
        Installed   = [bool]($nodePath -or $programInfo)
        NodePath    = $nodePath
        Version     = $version
        ProgramInfo = $programInfo
    }
}

function Get-PostgresStatus {
    <#
      Reuses Find-PostgresInstallation verbatim - the same multi-signal
      (PATH, well-known install roots, Windows service) detection every
      other script in this project already relies on instead of
      assuming PATH - combined with the Programs and Features
      registration, which is what Uninstall-PostgreSql actually needs in
      order to find the registered uninstaller.
    #>
    $existing    = Find-PostgresInstallation
    $programInfo = Get-InstalledProgramInfo -DisplayNamePattern 'PostgreSQL*' | Select-Object -First 1

    return [PSCustomObject]@{
        Installed   = [bool]($existing.Found -or $programInfo)
        Existing    = $existing
        ProgramInfo = $programInfo
    }
}

function Get-PostGISStatus {
    <#
      Detected purely via the Windows Programs and Features registration
      - deliberately NOT setup.ps1's own Test-PostGISAvailable, which
      proves PostGIS is installed by actually running CREATE EXTENSION
      against a live server. That functional check needs a running
      PostgreSQL server and a valid superuser password; neither should
      be a prerequisite just to answer "is PostGIS installed" here - by
      the time this question matters, PostgreSQL may already be stopped,
      and asking the operator for credentials purely to check for
      something about to be uninstalled anyway would be needless
      friction this script has no reason to impose. The registry entry
      the NSIS bundle installer registers is a reliable enough signal
      for this direction of the question.
    #>
    $programInfo = Get-InstalledProgramInfo -DisplayNamePattern 'PostGIS*' | Select-Object -First 1

    return [PSCustomObject]@{
        Installed   = [bool]$programInfo
        ProgramInfo = $programInfo
    }
}

function Write-DetectionLine {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][bool]$Installed
    )
    Write-Host ''
    Write-Host "${Label}:"
    Write-Host $(if ($Installed) { 'Detected.' } else { 'Not installed.' })
}

function Show-DetectionSummary {
    <#
      Runs all three detection checks exactly once and reports a
      Detected/Not installed summary for each before any removal begins
      - see this file's own header for why detection is hoisted up front
      rather than repeated inside each Uninstall-* phase. Nothing here
      fails just because a component is absent; that's the normal,
      expected case for a machine that never had all three installed in
      the first place, or that's already had this script run against it
      before.
    #>
    Write-PhaseBanner 'Detecting installed components'

    $Script:NodeStatus     = Get-NodeJsStatus
    $Script:PostgresStatus = Get-PostgresStatus
    $Script:PostGISStatus  = Get-PostGISStatus

    Write-DetectionLine -Label 'Node.js'    -Installed $Script:NodeStatus.Installed
    Write-DetectionLine -Label 'PostgreSQL' -Installed $Script:PostgresStatus.Installed
    Write-DetectionLine -Label 'PostGIS'    -Installed $Script:PostGISStatus.Installed
}

# ---------------------------------------------------------------------------
# PostGIS removal
# ---------------------------------------------------------------------------

function Uninstall-PostGIS {
    <#
      Removed first - see this file's own header for why PostGIS must be
      uninstalled before PostgreSQL itself (its uninstaller lives inside
      the PostgreSQL install directory).
    #>
    Write-PhaseBanner 'PostGIS'

    $status = $Script:PostGISStatus
    if (-not $status.Installed) {
        Write-Host ''
        Write-Host 'PostGIS:'
        Write-Host 'Not installed. Skipping.'
        return
    }

    Write-Host ''
    Write-Host 'PostGIS:'
    Write-Host 'Detected.'
    Write-Detail "Registered as: $($status.ProgramInfo.DisplayName)"

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to uninstall PostGIS. Re-run this script from an elevated PowerShell session.'
    }

    $uninstallCommand = Split-UninstallCommand -UninstallString $status.ProgramInfo.UninstallString
    if (-not (Test-Path -LiteralPath $uninstallCommand.FilePath)) {
        Stop-Setup "PostGIS is registered as installed, but its uninstaller was not found at the registered location: $($uninstallCommand.FilePath). It may need to be removed manually via Settings > Apps."
    }

    Write-Host ''
    Write-Step 'Uninstalling PostGIS (silent uninstall)...'
    Write-Detail 'This may take a few minutes.'

    # NSIS silent-uninstall convention (/S) - the identical flag
    # Install-PostGISBundle (setup.ps1) already uses for the silent
    # *install*, verified directly during that phase's own review; an
    # NSIS uninstaller generated alongside an NSIS installer accepts the
    # same flag.
    $arguments = if ($uninstallCommand.Arguments) { "$($uninstallCommand.Arguments) /S" } else { '/S' }
    $process = Start-ProcessWithActivityIndicator -FilePath $uninstallCommand.FilePath -ArgumentList $arguments -ActivityName 'Uninstalling PostGIS'

    if ($process.ExitCode -ne 0) {
        Stop-Setup "The PostGIS uninstaller returned exit code $($process.ExitCode)."
    }
    Write-Success '    Uninstaller reported success (exit code 0).'

    Write-Step 'Validating removal...'
    # A single, instant re-check here is unreliable: PostGIS's NSIS
    # uninstaller (like many NSIS installers) re-launches a detached copy
    # of itself to perform final cleanup - including deleting this very
    # registry entry - and the original process (the one just waited on
    # above) can exit and report success before that detached copy has
    # necessarily finished. Confirmed directly on a real machine: an
    # instant check here saw the entry still present, but it was gone
    # within seconds with nothing else on the system having changed in
    # between. Wait-Until (lib\DeltaInstaller.Common.ps1) tolerates that
    # normal completion lag instead of treating the registry as
    # instantaneously consistent with the process exit.
    $removed = Wait-Until -TimeoutSeconds 10 -Condition {
        -not (Get-InstalledProgramInfo -DisplayNamePattern 'PostGIS*' | Select-Object -First 1)
    }
    if (-not $removed) {
        $confirmed = Get-InstalledProgramInfo -DisplayNamePattern 'PostGIS*' | Select-Object -First 1
        Write-Host ''
        Write-Host 'PostGIS:' -ForegroundColor Red
        Write-Host 'Still detected.' -ForegroundColor Red
        Stop-Setup "PostGIS uninstall reported success, but '$($confirmed.DisplayName)' is still registered as installed after waiting for its own cleanup to finish. Remove it manually via Settings > Apps."
    }

    Write-Host ''
    Write-Success 'PostGIS successfully removed.'
    $Script:PostGISResult = 'Removed'
}

# ---------------------------------------------------------------------------
# PostgreSQL removal
# ---------------------------------------------------------------------------

function Read-DeleteDataDirectoryChoice {
    <#
      Never deletes the PostgreSQL data directory automatically -
      the operator is always asked explicitly, defaulting to "No" on any
      answer other than Y/y (the same blank-means-decline convention
      Confirm-UninstallIntent uses above): preserving data the operator
      may still need is always recoverable by asking again on a later
      run, an accidental deletion is not. Only ever called once
      PostgreSQL itself has already been successfully uninstalled and
      verified gone.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Existing)

    if (-not $Existing.InstallDir) {
        Write-Detail 'The PostgreSQL install directory could not be determined - skipping the data directory prompt. If data files remain on disk, remove them manually.'
        return
    }

    # This installer only ever installs PostgreSQL itself with <install
    # dir>\data as the data directory (see $Script:PostgresDataDirectory
    # in setup.ps1) - the same assumption Reset-PostgresSuperuserPassword
    # (lib\DeltaInstaller.Common.ps1) already makes for pg_hba.conf, and
    # equally the one layout this script can't discover automatically
    # for an instance it didn't itself install with a custom data
    # directory.
    $dataDirectory = Join-Path -Path $Existing.InstallDir -ChildPath 'data'
    if (-not (Test-Path -LiteralPath $dataDirectory)) {
        Write-Detail "No data directory found at $dataDirectory - nothing to delete."
        return
    }

    Write-Host ''
    Write-Host 'Delete the PostgreSQL data directory?'
    Write-Detail $dataDirectory
    Write-Host '(Default: No)'
    Write-Host ''
    Write-Host 'This will permanently delete every database in this PostgreSQL instance.' -ForegroundColor Yellow
    Write-Host ''
    $choice = Read-Host -Prompt 'Delete data directory? (y/N)'

    if ($choice.Trim() -notin @('Y', 'y')) {
        Write-Detail 'Data directory preserved.'
        $Script:DatabaseFilesResult = 'Preserved'
        return
    }

    Write-Step 'Deleting the PostgreSQL data directory...'
    Remove-Item -LiteralPath $dataDirectory -Recurse -Force
    Write-Success "    Deleted: $dataDirectory"
    $Script:DatabaseFilesResult = 'Deleted'
}

function Uninstall-PostgreSql {
    <#
      Stops the PostgreSQL Windows service before invoking the
      uninstaller - both to release any file locks the uninstaller (or a
      later data-directory deletion) would otherwise hit, and because a
      graceful stop is required as its own explicit step by this
      script's own requirements, not merely left to whatever the
      uninstaller itself may or may not do unprompted in unattended
      mode.

      Every uninstaller invocation goes through the registered
      UninstallString (Split-UninstallCommand, lib\DeltaInstaller.
      Common.ps1) - EDB's BitRock/InstallBuilder installer registers its
      own self-uninstaller executable (confirmed directly against a real
      installation: "C:\Program Files\PostgreSQL\<major>\uninstall-
      postgresql.exe", with no arguments already attached), which is
      then invoked here with the identical --mode unattended flags
      Install-PostgresServer (setup.ps1) already uses for the silent
      *install*. Confirmed directly, via a real uninstall on a real
      machine, that --mode unattended --unattendedmodeui none genuinely
      performs a full, non-interactive uninstall (not merely launches
      one): the installer's own persistent log, <install dir>\
      installation_summary.log (its real log - see below), recorded
      "Server/pgAdmin 4/Stack Builder/Command Line Tools uninstallation
      completed" for all four components, and postgres.exe, psql.exe,
      and the Windows service were all confirmed genuinely gone
      afterward. --debugtrace/--errortrace, by contrast, were confirmed
      to do nothing for this build - no file was ever created at the
      path they name, for either the install side or this uninstall
      side - so they're passed through mostly harmlessly (EDB's
      published reference lists them for the install path; unclear
      whether the uninstall path even recognizes them) but nothing
      downstream depends on them existing.

      What EDB's uninstaller does NOT reliably do, confirmed the same
      way: deregister its own Windows "Programs and Features" entry.
      That step only runs once the uninstaller can remove its own
      top-level install directory entirely, and in this project's own
      workflow that directory can essentially never end up empty at
      this point - PostGIS's own uninstaller (the phase immediately
      before this one) is independently confirmed to leave real files
      behind inside PostgreSQL's shared bin\/lib\/share\ directories,
      and the data\ directory is, by this script's own deliberate
      design, still present here regardless (deleting it is a separate,
      later, opt-in question - see Read-DeleteDataDirectoryChoice below,
      which runs AFTER this function already reports PostgreSQL
      removed). Confirmed this is a stable, permanent state, not a
      Wait-Until-style completion lag: the registry entry was still
      present 6+ minutes after installation_summary.log recorded
      completion, with the uninstaller's own exe already self-deleted
      (nothing left running that could still finish the job). Because of
      this, PostgreSQL removal is validated below against the same
      functional signal Find-PostgresInstallation already uses
      everywhere else in this project (psql.exe/postgres.exe locatable,
      service present) rather than the registry entry, which is not a
      reliable "is it uninstalled" signal for this installer technology
      under this project's own preserve-the-data-directory design - the
      registry entry is still reported to the operator, but as
      information, not as a validation failure.
    #>
    Write-PhaseBanner 'PostgreSQL'

    $status = $Script:PostgresStatus
    if (-not $status.Installed) {
        Write-Host ''
        Write-Host 'PostgreSQL:'
        Write-Host 'Not installed. Skipping.'
        return
    }

    $existing = $status.Existing

    Write-Host ''
    Write-Host 'PostgreSQL:'
    Write-Host 'Detected.'
    if ($existing.Version)     { Write-Detail "Version: $($existing.Version)" }
    if ($existing.ServiceName) { Write-Detail "Service: $($existing.ServiceName) ($($existing.ServiceStatus))" }

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to uninstall PostgreSQL. Re-run this script from an elevated PowerShell session.'
    }

    if (-not $status.ProgramInfo) {
        Stop-Setup "PostgreSQL appears to be installed (psql.exe found at $($existing.PsqlPath)) but no matching entry was found in Windows' Programs and Features registry, so it cannot be uninstalled automatically via its registered uninstaller. Remove it manually via Settings > Apps."
    }

    if ($existing.ServiceName -and $existing.ServiceStatus -eq 'Running') {
        Write-Host ''
        Write-Step "Stopping the PostgreSQL service ('$($existing.ServiceName)')..."
        Stop-Service -Name $existing.ServiceName -Force -ErrorAction Stop
        Write-Success '    Service stopped.'
    }

    $uninstallCommand = Split-UninstallCommand -UninstallString $status.ProgramInfo.UninstallString
    if (-not (Test-Path -LiteralPath $uninstallCommand.FilePath)) {
        Stop-Setup "PostgreSQL is registered as installed, but its uninstaller was not found at the registered location: $($uninstallCommand.FilePath). It may need to be removed manually via Settings > Apps."
    }

    $logPath        = Join-Path -Path $Script:WorkingDirectory -ChildPath 'postgres-uninstall.log'
    $errorTracePath = Join-Path -Path $Script:WorkingDirectory -ChildPath 'postgres-uninstall-errortrace.log'
    # EDB's own real log for this operation - confirmed directly, unlike
    # $logPath/$errorTracePath above, which this installer build never
    # actually writes to (see this function's own header comment).
    $realLogPath = Join-Path -Path $existing.InstallDir -ChildPath 'installation_summary.log'

    Write-Host ''
    Write-Step 'Uninstalling PostgreSQL (silent, unattended uninstall)...'
    Write-Detail "Installer's own log (if written): $realLogPath"
    Write-Detail 'This may take several minutes.'

    $argumentString = @(
        '--mode unattended'
        '--unattendedmodeui none'
        "--debugtrace `"$logPath`""
        "--errortrace `"$errorTracePath`""
    ) -join ' '
    if ($uninstallCommand.Arguments) {
        $argumentString = "$($uninstallCommand.Arguments) $argumentString"
    }

    $process = Start-ProcessWithActivityIndicator -FilePath $uninstallCommand.FilePath -ArgumentList $argumentString -ActivityName 'Uninstalling PostgreSQL'

    if ($process.ExitCode -ne 0) {
        Stop-Setup "The PostgreSQL uninstaller returned exit code $($process.ExitCode). Check $realLogPath for details, if it was written."
    }
    Write-Success '    Uninstaller reported success (exit code 0).'

    Write-Step 'Validating removal...'
    # Authoritative check: the same functional signal
    # (Find-PostgresInstallation - psql.exe/postgres.exe locatable, the
    # Windows service present) every other script in this project already
    # treats as "is PostgreSQL here", polled rather than checked once in
    # case of an ordinary completion lag (see Uninstall-PostGIS's
    # identical Wait-Until usage). Deliberately NOT gated on the Windows
    # Programs and Features registry entry - confirmed directly (see
    # this function's own header) that EDB's uninstaller only removes
    # that entry once its own install directory ends up fully empty,
    # which never happens in this project's workflow (PostGIS's known
    # leftover files, and the data\ directory this function deliberately
    # preserves until the separate prompt below) - so that entry is not
    # a reliable "still installed" signal here, and checking it as a
    # pass/fail condition would fail a genuinely successful uninstall
    # every single time, not just intermittently.
    $removed = Wait-Until -TimeoutSeconds 10 -Condition {
        -not (Find-PostgresInstallation).Found
    }
    if (-not $removed) {
        Write-Host ''
        Write-Host 'PostgreSQL:' -ForegroundColor Red
        Write-Host 'Still detected.' -ForegroundColor Red
        Stop-Setup 'PostgreSQL uninstall reported success, but psql.exe/postgres.exe can still be located. Remove it manually via Settings > Apps.'
    }

    Write-Host ''
    Write-Success 'PostgreSQL successfully removed.'
    $Script:PostgresResult = 'Removed'

    # Informational, not a failure: see this function's own header for
    # why EDB's uninstaller can legitimately leave this behind even after
    # a fully successful removal, given this project's own design.
    $residualProgramEntry = Get-InstalledProgramInfo -DisplayNamePattern 'PostgreSQL*' | Select-Object -First 1
    if ($residualProgramEntry) {
        Write-Detail "Note: Windows may still list '$($residualProgramEntry.DisplayName)' under installed apps. This is expected here - PostgreSQL's own uninstaller only removes that listing once its install directory is completely empty, and $($existing.InstallDir) still contains the data directory (and possibly other leftover files) at this point. It is not a sign that PostgreSQL itself is still functional."
    }

    Read-DeleteDataDirectoryChoice -Existing $existing
}

# ---------------------------------------------------------------------------
# Node.js removal
# ---------------------------------------------------------------------------

function Uninstall-NodeJs {
    <#
      Removed last - see this file's own header for why the uninstall
      order (PostGIS -> PostgreSQL -> Node.js) is the reverse of
      setup.ps1's install order.
    #>
    Write-PhaseBanner 'Node.js'

    $status = $Script:NodeStatus
    if (-not $status.Installed) {
        Write-Host ''
        Write-Host 'Node.js:'
        Write-Host 'Not installed. Skipping.'
        return
    }

    Write-Host ''
    Write-Host 'Node.js:'
    Write-Host 'Detected.'
    if ($status.Version) { Write-Detail "Version: v$($status.Version)" }

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to uninstall Node.js. Re-run this script from an elevated PowerShell session.'
    }

    if (-not $status.ProgramInfo) {
        Stop-Setup "Node.js appears to be installed (node.exe found at $($status.NodePath)) but no matching entry was found in Windows' Programs and Features registry, so it cannot be uninstalled automatically via msiexec. Remove it manually via Settings > Apps."
    }

    # The registered UninstallString for an MSI product is not reliably
    # an actual uninstall command - confirmed directly against a real
    # installation in this project's own environment: Node.js's own
    # UninstallString reads "MsiExec.exe /I{...}" (the INSTALL/repair
    # verb, /I, not /X) even though the product is fully installed.
    # Rather than trust whichever verb Windows happened to register, the
    # ProductCode GUID is extracted and passed to msiexec explicitly with
    # /x - the verb this project's own Install-NodeMsi (setup.ps1)
    # already knows is correct for removal.
    $productCodeMatch = [regex]::Match($status.ProgramInfo.UninstallString, '\{[0-9A-Fa-f-]+\}')
    if (-not $productCodeMatch.Success) {
        Stop-Setup "Could not determine the Node.js MSI product code from its registered uninstall string: $($status.ProgramInfo.UninstallString)"
    }
    $productCode = $productCodeMatch.Value

    $logPath = Join-Path -Path $Script:WorkingDirectory -ChildPath 'node-uninstall.log'

    Write-Host ''
    Write-Step 'Uninstalling Node.js (silent MSI uninstall)...'
    Write-Detail "Log: $logPath"
    Write-Detail 'This may take a few minutes.'

    $argumentString = "/x $productCode /qn /norestart /log `"$logPath`""
    $process = Start-ProcessWithActivityIndicator -FilePath 'msiexec.exe' -ArgumentList $argumentString -ActivityName 'Uninstalling Node.js'

    switch ($process.ExitCode) {
        0 {
            Write-Success '    Uninstall completed successfully.'
        }
        3010 {
            Write-Detail 'Uninstall completed successfully. A reboot is recommended but not required.'
            $Script:RebootRecommended = $true
        }
        default {
            Stop-Setup "The Node.js uninstaller returned exit code $($process.ExitCode). See the log for details: $logPath"
        }
    }

    Write-Step 'Refreshing environment variables for this session...'
    Update-SessionEnvironmentPath

    Write-Step 'Validating removal...'
    # Poll rather than check once - see Uninstall-PostGIS's identical
    # comment and Wait-Until's own docstring. msiexec's own transaction
    # model makes this the least likely of the three to actually lag
    # (it doesn't return until the MSI transaction, registry cleanup
    # included, is committed), but the same brief tolerance costs nothing
    # on the normal path - the condition is already true on its very
    # first check whenever nothing is lagging - so it's applied
    # consistently rather than assuming this installer technology alone
    # is exempt from the class of race PostGIS's uninstaller
    # demonstrated.
    $removed = Wait-Until -TimeoutSeconds 10 -Condition {
        -not (Find-NodeExecutable) -and
        -not (Get-InstalledProgramInfo -DisplayNamePattern 'Node.js*' | Select-Object -First 1)
    }
    if (-not $removed) {
        $confirmedNodePath = Find-NodeExecutable
        $confirmedProgram  = Get-InstalledProgramInfo -DisplayNamePattern 'Node.js*' | Select-Object -First 1
        Write-Host ''
        Write-Host 'Node.js:' -ForegroundColor Red
        Write-Host 'Still detected.' -ForegroundColor Red
        $stillThereDetail = if ($confirmedNodePath) { "node.exe is still found at $confirmedNodePath" } else { "'$($confirmedProgram.DisplayName)' is still registered as installed" }
        Stop-Setup "Node.js uninstall reported success, but $stillThereDetail after waiting for its own cleanup to finish."
    }

    Write-Host ''
    Write-Success 'Node.js successfully removed.'
    $Script:NodeJsResult = 'Removed'
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

function Write-UninstallSummary {
    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth)
    Write-Host 'DELTA Windows Uninstaller Summary'
    Write-Host ('=' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Node.js:'
    Write-Host $Script:NodeJsResult
    Write-Host ''
    Write-Host 'PostgreSQL:'
    Write-Host $Script:PostgresResult
    Write-Host ''
    Write-Host 'PostGIS:'
    Write-Host $Script:PostGISResult
    Write-Host ''
    Write-Host 'Database files:'
    Write-Host $Script:DatabaseFilesResult
    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth)

    if ($Script:RebootRecommended) {
        Write-Host ''
        Write-Host 'A reboot is recommended to complete removal, but has not been performed automatically.' -ForegroundColor Yellow
        Write-Host 'Reboot this machine at a convenient time.' -ForegroundColor Yellow
    }
}

function Initialize-Uninstall {
    if (-not (Test-Path -Path $Script:WorkingDirectory)) {
        New-Item -Path $Script:WorkingDirectory -ItemType Directory -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Orchestration
#
# Same shape as setup.ps1's own orchestration block: each phase is a
# single top-level function call, run in dependency order (see this
# file's own header for why PostGIS -> PostgreSQL -> Node.js, the
# reverse of setup.ps1's Node.js -> PostgreSQL -> PostGIS).
# ---------------------------------------------------------------------------

try {
    Confirm-UninstallIntent
    Initialize-Uninstall
    Show-DetectionSummary
    Uninstall-PostGIS
    Uninstall-PostgreSql
    Uninstall-NodeJs

    Write-UninstallSummary
    exit 0
}
catch {
    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Red
    Write-Host 'DELTA Uninstall failed.' -ForegroundColor Red
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

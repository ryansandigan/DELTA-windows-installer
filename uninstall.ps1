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

    This script's core job only ever removes what setup.ps1 itself
    installs - Node.js, PostgreSQL, and PostGIS - and does not delete
    the DELTA database unless the operator explicitly asks for the
    PostgreSQL data directory to be removed - see Uninstall-PostgreSql/
    Read-DeleteDataDirectoryChoice. It does not touch the DELTA runtime
    deployment (dts_shared_binary's copy under whatever directory
    Resolve-DeltaAppRoot chose during setup.ps1) either, UNLESS the
    operator explicitly opts into that separately, via the optional
    phase described next.

    Phase 0 (Stop-DeltaRuntimeBeforeUninstall) runs first, before any of
    that: it stops a currently-running DELTA instance - both the server
    process and its own launcher - using setup.ps1's own DELTA-runtime
    detection/stop implementation (promoted to lib\DeltaInstaller.
    Common.ps1 for this reuse). Without it, uninstalling Node.js while
    DELTA is still running can kill the server process without killing
    its launcher (Windows has no parent/child lifetime coupling), leaving
    an orphaned cmd.exe holding the DELTA runtime's redirected
    stdout/stderr log handles open indefinitely.

    Phase 0.5 (Uninstall-DeltaNginx) and Phase 0.6 (Uninstall-DeltaIis) run
    next, in that order, and are each independently optional - neither
    removes Node.js/PostgreSQL/PostGIS, and neither depends on the other.
    Both reuse the same Doctor primitives setup-nginx.ps1/setup-iis.ps1/
    doctor.ps1 already share (lib\DeltaDoctor.NGINX.ps1, lib\DeltaDoctor.
    IIS.ps1, lib\DeltaDoctor.ReverseProxy.ps1 - dot-sourced below) rather
    than reimplementing detection or lifecycle control a second time here.
    Both run BEFORE Phase 0.7 (the DELTA application directory, below) -
    deliberately, not by numbering coincidence: Uninstall-DeltaIis's own
    ownership check (Get-DeltaIisManagedWebsiteResult, lib\DeltaDoctor.
    IIS.ps1) can only attribute a candidate IIS website to THIS DELTA
    installation by cross-referencing the DELTA application directory's own
    resolved path (Get-DeltaInstallPath) against that site's PhysicalPath.
    Once that directory has been deleted, Get-DeltaInstallPath legitimately
    returns nothing, and a genuinely DELTA-owned IIS site can no longer be
    verified as such - it is reported as unattributable and left untouched
    rather than guessed at (see Uninstall-DeltaIis's own header), which is
    correct behavior for a site found in that state but the wrong outcome
    for a site an operator actually asked to have removed. Running Phase
    0.5/0.6 while the application directory - and its physical path - still
    exists is what keeps that ownership check meaningful.

    Phase 0.5 detects the DELTA-managed NGINX installation the exact way
    setup-nginx.ps1's own existing-installation check already does -
    nginx.exe present at the fixed $Script:NginxHome (C:\nginx) - and, only
    on explicit operator confirmation (default No), gracefully stops it
    (the same Send-DeltaNginxSignal 'quit' + Wait-Until sequence Stop-
    DeltaManagedNginx already uses), force-terminates any managed nginx.exe
    process still running afterward (Get-DeltaNginxManagedProcesses, matched
    by exact executable path, never by name alone), then deletes
    $Script:NginxHome entirely - binaries, generated configuration, conf.d,
    copied certificates, logs, and temp files all live under that one
    directory - and verifies it is actually gone. Never touches anything
    outside that directory.

    Phase 0.6 detects a DELTA-managed IIS website the exact way lib\
    DeltaDoctor.IIS.ps1's own Get-DeltaIisManagedWebsiteResult already does
    - a site named exactly $Script:DeltaIisSiteName ('DELTA') whose physical
    path matches the resolved DELTA installation - and, only on explicit
    operator confirmation (default No), removes exactly that website (which
    takes its own application pool association and every one of its own
    HTTP/HTTPS bindings with it), the dedicated $Script:DeltaIisAppPoolName
    application pool (but only if no other website still uses it), the SSL
    certificate behind its own HTTPS binding if one exists (but only if no
    other website's binding still references the same thumbprint), and its
    generated web.config (verified by the same "DELTA Reverse Proxy" rule-
    name marker lib\DeltaDoctor.IIS.ps1's own Doctor checks already use,
    before ever deleting it). Microsoft IIS itself, the IIS Windows Feature,
    the shared ARR/URL Rewrite installations, and every other website/
    application pool/binding/certificate on the machine are never touched -
    a name collision (a site called "DELTA" that isn't actually this
    installation's own) is reported and left completely alone, exactly as
    Get-DeltaIisManagedWebsiteResult's own CollidingSite already requires
    every other consumer of that function to handle.

    Phase 0.7 (Uninstall-DeltaApplicationDirectory) runs after both of
    those - now that any DELTA-managed reverse proxy has already either
    been removed or explicitly preserved on its own terms - and is entirely
    optional and separate from the Node.js/PostgreSQL/PostGIS removal this
    script otherwise performs: if a DELTA installation is found (Get-
    DeltaInstallPath), the operator is asked - defaulting to No - whether
    the DELTA application directory should also be removed. A No (or bare
    Enter) leaves it untouched. A Yes triggers Backup-DeltaApplicationDirectory
    first - pg_dump the database named by the DELTA .env's own DATABASE_URL
    into a .sql file inside that directory, then compress the directory
    into a timestamped ZIP under C:\DELTA-backups - and only once that
    backup has been created AND verified does this phase delete the DELTA
    application directory. Any failure in the backup (reading DATABASE_URL,
    pg_dump, ZIP creation, ZIP verification) goes through Stop-Setup, the
    same as every other unrecoverable condition in this file, which aborts
    the whole run rather than ever risking a deletion with no confirmed-good
    backup behind it.

    The ZIP intentionally omits reproducible dependency/build-cache
    artifacts ($Script:DeltaBackupExclusionPatterns - node_modules,
    .next\cache, tmp, cache) - see New-DeltaApplicationBackupArchive's own
    header for why: this backup exists to preserve user data and
    deployment configuration (the database dump, .env, uploads, logs,
    application source, package.json/package-lock.json), never to
    reproduce a `yarn install`, which is what makes those directories
    reproducible rather than backup-worthy in the first place.

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

# lib\DeltaDoctor.ReverseProxy.ps1 dot-sources both lib\DeltaDoctor.NGINX.ps1
# and lib\DeltaDoctor.IIS.ps1 - Phase 0.5/Phase 0.6 below reuse those files'
# own detection ($Script:NginxHome/$Script:NginxExePath, Get-DeltaNginxRuntimeState,
# $Script:DeltaIisSiteName/$Script:DeltaIisAppPoolName, Get-DeltaIisManagedWebsiteResult)
# and lifecycle primitives (Send-DeltaNginxSignal, Get-DeltaNginxManagedProcesses,
# Stop-DeltaIisManagedWebsite) exactly as setup-nginx.ps1/setup-iis.ps1/doctor.ps1
# already do, rather than a third, uninstall-specific reimplementation of
# either provider's own ownership rules.
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaDoctor.ReverseProxy.ps1')

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

# Populated by Uninstall-DeltaApplicationDirectory. 'N/A' is the starting
# assumption - the same convention $Script:DatabaseFilesResult above
# already uses - for a machine where Get-DeltaInstallPath never found a
# DELTA installation in the first place, so that phase has nothing to
# report.
$Script:DeltaAppDirectoryResult = 'N/A'

# The fixed backup destination root Uninstall-DeltaApplicationDirectory
# compresses the DELTA application directory into before ever deleting it
# - see that function's own header. A single, named constant rather than
# an inline literal so every reference (the confirmation prompt's own
# preview text and the actual backup step) can never drift apart into two
# different paths.
$Script:DeltaBackupsDirectory = 'C:\DELTA-backups'

# Directories excluded from the DELTA application directory backup - see
# New-DeltaApplicationBackupArchive's own header for the full rationale.
# Matched against each item's path relative to the DELTA application
# directory itself (never nested inside uploads\/logs\, which are real
# user data, not reproducible build output) - node_modules is the one
# known-real case for this deployment (React Router v7 + Express, per
# docs\01-runtime-architecture.md; no Next.js involved despite the
# .next\cache entry below), reinstallable via `yarn install` against the
# backed-up package.json/yarn.lock and never itself backup-worthy. The
# remaining three are precautionary, not currently produced by this
# application's own build - included because a generated cache/temp
# directory, if one ever does appear, is by definition reproducible and
# should never block or bloat a backup meant to preserve irreplaceable
# data.
$Script:DeltaBackupExclusionPatterns = @(
    'node_modules'
    '.next\cache'
    'tmp'
    'cache'
)

# Populated by Uninstall-DeltaNginx/Uninstall-DeltaIis. 'N/A' is the
# starting assumption, matching every other optional-phase result above -
# both functions always overwrite this with one of 'Not installed',
# 'Preserved', or 'Removed' before returning, so 'N/A' should never
# actually reach Write-UninstallSummary in practice; it exists purely as
# the same safe default convention, not a fourth reachable outcome.
$Script:NginxResult = 'N/A'
$Script:IisResult   = 'N/A'

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
# Phase 0 - DELTA runtime
# ---------------------------------------------------------------------------

function Stop-DeltaRuntimeBeforeUninstall {
    <#
      Phase 0 - runs before PostGIS/PostgreSQL/Node.js are touched at
      all. Root-cause finding: uninstalling Node.js while DELTA is still
      running can terminate the DELTA server process (node.exe) without
      terminating its own launcher (cmd.exe /c dotenv -e .env -- yarn
      start, Start-DeltaRuntimeForValidation in setup.ps1) - Windows has
      no parent/child lifetime coupling, so that launcher can survive
      indefinitely afterward, still holding the redirected stdout/stderr
      log file handles open and blocking deletion of the DELTA runtime
      directory.

      Reuses setup.ps1's own DELTA-runtime detection/stop implementation
      verbatim (Get-RunningDeltaProcesses, Get-RunningDeltaLauncherProcesses,
      Stop-RunningDeltaInstance - all promoted to lib\DeltaInstaller.
      Common.ps1 for exactly this reuse, the same way PostgreSQL/Node.js
      detection already were) rather than a second, uninstall-specific
      implementation - the identical, specific, two-signal matching
      Get-RunningDeltaProcesses already uses for the server process
      (entry-point suffix + this installation's own runtime root), plus
      the launcher's own fixed, literal invocation string for the cmd.exe
      wrapper - never a broad "any node.exe"/"any cmd.exe"/"any process
      whose command line mentions this path" sweep. Escalating to a
      forceful kill when graceful shutdown doesn't complete in time, and
      stopping the whole uninstall outright if even that fails, is
      Stop-RunningDeltaInstance's own existing behavior, reused unchanged
      here - see that function's own header.

      A no-op, idempotently, whenever no DELTA installation can be found
      on this machine at all (Get-DeltaInstallPath) - uninstalling
      PostGIS/PostgreSQL/Node.js on a machine that never had DELTA
      deployed, or where the runtime directory is simply gone, has
      nothing here to detect or stop - and equally when a DELTA
      installation IS found but nothing matching it is currently
      running, which is the normal case for a routine uninstall.
    #>
    Write-PhaseBanner 'Phase 0 - DELTA Runtime'

    $deltaInstallPath = Get-DeltaInstallPath
    if (-not $deltaInstallPath) {
        Write-Detail 'No DELTA installation found on this machine - nothing to stop.'
        return
    }

    Write-Step 'Detecting running DELTA instance...'
    $running = @(Get-RunningDeltaProcesses -DeltaRuntimeRoot $deltaInstallPath) + @(Get-RunningDeltaLauncherProcesses)
    if ($running.Count -eq 0) {
        Write-Host ''
        Write-Host 'No running DELTA instance detected.'
        return
    }

    Write-Host ''
    Write-Host 'DELTA runtime detected.'
    Write-Host ''

    Write-Step 'Stopping DELTA...'
    Write-Step 'Waiting for DELTA to exit...'
    Stop-RunningDeltaInstance -DeltaRuntimeRoot $deltaInstallPath

    Write-Host ''
    Write-Success 'DELTA runtime stopped successfully.'
}

# ---------------------------------------------------------------------------
# Phase 0.7 - DELTA application directory (optional)
# ---------------------------------------------------------------------------

function Test-DeltaBackupPathExcluded {
    <#
      Whether $RelativePath (a file or directory's path relative to the
      DELTA application directory itself, backslash-separated) falls
      under one of $ExclusionPatterns - either an exact match (the
      pattern IS this path) or a prefix match followed by a path
      separator (this path is NESTED inside a directory the pattern
      names) - never a bare substring match, which would also
      (incorrectly) exclude an unrelated sibling like "node_modules2" or
      match "cache" against something merely containing that word
      mid-name. Case-insensitive throughout, matching Windows' own
      filesystem semantics. Every pattern in $Script:DeltaBackupExclusionPatterns
      is itself relative to the DELTA application directory's own root -
      this is never applied against paths inside uploads\/logs\ turning
      up their own, unrelated "tmp"/"cache" subfolder, because
      Get-DeltaApplicationBackupFileList (below) stops descending into an
      excluded directory entirely rather than continuing to walk beneath
      it and re-testing every descendant path.
    #>
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string[]]$ExclusionPatterns
    )

    foreach ($pattern in $ExclusionPatterns) {
        if ($RelativePath -ieq $pattern) {
            return $true
        }
        if ($RelativePath.StartsWith("$pattern\", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-DeltaApplicationBackupFileList {
    <#
      Walks $RootPath itself - never Get-ChildItem -Recurse over the whole
      tree first and filtering the result afterward - specifically so an
      excluded directory (node_modules above all: routinely tens of
      thousands of files) is never even enumerated in the first place.
      Filtering after a full recursive listing would still pay that
      entire enumeration cost; pruning at the directory boundary the
      moment Test-DeltaBackupPathExcluded matches is what actually makes
      the backup faster, not merely smaller. An explicit stack, not
      recursive function calls, so this scales to a deeply nested
      node_modules-adjacent tree without PowerShell's own call-depth
      limit becoming a concern.

      Returns a [PSCustomObject]: Files (a list of [PSCustomObject]
      FullName/RelativePath - RelativePath already backslash-separated,
      relative to $RootPath) and ExcludedDirectories (every top-level
      relative path actually pruned, purely for the caller's own
      informational Write-Detail - never consulted for correctness).
    #>
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string[]]$ExclusionPatterns
    )

    # Resolved via Get-Item, not just $RootPath.TrimEnd('\') - confirmed
    # directly that the two can disagree (a short 8.3-form path resolves
    # to its long form once the filesystem provider touches it), and
    # every $item.FullName below comes from that same provider. A length
    # mismatch here silently corrupts every RelativePath computed via
    # Substring below - which does not merely mis-tag entries; it breaks
    # Test-DeltaBackupPathExcluded outright, since a relative path with a
    # stray leftover prefix never matches the exclusion patterns at all.
    # Resolving through Get-Item first guarantees this starts from
    # exactly the same normalization Get-ChildItem itself will produce
    # for every descendant.
    $normalizedRoot = (Get-Item -LiteralPath $RootPath).FullName.TrimEnd('\')
    $files = [System.Collections.Generic.List[PSCustomObject]]::new()
    $excludedDirectories = [System.Collections.Generic.List[string]]::new()

    $pendingDirectories = [System.Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($normalizedRoot)

    while ($pendingDirectories.Count -gt 0) {
        $currentDirectory = $pendingDirectories.Pop()

        foreach ($item in Get-ChildItem -LiteralPath $currentDirectory -Force) {
            $relativePath = $item.FullName.Substring($normalizedRoot.Length + 1)

            if ($item.PSIsContainer) {
                if (Test-DeltaBackupPathExcluded -RelativePath $relativePath -ExclusionPatterns $ExclusionPatterns) {
                    $excludedDirectories.Add($relativePath)
                    continue
                }
                $pendingDirectories.Push($item.FullName)
                continue
            }

            $files.Add([PSCustomObject]@{ FullName = $item.FullName; RelativePath = $relativePath })
        }
    }

    return [PSCustomObject]@{ Files = $files; ExcludedDirectories = $excludedDirectories }
}

function New-DeltaApplicationBackupArchive {
    <#
      Builds the DELTA application directory backup ZIP directly via
      System.IO.Compression.ZipFile/ZipArchive - deliberately NOT
      Compress-Archive, which has no exclude parameter at all in Windows
      PowerShell 5.1 and no way to reproduce a single top-level wrapping
      folder entry (tools\build-release.ps1's own New-ReleaseZip
      convention, matched here too) from an explicit, filtered file list
      either. This backup exists to preserve user data and deployment
      configuration - the SQL dump, .env, uploads\, logs\, application
      source, package.json/package-lock.json - never to reproduce a
      `yarn install`: node_modules (and, precautionarily, .next\cache/
      tmp/cache - see $Script:DeltaBackupExclusionPatterns's own header)
      is exactly as reinstallable from the backed-up package.json/
      yarn.lock as it was from source control in the first place, and
      skipping it is what actually makes this backup significantly
      faster and more reliable (fewer files to read, hash, and compress;
      less chance of a transient file-lock failure deep inside a
      dependency tree neither the operator nor DELTA itself will ever
      read again).

      Every file this function actually walks (Get-DeltaApplicationBackupFileList
      already pruned everything excluded) is added as its own ZIP entry
      under a single top-level "<DELTA folder name>/..." prefix - the
      same wrapping shape Compress-Archive -Path <directory> itself
      produces - via CreateEntryFromFile, so no intermediate staging copy
      of the (multi-gigabyte, in a real deployment) application directory
      is ever created on disk first. Overwrites $DestinationPath if it
      already exists, matching Compress-Archive's own -Force semantics
      this function replaces.

      Returns the number of files actually written into the archive -
      Backup-DeltaApplicationDirectory's own caller already verifies the
      resulting ZIP's entry count independently by reopening it, so this
      return value is informational (console reporting) only, never
      itself trusted as proof of success.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # Resolved the same way Get-DeltaApplicationBackupFileList resolves its
    # own -RootPath (see that function's own header for why) - so
    # $rootFolderName is derived from the identical, provider-normalized
    # path every ZIP entry name is actually built against below.
    $normalizedSource = (Get-Item -LiteralPath $SourceDirectory).FullName.TrimEnd('\')
    $rootFolderName   = Split-Path -Path $normalizedSource -Leaf

    $fileList = Get-DeltaApplicationBackupFileList -RootPath $normalizedSource -ExclusionPatterns $Script:DeltaBackupExclusionPatterns
    if ($fileList.ExcludedDirectories.Count -gt 0) {
        Write-Detail "Excluded (reproducible dependency/cache artifacts): $($fileList.ExcludedDirectories -join ', ')"
    }

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }

    $zipArchive = [System.IO.Compression.ZipFile]::Open($DestinationPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $fileList.Files) {
            $entryName = "$rootFolderName/$($file.RelativePath -replace '\\', '/')"
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
    finally {
        $zipArchive.Dispose()
    }

    return $fileList.Files.Count
}

function Backup-DeltaApplicationDirectory {
    <#
      Backs up the DELTA application directory before
      Uninstall-DeltaApplicationDirectory deletes it, and returns the
      resulting ZIP archive's path once every step below has succeeded.
      Every failure path here goes through Stop-Setup, exactly like every
      other unrecoverable condition in this file - which, via this
      script's own top-level try/catch, aborts the entire uninstall run
      rather than returning some "backup failed" signal the caller would
      have to remember to check. That is deliberate, not merely
      convenient: it is the only way to satisfy the hard requirement that
      the DELTA application directory must NEVER be deleted unless the
      backup completed successfully - Uninstall-DeltaApplicationDirectory
      below only ever reaches its own Remove-Item call after this
      function has already returned normally, so a thrown Stop-Setup
      here makes reaching that deletion code impossible, rather than
      merely unlikely.

      Steps, in order, each a hard prerequisite for the next:

        1. Read DATABASE_URL out of the DELTA install's own .env (Get-
           EnvFileValue) and parse it (ConvertFrom-DatabaseUrl) - the same
           two shared helpers setup.ps1's own credential-reuse path
           already relies on, not a second, uninstall-specific parser.
        2. Locate pg_dump.exe alongside the psql.exe Get-
           PostgresBinDirectory already resolves - PostgreSQL's own
           installer always places every client tool in that same bin\
           directory, the same assumption init_db.ps1's Install-
           DeltaDatabase already makes for createdb.exe/psql.exe.
        3. Run pg_dump, via PGPASSWORD (never on the command line, never
           logged) - identical credential handling to every other
           PostgreSQL invocation in this project (Install-DeltaDatabase
           in init_db.ps1, Test-PostGISAvailable in setup.ps1) - into a
           timestamped .sql file inside the DELTA application directory
           itself, so it is naturally swept up into the ZIP step next.
        4. Ensure the backup root ($Script:DeltaBackupsDirectory) exists.
        5. Compress the DELTA application directory - via
           New-DeltaApplicationBackupArchive (above), not Compress-Archive
           - into a timestamped ZIP under that backup root, wrapped in a
           single top-level folder entry the same way Compress-Archive
           -Path <directory> itself would (see that function's own
           header for why a direct ZipArchive call was needed instead).
           Reproducible dependency/build-cache artifacts
           ($Script:DeltaBackupExclusionPatterns - node_modules above
           all) are pruned during the walk, never added to the archive at
           all. Run AFTER the SQL dump is written, so the dump is
           included in the same pass with nothing further to reconcile.
        6. Verify the ZIP is real and non-empty by actually opening it
           (System.IO.Compression.ZipFile), not merely checking the file
           exists on disk - Compress-Archive itself already throws on a
           genuine failure, but a corrupt or truncated archive could
           still leave a file at that path.
    #>
    param([Parameter(Mandatory)][string]$DeltaInstallPath)

    $envPath = Join-Path -Path $DeltaInstallPath -ChildPath '.env'
    $databaseUrl = Get-EnvFileValue -Path $envPath -Key 'DATABASE_URL'
    if (-not $databaseUrl) {
        Stop-Setup "DATABASE_URL could not be read from $envPath. The DELTA application directory will not be deleted without a successful backup."
    }

    $connection = ConvertFrom-DatabaseUrl -DatabaseUrl $databaseUrl
    if (-not $connection) {
        Stop-Setup "DATABASE_URL in $envPath could not be parsed. The DELTA application directory will not be deleted without a successful backup."
    }

    $bin = Get-PostgresBinDirectory
    $pgDumpPath = Join-Path -Path $bin -ChildPath 'pg_dump.exe'
    if (-not (Test-Path -LiteralPath $pgDumpPath)) {
        Stop-Setup "pg_dump.exe was not found at $pgDumpPath. The DELTA application directory will not be deleted without a successful backup."
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dumpPath  = Join-Path -Path $DeltaInstallPath -ChildPath "DELTA-$timestamp.sql"

    Write-Step "Exporting the DELTA database ('$($connection.DatabaseName)') via pg_dump..."
    Write-Detail "Dump file: $dumpPath"

    $plainPassword = ConvertTo-PlainText -SecureString $connection.Password
    $previousPgPassword = $env:PGPASSWORD
    # Routine NOTICE-level messages on stderr must not become a
    # terminating error under this script's global $ErrorActionPreference
    # = 'Stop' - the identical fix, for the identical reason, as every
    # other native PostgreSQL client invocation in this project (see
    # Install-DeltaDatabase in init_db.ps1, Test-PostGISAvailable in
    # setup.ps1).
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $env:PGPASSWORD = $plainPassword
        $dumpOutput = & $pgDumpPath -h $connection.PostgresHost -p $connection.Port -U $connection.Username -d $connection.DatabaseName -f $dumpPath 2>&1
        $dumpExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($null -eq $previousPgPassword) {
            Remove-Item -Path Env:\PGPASSWORD -ErrorAction SilentlyContinue
        }
        else {
            $env:PGPASSWORD = $previousPgPassword
        }
        $plainPassword = $null
    }

    if ($dumpExitCode -ne 0 -or -not (Test-Path -LiteralPath $dumpPath -PathType Leaf)) {
        Stop-Setup "pg_dump failed (exit code $dumpExitCode): $(($dumpOutput | Out-String).Trim())`nThe DELTA application directory will not be deleted without a successful backup."
    }
    Write-Success "    Database exported: $dumpPath"

    if (-not (Test-Path -LiteralPath $Script:DeltaBackupsDirectory)) {
        Write-Step "Creating backup directory ($Script:DeltaBackupsDirectory)..."
        New-Item -Path $Script:DeltaBackupsDirectory -ItemType Directory -Force | Out-Null
    }

    $zipPath = Join-Path -Path $Script:DeltaBackupsDirectory -ChildPath "DELTA-$timestamp.zip"

    Write-Step 'Compressing the DELTA application directory...'
    Write-Detail "Archive: $zipPath"
    try {
        $archivedFileCount = New-DeltaApplicationBackupArchive -SourceDirectory $DeltaInstallPath -DestinationPath $zipPath
    }
    catch {
        Stop-Setup "Failed to create the backup archive at $zipPath`: $($_.Exception.Message)`nThe DELTA application directory will not be deleted without a successful backup."
    }
    Write-Detail "Files archived: $archivedFileCount"

    Write-Step 'Verifying backup archive...'
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
        Stop-Setup "Backup archive was not created at $zipPath. The DELTA application directory will not be deleted without a successful backup."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $entryCount = $archive.Entries.Count
        }
        finally {
            $archive.Dispose()
        }
    }
    catch {
        Stop-Setup "Backup archive at $zipPath could not be verified: $($_.Exception.Message)`nThe DELTA application directory will not be deleted without a successful backup."
    }
    if ($entryCount -eq 0) {
        Stop-Setup "Backup archive at $zipPath is empty. The DELTA application directory will not be deleted without a successful backup."
    }

    Write-Success "    Backup archive verified ($entryCount entries): $zipPath"
    return $zipPath
}

function Uninstall-DeltaApplicationDirectory {
    <#
      Optional Phase 0.7 - runs after Uninstall-DeltaNginx/Uninstall-DeltaIis
      and before Show-DetectionSummary. Deliberately NOT right after Stop-
      DeltaRuntimeBeforeUninstall (even though nothing further needs to
      happen to the runtime first - files/log handles are already released
      by that point) - see this file's own header for why: Uninstall-
      DeltaIis's own ownership check depends on the DELTA installation
      directory, and its physical path, still existing on disk, so this
      phase must run AFTER both reverse-proxy phases have already either
      removed or explicitly preserved whatever they found, never before.

      A no-op, idempotently, whenever Get-DeltaInstallPath finds nothing -
      the same "nothing here to act on" shape Stop-DeltaRuntimeBeforeUninstall
      itself already uses for exactly the same helper.

      Never deletes anything without being asked - the same explicit,
      default-No opt-in convention Read-DeleteDataDirectoryChoice below
      already uses for the PostgreSQL data directory: bare Enter, or
      anything other than Y/y, always means "preserve", never "delete".

      This phase is entirely self-contained: it touches only the DELTA
      application directory (and, via Backup-DeltaApplicationDirectory,
      the DELTA database and $Script:DeltaBackupsDirectory) and never
      Node.js, PostgreSQL itself, or PostGIS - those remain exactly
      Uninstall-PostGIS/Uninstall-PostgreSql/Uninstall-NodeJs's job,
      unaffected by whatever choice is made here.
    #>
    Write-PhaseBanner 'Phase 0.7 - DELTA Application Directory'

    $deltaInstallPath = Get-DeltaInstallPath
    if (-not $deltaInstallPath) {
        Write-Detail 'No DELTA installation found on this machine - nothing to remove.'
        return
    }

    Write-Host ''
    Write-Host 'A DELTA application directory was found:'
    Write-Detail $deltaInstallPath

    Write-Host ''
    Write-Host 'Delete the DELTA application directory?'
    Write-Host '(Default: No)'
    Write-Host ''
    Write-Host 'Before the directory is removed, the uninstaller will:'
    Write-Host ''
    Write-Host '  - Export the DELTA database using pg_dump'
    Write-Host '    (the database defined by DATABASE_URL)'
    Write-Host '  - Save the SQL dump into the DELTA application directory'
    Write-Host '  - Create the backup directory if it does not already exist:'
    Write-Host ''
    Write-Host "      $Script:DeltaBackupsDirectory"
    Write-Host ''
    Write-Host '  - Create a compressed backup of the entire DELTA application directory:'
    Write-Host ''
    Write-Host "      $Script:DeltaBackupsDirectory\DELTA-YYYYMMDD-HHMMSS.zip"
    Write-Host ''
    Write-Host '    The backup archive will include:'
    Write-Host '      - The exported database (.sql)'
    Write-Host '      - The .env file'
    Write-Host '      - Uploaded files'
    Write-Host '      - Logs'
    Write-Host '      - Configuration files'
    Write-Host '      - The application source (including package.json/package-lock.json)'
    Write-Host '      - All other files under the DELTA application directory'
    Write-Host ''
    Write-Host '    It will NOT include reproducible dependency/build-cache artifacts'
    Write-Host "    ($($Script:DeltaBackupExclusionPatterns -join ', ')) - reinstall these"
    Write-Host '    from the backed-up package.json/package-lock.json instead.'
    Write-Host ''
    Write-Host '  - Permanently delete the DELTA application directory:'
    Write-Host ''
    Write-Host "      $deltaInstallPath"
    Write-Host ''
    Write-Host 'This operation cannot be undone unless you restore the backup archive.' -ForegroundColor Yellow
    Write-Host ''
    $choice = Read-Host -Prompt 'Delete the DELTA application directory? (y/N)'

    if ($choice.Trim() -notin @('Y', 'y')) {
        Write-Host ''
        Write-Detail 'DELTA application directory preserved.'
        $Script:DeltaAppDirectoryResult = 'Preserved'
        return
    }

    Write-Host ''
    $backupArchivePath = Backup-DeltaApplicationDirectory -DeltaInstallPath $deltaInstallPath

    Write-Host ''
    Write-Step 'Deleting the DELTA application directory...'
    Remove-Item -LiteralPath $deltaInstallPath -Recurse -Force
    Write-Success "    Deleted: $deltaInstallPath"

    $Script:DeltaAppDirectoryResult = "Deleted (backup: $backupArchivePath)"
}

# ---------------------------------------------------------------------------
# Phase 0.5 - NGINX reverse proxy (optional)
# ---------------------------------------------------------------------------

function Stop-DeltaNginxForRemoval {
    <#
      The stop sequence Uninstall-DeltaNginx needs before it is safe to
      delete $Script:NginxHome - graceful first, forceful only if
      necessary, never the reverse. Deliberately NOT a call to lib\
      DeltaDoctor.NGINX.ps1's own Stop-DeltaManagedNginx: that function
      Stop-Setup's outright on a Broken runtime state or a graceful-stop
      timeout, which is exactly right for its own callers (a management
      menu action, a reverse-proxy handover that needs NGINX genuinely
      stopped before continuing) but wrong here - this requirement's own
      "if necessary, terminate any remaining nginx.exe processes" means a
      failed graceful stop should fall through to a forceful one, not
      abort the entire uninstall.

      Only ever reached once the operator has already confirmed removal -
      a graceful `-s quit` is attempted for a Running instance (any
      failure is caught and logged via Write-Detail, never allowed to
      abort this fallback sequence), then, whether that succeeded, timed
      out, or the instance was already Broken to begin with, every
      remaining nginx.exe process actually running from
      $Script:NginxExePath (Get-DeltaNginxManagedProcesses - matched by
      exact executable path, never by process name alone, so an unrelated
      NGINX instance running from a different directory is never touched)
      is force-terminated. Only aborts (Stop-Setup) if processes are still
      found running after the forceful termination attempt - Uninstall-
      DeltaNginx must never delete $Script:NginxHome while something is
      still holding its files open.
    #>

    $state = Get-DeltaNginxRuntimeState

    if ($state.State -eq 'Running') {
        Write-Step 'Stopping NGINX...'
        try {
            Send-DeltaNginxSignal -Signal 'quit'
        }
        catch {
            Write-Detail "Graceful stop failed: $($_.Exception.Message)"
        }

        Write-Step 'Waiting for NGINX to exit...'
        $stopped = Wait-Until -Condition { (Get-DeltaNginxRuntimeState).State -eq 'Stopped' } -TimeoutSeconds 15
        if ($stopped) {
            Write-Success '    NGINX stopped.'
            return
        }
    }

    # Deliberately NOT @(Get-DeltaNginxManagedProcesses) - that function
    # already returns `,@(...)` (a leading-comma-wrapped array) specifically
    # so a plain assignment always gets a real, flat array back, even for
    # 0 or 1 matches (see its own header). Wrapping that call in a SECOND
    # @() here does not flatten it back - @() around an existing array
    # variable is a no-op, but @() around a FUNCTION CALL collects
    # whatever single pipeline object the call emits, and the callee's own
    # `,@(...)` guarantees that single emitted object already IS the
    # array. The result is the array nested one level too deep: $remaining
    # became a 1-element array whose one element was itself the real
    # (0-, 1-, or N-element) array - so $remaining.Count was always 1
    # regardless of how many nginx.exe processes actually matched, the
    # `Count -eq 0` guard below never once returned early, and the
    # foreach further down bound $targetProcess to that inner array
    # object itself rather than to a Process - hence ".Id" failing with
    # "The property 'Id' cannot be found on this object" even when zero
    # (or several) processes were actually found. Confirmed directly by
    # reproducing this exact double-wrap with real spawned processes.
    $remaining = Get-DeltaNginxManagedProcesses
    if ($remaining.Count -eq 0) {
        return
    }

    Write-Step 'Terminating remaining NGINX process(es)...'
    foreach ($targetProcess in $remaining) {
        Write-Detail "PID $($targetProcess.Id)"
        Stop-Process -Id $targetProcess.Id -Force -ErrorAction SilentlyContinue
    }

    $terminated = Wait-Until -Condition { (Get-DeltaNginxManagedProcesses).Count -eq 0 } -TimeoutSeconds 10
    if (-not $terminated) {
        Stop-Setup 'NGINX process(es) could not be terminated. The NGINX installation directory will not be removed.'
    }
    Write-Success '    NGINX process(es) terminated.'
}

function Uninstall-DeltaNginx {
    <#
      Optional Phase 0.5 - runs right after Stop-DeltaRuntimeBeforeUninstall,
      and deliberately BEFORE Uninstall-DeltaApplicationDirectory (Phase
      0.7, below) rather than after it - this never touches Node.js,
      PostgreSQL, PostGIS, or the DELTA application directory itself, and
      its own choice has no bearing on any of them, but it (and Uninstall-
      DeltaIis right after it) must still run while the DELTA application
      directory itself still exists on disk - see this file's own header
      for why: Uninstall-DeltaIis's own ownership check depends on it.

      Detected the exact same way setup-nginx.ps1's own existing-
      installation check already does - nginx.exe present at the fixed,
      well-known $Script:NginxHome (C:\nginx, lib\DeltaDoctor.NGINX.ps1) -
      since that IS this installer's one DELTA-managed NGINX location; a
      no-op, reported plainly, whenever it isn't there.

      Never removes anything without being asked - the same explicit,
      default-No opt-in convention every other destructive prompt in this
      file already uses. A Yes stops NGINX (Stop-DeltaNginxForRemoval,
      above) and deletes $Script:NginxHome in its entirety - binaries,
      generated configuration, conf.d, copied certificates, logs, and temp
      files all live under that one directory, so nothing further needs
      to be enumerated separately - then verifies the directory is
      actually gone. Never touches anything outside $Script:NginxHome.
    #>
    Write-PhaseBanner 'Phase 0.5 - NGINX'

    if (-not (Test-Path -LiteralPath $Script:NginxExePath)) {
        Write-Detail 'No DELTA-managed NGINX installation found - nothing to remove.'
        $Script:NginxResult = 'Not installed'
        return
    }

    Write-Host ''
    Write-Host 'A DELTA-managed NGINX installation was found:'
    Write-Detail $Script:NginxHome

    Write-Host ''
    Write-Host 'Remove the NGINX installation?'
    Write-Host '(Default: No)'
    Write-Host ''
    Write-Host 'This will stop NGINX and permanently delete:'
    Write-Host ''
    Write-Detail $Script:NginxHome
    Write-Host ''
    Write-Host 'Including the NGINX binaries, generated configuration, conf.d, copied'
    Write-Host 'certificates, logs, and temporary files.'
    Write-Host ''
    Write-Host 'This operation cannot be undone.' -ForegroundColor Yellow
    Write-Host ''
    $choice = Read-Host -Prompt 'Remove the NGINX installation? (y/N)'

    if ($choice.Trim() -notin @('Y', 'y')) {
        Write-Host ''
        Write-Detail 'NGINX installation preserved.'
        $Script:NginxResult = 'Preserved'
        return
    }

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to remove NGINX. Re-run this script from an elevated PowerShell session.'
    }

    Write-Host ''
    Stop-DeltaNginxForRemoval

    Write-Step 'Removing the NGINX installation directory...'
    try {
        Remove-Item -LiteralPath $Script:NginxHome -Recurse -Force
    }
    catch {
        Stop-Setup "Failed to remove the NGINX installation directory ($($Script:NginxHome)): $($_.Exception.Message)"
    }

    Write-Step 'Verifying removal...'
    if (Test-Path -LiteralPath $Script:NginxHome) {
        Stop-Setup "The NGINX installation directory still exists after removal: $($Script:NginxHome)"
    }

    Write-Host ''
    Write-Success "NGINX successfully removed ($($Script:NginxHome))."
    $Script:NginxResult = 'Removed'
}

# ---------------------------------------------------------------------------
# Phase 0.6 - IIS reverse proxy (optional)
# ---------------------------------------------------------------------------

function Get-DeltaIisCertificateRemovalPlan {
    <#
      Decides whether the certificate behind the DELTA website's own HTTPS
      binding (if any) is safe to delete from Cert:\LocalMachine\My - only
      when no OTHER website's binding on the machine references the exact
      same thumbprint. Must be called BEFORE the DELTA website is removed
      (Get-DeltaIisExistingHttpsCertificateState, lib\DeltaDoctor.IIS.ps1,
      reads the binding off the live site) - Uninstall-DeltaIis captures
      this plan up front, then acts on it after the website itself is
      already gone.

      Returns $null when the site has no HTTPS binding at all (nothing to
      plan for). Otherwise a [PSCustomObject]: Thumbprint, and SafeToRemove
      - $true only once every OTHER website's own HTTPS binding has been
      checked and none of them reference this thumbprint. A certificate an
      administrator imported once and bound to two different sites (DELTA
      and something else) must never be deleted out from under that other
      site just because this one is being uninstalled.
    #>
    param([Parameter(Mandatory)][string]$SiteName)

    $httpsState = Get-DeltaIisExistingHttpsCertificateState
    if (-not $httpsState -or -not $httpsState.Thumbprint) {
        return $null
    }

    $sharedElsewhere = @(Get-Website -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $SiteName } | ForEach-Object {
        Get-WebBinding -Name $_.Name -Protocol 'https' -ErrorAction SilentlyContinue
    } | Where-Object { $_.certificateHash -eq $httpsState.Thumbprint })

    return [PSCustomObject]@{
        Thumbprint   = $httpsState.Thumbprint
        SafeToRemove = ($sharedElsewhere.Count -eq 0)
    }
}

function Uninstall-DeltaIis {
    <#
      Optional Phase 0.6 - runs after Uninstall-DeltaNginx and, like it, is
      deliberately positioned BEFORE Uninstall-DeltaApplicationDirectory
      (Phase 0.7, below) rather than after it: this phase's own ownership
      check (below) depends on the DELTA installation directory, and its
      physical path, still existing on disk - see this file's own header
      for the full rationale. Otherwise independent of Node.js/PostgreSQL/
      PostGIS, and of Uninstall-DeltaNginx's own choice.

      IMPORTANT: never uninstalls Microsoft IIS itself, never removes the
      IIS Windows Feature, and never touches the shared ARR/URL Rewrite
      installations or the machine-wide system.webServer/proxy setting
      setup-iis.ps1 enables - all of those can be shared by other websites
      entirely unrelated to DELTA. Only the specific IIS objects this
      installer itself created are ever in scope here.

      Detected via the exact same ownership rule every other consumer of
      Get-DeltaIisManagedWebsiteResult (lib\DeltaDoctor.IIS.ps1) already
      trusts: a site named exactly $Script:DeltaIisSiteName ('DELTA')
      whose PhysicalPath matches the resolved DELTA installation. A
      no-op, reported plainly, whenever: the WebAdministration module
      isn't even available (IIS was never installed, or is only partially
      present - nothing DELTA-specific could exist in that state either),
      no DELTA installation can currently be located (Get-DeltaInstallPath)
      - which, now that this phase runs BEFORE Uninstall-DeltaApplication-
      Directory in this same script, should no longer happen within a
      single run; it remains possible across separate runs (e.g. the
      application directory was already removed by hand, or by a prior
      uninstall.ps1 run before this ordering fix existed) - and a site
      cannot be safely attributed to an installation that can no longer be
      found, so it is left untouched rather than guessed at - or no site
      named $Script:DeltaIisSiteName exists at all. A site with that exact
      name that does NOT belong to this DELTA installation (CollidingSite)
      is reported and left completely alone, never touched.

      A Yes stops the website (Stop-DeltaIisManagedWebsite, lib\
      DeltaDoctor.IIS.ps1), removes it (which takes its own application
      pool association and every one of its own bindings with it in one
      step), then removes exactly three further things, each only if
      genuinely exclusive to DELTA: the dedicated application pool (only
      if no other website still references it), the SSL certificate
      behind its own former HTTPS binding if one existed (only if
      Get-DeltaIisCertificateRemovalPlan found no other website sharing
      it), and the generated web.config (only once its own "DELTA Reverse
      Proxy" rule-name marker - the same marker lib\DeltaDoctor.IIS.ps1's
      own Doctor checks already look for - confirms this installer
      actually wrote it, mirroring Get-DeltaNginxVHostSummary's own
      ownership-marker check for delta.conf in setup-nginx.ps1).
    #>
    Write-PhaseBanner 'Phase 0.6 - IIS'

    if (-not (Test-DeltaWebAdministrationModuleAvailable)) {
        Write-Detail 'Microsoft IIS is not installed on this machine - nothing to remove.'
        $Script:IisResult = 'Not installed'
        return
    }
    Import-Module WebAdministration -ErrorAction Stop

    $Script:DeltaInstallPath = Get-DeltaInstallPath
    if (-not $Script:DeltaInstallPath) {
        $orphanSite = Get-Website -Name $Script:DeltaIisSiteName -ErrorAction SilentlyContinue
        if ($orphanSite) {
            Write-Detail "An IIS website named '$($Script:DeltaIisSiteName)' exists, but the DELTA installation it would belong to could not be located (it may already have been removed) - it cannot be safely verified as DELTA-owned, so it will be left untouched."
        }
        else {
            Write-Detail 'No DELTA installation was found, and no DELTA IIS website exists - nothing to remove.'
        }
        $Script:IisResult = 'Not installed'
        return
    }

    $websiteResult = Get-DeltaIisManagedWebsiteResult
    if ($websiteResult.CollidingSite) {
        Write-Detail "A website named '$($Script:DeltaIisSiteName)' exists, but does not belong to this DELTA installation (physical path: $($websiteResult.CollidingSite.physicalPath)). It will be left untouched."
        $Script:IisResult = 'Not installed'
        return
    }

    $site = $websiteResult.ManagedSite
    if (-not $site) {
        Write-Detail 'No DELTA-managed IIS website was found - nothing to remove.'
        $Script:IisResult = 'Not installed'
        return
    }

    $siteName     = $site.name
    $appPoolName  = $site.applicationPool
    $physicalPath = $site.physicalPath
    $webConfigPath = Join-Path -Path $physicalPath -ChildPath 'web.config'

    Write-Host ''
    Write-Host 'A DELTA-managed IIS website was found:'
    Write-Detail "Website: $siteName"
    Write-Detail "Application pool: $appPoolName"
    Write-Detail "Physical path: $physicalPath"

    Write-Host ''
    Write-Host 'Remove the DELTA IIS reverse proxy configuration?'
    Write-Host '(Default: No)'
    Write-Host ''
    Write-Host 'This will remove, if present:'
    Write-Host ''
    Write-Detail "IIS website: $siteName"
    Write-Detail "Application pool: $appPoolName (only if not used by any other website)"
    Write-Detail 'HTTP/HTTPS bindings for this website'
    Write-Detail 'The SSL certificate bound to this website (only if not used by any other website)'
    Write-Detail "web.config: $webConfigPath"
    Write-Host ''
    Write-Host 'Microsoft IIS itself, the IIS Windows Feature, and the shared ARR/URL Rewrite'
    Write-Host 'installations will NOT be removed.'
    Write-Host ''
    Write-Host 'This operation cannot be undone.' -ForegroundColor Yellow
    Write-Host ''
    $choice = Read-Host -Prompt 'Remove the DELTA IIS reverse proxy configuration? (y/N)'

    if ($choice.Trim() -notin @('Y', 'y')) {
        Write-Host ''
        Write-Detail 'DELTA IIS reverse proxy configuration preserved.'
        $Script:IisResult = 'Preserved'
        return
    }

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to remove the DELTA IIS reverse proxy configuration. Re-run this script from an elevated PowerShell session.'
    }

    # Captured before the website is touched - Get-DeltaIisExistingHttpsCertificateState
    # (inside Get-DeltaIisCertificateRemovalPlan) reads the HTTPS binding off
    # the live site, which Remove-Website below deletes along with everything
    # else the site owns.
    $certificatePlan = Get-DeltaIisCertificateRemovalPlan -SiteName $siteName

    Write-Host ''
    Write-Step 'Stopping the DELTA-managed website...'
    Stop-DeltaIisManagedWebsite

    Write-Step "Removing the IIS website ('$siteName')..."
    try {
        Remove-Website -Name $siteName -ErrorAction Stop
    }
    catch {
        Stop-Setup "Failed to remove the IIS website '$siteName': $($_.Exception.Message)"
    }
    Write-Success "    Removed: $siteName"

    $appPoolPath = "IIS:\AppPools\$appPoolName"
    $appPoolStillUsed = [bool](Get-Website -ErrorAction SilentlyContinue | Where-Object { $_.applicationPool -eq $appPoolName })
    if ((Test-Path -LiteralPath $appPoolPath) -and -not $appPoolStillUsed) {
        Write-Step "Removing the application pool ('$appPoolName')..."
        try {
            Remove-WebAppPool -Name $appPoolName -ErrorAction Stop
        }
        catch {
            Stop-Setup "Failed to remove the application pool '$appPoolName': $($_.Exception.Message)"
        }
        Write-Success "    Removed: $appPoolName"
    }
    elseif ($appPoolStillUsed) {
        Write-Detail "Application pool '$appPoolName' is still used by another website - preserved."
    }

    if ($certificatePlan -and $certificatePlan.SafeToRemove) {
        Write-Step "Removing the SSL certificate (thumbprint $($certificatePlan.Thumbprint))..."
        try {
            Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($certificatePlan.Thumbprint)" -Force -ErrorAction Stop
        }
        catch {
            Stop-Setup "Failed to remove the SSL certificate (thumbprint $($certificatePlan.Thumbprint)): $($_.Exception.Message)"
        }
        Write-Success '    Certificate removed.'
    }
    elseif ($certificatePlan) {
        Write-Detail "The SSL certificate (thumbprint $($certificatePlan.Thumbprint)) is still used by another website - preserved."
    }

    if (Test-Path -LiteralPath $webConfigPath) {
        $webConfigContent = Get-Content -LiteralPath $webConfigPath -Raw
        if ($webConfigContent -match '<rule\s+name="DELTA Reverse Proxy"') {
            Write-Step 'Removing the generated web.config...'
            try {
                Remove-Item -LiteralPath $webConfigPath -Force -ErrorAction Stop
            }
            catch {
                Stop-Setup "Failed to remove web.config ($webConfigPath): $($_.Exception.Message)"
            }
            Write-Success "    Removed: $webConfigPath"
        }
        else {
            Write-Detail "web.config at $webConfigPath does not match the DELTA-generated shape - preserved."
        }
    }

    Write-Step 'Verifying removal...'
    $removed = Wait-Until -TimeoutSeconds 10 -Condition {
        -not (Get-Website -Name $siteName -ErrorAction SilentlyContinue)
    }
    if (-not $removed) {
        Stop-Setup "IIS website '$siteName' still exists after removal."
    }

    Write-Host ''
    Write-Success 'DELTA IIS reverse proxy configuration successfully removed.'
    $Script:IisResult = 'Removed'
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

function Read-DeleteLeftoverPostgresClientChoice {
    <#
      Confirmed real, not hypothetical: EDB's uninstaller can log
      "Command Line Tools uninstallation completed" while genuinely
      leaving psql.exe - plus the 2-3 runtime DLLs it loads
      (libiconv-2.dll/libintl-9.dll/libcharset-1.dll, confirmed directly
      on a real machine) - sitting in bin\, orphaned: no server, no
      service, nothing else on the machine depends on it. Only ever
      reached from Uninstall-PostgreSql after Test-PostgresServerPresent
      has already confirmed the server itself is gone, so this is never
      offered in place of reporting a genuinely failed uninstall.

      Same explicit-opt-in convention as Read-DeleteDataDirectoryChoice
      above - never deleted without being asked, defaulting to "No" on
      any answer other than Y/y.
    #>
    param([Parameter(Mandatory)][string]$PsqlPath)

    Write-Host ''
    Write-Host 'PostgreSQL:'
    Write-Detail "The command-line client (psql.exe) is still present at $PsqlPath. This is a known EDB uninstaller quirk, not a sign the server is still installed - the server itself was already confirmed removed above. It is an orphaned file only; not a running process and not security-relevant."
    Write-Host '(Default: No)'
    Write-Host ''
    $choice = Read-Host -Prompt 'Delete this leftover file? (y/N)'

    if ($choice.Trim() -notin @('Y', 'y')) {
        Write-Detail 'Leftover psql.exe preserved.'
        return
    }

    Write-Step 'Deleting leftover psql.exe...'
    Remove-Item -LiteralPath $PsqlPath -Force -ErrorAction SilentlyContinue
    Write-Success "    Deleted: $PsqlPath"
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
    # Authoritative check: the PostgreSQL *server* - the Windows service
    # and postgres.exe - via Test-PostgresServerPresent
    # (lib\DeltaInstaller.Common.ps1), not Find-PostgresInstallation's
    # Found, which is gated on psql.exe/PATH first. Confirmed directly
    # (see Test-PostgresServerPresent's own header) that EDB's uninstaller
    # can leave psql.exe - a client tool, not the server - behind even
    # after the server itself is fully and correctly removed; treating
    # that leftover as "still installed" would fail a genuinely
    # successful server uninstall. Polled rather than checked once in
    # case of an ordinary completion lag (see Uninstall-PostGIS's
    # identical Wait-Until usage). Deliberately NOT gated on the Windows
    # Programs and Features registry entry either - confirmed directly
    # (see this function's own header) that EDB's uninstaller only
    # removes that entry once its own install directory ends up fully
    # empty, which never happens in this project's workflow (PostGIS's
    # known leftover files, and the data\ directory this function
    # deliberately preserves until the separate prompt below) - so that
    # entry is not a reliable "still installed" signal here either.
    # -ServiceName scopes the service half of that check to the exact
    # installation captured in $existing above - not the bare
    # 'postgresql*' wildcard - so a second PostgreSQL version, an
    # unrelated postgresql*-named service, or a stale/stopped
    # registration belonging to something else on the box can't be
    # mistaken for this installation still being present.
    $removed = Wait-Until -TimeoutSeconds 10 -Condition {
        -not (Test-PostgresServerPresent -InstallDir $existing.InstallDir -ServiceName $existing.ServiceName)
    }
    if (-not $removed) {
        $postgresExePath  = Join-Path -Path $existing.InstallDir -ChildPath 'bin\postgres.exe'
        $exeStillPresent  = Test-Path -LiteralPath $postgresExePath
        $svcStillPresent  = $existing.ServiceName -and (Get-Service -Name $existing.ServiceName -ErrorAction SilentlyContinue)

        Write-Host ''
        Write-Host 'PostgreSQL:' -ForegroundColor Red
        Write-Host 'Still detected.' -ForegroundColor Red

        if ($svcStillPresent -and -not $exeStillPresent) {
            # postgres.exe is gone, so the server itself was removed -
            # only the service registration is lingering. Distinguish a
            # completion lag (SCM still finishing a pending deletion)
            # from a genuinely stale entry the uninstaller failed to
            # deregister, via `sc.exe qc`: EDB_ERROR_SERVICE_MARKED_FOR_DELETION
            # (1072) means Windows itself already knows this entry is on
            # its way out and will clear once the last open handle
            # closes; any other outcome means it is not scheduled for
            # removal at all.
            $null = & sc.exe qc $existing.ServiceName 2>&1
            $scExitCode = $LASTEXITCODE
            if ($scExitCode -eq 1072) {
                Stop-Setup "PostgreSQL uninstall reported success, and postgres.exe has been removed from $($existing.InstallDir)\bin, but the Windows service '$($existing.ServiceName)' is still finishing its own removal (marked for deletion, pending until the last open handle to it closes). Re-run this script in a few seconds - this is a completion lag, not a failed uninstall."
            }
            else {
                Stop-Setup "PostgreSQL uninstall reported success, and postgres.exe has been removed from $($existing.InstallDir)\bin, but the Windows service '$($existing.ServiceName)' is still registered and NOT marked for deletion (sc.exe qc exit code $scExitCode) - a stale registration the uninstaller left behind, not a completion lag. Remove it manually (as Administrator): sc.exe delete $($existing.ServiceName)"
            }
        }
        elseif ($exeStillPresent) {
            Stop-Setup "PostgreSQL uninstall reported success, but postgres.exe is still present at $postgresExePath$(if ($svcStillPresent) { " and the Windows service '$($existing.ServiceName)' is still registered" }). Remove it manually via Settings > Apps."
        }
        else {
            Stop-Setup "PostgreSQL uninstall reported success, but the Windows service '$($existing.ServiceName)' and/or postgres.exe at $postgresExePath can still be located. Remove it manually via Settings > Apps."
        }
    }

    Write-Host ''
    Write-Success 'PostgreSQL server successfully removed.'
    $Script:PostgresResult = 'Removed'

    # Informational, not a failure: see this function's own header for
    # why EDB's uninstaller can legitimately leave this behind even after
    # a fully successful removal, given this project's own design.
    $residualProgramEntry = Get-InstalledProgramInfo -DisplayNamePattern 'PostgreSQL*' | Select-Object -First 1
    if ($residualProgramEntry) {
        Write-Detail "Note: Windows may still list '$($residualProgramEntry.DisplayName)' under installed apps. This is expected here - PostgreSQL's own uninstaller only removes that listing once its install directory is completely empty, and $($existing.InstallDir) still contains the data directory (and possibly other leftover files) at this point. It is not a sign that PostgreSQL itself is still functional."
    }

    # Also informational, not a failure: re-run Find-PostgresInstallation
    # (not reused from $existing, which predates the uninstall) purely to
    # check for the leftover client binary Test-PostgresServerPresent
    # deliberately ignores above. Reported and offered as an explicit,
    # opt-in cleanup - never deleted silently - the same convention
    # Read-DeleteDataDirectoryChoice below already uses for the data
    # directory.
    $leftoverClient = Find-PostgresInstallation
    if ($leftoverClient.Found -and $leftoverClient.PsqlPath) {
        Read-DeleteLeftoverPostgresClientChoice -PsqlPath $leftoverClient.PsqlPath
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
    Write-Host 'DELTA application directory:'
    Write-Host $Script:DeltaAppDirectoryResult
    Write-Host ''
    Write-Host 'NGINX:'
    Write-Host $Script:NginxResult
    Write-Host ''
    Write-Host 'IIS:'
    Write-Host $Script:IisResult
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
    Stop-DeltaRuntimeBeforeUninstall
    Uninstall-DeltaNginx
    Uninstall-DeltaIis
    Uninstall-DeltaApplicationDirectory
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

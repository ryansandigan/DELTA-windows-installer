#Requires -Version 5.1
<#
.SYNOPSIS
    DELTA database upgrade - runs the repository's existing SQL upgrade
    chain against an existing DELTA database.

.DESCRIPTION
    Owns database-upgrade orchestration for the DELTA Windows installer -
    the canonical migration entry point setup.ps1 (Invoke-DeltaDatabaseUpgrade)
    runs unconditionally after every fresh installation and every update,
    never optionally. The upgrade logic itself - the self-selecting,
    version-driven chain of dts_database\upgrade_from_*.sql files,
    orchestrated by dts_database\upgrade_database.sql - is NOT redesigned
    here and is used completely unchanged. What this script owns is
    everything around that chain: invoking it correctly (fixing the same
    PATH-dependency and unquoted-credential gaps identified for init_db
    in the database/environment workflow assessment), and - the part
    that was hardened after an initial version of this script trusted
    the chain's own exit code as proof of success - classifying
    dts_system_info.version_no BEFORE running anything and verifying the
    result AFTER, so an unrecognized version is never reported as
    "already current" just because no `\if` branch in the chain matched
    it. See Update-DeltaDatabase below for the full state classification
    (missing database / uninitialized database / already current / needs
    migration / unrecognized version / genuine connection failure) and
    $Script:DeltaLatestSupportedSchemaVersion /
    $Script:DeltaUpgradableSchemaVersions above it for the audited
    version lists that classification is checked against - keep both in
    sync with dts_database\upgrade_database.sql's own chain and with the
    version dts_db_schema.sql seeds if either ever changes.

    Same two-mode support as init_db.ps1 (see Update-DeltaDatabase
    below, the one implementation both modes call):

      Mode 1 - invoked programmatically by setup.ps1's
      Invoke-DeltaDatabaseUpgrade, with all connection values supplied,
      including Password. Skips the interactive Y/N confirmation the
      original upgrade_database.sh/.bat prompted for, since a caller
      that already supplied a password has already made that decision.

      Mode 2 - standalone execution. Any connection value not supplied
      is prompted for, and the original scripts' "back up your database
      first" confirmation is shown - replacing the original
      upgrade_database.bat/upgrade_database.sh experience exactly.

.PARAMETER PostgresHost
    PostgreSQL server host. Defaults to localhost.

.PARAMETER Port
    PostgreSQL server port. Prompted for (default 5432 shown) if not
    supplied.

.PARAMETER Username
    PostgreSQL superuser/administrative username. Defaults to postgres.

.PARAMETER Password
    PostgreSQL superuser password, as a SecureString. Prompted for if not
    supplied - never pass this as a plaintext command-line string. Its
    presence is also what selects Mode 1 vs Mode 2 (see above).

.PARAMETER DatabaseName
    Name of the DELTA database to upgrade. Prompted for (default delta_db
    shown) if not supplied.

.PARAMETER AppRoot
    The DELTA application (runtime) root directory - where
    dts_shared_binary was deployed, i.e. where dts_database\
    upgrade_database.sql actually lives. Prompted for (default
    C:\DELTA shown) if not supplied - see Read-DeltaAppRoot
    (lib\DeltaInstaller.Common.ps1). When invoked by setup.ps1, this is
    always supplied explicitly (whatever the operator chose at
    Resolve-DeltaAppRoot), never left to prompt here.
#>
param(
    [string]$PostgresHost = 'localhost',
    [string]$Port,
    [string]$Username = 'postgres',
    [SecureString]$Password,
    [string]$DatabaseName,
    [string]$AppRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# See lib\DeltaInstaller.Common.ps1's own header for why this is a plain
# dot-sourced file and why $Script:ProjectRoot must be set before this.
# $Script:DeltaRuntimeRoot (the deployed DELTA application directory,
# separate from this installer repository) is resolved below, from
# -AppRoot if setup.ps1 supplied it, or by prompting (Read-DeltaAppRoot,
# defined in the dot-sourced file) if run standalone.
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Common.ps1')

# Mode detection, computed once at the top level, before anything else
# runs: if the caller already supplied a password, this is Mode 1 and
# the original scripts' interactive confirmation is skipped, since the
# caller already made that decision by choosing to invoke this script.
$Script:IsInteractive = -not $Password

# The authoritative record of what dts_database\upgrade_database.sql's
# \if/\gset chain actually does, audited directly against that file and
# against the version dts_db_schema.sql seeds (dts_db_schema.sql:1848,
# currently '0.2.3') - not guessed. Kept here, not in setup.ps1, so
# setup.ps1 never needs to know a single schema version number; it only
# ever calls this script and checks its exit code. If upgrade_database.sql's
# chain changes, update both of these together with the audit table in
# docs/04-database.md.
#
# $Script:DeltaLatestSupportedSchemaVersion is the version a fully
# up-to-date database - freshly initialized or fully migrated - must be
# at. $Script:DeltaUpgradableSchemaVersions are the only starting
# versions upgrade_database.sql's chain knows how to carry forward to
# that version. Anything else read from dts_system_info.version_no is
# unrecognized and must fail loudly, never be treated as "already
# current" by default.
$Script:DeltaLatestSupportedSchemaVersion = '0.2.3'
$Script:DeltaUpgradableSchemaVersions = @('0.1.1', '0.1.3', '0.2.0', '0.2.1', '0.2.2')

function Update-DeltaDatabase {
    <#
      Runs the repository's existing, unmodified SQL upgrade chain
      (dts_database\upgrade_database.sql, which self-selects and
      \ir-includes the matching upgrade_from_*.sql file based on
      dts_system_info.version_no) - the SQL itself is untouched, only
      how it's invoked from Windows changes.

      $upgradeScript is passed to psql as an absolute path. psql's \ir
      ("include relative") meta-command - which upgrade_database.sql
      uses for every upgrade_from_*.sql include - is documented to
      resolve relative to the directory of the currently executing
      script, not the process's working directory, so this works
      correctly regardless of where this script itself was invoked from
      (verified during runtime testing below, not just assumed from the
      documentation).
    #>
    param(
        [Parameter(Mandatory)][string]$PostgresHost,
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][SecureString]$Password,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    $bin     = Get-PostgresBinDirectory
    $psqlExe = Join-Path -Path $bin -ChildPath 'psql.exe'
    if (-not (Test-Path -LiteralPath $psqlExe)) {
        Stop-Setup "Required PostgreSQL executable not found: $psqlExe"
    }

    $upgradeScript = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'dts_database\upgrade_database.sql'
    if (-not (Test-Path -LiteralPath $upgradeScript)) {
        Stop-Setup "Upgrade script not found: $upgradeScript"
    }

    Write-Detail "Host: $PostgresHost"
    Write-Detail "Port: $Port"
    Write-Detail "Username: $Username"
    Write-Detail "Database: $DatabaseName"

    $plainPassword      = ConvertTo-PlainText -SecureString $Password
    $previousPgPassword = $env:PGPASSWORD
    $previousEap        = $ErrorActionPreference
    $versionBefore      = $null
    $versionAfter       = $null
    $outcomeMessage     = $null
    try {
        # Same reasoning as Test-PostGISAvailable/init_db.ps1: psql
        # writes routine NOTICE-level output to stderr, which 2>&1 under
        # a global $ErrorActionPreference = 'Stop' would otherwise turn
        # into a terminating error.
        $ErrorActionPreference = 'Continue'
        $env:PGPASSWORD = $plainPassword

        # State check #1 and #2 (database missing / database not yet
        # initialized) and, implicitly, #6 (a genuine connection or
        # permission failure) - all resolved by one query, before
        # version_no is ever trusted. to_regclass() returns NULL rather
        # than erroring when the table is simply absent, so a successful
        # connection that finds no dts_system_info table is distinguished
        # from a connection that couldn't be made at all. If the
        # connection itself fails - because $DatabaseName doesn't exist,
        # or for any other reason (auth, network, permissions) - this
        # query fails first, before any table-existence answer is even
        # possible, and Get-PostgresConnectionFailureReason (shared with
        # Test-PostgresCredentials elsewhere in this installer) is reused
        # to tell "database does not exist" apart from every other
        # connection failure, off the same psql stderr text it already
        # knows how to parse.
        Write-Step 'Checking database state...'
        $stateOutput = & $psqlExe -h $PostgresHost -p $Port -U $Username -d $DatabaseName --tuples-only --no-align -c "SELECT (to_regclass('public.dts_system_info') IS NOT NULL) AS tbl_exists;" 2>&1
        if ($LASTEXITCODE -ne 0) {
            $reason = Get-PostgresConnectionFailureReason -ErrorMessage (($stateOutput | Out-String).Trim())
            if ($reason -eq 'Database does not exist.') {
                Stop-Setup "Database '$DatabaseName' does not exist. Run init_db.ps1 to create and initialize it before upgrading."
            }
            Stop-Setup "Could not connect to database '$DatabaseName' to check its schema state: $reason"
        }
        $tableExists = ($stateOutput | Select-Object -First 1).Trim()
        if ($tableExists -ne 't') {
            Stop-Setup "Database '$DatabaseName' exists but has not been initialized (the dts_system_info table was not found). Run init_db.ps1 to initialize it before upgrading."
        }

        Write-Step 'Checking current schema version...'
        $beforeOutput = & $psqlExe -h $PostgresHost -p $Port -U $Username -d $DatabaseName --tuples-only --no-align -c 'SELECT version_no FROM dts_system_info;' 2>&1
        $versionBefore = $beforeOutput | Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($versionBefore)) {
            Stop-Setup "Could not read the current schema version from dts_system_info: $(($beforeOutput | Out-String).Trim())"
        }
        $versionBefore = $versionBefore.Trim()
        Write-Detail "Current version: $versionBefore"

        # State check #3 vs #4 vs #5: classify $versionBefore against the
        # audited version lists above BEFORE running anything. This is
        # the fix for the failure mode this hardening exists to close -
        # the old code ran upgrade_database.sql unconditionally and
        # reported success off nothing but psql's exit code, so a
        # database at an unrecognized version (every \if branch false,
        # zero rows changed, exit 0) was indistinguishable from one that
        # was genuinely already current. Never rely on the absence of a
        # matching \if branch to mean "current" - only an explicit match
        # against $Script:DeltaLatestSupportedSchemaVersion means that.
        if ($versionBefore -eq $Script:DeltaLatestSupportedSchemaVersion) {
            $versionAfter = $versionBefore
            $outcomeMessage = 'Database already current.'
        }
        elseif ($Script:DeltaUpgradableSchemaVersions -contains $versionBefore) {
            Write-Step 'Running database upgrade...'
            $upgradeOutput = & $psqlExe -h $PostgresHost -p $Port -U $Username -d $DatabaseName --set ON_ERROR_STOP=on -f $upgradeScript 2>&1
            if ($LASTEXITCODE -ne 0) {
                Stop-Setup "Database upgrade failed: $(($upgradeOutput | Out-String).Trim())"
            }

            Write-Step 'Validating upgrade...'
            $afterOutput = & $psqlExe -h $PostgresHost -p $Port -U $Username -d $DatabaseName --tuples-only --no-align -c 'SELECT version_no FROM dts_system_info;' 2>&1
            $versionAfter = $afterOutput | Select-Object -First 1
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($versionAfter)) {
                Stop-Setup "Post-upgrade validation failed: could not read dts_system_info.version_no after upgrade. $(($afterOutput | Out-String).Trim())"
            }
            $versionAfter = $versionAfter.Trim()

            # Positive verification (State result check, required
            # regardless of the chain's own exit code): the migration
            # chain exiting 0 only means no SQL statement errored, not
            # that the version actually landed on the declared latest
            # supported version. A chain that's missing a link for some
            # in-between version would otherwise silently leave the
            # database on an intermediate version while still reporting
            # success.
            if ($versionAfter -ne $Script:DeltaLatestSupportedSchemaVersion) {
                Stop-Setup "Database upgrade ran but the resulting schema version ('$versionAfter') does not match the expected latest supported version ('$($Script:DeltaLatestSupportedSchemaVersion)'). The migration chain may be incomplete for this starting version. Do not treat this as a successful upgrade - investigate before continuing."
            }
            $outcomeMessage = 'Database migrated successfully.'
        }
        else {
            Stop-Setup @"
Database '$DatabaseName' is at schema version '$versionBefore', which this installer does not recognize.

Versions this installer knows how to upgrade from: $($Script:DeltaUpgradableSchemaVersions -join ', ')
Latest supported version: $($Script:DeltaLatestSupportedSchemaVersion)

Refusing to guess at how to handle an unrecognized schema version. Verify the database's actual state before continuing.
"@
        }
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

    Write-Host ''
    Write-Success $outcomeMessage
    Write-Host ''
    Write-Host 'Version before:'
    Write-Host $versionBefore
    Write-Host ''
    Write-Host 'Version after:'
    Write-Host $versionAfter
    Write-Host ''
    Write-Host 'Database migration check completed.'
    Write-Host "Final schema version: $versionAfter"
}

try {
    Write-PhaseBanner 'DELTA Database Upgrade'

    if ($Script:IsInteractive) {
        Write-Host 'WARNING: You are about to upgrade your DELTA database.'
        Write-Host 'Make sure to BACK UP your database before continuing.'
        Write-Host ''
        $confirm = Read-Host -Prompt 'Do you want to continue running the database upgrade? (Y/N)'
        if ($confirm -notin @('Y', 'y')) {
            Write-Host 'Upgrade canceled by user.'
            exit 1
        }
        Write-Host ''
    }

    if ([string]::IsNullOrWhiteSpace($AppRoot)) {
        $AppRoot = Read-DeltaAppRoot
    }
    $Script:DeltaRuntimeRoot = $AppRoot.TrimEnd('\')

    if ([string]::IsNullOrWhiteSpace($Port)) {
        $enteredPort = Read-Host -Prompt 'Enter PostgreSQL port [5432]'
        $Port = if ([string]::IsNullOrWhiteSpace($enteredPort)) { '5432' } else { $enteredPort.Trim() }
    }

    if (-not $Password) {
        $Password = Read-PostgresSuperuserPassword
    }

    if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
        $enteredName = Read-Host -Prompt 'Enter the DELTA database name [delta_db]'
        $DatabaseName = if ([string]::IsNullOrWhiteSpace($enteredName)) { 'delta_db' } else { $enteredName.Trim() }
    }

    Update-DeltaDatabase -PostgresHost $PostgresHost -Port $Port -Username $Username -Password $Password -DatabaseName $DatabaseName

    exit 0
}
catch {
    Write-Host ''
    Write-Host 'DELTA database upgrade failed.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

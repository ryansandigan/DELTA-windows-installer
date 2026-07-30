#Requires -Version 5.1
<#
.SYNOPSIS
    DELTA database upgrade - runs the repository's existing SQL upgrade
    chain against an existing DELTA database.

.DESCRIPTION
    Owns database-upgrade orchestration for the DELTA Windows installer.
    The upgrade logic itself - the self-selecting, version-driven chain
    of dts_database\upgrade_from_*.sql files, orchestrated by
    dts_database\upgrade_database.sql - is NOT redesigned here and is
    used completely unchanged. This script only replaces the .bat/.sh
    wrapper around `psql -f dts_database/upgrade_database.sql`, fixing
    the same PATH-dependency and unquoted-credential gaps identified for
    init_db in the database/environment workflow assessment.

    Same two-mode support as init_db.ps1 (see Update-DeltaDatabase
    below, the one implementation both modes call):

      Mode 1 - invoked programmatically (e.g. a future setup.ps1 upgrade
      flow) with all connection values supplied, including Password.
      Skips the interactive Y/N confirmation the original
      upgrade_database.sh/.bat prompted for, since a caller that already
      supplied a password has already made that decision.

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
    Name of the DELTA database to upgrade. Prompted for (default dts_db
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
    try {
        # Same reasoning as Test-PostGISAvailable/init_db.ps1: psql
        # writes routine NOTICE-level output to stderr, which 2>&1 under
        # a global $ErrorActionPreference = 'Stop' would otherwise turn
        # into a terminating error.
        $ErrorActionPreference = 'Continue'
        $env:PGPASSWORD = $plainPassword

        Write-Step 'Checking current schema version...'
        $beforeOutput = & $psqlExe -h $PostgresHost -p $Port -U $Username -d $DatabaseName --tuples-only --no-align -c 'SELECT version_no FROM dts_system_info;' 2>&1
        $versionBefore = $beforeOutput | Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($versionBefore)) {
            Stop-Setup "Could not read the current schema version from dts_system_info: $(($beforeOutput | Out-String).Trim())"
        }
        Write-Detail "Current version: $($versionBefore.Trim())"

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
    Write-Success 'DELTA database upgrade complete.'
    Write-Host ''
    Write-Host 'Version before:'
    Write-Host $versionBefore.Trim()
    Write-Host ''
    Write-Host 'Version after:'
    Write-Host $versionAfter.Trim()
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
        $enteredName = Read-Host -Prompt 'Enter the DELTA database name [dts_db]'
        $DatabaseName = if ([string]::IsNullOrWhiteSpace($enteredName)) { 'dts_db' } else { $enteredName.Trim() }
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

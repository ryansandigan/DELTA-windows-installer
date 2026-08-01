#Requires -Version 5.1
<#
.SYNOPSIS
    DELTA database initialization - creates the DELTA database and
    restores its schema against an existing PostgreSQL + PostGIS
    installation.

.DESCRIPTION
    Owns all database-initialization business logic for the DELTA Windows
    installer (see Initialize-DeltaDatabase below). Runs in one of two
    modes, both calling that same function - never two copies of the
    logic:

      Mode 1 - invoked by setup.ps1 (Complete-DatabaseSetup), which
      already knows the PostgreSQL host/port/username/password from
      Phase 2A. Supply them all as parameters and this script prompts
      for nothing.

      Mode 2 - standalone execution. Any connection value not supplied
      on the command line is prompted for interactively, replacing the
      original init_db.bat/init_db.sh experience.

    Unlike the original init_db.bat, this script never depends on PATH to
    find createdb.exe/psql.exe. The database/environment workflow
    assessment verified directly - in a genuinely clean shell, not
    inferred - that PostgreSQL's own installer never adds its bin
    directory to PATH (neither Machine nor User scope), which is exactly
    why the original init_db.bat/.sh cannot run on a freshly provisioned
    machine. This script resolves the executable path via
    Get-PostgresBinDirectory (lib\DeltaInstaller.Common.ps1) instead,
    which reuses Find-PostgresInstallation's own multi-signal detection.

    Also unlike the original scripts, this one performs real post-import
    validation: after restoring the schema, it queries
    dts_system_info.version_no and runs SELECT PostGIS_Full_Version() -
    not just checking that psql exited 0.

    Immediately after that validation succeeds, Set-DeltaAdministratorPassword
    prompts for a password for the DELTA administrator account the schema
    itself seeds (username/email are fixed, seeded values, shown but never
    prompted for) and UPDATEs it onto that existing row - never INSERTs a
    new one - via pgcrypto's crypt()/gen_salt('bf', 10), then verifies
    exactly one row was affected before continuing.

.PARAMETER PostgresHost
    PostgreSQL server host. Defaults to localhost.

.PARAMETER Port
    PostgreSQL server port. Prompted for (default 5432 shown) if not
    supplied.

.PARAMETER Username
    PostgreSQL superuser/administrative username. Defaults to postgres.

.PARAMETER Password
    PostgreSQL superuser password, as a SecureString. Prompted for if not
    supplied - never pass this as a plaintext command-line string.

.PARAMETER DatabaseName
    Name of the DELTA database to create. Prompted for (default delta_db
    shown) if not supplied.

.PARAMETER AppRoot
    The DELTA application (runtime) root directory - where
    dts_shared_binary was deployed, i.e. where dts_database\
    dts_db_schema.sql actually lives. Prompted for (default
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

function Initialize-DeltaDatabase {
    <#
      The actual database-initialization logic - the one implementation
      shared by both execution modes. The only difference between modes
      is how the parameters got their values (supplied directly vs.
      prompted for, in the try block below); this function never knows
      or cares which happened.

      Ends by calling Set-DeltaAdministratorPassword once schema restore
      and validation have both succeeded - configuring the DELTA
      administrator account is treated as part of "database
      initialization" as a whole, not a separate phase an operator could
      skip past, since the account only gets (re-)seeded when the schema
      itself is freshly restored (never during an upgrade).
    #>
    param(
        [Parameter(Mandatory)][string]$PostgresHost,
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][SecureString]$Password,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    $bin         = Get-PostgresBinDirectory
    $createdbExe = Join-Path -Path $bin -ChildPath 'createdb.exe'
    $psqlExe     = Join-Path -Path $bin -ChildPath 'psql.exe'
    foreach ($exe in @($createdbExe, $psqlExe)) {
        if (-not (Test-Path -LiteralPath $exe)) {
            Stop-Setup "Required PostgreSQL executable not found: $exe"
        }
    }

    $schemaFile = Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'dts_database\dts_db_schema.sql'
    if (-not (Test-Path -LiteralPath $schemaFile)) {
        Stop-Setup "DELTA schema file not found: $schemaFile"
    }

    Write-Detail "Host: $PostgresHost"
    Write-Detail "Port: $Port"
    Write-Detail "Username: $Username"
    Write-Detail "Database: $DatabaseName"

    $plainPassword       = ConvertTo-PlainText -SecureString $Password
    $previousPgPassword  = $env:PGPASSWORD
    $previousEap         = $ErrorActionPreference
    $versionLine         = $null
    try {
        # psql/createdb write routine NOTICE-level messages to stderr
        # (e.g. a duplicate-database notice on a re-run). Under this
        # script's global $ErrorActionPreference = 'Stop', capturing
        # native stderr via 2>&1 would otherwise turn that into a
        # terminating error - see Test-PostGISAvailable in
        # DeltaInstaller.Common.ps1 for the same fix applied there.
        $ErrorActionPreference = 'Continue'
        $env:PGPASSWORD = $plainPassword

        Write-Step "Creating database '$DatabaseName'..."
        $createOutput = & $createdbExe -h $PostgresHost -p $Port -U $Username $DatabaseName 2>&1
        if ($LASTEXITCODE -ne 0) {
            Stop-Setup "Failed to create database '$DatabaseName': $(($createOutput | Out-String).Trim())"
        }
        Write-Success "    Database '$DatabaseName' created."

        Write-Step 'Restoring DELTA schema...'
        $restoreOutput = & $psqlExe -h $PostgresHost -p $Port -U $Username -d $DatabaseName --set ON_ERROR_STOP=on -f $schemaFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            Stop-Setup "Failed to restore schema: $(($restoreOutput | Out-String).Trim())"
        }
        Write-Success '    Schema restored.'

        Write-Step 'Validating installation...'
        $versionOutput = & $psqlExe -h $PostgresHost -p $Port -U $Username -d $DatabaseName --tuples-only --no-align -c 'SELECT version_no FROM dts_system_info;' 2>&1
        $versionLine = $versionOutput | Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($versionLine)) {
            Stop-Setup "Post-import validation failed: could not read dts_system_info.version_no. $(($versionOutput | Out-String).Trim())"
        }

        $postgisOutput = & $psqlExe -h $PostgresHost -p $Port -U $Username -d $DatabaseName --tuples-only --no-align -c 'SELECT PostGIS_Full_Version();' 2>&1
        if ($LASTEXITCODE -ne 0 -or -not ($postgisOutput -match 'POSTGIS=')) {
            Stop-Setup "Post-import validation failed: PostGIS is not usable in the new database. $(($postgisOutput | Out-String).Trim())"
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
    Write-Success 'DELTA database initialized successfully.'
    Write-Host ''
    Write-Host 'Database:'
    Write-Host $DatabaseName
    Write-Host ''
    Write-Host 'Schema version:'
    Write-Host $versionLine.Trim()

    Set-DeltaAdministratorPassword -PostgresHost $PostgresHost -Port $Port -Username $Username -Password $Password -DatabaseName $DatabaseName
}

function Read-DeltaAdministratorPassword {
    <#
      Prompts twice for the DELTA administrator account's password and
      requires a match - the same validated double-entry shape as
      Read-PostgresSuperuserPassword (lib\DeltaInstaller.Common.ps1), but
      kept as its own small copy rather than shared: this is an
      unrelated credential (the DELTA application's seeded admin
      account, not the PostgreSQL superuser), and duplicating this
      already-simple loop once is lower-risk than reworking the
      already-tested Postgres password logic just to parameterize its
      prompt text.
    #>
    while ($true) {
        $first  = Read-Host -Prompt 'Enter the DELTA administrator password' -AsSecureString
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

function Set-DeltaAdministratorPassword {
    <#
      Configures the password on the DELTA administrator account the
      schema itself already seeds (dts_db_schema.sql:2669) - deliberately
      an UPDATE against the existing seeded row, never an INSERT of a
      new one: idempotent (safe to re-run), avoids a duplicate/unique
      violation against the row the schema already created, and needs no
      fixed UUID of its own. Creating the account is the schema's
      responsibility; this only ever configures the deployment-specific
      password on the one the schema already created.

      Username and email are fixed, seeded values (dts_db_schema.sql
      line 2669: first_name/last_name = 'admin', email =
      'admin@admin.com') - displayed for the operator's information
      only, never prompted for.

      IMPORTANT: public.super_admin_users has no "username" column at
      all - only id/first_name/last_name/email/password (confirmed
      directly against dts_db_schema.sql:1011-1017). The row is
      identified by `email` instead, which the schema also gives a
      UNIQUE constraint (super_admin_users_email_unique,
      dts_db_schema.sql:3031-3032) - guaranteeing the UPDATE below can
      only ever match zero or one row, which is exactly what the
      row-count validation afterward checks for.

      Uses pgcrypto's crypt()/gen_salt('bf', 10) - already available
      immediately after schema restore, since dts_db_schema.sql itself
      creates the pgcrypto extension (line 23) - producing the same
      bcrypt hash format already seeded (a `$2a$10$...` hash), so this
      changes what the stored hash is, not how the application verifies
      it.

      The new password is substituted into the SQL as :'password' - the
      QUOTED psql-variable form, which psql escapes as a proper SQL
      string literal itself - never the bare :password form, which
      would substitute unescaped text directly into the query and break
      on a password containing a single quote. Two things were verified
      directly (not assumed) before landing on this exact mechanism:

        - psql only expands :'var' / :var substitutions when the SQL
          comes from a script (-f, or stdin) - NOT from a -c command
          string, which fails with "syntax error at or near ':'". So the
          UPDATE has to be written to a temporary script file and run
          via -f, never -c.
        - Passing the password itself via -v "password=$value" breaks
          silently (empty output, no error) the moment the value
          contains a literal double-quote character - a real, reproduced
          Windows PowerShell 5.1 / native-argv-escaping limitation, not
          a psql issue. Passing it instead via an environment variable
          and importing it with psql's own \getenv meta-command sidesteps
          command-line argv escaping entirely (env vars aren't parsed by
          CommandLineToArgvW-style rules at all) - the same reasoning
          that already justifies using $env:PGPASSWORD instead of a
          -password flag elsewhere in this project. Verified round-trip
          correct against passwords containing single quotes, double
          quotes, backslashes, and common punctuation together.

      $env:PGPASSWORD (the *connection* password) and the temporary
      DELTA_ADMIN_NEW_PASSWORD env var (the *new admin* password) are
      two independent values for two independent credentials - never
      conflated - both cleared in the finally block whether this
      succeeds or fails.
    #>
    param(
        [Parameter(Mandatory)][string]$PostgresHost,
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][SecureString]$Password,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    Write-PhaseBanner 'DELTA Administrator Account'

    $adminEmail = 'admin@admin.com'

    Write-Host 'Administrator username:'
    Write-Host 'admin'
    Write-Host ''
    Write-Host 'Administrator email:'
    Write-Host $adminEmail
    Write-Host ''

    $adminPassword = Read-DeltaAdministratorPassword

    Write-Step 'Configuring DELTA administrator account...'

    $bin     = Get-PostgresBinDirectory
    $psqlExe = Join-Path -Path $bin -ChildPath 'psql.exe'
    if (-not (Test-Path -LiteralPath $psqlExe)) {
        Stop-Setup "Required PostgreSQL executable not found: $psqlExe"
    }

    $escapedEmail = $adminEmail.Replace("'", "''")
    $updateSqlPath = Join-Path -Path $env:TEMP -ChildPath "delta-admin-update-$([guid]::NewGuid().ToString('N')).sql"
    Set-Content -LiteralPath $updateSqlPath -Encoding utf8 -Value @(
        '\getenv password DELTA_ADMIN_NEW_PASSWORD'
        "UPDATE public.super_admin_users SET password = crypt(:'password', gen_salt('bf', 10)) WHERE email = '$escapedEmail' RETURNING email;"
    )

    $plainConnectionPassword = ConvertTo-PlainText -SecureString $Password
    $plainAdminPassword      = ConvertTo-PlainText -SecureString $adminPassword
    $previousPgPassword      = $env:PGPASSWORD
    $previousAdminPwEnv      = $env:DELTA_ADMIN_NEW_PASSWORD
    $previousEap             = $ErrorActionPreference
    $output                  = $null
    $exitCode                = $null
    try {
        # Same reasoning as Initialize-DeltaDatabase above: psql's
        # routine stderr output would otherwise become a terminating
        # error under this script's global $ErrorActionPreference = 'Stop'.
        $ErrorActionPreference = 'Continue'
        $env:PGPASSWORD = $plainConnectionPassword
        $env:DELTA_ADMIN_NEW_PASSWORD = $plainAdminPassword

        $output = & $psqlExe -h $PostgresHost -p $Port -U $Username -d $DatabaseName `
            --set ON_ERROR_STOP=on --tuples-only --no-align --quiet `
            -f $updateSqlPath 2>&1
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
        if ($null -eq $previousAdminPwEnv) {
            Remove-Item -Path Env:\DELTA_ADMIN_NEW_PASSWORD -ErrorAction SilentlyContinue
        }
        else {
            $env:DELTA_ADMIN_NEW_PASSWORD = $previousAdminPwEnv
        }
        $plainConnectionPassword = $null
        $plainAdminPassword      = $null
        Remove-Item -LiteralPath $updateSqlPath -Force -ErrorAction SilentlyContinue
    }

    if ($exitCode -ne 0) {
        Stop-Setup "Failed to configure the DELTA administrator account: $(($output | Out-String).Trim())"
    }

    $updatedRows = @($output | Where-Object { $_.Trim() })
    if ($updatedRows.Count -eq 0) {
        Stop-Setup @'
Unable to locate the default DELTA administrator account.

The restored database does not contain the expected seeded administrator.
'@
    }
    if ($updatedRows.Count -gt 1) {
        Stop-Setup "Expected exactly one DELTA administrator account to update, but $($updatedRows.Count) rows matched email '$adminEmail'. Refusing to continue with an ambiguous match."
    }

    Write-Success '    Administrator account configured successfully.'
}

try {
    Write-PhaseBanner 'DELTA Database Initialization'

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

    Initialize-DeltaDatabase -PostgresHost $PostgresHost -Port $Port -Username $Username -Password $Password -DatabaseName $DatabaseName

    exit 0
}
catch {
    Write-Host ''
    Write-Host 'DELTA database initialization failed.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

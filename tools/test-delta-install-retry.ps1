#Requires -Version 5.1
<#
.SYNOPSIS
    Validates Invoke-DeltaComponentInstallWithRetry's bounded retry
    mechanics and Test-PostgresFreshInstallCleanupSafe's cleanup safety
    rules.

.DESCRIPTION
    Invoke-DeltaComponentInstallWithRetry (lib\DeltaInstaller.Common.ps1)
    is the shared orchestration behind setup.ps1's Node.js / PostgreSQL /
    PostGIS installation retry handling: at most 2 attempts, validation
    consulted before ever retrying, component-specific cleanup only
    between a failed attempt and its single retry, Stop-Setup once every
    attempt is exhausted. Test-PostgresFreshInstallCleanupSafe is the
    pure predicate deciding whether Install-PostgreSql's retry cleanup
    may delete anything at all.

    This script exercises both directly - no real installers, no
    filesystem or service state - by driving the retry loop with
    instrumented scriptblocks and asserting on attempt counts, cleanup
    invocations, and the final failure message (including that it never
    contains a password). Covers the required scenarios:

      1. Installer succeeds on attempt 1 -> no retry, no cleanup.
      2. Installer fails but component validation succeeds -> no retry.
      3. Fresh install fails, cleanup runs, attempt 2 succeeds.
      4. Both attempts fail -> terminates via Stop-Setup, exactly 2
         attempts, message names the attempt count and log hint.
      5. Alternate success exit codes (MSI 3010) honored.
      6. Second attempt fails but validation then succeeds -> continue.
      7. Failure diagnostics contain no secrets.
      Plus the Test-PostgresFreshInstallCleanupSafe decision table
      (pre-existing component -> never cleaned; current-attempt partial
      artifacts only -> cleanable).

    Exits 0 if every case passes, 1 otherwise - safe to wire into CI or
    run locally after touching the retry logic, same contract as
    tools\test-delta-process-matching.ps1.

.EXAMPLE
    .\tools\test-delta-install-retry.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Only lib\DeltaInstaller.Common.ps1 is needed - both functions under test
# are self-contained there (never setup.ps1 itself, which would run the
# actual installer).
$Script:ProjectRoot = if ($PSScriptRoot) { Split-Path -Path $PSScriptRoot -Parent } else { (Get-Location).Path }
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Common.ps1')

$Script:FailureCount = 0

function Assert-True {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail
    )
    if ($Condition) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    else {
        $Script:FailureCount++
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        if ($Detail) {
            Write-Host "       $Detail"
        }
    }
}

function Invoke-RetryScenario {
    <#
      Drives Invoke-DeltaComponentInstallWithRetry with instrumented
      scriptblocks. $ExitCodes supplies one exit code per install
      attempt; $UsableResults supplies successive TestComponentUsable
      answers (the last value repeats if the loop asks again). Returns a
      state object recording exactly what the loop did, including
      whether it threw and with what message.
    #>
    param(
        [Parameter(Mandatory)][int[]]$ExitCodes,
        [Parameter(Mandatory)][bool[]]$UsableResults,
        [int[]]$SuccessExitCodes = @(0),
        [string]$FailureLogHint = ''
    )

    # A stand-in secret proving requirement 7: even though a password is
    # in scope of (and "used" by) the install action, no failure output
    # may ever contain it.
    $fakeSuperuserPassword = 'S3cr3t-Pa55word!'

    $state = @{
        Installs     = @()
        UsableChecks = 0
        Cleanups     = 0
        Threw        = $false
        Message      = $null
    }

    try {
        Invoke-DeltaComponentInstallWithRetry -ComponentName 'TestComponent' `
            -RetryDelaySeconds 0 `
            -SuccessExitCodes $SuccessExitCodes `
            -FailureLogHint $FailureLogHint `
            -InstallAction {
                param($Attempt)
                $state.Installs += $Attempt
                $null = $fakeSuperuserPassword  # "used" to build installer arguments
                return $ExitCodes[$state.Installs.Count - 1]
            } `
            -TestComponentUsable {
                $index = [Math]::Min($state.UsableChecks, $UsableResults.Count - 1)
                $state.UsableChecks++
                return $UsableResults[$index]
            } `
            -CleanupAction {
                $state.Cleanups++
            }
    }
    catch {
        $state.Threw   = $true
        $state.Message = $_.Exception.Message
    }

    return [PSCustomObject]$state
}

Write-Host ''
Write-Host '--- Invoke-DeltaComponentInstallWithRetry ---'
Write-Host ''

# Scenario 1: success on attempt 1 -> no validation call, no cleanup, no retry.
$r = Invoke-RetryScenario -ExitCodes @(0) -UsableResults @($false)
Assert-True -Name 'Success on attempt 1: exactly one install attempt' -Condition ($r.Installs.Count -eq 1 -and $r.Installs[0] -eq 1)
Assert-True -Name 'Success on attempt 1: no validation fallback, no cleanup, no failure' -Condition ($r.UsableChecks -eq 0 -and $r.Cleanups -eq 0 -and -not $r.Threw)

# Scenario 2: installer fails but the component validates as usable -> no retry, no cleanup.
$r = Invoke-RetryScenario -ExitCodes @(1) -UsableResults @($true)
Assert-True -Name 'Failed exit code but component usable: no retry' -Condition ($r.Installs.Count -eq 1 -and -not $r.Threw)
Assert-True -Name 'Failed exit code but component usable: cleanup never runs' -Condition ($r.Cleanups -eq 0 -and $r.UsableChecks -eq 1)

# Scenario 3: fresh install fails, cleanup runs once, attempt 2 succeeds.
$r = Invoke-RetryScenario -ExitCodes @(1, 0) -UsableResults @($false)
Assert-True -Name 'Retry after failure: two attempts, numbered 1 and 2' -Condition ($r.Installs.Count -eq 2 -and $r.Installs[0] -eq 1 -and $r.Installs[1] -eq 2)
Assert-True -Name 'Retry after failure: cleanup ran exactly once, setup continued' -Condition ($r.Cleanups -eq 1 -and -not $r.Threw)

# Scenario 4: both attempts fail -> terminates, bounded at exactly 2 attempts.
$r = Invoke-RetryScenario -ExitCodes @(1, 1, 0) -UsableResults @($false) -FailureLogHint 'Logs: X (attempt 1), Y (attempt 2).'
Assert-True -Name 'Both attempts fail: setup terminates via Stop-Setup' -Condition $r.Threw
Assert-True -Name 'Both attempts fail: exactly 2 attempts, never a third' -Condition ($r.Installs.Count -eq 2)
Assert-True -Name 'Both attempts fail: cleanup only ran between the two attempts' -Condition ($r.Cleanups -eq 1)
Assert-True -Name 'Both attempts fail: message names component, attempt count, and logs' `
    -Condition ($r.Threw -and $r.Message -eq 'TestComponent installation failed after 2 attempts. See the installer logs for details. Logs: X (attempt 1), Y (attempt 2).') `
    -Detail "Actual message: $($r.Message)"

# Scenario 5: alternate success exit codes (MSI 3010 = success, reboot recommended).
$r = Invoke-RetryScenario -ExitCodes @(3010) -UsableResults @($false) -SuccessExitCodes @(0, 3010)
Assert-True -Name 'Exit code 3010 with SuccessExitCodes 0,3010: treated as success, no retry' -Condition ($r.Installs.Count -eq 1 -and $r.Cleanups -eq 0 -and -not $r.Threw)

# Scenario 6: attempt 2 also exits non-zero, but validation then succeeds -> continue.
$r = Invoke-RetryScenario -ExitCodes @(1, 1) -UsableResults @($false, $true)
Assert-True -Name 'Second attempt fails but validation succeeds: setup continues' -Condition ($r.Installs.Count -eq 2 -and $r.UsableChecks -eq 2 -and -not $r.Threw)

# Scenario 7: failure diagnostics contain no secrets.
$r = Invoke-RetryScenario -ExitCodes @(1, 1) -UsableResults @($false) -FailureLogHint 'Logs: X.'
Assert-True -Name 'Failure message contains no password material' `
    -Condition ($r.Threw -and $r.Message -notmatch 'S3cr3t-Pa55word!' -and $r.Message -notmatch '(?i)password') `
    -Detail "Actual message: $($r.Message)"

Write-Host ''
Write-Host '--- Test-PostgresFreshInstallCleanupSafe ---'
Write-Host ''

$cleanupCases = @(
    [PSCustomObject]@{
        Name     = 'Confirmed fresh-install partial failure (nothing pre-existing, no service, uninitialized) -> cleanup allowed'
        Args     = @{ InstallPrefixExistedBeforeSetup = $false; DataDirectoryExistedBeforeSetup = $false; ServiceExistedBeforeSetup = $false; ServiceExistsNow = $false; DataDirectoryInitializedNow = $false }
        Expected = $true
    }
    [PSCustomObject]@{
        Name     = 'Install prefix existed before setup -> never cleaned'
        Args     = @{ InstallPrefixExistedBeforeSetup = $true; DataDirectoryExistedBeforeSetup = $false; ServiceExistedBeforeSetup = $false; ServiceExistsNow = $false; DataDirectoryInitializedNow = $false }
        Expected = $false
    }
    [PSCustomObject]@{
        Name     = 'Data directory existed before setup -> never cleaned'
        Args     = @{ InstallPrefixExistedBeforeSetup = $false; DataDirectoryExistedBeforeSetup = $true; ServiceExistedBeforeSetup = $false; ServiceExistsNow = $false; DataDirectoryInitializedNow = $false }
        Expected = $false
    }
    [PSCustomObject]@{
        Name     = 'Service existed before setup -> never cleaned'
        Args     = @{ InstallPrefixExistedBeforeSetup = $false; DataDirectoryExistedBeforeSetup = $false; ServiceExistedBeforeSetup = $true; ServiceExistsNow = $false; DataDirectoryInitializedNow = $false }
        Expected = $false
    }
    [PSCustomObject]@{
        Name     = 'Failed attempt still registered a service -> not a clean partial extraction, never cleaned'
        Args     = @{ InstallPrefixExistedBeforeSetup = $false; DataDirectoryExistedBeforeSetup = $false; ServiceExistedBeforeSetup = $false; ServiceExistsNow = $true; DataDirectoryInitializedNow = $false }
        Expected = $false
    }
    [PSCustomObject]@{
        Name     = 'Data directory reached initdb (PG_VERSION present) -> cluster never deleted'
        Args     = @{ InstallPrefixExistedBeforeSetup = $false; DataDirectoryExistedBeforeSetup = $false; ServiceExistedBeforeSetup = $false; ServiceExistsNow = $false; DataDirectoryInitializedNow = $true }
        Expected = $false
    }
    [PSCustomObject]@{
        Name     = 'Everything pre-existing (reused installation with an installer/validation problem) -> never cleaned'
        Args     = @{ InstallPrefixExistedBeforeSetup = $true; DataDirectoryExistedBeforeSetup = $true; ServiceExistedBeforeSetup = $true; ServiceExistsNow = $true; DataDirectoryInitializedNow = $true }
        Expected = $false
    }
)

foreach ($case in $cleanupCases) {
    $caseArgs = $case.Args
    $actual = Test-PostgresFreshInstallCleanupSafe @caseArgs
    Assert-True -Name $case.Name -Condition ($actual -eq $case.Expected) -Detail "Expected $($case.Expected), got $actual"
}

Write-Host ''
if ($Script:FailureCount -eq 0) {
    Write-Host 'All retry-handling test cases passed.' -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$($Script:FailureCount) retry-handling test case(s) FAILED." -ForegroundColor Red
    exit 1
}

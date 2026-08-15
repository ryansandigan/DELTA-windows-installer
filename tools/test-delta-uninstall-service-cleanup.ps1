#Requires -Version 5.1
<#
.SYNOPSIS
    Validates uninstall.ps1's Phase 0 DeltaApp service handling, including
    removal of a registration that outlived its own DELTA installation
    directory.

.DESCRIPTION
    Stop-DeltaRuntimeBeforeUninstall (uninstall.ps1) has two distinct
    responsibilities that resolve the same install path but must NOT share
    the same early return:

      - Process-level cleanup, which genuinely has nothing to do when
        Get-DeltaInstallPath finds no installation.
      - DeltaApp service handling, which does: a service registration can
        outlive the directory it points at (an operator who deleted the
        DELTA directory by hand, or an earlier uninstall whose removal only
        reached "marked for deletion" with no reboot since). Get-DeltaInstallPath
        correctly returns nothing in that state - the registry's InstallPath
        must still pass Test-Path, and C:\DELTA\.env must exist, for either
        fallback to resolve - so gating the service check on it left the
        registration untouched by the entire uninstall: still Automatic,
        pointed at a DeltaApp.exe that no longer exists, failing at every
        boot, and reported as 'N/A' in the summary.

    Phase 0.7 (Uninstall-DeltaApplicationDirectory) cannot cover that case
    because it resolves the same path and returns just as early, which is
    what makes Phase 0 the only point in the run where an orphan is
    reachable. These cases pin that down, along with the behaviour that must
    NOT change: when a DELTA directory does exist, Phase 0 still only STOPS
    the service, and every removal/preserve/disable decision stays with
    Phase 0.7.

    Runs entirely against stubs - no service registration, no SCM calls, no
    deployed DELTA, no Administrator rights - in the same style as
    tools\test-delta-service-definition.ps1 and
    tools\test-delta-process-matching.ps1. The function under test is
    extracted from uninstall.ps1 by AST rather than dot-sourced, because
    dot-sourcing that file would run its whole orchestration block
    (including the interactive Confirm-UninstallIntent prompt). Extracting
    it means these cases run the real shipped function body, not a copy
    that could drift from it.

    Exits 0 if every case passes, 1 otherwise.

.EXAMPLE
    .\tools\test-delta-uninstall-service-cleanup.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# lib\DeltaInstaller.Common.ps1 dot-sources lib\DeltaInstaller.Service.ps1
# itself, so this single dot-source brings in the console vocabulary
# (Write-Step/Write-Detail/Write-Success/Write-PhaseBanner) and
# $Script:DeltaServiceName - exactly as uninstall.ps1 gets them.
$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Common.ps1')

$Script:Failures = 0
$Script:Passes   = 0

function Assert-True {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail
    )
    if ($Condition) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $Script:Passes++
    }
    else {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor Red }
        $Script:Failures++
    }
}

# ---------------------------------------------------------------------------
# The function under test, taken from uninstall.ps1 itself
# ---------------------------------------------------------------------------

function Import-FunctionFromScript {
    <#
      Defines a single named function from another script file without
      executing anything else in it. The alternative - dot-sourcing
      uninstall.ps1 - would run its orchestration block and stop at the
      interactive confirmation prompt.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FunctionName
    )

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw "$Path failed to parse: $(($errors | ForEach-Object { $_.Message }) -join '; ')"
    }

    $definition = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName },
        $true
    ) | Select-Object -First 1

    if (-not $definition) {
        throw "$FunctionName was not found in $Path."
    }

    return $definition.Extent.Text
}

$Script:UninstallScriptPath = Join-Path -Path $Script:ProjectRoot -ChildPath 'uninstall.ps1'
. ([scriptblock]::Create((Import-FunctionFromScript -Path $Script:UninstallScriptPath -FunctionName 'Stop-DeltaRuntimeBeforeUninstall')))

# ---------------------------------------------------------------------------
# Stubs
#
# Defined AFTER the dot-source above so they shadow the real
# implementations from lib\. Every one records that it was called, because
# what this phase must NOT do (remove a service while its directory still
# exists; touch process cleanup when there is no installation) matters as
# much as what it must.
# ---------------------------------------------------------------------------

$Script:InstallPath           = $null
$Script:ServiceInstalled      = $false
$Script:StopServiceSucceeds   = $true
$Script:RemoveServiceSucceeds = $true
$Script:Calls                 = @()
$Script:RemoveAppRootArgument = 'never-called'

function Get-DeltaInstallPath { return $Script:InstallPath }

function Test-DeltaServiceInstalled {
    $Script:Calls += 'Test-DeltaServiceInstalled'
    return $Script:ServiceInstalled
}

function Stop-DeltaWindowsService {
    $Script:Calls += 'Stop-DeltaWindowsService'
    return $Script:StopServiceSucceeds
}

function Uninstall-DeltaWindowsService {
    param([AllowNull()][string]$AppRoot)
    $Script:Calls += 'Uninstall-DeltaWindowsService'
    $Script:RemoveAppRootArgument = $AppRoot
    return $Script:RemoveServiceSucceeds
}

function Get-RunningDeltaProcesses {
    param([Parameter(Mandatory)][string]$DeltaRuntimeRoot)
    $Script:Calls += 'Get-RunningDeltaProcesses'
    return @()
}

function Get-RunningDeltaLauncherProcesses {
    $Script:Calls += 'Get-RunningDeltaLauncherProcesses'
    return @()
}

function Stop-RunningDeltaInstance {
    param([Parameter(Mandatory)][string]$DeltaRuntimeRoot)
    $Script:Calls += 'Stop-RunningDeltaInstance'
}

function Invoke-Phase0 {
    <#
      Resets recorded state, runs the real Phase 0 body against the stubs
      above, and returns everything the assertions need. Any terminating
      error is captured rather than thrown: "an orphan that could not be
      removed must not break unrelated cleanup" is itself one of the
      properties under test.
    #>
    param(
        [AllowNull()][string]$InstallPath,
        [bool]$ServiceInstalled,
        [bool]$StopSucceeds = $true,
        [bool]$RemoveSucceeds = $true
    )

    $Script:InstallPath           = $InstallPath
    $Script:ServiceInstalled      = $ServiceInstalled
    $Script:StopServiceSucceeds   = $StopSucceeds
    $Script:RemoveServiceSucceeds = $RemoveSucceeds
    $Script:Calls                 = @()
    $Script:RemoveAppRootArgument = 'never-called'
    $Script:DeltaServiceResult    = 'N/A'

    $caught = $null
    try {
        Stop-DeltaRuntimeBeforeUninstall | Out-Null
    }
    catch {
        $caught = $_
    }

    return [PSCustomObject]@{
        Calls          = @($Script:Calls)
        ServiceResult  = $Script:DeltaServiceResult
        RemoveAppRoot  = $Script:RemoveAppRootArgument
        Error          = $caught
    }
}

Write-Host ''
Write-Host 'DELTA uninstall - Phase 0 Windows service handling'
Write-Host ''

# ---------------------------------------------------------------------------
# 1. Service installed + valid DELTA directory
#
# The pre-existing contract, and the one this change must not disturb: the
# service is stopped here and NOTHING else. Removal, preservation, and the
# disable-with-marker path all belong to Phase 0.7, which is the only place
# that knows whether the operator is keeping the directory.
# ---------------------------------------------------------------------------

Write-Host "`n--- 1. Service installed, DELTA directory present ---"

$case = Invoke-Phase0 -InstallPath 'C:\DELTA' -ServiceInstalled $true

Assert-True -Name 'The service is stopped' `
    -Condition ($case.Calls -contains 'Stop-DeltaWindowsService')
Assert-True -Name 'The service is NOT removed - that decision belongs to Phase 0.7' `
    -Condition ($case.Calls -notcontains 'Uninstall-DeltaWindowsService')
Assert-True -Name 'The service result is left for Phase 0.7 to report' `
    -Condition ($case.ServiceResult -eq 'N/A') `
    -Detail "Got: $($case.ServiceResult)"
Assert-True -Name 'Process-level cleanup still runs' `
    -Condition ($case.Calls -contains 'Get-RunningDeltaProcesses')
Assert-True -Name 'The service is stopped BEFORE any process is inspected' `
    -Condition ([array]::IndexOf($case.Calls, 'Stop-DeltaWindowsService') -lt [array]::IndexOf($case.Calls, 'Get-RunningDeltaProcesses'))
Assert-True -Name 'No error' -Condition ($null -eq $case.Error)

# ---------------------------------------------------------------------------
# 2. Service installed + missing DELTA directory (the orphan)
# ---------------------------------------------------------------------------

Write-Host "`n--- 2. Service installed, DELTA directory missing (orphaned registration) ---"

$case = Invoke-Phase0 -InstallPath $null -ServiceInstalled $true

Assert-True -Name 'The orphaned service is detected despite no installation path' `
    -Condition ($case.Calls -contains 'Test-DeltaServiceInstalled')
Assert-True -Name 'It is stopped before removal is attempted' `
    -Condition (
        ($case.Calls -contains 'Stop-DeltaWindowsService') -and
        ([array]::IndexOf($case.Calls, 'Stop-DeltaWindowsService') -lt [array]::IndexOf($case.Calls, 'Uninstall-DeltaWindowsService'))
    )
Assert-True -Name 'The orphaned registration is removed' `
    -Condition ($case.Calls -contains 'Uninstall-DeltaWindowsService')
Assert-True -Name 'Removal goes through the -AppRoot $null (sc.exe delete) fallback' `
    -Condition ([string]::IsNullOrEmpty($case.RemoveAppRoot)) `
    -Detail "Got: '$($case.RemoveAppRoot)'"
Assert-True -Name 'The summary reports the removal rather than N/A' `
    -Condition ($case.ServiceResult -match '^Removed') `
    -Detail "Got: $($case.ServiceResult)"
Assert-True -Name 'The summary says WHY there was no directory' `
    -Condition ($case.ServiceResult -match 'orphaned')
Assert-True -Name 'Process-level cleanup is still skipped - there is no installation to inspect' `
    -Condition ($case.Calls -notcontains 'Get-RunningDeltaProcesses')
Assert-True -Name 'No running-instance stop is attempted against a path that does not exist' `
    -Condition ($case.Calls -notcontains 'Stop-RunningDeltaInstance')
Assert-True -Name 'No error' -Condition ($null -eq $case.Error)

# ---------------------------------------------------------------------------
# 3. No service + missing DELTA directory
#
# The compatibility case: a machine that never had the service-based
# installer, or one already fully cleaned up. Must stay a silent no-op.
# ---------------------------------------------------------------------------

Write-Host "`n--- 3. No service, no DELTA directory ---"

$case = Invoke-Phase0 -InstallPath $null -ServiceInstalled $false

Assert-True -Name 'Nothing is stopped' `
    -Condition ($case.Calls -notcontains 'Stop-DeltaWindowsService')
Assert-True -Name 'Nothing is removed' `
    -Condition ($case.Calls -notcontains 'Uninstall-DeltaWindowsService')
Assert-True -Name 'No process cleanup is attempted' `
    -Condition ($case.Calls -notcontains 'Get-RunningDeltaProcesses')
Assert-True -Name 'The service result stays N/A' `
    -Condition ($case.ServiceResult -eq 'N/A') `
    -Detail "Got: $($case.ServiceResult)"
Assert-True -Name 'No error - an older installation must not fail the uninstall' `
    -Condition ($null -eq $case.Error)

# ---------------------------------------------------------------------------
# 3b. No service + valid DELTA directory
#
# The other half of compatibility: a pre-service DELTA deployment still
# running the legacy directly-launched runtime.
# ---------------------------------------------------------------------------

Write-Host "`n--- 3b. No service, DELTA directory present (legacy deployment) ---"

$case = Invoke-Phase0 -InstallPath 'C:\DELTA' -ServiceInstalled $false

Assert-True -Name 'No service call is made' `
    -Condition (
        ($case.Calls -notcontains 'Stop-DeltaWindowsService') -and
        ($case.Calls -notcontains 'Uninstall-DeltaWindowsService')
    )
Assert-True -Name 'Legacy process cleanup still runs' `
    -Condition ($case.Calls -contains 'Get-RunningDeltaProcesses')
Assert-True -Name 'The launcher is inspected too, not just the server process' `
    -Condition ($case.Calls -contains 'Get-RunningDeltaLauncherProcesses')
Assert-True -Name 'The service result stays N/A' `
    -Condition ($case.ServiceResult -eq 'N/A')
Assert-True -Name 'No error' -Condition ($null -eq $case.Error)

# ---------------------------------------------------------------------------
# 4. Already-stopped service
#
# Stop-DeltaWindowsService returns $true immediately for a service that is
# already Stopped, so "already stopped" and "stopped successfully" are the
# same input here. What matters is that an already-stopped orphan is still
# REMOVED rather than treated as nothing to do, and that an already-stopped
# service with a live directory is still left alone.
# ---------------------------------------------------------------------------

Write-Host "`n--- 4. Already-stopped service ---"

$case = Invoke-Phase0 -InstallPath $null -ServiceInstalled $true -StopSucceeds $true

Assert-True -Name 'An already-stopped orphan is still removed' `
    -Condition ($case.Calls -contains 'Uninstall-DeltaWindowsService')
Assert-True -Name 'An already-stopped orphan still reports Removed' `
    -Condition ($case.ServiceResult -match '^Removed')

$case = Invoke-Phase0 -InstallPath 'C:\DELTA' -ServiceInstalled $true -StopSucceeds $true

Assert-True -Name 'An already-stopped service with a live directory is still not removed' `
    -Condition ($case.Calls -notcontains 'Uninstall-DeltaWindowsService')

# A service that will not stop must not block the orphan cleanup: the
# registration is what is being removed, and sc.exe delete marks a running
# service for deletion rather than refusing.
$case = Invoke-Phase0 -InstallPath $null -ServiceInstalled $true -StopSucceeds $false

Assert-True -Name 'An orphan that would not stop is still removed' `
    -Condition ($case.Calls -contains 'Uninstall-DeltaWindowsService')
Assert-True -Name 'A failed stop does not fail the run' `
    -Condition ($null -eq $case.Error)

# ---------------------------------------------------------------------------
# 5. Orphan removal fails
#
# sc.exe delete on a service the SCM still holds open marks it for deletion
# and it disappears at the next reboot. That is a reportable outcome, not a
# failure, and it must never abort a run whose real job is removing
# PostGIS/PostgreSQL/Node.js.
# ---------------------------------------------------------------------------

Write-Host "`n--- 5. Orphan removal does not complete ---"

$case = Invoke-Phase0 -InstallPath $null -ServiceInstalled $true -RemoveSucceeds $false

Assert-True -Name 'Removal was attempted' `
    -Condition ($case.Calls -contains 'Uninstall-DeltaWindowsService')
Assert-True -Name 'The result is the existing "still present" wording, not Removed' `
    -Condition ($case.ServiceResult -eq 'Removal requested (registration still present - may clear after reboot)') `
    -Detail "Got: $($case.ServiceResult)"
Assert-True -Name 'The result is not silently left at N/A' `
    -Condition ($case.ServiceResult -ne 'N/A')
Assert-True -Name 'The phase returns normally so unrelated cleanup continues' `
    -Condition ($null -eq $case.Error) `
    -Detail "Got: $($case.Error)"

# The wording has to match what Phase 0.7 already reports for the same
# outcome - two different sentences for one state is exactly how a summary
# starts lying about what happened.
$phase07Text = Get-Content -LiteralPath $Script:UninstallScriptPath -Raw
Assert-True -Name 'The wording matches the one Phase 0.7 already uses for this outcome' `
    -Condition (
        ([regex]::Matches($phase07Text, [regex]::Escape('Removal requested (registration still present - may clear after reboot)'))).Count -ge 2
    )

# ---------------------------------------------------------------------------
# Ordering invariant
#
# The whole fix is that the service block sits ABOVE the install-path early
# return. Asserted against the shipped source, not just behaviour, because a
# later edit could reintroduce the gap while every case above still passes
# for a machine that happens to have an installation directory.
# ---------------------------------------------------------------------------

Write-Host "`n--- 6. Source ordering ---"

$phase0Text = Import-FunctionFromScript -Path $Script:UninstallScriptPath -FunctionName 'Stop-DeltaRuntimeBeforeUninstall'
$serviceCheckIndex = $phase0Text.IndexOf('Test-DeltaServiceInstalled')
$earlyReturnIndex = $phase0Text.IndexOf('nothing to stop')

Assert-True -Name 'The service check appears before the no-installation early return' `
    -Condition ($serviceCheckIndex -ge 0 -and $earlyReturnIndex -ge 0 -and $serviceCheckIndex -lt $earlyReturnIndex) `
    -Detail "service check at $serviceCheckIndex, early return at $earlyReturnIndex"

# Counted as parsed COMMANDS, not as occurrences of the string: the
# function's own header and the comment explaining the ordering both name
# Get-DeltaInstallPath in prose, and a text match would score those as
# calls. One resolution shared by both halves of the phase is the point -
# re-resolving it per half would let the two disagree.
$phase0Ast = [System.Management.Automation.Language.Parser]::ParseInput($phase0Text, [ref]$null, [ref]$null)
$installPathCalls = @($phase0Ast.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-DeltaInstallPath' },
    $true
))

Assert-True -Name 'Phase 0 still resolves the install path exactly once' `
    -Condition ($installPathCalls.Count -eq 1) `
    -Detail "Got: $($installPathCalls.Count) call(s)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ''
if ($Script:Failures -eq 0) {
    Write-Host "All $($Script:Passes) test case(s) passed." -ForegroundColor Green
    exit 0
}

Write-Host "$($Script:Failures) of $($Script:Passes + $Script:Failures) test case(s) FAILED." -ForegroundColor Red
exit 1

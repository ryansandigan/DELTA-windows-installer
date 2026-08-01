#Requires -Version 5.1
<#
.SYNOPSIS
    Validates Test-DeltaManagedProcessCommandLine against real and
    adversarial DELTA process command lines.

.DESCRIPTION
    Test-DeltaManagedProcessCommandLine (lib\DeltaInstaller.Common.ps1) is
    the matching predicate behind setup.ps1's Get-RunningDeltaProcesses -
    it decides whether a given node.exe command line is genuinely this
    installer's own managed DELTA runtime. It replaced an earlier
    implementation that matched a single absolute-path string and was
    confirmed, by direct reproduction against a real `dotenv -e .env --
    yarn start` invocation, to never match a real DELTA process at all
    (see docs/02-windows-installation.md and this project's own
    investigation history for the full trail).

    This script exercises that predicate directly - no live process, no
    CIM query, no installed DELTA runtime required - against a fixed set
    of command lines: the real invocation that was captured live, its
    backslash/absolute variants, and the specific adversarial case
    (an unrelated deployment sharing the same entry-point convention)
    the two-signal design exists to reject.

    Exits 0 if every case matches its expected result, 1 otherwise - safe
    to wire into CI or run locally after touching the matching logic.

.EXAMPLE
    .\tools\test-delta-process-matching.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Only lib\DeltaInstaller.Common.ps1 is needed - Test-DeltaManagedProcessCommandLine
# is a pure function with no dependency on setup.ps1's own orchestration or
# $Script:ProjectRoot, so dot-sourcing the shared lib file alone (never
# setup.ps1 itself, which would run the actual installer) is sufficient.
$Script:ProjectRoot = if ($PSScriptRoot) { Split-Path -Path $PSScriptRoot -Parent } else { (Get-Location).Path }
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Common.ps1')

# Every command line below is either a real, live-captured invocation
# (see the header above) or a deliberately adversarial construction - none
# of these are guesses at what a command line might look like.
$testCases = @(
    [PSCustomObject]@{
        Name             = 'Real invocation: dotenv/yarn -> react-router-serve .bin shim (forward-slash, relative entry point)'
        CommandLine      = '"node"   "C:\DELTA\node_modules\.bin\\..\@react-router\serve\bin.cjs" ./build/server/index.js'
        DeltaRuntimeRoot = 'C:\DELTA'
        Expected         = $true
    }
    [PSCustomObject]@{
        Name             = 'Backslash, relative entry point (e.g. docs'' own NSSM-style example)'
        CommandLine      = '"C:\Program Files\nodejs\node.exe" "C:\DELTA\node_modules\@react-router\serve\dist\cli.js" .\build\server\index.js'
        DeltaRuntimeRoot = 'C:\DELTA'
        Expected         = $true
    }
    [PSCustomObject]@{
        Name             = 'Absolute entry-point argument'
        CommandLine      = '"C:\Program Files\nodejs\node.exe" C:\DELTA\build\server\index.js'
        DeltaRuntimeRoot = 'C:\DELTA'
        Expected         = $true
    }
    [PSCustomObject]@{
        Name             = 'Unrelated deployment - same entry-point convention, different install directory (must be rejected)'
        CommandLine      = '"node" "C:\OtherApp\node_modules\.bin\..\@react-router\serve\bin.cjs" ./build/server/index.js'
        DeltaRuntimeRoot = 'C:\DELTA'
        Expected         = $false
    }
    [PSCustomObject]@{
        Name             = 'Case-insensitive match (Windows paths are case-insensitive)'
        CommandLine      = '"node" "c:\delta\node_modules\.bin\..\@react-router\serve\bin.cjs" ./BUILD/SERVER/INDEX.JS'
        DeltaRuntimeRoot = 'C:\DELTA'
        Expected         = $true
    }
    [PSCustomObject]@{
        Name             = 'Trailing directory separator on DeltaRuntimeRoot is tolerated'
        CommandLine      = '"node" "C:\DELTA\node_modules\.bin\..\@react-router\serve\bin.cjs" ./build/server/index.js'
        DeltaRuntimeRoot = 'C:\DELTA\'
        Expected         = $true
    }
    [PSCustomObject]@{
        Name             = 'Unrelated node.exe process - no DELTA entry point at all'
        CommandLine      = '"C:\Program Files\nodejs\node.exe" some-other-script.js'
        DeltaRuntimeRoot = 'C:\DELTA'
        Expected         = $false
    }
    [PSCustomObject]@{
        Name             = 'Null command line (e.g. an access-denied CIM query) never matches'
        CommandLine      = $null
        DeltaRuntimeRoot = 'C:\DELTA'
        Expected         = $false
    }
)

$failureCount = 0

foreach ($case in $testCases) {
    $actual = Test-DeltaManagedProcessCommandLine -CommandLine $case.CommandLine -DeltaRuntimeRoot $case.DeltaRuntimeRoot
    $passed = ($actual -eq $case.Expected)

    if ($passed) {
        Write-Host "[PASS] $($case.Name)" -ForegroundColor Green
    }
    else {
        $failureCount++
        Write-Host "[FAIL] $($case.Name)" -ForegroundColor Red
        Write-Host "       CommandLine      : $($case.CommandLine)"
        Write-Host "       DeltaRuntimeRoot : $($case.DeltaRuntimeRoot)"
        Write-Host "       Expected         : $($case.Expected)"
        Write-Host "       Actual           : $actual"
    }
}

Write-Host ''
if ($failureCount -eq 0) {
    Write-Host "All $($testCases.Count) test case(s) passed." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$failureCount of $($testCases.Count) test case(s) FAILED." -ForegroundColor Red
    exit 1
}

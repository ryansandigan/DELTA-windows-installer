#Requires -Version 5.1
<#
.SYNOPSIS
    Validates the DELTA Windows Service configuration rendering, path
    helpers, and runtime state mapping.

.DESCRIPTION
    Exercises lib\DeltaInstaller.Service.ps1's pure logic directly - no
    service registration, no WinSW binary, no deployed DELTA, no
    Administrator rights required - in the same style as
    tools\test-delta-process-matching.ps1 and
    tools\test-delta-public-url-port-sync.ps1.

    What is covered, and why each case exists rather than being assumed:

      - The rendered service definition against a normal path, a path
        containing SPACES, and a path containing an XML-significant
        character. Every path token in the template sits inside quotes and
        every substituted value is XML-escaped; both properties are
        load-bearing and neither is visible by reading the template alone.
      - The absence of hardcoded values. C:\DELTA and port 3000 are the two
        defaults this repository has always been careful never to bake into
        anything, and a service definition is exactly the sort of generated
        file where one could reappear unnoticed. The port assertion is
        stronger than it looks: the service configuration must contain no
        port at all, because PORT reaches the runtime through .env rather
        than through the service.
      - The PostgreSQL <depend> element appearing only when a dependency was
        actually supplied - "no dependency" has to mean no element, not an
        empty one.
      - Unsubstituted-token detection, so a template that grows a new
        placeholder fails loudly at generation time instead of producing a
        service that will not start.
      - The runtime state mapping, including the states that only exist
        because a service exists (Damaged, Broken-with-service,
        NotInstalled) and the ones that predate it (Conflicted, Running).
      - The displayed startup mode across Automatic, Manual, Disabled and
        an unreadable start type - and that no delayed-start wording
        survives in any of them.
      - Delayed automatic start being treated as CONFIGURATION DRIFT rather
        than as a supported mode. DELTA now uses plain Automatic, so a
        service still carrying that flag - which is every deployment made
        by an earlier version of this installer - must be corrected. The
        flag is invisible in StartType, so this is asserted directly.

    Exits 0 if every case passes, 1 otherwise - safe to run locally after
    touching the service logic, or from CI.

.EXAMPLE
    .\tools\test-delta-service-definition.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# lib\DeltaInstaller.Common.ps1 dot-sources lib\DeltaInstaller.Service.ps1
# itself (see that file's own trailing section), so this single dot-source
# brings in both - exactly as setup.ps1/uninstall.ps1 get them.
$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Common.ps1')

$Script:TemplatePath = Join-Path -Path $Script:ProjectRoot -ChildPath 'templates\service\delta-service.xml'

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

function Test-IsWellFormedXml {
    <#
      A plain [bool] "does this parse as XML". Deliberately a function
      rather than an inline scriptblock: ScriptBlock.Invoke() returns a
      Collection[PSObject], not a Boolean, which a [bool] parameter refuses
      to bind.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Xml)

    try {
        [xml]$Xml | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function New-TestDefinition {
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [string]$NodeExecutable = 'C:\Program Files\nodejs\node.exe',
        [string]$ServeCli,
        [AllowNull()][string]$PostgresServiceName
    )

    # [IO.Path]::Combine rather than Join-Path: Join-Path resolves the
    # PSDrive and throws for a drive that does not exist on the test
    # machine, which would make these cases depend on the tester's own disk
    # layout. Pure string composition is what is wanted here.
    if (-not $ServeCli) {
        $ServeCli = [System.IO.Path]::Combine($AppRoot, 'node_modules\@react-router\serve\bin.js')
    }

    return Get-DeltaServiceDefinitionContent `
        -TemplatePath $Script:TemplatePath `
        -AppRoot $AppRoot `
        -NodeExecutable $NodeExecutable `
        -ServeCliPath $ServeCli `
        -EnvPath ([System.IO.Path]::Combine($AppRoot, '.env')) `
        -LogDirectory ([System.IO.Path]::Combine($AppRoot, 'logs')) `
        -PostgresServiceName $PostgresServiceName
}

Write-Host ''
Write-Host 'DELTA Windows Service - configuration and state tests'
Write-Host ''

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

# Built from $env:SystemDrive rather than a literal drive letter: the path
# helpers below use Join-Path, which resolves the PSDrive and throws for a
# drive that does not exist on the machine running the tests. The rendering
# cases further down are pure string substitution and deliberately DO use
# other drive letters, since proving drive-independence is part of the point
# there.
$spacedRoot = "$env:SystemDrive\Program Files\DELTA App"
Assert-True -Name 'Service directory is <AppRoot>\service' `
    -Condition ((Get-DeltaServiceDirectory -AppRoot $spacedRoot) -eq "$spacedRoot\service")

Assert-True -Name 'Service executable basename matches the service name' `
    -Condition ((Split-Path -Leaf (Get-DeltaServiceExecutablePath -AppRoot $spacedRoot)) -eq "$($Script:DeltaServiceName).exe")

# WinSW requires <name>.xml beside <name>.exe - if these ever diverge the
# service silently fails to find its own configuration.
Assert-True -Name 'Service definition basename matches the executable basename' `
    -Condition (
        [System.IO.Path]::GetFileNameWithoutExtension((Get-DeltaServiceDefinitionPath -AppRoot $spacedRoot)) -eq
        [System.IO.Path]::GetFileNameWithoutExtension((Get-DeltaServiceExecutablePath -AppRoot $spacedRoot))
    )

Assert-True -Name 'Virtual service account is derived from the service name' `
    -Condition ($Script:DeltaServiceAccount -eq "NT SERVICE\$($Script:DeltaServiceName)")

# ---------------------------------------------------------------------------
# Rendering - normal path
# ---------------------------------------------------------------------------

$normal = New-TestDefinition -AppRoot 'C:\DELTA' -PostgresServiceName 'postgresql-x64-17'

Assert-True -Name 'Rendered definition is well-formed XML' `
    -Condition (Test-IsWellFormedXml -Xml $normal)

$normalXml = [xml]$normal
Assert-True -Name 'Service id is the configured service name' `
    -Condition ($normalXml.service.id -eq $Script:DeltaServiceName)

Assert-True -Name 'Executable is the absolute node.exe path' `
    -Condition ($normalXml.service.executable -eq 'C:\Program Files\nodejs\node.exe')

Assert-True -Name 'Working directory is the application root' `
    -Condition ($normalXml.service.workingdirectory -eq 'C:\DELTA')

Assert-True -Name 'Arguments load .env through Node --env-file' `
    -Condition ($normalXml.service.arguments -match '--env-file=')

Assert-True -Name 'Arguments run the compiled server entry point' `
    -Condition ($normalXml.service.arguments -match ([regex]::Escape('./build/server/index.js')))

# The whole point of the direct launch: none of the legacy chain may appear
# in what the service actually EXECUTES. Asserted against the executable and
# arguments specifically rather than the whole file, because the template's
# explanatory comments legitimately name cmd.exe/start.bat/dotenv/yarn while
# documenting why none of them is used.
$normalExecuted = "$($normalXml.service.executable) $($normalXml.service.arguments)"
foreach ($forbidden in @('cmd.exe', 'start.bat', 'dotenv ', 'yarn')) {
    Assert-True -Name "Service never executes '$($forbidden.Trim())'" `
        -Condition ($normalExecuted -notmatch [regex]::Escape($forbidden)) `
        -Detail "Found '$forbidden' in: $normalExecuted"
}

# --env-file= is the Node option and must survive; a bare "dotenv" command
# must not. Guarding these separately keeps the assertion above honest
# rather than making it pass by accident on substring boundaries.
Assert-True -Name "Service does not invoke the dotenv-cli wrapper" `
    -Condition ($normalXml.service.arguments -notmatch '(^|\s)dotenv(\s|$)')

Assert-True -Name 'Startup is automatic' `
    -Condition ($normalXml.service.startmode -eq 'Automatic')

# Asserted by XPath rather than against the raw text: the template's own
# comment explains why there is no such element, and a text search cannot
# tell that explanation apart from the element itself. SelectSingleNode sees
# only real elements, and is not intercepted by PowerShell's XML adapter the
# way property access would be.
Assert-True -Name 'No delayed automatic start is configured' `
    -Condition ($null -eq $normalXml.SelectSingleNode('/service/delayedAutoStart')) `
    -Detail 'The rendered definition still declares a delayedAutoStart element.'

Assert-True -Name 'PostgreSQL dependency is rendered when supplied' `
    -Condition ($normalXml.service.depend -eq 'postgresql-x64-17')

Assert-True -Name 'Restart policy is bounded (a finite number of restart actions)' `
    -Condition (@($normalXml.service.onfailure).Count -ge 1 -and @($normalXml.service.onfailure | Where-Object { $_.action -eq 'restart' }).Count -le 5)

Assert-True -Name 'A failure reset period is configured' `
    -Condition (-not [string]::IsNullOrWhiteSpace($normalXml.service.resetfailure))

Assert-True -Name 'A stop timeout is configured' `
    -Condition (-not [string]::IsNullOrWhiteSpace($normalXml.service.stoptimeout))

Assert-True -Name 'Log output is bounded (roll-by-size)' `
    -Condition ($normalXml.service.log.mode -eq 'roll-by-size')

# ---------------------------------------------------------------------------
# Rendering - no PostgreSQL dependency
# ---------------------------------------------------------------------------

$noDepend = New-TestDefinition -AppRoot 'C:\DELTA' -PostgresServiceName $null
$noDependXml = [xml]$noDepend

Assert-True -Name 'No <depend> element at all when no dependency applies' `
    -Condition ($null -eq $noDependXml.service.SelectSingleNode('depend')) `
    -Detail 'An empty <depend> element is not the same as no dependency and WinSW rejects it.'

# ---------------------------------------------------------------------------
# Rendering - configurable paths (no hardcoded C:\DELTA or port 3000)
# ---------------------------------------------------------------------------

$custom = New-TestDefinition -AppRoot 'E:\Applications\Delta-Production' -PostgresServiceName $null

Assert-True -Name 'Custom application root is honoured' `
    -Condition (([xml]$custom).service.workingdirectory -eq 'E:\Applications\Delta-Production')

Assert-True -Name 'No hardcoded C:\DELTA leaks into a custom-root definition' `
    -Condition ($custom -notmatch [regex]::Escape('C:\DELTA')) `
    -Detail 'The rendered definition referenced C:\DELTA despite a different application root.'

# PORT reaches the runtime via .env, never via the service configuration -
# so no port number should appear anywhere in the rendered file.
Assert-True -Name 'No port number is embedded in the service definition' `
    -Condition ($custom -notmatch '\b3000\b') `
    -Detail 'A port number appeared in the service configuration; PORT must come from .env only.'

# ---------------------------------------------------------------------------
# Rendering - paths containing spaces and XML-significant characters
# ---------------------------------------------------------------------------

$spaced = New-TestDefinition -AppRoot 'D:\Program Files\DELTA App' -PostgresServiceName $null
$spacedXml = [xml]$spaced

Assert-True -Name 'Application root containing spaces survives rendering' `
    -Condition ($spacedXml.service.workingdirectory -eq 'D:\Program Files\DELTA App')

# Unquoted, a spaced path would be split into several arguments by Node's
# own command-line parsing and the service would fail to start.
Assert-True -Name 'Spaced .env path is quoted inside the arguments' `
    -Condition ($spacedXml.service.arguments -match ([regex]::Escape('--env-file="D:\Program Files\DELTA App\.env"')))

Assert-True -Name 'Spaced serve CLI path is quoted inside the arguments' `
    -Condition ($spacedXml.service.arguments -match ([regex]::Escape('"D:\Program Files\DELTA App\node_modules\@react-router\serve\bin.js"')))

$ampersand = New-TestDefinition -AppRoot 'C:\Delta R&D' -PostgresServiceName $null
Assert-True -Name 'XML-significant character in a path is escaped, not emitted raw' `
    -Condition ($ampersand -match 'R&amp;D')

Assert-True -Name 'Definition with an escaped path still parses as XML' `
    -Condition (Test-IsWellFormedXml -Xml $ampersand)

Assert-True -Name 'Escaped path round-trips back to its original value' `
    -Condition (([xml]$ampersand).service.workingdirectory -eq 'C:\Delta R&D')

# ---------------------------------------------------------------------------
# Rendering - unsubstituted token detection
# ---------------------------------------------------------------------------

Assert-True -Name 'Rendered definition retains no __DELTA_*__ tokens' `
    -Condition ($normal -notmatch '__DELTA_[A-Z0-9_]+__')

$tokenTemplate = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "delta-service-token-test-$([guid]::NewGuid().ToString('N')).xml"
try {
    Set-Content -LiteralPath $tokenTemplate -Value '<service><id>__DELTA_SERVICE_ID__</id><x>__DELTA_NOT_A_REAL_TOKEN__</x></service>' -Encoding utf8
    $threw = $false
    try {
        Get-DeltaServiceDefinitionContent -TemplatePath $tokenTemplate -AppRoot 'C:\DELTA' `
            -NodeExecutable 'C:\node.exe' -ServeCliPath 'C:\cli.js' -EnvPath 'C:\DELTA\.env' `
            -LogDirectory 'C:\DELTA\logs' -PostgresServiceName $null | Out-Null
    }
    catch {
        $threw = $true
    }
    Assert-True -Name 'An unsubstituted template token fails rendering loudly' -Condition $threw `
        -Detail 'A template placeholder with no matching replacement was silently emitted.'
}
finally {
    Remove-Item -LiteralPath $tokenTemplate -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# XML escaping helper
# ---------------------------------------------------------------------------

Assert-True -Name 'ConvertTo-DeltaServiceXmlText escapes all five XML entities' `
    -Condition ((ConvertTo-DeltaServiceXmlText -Value '<a&b"c''d>') -eq '&lt;a&amp;b&quot;c&apos;d&gt;')

Assert-True -Name 'ConvertTo-DeltaServiceXmlText handles an empty value' `
    -Condition ((ConvertTo-DeltaServiceXmlText -Value '') -eq '')

# ---------------------------------------------------------------------------
# Runtime state mapping
#
# Exercised through the same decision table Get-DeltaRuntimeState applies,
# against synthetic inputs - a live service, live processes, and a bound
# port cannot be conjured in a unit test, and the mapping is the part that
# actually encodes the design decisions worth protecting.
# ---------------------------------------------------------------------------

function Get-TestRuntimeStateName {
    param(
        [bool]$ServiceExists,
        [string]$ServiceStatus = 'Stopped',
        [bool]$ServiceDamaged,
        [int]$ProcessCount,
        [int]$LauncherCount,
        [bool]$PortOwnedByDelta,
        [AllowNull()][string]$UnrelatedPortOwner
    )

    $serviceRunning = ($ServiceExists -and $ServiceStatus -eq 'Running')

    if ($ServiceDamaged) { return 'Damaged' }
    if ($UnrelatedPortOwner -and $ProcessCount -eq 0) { return 'Conflicted' }
    if ($serviceRunning -and $ProcessCount -eq 0) { return 'Broken' }
    if ($ProcessCount -gt 0 -and $ServiceExists -and -not $serviceRunning) { return 'Broken' }
    if ($ProcessCount -eq 0 -and $LauncherCount -gt 0) { return 'Broken' }
    if ($ProcessCount -gt 0 -and $PortOwnedByDelta) { return 'Running' }
    if ($ProcessCount -gt 0) { return 'Starting' }
    if (-not $ServiceExists) { return 'NotInstalled' }
    return 'Stopped'
}

$stateCases = @(
    @{ Name = 'Healthy service-managed DELTA is Running';
       Args = @{ ServiceExists = $true; ServiceStatus = 'Running'; ProcessCount = 1; PortOwnedByDelta = $true }; Expected = 'Running' }

    @{ Name = 'Service running, process up, port not yet bound is Starting';
       Args = @{ ServiceExists = $true; ServiceStatus = 'Running'; ProcessCount = 1; PortOwnedByDelta = $false }; Expected = 'Starting' }

    @{ Name = 'Service Running with no DELTA process is Broken, never Running';
       Args = @{ ServiceExists = $true; ServiceStatus = 'Running'; ProcessCount = 0 }; Expected = 'Broken' }

    @{ Name = 'DELTA process with its service stopped is an unsupervised orphan (Broken)';
       Args = @{ ServiceExists = $true; ServiceStatus = 'Stopped'; ProcessCount = 1; PortOwnedByDelta = $true }; Expected = 'Broken' }

    @{ Name = 'Legacy launcher with no server process is Broken';
       Args = @{ ServiceExists = $false; ProcessCount = 0; LauncherCount = 1 }; Expected = 'Broken' }

    @{ Name = 'Registered service with missing files is Damaged';
       Args = @{ ServiceExists = $true; ServiceStatus = 'Stopped'; ServiceDamaged = $true }; Expected = 'Damaged' }

    @{ Name = 'Unrelated process on the configured port is Conflicted';
       Args = @{ ServiceExists = $true; ServiceStatus = 'Stopped'; ProcessCount = 0; UnrelatedPortOwner = 'nginx.exe (PID 42)' }; Expected = 'Conflicted' }

    @{ Name = 'Registered but stopped, nothing listening, is Stopped';
       Args = @{ ServiceExists = $true; ServiceStatus = 'Stopped'; ProcessCount = 0 }; Expected = 'Stopped' }

    @{ Name = 'No service and nothing running is NotInstalled';
       Args = @{ ServiceExists = $false; ProcessCount = 0 }; Expected = 'NotInstalled' }

    @{ Name = 'Legacy directly-launched DELTA with no service is Running (migration is detectable)';
       Args = @{ ServiceExists = $false; ProcessCount = 1; PortOwnedByDelta = $true }; Expected = 'Running' }
)

foreach ($case in $stateCases) {
    $caseArgs = $case.Args
    $actual = Get-TestRuntimeStateName @caseArgs
    Assert-True -Name $case.Name -Condition ($actual -eq $case.Expected) -Detail "Expected '$($case.Expected)', got '$actual'."
}

# ---------------------------------------------------------------------------
# Startup mode description
#
# Unlike the state mapping above, these call the real function directly - it
# is pure and needs no service, no registry, and no Administrator rights.
# What is protected here is that the displayed mode is the SCM's own
# StartType and nothing else. DELTA is configured for plain Automatic, so a
# delayed-start qualifier has no legitimate mode left to describe: a service
# still carrying that flag is drift the repair path corrects, and dressing it
# up as a supported mode on screen would present a problem as a setting.
# ---------------------------------------------------------------------------

$startModeCases = @(
    @{ Name = 'Automatic is described as Automatic'; StartType = 'Automatic'; Expected = 'Automatic' }
    @{ Name = 'Manual is described as Manual';       StartType = 'Manual';    Expected = 'Manual' }
    @{ Name = 'Disabled is described as Disabled';   StartType = 'Disabled';  Expected = 'Disabled' }

    @{ Name = 'An unknown start type is reported as Unknown rather than blank';
       StartType = ''; Expected = 'Unknown' }
)

foreach ($case in $startModeCases) {
    $actual = Get-DeltaServiceStartModeDescription -StartType $case.StartType
    Assert-True -Name $case.Name -Condition ($actual -eq $case.Expected) `
        -Detail "Expected '$($case.Expected)', got '$actual'."
}

# The status line an administrator reads must be exactly "(Running,
# Automatic)" / "(Stopped, Automatic)" - no delayed-start wording survives
# anywhere in the displayed mode.
foreach ($startType in @('Automatic', 'Manual', 'Disabled')) {
    Assert-True -Name "Startup mode description of $startType carries no delayed-start wording" `
        -Condition ((Get-DeltaServiceStartModeDescription -StartType $startType) -notmatch 'Delayed')
}

# ---------------------------------------------------------------------------
# Service definition file validity
#
# "The XML is present" and "the XML is usable" are different facts, and the
# difference is a service that fails at every boot for a reason no restart
# fixes. These run against real files in a temporary directory - the check
# parses a document, so a synthetic input would not exercise it at all.
# ---------------------------------------------------------------------------

$Script:DefinitionTestRoot = Join-Path -Path $env:TEMP -ChildPath "delta-service-tests-$PID"
New-Item -Path $Script:DefinitionTestRoot -ItemType Directory -Force | Out-Null

try {
    $validDefinitionPath = Join-Path -Path $Script:DefinitionTestRoot -ChildPath 'valid.xml'
    Set-Content -LiteralPath $validDefinitionPath -Value (New-TestDefinition -AppRoot 'C:\DeltaTest') -Encoding UTF8

    Assert-True -Name 'A rendered service definition is recognised as valid' `
        -Condition (Test-DeltaServiceDefinitionFile -Path $validDefinitionPath)

    $missingDefinitionPath = Join-Path -Path $Script:DefinitionTestRoot -ChildPath 'absent.xml'
    Assert-True -Name 'A missing definition file is not valid' `
        -Condition (-not (Test-DeltaServiceDefinitionFile -Path $missingDefinitionPath))

    # The realistic corruption: a write that stopped partway through.
    $truncatedDefinitionPath = Join-Path -Path $Script:DefinitionTestRoot -ChildPath 'truncated.xml'
    Set-Content -LiteralPath $truncatedDefinitionPath -Value '<service><id>DeltaApp</id>' -Encoding UTF8
    Assert-True -Name 'A truncated definition file is not valid' `
        -Condition (-not (Test-DeltaServiceDefinitionFile -Path $truncatedDefinitionPath))

    $emptyDefinitionPath = Join-Path -Path $Script:DefinitionTestRoot -ChildPath 'empty.xml'
    Set-Content -LiteralPath $emptyDefinitionPath -Value '' -Encoding UTF8
    Assert-True -Name 'An empty definition file is not valid' `
        -Condition (-not (Test-DeltaServiceDefinitionFile -Path $emptyDefinitionPath))

    # Well-formed XML that is not a service definition - a backup, an
    # unrelated config, anything that landed on the path by mistake.
    $wrongRootPath = Join-Path -Path $Script:DefinitionTestRoot -ChildPath 'wrong-root.xml'
    Set-Content -LiteralPath $wrongRootPath -Value '<configuration><service /></configuration>' -Encoding UTF8
    Assert-True -Name 'Well-formed XML that is not a <service> document is not valid' `
        -Condition (-not (Test-DeltaServiceDefinitionFile -Path $wrongRootPath))

    Assert-True -Name 'A null definition path is not valid rather than an error' `
        -Condition (-not (Test-DeltaServiceDefinitionFile -Path $null))
}
finally {
    Remove-Item -LiteralPath $Script:DefinitionTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Registered binary path comparison
#
# The SCM stores this path in a shape nobody types by hand. A quoting or
# casing difference must never be mistaken for "this registration belongs to
# another deployment", because that mistake costs a needless re-registration
# on every single run.
# ---------------------------------------------------------------------------

$expectedWrapperPath = 'C:\DELTA\service\DeltaApp.exe'

$binaryPathCases = @(
    @{ Name = 'Quoted ImagePath matching the expected wrapper is a match';
       Actual = '"C:\DELTA\service\DeltaApp.exe"'; Expected = $expectedWrapperPath; Match = $true }

    @{ Name = 'Unquoted ImagePath matching the expected wrapper is a match';
       Actual = 'C:\DELTA\service\DeltaApp.exe'; Expected = $expectedWrapperPath; Match = $true }

    @{ Name = 'Case differences are not a mismatch';
       Actual = '"c:\delta\SERVICE\deltaapp.exe"'; Expected = $expectedWrapperPath; Match = $true }

    @{ Name = 'Trailing arguments after a quoted path do not break the match';
       Actual = '"C:\DELTA\service\DeltaApp.exe" --run'; Expected = $expectedWrapperPath; Match = $true }

    @{ Name = 'A path with redundant separators still matches';
       Actual = '"C:\DELTA\service\..\service\DeltaApp.exe"'; Expected = $expectedWrapperPath; Match = $true }

    @{ Name = 'A registration pointing at another application root is a mismatch';
       Actual = '"D:\Apps\DELTA\service\DeltaApp.exe"'; Expected = $expectedWrapperPath; Match = $false }

    @{ Name = 'An unreadable ImagePath is not reported as a mismatch';
       Actual = ''; Expected = $expectedWrapperPath; Match = $true }
)

foreach ($case in $binaryPathCases) {
    $actual = Test-DeltaServiceBinaryPathMatch -BinaryPath $case.Actual -ExpectedPath $case.Expected
    Assert-True -Name $case.Name -Condition ($actual -eq $case.Match) `
        -Detail "Expected '$($case.Match)', got '$actual'."
}

# ---------------------------------------------------------------------------
# Repair condition detection
#
# What is wrong with the registration, named precisely. These call the real
# function - it is pure - and the ordering cases matter as much as the
# individual ones: several conditions can be true simultaneously, and which
# one is reported decides what the operator is asked.
# ---------------------------------------------------------------------------

function New-TestConditionArgs {
    <#
      A healthy, service-managed registration, as named overrides applied to
      it. Written this way so each case below states only what it changes,
      which is what makes the difference between cases readable.
    #>
    param([hashtable]$Override = @{})

    $baseline = @{
        ServiceInstalled  = $true
        ServiceStartType  = 'Automatic'
        # Plain Automatic - no delayed start. This is the supported
        # configuration, so it is what "healthy" means in every case below.
        DelayedAutoStart  = $false
        ExecutablePresent = $true
        DefinitionPresent = $true
        DefinitionValid   = $true
        BinaryPathMatches = $true
        ServiceAccount    = 'NT SERVICE\DeltaApp'
    }

    foreach ($key in $Override.Keys) {
        $baseline[$key] = $Override[$key]
    }
    return $baseline
}

$conditionCases = @(
    @{ Name = 'A healthy service-managed installation has no repair condition';
       Override = @{}; Expected = 'None' }

    @{ Name = 'No registration at all is Missing (the migration case)';
       Override = @{ ServiceInstalled = $false; ServiceStartType = ''; DelayedAutoStart = $false;
                     ExecutablePresent = $false; DefinitionPresent = $false; DefinitionValid = $false;
                     ServiceAccount = '' }; Expected = 'Missing' }

    @{ Name = 'A registration whose WinSW executable is gone is WrapperMissing';
       Override = @{ ExecutablePresent = $false }; Expected = 'WrapperMissing' }

    @{ Name = 'A registration whose definition file is gone is DefinitionMissing';
       Override = @{ DefinitionPresent = $false; DefinitionValid = $false }; Expected = 'DefinitionMissing' }

    @{ Name = 'A present-but-unparseable definition is DefinitionInvalid, not DefinitionMissing';
       Override = @{ DefinitionValid = $false }; Expected = 'DefinitionInvalid' }

    @{ Name = 'A registration pointing at another application root is WrongExecutablePath';
       Override = @{ BinaryPathMatches = $false }; Expected = 'WrongExecutablePath' }

    @{ Name = 'A service running as the wrong account is WrongIdentity';
       Override = @{ ServiceAccount = 'LocalSystem' }; Expected = 'WrongIdentity' }

    @{ Name = 'Service account casing alone is not a repair condition';
       Override = @{ ServiceAccount = 'nt service\deltaapp' }; Expected = 'None' }

    @{ Name = 'A disabled service is Disabled, never damage';
       Override = @{ ServiceStartType = 'Disabled' }; Expected = 'Disabled' }

    @{ Name = 'A manual-start service is StartTypeDrift';
       Override = @{ ServiceStartType = 'Manual' }; Expected = 'StartTypeDrift' }

    # The migration case for every deployment made by an earlier version of
    # this installer: the SCM reports Automatic, and only the separate
    # registry flag reveals that Windows is still deferring the start.
    @{ Name = 'Automatic WITH the delayed flag is StartTypeDrift';
       Override = @{ DelayedAutoStart = $true }; Expected = 'StartTypeDrift' }

    # Windows leaves DelayedAutostart behind when a service is switched away
    # from Automatic, so a stale flag must not turn an already-correct
    # diagnosis into a start-mode one - Disabled and Manual are still
    # reported as themselves.
    @{ Name = 'A stale delayed flag on a disabled service is still Disabled';
       Override = @{ ServiceStartType = 'Disabled'; DelayedAutoStart = $true }; Expected = 'Disabled' }

    @{ Name = 'A stale delayed flag on a manual service is still StartTypeDrift';
       Override = @{ ServiceStartType = 'Manual'; DelayedAutoStart = $true }; Expected = 'StartTypeDrift' }

    # Ordering. A damaged service that is also disabled must be reported as
    # damaged: the repair re-registers it, which restores the start type on
    # the way past, so asking about the start type first would be a question
    # whose answer changes nothing.
    @{ Name = 'Damage outranks a disabled start type';
       Override = @{ ExecutablePresent = $false; ServiceStartType = 'Disabled' }; Expected = 'WrapperMissing' }

    @{ Name = 'Damage outranks a wrong service account';
       Override = @{ DefinitionValid = $false; ServiceAccount = 'LocalSystem' }; Expected = 'DefinitionInvalid' }

    @{ Name = 'A wrong account outranks a disabled start type';
       Override = @{ ServiceAccount = 'LocalSystem'; ServiceStartType = 'Disabled' }; Expected = 'WrongIdentity' }
)

foreach ($case in $conditionCases) {
    $conditionArgs = New-TestConditionArgs -Override $case.Override
    $actual = Get-DeltaServiceRepairCondition @conditionArgs
    Assert-True -Name $case.Name -Condition ($actual -eq $case.Expected) `
        -Detail "Expected '$($case.Expected)', got '$actual'."
}

# ---------------------------------------------------------------------------
# Repair plan decisions
#
# The rule this whole feature rests on: a missing DeltaApp service is NOT a
# reason to update or reinstall DELTA. These cases are the guarantee that it
# stays true - and that the exceptions (a genuinely missing prerequisite, a
# port held by somebody else, a deliberately disabled service) each keep
# their own distinct, safe behaviour.
# ---------------------------------------------------------------------------

$planCases = @(
    @{ Name = 'A healthy service-managed installation plans no action at all';
       Args = @{ Condition = 'None' }; Action = 'None'; Confirm = $false }

    @{ Name = 'Valid existing deployment with no service is repaired in place, not updated';
       Args = @{ Condition = 'Missing'; PrerequisitesSatisfied = $true }; Action = 'Repair'; Confirm = $false }

    @{ Name = 'A legacy DELTA process running with no service is repaired, but only after confirmation';
       Args = @{ Condition = 'Missing'; PrerequisitesSatisfied = $true; RuntimeRunning = $true };
       Action = 'Repair'; Confirm = $true }

    @{ Name = 'A missing WinSW executable is repaired, not redeployed';
       Args = @{ Condition = 'WrapperMissing'; PrerequisitesSatisfied = $true }; Action = 'Repair'; Confirm = $false }

    @{ Name = 'A missing service definition is repaired, not redeployed';
       Args = @{ Condition = 'DefinitionMissing'; PrerequisitesSatisfied = $true }; Action = 'Repair'; Confirm = $false }

    @{ Name = 'An invalid service definition is repaired, not redeployed';
       Args = @{ Condition = 'DefinitionInvalid'; PrerequisitesSatisfied = $true }; Action = 'Repair'; Confirm = $false }

    @{ Name = 'A registration pointing elsewhere is repaired in place';
       Args = @{ Condition = 'WrongExecutablePath'; PrerequisitesSatisfied = $true }; Action = 'Repair'; Confirm = $false }

    @{ Name = 'A wrong service identity is repaired in place';
       Args = @{ Condition = 'WrongIdentity'; PrerequisitesSatisfied = $true }; Action = 'Repair'; Confirm = $false }

    # The minimum operation in the whole design: one sc.exe start-mode
    # change, decided without a prerequisite survey and without a restart.
    @{ Name = 'Start-type drift is corrected in place, without confirmation';
       Args = @{ Condition = 'StartTypeDrift'; PrerequisitesSatisfied = $true }; Action = 'Configure'; Confirm = $false }

    # The delayed-start migration, and the property that makes it safe to do
    # automatically on a production server: Configure never asks and never
    # restarts, so a DELTA that is serving keeps serving and its node.exe
    # keeps its PID. Any other action here would interrupt it.
    @{ Name = 'Delayed-start drift on a serving DELTA is corrected without confirmation or restart';
       Args = @{ Condition = 'StartTypeDrift'; PrerequisitesSatisfied = $true; RuntimeRunning = $true };
       Action = 'Configure'; Confirm = $false }

    @{ Name = 'A deliberately disabled service is never re-enabled without confirmation';
       Args = @{ Condition = 'Disabled'; PrerequisitesSatisfied = $true }; Action = 'Enable'; Confirm = $true }

    @{ Name = 'A service disabled by uninstall still requires confirmation to re-enable';
       Args = @{ Condition = 'Disabled'; PrerequisitesSatisfied = $true; DisabledByUninstall = $true };
       Action = 'Enable'; Confirm = $true }

    @{ Name = 'A genuinely incomplete deployment routes to the existing update flow';
       Args = @{ Condition = 'Missing'; PrerequisitesSatisfied = $false;
                 MissingPrerequisites = @('Node.js (node.exe could not be located)') };
       Action = 'Update'; Confirm = $true }

    @{ Name = 'An unrelated process on the DELTA port blocks the repair rather than resolving it';
       Args = @{ Condition = 'Missing'; PrerequisitesSatisfied = $true; UnrelatedPortOwner = 'nginx.exe (PID 42)' };
       Action = 'Blocked'; Confirm = $false }

    # A port conflict is reported even when the deployment is ALSO
    # incomplete: killing nothing and starting nothing is the safe answer
    # either way, and the conflict is the fact the operator has to act on.
    @{ Name = 'A port conflict outranks a missing prerequisite';
       Args = @{ Condition = 'Missing'; PrerequisitesSatisfied = $false;
                 MissingPrerequisites = @('Node.js (node.exe could not be located)');
                 UnrelatedPortOwner = 'nginx.exe (PID 42)' };
       Action = 'Blocked'; Confirm = $false }

    # A start-mode correction touches nothing a port owner could care about.
    @{ Name = 'A port conflict does not block a start-mode correction';
       Args = @{ Condition = 'StartTypeDrift'; PrerequisitesSatisfied = $true; UnrelatedPortOwner = 'nginx.exe (PID 42)' };
       Action = 'Configure'; Confirm = $false }
)

foreach ($case in $planCases) {
    $planArgs = $case.Args
    $plan = Get-DeltaServiceRepairPlan @planArgs
    Assert-True -Name $case.Name -Condition ($plan.Action -eq $case.Action) `
        -Detail "Expected action '$($case.Action)', got '$($plan.Action)'."
    Assert-True -Name "$($case.Name) - confirmation requirement" `
        -Condition ($plan.RequiresConfirmation -eq $case.Confirm) `
        -Detail "Expected RequiresConfirmation '$($case.Confirm)', got '$($plan.RequiresConfirmation)'."
}

# Idempotency, stated as the property that actually protects a healthy
# installation: once the service is registered, enabled, intact and
# correctly configured, a repeated run has no condition to act on and
# therefore nothing to re-register, rewrite, or restart.
$healthyArgs = New-TestConditionArgs
Assert-True -Name 'Repeated assessment of a repaired installation stays a no-op (idempotent)' `
    -Condition (
        ((Get-DeltaServiceRepairCondition @healthyArgs) -eq 'None') -and
        ((Get-DeltaServiceRepairPlan -Condition (Get-DeltaServiceRepairCondition @healthyArgs)).Action -eq 'None')
    )

# Running and Stopped are both healthy service-managed states - the SCM
# status is not an input to the repair decision at all, and must not become
# one: a stopped delayed-start service shortly after boot is normal.
Assert-True -Name 'A stopped but healthy service is not a repair condition' `
    -Condition ((Get-DeltaServiceRepairCondition @healthyArgs) -eq 'None')

# The disabled-by-uninstall marker changes the EXPLANATION, never the
# requirement to confirm - that distinction is the whole point of recording
# it, so it is asserted on the text rather than only on the action.
$uninstallDisabledPlan = Get-DeltaServiceRepairPlan -Condition 'Disabled' -PrerequisitesSatisfied $true -DisabledByUninstall $true
$operatorDisabledPlan  = Get-DeltaServiceRepairPlan -Condition 'Disabled' -PrerequisitesSatisfied $true

Assert-True -Name 'A service disabled by uninstall is explained as such' `
    -Condition (($uninstallDisabledPlan.Details -join ' ') -match 'uninstall')

Assert-True -Name 'A service disabled outside the installer is not blamed on an uninstall' `
    -Condition (($operatorDisabledPlan.Details -join ' ') -notmatch 'uninstall')

Assert-True -Name 'A service disabled outside the installer is described as possibly deliberate' `
    -Condition (($operatorDisabledPlan.Details -join ' ') -match 'deliberate')

# The blocked plan must name the owning process and must never suggest
# stopping it - this installer does not terminate processes it does not own.
$blockedPlan = Get-DeltaServiceRepairPlan -Condition 'Missing' -PrerequisitesSatisfied $true -UnrelatedPortOwner 'nginx.exe (PID 42)'
Assert-True -Name 'A blocked repair names the conflicting process' `
    -Condition (($blockedPlan.Details -join ' ') -match 'nginx\.exe \(PID 42\)')

Assert-True -Name 'A blocked repair reports the conflict rather than proposing to end it' `
    -Condition (($blockedPlan.Details -join ' ') -match 'left running untouched')

# The promise made to the operator in the repair screen, asserted as text:
# a missing service does not put their data, configuration or database at
# risk, and the screen has to say so.
$repairPlan = Get-DeltaServiceRepairPlan -Condition 'Missing' -PrerequisitesSatisfied $true
Assert-True -Name 'A repair tells the operator their application and data are not modified' `
    -Condition (($repairPlan.Details -join ' ') -match 'not modified')

Assert-True -Name 'A repair of a running DELTA warns that it will be restarted' `
    -Condition (
        ((Get-DeltaServiceRepairPlan -Condition 'Missing' -PrerequisitesSatisfied $true -RuntimeRunning $true).Details -join ' ') -match 'restarted'
    )

# The opposite promise, and the one the delayed-start migration depends on:
# a start-mode correction must state that DELTA is NOT restarted, because
# that is what makes it safe to apply automatically to a production server
# that is currently serving traffic.
$configurePlan = Get-DeltaServiceRepairPlan -Condition 'StartTypeDrift' -PrerequisitesSatisfied $true -RuntimeRunning $true
Assert-True -Name 'A start-mode correction states that DELTA is not restarted' `
    -Condition (($configurePlan.Details -join ' ') -match 'not restarted')

Assert-True -Name 'A start-mode correction targets plain Automatic' `
    -Condition (
        (($configurePlan.Details -join ' ') -match 'Automatic') -and
        (($configurePlan.Details -join ' ') -notmatch 'Delayed')
    )

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

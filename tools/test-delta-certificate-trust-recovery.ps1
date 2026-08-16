#Requires -Version 5.1
<#
.SYNOPSIS
    Validates the certificate-trust recovery around Phase 3's
    init_website.bat dependency installation (setup.ps1).

.DESCRIPTION
    When init_website.bat fails because npm/Yarn could not validate the
    package registry certificate - and ONLY then - setup.ps1 offers the
    administrator one retry with strict SSL certificate verification
    disabled. These cases pin down the whole of that behaviour:

      1. A successful run is completely untouched: no prompt, no
         configuration read or written, one execution.
      2. `unable to get local issuer certificate` raises the prompt.
      3. `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` raises the prompt.
      4. Declining (bare Enter, the default) preserves the ORIGINAL
         failure and changes no SSL setting.
      5. Accepting disables strict SSL for npm and Yarn and re-runs
         init_website.bat itself - never a hand-reproduced copy of the
         commands inside it.
      6. A successful retry lets the installation continue.
      7. A failing retry stops with the retry's own failure and never
         loops - not even when the retry ALSO reports a certificate
         error.
      8. ESOCKETTIMEDOUT (and DNS/timeout/generic install failures) must
         never raise the prompt.
      9. Pre-existing strict-ssl configuration is preserved: an explicit
         value is written back, a value that was never configured is
         deleted again rather than being invented as 'true', and an
         administrator who had already disabled strict-ssl before DELTA
         setup never has it changed or re-enabled.

    Runs entirely against stubs - no real npm, no real Yarn, no network,
    no Administrator rights - in the same style as
    tools\test-delta-install-retry.ps1 and
    tools\test-delta-installer-reuse.ps1. The functions under test are
    extracted from setup.ps1 by AST rather than dot-sourced (dot-sourcing
    it would run its whole orchestration block), so these cases exercise
    the real shipped bodies rather than copies that could drift from
    them. Only the process execution itself and npm are stubbed; the
    prompt is the real Read-DeltaYesNoConfirmation from
    lib\DeltaInstaller.Common.ps1, driven through a stubbed Read-Host, so
    the prompt text and its "blank means No" default are genuinely under
    test.

    Exits 0 if every case passes, 1 otherwise.

.EXAMPLE
    .\tools\test-delta-certificate-trust-recovery.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Common.ps1')

$Script:Failures = 0
$Script:Passes   = 0

# Write-Host is shadowed further down so the prompt's own text can be
# captured and asserted on. The reporting helpers therefore call the
# cmdlet by its fully qualified name, which no function can shadow.
function Assert-True {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail
    )
    if ($Condition) {
        Microsoft.PowerShell.Utility\Write-Host "[PASS] $Name" -ForegroundColor Green
        $Script:Passes++
    }
    else {
        Microsoft.PowerShell.Utility\Write-Host "[FAIL] $Name" -ForegroundColor Red
        if ($Detail) { Microsoft.PowerShell.Utility\Write-Host "       $Detail" -ForegroundColor Red }
        $Script:Failures++
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Expected,
        [AllowNull()]$Actual
    )
    Assert-True -Name $Name -Condition ("$Expected" -eq "$Actual") -Detail "Expected '$Expected' but got '$Actual'."
}

function Write-TestSection {
    param([Parameter(Mandatory)][string]$Title)
    Microsoft.PowerShell.Utility\Write-Host ''
    Microsoft.PowerShell.Utility\Write-Host "--- $Title ---"
    Microsoft.PowerShell.Utility\Write-Host ''
}

# ---------------------------------------------------------------------------
# The code under test, taken from setup.ps1 itself
# ---------------------------------------------------------------------------

function Import-FunctionFromScript {
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

function Import-ScriptVariableFromScript {
    <#
      The same idea for a top-level $Script:<name> = ... assignment, so
      the certificate-failure pattern list these cases assert on is the
      shipped one rather than a copy of it kept in this file.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$VariableName
    )

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw "$Path failed to parse: $(($errors | ForEach-Object { $_.Message }) -join '; ')"
    }

    $assignment = $ast.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq "Script:$VariableName"
        },
        $true
    ) | Select-Object -First 1

    if (-not $assignment) {
        throw "`$Script:$VariableName was not found in $Path."
    }

    return $assignment.Extent.Text
}

$Script:SetupScriptPath = Join-Path -Path $Script:ProjectRoot -ChildPath 'setup.ps1'

. ([scriptblock]::Create((Import-ScriptVariableFromScript -Path $Script:SetupScriptPath -VariableName 'DeltaCertificateTrustFailurePatterns')))
foreach ($functionName in @(
    'Show-Warning'
    'Test-DeltaCertificateTrustFailure'
    'Test-NpmAvailable'
    'Get-NpmStrictSslState'
    'Resolve-NpmStrictSslWorkaroundPlan'
    'Set-NpmStrictSslDisabled'
    'Restore-NpmStrictSslState'
    'Read-DeltaCertificateTrustWorkaroundConfirmation'
    'Invoke-DeltaWebsiteInitWithStrictSslDisabled'
    'Invoke-DeltaWebsiteInit'
)) {
    . ([scriptblock]::Create((Import-FunctionFromScript -Path $Script:SetupScriptPath -FunctionName $functionName)))
}

# ---------------------------------------------------------------------------
# Stubs
#
# Defined AFTER the dot-sources above so they shadow anything of the same
# name. Console output is captured rather than printed: what the operator
# is told (and asked) is part of the behaviour under test, and silence
# keeps the pass/fail list readable.
# ---------------------------------------------------------------------------

$Script:ConsoleLines = New-Object System.Collections.Generic.List[string]

function Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)][AllowNull()]$Object,
        $ForegroundColor,
        $BackgroundColor,
        [switch]$NoNewline
    )
    $Script:ConsoleLines.Add("$Object")
}

function Write-Step    { param([Parameter(Mandatory)][string]$Message) $Script:ConsoleLines.Add($Message) }
function Write-Detail  { param([Parameter(Mandatory)][string]$Message) $Script:ConsoleLines.Add($Message) }
function Write-Success { param([Parameter(Mandatory)][string]$Message) $Script:ConsoleLines.Add($Message) }

function Stop-Setup {
    param([Parameter(Mandatory)][string]$Message)
    throw "STOP-SETUP: $Message"
}

# The operator's answer to the single [y/N] prompt. $null means "the
# prompt must never be reached" - a scenario that reaches it anyway fails
# loudly instead of silently defaulting to No.
$Script:PromptAnswer = $null
$Script:PromptCount  = 0

function Read-Host {
    [CmdletBinding()]
    param([string]$Prompt, [switch]$AsSecureString)
    $Script:PromptCount++
    if ($null -eq $Script:PromptAnswer) {
        throw "Read-Host was reached unexpectedly (prompt: '$Prompt')."
    }
    return $Script:PromptAnswer
}

# Stand-in npm holding only what an administrator (or an earlier DELTA
# run) explicitly configured - which is precisely what the real `npm
# config list` prints, and what `npm config get` falls back to a default
# for when absent.
$Script:NpmConfig    = @{}
$Script:NpmDefaults  = @{ 'strict-ssl' = 'true' }
$Script:NpmCalls     = New-Object System.Collections.Generic.List[string]
$Script:NpmRejectSet = $false

function npm {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CommandArgs)

    $Script:NpmCalls.Add(($CommandArgs -join ' '))

    if ($CommandArgs.Count -ge 2 -and $CommandArgs[0] -eq 'config') {
        switch ($CommandArgs[1]) {
            'get' {
                $key = $CommandArgs[2]
                if ($Script:NpmConfig.ContainsKey($key))   { return $Script:NpmConfig[$key] }
                if ($Script:NpmDefaults.ContainsKey($key)) { return $Script:NpmDefaults[$key] }
                return 'undefined'
            }
            'set' {
                # $Script:NpmRejectSet models npm accepting the command
                # without the value actually taking effect (a read-only or
                # otherwise unwritable config), which is the case
                # Set-NpmStrictSslDisabled verifies by reading back rather
                # than trusting an exit code.
                if (-not $Script:NpmRejectSet) {
                    $Script:NpmConfig[$CommandArgs[2]] = $CommandArgs[3]
                }
                return
            }
            'delete' {
                $Script:NpmConfig.Remove($CommandArgs[2])
                return
            }
            'list' {
                # Shaped like the real thing: explicitly configured values
                # only, plus the comment lines npm always prints. Defaults
                # never appear here - that is what makes "was this set on
                # purpose?" answerable at all.
                $lines = New-Object System.Collections.Generic.List[string]
                $lines.Add('; "builtin" config from C:\Program Files\nodejs\node_modules\npm\npmrc')
                $lines.Add('')
                foreach ($key in $Script:NpmConfig.Keys) {
                    $lines.Add("$key = `"$($Script:NpmConfig[$key])`"")
                }
                $lines.Add('; node version = v24.18.0')
                return $lines.ToArray()
            }
        }
    }

    throw "Unexpected npm invocation: $($CommandArgs -join ' ')"
}

# Scripted init_website.bat runs. Each call consumes the next queued
# result (the last one repeats if asked again, which would itself be the
# symptom of an unbounded retry loop) and records the SSL configuration
# visible at the moment it ran - the only way to prove the workaround was
# actually in force for the retry rather than merely applied and undone
# around it.
$Script:ProcessResults = @()
$Script:ProcessCalls   = @()

function Invoke-DeltaWebsiteInitProcess {
    param([Parameter(Mandatory)][string]$InitWebsitePath)

    $index = $Script:ProcessCalls.Count
    $Script:ProcessCalls += [PSCustomObject]@{
        Path          = $InitWebsitePath
        NpmStrictSsl  = if ($Script:NpmConfig.ContainsKey('strict-ssl')) { $Script:NpmConfig['strict-ssl'] } else { $null }
        YarnStrictSsl = if (Test-Path -LiteralPath 'Env:\YARN_STRICT_SSL') { $env:YARN_STRICT_SSL } else { $null }
    }

    $result = $Script:ProcessResults[[Math]::Min($index, $Script:ProcessResults.Count - 1)]
    return [PSCustomObject]@{ ExitCode = $result.ExitCode; Output = $result.Output }
}

# ---------------------------------------------------------------------------
# Sandbox - Invoke-DeltaWebsiteInit's own existence check is real, so
# init_website.bat has to exist. The path contains spaces on purpose.
# ---------------------------------------------------------------------------

$Script:SandboxRoot      = Join-Path -Path (Get-Item -LiteralPath $env:TEMP).FullName -ChildPath "delta cert tests $([guid]::NewGuid().ToString('N'))"
$Script:DeltaRuntimeRoot = Join-Path -Path $Script:SandboxRoot -ChildPath 'DELTA runtime'
New-Item -Path $Script:DeltaRuntimeRoot -ItemType Directory -Force | Out-Null
Set-Content -LiteralPath (Join-Path -Path $Script:DeltaRuntimeRoot -ChildPath 'init_website.bat') -Value '@echo off' -Encoding Ascii

# ---------------------------------------------------------------------------
# Scenario driver
# ---------------------------------------------------------------------------

$Script:CertificateFailureOutput = @'
error An unexpected error occurred: "https://registry.yarnpkg.com/drizzle-orm: unable to get local issuer certificate".
info Visit https://yarnpkg.com/en/docs/cli/install for documentation about this command.
'@

$Script:CertificateFailureCodeOutput = @'
npm error code UNABLE_TO_GET_ISSUER_CERT_LOCALLY
npm error errno UNABLE_TO_GET_ISSUER_CERT_LOCALLY
npm error request to https://registry.npmjs.org/yarn failed, reason: unable to verify the first certificate
'@

$Script:TimeoutFailureOutput = @'
error An unexpected error occurred: "https://registry.yarnpkg.com/drizzle-orm/-/drizzle-orm-0.45.2.tgz: ESOCKETTIMEDOUT".
Error: Failed to install dependencies with yarn.
'@

function Invoke-WebsiteInitScenario {
    <#
      Runs Invoke-DeltaWebsiteInit against a scripted sequence of
      init_website.bat results and a scripted operator answer, returning
      everything the run did.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Results,
        # Deliberately untyped: $null has to survive as $null here (it is
        # what makes "this scenario must never reach the prompt"
        # enforceable), and a [string] parameter would quietly turn it
        # into '' - which the prompt would read as a valid "No".
        $Answer = $null,
        [hashtable]$ExistingNpmConfig = @{},
        [switch]$NpmRejectsSet
    )

    $Script:ConsoleLines.Clear()
    $Script:NpmCalls.Clear()
    $Script:ProcessCalls = @()
    $Script:ProcessResults = $Results
    $Script:PromptAnswer   = $Answer
    $Script:PromptCount    = 0
    $Script:NpmConfig      = @{}
    $Script:NpmRejectSet   = [bool]$NpmRejectsSet
    foreach ($key in $ExistingNpmConfig.Keys) { $Script:NpmConfig[$key] = $ExistingNpmConfig[$key] }
    Remove-Item -LiteralPath 'Env:\YARN_STRICT_SSL' -ErrorAction SilentlyContinue

    $threw   = $false
    $message = $null
    try {
        Invoke-DeltaWebsiteInit
    }
    catch {
        $threw   = $true
        $message = $_.Exception.Message
    }

    return [PSCustomObject]@{
        Threw            = $threw
        Message          = $message
        Prompts          = $Script:PromptCount
        Runs             = [object[]]$Script:ProcessCalls
        NpmCalls         = @($Script:NpmCalls)
        NpmConfig        = $Script:NpmConfig.Clone()
        Console          = ($Script:ConsoleLines -join "`n")
        YarnStrictSslNow = if (Test-Path -LiteralPath 'Env:\YARN_STRICT_SSL') { $env:YARN_STRICT_SSL } else { $null }
    }
}

$Script:OriginalFailureMessage = 'STOP-SETUP: init_website.bat failed with exit code 1. See its output above for details.'

# ---------------------------------------------------------------------------
# 1. A successful run is untouched
# ---------------------------------------------------------------------------

Write-TestSection -Title '1. Successful init_website.bat run'

$r = Invoke-WebsiteInitScenario -Results @(@{ ExitCode = 0; Output = 'Installation complete!' }) -Answer $null
Assert-True  -Name 'Success: installation continues (no failure raised)' -Condition (-not $r.Threw) -Detail $r.Message
Assert-Equal -Name 'Success: init_website.bat ran exactly once' -Expected 1 -Actual $r.Runs.Count
Assert-Equal -Name 'Success: the administrator is never prompted' -Expected 0 -Actual $r.Prompts
Assert-Equal -Name 'Success: npm configuration is never even read' -Expected 0 -Actual $r.NpmCalls.Count
Assert-True  -Name 'Success: no strict SSL configuration was written' -Condition (-not $r.NpmConfig.ContainsKey('strict-ssl'))
Assert-True  -Name 'Success: YARN_STRICT_SSL was never left behind' -Condition ($null -eq $r.YarnStrictSslNow)
Assert-True  -Name 'Success: reports dependencies installed' -Condition ($r.Console -match 'Runtime dependencies installed')

# ---------------------------------------------------------------------------
# 2 & 3. Recognized certificate failures raise the prompt
# ---------------------------------------------------------------------------

Write-TestSection -Title '2/3. Certificate trust failures raise the recovery prompt'

$r = Invoke-WebsiteInitScenario -Results @(@{ ExitCode = 1; Output = $Script:CertificateFailureOutput }) -Answer ''
Assert-Equal -Name "'unable to get local issuer certificate': the recovery prompt appears" -Expected 1 -Actual $r.Prompts

$promptText = $r.Console
$requiredPromptLines = @(
    'A certificate trust error was detected while downloading DELTA dependencies.'
    'The current network environment may prevent npm/Yarn from validating'
    'the package registry certificate.'
    'DELTA can retry the dependency installation with strict SSL certificate'
    'verification disabled.'
    'Disabling certificate verification reduces the security of package'
    'downloads and should only be used if you trust the current network.'
    'Disable strict SSL verification and retry?'
)
foreach ($line in $requiredPromptLines) {
    Assert-True -Name "Prompt text includes: $line" -Condition ($promptText -like "*$line*") -Detail "Prompt was:`n$promptText"
}
Assert-True -Name 'Prompt is presented as a warning' -Condition ($promptText -match 'WARNING')

$r = Invoke-WebsiteInitScenario -Results @(@{ ExitCode = 1; Output = $Script:CertificateFailureCodeOutput }) -Answer ''
Assert-Equal -Name "'UNABLE_TO_GET_ISSUER_CERT_LOCALLY': the recovery prompt appears" -Expected 1 -Actual $r.Prompts

# Mixed output - a certificate error alongside unrelated noise - still
# counts, since the certificate failure is the one that can be recovered.
$r = Invoke-WebsiteInitScenario -Results @(@{ ExitCode = 1; Output = "warning ESOCKETTIMEDOUT`nerror unable to get local issuer certificate" }) -Answer ''
Assert-Equal -Name 'Certificate error mixed with unrelated warnings: prompt still appears' -Expected 1 -Actual $r.Prompts

# ---------------------------------------------------------------------------
# 4. Declining preserves the original failure
# ---------------------------------------------------------------------------

Write-TestSection -Title '4. Administrator declines the workaround'

foreach ($declineAnswer in @('', 'n', 'N', 'no', 'anything else')) {
    $r = Invoke-WebsiteInitScenario -Results @(@{ ExitCode = 1; Output = $Script:CertificateFailureOutput }) -Answer $declineAnswer
    $label = if ($declineAnswer -eq '') { '<Enter>' } else { $declineAnswer }
    Assert-True  -Name "Declined ($label): the original failure is preserved verbatim" `
        -Condition ($r.Threw -and $r.Message -eq $Script:OriginalFailureMessage) -Detail "Actual: $($r.Message)"
    Assert-Equal -Name "Declined ($label): init_website.bat is never retried" -Expected 1 -Actual $r.Runs.Count
    Assert-Equal -Name "Declined ($label): npm configuration is never touched" -Expected 0 -Actual $r.NpmCalls.Count
    Assert-True  -Name "Declined ($label): no strict SSL setting was changed" `
        -Condition ((-not $r.NpmConfig.ContainsKey('strict-ssl')) -and $null -eq $r.YarnStrictSslNow)
}

$r = Invoke-WebsiteInitScenario -Results @(@{ ExitCode = 1; Output = $Script:CertificateFailureOutput }) -Answer ''
Assert-True -Name 'Declined: the operator is told verification was left enabled' `
    -Condition ($r.Console -match 'left enabled')

# ---------------------------------------------------------------------------
# 5 & 6. Accepting disables strict SSL and retries once
# ---------------------------------------------------------------------------

Write-TestSection -Title '5/6. Administrator accepts - one retry, which succeeds'

$r = Invoke-WebsiteInitScenario -Results @(
    @{ ExitCode = 1; Output = $Script:CertificateFailureOutput }
    @{ ExitCode = 0; Output = 'Installation complete!' }
) -Answer 'y'

Assert-True  -Name 'Accepted: strict-ssl was set to false' -Condition (($r.NpmCalls -join '|') -match 'config set strict-ssl false')
Assert-Equal -Name 'Accepted: init_website.bat ran exactly twice' -Expected 2 -Actual $r.Runs.Count
Assert-Equal -Name 'Accepted: the retry ran with npm strict-ssl disabled' -Expected 'false' -Actual $r.Runs[1].NpmStrictSsl
Assert-Equal -Name 'Accepted: the retry ran with YARN_STRICT_SSL=false' -Expected 'false' -Actual $r.Runs[1].YarnStrictSsl
Assert-Equal -Name 'Accepted: the first run was NOT affected by the workaround' -Expected $null -Actual $r.Runs[0].YarnStrictSsl
Assert-True  -Name 'Accepted: the retry runs the same init_website.bat, not a reproduction of it' `
    -Condition ($r.Runs[1].Path -eq $r.Runs[0].Path -and $r.Runs[1].Path -like '*init_website.bat')
Assert-Equal -Name 'Accepted: prompted exactly once' -Expected 1 -Actual $r.Prompts

Assert-True  -Name 'Retry succeeded: installation continues' -Condition (-not $r.Threw) -Detail $r.Message
Assert-True  -Name 'Retry succeeded: reports dependencies installed' -Condition ($r.Console -match 'Runtime dependencies installed')
Assert-True  -Name 'Retry succeeded: strict-ssl was removed again afterwards' -Condition (-not $r.NpmConfig.ContainsKey('strict-ssl'))
Assert-True  -Name 'Retry succeeded: YARN_STRICT_SSL was removed again afterwards' -Condition ($null -eq $r.YarnStrictSslNow)

$r = Invoke-WebsiteInitScenario -Results @(
    @{ ExitCode = 1; Output = $Script:CertificateFailureOutput }
    @{ ExitCode = 0; Output = 'Installation complete!' }
) -Answer 'Y'
Assert-Equal -Name "Accepted with 'Y': the retry still runs" -Expected 2 -Actual $r.Runs.Count

# ---------------------------------------------------------------------------
# 7. A failing retry stops - and never loops
# ---------------------------------------------------------------------------

Write-TestSection -Title '7. Retry fails'

$r = Invoke-WebsiteInitScenario -Results @(
    @{ ExitCode = 1; Output = $Script:CertificateFailureOutput }
    @{ ExitCode = 2; Output = "error Failed to install dependencies with yarn." }
) -Answer 'y'
Assert-True  -Name 'Retry failed: the installer stops' -Condition $r.Threw
Assert-Equal -Name "Retry failed: reports the retry's own failure" `
    -Expected 'STOP-SETUP: init_website.bat failed with exit code 2 after retrying with strict SSL certificate verification disabled. See its output above for details.' `
    -Actual $r.Message
Assert-Equal -Name 'Retry failed: exactly two runs, never a third' -Expected 2 -Actual $r.Runs.Count
Assert-True  -Name 'Retry failed: strict-ssl is still restored' -Condition (-not $r.NpmConfig.ContainsKey('strict-ssl'))
Assert-True  -Name 'Retry failed: YARN_STRICT_SSL is still removed' -Condition ($null -eq $r.YarnStrictSslNow)

# The loop-proofing case: the retry reports the SAME certificate error.
# Recovery must not be offered a second time.
$r = Invoke-WebsiteInitScenario -Results @(
    @{ ExitCode = 1; Output = $Script:CertificateFailureOutput }
    @{ ExitCode = 1; Output = $Script:CertificateFailureOutput }
) -Answer 'y'
Assert-Equal -Name 'Retry fails with the same certificate error: still exactly two runs' -Expected 2 -Actual $r.Runs.Count
Assert-Equal -Name 'Retry fails with the same certificate error: prompted only once' -Expected 1 -Actual $r.Prompts
Assert-True  -Name 'Retry fails with the same certificate error: installer stops' -Condition $r.Threw

# ---------------------------------------------------------------------------
# 8. Unrelated failures never raise the prompt
# ---------------------------------------------------------------------------

Write-TestSection -Title '8. Non-certificate failures'

$unrelatedFailures = @(
    @{ Name = 'ESOCKETTIMEDOUT';              Output = $Script:TimeoutFailureOutput }
    @{ Name = 'connection timeout';           Output = 'error Error: connect ETIMEDOUT 104.16.24.35:443' }
    @{ Name = 'DNS failure';                  Output = 'npm error code ENOTFOUND`nnpm error syscall getaddrinfo' }
    @{ Name = 'generic install failure';      Output = 'Error: Failed to install dependencies with yarn.' }
    @{ Name = 'registry 404';                 Output = 'error An unexpected error occurred: "https://registry.yarnpkg.com/nope: Not found".' }
    @{ Name = 'yarn missing from PATH';       Output = 'Error: Yarn is not recognized. Ensure it installed correctly.' }
    @{ Name = 'no output at all';             Output = '' }
)

foreach ($case in $unrelatedFailures) {
    # $Answer stays $null: reaching the prompt at all throws inside the
    # Read-Host stub, so these can never pass by accidentally answering No.
    $r = Invoke-WebsiteInitScenario -Results @(@{ ExitCode = 1; Output = $case.Output }) -Answer $null
    Assert-Equal -Name "$($case.Name): the certificate prompt never appears" -Expected 0 -Actual $r.Prompts
    Assert-True  -Name "$($case.Name): the original failure is reported unchanged" `
        -Condition ($r.Threw -and $r.Message -eq $Script:OriginalFailureMessage) -Detail "Actual: $($r.Message)"
    Assert-Equal -Name "$($case.Name): init_website.bat is never retried" -Expected 1 -Actual $r.Runs.Count
    Assert-Equal -Name "$($case.Name): npm configuration is never touched" -Expected 0 -Actual $r.NpmCalls.Count
}

# ---------------------------------------------------------------------------
# 9. Existing strict-ssl configuration is preserved
# ---------------------------------------------------------------------------

Write-TestSection -Title '9. Existing strict-ssl configuration'

# 9a. Explicitly configured 'true' -> written back exactly as it was.
$r = Invoke-WebsiteInitScenario -Results @(
    @{ ExitCode = 1; Output = $Script:CertificateFailureOutput }
    @{ ExitCode = 0; Output = 'Installation complete!' }
) -Answer 'y' -ExistingNpmConfig @{ 'strict-ssl' = 'true' }
Assert-Equal -Name "Pre-existing strict-ssl=true: restored to 'true' after the retry" -Expected 'true' -Actual $r.NpmConfig['strict-ssl']
Assert-Equal -Name 'Pre-existing strict-ssl=true: disabled while the retry ran' -Expected 'false' -Actual $r.Runs[1].NpmStrictSsl
Assert-True  -Name 'Pre-existing strict-ssl=true: restored by setting it, never by deleting it' `
    -Condition (($r.NpmCalls -join '|') -notmatch 'config delete strict-ssl')

# 9b. Explicit 'true' with a FAILING retry -> still restored.
$r = Invoke-WebsiteInitScenario -Results @(
    @{ ExitCode = 1; Output = $Script:CertificateFailureOutput }
    @{ ExitCode = 1; Output = 'error Failed to install dependencies with yarn.' }
) -Answer 'y' -ExistingNpmConfig @{ 'strict-ssl' = 'true' }
Assert-Equal -Name 'Pre-existing strict-ssl=true: restored even when the retry fails' -Expected 'true' -Actual $r.NpmConfig['strict-ssl']

# 9c. Already disabled before DELTA setup -> never changed, never re-enabled.
$r = Invoke-WebsiteInitScenario -Results @(
    @{ ExitCode = 1; Output = $Script:CertificateFailureOutput }
    @{ ExitCode = 0; Output = 'Installation complete!' }
) -Answer 'y' -ExistingNpmConfig @{ 'strict-ssl' = 'false' }
Assert-Equal -Name 'Already disabled: left disabled afterwards (never re-enabled)' -Expected 'false' -Actual $r.NpmConfig['strict-ssl']
Assert-True  -Name 'Already disabled: npm configuration is never written' `
    -Condition (($r.NpmCalls -join '|') -notmatch 'config (set|delete) strict-ssl') -Detail ($r.NpmCalls -join ' | ')
Assert-Equal -Name 'Already disabled: the retry still runs' -Expected 2 -Actual $r.Runs.Count
Assert-True  -Name 'Already disabled: the operator is told the setting was left alone' `
    -Condition ($r.Console -match 'already disabled')

# 9d. npm accepts the command but the value does not take -> the retry
# still happens, the operator is told, and nothing is left behind.
$r = Invoke-WebsiteInitScenario -Results @(
    @{ ExitCode = 1; Output = $Script:CertificateFailureOutput }
    @{ ExitCode = 0; Output = 'Installation complete!' }
) -Answer 'y' -NpmRejectsSet
Assert-True  -Name 'strict-ssl change refused: the operator is told it did not take' `
    -Condition ($r.Console -match 'did not accept')
Assert-Equal -Name 'strict-ssl change refused: the retry still runs (Yarn may still succeed)' -Expected 2 -Actual $r.Runs.Count
Assert-Equal -Name 'strict-ssl change refused: the retry still ran with YARN_STRICT_SSL=false' -Expected 'false' -Actual $r.Runs[1].YarnStrictSsl
Assert-True  -Name 'strict-ssl change refused: nothing is left behind in npm config' -Condition (-not $r.NpmConfig.ContainsKey('strict-ssl'))

# 9e. Unrelated npm settings are never disturbed.
$r = Invoke-WebsiteInitScenario -Results @(
    @{ ExitCode = 1; Output = $Script:CertificateFailureOutput }
    @{ ExitCode = 0; Output = 'Installation complete!' }
) -Answer 'y' -ExistingNpmConfig @{ 'prefix' = 'C:\Users\Administrator\AppData\Roaming\npm'; 'registry' = 'https://registry.npmjs.org/' }
Assert-Equal -Name 'Unrelated npm settings: prefix untouched' -Expected 'C:\Users\Administrator\AppData\Roaming\npm' -Actual $r.NpmConfig['prefix']
Assert-Equal -Name 'Unrelated npm settings: registry untouched' -Expected 'https://registry.npmjs.org/' -Actual $r.NpmConfig['registry']
Assert-True  -Name 'Unrelated npm settings: strict-ssl removed again (it was never configured)' -Condition (-not $r.NpmConfig.ContainsKey('strict-ssl'))

# ---------------------------------------------------------------------------
# Unit-level decision tables
# ---------------------------------------------------------------------------

Write-TestSection -Title 'Test-DeltaCertificateTrustFailure decision table'

$detectionCases = @(
    [PSCustomObject]@{ Expected = $true;  Name = 'unable to get local issuer certificate';        Text = 'error ...: unable to get local issuer certificate' }
    [PSCustomObject]@{ Expected = $true;  Name = 'UNABLE_TO_GET_ISSUER_CERT_LOCALLY';             Text = 'npm error code UNABLE_TO_GET_ISSUER_CERT_LOCALLY' }
    [PSCustomObject]@{ Expected = $true;  Name = 'unable_to_get_issuer_cert_locally (lowercase)'; Text = 'reason: unable_to_get_issuer_cert_locally' }
    [PSCustomObject]@{ Expected = $true;  Name = 'Unable To Get Local Issuer Certificate (mixed case)'; Text = 'Unable To Get Local Issuer Certificate' }
    [PSCustomObject]@{ Expected = $true;  Name = 'self signed certificate in certificate chain';  Text = 'error self signed certificate in certificate chain' }
    [PSCustomObject]@{ Expected = $true;  Name = 'SELF_SIGNED_CERT_IN_CHAIN';                     Text = 'npm error code SELF_SIGNED_CERT_IN_CHAIN' }
    [PSCustomObject]@{ Expected = $false; Name = 'ESOCKETTIMEDOUT';                               Text = 'error ...drizzle-orm-0.45.2.tgz: ESOCKETTIMEDOUT' }
    [PSCustomObject]@{ Expected = $false; Name = 'ETIMEDOUT';                                     Text = 'Error: connect ETIMEDOUT 104.16.24.35:443' }
    [PSCustomObject]@{ Expected = $false; Name = 'ENOTFOUND (DNS)';                               Text = 'npm error code ENOTFOUND' }
    [PSCustomObject]@{ Expected = $false; Name = 'generic dependency failure';                    Text = 'Error: Failed to install dependencies with yarn.' }
    [PSCustomObject]@{ Expected = $false; Name = 'the word certificate on its own';               Text = 'checking certificate pinning configuration' }
    [PSCustomObject]@{ Expected = $false; Name = 'empty output';                                  Text = '' }
    [PSCustomObject]@{ Expected = $false; Name = 'whitespace-only output';                        Text = "  `n  " }
)

foreach ($case in $detectionCases) {
    $actual = Test-DeltaCertificateTrustFailure -OutputText $case.Text
    Assert-True -Name "Detection - $($case.Name) -> $($case.Expected)" -Condition ($actual -eq $case.Expected) -Detail "Expected $($case.Expected), got $actual"
}

Assert-True -Name 'Detection: null output is not a certificate failure' -Condition (-not (Test-DeltaCertificateTrustFailure -OutputText $null))

Write-TestSection -Title 'Resolve-NpmStrictSslWorkaroundPlan decision table'

$planCases = @(
    [PSCustomObject]@{
        Name     = 'npm unavailable -> nothing is changed or restored'
        Args     = @{ NpmAvailable = $false; EffectiveValue = $null; IsExplicitlyConfigured = $false }
        Expected = @{ NeedsChange = $false; RestoreAction = 'None'; RestoreValue = $null }
    }
    [PSCustomObject]@{
        Name     = 'default (never configured) -> change, then delete the key again'
        Args     = @{ NpmAvailable = $true; EffectiveValue = 'true'; IsExplicitlyConfigured = $false }
        Expected = @{ NeedsChange = $true; RestoreAction = 'Delete'; RestoreValue = $null }
    }
    [PSCustomObject]@{
        Name     = "explicitly configured 'true' -> change, then write 'true' back"
        Args     = @{ NpmAvailable = $true; EffectiveValue = 'true'; IsExplicitlyConfigured = $true }
        Expected = @{ NeedsChange = $true; RestoreAction = 'Set'; RestoreValue = 'true' }
    }
    [PSCustomObject]@{
        Name     = 'already disabled -> never changed, never restored'
        Args     = @{ NpmAvailable = $true; EffectiveValue = 'false'; IsExplicitlyConfigured = $true }
        Expected = @{ NeedsChange = $false; RestoreAction = 'None'; RestoreValue = $null }
    }
    [PSCustomObject]@{
        Name     = 'already disabled with odd casing/whitespace -> still never changed'
        Args     = @{ NpmAvailable = $true; EffectiveValue = ' False '; IsExplicitlyConfigured = $true }
        Expected = @{ NeedsChange = $false; RestoreAction = 'None'; RestoreValue = $null }
    }
    [PSCustomObject]@{
        Name     = 'value unreadable -> change, then delete rather than invent a value'
        Args     = @{ NpmAvailable = $true; EffectiveValue = $null; IsExplicitlyConfigured = $false }
        Expected = @{ NeedsChange = $true; RestoreAction = 'Delete'; RestoreValue = $null }
    }
)

foreach ($case in $planCases) {
    $caseArgs = $case.Args
    $plan = Resolve-NpmStrictSslWorkaroundPlan @caseArgs
    Assert-Equal -Name "Plan - $($case.Name) [NeedsChange]"   -Expected $case.Expected.NeedsChange   -Actual $plan.NeedsChange
    Assert-Equal -Name "Plan - $($case.Name) [RestoreAction]" -Expected $case.Expected.RestoreAction -Actual $plan.RestoreAction
    Assert-Equal -Name "Plan - $($case.Name) [RestoreValue]"  -Expected $case.Expected.RestoreValue  -Actual $plan.RestoreValue
}

Write-TestSection -Title 'Get-NpmStrictSslState'

$Script:NpmConfig = @{}
$state = Get-NpmStrictSslState
Assert-True  -Name 'State: npm reported as available' -Condition $state.Available
Assert-Equal -Name "State: unconfigured strict-ssl reads npm's default" -Expected 'true' -Actual $state.EffectiveValue
Assert-True  -Name 'State: unconfigured strict-ssl is not reported as explicitly configured' -Condition (-not $state.IsExplicitlyConfigured)

$Script:NpmConfig = @{ 'strict-ssl' = 'false' }
$state = Get-NpmStrictSslState
Assert-Equal -Name 'State: configured strict-ssl value is read back' -Expected 'false' -Actual $state.EffectiveValue
Assert-True  -Name 'State: configured strict-ssl is reported as explicitly configured' -Condition $state.IsExplicitlyConfigured

$Script:NpmConfig = @{ 'prefix' = 'C:\npm' }
$state = Get-NpmStrictSslState
Assert-True -Name 'State: an unrelated configured key is not mistaken for strict-ssl' -Condition (-not $state.IsExplicitlyConfigured)

# ---------------------------------------------------------------------------

Remove-Item -LiteralPath $Script:SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue

Microsoft.PowerShell.Utility\Write-Host ''
if ($Script:Failures -eq 0) {
    Microsoft.PowerShell.Utility\Write-Host "All $($Script:Passes) certificate-trust recovery test cases passed." -ForegroundColor Green
    exit 0
}
else {
    Microsoft.PowerShell.Utility\Write-Host "$($Script:Failures) of $($Script:Passes + $Script:Failures) certificate-trust recovery test case(s) FAILED." -ForegroundColor Red
    exit 1
}

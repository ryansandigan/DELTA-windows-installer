#Requires -Version 5.1
<#
.SYNOPSIS
    Validates how the installer keeps PUBLIC_URL and PORT consistent when
    the DELTA backend port changes, and that it never touches a
    PUBLIC_URL it does not own.

.DESCRIPTION
    .env.example ships PUBLIC_URL="http://localhost:3000" alongside
    PORT="3000", so the shipped default describes the local Node listener
    directly. When Resolve-DeltaApplicationPort (setup.ps1) has to move
    DELTA onto a different port because the configured one is occupied,
    that default would otherwise be left naming a port nothing is
    listening on.

    The rule under test, implemented by Resolve-DeltaLocalhostPublicUrlSync
    and applied by Update-DeltaBackendPortEnvironment (both in
    lib\DeltaInstaller.Common.ps1), is deliberately narrow: PUBLIC_URL
    follows PORT only while it is still recognizably the installer's own
    localhost form for the port .env described before the change. Any
    other value - a real public domain, an https URL, a localhost URL
    carrying a path or query - is an operator/reverse-proxy decision and
    survives the port move untouched, because PUBLIC_URL is the
    externally meaningful base address while PORT is only what Node
    binds, and behind NGINX/IIS those are legitimately different.

    Everything here runs against temporary .env files and the repository's
    own .env.example - no installed DELTA runtime, no live ports, no
    registry, and setup.ps1 itself is never dot-sourced (that would run
    the installer). The production write path is exercised directly
    rather than reimplemented, so a change to the rule that this file
    does not agree with fails here.

    Exits 0 if every case matches its expected result, 1 otherwise.

.EXAMPLE
    .\tools\test-delta-public-url-port-sync.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = if ($PSScriptRoot) { Split-Path -Path $PSScriptRoot -Parent } else { (Get-Location).Path }
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Common.ps1')

$Script:EnvTemplatePath = Join-Path -Path $Script:ProjectRoot -ChildPath '.env.example'

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

$Script:Failures = 0
$Script:Total = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Expected,
        [AllowNull()]$Actual
    )

    $Script:Total++

    # $null and '' are distinct outcomes here - "leave PUBLIC_URL alone"
    # versus "write an empty value" are not the same answer - so they are
    # compared as such rather than through PowerShell's own -eq.
    $expectedIsNull = ($null -eq $Expected)
    $actualIsNull = ($null -eq $Actual)
    $passed = if ($expectedIsNull -or $actualIsNull) { $expectedIsNull -and $actualIsNull } else { $Expected -ceq $Actual }

    if ($passed) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    else {
        $Script:Failures++
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host "       Expected : $(if ($expectedIsNull) { '<null>' } else { "'$Expected'" })"
        Write-Host "       Actual   : $(if ($actualIsNull) { '<null>' } else { "'$Actual'" })"
    }
}

# One directory per run, removed at the end - the .env files below are
# scratch, and Update-DeltaBackendPortEnvironment also drops a timestamped
# .bak beside each one (Backup-DeltaEnvironmentFile), so leaving them
# behind would accumulate on every run.
$Script:TempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("delta-env-test-" + [guid]::NewGuid().ToString('n'))
New-Item -Path $Script:TempRoot -ItemType Directory -Force | Out-Null

function New-TestEnvFile {
    <#
      Writes $Lines to a fresh temporary .env and returns its path. Each
      case gets its own subdirectory so the timestamped backups
      Update-DeltaBackendPortEnvironment takes can never collide between
      cases.
    #>
    # AllowEmptyString because a real .env is full of blank lines, and
    # preserving them is part of what these cases verify.
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)

    $directory = Join-Path -Path $Script:TempRoot -ChildPath ([guid]::NewGuid().ToString('n'))
    New-Item -Path $directory -ItemType Directory -Force | Out-Null

    $path = Join-Path -Path $directory -ChildPath '.env'
    Set-Content -LiteralPath $path -Value $Lines -Encoding utf8
    return $path
}

function Invoke-PortChange {
    <#
      The production write path, with Write-Host output (the backup
      notice) suppressed via the information stream so test output stays
      readable.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$PreviousPort,
        [Parameter(Mandatory)][int]$NewPort
    )

    return Update-DeltaBackendPortEnvironment -Path $Path -PreviousPort $PreviousPort -NewPort $NewPort 6>$null
}

function Write-TestGroup {
    param([Parameter(Mandatory)][string]$Name)
    Write-Host ''
    Write-Host "--- $Name" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 1. The shipped template's own defaults
# ---------------------------------------------------------------------------

Write-TestGroup '1. .env.example defaults'

Assert-Equal -Name '.env.example ships PUBLIC_URL="http://localhost:3000"' `
    -Expected 'http://localhost:3000' `
    -Actual (Get-EnvFileValue -Path $Script:EnvTemplatePath -Key 'PUBLIC_URL')

Assert-Equal -Name '.env.example ships PORT="3000"' `
    -Expected '3000' `
    -Actual (Get-EnvFileValue -Path $Script:EnvTemplatePath -Key 'PORT')

# The two defaults must describe the same listener - that agreement is
# the whole reason the synchronization rule below has to exist.
Assert-Equal -Name '.env.example PUBLIC_URL and PORT describe the same listener' `
    -Expected (Get-DeltaLocalhostPublicUrl -Port ([int](Get-EnvFileValue -Path $Script:EnvTemplatePath -Key 'PORT'))) `
    -Actual (Get-EnvFileValue -Path $Script:EnvTemplatePath -Key 'PUBLIC_URL')

# ---------------------------------------------------------------------------
# 2. The synchronization rule itself
# ---------------------------------------------------------------------------

Write-TestGroup '2. Resolve-DeltaLocalhostPublicUrlSync ownership rule'

$syncCases = @(
    # --- Synchronized: still the installer's own localhost default ---
    [PSCustomObject]@{
        Name         = 'Unchanged port leaves PUBLIC_URL alone'
        CurrentValue = 'http://localhost:3000'; PreviousPort = 3000; NewPort = 3000; Expected = $null
    }
    [PSCustomObject]@{
        Name         = 'Default localhost URL follows the port 3000 -> 3001'
        CurrentValue = 'http://localhost:3000'; PreviousPort = 3000; NewPort = 3001; Expected = 'http://localhost:3001'
    }
    [PSCustomObject]@{
        Name         = 'Trailing slash is the same URL and still follows'
        CurrentValue = 'http://localhost:3000/'; PreviousPort = 3000; NewPort = 3001; Expected = 'http://localhost:3001'
    }
    [PSCustomObject]@{
        Name         = 'Surrounding whitespace is tolerated'
        CurrentValue = '  http://localhost:3000  '; PreviousPort = 3000; NewPort = 3001; Expected = 'http://localhost:3001'
    }
    [PSCustomObject]@{
        Name         = 'Scheme/host casing is normalized, not treated as customization'
        CurrentValue = 'HTTP://LOCALHOST:3000'; PreviousPort = 3000; NewPort = 3001; Expected = 'http://localhost:3001'
    }
    [PSCustomObject]@{
        Name         = 'Implicit default port matches an explicit previous port of 80'
        CurrentValue = 'http://localhost'; PreviousPort = 80; NewPort = 3001; Expected = 'http://localhost:3001'
    }

    # --- Preserved: not ours to rewrite ---
    [PSCustomObject]@{
        Name         = 'Customized public domain survives the port move'
        CurrentValue = 'https://delta.example.org'; PreviousPort = 3000; NewPort = 3001; Expected = $null
    }
    [PSCustomObject]@{
        Name         = 'Real deployment domain survives the port move'
        CurrentValue = 'https://delta.ncscm.gov.jo'; PreviousPort = 3000; NewPort = 3001; Expected = $null
    }
    [PSCustomObject]@{
        Name         = 'https on localhost is a TLS front, not our default'
        CurrentValue = 'https://localhost:3000'; PreviousPort = 3000; NewPort = 3001; Expected = $null
    }
    [PSCustomObject]@{
        Name         = 'localhost URL carrying a path is a customization'
        CurrentValue = 'http://localhost:3000/delta'; PreviousPort = 3000; NewPort = 3001; Expected = $null
    }
    [PSCustomObject]@{
        Name         = 'localhost URL carrying a query is a customization'
        CurrentValue = 'http://localhost:3000/?tenant=jo'; PreviousPort = 3000; NewPort = 3001; Expected = $null
    }
    [PSCustomObject]@{
        Name         = 'localhost URL carrying a fragment is a customization'
        CurrentValue = 'http://localhost:3000/#/app'; PreviousPort = 3000; NewPort = 3001; Expected = $null
    }
    [PSCustomObject]@{
        Name         = 'localhost URL carrying userinfo is a customization'
        CurrentValue = 'http://user:secret@localhost:3000'; PreviousPort = 3000; NewPort = 3001; Expected = $null
    }
    [PSCustomObject]@{
        Name         = '127.0.0.1 was never generated by this installer'
        CurrentValue = 'http://127.0.0.1:3000'; PreviousPort = 3000; NewPort = 3001; Expected = $null
    }
    [PSCustomObject]@{
        Name         = 'A hostname that merely resolves locally is not localhost'
        CurrentValue = 'http://delta.internal:3000'; PreviousPort = 3000; NewPort = 3001; Expected = $null
    }
    [PSCustomObject]@{
        Name         = 'localhost on some other port is not the previous port'
        CurrentValue = 'http://localhost:8080'; PreviousPort = 3000; NewPort = 3001; Expected = $null
    }
    [PSCustomObject]@{
        Name         = 'Unparseable value is never rewritten'
        CurrentValue = 'not a url at all'; PreviousPort = 3000; NewPort = 3001; Expected = $null
    }
    [PSCustomObject]@{
        Name         = 'Empty PUBLIC_URL is never filled in'
        CurrentValue = ''; PreviousPort = 3000; NewPort = 3001; Expected = $null
    }
    [PSCustomObject]@{
        Name         = 'Absent PUBLIC_URL is never invented'
        CurrentValue = $null; PreviousPort = 3000; NewPort = 3001; Expected = $null
    }
)

foreach ($case in $syncCases) {
    Assert-Equal -Name $case.Name `
        -Expected $case.Expected `
        -Actual (Resolve-DeltaLocalhostPublicUrlSync -CurrentValue $case.CurrentValue -PreviousPort $case.PreviousPort -NewPort $case.NewPort)
}

# ---------------------------------------------------------------------------
# 3. Fresh install forced onto another port, against the real template
# ---------------------------------------------------------------------------

Write-TestGroup '3. Fresh install: port 3000 occupied, installer selects 3001'

$templateLines = Get-Content -LiteralPath $Script:EnvTemplatePath
$freshEnvPath = New-TestEnvFile -Lines $templateLines
Invoke-PortChange -Path $freshEnvPath -PreviousPort 3000 -NewPort 3001 | Out-Null

Assert-Equal -Name 'PORT becomes 3001' `
    -Expected '3001' -Actual (Get-EnvFileValue -Path $freshEnvPath -Key 'PORT')

Assert-Equal -Name 'PUBLIC_URL follows to http://localhost:3001' `
    -Expected 'http://localhost:3001' -Actual (Get-EnvFileValue -Path $freshEnvPath -Key 'PUBLIC_URL')

Assert-Equal -Name 'PUBLIC_URL is written with the project double-quoted framing' `
    -Expected 'PUBLIC_URL="http://localhost:3001"' `
    -Actual (@(Get-Content -LiteralPath $freshEnvPath) | Where-Object { $_ -match '^\s*PUBLIC_URL\s*=' } | Select-Object -First 1)

Assert-Equal -Name 'PORT is written with the project double-quoted framing' `
    -Expected 'PORT="3001"' `
    -Actual (@(Get-Content -LiteralPath $freshEnvPath) | Where-Object { $_ -match '^\s*PORT\s*=' } | Select-Object -First 1)

# Nothing outside the two managed lines may move - same count, same
# order, same content, including comments, blank lines, the
# single-quoted EMAIL_FROM, and the commented-out SSO block.
$freshResultLines = @(Get-Content -LiteralPath $freshEnvPath)
$isManagedLine = { param($line) $line -match '^\s*(PUBLIC_URL|PORT)\s*=' }

Assert-Equal -Name 'Line count is unchanged' `
    -Expected $templateLines.Count -Actual $freshResultLines.Count

$untouchedTemplate = @($templateLines | Where-Object { -not (& $isManagedLine $_) }) -join "`n"
$untouchedResult = @($freshResultLines | Where-Object { -not (& $isManagedLine $_) }) -join "`n"
Assert-Equal -Name 'Every unmanaged line passes through byte-for-byte' `
    -Expected $untouchedTemplate -Actual $untouchedResult

# SMTP_PORT must not be caught by anything matching "PORT" loosely.
Assert-Equal -Name 'SMTP_PORT is not mistaken for the application PORT' `
    -Expected '587' -Actual (Get-EnvFileValue -Path $freshEnvPath -Key 'SMTP_PORT')

# ---------------------------------------------------------------------------
# 4. Customized public domain plus a backend port change
# ---------------------------------------------------------------------------

Write-TestGroup '4. Customized public domain, backend port 3000 -> 3001'

$customEnvPath = New-TestEnvFile -Lines @(
    '# Base URL for the application (used for links in emails, etc.)'
    'PUBLIC_URL="https://delta.example.org"'
    ''
    'NODE_ENV="production"'
    'PORT="3000"'
    'DATABASE_URL="postgresql://delta:pw@localhost:5432/delta_db"'
)
$customResult = Invoke-PortChange -Path $customEnvPath -PreviousPort 3000 -NewPort 3001

Assert-Equal -Name 'PORT becomes 3001' `
    -Expected '3001' -Actual (Get-EnvFileValue -Path $customEnvPath -Key 'PORT')

Assert-Equal -Name 'Customized PUBLIC_URL is preserved exactly' `
    -Expected 'https://delta.example.org' -Actual (Get-EnvFileValue -Path $customEnvPath -Key 'PUBLIC_URL')

Assert-Equal -Name 'The PUBLIC_URL line itself is byte-for-byte untouched' `
    -Expected 'PUBLIC_URL="https://delta.example.org"' `
    -Actual (@(Get-Content -LiteralPath $customEnvPath) | Where-Object { $_ -match '^\s*PUBLIC_URL\s*=' } | Select-Object -First 1)

Assert-Equal -Name 'The write reports that PUBLIC_URL was not synchronized' `
    -Expected $null -Actual $customResult.PublicUrl

# A .env that never declared PUBLIC_URL must not gain one.
$noUrlEnvPath = New-TestEnvFile -Lines @(
    'NODE_ENV="production"'
    'PORT="3000"'
)
Invoke-PortChange -Path $noUrlEnvPath -PreviousPort 3000 -NewPort 3001 | Out-Null

Assert-Equal -Name 'PORT is updated when PUBLIC_URL is absent entirely' `
    -Expected '3001' -Actual (Get-EnvFileValue -Path $noUrlEnvPath -Key 'PORT')

Assert-Equal -Name 'PUBLIC_URL is not appended to a .env that never declared it' `
    -Expected $null -Actual (Get-EnvFileValue -Path $noUrlEnvPath -Key 'PUBLIC_URL')

# ---------------------------------------------------------------------------
# 5. Update / reinstall must not reset a customized PUBLIC_URL
# ---------------------------------------------------------------------------

Write-TestGroup '5. Update/reinstall preservation'

# An Upgrade re-runs New-DeltaEnvironmentFile (setup.ps1) against the
# EXISTING .env with DATABASE_URL as the only managed value - that is the
# mechanism reproduced here, so changing .env.example's own PUBLIC_URL
# default can never reach an installed deployment.
$installedLines = @(
    '# Base URL for the application (used for links in emails, etc.)'
    'PUBLIC_URL="https://delta.ncscm.gov.jo"'
    'NODE_ENV="production"'
    'PORT="3001"'
    'DATABASE_URL="postgresql://delta:old@localhost:5432/delta_db"'
    'SESSION_SECRET="operator-chosen-secret" # should be random string for production'
    "EMAIL_FROM='`"DELTA`" <no-reply@ncscm.gov.jo>'"
)
$upgradedLines = Update-ManagedEnvironmentLines -SourceLines $installedLines -ManagedValues ([ordered]@{
    DATABASE_URL = 'postgresql://delta:new@localhost:5432/delta_db'
})
$upgradedEnvPath = New-TestEnvFile -Lines $upgradedLines

Assert-Equal -Name 'Upgrade preserves the customized PUBLIC_URL' `
    -Expected 'https://delta.ncscm.gov.jo' -Actual (Get-EnvFileValue -Path $upgradedEnvPath -Key 'PUBLIC_URL')

Assert-Equal -Name 'Upgrade preserves the existing PORT' `
    -Expected '3001' -Actual (Get-EnvFileValue -Path $upgradedEnvPath -Key 'PORT')

Assert-Equal -Name 'Upgrade still applies the one value it manages' `
    -Expected 'postgresql://delta:new@localhost:5432/delta_db' -Actual (Get-EnvFileValue -Path $upgradedEnvPath -Key 'DATABASE_URL')

Assert-Equal -Name 'Upgrade preserves an operator SESSION_SECRET and its inline comment' `
    -Expected 'SESSION_SECRET="operator-chosen-secret" # should be random string for production' `
    -Actual (@($upgradedLines) | Where-Object { $_ -match '^\s*SESSION_SECRET\s*=' } | Select-Object -First 1)

# A port change on that same installed deployment must likewise leave the
# customized URL alone - the two preservation paths are independent.
Invoke-PortChange -Path $upgradedEnvPath -PreviousPort 3001 -NewPort 3002 | Out-Null

Assert-Equal -Name 'A later port move still preserves the customized PUBLIC_URL' `
    -Expected 'https://delta.ncscm.gov.jo' -Actual (Get-EnvFileValue -Path $upgradedEnvPath -Key 'PUBLIC_URL')

Assert-Equal -Name 'A later port move does update PORT' `
    -Expected '3002' -Actual (Get-EnvFileValue -Path $upgradedEnvPath -Key 'PORT')

# ---------------------------------------------------------------------------
# 6. Quoting and inline comments
# ---------------------------------------------------------------------------

Write-TestGroup '6. Quoting and inline comments'

$quotingEnvPath = New-TestEnvFile -Lines @(
    "PUBLIC_URL='http://localhost:3000' # installer default, change for production"
    'PORT=3000 # unquoted on purpose'
    "EMAIL_FROM='`"DELTA`" <no-reply@undrr.org>'"
    'EMAIL_TRANSPORT="file" # file or smtp'
    'SUPPORT_URL="https://www.undrr.org/contact?topic=delta"'
)
Invoke-PortChange -Path $quotingEnvPath -PreviousPort 3000 -NewPort 3001 | Out-Null
$quotingResultLines = @(Get-Content -LiteralPath $quotingEnvPath)

Assert-Equal -Name 'Single-quoted localhost default is recognized and synchronized' `
    -Expected 'PUBLIC_URL="http://localhost:3001" # installer default, change for production' `
    -Actual ($quotingResultLines | Where-Object { $_ -match '^\s*PUBLIC_URL\s*=' } | Select-Object -First 1)

Assert-Equal -Name 'Unquoted PORT with an inline comment keeps the comment' `
    -Expected 'PORT="3001" # unquoted on purpose' `
    -Actual ($quotingResultLines | Where-Object { $_ -match '^\s*PORT\s*=' } | Select-Object -First 1)

Assert-Equal -Name 'A value containing double quotes keeps its single-quoted line untouched' `
    -Expected "EMAIL_FROM='`"DELTA`" <no-reply@undrr.org>'" `
    -Actual ($quotingResultLines | Where-Object { $_ -match '^\s*EMAIL_FROM\s*=' } | Select-Object -First 1)

Assert-Equal -Name 'An unrelated inline comment is left alone' `
    -Expected 'EMAIL_TRANSPORT="file" # file or smtp' `
    -Actual ($quotingResultLines | Where-Object { $_ -match '^\s*EMAIL_TRANSPORT\s*=' } | Select-Object -First 1)

# A '#' inside a quoted value is part of the value, not a comment - the
# reader this rule depends on must not truncate at it.
Assert-Equal -Name 'A URL with a query string reads back intact' `
    -Expected 'https://www.undrr.org/contact?topic=delta' `
    -Actual (Get-EnvFileValue -Path $quotingEnvPath -Key 'SUPPORT_URL')

$hashEnvPath = New-TestEnvFile -Lines @(
    'PUBLIC_URL="https://delta.example.org/#/home"'
    'PORT="3000"'
)
Invoke-PortChange -Path $hashEnvPath -PreviousPort 3000 -NewPort 3001 | Out-Null

Assert-Equal -Name 'A quoted URL containing # is preserved whole' `
    -Expected 'https://delta.example.org/#/home' -Actual (Get-EnvFileValue -Path $hashEnvPath -Key 'PUBLIC_URL')

# ---------------------------------------------------------------------------
# 7. Access guide, runtime, and reverse proxy on a non-default port
# ---------------------------------------------------------------------------

Write-TestGroup '7. Non-default backend port: access guide, runtime, reverse proxy'

# Resolve-DeltaBackendPort's contract (shared by setup.ps1,
# setup-nginx.ps1, setup-iis.ps1, and the Doctor) reads the synchronized
# value back, so every downstream consumer agrees on 3001.
$runtimeEnvPath = New-TestEnvFile -Lines $templateLines
Invoke-PortChange -Path $runtimeEnvPath -PreviousPort 3000 -NewPort 3001 | Out-Null

$rawPort = Get-EnvFileValue -Path $runtimeEnvPath -Key 'PORT'
Assert-Equal -Name 'The written PORT is a valid TCP port' -Expected $true -Actual (Test-ValidTcpPort -Value $rawPort)
Assert-Equal -Name 'Backend port detection reads back 3001' -Expected 3001 -Actual ([int]$rawPort)

# The access guide builds its URLs from the resolved port, never from
# PUBLIC_URL - Show-DeltaAccessGuide (setup.ps1) prints
# "http://localhost:<port>", which on a synchronized .env is exactly the
# PUBLIC_URL value too.
Assert-Equal -Name 'Access-guide local URL matches the synchronized PUBLIC_URL' `
    -Expected (Get-EnvFileValue -Path $runtimeEnvPath -Key 'PUBLIC_URL') `
    -Actual (Get-DeltaLocalhostPublicUrl -Port ([int]$rawPort))

# A reverse proxy owns PUBLIC_URL from the moment it is configured, and
# its URL never carries the backend port - NGINX/IIS front 80/443 and
# forward to localhost:<PORT>.
$proxyUrl = Get-DeltaPublicUrl -Domain 'delta.example.org' -Https $true
Assert-Equal -Name 'Reverse-proxy PUBLIC_URL carries no backend port' -Expected 'https://delta.example.org' -Actual $proxyUrl

Assert-Equal -Name 'Proxy URL comparison ignores trailing slash and casing' `
    -Expected $true -Actual (Test-DeltaPublicUrlsMatch -First $proxyUrl -Second 'https://Delta.Example.org/')

Assert-Equal -Name 'Proxy URL is never confused with the installer localhost default' `
    -Expected $false -Actual (Test-DeltaInstallerManagedLocalhostPublicUrl -Value $proxyUrl -Port 3001)

# After a proxy has taken PUBLIC_URL over, a further backend port move
# leaves it alone - the documented Public URL -> NGINX/IIS ->
# http://localhost:<PORT> -> DELTA relationship stays intact.
$proxyEnvPath = New-TestEnvFile -Lines $templateLines
Invoke-PortChange -Path $proxyEnvPath -PreviousPort 3000 -NewPort 3001 | Out-Null
$Script:DeltaEnvPath = $proxyEnvPath
Sync-DeltaPublicUrlEnvironment -Domain 'delta.example.org' -Https $true 6>$null

Assert-Equal -Name 'Reverse-proxy sync takes ownership of PUBLIC_URL' `
    -Expected 'https://delta.example.org' -Actual (Get-EnvFileValue -Path $proxyEnvPath -Key 'PUBLIC_URL')

Invoke-PortChange -Path $proxyEnvPath -PreviousPort 3001 -NewPort 3002 | Out-Null

Assert-Equal -Name 'A backend port move behind a proxy preserves the public URL' `
    -Expected 'https://delta.example.org' -Actual (Get-EnvFileValue -Path $proxyEnvPath -Key 'PUBLIC_URL')

Assert-Equal -Name 'A backend port move behind a proxy still updates PORT' `
    -Expected '3002' -Actual (Get-EnvFileValue -Path $proxyEnvPath -Key 'PORT')

# ---------------------------------------------------------------------------
# 8. The default template must be a combination in which login actually works
# ---------------------------------------------------------------------------
#
# The DELTA runtime marks its session cookies Secure whenever
# NODE_ENV=production - driven by NODE_ENV alone, never by PUBLIC_URL, the
# request protocol, or X-Forwarded-Proto (verified against
# dts_shared_binary's own build/server/index.js, and observed live on the
# wire: "Set-Cookie: __session=...; HttpOnly; Secure; SameSite=Lax").
# Browsers accept a Secure cookie over plain http ONLY for a potentially
# trustworthy origin, which in practice means localhost. The login form's
# CSRF token travels in that same cookie, so a browser that discards it
# fails the login POST outright.
#
# That makes "http + localhost" and "https + anything" the only shipped
# defaults in which an operator can actually sign in. These guard that
# invariant: a future edit that points the default PUBLIC_URL at a plain
# http non-localhost host while NODE_ENV stays production would break
# login silently, with the page still loading normally - exactly the
# failure this file exists to keep out of a release.

Write-TestGroup '8. Default template is a configuration login can succeed in'

$templateNodeEnv = Get-EnvFileValue -Path $Script:EnvTemplatePath -Key 'NODE_ENV'
Assert-Equal -Name '.env.example ships NODE_ENV="production"' -Expected 'production' -Actual $templateNodeEnv

function Test-SecureCookieOriginUsable {
    <#
      Whether a browser will accept a Secure cookie from $Url - true for
      any https origin, and for http only when the host is localhost.
      Mirrors the browser rule, not a DELTA-specific one.
    #>
    param([Parameter(Mandatory)][string]$Url)

    $uri = [System.Uri]$Url
    if ($uri.Scheme -eq 'https') { return $true }
    return ($uri.Host -eq 'localhost')
}

$templatePublicUrl = Get-EnvFileValue -Path $Script:EnvTemplatePath -Key 'PUBLIC_URL'
Assert-Equal -Name 'Default PUBLIC_URL is an origin that can hold a Secure cookie' `
    -Expected $true -Actual (Test-SecureCookieOriginUsable -Url $templatePublicUrl)

# The same must hold after the installer moves the port, since the synced
# value is still a localhost URL and localhost is what makes it work.
Assert-Equal -Name 'Port-synced PUBLIC_URL is still such an origin' `
    -Expected $true -Actual (Test-SecureCookieOriginUsable -Url (Get-DeltaLocalhostPublicUrl -Port 3001))

# Cookies are scoped by host and path, never by port, so moving the
# backend port cannot invalidate an existing session - the synced URL
# differs from the original only in its port.
$beforeSync = [System.Uri](Get-DeltaLocalhostPublicUrl -Port 3000)
$afterSync = [System.Uri](Get-DeltaLocalhostPublicUrl -Port 3001)
Assert-Equal -Name 'Port sync changes only the port, never the cookie host' `
    -Expected $beforeSync.Host -Actual $afterSync.Host

Assert-Equal -Name 'Port sync never changes the scheme' `
    -Expected $beforeSync.Scheme -Actual $afterSync.Scheme

# A reverse-proxy URL is https, so it satisfies the same invariant by the
# other branch - no localhost requirement once TLS is terminated.
Assert-Equal -Name 'Reverse-proxy https URL satisfies the invariant' `
    -Expected $true -Actual (Test-SecureCookieOriginUsable -Url (Get-DeltaPublicUrl -Domain 'delta.example.org' -Https $true))

# ---------------------------------------------------------------------------

Remove-Item -LiteralPath $Script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($Script:Failures -eq 0) {
    Write-Host "All $($Script:Total) test case(s) passed." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$($Script:Failures) of $($Script:Total) test case(s) FAILED." -ForegroundColor Red
    exit 1
}

#Requires -Version 5.1
<#
.SYNOPSIS
    Installs and configures NGINX as an optional reverse proxy for DELTA.

.DESCRIPTION
    Separate from setup.ps1 - DELTA runs standalone on http://localhost:3000
    without this script, and nothing here is a dependency of the main
    installer. Run this only when a native reverse proxy in front of DELTA
    is actually wanted (e.g. to serve DELTA on port 80, or as the future home
    of a real TLS certificate).

    Before anything else - even before checking for an existing NGINX
    installation - Resolve-DeltaInstallation confirms a DELTA installation
    actually exists on this machine, via Get-DeltaInstallPath
    (lib\DeltaInstaller.Common.ps1's shared discovery helper: the Windows
    Registry key setup.ps1's own Register-DeltaInstallation writes, falling
    back to the legacy C:\DELTA\.env convention for installations that
    predate it). This script is a CONSUMER of that discovery, never a
    second implementation of it, and never assumes DELTA lives at a fixed
    C:\DELTA path itself. No installation found means nothing else in this
    script runs.

    Conservative by design: installing a FRESH copy of NGINX is something
    this script is willing to automate; modifying an EXISTING one is not.
    Once a DELTA installation has been confirmed, the next thing this
    script does - before installing anything, before writing a single
    configuration file - is check whether C:\nginx\nginx.exe already
    exists. If it does, the script stops
    immediately (Show-ExistingNginxNotice) and touches nothing at all: no
    file is written, no backup is made, no signal is sent to whatever may
    already be running. This installer must never assume it owns an
    existing NGINX installation - a real, hand-configured, already-running
    reverse proxy at this exact default path is a realistic thing to find
    on a real machine, not a hypothetical edge case, and overwriting it
    would be a production incident, not a convenience.

    Only once that check has passed (no existing installation found) does
    it proceed, in three phases:

      1. Install-Nginx - installs the one pinned version, $Script:NginxVersion
         (see the Configuration section below), from a local
         installers\nginx-<version>.zip if that exact file is present, or
         downloads the official Windows ZIP distribution from nginx.org
         otherwise - never a third-party installer or repackaging, and
         never any version other than the one pinned. Also ensures
         conf\conf.d\ exists, since the official ZIP distribution does not
         ship that directory itself.

      2. New-DeltaNginxConfiguration - writes C:\nginx\conf\nginx.conf and
         C:\nginx\conf\conf.d\delta.conf from the canonical templates in
         templates\nginx\ (this repository), rather than generating either
         file line-by-line from PowerShell. This deliberately replaces the
         large block of commented sample configuration NGINX itself ships
         in conf\nginx.conf with a minimal, DELTA-specific file. No backup
         step here - by the time this runs, the existing-installation check
         above has already guaranteed there is nothing pre-existing worth
         protecting.

      3. Test-DeltaNginxConfiguration - runs `nginx -t` against the
         configuration just written. A validation failure stops the script
         immediately, before NGINX is ever started.

      4. Start-DeltaNginx - starts NGINX. On this path it is always a fresh
         start, never a reload - the existing-installation check above
         guarantees nothing at $Script:NginxHome was already running.

    Finishes by printing a summary (Show-DeltaNginxSummary).

    Re-running this script after it has already installed NGINX once is
    safe in the sense that nothing gets corrupted - but it will simply
    detect the NGINX it just installed and stop with the same
    already-installed notice everything else does. This script installs
    and configures NGINX exactly once; it is not a repeatable reconciler.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See lib\DeltaInstaller.Common.ps1's own header for why $Script:ProjectRoot
# must be computed here, before dot-sourcing it, rather than inside it.
$Script:ProjectRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path -Path $Script:ProjectRoot -ChildPath 'lib\DeltaInstaller.Common.ps1')

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$Script:NginxHome            = 'C:\nginx'
$Script:NginxExePath         = Join-Path -Path $Script:NginxHome -ChildPath 'nginx.exe'
$Script:NginxConfDirectory   = Join-Path -Path $Script:NginxHome -ChildPath 'conf'
$Script:NginxMainConfigPath  = Join-Path -Path $Script:NginxConfDirectory -ChildPath 'nginx.conf'
$Script:NginxConfDDirectory  = Join-Path -Path $Script:NginxConfDirectory -ChildPath 'conf.d'
$Script:DeltaVHostConfigPath = Join-Path -Path $Script:NginxConfDDirectory -ChildPath 'delta.conf'

# The one NGINX version this installer ever installs - pinned, not "latest",
# so a run today and a run next year install byte-for-byte the same NGINX.
# Used consistently below wherever a version could otherwise vary: the local
# package filename, the download URL, and the installation summary. Official
# Windows ZIP distribution only - nginx.org publishes precompiled Windows
# binaries under this exact naming convention (confirmed live via a direct
# HTTP HEAD request at the time this was written - re-verify against
# https://nginx.org/en/download.html before bumping this version, the same
# caveat setup.ps1 carries for its own EDB/PostGIS download URLs).
$Script:NginxVersion     = '1.29.2'
$Script:NginxDownloadUrl = "https://nginx.org/download/nginx-$($Script:NginxVersion).zip"

# Downloaded packages are cached project-locally in .\installers (sibling to
# this script, gitignored), matching setup.ps1's own $Script:InstallersDirectory
# convention - installers\nginx-<version>.zip (see Get-NginxPackage), whether
# placed there manually by an operator (e.g. for an air-gapped install) or
# cached from this script's own prior download, is preferred over a fresh
# download when present.
$Script:InstallersDirectory = Join-Path -Path $Script:ProjectRoot -ChildPath 'installers'

# Canonical configuration templates (this repository) copied into place -
# see this file's own header for why these are maintained as real, readable
# files rather than generated via PowerShell string concatenation.
$Script:NginxMainConfigTemplate  = Join-Path -Path $Script:ProjectRoot -ChildPath 'templates\nginx\nginx.conf'
$Script:DeltaVHostConfigTemplate = Join-Path -Path $Script:ProjectRoot -ChildPath 'templates\nginx\delta.conf'

$Script:DeltaBackendUrl  = 'http://localhost:3000'
$Script:DeltaFrontendUrl = 'http://localhost'

# ---------------------------------------------------------------------------
# DELTA installation discovery
# ---------------------------------------------------------------------------

function Resolve-DeltaInstallation {
    <#
      The first real action this script takes - before even checking for
      an existing NGINX installation. Confirms a real DELTA installation
      exists on this machine via the shared discovery helper,
      Get-DeltaInstallPath (lib\DeltaInstaller.Common.ps1, dot-sourced
      above) - never a hardcoded C:\DELTA assumption of this script's own.
      That helper already implements the full resolution order (the
      registry key setup.ps1's own Register-DeltaInstallation writes,
      falling back to the legacy C:\DELTA\.env convention for
      installations that predate it) - this script is a CONSUMER of that
      discovery, not a second implementation of it, so nothing here
      re-checks the registry or the legacy path itself.

      Stops immediately (Stop-Setup) if Get-DeltaInstallPath returns
      $null - a reverse proxy for a DELTA installation that doesn't exist
      makes no sense, so nothing else in this script (not even the
      existing-NGINX check) is allowed to run in that case.

      $Script:DeltaEnvPath is built via Join-Path from the resolved
      $Script:DeltaInstallPath, never string concatenation - both are
      script-scoped so Show-DeltaNginxSummary can display exactly which
      DELTA installation this reverse proxy was set up for.
    #>

    Write-PhaseBanner 'DELTA Installation Discovery'
    Write-Step 'Locating the DELTA installation...'

    $Script:DeltaInstallPath = Get-DeltaInstallPath
    if (-not $Script:DeltaInstallPath) {
        Stop-Setup @'
DELTA installation not found.

Please install DELTA using setup.ps1 before running setup-nginx.ps1.
'@
    }

    $Script:DeltaEnvPath = Join-Path -Path $Script:DeltaInstallPath -ChildPath '.env'

    Write-Success '    DELTA installation found.'
    Write-Host ''
    Write-Host 'Location:'
    Write-Host $Script:DeltaInstallPath
}

# ---------------------------------------------------------------------------
# Native command output helper
# ---------------------------------------------------------------------------

function ConvertTo-NativeCommandOutputText {
    <#
      Joins a native command's captured output (as returned by a call using
      2>&1, one array element per line) back into plain, readable text.

      Deliberately NOT "($Output | Out-String).Trim()": a stderr line
      merged via 2>&1 arrives as an ErrorRecord, not a plain string, and
      Out-String renders an ErrorRecord through PowerShell's own default
      error format view - "At line X char Y", "+ CategoryInfo", etc. -
      rather than the line of text nginx.exe actually printed. Confirmed
      directly: a completely successful `nginx -t` (exit code 0) otherwise
      displays with that full diagnostic frame around it, indistinguishable
      at a glance from a real failure. Calling .ToString() on each element
      individually first (which for an ErrorRecord returns just its
      message) avoids that, for both success and failure output alike.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Output)

    $lines = @($Output | ForEach-Object { $_.ToString() })
    return ($lines -join [Environment]::NewLine).Trim()
}

# ---------------------------------------------------------------------------
# Download / install
# ---------------------------------------------------------------------------

function Get-NginxPackage {
    <#
      Returns the path to the NGINX Windows ZIP package for the pinned
      $Script:NginxVersion - and only that version, never any other.

      Deliberately an EXACT filename match against
      installers\nginx-<version>.zip, not an installers\nginx-*.zip
      wildcard: the entire point of pinning $Script:NginxVersion is that
      this installer always installs that one version, and a wildcard match
      could silently pick up a differently-versioned package an operator
      happened to leave in the same directory. The same exact path serves
      both an operator-supplied local package (e.g. for an air-gapped
      install) and this function's own cached download from a prior run -
      there is no meaningful difference between the two once the filename
      matches the pin, so both are handled by the same Test-Path check
      rather than two separate code paths.
    #>

    $packagePath = Join-Path -Path $Script:InstallersDirectory -ChildPath "nginx-$($Script:NginxVersion).zip"

    if (Test-Path -LiteralPath $packagePath) {
        Write-Step 'Using local NGINX package...'
        Write-Detail "Package: $packagePath"
        return $packagePath
    }

    if (-not (Test-Path -Path $Script:InstallersDirectory)) {
        New-Item -Path $Script:InstallersDirectory -ItemType Directory -Force | Out-Null
    }

    Write-Step "Downloading NGINX $($Script:NginxVersion) (official Windows ZIP distribution)..."
    Write-Detail "Source: $($Script:NginxDownloadUrl)"
    Write-Detail "Target: $packagePath"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Script:NginxDownloadUrl -OutFile $packagePath -UseBasicParsing
    }
    catch {
        Stop-Setup "Failed to download NGINX from $($Script:NginxDownloadUrl): $($_.Exception.Message)"
    }

    if (-not (Test-Path -Path $packagePath) -or (Get-Item -Path $packagePath).Length -eq 0) {
        Stop-Setup "Download reported success but the package file is missing or empty: $packagePath"
    }

    Write-Success '    Download complete.'
    return $packagePath
}

function Install-NginxFromZip {
    <#
      Extracts $ZipPath into a temporary staging directory and moves its
      contents into $Script:NginxHome. The official ZIP distribution wraps
      everything in a single top-level nginx-<version>\ directory
      (nginx.exe, conf\, html\, logs\, temp\, contrib\, docs\) - that inner
      directory's CONTENTS are what belongs at $Script:NginxHome, never the
      version-named directory itself, so this always detects and unwraps
      it rather than assuming a fixed folder name (a locally-supplied
      installers\nginx-*.zip is not guaranteed to use nginx.org's own naming).
    #>
    param([Parameter(Mandatory)][string]$ZipPath)

    Write-Step 'Extracting NGINX...'
    Write-Detail "Package: $ZipPath"
    Write-Detail "Target: $($Script:NginxHome)"

    $stagingDirectory = Join-Path -Path $env:TEMP -ChildPath "delta-nginx-extract-$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $stagingDirectory -ItemType Directory -Force | Out-Null

    try {
        try {
            Expand-Archive -LiteralPath $ZipPath -DestinationPath $stagingDirectory -Force
        }
        catch {
            Stop-Setup "Failed to extract the NGINX package ($ZipPath): $($_.Exception.Message)"
        }

        # @(...) here is deliberate, not decorative - Get-ChildItem returns
        # a bare (non-array) DirectoryInfo, not a one-element array, when
        # exactly one subdirectory matches, and PowerShell's own pipeline
        # unwrapping means an un-guarded ".Count" or index on that result
        # would behave inconsistently depending on how many entries came
        # back. Forcing it into a real array here first is what makes
        # ".Count -eq 1" and "[0]" below trustworthy either way.
        $extractedEntries = @(Get-ChildItem -Path $stagingDirectory -Directory)
        $sourceDirectory = if ($extractedEntries.Count -eq 1) { $extractedEntries[0].FullName } else { $stagingDirectory }

        if (-not (Test-Path -Path $Script:NginxHome)) {
            New-Item -Path $Script:NginxHome -ItemType Directory -Force | Out-Null
        }

        Get-ChildItem -Path $sourceDirectory -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Script:NginxHome -Recurse -Force
        }
    }
    finally {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Success '    Extraction complete.'
}

function Install-Nginx {
    <#
      Phase 1. Callers MUST have already confirmed nginx.exe does not exist
      at $Script:NginxExePath (see the orchestration block's own
      existing-installation check, which runs before this is ever called) -
      this function always installs, unconditionally, and never re-checks
      that guarantee itself. It never attempts to detect or reconcile a
      different NGINX version the way setup.ps1's Node.js/PostgreSQL phases
      do either, since there is nothing to reconcile: the pinned
      $Script:NginxVersion is the only version this ever installs.

      Also ensures conf\conf.d\ exists once extraction finishes - the
      official ZIP distribution does not ship that directory itself, and
      conf\nginx.conf's `include conf.d/*.conf;` (see
      templates\nginx\nginx.conf) depends on it being there.
    #>

    Write-PhaseBanner 'NGINX Installation'
    Write-Step "NGINX was not found at $($Script:NginxExePath) - installing version $($Script:NginxVersion)..."

    if (-not (Test-IsAdministrator)) {
        Stop-Setup "Administrator privileges are required to install NGINX to $($Script:NginxHome). Re-run this script from an elevated PowerShell session."
    }

    $packagePath = Get-NginxPackage
    Install-NginxFromZip -ZipPath $packagePath

    Write-Step 'Validating installation...'
    if (-not (Test-Path -LiteralPath $Script:NginxExePath)) {
        Stop-Setup "NGINX installation appeared to succeed, but nginx.exe was not found afterward at $($Script:NginxExePath)."
    }

    Write-Step 'Ensuring required directories exist...'
    if (-not (Test-Path -LiteralPath $Script:NginxConfDDirectory)) {
        New-Item -Path $Script:NginxConfDDirectory -ItemType Directory -Force | Out-Null
        Write-Detail "Created: $($Script:NginxConfDDirectory)"
    }
    else {
        Write-Detail "Already exists: $($Script:NginxConfDDirectory)"
    }

    Write-Host ''
    Write-Success 'NGINX successfully installed.'
    Write-Host ''
    Write-Host 'Version:'
    Write-Host $Script:NginxVersion
    Write-Host ''
    Write-Host 'Location:'
    Write-Host $Script:NginxHome
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Install-NginxConfigFile {
    <#
      Copies $TemplatePath to $DestinationPath, unconditionally - no
      diffing against, or backing up, whatever might already be there. That
      is deliberate, not an oversight: this only ever runs immediately
      after Install-Nginx has just extracted a brand-new NGINX (see the
      orchestration block's existing-installation check, which runs before
      any of this and refuses to proceed at all if NGINX was already
      present) - there is no pre-existing, operator-meaningful
      configuration here worth diffing against or protecting, only NGINX's
      own freshly-extracted stock nginx.conf sample. Backing up a file that
      was never anything but this script's own install artifact would add
      complexity without protecting anything real.
    #>
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$Description
    )

    $destinationDirectory = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path -Path $destinationDirectory)) {
        New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
    }

    Copy-Item -LiteralPath $TemplatePath -Destination $DestinationPath -Force
    Write-Success "    $Description written: $DestinationPath"
}

function New-DeltaNginxConfiguration {
    <#
      Phase 2. Writes both canonical configuration files from the templates
      under templates\nginx\ (this repository) - never generated inline as
      PowerShell string concatenation, so they stay readable and
      version-controlled on their own. See this script's own header for why
      conf\nginx.conf itself is replaced outright rather than left as
      NGINX's own heavily-commented sample file, and why no backup step is
      needed here (Install-NginxConfigFile).
    #>

    Write-PhaseBanner 'NGINX Configuration'

    foreach ($template in @($Script:NginxMainConfigTemplate, $Script:DeltaVHostConfigTemplate)) {
        if (-not (Test-Path -LiteralPath $template)) {
            Stop-Setup "Required configuration template not found: $template"
        }
    }

    Write-Step 'Writing main NGINX configuration...'
    Install-NginxConfigFile -TemplatePath $Script:NginxMainConfigTemplate -DestinationPath $Script:NginxMainConfigPath -Description 'Main configuration'

    Write-Step 'Writing DELTA reverse proxy configuration...'
    Install-NginxConfigFile -TemplatePath $Script:DeltaVHostConfigTemplate -DestinationPath $Script:DeltaVHostConfigPath -Description 'DELTA virtual host configuration'
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

function Test-DeltaNginxConfiguration {
    <#
      Phase 3. Runs `nginx -t` against the configuration just written -
      -p/-c are passed explicitly (rather than relying on nginx.exe's own
      default prefix resolution, which depends on the current working
      directory) so this behaves identically no matter where this script is
      invoked from. A non-zero exit stops the script immediately, before
      Start-DeltaNginx ever runs - an already-running NGINX is deliberately
      never touched by a configuration that fails to validate.
    #>

    Write-PhaseBanner 'NGINX Configuration Validation'
    Write-Step 'Validating configuration (nginx -t)...'

    $previousEap = $ErrorActionPreference
    try {
        # nginx -t writes its result to stderr even on success - under this
        # script's global $ErrorActionPreference = 'Stop', capturing native
        # stderr via 2>&1 would otherwise turn that routine output into a
        # terminating error (the same fix applied around psql calls
        # elsewhere in this project - see Test-PostGISAvailable).
        $ErrorActionPreference = 'Continue'
        $output = & $Script:NginxExePath '-t' '-p' $Script:NginxHome '-c' 'conf\nginx.conf' 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    $outputText = ConvertTo-NativeCommandOutputText -Output $output

    if ($exitCode -ne 0) {
        Write-Host ''
        Write-Host $outputText -ForegroundColor Red
        Stop-Setup 'NGINX configuration validation failed. NGINX was not started or reloaded - fix the error above and re-run this script.'
    }

    Write-Detail $outputText
    Write-Success '    Configuration is valid.'
}

# ---------------------------------------------------------------------------
# Start / reload
# ---------------------------------------------------------------------------

function Get-RunningDeltaNginxProcess {
    <#
      Finds an nginx.exe process actually running FROM $Script:NginxHome -
      matched by its executable path, never by process name alone.
      Get-Process -Name 'nginx' matches every nginx.exe on the machine
      regardless of which installation it belongs to - confirmed directly
      to be a real, not theoretical, distinction: a machine can easily run
      a separate, unrelated NGINX instance from a different directory, and
      a name-only match against that instance would falsely report this
      script's own target as "already running" (and then send it a reload
      signal, or treat a failed start as successful, based on someone
      else's process). Mirrors Get-RunningDeltaProcesses in setup.ps1,
      which matches its own node.exe target the same specific way rather
      than a generic name sweep.
    #>
    return Get-Process -Name 'nginx' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and ($_.Path -eq $Script:NginxExePath) } catch { $false }
    } | Select-Object -First 1
}

function Start-DeltaNginx {
    <#
      Phase 4. Starts NGINX. Given the existing-installation check in the
      orchestration block below, this always takes the fresh-start path in
      practice - Install-Nginx has just extracted a brand-new NGINX that
      cannot already be running. The reload branch (`nginx -s reload`,
      matched via Get-RunningDeltaNginxProcess rather than a name-only
      Get-Process check - see that function's own header for why) is kept
      as a defensive fallback rather than removed: harmless if unreachable
      in the normal flow, and correct if it is ever reached.

      Binding to port 80 (this configuration's default) requires
      Administrator privileges on Windows, so that's checked here
      specifically rather than relying solely on Install-Nginx's own check.
    #>

    Write-PhaseBanner 'NGINX Start / Reload'

    if (-not (Test-IsAdministrator)) {
        Stop-Setup 'Administrator privileges are required to start or reload NGINX (binding port 80 requires it). Re-run this script from an elevated PowerShell session.'
    }

    $running = Get-RunningDeltaNginxProcess
    if ($running) {
        Write-Step 'Reloading NGINX configuration...'
        $previousEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = & $Script:NginxExePath '-s' 'reload' '-p' $Script:NginxHome '-c' 'conf\nginx.conf' 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousEap
        }

        if ($exitCode -ne 0) {
            Stop-Setup "Failed to reload NGINX: $(ConvertTo-NativeCommandOutputText -Output $output)"
        }

        Write-Success '    NGINX reloaded.'
        return
    }

    Write-Step 'Starting NGINX...'
    Start-Process -FilePath $Script:NginxExePath -ArgumentList @('-p', $Script:NginxHome, '-c', 'conf\nginx.conf') `
        -WorkingDirectory $Script:NginxHome -WindowStyle Hidden | Out-Null

    $started = Wait-Until -Condition { Get-RunningDeltaNginxProcess } -TimeoutSeconds 10
    if (-not $started) {
        Stop-Setup 'NGINX did not appear to start within 10 seconds.'
    }

    Write-Success '    NGINX started.'
}

# ---------------------------------------------------------------------------
# Installation summary
# ---------------------------------------------------------------------------

function Show-DeltaNginxSummary {
    <#
      Purely a console-output concern, reusing the existing
      Write-SetupBanner/Write-PhaseBanner/Write-Detail vocabulary
      (lib\DeltaInstaller.Common.ps1) rather than introducing new
      formatting primitives - the same approach setup.ps1's own final
      summary takes. Deliberately plain ASCII markers ("[OK]"), not a
      Unicode checkmark - matches every other console message in this
      project (confirmed elsewhere that a Unicode character here mojibakes
      or drops once output is piped/redirected rather than written straight
      to an interactive console host).
    #>

    Write-SetupBanner -Title 'DELTA NGINX Setup Complete' -Subtitle 'Installation completed successfully.'

    Write-Success "    [OK] NGINX $($Script:NginxVersion) installed"

    Write-PhaseBanner 'DELTA Installation'
    Write-Host 'Location:'
    Write-Detail $Script:DeltaInstallPath
    Write-Host ''
    Write-Host 'Environment File:'
    Write-Detail $Script:DeltaEnvPath

    Write-PhaseBanner 'Configuration'
    Write-Host 'NGINX Home:'
    Write-Detail $Script:NginxHome
    Write-Host ''
    Write-Host 'Main Configuration:'
    Write-Detail $Script:NginxMainConfigPath
    Write-Host ''
    Write-Host 'DELTA Virtual Host:'
    Write-Detail $Script:DeltaVHostConfigPath

    Write-PhaseBanner 'Backend'
    Write-Host 'DELTA:'
    Write-Detail $Script:DeltaBackendUrl

    Write-PhaseBanner 'Frontend'
    Write-Detail $Script:DeltaFrontendUrl

    Write-PhaseBanner 'Useful Commands'
    Write-Detail "(run from $($Script:NginxHome))"
    Write-Host ''
    Write-Host 'nginx -t'
    Write-Detail 'Validate configuration'
    Write-Host ''
    Write-Host 'nginx -s reload'
    Write-Detail 'Reload configuration'
    Write-Host ''
    Write-Host 'nginx -s quit'
    Write-Detail 'Stop NGINX'

    Write-PhaseBanner 'HTTPS'
    Write-Host 'HTTPS is not enabled by default.'
    Write-Host ''
    Write-Host 'A fully documented HTTPS configuration template has been included'
    Write-Host "inside $(Split-Path -Path $Script:DeltaVHostConfigPath -Leaf)."

    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth)
    Write-Host ''
}

function Show-ExistingNginxNotice {
    <#
      The entire response to finding NGINX already installed
      ($Script:NginxExePath already exists) - shown BEFORE Install-Nginx,
      New-DeltaNginxConfiguration, Test-DeltaNginxConfiguration, or
      Start-DeltaNginx ever run, so nothing is touched: no file is written,
      no backup is made, no signal is sent to whatever may already be
      running there. Per this script's own design philosophy (see its
      header): installing a fresh copy of NGINX is safe to automate;
      reconciling configuration on an existing one is not - an
      already-installed, potentially hand-configured (and possibly live)
      reverse proxy at this exact default path is a realistic thing to find
      on a real machine, not just a theoretical caution.

      Deliberately spells out that this is intentional, expected behavior
      (not an error this installer stumbled into) - an administrator seeing
      this needs to walk away confident the script did exactly what it was
      designed to do, not wonder whether something went wrong. Also points
      at $Script:DeltaVHostConfigTemplate (this repository's own canonical
      DELTA reverse proxy template - never generated or copied anywhere by
      this code path) so the administrator has a concrete starting point
      for adapting their existing configuration, rather than just being
      told a merge is needed with nothing to merge from.
    #>

    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth)
    Write-Host ''
    Write-Host 'Existing NGINX installation detected.'
    Write-Host ''
    Write-Host 'setup-nginx.ps1 only installs new NGINX instances.'
    Write-Host 'Existing installations are intentionally left untouched.'
    Write-Host ''
    Write-Host 'No changes have been made.'
    Write-Host ''
    Write-Host 'NGINX Home'
    Write-Host ''
    Write-Detail $Script:NginxHome
    Write-Host ''
    Write-Host 'Main Configuration'
    Write-Host ''
    Write-Detail $Script:NginxMainConfigPath
    Write-Host ''
    Write-Host 'Virtual Hosts'
    Write-Host ''
    Write-Detail "$($Script:NginxConfDDirectory)\"
    Write-Host ''
    Write-Host 'DELTA Template'
    Write-Host ''
    Write-Detail $Script:DeltaVHostConfigTemplate
    Write-Host ''
    Write-Host 'Review your existing NGINX configuration and adapt the provided'
    Write-Host 'DELTA reverse proxy template to your environment.'
    Write-Host ''
    Write-Host 'If you intended to install a new NGINX instance,'
    Write-Host 'run setup-nginx.ps1 on a clean server or after'
    Write-Host 'removing the existing NGINX installation.'
    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth)
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

try {
    Write-SetupBanner -Title 'DELTA NGINX Setup' -Subtitle 'Optional reverse proxy for DELTA'

    # Must happen before anything else, including the existing-NGINX check
    # below - see Resolve-DeltaInstallation's own header. Nothing above this
    # point has touched the filesystem.
    Resolve-DeltaInstallation

    # The next check that must happen before any NGINX-specific action -
    # see this script's own header and Show-ExistingNginxNotice. Nothing
    # below this point is reachable if NGINX is already installed.
    if (Test-Path -LiteralPath $Script:NginxExePath) {
        Show-ExistingNginxNotice
        exit 0
    }

    Install-Nginx
    New-DeltaNginxConfiguration
    Test-DeltaNginxConfiguration
    Start-DeltaNginx
    Show-DeltaNginxSummary

    exit 0
}
catch {
    Write-Host ''
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Red
    Write-Host 'DELTA NGINX setup failed.' -ForegroundColor Red
    Write-Host ('=' * $Script:BannerWidth) -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

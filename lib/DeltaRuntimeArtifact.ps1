<#
.SYNOPSIS
    Automatic DELTA runtime artifact (dts_shared_binary) acquisition and
    update, sourced from the public DELTA GitHub Releases API.

.DESCRIPTION
    Dot-sourced by setup.ps1 alongside lib\DeltaInstaller.Common.ps1 - the
    only thing borrowed from that file is the shared console-output
    vocabulary (Write-PhaseBanner/Write-Step/Write-Detail/Write-Success)
    and Stop-Setup. This file reads none of setup.ps1's own
    Configuration-section state ($Script:PostgresPort and friends), and
    none of setup.ps1's other phases depend on anything defined here -
    the single entry point, Update-DeltaRuntimeArtifact, takes the
    runtime source directory and the installer's project root as plain
    parameters rather than reaching into script-scoped variables owned
    by setup.ps1.

    Update-DeltaRuntimeArtifact is called once, before Install-DeltaRuntime,
    so that whatever Install-DeltaRuntime later deploys into the
    operator's chosen application directory is already the latest
    available dts_shared_binary - or a deliberate, operator-approved
    decision to keep the bundled one. It handles three cases
    automatically:

      1. No local dts_shared_binary at all       -> download it. No
         prompt: installation cannot proceed without a runtime artifact.
      2. Local version matches the latest release -> report and continue.
      3. A newer release is available             -> prompt; bare Enter
         keeps the bundled runtime (the safe default).

    Uses the GitHub Releases API (never the HTML releases page), locates
    the runtime asset by filename (dts_binary.zip - never array
    position, since nothing guarantees it's first), and verifies its
    SHA-256 digest (as published by the API alongside the asset) before
    ever extracting it. The existing bundled runtime, if any, is never
    removed until a replacement has been downloaded, verified, AND
    successfully extracted - see Expand-DeltaRuntimeArtifact for how the
    staging-directory approach makes that guarantee hold even though
    extraction itself is a single Expand-Archive call.
#>

$Script:DeltaRuntimeArtifactApiUrl    = 'https://api.github.com/repos/PreventionWeb/delta/releases/latest'
$Script:DeltaRuntimeArtifactAssetName = 'dts_binary.zip'

# ---------------------------------------------------------------------------
# Version reading and comparison
# ---------------------------------------------------------------------------

function Get-DeltaRuntimeLocalVersion {
    <#
      Reads the "version" field out of <RuntimeDirectory>\package.json.
      Returns $null - never throws - if the directory, the file, or the
      field don't exist, or the file isn't valid JSON: every caller
      treats "could not determine a local version" as its own distinct,
      explicit case rather than one this function decides on their
      behalf.
    #>
    param([Parameter(Mandatory)][string]$RuntimeDirectory)

    $packageJsonPath = Join-Path -Path $RuntimeDirectory -ChildPath 'package.json'
    if (-not (Test-Path -LiteralPath $packageJsonPath)) {
        return $null
    }

    try {
        $package = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }

    if (-not $package -or -not $package.PSObject.Properties['version'] -or -not $package.version) {
        return $null
    }

    return [string]$package.version
}

function ConvertTo-DeltaComparableVersion {
    <#
      Normalizes a version string - with or without a leading v/V, with
      2-4 dotted numeric components, and tolerant of a trailing
      pre-release/build suffix (e.g. "-beta") - into a [version] for
      ordinal comparison. Returns $null, never throws, for anything that
      doesn't start with a recognizable dotted-numeric run, so callers
      always get a definite "cannot compare" signal instead of a
      half-parsed guess.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RawVersion)

    $trimmed = $RawVersion.Trim().TrimStart('v', 'V')
    $match = [regex]::Match($trimmed, '^\d+(\.\d+){0,3}')
    if (-not $match.Success) {
        return $null
    }

    $parts = @($match.Value -split '\.')
    while ($parts.Count -lt 2) {
        $parts += '0'
    }

    try {
        return [version]($parts -join '.')
    }
    catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# GitHub Releases API
# ---------------------------------------------------------------------------

function Get-DeltaLatestReleaseInfo {
    <#
      Queries the public DELTA GitHub Releases API (never the HTML
      releases page) for the latest release, and locates the runtime
      asset within it by exact filename match against
      $Script:DeltaRuntimeArtifactAssetName - never by array position,
      since nothing about the API's asset ordering is documented or
      guaranteed. A User-Agent header is required - GitHub's API
      rejects anonymous requests without one - and no auth token is
      sent, since the repository is public.

      Returns $null on any failure to reach GitHub or to parse a usable
      response. The caller decides what that means (fall back to the
      bundled runtime, or abort) since that decision depends on whether
      a bundled runtime already exists, which this function has no
      reason to know about.

      AssetUrl/AssetDigestSha256 on the returned object are both $null
      if the release exists but no dts_binary.zip asset was found on it
      - again left for the caller to interpret, since "no runtime asset
      on the latest release" only matters if a download is actually
      about to be attempted.
    #>

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri $Script:DeltaRuntimeArtifactApiUrl `
            -Headers @{ 'User-Agent' = 'DELTA-Windows-Installer' } -UseBasicParsing -ErrorAction Stop
    }
    catch {
        return $null
    }

    if (-not $release -or -not $release.tag_name) {
        return $null
    }

    $asset = $release.assets | Where-Object { $_.name -eq $Script:DeltaRuntimeArtifactAssetName } | Select-Object -First 1

    $digest = $null
    if ($asset -and $asset.PSObject.Properties['digest'] -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $digest = $Matches[1].ToUpperInvariant()
    }

    return [PSCustomObject]@{
        TagName           = $release.tag_name
        Version           = $release.tag_name.ToString().TrimStart('v', 'V')
        AssetUrl          = if ($asset) { $asset.browser_download_url } else { $null }
        AssetDigestSha256 = $digest
    }
}

# ---------------------------------------------------------------------------
# Download, verification, extraction
# ---------------------------------------------------------------------------

function Save-DeltaRuntimeArtifactDownload {
    <#
      Downloads $Url to $DownloadPath (the ".download" staging name -
      never the final "dts_binary.zip" name directly, so a process that
      dies mid-download never leaves a file that looks like a complete,
      valid zip). Returns $true/$false rather than throwing - a failed
      download is an expected, handled outcome here (see Error Handling
      in this feature's design notes), not a script-ending condition.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DownloadPath
    )

    Write-Step 'Downloading the latest runtime...'
    Write-Detail "Source: $Url"
    Write-Detail "Target: $DownloadPath"

    if (Test-Path -LiteralPath $DownloadPath) {
        Remove-Item -LiteralPath $DownloadPath -Force
    }

    # Invoke-WebRequest's default progress-bar rendering can make a
    # download dramatically slower in some hosts (confirmed directly
    # while testing this function) - suppressed for the duration of this
    # one call only, restored in finally.
    $previousProgressPreference = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $DownloadPath -UseBasicParsing -ErrorAction Stop
    }
    catch {
        return $false
    }
    finally {
        $ProgressPreference = $previousProgressPreference
    }

    if (-not (Test-Path -LiteralPath $DownloadPath) -or (Get-Item -LiteralPath $DownloadPath).Length -eq 0) {
        return $false
    }

    Write-Success '    Download complete.'
    return $true
}

function Test-DeltaRuntimeArtifactDigest {
    <#
      Verifies $DownloadPath's SHA-256 hash against $ExpectedSha256 (the
      digest the GitHub Releases API published for this asset). A
      missing expected digest is treated the same as a mismatch - fails
      verification - since there is no other trustworthy value to check
      against, and this feature's entire safety contract depends on
      never extracting an unverified download.
    #>
    param(
        [Parameter(Mandatory)][string]$DownloadPath,
        [AllowEmptyString()][string]$ExpectedSha256
    )

    Write-Step 'Verifying download...'

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        Write-Detail 'No SHA-256 digest was published for this asset - cannot verify.'
        return $false
    }

    $actualSha256 = (Get-FileHash -Path $DownloadPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualSha256 -ne $ExpectedSha256) {
        Write-Detail "Expected: $ExpectedSha256"
        Write-Detail "Computed: $actualSha256"
        return $false
    }

    Write-Success '    Checksum verified.'
    return $true
}

function Expand-DeltaRuntimeArtifact {
    <#
      Extracts $ZipPath into a fresh, private staging directory under
      %TEMP% first, and only moves the result into $RuntimeDirectory
      once staging is confirmed to actually contain a usable
      dts_shared_binary\package.json. This is what makes "never remove
      the existing runtime until the replacement has been fully
      downloaded, verified, AND extracted" hold true even though
      extraction itself is a single Expand-Archive call: extracting
      directly into $RuntimeDirectory would otherwise require deleting
      (or overwriting into) whatever is already there before knowing the
      new archive is actually valid.

      Returns $true/$false rather than throwing - the caller decides
      whether a failure here is fatal (no existing runtime to fall back
      to) or recoverable (existing runtime is left untouched).
    #>
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$RuntimeDirectory
    )

    Write-Step 'Extracting runtime...'

    $stagingDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "delta-runtime-$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $stagingDirectory -ItemType Directory -Force | Out-Null

    try {
        try {
            Expand-Archive -LiteralPath $ZipPath -DestinationPath $stagingDirectory -Force -ErrorAction Stop
        }
        catch {
            return $false
        }

        $extractedRuntime = Join-Path -Path $stagingDirectory -ChildPath 'dts_shared_binary'
        $extractedPackageJson = Join-Path -Path $extractedRuntime -ChildPath 'package.json'
        if (-not (Test-Path -LiteralPath $extractedPackageJson)) {
            return $false
        }

        if (Test-Path -LiteralPath $RuntimeDirectory) {
            Remove-Item -LiteralPath $RuntimeDirectory -Recurse -Force
        }

        Move-Item -LiteralPath $extractedRuntime -Destination $RuntimeDirectory
        return $true
    }
    finally {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Shared download -> verify -> extract sequence
# ---------------------------------------------------------------------------

function Invoke-DeltaRuntimeArtifactUpdate {
    <#
      The download/verify/extract/validate sequence shared by Scenario 1
      (no local runtime at all) and Scenario 3 (operator chose to
      update) - the only difference between them is what a failure
      means: Scenario 1 has no existing runtime to fall back to, so any
      failure here aborts installation; Scenario 3 already has a working
      bundled runtime, so the same failures instead degrade to "keep
      using the bundled runtime". That distinction is $HasExistingRuntime.

      Every failure path here matches the design's error-handling
      contract exactly: missing runtime asset, download failure, and
      SHA-256 mismatch are all "fall back if possible, abort if not" -
      never a partial or silently-corrupted install.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Latest,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$DownloadPath,
        [Parameter(Mandatory)][string]$RuntimeDirectory,
        [Parameter(Mandatory)][bool]$HasExistingRuntime
    )

    if (-not $Latest.AssetUrl) {
        if ($HasExistingRuntime) {
            Write-Host ''
            Write-Host "No '$($Script:DeltaRuntimeArtifactAssetName)' asset was found on the latest release ($($Latest.TagName))." -ForegroundColor Yellow
            Write-Host ''
            Write-Host 'The installer will continue using the bundled runtime.'
            return
        }
        Stop-Setup "No '$($Script:DeltaRuntimeArtifactAssetName)' asset was found on the latest release ($($Latest.TagName)), and no bundled runtime artifact is available.`n`nInstallation cannot continue because no runtime artifact is available."
    }

    $downloaded = Save-DeltaRuntimeArtifactDownload -Url $Latest.AssetUrl -DownloadPath $DownloadPath
    if (-not $downloaded) {
        if ($HasExistingRuntime) {
            Write-Host ''
            Write-Host 'Unable to download the DELTA runtime artifact.' -ForegroundColor Yellow
            Write-Host ''
            Write-Host 'The installer will continue using the bundled runtime.'
            return
        }
        Stop-Setup "Unable to download the DELTA runtime artifact.`n`nInstallation cannot continue because no runtime artifact is available."
    }

    $verified = Test-DeltaRuntimeArtifactDigest -DownloadPath $DownloadPath -ExpectedSha256 $Latest.AssetDigestSha256
    if (-not $verified) {
        Remove-Item -LiteralPath $DownloadPath -Force -ErrorAction SilentlyContinue
        if ($HasExistingRuntime) {
            Write-Host ''
            Write-Host 'Downloaded runtime artifact failed SHA-256 verification.' -ForegroundColor Yellow
            Write-Host ''
            Write-Host 'The installer will continue using the existing bundled runtime.'
            return
        }
        Stop-Setup "Downloaded runtime artifact failed SHA-256 verification.`n`nInstallation cannot continue because no valid runtime artifact is available."
    }

    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
    Rename-Item -LiteralPath $DownloadPath -NewName (Split-Path -Path $ZipPath -Leaf)

    $extracted = Expand-DeltaRuntimeArtifact -ZipPath $ZipPath -RuntimeDirectory $RuntimeDirectory
    if (-not $extracted) {
        Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
        if ($HasExistingRuntime) {
            Stop-Setup "Extraction of the downloaded runtime artifact failed, or did not produce a usable package.json. The existing bundled runtime at $RuntimeDirectory was left untouched."
        }
        Stop-Setup 'Extraction of the downloaded runtime artifact failed, or did not produce a usable package.json. Installation cannot continue because no runtime artifact is available.'
    }

    $extractedVersion = Get-DeltaRuntimeLocalVersion -RuntimeDirectory $RuntimeDirectory
    if (-not $extractedVersion) {
        Stop-Setup "Runtime extraction completed, but package.json could not be read afterward at $RuntimeDirectory."
    }

    Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue

    Write-Host ''
    if ($HasExistingRuntime) {
        Write-Success 'DELTA runtime updated successfully.'
    }
    else {
        Write-Success 'Runtime artifact installed successfully.'
    }
    Write-Host ''
    Write-Host 'Version:'
    Write-Host $extractedVersion
}

# ---------------------------------------------------------------------------
# Scenario 3 prompt
# ---------------------------------------------------------------------------

function Read-DeltaRuntimeUpdateChoice {
    <#
      Displays the "newer runtime available" summary and asks whether to
      update or keep the bundled runtime. Bare Enter defaults to
      "Continue" (keep the bundled runtime) - deliberately the
      conservative default, unlike Read-ExistingPostgresChoice's default
      of "Reuse": reusing an existing PostgreSQL instance is this
      installer's recommended path, but silently replacing a working
      runtime artifact on every run is not something an operator should
      have to opt out of by remembering to type "1".
    #>
    param(
        [Parameter(Mandatory)][string]$LocalVersion,
        [Parameter(Mandatory)][string]$LatestVersion
    )

    Write-Host ''
    Write-Host 'A newer DELTA runtime artifact is available.'
    Write-Host ''
    Write-Host 'Bundled version:'
    Write-Host $LocalVersion
    Write-Host ''
    Write-Host 'Latest version:'
    Write-Host $LatestVersion
    Write-Host ''
    Write-Host '1) Continue using the bundled runtime'
    Write-Host '2) Download and replace with the latest runtime'
    Write-Host ''

    while ($true) {
        $choice = Read-Host -Prompt 'Choose an option [1]'
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }

        switch ($choice.Trim()) {
            '1' { return 'Continue' }
            '2' { return 'Update' }
        }
        Write-Host "'$choice' is not a valid option." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function Update-DeltaRuntimeArtifact {
    <#
      Ensures $RuntimeDirectory (the dts_shared_binary artifact shipped
      inside the installer repository) holds the latest available DELTA
      runtime before the rest of the installer touches it - the single
      function every caller needs. $ZipPath/its ".download" staging file
      are both created directly under $ProjectRoot, alongside
      $RuntimeDirectory itself, matching how the artifact has always
      been documented (docs/00-overview.md, docs/02-windows-
      installation.md): unpacked at the installer repository's own root,
      never nested or cached elsewhere the way Node/PostgreSQL/PostGIS
      installers are (see $Script:InstallersDirectory in setup.ps1) -
      this artifact is never meant to be reused across runs the way
      those are, so nothing here persists past a successful extraction.

      Three outcomes, all logged distinctly:
        1. $RuntimeDirectory doesn't exist yet -> download, no prompt.
        2. It exists and already matches the latest release (or is
           newer, or can't be numerically compared) -> report, continue.
        3. It exists and a newer release is available -> prompt,
           defaulting to keeping the bundled runtime.

      GitHub connectivity failures and SHA-256 verification failures
      both degrade to "keep using the bundled runtime" whenever
      $RuntimeDirectory already exists, and abort installation only when
      it doesn't - see Invoke-DeltaRuntimeArtifactUpdate for where that
      distinction is actually enforced.
    #>
    param(
        [Parameter(Mandatory)][string]$RuntimeDirectory,
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    Write-PhaseBanner 'DELTA Runtime Artifact'

    $zipPath      = Join-Path -Path $ProjectRoot -ChildPath 'dts_binary.zip'
    $downloadPath = "$zipPath.download"

    $runtimeExists = Test-Path -LiteralPath $RuntimeDirectory

    Write-Step 'Checking for the latest DELTA runtime release...'
    $latest = Get-DeltaLatestReleaseInfo

    if (-not $latest) {
        if ($runtimeExists) {
            Write-Host ''
            Write-Host 'Unable to contact GitHub.' -ForegroundColor Yellow
            Write-Host ''
            Write-Host 'The installer will continue using the bundled runtime.'
            return
        }
        Stop-Setup "Unable to download the DELTA runtime artifact.`n`nInstallation cannot continue because no runtime artifact is available."
    }

    if (-not $runtimeExists) {
        Write-Host ''
        Write-Host 'No bundled DELTA runtime artifact was found.'
        Write-Host ''
        Invoke-DeltaRuntimeArtifactUpdate -Latest $latest -ZipPath $zipPath -DownloadPath $downloadPath `
            -RuntimeDirectory $RuntimeDirectory -HasExistingRuntime:$false
        return
    }

    $localVersion = Get-DeltaRuntimeLocalVersion -RuntimeDirectory $RuntimeDirectory
    if (-not $localVersion) {
        Stop-Setup "The bundled DELTA runtime at $RuntimeDirectory does not have a readable 'version' in its package.json - cannot determine its version."
    }

    $localComparable  = ConvertTo-DeltaComparableVersion -RawVersion $localVersion
    $latestComparable = ConvertTo-DeltaComparableVersion -RawVersion $latest.Version

    if (-not $localComparable -or -not $latestComparable -or $localComparable -ge $latestComparable) {
        Write-Host ''
        Write-Host 'Bundled DELTA runtime:'
        Write-Host $localVersion
        Write-Host ''
        Write-Host 'Latest release:'
        Write-Host $latest.Version
        Write-Host ''
        if (-not $localComparable -or -not $latestComparable) {
            Write-Detail 'Unable to compare versions numerically - continuing with the bundled runtime.'
        }
        Write-Host 'The bundled runtime is already up to date.'
        return
    }

    $decision = Read-DeltaRuntimeUpdateChoice -LocalVersion $localVersion -LatestVersion $latest.Version
    if ($decision -eq 'Continue') {
        Write-Detail 'Continuing with the bundled runtime.'
        return
    }

    Invoke-DeltaRuntimeArtifactUpdate -Latest $latest -ZipPath $zipPath -DownloadPath $downloadPath `
        -RuntimeDirectory $RuntimeDirectory -HasExistingRuntime:$true
}

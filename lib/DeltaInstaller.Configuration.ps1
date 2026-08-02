<#
.SYNOPSIS
    Loads .env.installer - the single source of truth for pinned
    third-party installer versions, filenames, and download URLs.

.DESCRIPTION
    Dot-sourced after lib\DeltaInstaller.Common.ps1 (whose Stop-Setup this
    file's own fail-fast error path calls - see that file's own header for
    the $Script:ProjectRoot/dot-sourcing convention this follows, and for
    why $Script:ProjectRoot must already be set before this line rather
    than computed inside it) by any entry-point script OR library file
    that needs $Script:InstallerConfig.

    Node.js, PostgreSQL, PostGIS, and NGINX version numbers, installer
    filenames, and download URLs used to be literal values scattered
    across setup.ps1 and setup-nginx.ps1. They now all live in
    .env.installer, at the repository root, parsed into
    $Script:InstallerConfig by Import-DeltaInstallerConfig, below - e.g.
    $Script:InstallerConfig.POSTGRES_VERSION,
    $Script:InstallerConfig.NODE_URL.

    Import-DeltaInstallerConfig is idempotent - see its own header - so
    this file is deliberately safe to dot-source from more than one place
    in the same run (an entry-point script AND a lib\ file it dot-sources,
    in either order) without re-parsing .env.installer or caring which one
    got there first. This is what lets library files that need installer
    metadata (e.g. a future lib\DeltaDoctor.IIS.ps1 reading IIS_ARR_URL)
    dot-source this file themselves, exactly the way they already
    dot-source DeltaInstaller.Common.ps1 themselves, rather than trusting
    every current and future caller to remember to load it first.

    See Import-DeltaInstallerConfig's own header for the exact parser
    rules (blank lines, comments, KEY=VALUE, whitespace, duplicate keys,
    fail-fast). $Script:RequiredInstallerConfigKeys, immediately below,
    doubles as this file's "known key" list: every key parsed from
    .env.installer that isn't in it produces a non-fatal
    "Unknown installer configuration key" warning (Get-
    DeltaInstallerConfigKeySuggestion below proposes a correction when one
    parsed key is a plausible typo of a known one), purely to catch typos
    like POSTGRES_VERSON early - it never stops the installer by itself.
    Only genuinely missing/blank keys from $Script:RequiredInstallerConfigKeys
    do that, exactly as before.
#>

# ---------------------------------------------------------------------------
# Known / required configuration keys
#
# Every key .env.installer is currently expected to define, grouped by the
# component it configures. This list serves two purposes:
#
#   1. Required-key validation - Import-DeltaInstallerConfig calls
#      Stop-Setup if any of these is missing or blank once parsing
#      finishes (fail-fast - see that function's own header).
#   2. Known-key detection - any parsed key NOT in this list produces a
#      non-fatal "unknown key" warning (see Import-DeltaInstallerConfig),
#      so a typo like POSTGRES_VERSON is caught even on a run where the
#      correctly-spelled key also happens to be present.
#
# Future optional keys (POSTGRES_SHA256, POSTGIS_SHA256, NODE_SHA256,
# NGINX_SHA256, IIS_VERSION, IIS_URL, DELTA_RUNTIME_VERSION, etc. - see the
# feature request this file implements) need NO parser changes to be read
# from .env.installer: $Script:InstallerConfig exposes every key present
# in the file automatically. This list only needs a new entry once a key
# becomes either required (so a missing value fails fast) or simply known
# (so it stops triggering the unknown-key warning) - whichever is needed
# first; a key can be added here as "known but not required" by splitting
# this into two lists if that distinction is ever needed, but there is no
# such key yet.
# ---------------------------------------------------------------------------
$Script:RequiredInstallerConfigKeys = @(
    # DELTA (this installer's own version). NOT currently read by any
    # script - lib\DeltaInstaller.Version.ps1's own
    # $Script:DeltaInstallerVersion remains the sole authoritative source
    # (see that file's own header for why - a CI release gate dot-sources
    # it standalone). Kept here, and required, for future diagnostics/
    # installer reporting - the duplication is intentional, not dead
    # config to be pruned.
    'DELTA_VERSION',

    # Node.js
    'NODE_VERSION',
    'NODE_INSTALLER',
    'NODE_URL',

    # PostgreSQL
    'POSTGRES_VERSION',
    'POSTGRES_INSTALLER',
    'POSTGRES_URL',

    # PostGIS
    'POSTGIS_VERSION',
    'POSTGIS_INSTALLER',
    'POSTGIS_URL',

    # NGINX
    'NGINX_VERSION',
    'NGINX_INSTALLER',
    'NGINX_URL'
)

# Initialized here, unconditionally, rather than left for Import-
# DeltaInstallerConfig's own idempotency check to discover on first read -
# Set-StrictMode -Version Latest (every entry-point script in this project
# sets it) throws on a read of a $Script: variable that was never assigned
# at all, and that check runs on every single call, including the very
# first one in a given process, before anything has been parsed yet. Same
# reasoning as $Script:DeltaReverseProxyHandoverOccurred in
# lib\DeltaInstaller.Common.ps1 - see that file's own comment.
$Script:InstallerConfig = $null

function Get-DeltaLevenshteinDistance {
    <#
      Standard Levenshtein edit distance (single-character insertions,
      deletions, substitutions) between $Left and $Right. Pure string
      math, no installer-specific knowledge - the only caller is Get-
      DeltaInstallerConfigKeySuggestion, below.
    #>
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    $leftLength  = $Left.Length
    $rightLength = $Right.Length

    $distance = [Array]::CreateInstance([int], ($leftLength + 1), ($rightLength + 1))
    for ($i = 0; $i -le $leftLength; $i++)  { $distance[$i, 0] = $i }
    for ($j = 0; $j -le $rightLength; $j++) { $distance[0, $j] = $j }

    # Each index expression below is deliberately parenthesized -
    # $distance[$i - 1, $j] (unparenthesized) is a PowerShell 5.1 parser
    # trap: it throws "does not contain a method named 'op_Subtraction'"
    # instead of indexing with ($i - 1), because the comma-separated
    # multi-dimensional index list doesn't combine with a bare '-'
    # the way a normal arithmetic expression does. $distance[($i - 1), $j]
    # parses correctly.
    for ($i = 1; $i -le $leftLength; $i++) {
        for ($j = 1; $j -le $rightLength; $j++) {
            $substitutionCost = if ($Left[$i - 1] -eq $Right[$j - 1]) { 0 } else { 1 }
            $deletion     = $distance[($i - 1), $j] + 1
            $insertion    = $distance[$i, ($j - 1)] + 1
            $substitution = $distance[($i - 1), ($j - 1)] + $substitutionCost
            $distance[$i, $j] = [Math]::Min([Math]::Min($deletion, $insertion), $substitution)
        }
    }

    return $distance[$leftLength, $rightLength]
}

function Get-DeltaInstallerConfigKeySuggestion {
    <#
      Returns whichever entry of $Script:RequiredInstallerConfigKeys is
      the closest case-insensitive Levenshtein match to $UnknownKey, or
      $null if even the closest one is too far away to plausibly be the
      same typo'd key. The distance-3 cutoff is generous enough to catch
      a transposed/missing/extra/wrong letter (e.g. POSTGRES_VERSON ->
      POSTGRES_VERSION is distance 1) without suggesting an unrelated key
      for a genuinely different, intentional one.
    #>
    param([Parameter(Mandatory)][string]$UnknownKey)

    $bestMatch    = $null
    $bestDistance = [int]::MaxValue

    foreach ($knownKey in $Script:RequiredInstallerConfigKeys) {
        $distance = Get-DeltaLevenshteinDistance -Left $UnknownKey.ToUpperInvariant() -Right $knownKey.ToUpperInvariant()
        if ($distance -lt $bestDistance) {
            $bestDistance = $distance
            $bestMatch    = $knownKey
        }
    }

    if ($bestMatch -and $bestDistance -le 3) {
        return $bestMatch
    }
    return $null
}

function Write-DeltaInstallerConfigWarning {
    <#
      A small, self-contained "WARNING" block in this project's own
      Write-Host-based console vocabulary (see lib\DeltaInstaller.Common.ps1)
      - deliberately not the built-in Write-Warning cmdlet, whose output
      goes through $WarningPreference/the warning stream rather than this
      project's established plain Write-Host convention, and deliberately
      not setup.ps1's own Show-Warning, which is local to that script and
      not visible here (this file is also dot-sourced by setup-nginx.ps1).

      $Message is deliberately NOT [Parameter(Mandatory)]: PowerShell's
      mandatory-parameter validation rejects an empty-string ELEMENT
      inside an array argument, not just a null/empty array itself - and
      blank lines (''), used here for readable spacing between sections
      of a warning, are exactly that.
    #>
    param([string[]]$Message)

    Write-Host ''
    Write-Host 'WARNING' -ForegroundColor Yellow
    Write-Host ''
    foreach ($line in $Message) {
        Write-Host $line
    }
    Write-Host ''
}

function Import-DeltaInstallerConfig {
    <#
      Parses .env.installer at $Path into an ordered hashtable
      ($Script:InstallerConfig), one entry per configuration line.

      Idempotent: if $Script:InstallerConfig is already set (a prior call
      in this same process already parsed it - see the module-level
      $Script:InstallerConfig = $null initialization above), this returns
      that cached value immediately without touching $Path, re-reading
      the file, or re-running any validation/warning logic a second time.
      This is deliberate, not an optimization afterthought: it is what
      lets any entry-point script AND any lib\ file dot-source
      DeltaInstaller.Configuration.ps1 and call this function freely,
      in any order, any number of times in the same run, without either
      one needing to know whether the other already did - see this file's
      own .DESCRIPTION. $Path is only ever consulted on the first call;
      passing a different $Path on a later call in the same process is
      silently ignored, exactly like calling it with no arguments would be
      if $Path weren't Mandatory.

      Parser rules (first call only):
        - Blank lines (empty, or whitespace-only after trimming) are
          ignored.
        - Lines whose first non-whitespace character is '#' are treated
          as comments and ignored entirely - there is no inline/trailing
          '#' comment support, only whole-line comments.
        - Every other line must be KEY=VALUE - the first '=' on the line
          is the separator; both KEY and VALUE are trimmed of leading/
          trailing whitespace. There is no quoting, escaping, or
          variable-expansion support (by design - see this file's own
          .DESCRIPTION and the feature request it implements).
        - Duplicate keys: last one wins. A key defined twice simply has
          its value overwritten by the later line, silently - the same
          behavior as assigning the same PowerShell variable twice.
        - Insertion order is preserved: $config is an [ordered] hashtable,
          populated in the same top-to-bottom order .env.installer is
          read in, so $Script:InstallerConfig's own key order matches the
          file's for easier debugging (e.g. dumping it with
          .GetEnumerator()) - not required for correctness, since lookups
          are always by key, but kept intentionally rather than left to
          chance.

      Fail-fast behavior (Stop-Setup - a terminating throw, see
      lib\DeltaInstaller.Common.ps1 - never a silent fallback):
        - $Path does not exist.
        - A non-blank, non-comment line has no '=' (or one at position 0,
          i.e. an empty key).
        - Once parsing finishes, any key in $Script:RequiredInstallerConfigKeys
          is absent from the file, or present with a blank/whitespace-only
          value.

      Non-fatal warning behavior: any parsed key NOT in
      $Script:RequiredInstallerConfigKeys triggers a "Unknown installer
      configuration key" warning (Write-DeltaInstallerConfigWarning),
      with a "Did you mean <X>?" suggestion when Get-
      DeltaInstallerConfigKeySuggestion finds a close enough match - this
      exists purely to catch spelling mistakes (e.g. POSTGRES_VERSON)
      early, and never stops the installer by itself, independent of
      whatever the separate required-key check above decides.

      Future keys (POSTGRES_SHA256, IIS_URL, DELTA_RUNTIME_VERSION, etc.)
      need no changes to this parser to be read - they're exposed on the
      returned hashtable automatically the moment they appear in
      .env.installer. Only $Script:RequiredInstallerConfigKeys, above,
      ever needs updating: add a key there once it becomes mandatory (to
      get fail-fast validation), or simply to stop it from triggering the
      unknown-key warning.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if ($Script:InstallerConfig) {
        return $Script:InstallerConfig
    }

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        Stop-Setup "Installer configuration file not found: $Path"
    }

    $config = [ordered]@{}

    $lineNumber = 0
    foreach ($rawLine in Get-Content -Path $Path) {
        $lineNumber++
        $line = $rawLine.Trim()

        if (-not $line -or $line.StartsWith('#')) {
            continue
        }

        $separatorIndex = $line.IndexOf('=')
        if ($separatorIndex -lt 1) {
            Stop-Setup "Installer configuration file '$Path' has an invalid line (expected KEY=VALUE) at line ${lineNumber}: $rawLine"
        }

        $key   = $line.Substring(0, $separatorIndex).Trim()
        $value = $line.Substring($separatorIndex + 1).Trim()
        $config[$key] = $value
    }

    foreach ($parsedKey in $config.Keys) {
        if ($Script:RequiredInstallerConfigKeys -notcontains $parsedKey) {
            $suggestion = Get-DeltaInstallerConfigKeySuggestion -UnknownKey $parsedKey
            if ($suggestion) {
                Write-DeltaInstallerConfigWarning -Message @(
                    'Unknown installer configuration key:',
                    '',
                    $parsedKey,
                    '',
                    'Did you mean:',
                    '',
                    "$suggestion ?"
                )
            }
            else {
                Write-DeltaInstallerConfigWarning -Message @(
                    'Unknown installer configuration key:',
                    '',
                    $parsedKey
                )
            }
        }
    }

    foreach ($requiredKey in $Script:RequiredInstallerConfigKeys) {
        if (-not $config.Contains($requiredKey) -or [string]::IsNullOrWhiteSpace($config[$requiredKey])) {
            Stop-Setup "Installer configuration file '$Path' is missing required key: $requiredKey"
        }
    }

    return $config
}

# Runs on every dot-source of this file, but only does real work once per
# process - Import-DeltaInstallerConfig's own idempotency check (see its
# header) makes every dot-source after the first a cheap no-op that
# returns the already-parsed $Script:InstallerConfig unchanged.
$Script:InstallerConfig = Import-DeltaInstallerConfig -Path (Join-Path -Path $Script:ProjectRoot -ChildPath '.env.installer')

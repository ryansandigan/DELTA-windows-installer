# TODO - setup-iis.ps1 Enhancements

## Overview

`setup-nginx.ps1` is the existing, shipped optional reverse-proxy installer for DELTA - see `TODO-setup-nginx-enhancements.md` for its own implementation history. This document is its sibling: the implementation roadmap for `setup-iis.ps1`, an alternative reverse-proxy installer for administrators who standardize on Microsoft IIS instead of NGINX.

Unlike the NGINX document, which tracks incremental enhancements layered onto an already-shipped installer, `setup-iis.ps1` does not exist yet. This document defines the phases required to build it from scratch - but the goal is not a from-scratch design. `setup-iis.ps1` should feel like a sibling of `setup-nginx.ps1`, not an independent project: the same administrator experience (guided prompts, the same confirmation/summary conventions, the same conservative "never silently touch something I don't own" posture), the same shared DELTA-discovery/backend-port/domain helpers from `lib\DeltaInstaller.Common.ps1`, and IIS-native concepts substituted only where NGINX's own concepts (a single self-contained installation directory, a pid file, a directly-bound listening socket) genuinely do not translate.

Phases are implemented one at a time, in order. Do not start a phase before the previous one is marked Completed below.

A note on scope up front, because it shapes several phases below: `setup-nginx.ps1` owns its entire installation - `C:\nginx` either belongs to this installer or the installer refuses to touch it at all. IIS is not like that. A machine can easily already run IIS for entirely unrelated purposes (an intranet site, another application's reverse proxy, SharePoint, whatever) before `setup-iis.ps1` is ever run. This installer must be able to install IIS if it is missing, or add its own DELTA site alongside an existing IIS installation without disturbing anything else already hosted on it. "An existing IIS installation" and "an existing DELTA site" are two different, independently-checked facts here, where for NGINX they were the same fact.

---

## Status

| Phase | Description | Status |
|-------|--------------|--------|
| 1 | Shared DELTA Installation Discovery | Completed |
| 2 | Microsoft IIS Detection | Completed |
| 3 | IIS Installation | Completed |
| 4 | Application Request Routing (ARR) | Completed |
| 5 | Website Discovery | Completed |
| 6 | Website Configuration | Completed |
| 7 | Windows SSL Certificate (.pfx) | Completed |
| 8 | Runtime Management | Not Started (next) |
| 9 | Port Prerequisite Validation | Not Started |
| 10 | Installation Summary | Not Started |

**Renumbering note:** the original roadmap's standalone Phase 7 (Website
Domain) and the original, separately-numbered Phase 8 (SSL Certificate) /
Phase 9 (Existing Certificate Handling) have both been retired as
independent table rows:

- **Website Domain merged into Phase 6.** Once Phase 6 (Website
  Configuration) was actually implemented, `Resolve-DeltaWebsiteDomain`
  turned out to have no natural seam separating "resolve the domain" from
  "configure the website with it" - the resolved domain is consumed
  directly inside Phase 6's own orchestrator, on every invocation, for
  both the website's HTTP binding host header and the generated
  `web.config`'s `__DELTA_SERVER_NAME__` token. There was never going to
  be a second, independent implementation step here. See the retired
  Phase 7 section below (kept for historical context, not deleted) for
  the full note.
- **SSL Certificate and Existing Certificate Handling combined into one
  new Phase 7.** The original roadmap split "import a certificate" and
  "handle an already-imported certificate on rerun" into two separate
  phases: `setup-nginx.ps1`'s own equivalent (`Install-DeltaSslCertificate`)
  already implements both as a single wizard, and IIS's own version
  follows the identical shape - there was no reason to implement them as
  two separate `setup-iis.ps1` phases either.
- Every phase after the original Phase 9 has been renumbered down by two
  accordingly (original 10/11/12 → new 8/9/10).

Phases 1 through 7 are implemented. Implementation should proceed in the order above - each phase's design below assumes every earlier phase is already in place, exactly as `TODO-setup-nginx-enhancements.md`'s own phases build on one another.

---

# 1. Shared DELTA Installation Discovery

## Status: Completed

`setup-iis.ps1` now exists as an initial skeleton, structured as a sibling
of `setup-nginx.ps1` (same header conventions, `Set-StrictMode -Version
Latest`, `$Script:ProjectRoot` computation before dot-sourcing
`lib\DeltaInstaller.Common.ps1`, `Write-SetupBanner`/`Write-PhaseBanner`/
`Write-Detail`/`Write-Success`, and a single top-level try/catch that
converts an uncaught error into the same red failure banner shape
`setup-nginx.ps1` uses).

What it does, in order:

1. Displays the IIS-specific setup banner ("DELTA IIS Setup / Optional
   reverse proxy for DELTA").
2. Calls the shared `Resolve-DeltaInstallation` (no second implementation
   written - see that function's own header in
   `lib\DeltaInstaller.Common.ps1`), which stops the script immediately
   (`Stop-Setup`) if no DELTA installation can be found, before any
   IIS-specific code would ever run.
3. On success, prints a minimal discovery-only summary (installation
   location and `.env` path) - no IIS information appears, since none
   exists yet.
4. Prints a stub notice stating plainly that Phase 1 is complete and that
   Microsoft IIS functionality itself begins in the next development
   phase, then exits successfully (`exit 0`) - this is expected,
   successful completion, not an error.

What was validated: a standalone test harness (dot-sourcing the real
`lib\DeltaInstaller.Common.ps1` and `setup-iis.ps1` function definitions,
then substituting `Get-DeltaInstallPath` per scenario so no real system
state had to be mutated) exercised all three discovery outcomes -
registry-based install found, legacy `C:\DELTA\.env`-style install found,
and no installation at all (clean `Stop-Setup` failure, exit 1) - plus a
live end-to-end run against this machine's own real, registry-registered
DELTA installation. Output formatting (banners, section headers, `Write-
Detail` indentation) matches `setup-nginx.ps1`'s existing conventions in
all cases.

No IIS functionality has been introduced - no `Get-WindowsFeature`/
`Get-WindowsOptionalFeature` detection, no IIS installation, no site or
binding logic. That begins with Phase 2 below, now the next pending phase.

## Objective

Before anything IIS-specific happens, confirm a real DELTA installation actually exists on this machine, via the shared `Resolve-DeltaInstallation` helper.

**Update:** `Resolve-DeltaInstallation` has already been promoted into `lib\DeltaInstaller.Common.ps1`, ahead of `setup-iis.ps1` itself existing - a preparatory refactoring pass moved it out of `setup-nginx.ps1` once it was confirmed to have no NGINX-specific knowledge at all (it only calls `Get-DeltaInstallPath` below and sets two script-scoped variables). `setup-nginx.ps1` was updated to consume the shared copy with no change to its own behavior. Phase 1 of `setup-iis.ps1` itself is therefore just: dot-source `lib\DeltaInstaller.Common.ps1` and call `Resolve-DeltaInstallation` - the promotion work this phase originally called for is already done, and no second copy should ever be written.

Reuse:

```powershell
Resolve-DeltaInstallation
```

(`lib\DeltaInstaller.Common.ps1`) - internally calls `Get-DeltaInstallPath`, which resolves, in order:

1. The Windows Registry key `setup.ps1`'s own `Register-DeltaInstallation` writes (`HKLM\SOFTWARE\PreventionWeb\DELTA`).
2. The legacy `C:\DELTA\.env` convention, for installations that predate the registry key.
3. `$null` if DELTA is not installed at all.

No hardcoded `C:\DELTA` path anywhere in `setup-iis.ps1`, matching `setup-nginx.ps1`'s own Phase 1 requirement exactly.

## Behavior

If no installation is found:

- stop the installer (`Stop-Setup`, the same shared helper `setup-nginx.ps1` already uses)
- display a clear message instructing the administrator to install DELTA first (`Resolve-DeltaInstallation`'s own message currently names `setup-nginx.ps1` specifically, inherited unchanged from before the promotion - revisit whether this should be parameterized once `setup-iis.ps1` is a second real caller of it, so the message names whichever script the administrator actually ran)

Also resolves and stores `$Script:DeltaEnvPath` (`<InstallPath>\.env`), exactly as `setup-nginx.ps1` does - consumed by Phase 6's backend port detection.

---

# 2. Microsoft IIS Detection

## Status: Completed

`setup-iis.ps1` now determines the current Microsoft IIS environment -
detection only, exactly as this phase requires: nothing added installs,
enables, or configures IIS, regardless of what is found. No `Stop-Setup`
path exists anywhere in this phase either - "IIS is not installed" is
reported, not treated as a failure.

What was implemented:

- `Test-DeltaServerManagerAvailable` - `Get-Module -ListAvailable -Name
  ServerManager`, the actual gate deciding which of the two Windows
  Feature APIs is callable (never assumed from the OS name/edition).
- `Get-DeltaIisOperatingSystemInfo` - branches on the above into `Server`/
  `Client`, and separately reads `Win32_OperatingSystem`'s `Caption` via
  `Get-CimInstance` purely for the administrator-facing display string
  (e.g. "Microsoft Windows Server 2025 Standard Evaluation") - the
  display string is never what decides the branch.
- `Get-DeltaIisRequiredFeatureDefinitions` - the explicit Server-role-
  service-name -> Client-optional-feature-name mapping table for the nine
  features this phase's own "Required IIS Features" list calls out (Web
  Server; Management Console; Management Scripting Tools; Static Content;
  Default Document; HTTP Errors; HTTP Redirect; HTTP Logging; Request
  Monitor) - maintained by hand, never assumed to be a mechanical prefix
  substitution, per this phase's own warning.
- `Test-DeltaIisFeatureInstalled` - `Get-WindowsFeature` on Server,
  `Get-WindowsOptionalFeature -Online` on Client; any query failure
  (missing cmdlet, unrecognized name) reports `Missing` rather than
  throwing, since Phase 2 only promises a binary Installed/Missing report.
- `Get-DeltaIisVersion` - reads `HKLM:\SOFTWARE\Microsoft\InetStp`'s
  `VersionString` directly (module-independent, per this phase's own
  "Preferred PowerShell APIs" recommendation), stripping the leading
  "Version " label so the summary shows the bare number (e.g. `10.0`).
  Returns `$null` (reported as "Not Installed") if the key does not exist.
- `Test-DeltaWebAdministrationModuleAvailable` - `Get-Module
  -ListAvailable -Name WebAdministration`. Never calls `Import-Module`
  anywhere in this phase, per its own explicit requirement.
- `Get-DeltaIisDetectionResult` - the orchestrator collecting all of the
  above into one result object. `Installed` is decided from two
  independent signals (the InetStp version key OR the "Web Server"
  feature itself reporting Installed/Enabled), not one - the same
  "never trust a single signal alone" discipline `setup-nginx.ps1`'s own
  `Get-DeltaNginxRuntimeState` already holds.
- `Show-DeltaIisDetectionSummary` - the dedicated "Microsoft IIS"
  detection section (Status, Version, Operating System, Detection
  Mechanism, Management Module, and a column-aligned Required Features
  list), reusing the existing dash-rule/`Write-Detail` formatting
  vocabulary rather than introducing a new style.
- `Show-DeltaIisPhase2StubNotice` - shown only when IIS was NOT found
  installed (there is nothing for Phase 3 to install otherwise, so the
  "installation will be implemented in the next phase" message would be
  misleading if IIS already exists).

  **Superseded by Phase 3:** now that Phase 3 actually installs whatever
  is missing, this stub notice/function has been removed entirely (there
  is no longer a "next phase will handle this" case to defer to) and
  replaced by Phase 3's own real installation flow below - the detection
  logic and result object it stood in front of are unchanged.

## Validation

All seven scenarios this phase calls out were validated without ever
mutating real machine state:

1. **Windows Server detection** - validated live, against this
   development machine's own real state (Windows Server 2025;
   `ServerManager` module present -> Server branch, `Get-WindowsFeature`
   used).
2. **Windows Client detection** - validated via a test harness that
   overrides `Test-DeltaServerManagerAvailable` to return `$false` and
   stubs `Get-WindowsOptionalFeature` - confirmed the Client branch
   correctly selects `Get-WindowsOptionalFeature -Online` and reports the
   "DISM (Get-WindowsOptionalFeature)" detection mechanism.
3. **IIS installed -> version detected** - validated via the same
   harness (`Get-DeltaIisVersion` stubbed to return `'10.0'`); the
   summary displayed `Version: 10.0` and `Status: Installed` correctly.
4. **IIS not installed -> reported cleanly** - validated live (this
   machine has no IIS installed at all: `Get-WindowsFeature -Name
   Web-Server` reports `Installed: False`, `HKLM:\SOFTWARE\Microsoft\
   InetStp` does not exist) - `Status: Not Installed`, `Version: Not
   Installed`, all nine required features reported `Missing`, and
   `Show-DeltaIisPhase2StubNotice` displayed, exit code 0.
5. **Missing role services reported individually** - validated via a
   harness scenario stubbing `Get-WindowsFeature` to report exactly two
   of the nine required features (`Web-Scripting-Tools`,
   `Web-Request-Monitor`) as not installed - the summary listed those two
   as `Missing` and the remaining seven as `Installed`, confirming
   per-feature reporting rather than one aggregate status.
6. **WebAdministration present** - validated via the harness
   (`Test-DeltaWebAdministrationModuleAvailable` stubbed to `$true`) -
   summary reported `Management Module: Available`.
7. **WebAdministration absent** - validated live (this machine has no
   WebAdministration module installed) - summary reported `Management
   Module: Missing`.

No changes were made to the machine in any scenario - confirmed by
`Get-WindowsFeature -Name Web-Server` reporting `Installed: False`
unaffected before and after every run, and by the complete absence of any
`Install-WindowsFeature`/`Enable-WindowsOptionalFeature`/`Import-Module`
call anywhere in this phase's code.

## Platform differences discovered

- `Get-WindowsOptionalFeature` (the `Dism` module) is present on this
  Windows Server machine too, not just on client SKUs - it was only
  exercised here via the test harness (this development machine is
  Server, so the real orchestration always takes the `ServerManager`
  branch), but its presence on Server meant the harness could stub it
  cleanly without needing a real client machine to prove the client
  code path is at least callable.
- Confirmed directly: a plain (non-`[CmdletBinding()]`) PowerShell
  function cannot accept common parameters like `-ErrorAction` - calling
  one with `-ErrorAction Stop` (as both `Test-DeltaIisFeatureInstalled`
  call sites do, deliberately, so a query failure is caught rather than
  silently returning `$null`) throws a parameter-binding error unless the
  function declares `[CmdletBinding()]`. Not a bug in `setup-iis.ps1`
  itself, but a real gotcha hit while building the Windows Client test
  harness (its stub `Get-WindowsFeature`/`Get-WindowsOptionalFeature`
  functions needed `[CmdletBinding()]` added before the mocked "Installed"
  state was actually observed instead of every call silently falling into
  Test-DeltaIisFeatureInstalled's own catch block) - worth remembering for
  any future test harness against real cmdlets in this project.

## Objective

Determine, without installing or changing anything:

- whether IIS is installed at all
- which IIS version is present
- whether the specific role services this installer depends on (see Phase 3) are present, since "IIS is installed" and "every role service this installer needs is installed" are not the same fact - an administrator's existing IIS installation may be missing pieces like the scripting/management tools this installer itself depends on

## Preferred PowerShell APIs

Two ways to query Windows Feature / role-service state exist, and they are not equivalent:

- **`Get-WindowsFeature`** (`ServerManager` module) - the correct API on **Windows Server**. Only available there; the `ServerManager` module does not exist on client SKUs at all.
- **`Get-WindowsOptionalFeature -Online`** (`DISM` module) - the correct API on **Windows 11 / Windows 10** (client SKUs), where IIS ships as an optional feature (`IIS-WebServerRole`, `IIS-WebServer`, etc.) rather than a Server Manager role.

`setup-iis.ps1` must detect which of the two APIs applies (e.g. via `Get-WmiObject Win32_OperatingSystem`'s `ProductType`, or simply `Test-Path` for the presence of the `ServerManager` module) and branch accordingly, rather than assuming Windows Server the way the rest of this project's documentation (CLAUDE.md's own "Windows Server 2025" objective) otherwise does - `setup-iis.ps1` is a strong candidate for being the first script in this project that has to run on both, since IIS-as-a-reverse-proxy is a plausible administrator choice on a Windows 11 developer/pilot machine too.

For querying an **installed** IIS instance's version and live configuration (once present), the two competing management modules are:

- **`WebAdministration`** - the long-standing, most widely-documented module (`New-Website`, `New-WebBinding`, `Get-Website`, `Get-WebAppPoolState`, `Set-WebConfigurationProperty`, the `IIS:\` PSDrive). Ships when the `Web-Scripting-Tools` role service (Server) / `IIS-ManagementScriptingTools` optional feature (client) is installed - itself one of the role services Phase 3 must therefore ensure gets installed, not merely IIS's web-serving role services alone.
- **`IISAdministration`** - Microsoft's newer replacement module, a more modern object model, but less universally documented/relied-upon in existing automation.

**Recommendation:** `WebAdministration`, for the same reason `setup-nginx.ps1` prefers the official, plain ZIP distribution over any wrapper - it is the more universally available, most-documented, longest-supported option, and every cmdlet this roadmap references below (Phases 5-9) assumes it. Confirm this decision at implementation time rather than treating it as settled - if `IISAdministration` turns out to offer something `WebAdministration` cannot for a specific later phase (Phase 8's runtime-state detection is the most likely candidate), document the exception there rather than reversing this default silently.

The detected IIS version (`(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\InetStp\').VersionString` is the traditional, reliable source for this - works whether or not the management PowerShell module is loaded yet) is stored for Phase 10's installation summary.

---

# 3. IIS Installation

## Status: Completed

`setup-iis.ps1` now installs exactly the role services/features Phase 2's
own detection identified as missing from its fixed nine-feature table -
never a broader install, and never a second, independent feature list.
ARR, URL Rewrite, website/application pool creation, bindings,
certificates, reverse-proxy `web.config`, runtime management, and port
prerequisite checks were all deliberately left untouched, per this
phase's own scope boundary - those remain Phases 4 onward.

What was implemented:

- `Get-DeltaIisMissingFeatures` - the subset of a `Get-DeltaIisDetectionResult`
  result not currently installed; the one shared list the confirmation
  prompt, the installer, and post-install verification all act on, so
  there is exactly one definition of "missing" anywhere in this script.
  `Get-DeltaIisDetectionResult` itself (Phase 2) was extended to carry
  `ServerFeatureName`/`ClientFeatureName` on each feature entry (not just
  `Category`/`Label`) specifically so this phase could install straight
  off that result without re-deriving the mapping a second time.
- `Read-DeltaIisInstallConfirmation` - reuses the shared
  `Read-DeltaYesNoConfirmation` (`lib\DeltaInstaller.Common.ps1`)
  rule/body/prompt/rule frame, bare-Enter-means-No, exactly as this
  phase's own requirement to "not introduce another generic Yes/No
  prompt implementation" specifies. Skipped entirely (no prompt at all)
  when nothing is missing.
- `Install-DeltaIisFeatures` - the platform branch. `Install-WindowsFeature
  -Name <missing-only> -IncludeManagementTools` on Server;
  `Enable-WindowsOptionalFeature -Online -FeatureName <missing-only> -All
  -NoRestart` on Client - the caller's own `$OperatingSystemType` (Phase
  2's `Get-DeltaIisOperatingSystemInfo`) decides the branch, so a Client
  OS can never reach `Install-WindowsFeature` and a Server can never
  reach `Enable-WindowsOptionalFeature`. Checks `Test-IsAdministrator`
  (the existing shared check, no new one written) before either cmdlet
  runs at all, and `Stop-Setup`s outright rather than attempting a
  partial install if elevation is missing. Returns each API's own
  `RestartNeeded` signal; does not otherwise treat a "successful" cmdlet
  result as proof anything actually works.
- `Show-DeltaIisRestartRequiredNotice` - the dedicated notice shown when
  either API reports a restart is needed. The orchestration block exits
  (0) immediately after this, without ever calling
  `Confirm-DeltaIisPostInstallState` or `Show-DeltaIisInstallationSummary`
  - per this phase's own "do not continue into future IIS phases... do
  not claim IIS is fully ready" requirement. Windows is never restarted
  automatically.
- `Confirm-DeltaIisPostInstallState` - the authoritative check, run
  against a **freshly re-run** `Get-DeltaIisDetectionResult` (never the
  installation cmdlet's own reported result) taken after
  `Install-DeltaIisFeatures` returns. Two independent, separately-worded
  failures: any required feature still `Missing` (listed individually by
  name, never summarized as a count) and WebAdministration still
  unavailable even though every required feature now reports `Installed`
  (its own diagnostic message, mentioning that a restart may still be
  needed even when neither API flagged one). Never imports
  `WebAdministration` - `Test-DeltaWebAdministrationModuleAvailable`
  (Phase 2, `Get-Module -ListAvailable`) is already sufficient.
- `Show-DeltaIisInstallationSummary` - the Phase 3 "Microsoft IIS
  Installation" summary (Operating System, Status, IIS Version, Required
  Features, Management Module, Restart Required). `Status` reports
  `Already Installed` instead of `Installed` when nothing needed
  installing this run, per this phase's own explicit "do not pretend the
  script installed them again" requirement - a deliberately different
  function from Phase 2's own `Show-DeltaIisDetectionSummary`, not a
  re-skin of it, since this one reports on an install outcome, not
  point-in-time detection.
- Orchestration: already-installed -> summary only, no prompt, no install
  command; missing features -> confirmation -> (declined -> cancelled
  notice, exit 0, nothing changed) or (confirmed -> install -> restart
  needed -> restart notice, exit 0, stop here / no restart needed ->
  post-install verification -> summary, exit 0).

## Server vs. Client behavior

- **Server:** `ServerManager` module present (Phase 2's own gate) ->
  `Install-WindowsFeature -Name <missing Web-* names> -IncludeManagementTools`.
  Never calls `Enable-WindowsOptionalFeature`.
- **Client:** `ServerManager` module absent -> `Enable-WindowsOptionalFeature
  -Online -FeatureName <missing IIS-* names> -All -NoRestart`. Never
  calls `Install-WindowsFeature` or any other `ServerManager` cmdlet -
  validated directly (see Validation below) by making a mocked
  `Install-WindowsFeature` throw if invoked at all during a Client-branch
  scenario.
- Both branches install **only** the specific missing feature names
  passed in - confirmed directly (see Validation) that a partial-install
  scenario (2 of 9 features missing) results in the installation cmdlet
  being called with exactly those 2 names, not all 9.

## Restart handling

Both `Install-WindowsFeature` and `Enable-WindowsOptionalFeature -NoRestart`
report their own `RestartNeeded`/`RestartNeeded` signal independently of
whether an automatic restart actually happens (`-NoRestart` only
suppresses the automatic reboot itself, not the reported need for one).
When either API reports a restart is needed, `setup-iis.ps1` shows
`Show-DeltaIisRestartRequiredNotice` and exits successfully (0) without
ever reaching Post-Installation Verification or the Installation Summary
- confirmed live (see Validation): a real `Install-WindowsFeature` run on
this development machine genuinely reported `RestartNeeded = $true`, and
the script stopped exactly there, printing the restart notice, with none
of the post-install verification/summary output appearing. Windows is
never restarted automatically anywhere in this script.

## Validation

All seven scenarios this phase calls out were validated - a mix of an
isolated test harness (mocked `Install-WindowsFeature`/
`Enable-WindowsOptionalFeature`/`Read-DeltaIisInstallConfirmation`, never
touching the real machine) and real, live runs against this development
machine (Windows Server 2025), including one real IIS installation:

1. **Windows Server, IIS absent - correct missing list, confirmation
   prompt, `Install-WindowsFeature` receives only required features** -
   validated live: the real detection correctly listed all nine features
   as missing, the confirmation prompt displayed them, and (with
   confirmation) the mocked/real installer received exactly the nine
   `Web-*` names from Phase 2's own mapping - never a superset.
2. **Windows Server, partial IIS installation - only missing role
   services installed** - validated via the harness: a detection with
   only `Web-Scripting-Tools`/`Web-Request-Monitor` missing resulted in
   `Install-WindowsFeature` being called with exactly those two names.
3. **Windows Client - `Enable-WindowsOptionalFeature` used, `ServerManager`
   never called** - validated via the harness: a mocked
   `Install-WindowsFeature` was made to `throw` if invoked at all; the
   Client-branch scenario completed successfully via
   `Enable-WindowsOptionalFeature` alone, confirming `Install-WindowsFeature`
   was never reached.
4. **User declines - exit 0, zero system changes** - validated live: a
   real run against this machine (with IIS genuinely absent), answering
   "n" at the confirmation prompt, exited 0 with "No changes have been
   made." and `Get-WindowsFeature -Name Web-Server` confirmed still
   `Installed: False` immediately afterward.
5. **Already-complete installation - no installation command runs,
   summary reports already installed** - validated both ways: via the
   harness (a captured "install was called" sentinel variable remained
   untouched) and live, by re-running `setup-iis.ps1` a second time after
   the real installation below completed - it reported `Status: Already
   Installed` and ran no installation command.
6. **Restart required - restart is clearly reported, later phases are
   not entered** - validated live: the real `Install-WindowsFeature` run
   below reported `RestartNeeded = $true`; the script printed the restart
   notice and exited 0 without ever printing the Installation Summary or
   running Post-Installation Verification. Also validated via the
   harness with a detection deliberately rigged to fail verification if
   reached at all - it was never reached.
7. **Post-install verification failure - installer stops with a clear
   list of missing features** - validated via the harness in two forms:
   a required feature still reporting `Missing` after "installation"
   (stopped, listing that feature by name) and every required feature
   `Installed` but `WebAdministration` still unavailable (stopped with
   the dedicated WebAdministration-specific diagnostic).

**A real installation was also performed** (by explicit request) against
this development machine to validate the full path end-to-end beyond
what mocking alone can prove: `setup-iis.ps1` was run live, all nine
missing features were confirmed and passed to a real `Install-WindowsFeature`
call, which genuinely installed them and reported `RestartNeeded = $true`
- the script correctly stopped at the restart notice. A follow-up
`Get-WindowsFeature`/`Get-Module -ListAvailable -Name WebAdministration`
check confirmed all nine features were genuinely `Installed` and
WebAdministration was genuinely available, even though the CBS
`RebootPending` registry key was not set - a concrete confirmation that
`Install-WindowsFeature`'s own `$result.RestartNeeded` is a more reliable
signal than inferring restart-pending state from a specific registry key
ourselves, and that this phase's decision to trust it directly (rather
than re-deriving it) was correct. Re-running `setup-iis.ps1` again
afterward (without restarting) exercised the real "already installed"
path end-to-end: `Status: Already Installed`, no installation command
ran, and the full summary displayed correctly.

## Objective

If Phase 2 determines IIS (or a role service this installer needs) is missing, install it automatically - the same "installing a fresh copy is something this script is willing to automate" posture `setup-nginx.ps1`'s own header describes for NGINX, extended here to cover partial installations (IIS present, but missing a role service this installer needs) as well as a completely clean machine.

## Windows Server

```powershell
Install-WindowsFeature -Name Web-Server, Web-Common-Http, Web-Default-Doc, Web-Http-Errors, `
    Web-Static-Content, Web-Http-Redirect, Web-Http-Logging, Web-Request-Monitor, `
    Web-Scripting-Tools, Web-Mgmt-Console -IncludeManagementTools
```

Role services and why each is needed:

- `Web-Server` - the umbrella role; installs the core web server engine.
- `Web-Common-Http` / `Web-Default-Doc` / `Web-Http-Errors` / `Web-Static-Content` - baseline HTTP serving, installed by default alongside `Web-Server` in practice but listed explicitly rather than assumed, matching this project's own "never assume, verify" convention.
- `Web-Http-Redirect` - needed for the HTTP→HTTPS redirect behavior Phase 7 must configure once a certificate exists (the direct analogue of `templates\nginx\delta-https.conf`'s own `return 301 https://$host$request_uri;` redirect block).
- `Web-Http-Logging` / `Web-Request-Monitor` - diagnostics, matching this project's own "clear diagnostics" objective.
- `Web-Scripting-Tools` - installs the `WebAdministration` PowerShell module Phase 2 already committed to. Without this role service, every later phase's PowerShell cmdlets are unavailable even though IIS itself is "installed."
- `Web-Mgmt-Console` - the IIS Manager GUI. Not strictly required for this installer's own automation, but included so an administrator troubleshooting a `Broken` state (Phase 8) has the same visual tooling available that NGINX administrators do not have an equivalent of - a deliberate, small UX kindness rather than a hard technical dependency.

## Windows 11 compatibility

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole, IIS-WebServer, `
    IIS-CommonHttpFeatures, IIS-HttpErrors, IIS-HttpRedirect, IIS-HttpLogging, `
    IIS-RequestMonitor, IIS-ManagementConsole, IIS-ManagementScriptingTools -All -NoRestart
```

The feature *names* differ from the Server role-service names above (`IIS-WebServerRole` vs `Web-Server`, etc.) even though the underlying capability is the same - this mapping must be maintained explicitly (e.g. a lookup table keyed by the Phase 2 OS-type detection), not assumed to be a mechanical prefix substitution, since a small number of role services have no direct client-SKU equivalent at all (ARR/URL Rewrite in particular - see Phase 4, which are never Windows Features on either SKU).

## Verification

Mirrors `Install-Nginx`'s own "installation appeared to succeed, verify the thing that must now exist actually does" pattern (`Test-Path -LiteralPath $Script:NginxExePath` there) - here, re-running Phase 2's own detection immediately after installation and confirming every required role service now reports Installed, rather than trusting `Install-WindowsFeature`'s own exit code alone. A restart requirement (`$result.RestartNeeded`) must be surfaced clearly to the administrator, not silently ignored - unlike NGINX, some IIS role service installations can require a reboot before they are actually usable, and this installer must never proceed past this phase pretending otherwise.

---

# 4. Application Request Routing (ARR)

## Status: Completed

`setup-iis.ps1` now ensures URL Rewrite and ARR are installed and that
`system.webServer/proxy` is enabled machine-wide - never creating a
website, application pool, binding, or certificate, per this phase's own
scope boundary.

### Implementation

- `Get-DeltaArrRequiredComponents` - the two-component table (URL
  Rewrite, ARR), each entry carrying its `DisplayNamePattern`, a fully-
  resolved `ModuleFilePath`, `PackageFileName`, `DownloadUrl`, and
  `LogFileName`. Detection-only data; nothing here installs anything.
- `Test-DeltaArrComponentInstalled` - **AND**, not OR, of two signals: a
  matching Programs-and-Features registry entry
  (`Get-InstalledProgramInfo`, the existing shared registry-based lookup
  this project already uses for PostgreSQL, never `Win32_Product`) and
  the component's own native module DLL actually present on disk. This
  is the opposite combination from Phase 2/3's own "OR" ("Installed" =
  version-key OR feature-check) - deliberately, because the two cases are
  not symmetric (see "Platform differences discovered" below for why
  this specific asymmetry was not just theoretical here).
- `Test-DeltaIisProxyEnabled` - `Get-WebConfigurationProperty -Filter
  system.webServer/proxy -Name enabled -PSPath MACHINE/WEBROOT/APPHOST`.
  Returns `$false` (never throws) if WebAdministration is unavailable or
  the property can't be read.
- `Get-DeltaArrDetectionResult` / `Show-DeltaArrDetectionSummary` - the
  same detect-then-summarize shape Phase 2/3 already established, scaled
  to this phase's own two components plus the proxy setting.
- `Read-DeltaArrInstallConfirmation` - reuses the shared
  `Read-DeltaYesNoConfirmation`, default No, per this phase's own "do not
  introduce another generic Yes/No prompt implementation" requirement.
  Lists missing components and/or the pending proxy-enable change
  explicitly. Skipped entirely or shown with an empty missing-components
  list when only the proxy setting itself is pending - `$MissingComponents`
  needed `[AllowEmptyCollection()]` for this (see "Bugs found" below).
- `Get-DeltaArrComponentPackage` / `Install-DeltaArrComponent` - mirrors
  `Get-NginxPackage`'s own "local `installers\` cache preferred over a
  fresh download" behavior, then installs silently via
  `Start-ProcessWithActivityIndicator` + `msiexec /qn /norestart /log`
  (the exact same shared activity-indicator wrapper and log-file
  convention `setup.ps1`'s own `Install-NodeMsi` already uses for
  Node.js) - not a bare `Start-Process` call. Exit code 0 = success;
  3010 = success but restart required - unlike `Install-NodeMsi`'s own
  "3010 is merely recommended" stance for Node.js, this phase treats
  3010 as a hard stop before Phase 5, per its own requirement that
  `system.webServer/proxy` cannot reliably be configured until after
  that reboot. Any other exit code is an unconditional failure.
- `Confirm-DeltaArrPostInstallState` - re-runs
  `Get-DeltaArrDetectionResult` after installation and treats **that**
  result as authoritative, never `msiexec`'s own reported exit code
  alone. Stops with a specific list of any component still `Missing`,
  then (only once components are confirmed installed) enables the proxy
  setting and re-verifies it, stopping if it still reads back disabled.
- `Invoke-DeltaArrSetup` - the orchestrator: detect → confirm → install →
  re-verify → enable/verify proxy, returning `Ready` rather than exiting
  itself. Reuses `Show-DeltaIisInstallCancelledNotice` and
  `Show-DeltaIisRestartRequiredNotice` verbatim from Phase 3 for the
  decline/restart-required cases - both are already fully generic
  wording, so no new near-duplicate notice function was written.

### Bugs found and fixed during real validation

- **`[Parameter(Mandatory)][array]` rejects a genuinely empty array.**
  `Read-DeltaArrInstallConfirmation`'s `-MissingComponents` legitimately
  receives `@()` when only the proxy setting needs enabling - PowerShell
  throws "Cannot bind argument... because it is an empty collection" in
  that case unless `[AllowEmptyCollection()]` is also present, even
  though the value is a real array, not `$null`. Caught immediately by a
  live run (declining a proxy-only-pending confirmation), fixed by adding
  the attribute.
- **Wrong assumption about ARR's own module file location.** The
  original detection logic assumed both URL Rewrite and ARR install their
  native module under the same `%WINDIR%\System32\inetsrv` directory -
  true for URL Rewrite (`rewrite.dll`), **false** for ARR, which installs
  to its own `%ProgramFiles%\IIS\Application Request Routing\requestRouter.dll`
  instead. This was caught by a **real installation** on this development
  machine: both MSIs genuinely installed successfully (confirmed via
  their own install logs and a Programs-and-Features registry check), but
  `Confirm-DeltaArrPostInstallState` correctly refused to report success,
  stopping with "Application Request Routing... still report Missing" -
  exactly the "never trust the installation command's own result alone"
  discipline this phase's own requirements call for, working as intended
  against a bug in the detection code itself rather than a real install
  failure. Fixed by giving each component definition its own
  `ModuleFilePath` instead of assuming a shared directory.
- **A pinned download URL was already dead.** The original URL Rewrite
  download URL (sourced from this roadmap document's own illustrative
  example) returned `404 Not Found` when actually requested. Replaced
  with a different, confirmed-reachable Microsoft Download Center URL
  after testing several candidates directly (`HEAD` request, 200,
  plausible MSI content-length) - exactly the "re-verify before pinning"
  caveat this phase's own roadmap text already anticipated. The ARR
  download URL was reachable on the first try and needed no change.

### ARR detection method

Two independent signals, combined with **AND** (not Phase 2/3's OR) -
see "Implementation" above for the full rationale: a live install can
leave a genuine Programs-and-Features entry behind that is not yet (or
no longer) backed by a real, present module file, and this phase biases
toward the safer failure mode (redundant reinstall attempt) rather than
the more dangerous one (silently treating a stale/partial state as fully
installed).

### ARR installation method

Silent `msiexec /qn /norestart /log <path>` via the shared
`Start-ProcessWithActivityIndicator`, matching `setup.ps1`'s own
`Install-NodeMsi` convention exactly (activity indicator, dedicated log
file, admin-privilege check before running). Local `installers\` cache
preferred over a fresh download, matching `Get-NginxPackage`'s own
behavior.

### Proxy enablement verification

`Set-WebConfigurationProperty -Filter system.webServer/proxy -Name
enabled -Value True -PSPath MACHINE/WEBROOT/APPHOST`, immediately
re-read back via `Get-WebConfigurationProperty` (`Test-DeltaIisProxyEnabled`)
rather than trusting the `Set-` call's own lack of a thrown error as
proof - `Stop-Setup` if it still reads back disabled.

### Validation

- **ARR already installed** / **already fully configured (no prompt at
  all)** - validated via an isolated harness (both components
  `Installed`, proxy `Enabled` → `Read-DeltaArrInstallConfirmation`
  stubbed to `throw` if called at all, confirming it never was) and,
  after the real installation below completed, a real live rerun that
  showed "already fully configured" and skipped the prompt entirely.
- **ARR missing** / **URL Rewrite missing** - validated live: this
  machine had neither installed; the detection summary correctly listed
  both as `Missing` (once the AND-logic fix above was in place; before
  that fix, a transient/incorrect registry read briefly reported a false
  "Installed" for both - see "Bugs found" for the related, confirmed-real
  module-path bug this same AND logic was designed to guard against).
- **Successful installation** - validated live: a real download +
  silent `msiexec` install of both MSIs on this development machine,
  confirmed via Programs-and-Features registry entries and each
  component's own real install log ("Installation completed
  successfully").
- **Verification failure** - validated for real (see "Bugs found"
  above) and additionally via an isolated harness forcing a component to
  still report `Missing` after "installation," confirming the specific
  by-name `Stop-Setup` message.
- **Restart-required path** - validated via an isolated harness (`msiexec`
  exit code 3010) - `Show-DeltaIisRestartRequiredNotice` displayed and
  `Confirm-DeltaArrPostInstallState`/Phase 5 confirmed never reached.
- **User declines** - validated live: answering "n" at the confirmation
  prompt exited 0 with "No changes have been made," and a follow-up
  `Get-WindowsFeature`/registry check confirmed nothing had changed.

No restart was actually required by either real MSI install on this
machine - the restart-required path itself was validated only via the
harness, not live, since neither real install triggered it.

### Addendum: `preserveHostHeader` + `allowedServerVariables` (real login-failure investigation)

A confirmed production DELTA login failure (NGINX → IIS → DELTA topology;
`POST /en/admin/login.data` returning HTTP 400) traced back to two gaps
in this phase's original implementation - both now fixed:

- **`preserveHostHeader` was never configured.** ARR's own default for
  `system.webServer/proxy/@preserveHostHeader` is `False`, meaning ARR
  substitutes `localhost:<port>` for the original inbound Host header
  before forwarding. DELTA depends on the original Host header
  surviving the proxy hop (sessions, CSRF, Remix action routing,
  redirects) - `setup-nginx.ps1`'s own NGINX templates have always sent
  `proxy_set_header Host $host` (the NGINX equivalent), so this was an
  IIS-only parity gap. `Confirm-DeltaArrPostInstallState` now sets
  `enabled` and `preserveHostHeader` INDEPENDENTLY (never a single "is
  the proxy already configured" early return) - a machine with
  `enabled=True, preserveHostHeader=False` is correctly treated as not
  yet configured, which the original single-property early return would
  have missed entirely.
- **Changing `system.webServer/proxy` at runtime requires `iisreset`,
  not app-pool/site recycling.** Confirmed via real testing: this is a
  MACHINE-WIDE `applicationHost.config` setting, not scoped to any
  single application pool, and IIS's normal per-app-pool
  configuration-change recycling does not reliably pick it up. A plain
  app-pool or website recycle left the change ineffective until a full
  `iisreset /noforce`. `Restart-DeltaIisForArrConfiguration`
  (setup-iis.ps1) now runs `iisreset.exe /noforce` via the shared
  `Start-ProcessWithActivityIndicator` - but ONLY when at least one of
  the three machine-wide properties below actually needed to change this
  run, never unconditionally, per this project's own "maintain
  idempotent installation steps" rule (CLAUDE.md). Post-restart state is
  re-verified via a FRESH `Get-DeltaArrDetectionResult` call, never
  trusted from the `Set-`/`Add-WebConfigurationProperty` calls' own lack
  of a thrown error.

A third, related gap was found while implementing X-Forwarded-Proto/
Host/Port parity with NGINX (see Phase 6's own addendum below):
`system.webServer/rewrite/allowedServerVariables` is locked
(`overrideModeDefault="Deny"`) at the server level by default. A
site-level `web.config` attempting to declare it there - the original
design of this addendum - fails EVERY request to the site with HTTP
500.52 ("URL Rewrite Module Error"), confirmed via a real, throwaway IIS
site on a machine with URL Rewrite/ARR installed. The fix is the same
shape as `preserveHostHeader`: the three required names
(`HTTP_X_FORWARDED_PROTO`/`HOST`/`PORT`) are added machine-wide
(`MACHINE/WEBROOT/APPHOST`) by `Confirm-DeltaArrPostInstallState`
instead, and `templates\iis\web.config` never declares
`allowedServerVariables` at all.

`Get-DeltaArrDetectionResult` (`lib\DeltaDoctor.IIS.ps1`) now also
reports each component's own installed `Version` (`DisplayVersion` from
the same `Get-InstalledProgramInfo` registry lookup
`Test-DeltaArrComponentInstalled` already performed - not a second
version-detection mechanism), shown in `Show-DeltaArrDetectionSummary`.
`Get-DeltaDoctorIisPrerequisiteChecks` (the Doctor's own IIS
prerequisite checklist, shared with `doctor.ps1`) now includes
Error-severity checks for `preserveHostHeader` and the
`allowedServerVariables` allow-list alongside the existing `enabled`
check - `Ready` is `False` if any of the three read wrong, matching this
addendum's own "not a warning" requirement (a confirmed login-failure
cause, never merely cosmetic).

Validated live on a real Windows Server IIS installation (URL
Rewrite/ARR already installed): a simulated `enabled=True,
preserveHostHeader=False` machine was correctly flagged unhealthy by the
Doctor and correctly repaired by `Confirm-DeltaArrPostInstallState` with
exactly one `iisreset`; an already-correct machine triggered zero
restarts; changing exactly one of the three properties triggered exactly
one restart; and a temporary IIS site directly confirmed the HTTP
500.52 failure mode for the rejected site-level `allowedServerVariables`
design, and its resolution once moved server-wide.

## Objective

Unlike every role service in Phase 3, **ARR and URL Rewrite are not Windows Features at all** - they are separate, standalone Microsoft redistributables, historically distributed through the Web Platform Installer (WebPI), which Microsoft has since retired. This is the single biggest structural difference from `setup-nginx.ps1`'s own Phase 1 (`Install-Nginx`), and needs to be treated as its own phase for exactly that reason.

## What's required

- **URL Rewrite Module 2.1** - provides the `<rewrite>` `web.config` section Phase 6's generated site configuration depends on.
- **Application Request Routing 3.0** - provides the actual reverse-proxy engine. ARR's own proxy behavior is not automatic once installed - it must additionally be *enabled* at the server level (`system.webServer/proxy`, a machine-wide `applicationHost.config` setting, not a per-site one):

```powershell
Set-WebConfigurationProperty -Filter 'system.webServer/proxy' -Name 'enabled' -Value 'True' -PSPath 'MACHINE/WEBROOT/APPHOST'
```

Both are standard MSI packages (`rewrite_amd64_en-US.msi`, `requestRouter_amd64.msi` as of the versions current when this phase is implemented - re-verify the exact current download URLs against Microsoft's own IIS.net/Download Center pages before pinning them, the same caveat `setup-nginx.ps1`'s own header carries for its nginx.org download URL) - both installable silently:

```powershell
Start-Process -FilePath 'msiexec.exe' -ArgumentList '/i', $installerPath, '/quiet', '/norestart' -Wait
```

## Research finding: silent installation is possible

Per this phase's own instruction to determine whether ARR/URL Rewrite can be installed silently: **yes** - both are ordinary MSI packages once obtained directly (not through the retired WebPI wrapper), and `msiexec /quiet` is the same silent-install mechanism `setup.ps1` already relies on for other Windows installers in this project. No administrator interaction is required for the install step itself.

What **does** need explicit administrator guidance, and should be documented plainly rather than silently worked around:

- **Download source stability.** WebPI's retirement means these MSIs must be fetched from a specific, pinned Microsoft Download Center / IIS.net URL rather than a general "latest version" endpoint that might not exist reliably long-term - the same pinned-version philosophy `setup-nginx.ps1` already applies to its own NGINX ZIP download, extended here with an extra note that Microsoft's own hosting of these two packages specifically has been less stable historically than `nginx.org`'s, and the local-cache-under `installers\` fallback (mirroring `Get-NginxPackage`'s own local-file-preferred-over-download behavior) matters more here, not less.
- **A restart may be required** after ARR installation specifically (it installs a native IIS module) before `system.webServer/proxy` becomes configurable - this must be surfaced to the administrator exactly like Phase 3's own restart-required case, not silently retried in a loop.

---

# 5. Website Discovery

## Status: Completed

`setup-iis.ps1` now determines whether a managed DELTA IIS website
already exists - purely read-only; it never creates, modifies, or
deletes any IIS website, application pool, binding, or certificate. Only
reached once Phase 4 has reported `Ready`.

### Implementation

- `$Script:DeltaIisSiteName = 'DELTA'` - the fixed, well-known site
  identity (Configuration section), matching NGINX's own fixed
  `$Script:NginxHome` (`C:\nginx`) convention: never inferred, never
  scanned for.
- `Get-DeltaIisManagedWebsiteResult` - the direct IIS analogue of
  `setup-nginx.ps1`'s own `Get-DeltaNginxManagedProcesses` (which matches
  by executable path, never by process name alone). Primary signal: a
  site named exactly `$Script:DeltaIisSiteName` exists at all
  (`Get-Website`). Secondary, defense-in-depth signal: that site's own
  `PhysicalPath` matches the DELTA installation path Phase 1 already
  resolved (`$Script:DeltaInstallPath`) - per this phase's own roadmap
  text, "cross-validate its physical path... against the resolved DELTA
  installation path from Phase 1." Compared after expanding any
  environment-variable tokens IIS may have stored the path with
  (confirmed directly: IIS's own Default Web Site stores
  `%SystemDrive%\inetpub\wwwroot` unexpanded) and trimming a trailing
  backslash, so formatting differences alone never cause a false
  negative. Returns both `ManagedSite` (only once both checks agree) and
  `CollidingSite` (a name match that failed the physical-path check), so
  the two "nothing found" reasons can be reported distinctly.
- `Get-DeltaIisSiteHostHeader` - reads the actual, already-configured
  host header off the site's own first binding (`Get-WebBinding`,
  parsing `bindingInformation`'s third colon-delimited segment) - never
  re-prompted.
- `Show-DeltaIisExistingWebsiteSummary` - the "Existing DELTA IIS
  Website" summary (Website/Status/Physical Path/Host Header/Backend/
  Application Pool), reading Status/Physical Path/Host Header/
  Application Pool straight off the live site object, and Backend via
  the now-shared `Resolve-DeltaBackendPort` (see below) - per this
  phase's own explicit "Reuse the shared... `Resolve-DeltaBackendPort`"
  instruction, since there is no generated `web.config` yet for this
  phase to read an actual proxy target back out of (that artifact
  doesn't exist until Phase 6).
- `Show-DeltaIisSiteNameCollisionNotice` - a distinct notice for the
  `CollidingSite` case, explaining specifically why this installer will
  not touch a same-named-but-unrelated site, rather than silently folding
  it into the generic "nothing found" message.
- `Show-DeltaIisNoManagedWebsiteNotice` - the Fresh Installation notice
  (this phase's own example wording exactly).
- `Invoke-DeltaIisWebsiteDiscovery` - the orchestrator; the one place
  `WebAdministration` is imported for this phase (guarded by
  `Test-DeltaWebAdministrationModuleAvailable`, `Stop-Setup` if somehow
  still unavailable - defensive, since Phase 3/4 already guarantee it in
  practice).

### `Resolve-DeltaBackendPort` promoted to the shared library

This phase's own "Reuse the shared... `Resolve-DeltaBackendPort`"
requirement named a function that, at the start of this phase, still
only existed inside `setup-nginx.ps1` - the promotion this roadmap's own
Phase 6 text anticipated ("promoted alongside `Resolve-DeltaInstallation`
if it is not already fully engine-agnostic - it already is") had not
actually happened yet. Done now, as part of this phase: `Resolve-DeltaBackendPort`
and its `Test-ValidTcpPort` dependency (plus the
`$Script:DefaultDeltaBackendPort` constant) moved into
`lib\DeltaInstaller.Common.ps1`, with `setup-nginx.ps1` updated to a
pointer comment consuming the shared copy - no behavior change, verified
directly (see Validation below). The one deliberate wording change: the
invalid-`PORT` error message no longer names `setup-nginx.ps1`
specifically ("re-run this script" instead), since it is now genuinely
called from two different entry-point scripts - the same "revisit once a
second real caller exists" note `Resolve-DeltaInstallation`'s own header
already carried forward from Phase 1.

### Deliberate scope decision: `Resolve-DeltaWebsiteDomain` is NOT called in this phase

This phase's own reuse list also names `Resolve-DeltaWebsiteDomain`, but
it is not actually invoked anywhere in Phase 5's implementation.
`Resolve-DeltaWebsiteDomain` always interactively prompts the
administrator - and neither of this phase's own two example outputs
(Existing DELTA Website, Fresh Installation) shows any prompt at all, and
the phase's own "Do not modify anything" requirement for the existing-
site case reads most naturally as "do not ask for anything either." An
existing site's host header is read directly off its own live binding
instead (see `Get-DeltaIisSiteHostHeader` above), which is both more
accurate (reports what is actually configured, not what `.env` currently
says) and non-interactive. `Resolve-DeltaWebsiteDomain` is instead called
directly inside Phase 6 (Website Configuration) itself - the roadmap
originally assigned this to a standalone Phase 7 ("Website Domain"), but
that phase was retired and merged into Phase 6 once Phase 6 was actually
implemented (see the renumbering note in the Status table, and the
retired Phase 7 section itself, for the full explanation) - this remains
a scope clarification for Phase 5 specifically, not a contradiction of
this phase's own reuse list.

### Managed website discovery logic

Two independent checks, both required (site name AND physical path) -
never inferred from either alone. A site named `DELTA` with an unrelated
`PhysicalPath` is treated as a **collision**, reported distinctly, and
left completely untouched - never assumed to be "close enough."

### Validation

- **Managed DELTA site detected** - validated via an isolated harness
  (mocked `Get-Website`/`Get-WebBinding` returning a site named `DELTA`
  with `PhysicalPath = 'C:\DELTA'` and a `delta.example.org` host header)
  - `Show-DeltaIisExistingWebsiteSummary` displayed every field
  correctly, including `Backend` via a real `Resolve-DeltaBackendPort`
  call.
- **Unrelated IIS websites ignored** - trivially true by construction
  (`Get-Website -Name $Script:DeltaIisSiteName` only ever looks up the
  fixed name) and confirmed via the harness with a mocked `Get-Website`
  that has no `DELTA`-named entry at all.
- **No website found** - validated live, twice, against this real
  machine (which genuinely has no `DELTA` site): once immediately after
  Phase 4's real ARR installation completed, and once again on a full
  idempotent rerun - both times reaching Phase 5 for real (via
  `Import-Module WebAdministration`, a real `Get-Website -Name 'DELTA'`
  call) and correctly reporting "No managed DELTA IIS website was found,"
  exit 0.
- **Mismatched physical path rejected** - validated via an isolated
  harness: a site named `DELTA` with an unrelated `PhysicalPath`
  produced `ManagedSite = $null` and `CollidingSite` set, with
  `Show-DeltaIisSiteNameCollisionNotice` displaying the actual vs.
  expected paths correctly before falling through to the "no managed
  site" notice.

A real test website was deliberately NOT created on this machine to
validate the "managed site detected" case live - even though trivially
reversible, it was judged unnecessary real IIS mutation given the
isolated harness already proves the same `Get-Website`/`PhysicalPath`
comparison logic completely, and this phase's own design philosophy
already asks for the most conservative posture available toward existing
IIS state.

## Objective

Detect whether a DELTA-managed IIS site already exists - the IIS analogue of `setup-nginx.ps1`'s own top-level "does `C:\nginx\nginx.exe` already exist" check, but structurally harder: NGINX's entire installation directory either belongs to this installer or doesn't exist; IIS can easily be hosting several completely unrelated websites already, none of which this installer may ever touch.

## Managed vs. unrelated

- **Primary signal:** a fixed, well-known site name this installer always uses - e.g. `$Script:DeltaIisSiteName = 'DELTA'` - checked via `Get-Website -Name $Script:DeltaIisSiteName`. Exactly analogous to NGINX's own fixed `C:\nginx` convention: the administrator never gets to name this site something else, and this installer never scans for "a site that looks like it might be DELTA."
- **Secondary, defense-in-depth signal:** if a site with that exact name exists, cross-validate its physical path (`(Get-Website -Name $Script:DeltaIisSiteName).PhysicalPath`, or the equivalent of its reverse-proxy `web.config` target) against the resolved DELTA installation path from Phase 1, before treating it as "the managed DELTA site." A name collision with something an administrator happened to independently name "DELTA" is unlikely but not impossible, and this installer must never assume ownership from the name alone the way `Get-DeltaNginxManagedProcesses` never assumes ownership from a process *name* alone (matched by executable path instead) - the same principle, applied to a different kind of identifier.

## Behavior

- No site by that name (or a name-match that fails the physical-path cross-check) → this is a fresh installation from this installer's own point of view, even if IIS itself is not new. Continue into Phase 6.
- A confirmed managed DELTA site already exists → do not create or overwrite anything. Continue into an existing-installation management workflow, the direct analogue of `Show-DeltaNginxManagementMenu` - see Phase 8.

The installer must never overwrite an unrelated website - this is the single hardest safety requirement carried over from `setup-nginx.ps1`'s own design philosophy, and arguably more important here than it was for NGINX, since the blast radius of a mistake is an entire shared IIS server rather than a dedicated reverse-proxy box.

---

# 6. Website Configuration

## Status: Completed

`setup-iis.ps1` now creates or updates the managed DELTA IIS website
itself - the application pool, the website, its physical path, the
generated `web.config`, the ARR reverse-proxy rule inside it, and the
HTTP binding. Does not touch SSL/HTTPS/certificate import/runtime
management/port-binding-conflict validation, per this phase's own scope
boundary.

### Implementation

- `$Script:DeltaIisAppPoolName = 'DELTA'` / `$Script:DeltaIisWebConfigTemplate`
  (`templates\iis\web.config`) - new Configuration-section constants,
  alongside Phase 5's own `$Script:DeltaIisSiteName`.
- **`templates\iis\web.config`** (new directory, sibling to
  `templates\nginx\`) - the canonical, version-controlled ARR reverse-
  proxy rule template, following the exact same header-comment/
  regeneration-warning philosophy as `templates\nginx\delta-http.conf`.
  Tokens: `__DELTA_BACKEND_PORT__` (the `<action>` element's proxy target)
  and `__DELTA_SERVER_NAME__` (a documentation-only comment - the actual
  public hostname lives in the website's own HTTP binding, not inside
  `web.config` itself, since IIS has no `web.config`-level equivalent of
  NGINX's `server_name` directive).
- `Get-DeltaIisAppPoolAttributeValue` - a defensive helper for reading
  Application Pool attributes via the `IIS:\` provider, needed because of
  a confirmed real inconsistency (see "Bugs found/quirks confirmed"
  below): some attributes come back as a plain scalar, others wrapped in
  a `ConfigurationAttribute` object requiring `.Value`.
- `Confirm-DeltaIisAppPool` - creates the `DELTA` application pool if
  missing; either way, reconciles exactly three settings this installer
  owns (`managedRuntimeVersion=''` for "No Managed Code",
  `managedPipelineMode='Integrated'`, `autoStart=$true`) - never
  recreated, and no other app pool setting is ever touched.
- `New-DeltaIisWebConfig` - writes `$Script:DeltaInstallPath\web.config`
  (the DELTA installation directory itself - **not** a second,
  IIS-specific application directory, per this phase's own explicit "Do
  not create a second application directory. Reuse the existing
  installation." requirement, and exactly what Phase 5's own
  `Get-DeltaIisManagedWebsiteResult` already cross-validates a managed
  site's `PhysicalPath` against) via the shared `Write-DeltaTemplateFile`
  - never PowerShell string concatenation, never a second template-
  rendering implementation.
- `Confirm-DeltaIisWebsiteBinding` - creates or updates ONLY this
  installer's own single HTTP:80 binding (matched by protocol+port, not
  by replacing the site's entire bindings collection) - confirmed
  directly (a throwaway test site with a second, unrelated binding added
  alongside) that this leaves any other binding an administrator added by
  hand completely untouched, per this phase's own "Do not remove custom
  bindings" requirement.
- `Confirm-DeltaIisWebsite` - `New-Website` only when
  `Get-DeltaIisManagedWebsiteResult` found nothing genuinely ours;
  otherwise reconciles only the Application Pool association and the
  site's own single binding - never recreated.
- `Confirm-DeltaIisWebsiteConfigurationResult` - the Verification section
  requirement made real: re-reads IIS from scratch (a fresh `Get-Website`
  call) and independently checks application pool existence, physical
  path, application pool association, `web.config` existence AND that its
  rewrite rule's URL literally contains the current resolved backend
  port (not just "a file exists"), and the host header - collecting every
  failure at once (the same shape `Test-DeltaNginxStartupHealth` already
  uses in `setup-nginx.ps1`) rather than stopping at the first. Never
  trusts `New-WebAppPool`/`New-Website`/`Set-WebBinding`'s own lack of a
  thrown error as proof of anything.
- `Show-DeltaIisWebsiteConfigurationSummary` - this phase's own "Summary"
  example, verbatim. Says nothing about HTTPS, per this phase's own
  explicit "Do not mention HTTPS yet" requirement.
- `Invoke-DeltaIisWebsiteConfiguration` - the orchestrator. Reuses
  `Get-DeltaIisManagedWebsiteResult` (Phase 5) a second, independent time
  rather than threading Phase 5's own display-only orchestrator's result
  through - Phase 5 itself stays exactly as already implemented. A
  `CollidingSite` is a hard `Stop-Setup` here (not merely Phase 5's own
  informational notice) - fails BEFORE `Resolve-DeltaWebsiteDomain` is
  ever called, so an unresolvable name collision never even prompts the
  administrator. `Resolve-DeltaWebsiteDomain` and `Resolve-DeltaBackendPort`
  both run on **every** invocation, fresh or rerun alike - this phase has
  no separate "management menu" concept yet, so "always resolve fresh
  inputs, then reconcile IIS state to match them" is what makes a changed
  backend port or website domain regenerate correctly on a plain rerun,
  with no separate "update" code path required.

### Application Pool strategy

Create-if-missing, reconcile-if-present, never recreate. Only three
settings are ever touched (`managedRuntimeVersion`, `managedPipelineMode`,
`autoStart`) - anything else an administrator configured on the pool by
hand is left alone.

### `web.config` template generation

`templates\iis\web.config`, rendered via the shared `Write-DeltaTemplateFile`
- unconditionally overwritten on every run (no backup, no diff), the same
posture `New-DeltaNginxConfiguration` already takes for `delta.conf`,
since this phase's own design philosophy requires the generated
configuration to be deterministic and idempotent, not preserved-if-
customized.

### Rerunnable behavior

Every write this phase performs is idempotent: application pool settings
are only changed if they differ from the desired value; `web.config` is
always regenerated from the current resolved inputs (harmless when
nothing changed); the website's binding is only updated if its host
header differs from the newly-resolved domain; `New-Website`/`New-WebAppPool`
are only ever called once, on first creation. Confirmed directly (see
Validation) that repeated real runs never produce a duplicate site or
pool, and that changing an input (backend port, domain) on a subsequent
run correctly regenerates only what needs to change.

### Bugs found / quirks confirmed during real validation

- **`Get-ItemProperty` on `IIS:\AppPools\<name>` returns inconsistent
  shapes.** Confirmed directly on a real machine: `managedRuntimeVersion`
  and `autoStart` come back wrapped in a
  `Microsoft.IIs.PowerShell.Framework.ConfigurationAttribute` object
  (needs `.Value`), while `managedPipelineMode` comes back as a plain
  `System.String` directly - an enum-backed attribute apparently gets
  unwrapped by the provider while others don't. `Get-DeltaIisAppPoolAttributeValue`
  handles both shapes generically (checks for a `.Value` property, falls
  back to the raw result) rather than hardcoding which attributes need
  unwrapping - the same defensive shape `Get-RegistryPropertyValue`
  already uses for the analogous registry-result problem.
- **Binding updates must target the specific binding object, not the
  collection.** Confirmed via a throwaway test site: `Set-WebBinding
  -BindingInformation <old> -PropertyName bindingInformation -Value <new>`
  updates exactly the one matched binding and leaves every other binding
  on the site untouched - the mechanism `Confirm-DeltaIisWebsiteBinding`
  depends on to satisfy "Do not remove custom bindings."

### Deliberate scope decision: physical path is the DELTA installation directory itself

This phase's own roadmap text illustrates site creation with a
`$Script:DeltaIisSitePath` distinct from the DELTA installation path -
but the explicit implementation instructions for this phase ("Use the
managed DELTA installation path. Do not create a second application
directory. Reuse the existing installation.") and Phase 5's own already-
implemented physical-path cross-check (against `$Script:DeltaInstallPath`
specifically, not a separate IIS-specific folder) both require the
opposite: the website's `PhysicalPath` is `$Script:DeltaInstallPath`
itself. No separate `$Script:DeltaIisSitePath` was introduced - doing so
would have made Phase 5's own managed-site detection permanently unable
to recognize a site this very phase creates.

### Validation

Performed almost entirely against this development machine's real,
already-fully-configured IIS/ARR installation (from Phases 3/4) - real
validation was possible for nearly every scenario this phase calls out:

1. **Fresh machine → Application Pool created → Website created →
   web.config generated → Verification succeeds** - validated live, end
   to end: a real run created the `DELTA` application pool (`No Managed
   Code`, `Integrated`, `autoStart=True`), wrote `C:\DELTA\web.config`,
   created the `DELTA` website (`PhysicalPath=C:\DELTA`,
   `HostHeader=localhost`, bound to the new app pool), verification
   passed, and the summary displayed correctly. Independently re-checked
   afterward via direct `Get-Website`/`Get-WebBinding`/`Get-ItemProperty`
   calls in a separate process - not just trusting the script's own
   report.
2. **Existing managed website → Configuration updated → Website
   preserved → No duplicate website** - validated live via multiple
   reruns against the site created in scenario 1: each rerun correctly
   reported "Already exists," reconciled only what needed reconciling,
   and never created a second site or pool (`Get-Website`/`IIS:\AppPools`
   counts confirmed exactly 1 each throughout).
3. **Backend port changes inside DELTA `.env` → Generated web.config
   reflects the new backend port** - validated live: added `PORT=4321` to
   the real `C:\DELTA\.env` (backed up and restored afterward), reran -
   `web.config`'s `<action>` URL and the summary's `Backend` line both
   updated to `4321`, confirmed by reading the actual file content back.
4. **Website domain changes → Host Header updated → web.config
   regenerated** - validated live: reran with `delta.example.org`
   instead of `localhost` - `Confirm-DeltaIisWebsiteBinding` correctly
   updated the existing binding (`Set-WebBinding`, confirmed via a direct
   `Get-WebBinding` check afterward showing `*:80:delta.example.org`),
   and `web.config`'s own comment updated to match. Restored to
   `localhost` afterward via the same mechanism.
5. **Repeated execution → No duplicate application pools → No duplicate
   websites → Idempotent behavior** - validated live across every rerun
   above; additionally, the `DELTA` application pool's
   `managedRuntimeVersion` was deliberately drifted to `v4.0` by hand
   between runs, and the next run correctly detected and corrected it
   back to `''` (logged as `Updated managedRuntimeVersion -> ''`) -
   confirming the reconciliation path actually fires when something has
   drifted, not only when everything already matches.

Two scenarios this phase's own requirements imply were validated via an
isolated harness instead of live, since reproducing them safely against
the real, now-in-use `DELTA` site would have meant deliberately breaking
it:

- **Name collision** (a site named `DELTA` that does not belong to this
  installation) - a mocked `Get-DeltaIisManagedWebsiteResult` returning a
  `CollidingSite`, with `Resolve-DeltaWebsiteDomain` stubbed to `throw` if
  called at all, confirmed `Invoke-DeltaIisWebsiteConfiguration` stops
  with a clear `Stop-Setup` message **before** any prompting happens.
- **Post-configuration verification failure** - two harness scenarios
  (a physical-path mismatch plus a missing `web.config`; a `web.config`
  whose rewrite rule references the wrong backend port) both produced the
  correct, specific, itemized `Stop-Setup` message via
  `Confirm-DeltaIisWebsiteConfigurationResult`, collecting multiple
  simultaneous failures in one report rather than stopping at the first.

## Objective

Create (or, once Phase 5 confirms it is genuinely ours, update) the DELTA IIS website - the analogue of `New-DeltaNginxConfiguration`, producing IIS's equivalent of `templates\nginx\delta-http.conf`/`delta-https.conf`.

## What IIS's own generated artifact looks like

NGINX's per-site behavior lives in a single generated `conf.d\delta.conf` file. IIS's equivalent is a generated `web.config` (the ARR/URL Rewrite `<rewrite>` rules living inside it) at the DELTA site's own physical path - a new `templates\iis\` directory (sibling to `templates\nginx\`) should hold the canonical, token-substituted templates for this, following the exact same "canonical, readable, version-controlled template files, never PowerShell string concatenation" principle `setup-nginx.ps1`'s own header documents for its NGINX templates.

**Update:** the token-substitution mechanism itself (`__DELTA_BACKEND_PORT__`, `__DELTA_SERVER_NAME__`, etc., written out via a BOM-less UTF-8 encoding) has already been generalized and promoted into `lib\DeltaInstaller.Common.ps1` as `Write-DeltaTemplateFile` - originally `setup-nginx.ps1`'s own `Install-NginxConfigFile`, moved by a preparatory refactoring pass once confirmed to have no knowledge of nginx.conf/web.config/XML at all: it only loads a template, applies literal token replacements, and writes the result out with the same BOM-less encoding either consumer needs. `setup-nginx.ps1`'s `New-DeltaNginxConfiguration` already calls the shared function under its new name. `setup-iis.ps1`'s web.config generation should call `Write-DeltaTemplateFile` directly rather than reimplementing it for XML - the function has no opinion on the destination format, only on the load/substitute/write mechanics.

Illustrative shape of the generated reverse-proxy rule (not a literal final template - confirm exact ARR/URL Rewrite syntax at implementation time):

```xml
<rewrite>
  <rules>
    <rule name="DELTA Reverse Proxy" stopProcessing="true">
      <match url="(.*)" />
      <action type="Rewrite" url="http://localhost:{DELTA_BACKEND_PORT}/{R:1}" />
    </rule>
  </rules>
</rewrite>
```

## Bindings and backend destination

Reuse:

```powershell
Resolve-DeltaBackendPort
```

Identical in spirit to `setup-nginx.ps1`'s own Phase 4 (`Resolve-DeltaBackendPort` in that script) - reads `PORT` from the DELTA installation's own `.env` (`$Script:DeltaEnvPath`, from Phase 1 here) via the already-shared `Get-EnvFileValue` helper, falls back to the shared default when unset, and stops the installer outright on an invalid value. This should be the exact same function `setup-nginx.ps1` already calls (promoted alongside `Resolve-DeltaInstallation` if it is not already fully engine-agnostic - it already is, since it has no NGINX-specific knowledge at all) rather than a second, `setup-iis.ps1`-specific copy.

Site creation itself:

```powershell
New-Website -Name $Script:DeltaIisSiteName -PhysicalPath $Script:DeltaIisSitePath `
    -ApplicationPool $Script:DeltaIisAppPoolName -Port 80 -HostHeader $Script:DeltaWebsiteDomain
```

A dedicated Application Pool (never the IIS `DefaultAppPool`, the same "never assume/reuse something you don't own" principle applied to app pools) - name, .NET CLR version ("No Managed Code" is correct here, since this pool only ever proxies to the Node.js backend, never runs managed application code itself), and pipeline mode are all decided at this phase and documented for Phase 10's summary.

### Addendum: X-Forwarded-Proto/Host/Port parity with NGINX

`setup-nginx.ps1`'s own NGINX templates (`templates\nginx\delta-http.conf`/
`delta-https.conf`) have always forwarded `X-Forwarded-For`,
`X-Forwarded-Proto`, `X-Forwarded-Host`, and `X-Forwarded-Port` to the
DELTA backend. `templates\iis\web.config` originally forwarded none of
these - a parity gap found during the same login-failure investigation
that led to Phase 4's own `preserveHostHeader` addendum (above).
`X-Forwarded-For` is supplied automatically by ARR once
`system.webServer/proxy` is enabled, so only the other three needed
adding.

The `DELTA Reverse Proxy` rule now sets them via URL Rewrite
`<serverVariables>`, using two `<rewriteMaps>` (`DeltaForwardedProto`,
`DeltaForwardedPort`) to translate the built-in `{HTTPS}` server
variable (`"on"`/`"off"`) into the values actually expected
(`"https"`/`"http"` and `"443"`/`"80"`) - never hardcoded, since the
site serves both HTTP and HTTPS bindings. `X-Forwarded-Host` is set
directly from the built-in `{HTTP_HOST}` server variable (the original
inbound Host header, read-only, no allow-list needed to reference it).

Setting a server variable requires `system.webServer/rewrite/allowedServerVariables`
to permit it by name - the ORIGINAL design of this addendum declared
these three names directly in `templates\iis\web.config` itself, which
a real, throwaway IIS test site (URL Rewrite/ARR already installed)
proved fails EVERY request with HTTP 500.52 ("URL Rewrite Module
Error"): `allowedServerVariables` is locked
(`overrideModeDefault="Deny"`) at the server level by default, so a
site-level declaration is rejected outright. The fix - and the reason
this is documented as a Phase 4 addendum too - is that these three names
are instead added machine-wide (`MACHINE/WEBROOT/APPHOST`) by
`Confirm-DeltaArrPostInstallState`, the same place `enabled`/
`preserveHostHeader` already are; `templates\iis\web.config` never
declares `allowedServerVariables` at all.

`Get-DeltaDoctorWebsiteChecks` (`lib\DeltaDoctor.IIS.ps1`) now includes
three Error-severity, per-site checks - "X-Forwarded-Proto/Host/Port
forwarding configured" - each a plain regex match against the live
`web.config`'s own `<set name="HTTP_X_FORWARDED_*">` line, matching the
existing "Rewrite rule present" pattern exactly. These check ONLY
whether THIS site's own rule sets the variable - not also for a matching
`allowedServerVariables` entry in the same file, since that no longer
lives there at all (it is the separate, machine-wide fact
`Test-DeltaIisForwardedServerVariablesAllowed` checks instead, see
Phase 4's own addendum). A missing or hand-edited-away forwarded-header
rule now makes the site's own configuration `NeedsRepair = $true`,
which the existing `Invoke-DeltaIisConfigurationCheckup` Detect →
Diagnose → Offer Repair → Validate Again cycle already regenerates
`web.config` wholesale to fix - no separate repair workflow was added.

Validated live: a real, throwaway IIS site (with a correctly rendered
`web.config`) confirmed all three checks pass on a fresh, correct file;
manually removing one `<set>` line flipped exactly that one check to
`FAIL` while the other two remained unaffected, and the site's own live
HTTP behavior (once `allowedServerVariables` was populated machine-wide)
correctly reached ARR's own backend-connection attempt (`502.3 Bad
Gateway` against a deliberately nonexistent backend) rather than any
configuration-parse error.

---

# 7. Website Domain — Merged into Phase 6

## Status: Merged into Phase 6

The original roadmap treated Website Domain resolution as its own
standalone phase, on the implicit assumption that "resolve the domain"
and "configure the website with it" might need to happen as two separate
implementation steps, the way `setup-nginx.ps1`'s own Phase 4 (backend
port) and Phase 5 (website domain) are each their own phase ahead of
NGINX's own Phase 3 (configuration generation) actually consuming them.

Once Phase 6 (Website Configuration) was actually implemented, that
assumption turned out not to hold for IIS: there is no natural seam
between the two steps here. `Resolve-DeltaWebsiteDomain` is called
directly inside Phase 6's own `Invoke-DeltaIisWebsiteConfiguration`
orchestrator - on every invocation, fresh install or rerun alike - and
its result is consumed immediately, in the same phase, for both the
website's own HTTP binding host header and the `__DELTA_SERVER_NAME__`
token baked into the generated `web.config`. Implementing "resolve the
domain" as an independent phase would have meant either prompting twice
(once standalone, once again inside Website Configuration) or threading
a resolved value across a phase boundary that does nothing else with the
time in between - neither is a real architectural benefit, just
ceremony. Website Domain resolution is therefore an intrinsic part of
Website Configuration, not an independent implementation phase, and this
phase is retired with no code of its own.

All phases after this one have been renumbered down by one accordingly -
see the renumbering note in the Status table above (which also covers
the separate merge of the original Phase 8/Phase 9 into one new Phase 7).

The original roadmap text below is kept for historical context, not
deleted - see `Get-DeltaIisSiteHostHeader`/`Confirm-DeltaIisWebsiteBinding`
(Phase 6's own implementation) for what actually shipped instead.

## Original Objective (superseded)

Reuse:

```powershell
Resolve-DeltaWebsiteDomain
```

(`lib\DeltaInstaller.Common.ps1`, alongside `Test-DeltaWebsiteDomain`) - this function already has no NGINX-specific knowledge at all; its own header in the NGINX roadmap explicitly anticipates this exact reuse ("this phase's own requirements call out reuse by a future `setup-iis.ps1`" - see `TODO-setup-nginx-enhancements.md`, Phase 5). Nothing about the prompt, validation rules, or `localhost` default changes here.

## Original IIS-specific consumption (superseded)

The resolved domain becomes the site's **host header**, not a `server_name` directive - `New-Website`/`New-WebBinding`'s own `-HostHeader` parameter (Phase 6 above). Unlike NGINX (where `server_name` is purely a virtual-host-matching directive with no other side effect), an IIS host-header binding interacts with Phase 9's port-conflict detection directly: a second site bound to the same port with a *different* host header is normal, expected IIS multi-tenancy, not a conflict at all - see Phase 9's own "how this differs when IIS is already installed" discussion.

---

# 7. Windows SSL Certificate (.pfx)

## Status: Completed

`setup-iis.ps1` now configures HTTPS for the managed DELTA website using
the Windows Certificate Store - never a file-path reference the way
`setup-nginx.ps1` uses for NGINX. Combines what the roadmap originally
split into two phases (SSL Certificate, Existing Certificate Handling)
into one wizard, mirroring `setup-nginx.ps1`'s own
`Install-DeltaSslCertificate`. Does not implement runtime management or
port/binding conflict validation, per this phase's own scope boundary.

### Implementation

- `Select-DeltaSslFile`/`Test-DeltaSslFileExtension` - promoted from
  `setup-nginx.ps1` into `lib\DeltaInstaller.Common.ps1` (they had no
  NGINX-specific knowledge at all - a generic WinForms file-picker and a
  generic extension checker) so `setup-iis.ps1` could reuse them directly
  for `.pfx` selection rather than duplicating them.
- `Read-DeltaIisSslCertificateChoice` - the opening Yes/No question, this
  phase's own exact wording ("Do you already have an SSL certificate
  (.pfx)?"), bare-Enter-means-No, mirroring `setup-nginx.ps1`'s own
  `Read-SslCertificateChoice` shape without reusing it directly (its body
  text is NGINX-specific and its own wording target - ".pfx" vs. no
  extension mentioned - genuinely differs).
- `Get-DeltaIisExistingHttpsCertificateState` - the "Existing Certificate"
  detection: whether the managed site already has an HTTPS binding, and
  whether the certificate store still has a resolvable certificate behind
  that binding's own thumbprint - a deliberate two-part check, mirroring
  `Test-DeltaSslCertificateFilesExist`'s own "only existing when BOTH
  halves are genuinely present" requirement.
- `Show-DeltaIisOrphanedCertificateBindingNotice` - the distinct,
  `Broken`-like case this phase's own roadmap text calls out by name: an
  HTTPS binding whose thumbprint no longer resolves in the store. Reported
  plainly, then treated as no certificate configured (falls through to
  the fresh Yes/No wizard) - never silently folded into either "none" or
  "existing."
- `Read-DeltaIisExistingCertificateChoice` - Replace/Keep/Cancel, no
  bare-Enter default, mirroring `setup-nginx.ps1`'s own
  `Read-ExistingSslCertificateChoice` shape (a decision this consequential
  is never made by a stray Enter keypress).
- `Select-DeltaIisPfxFile`/`Import-DeltaIisSslCertificate` - selects a
  `.pfx` via the shared `Select-DeltaSslFile`, rejects every other
  extension, prompts for the password via `Read-Host -AsSecureString`
  (never echoed), and imports via the Windows-native
  `Import-PfxCertificate` into `Cert:\LocalMachine\My`. The returned
  certificate object's own `.Thumbprint` is the only value ever consumed
  afterward - never searched for again by friendly name, per this phase's
  own explicit requirement. An incorrect password or any other import
  failure stops the installer outright, no retry loop.
- `Confirm-DeltaIisHttpsBinding` - creates or reconciles ONLY this
  installer's own single HTTPS:443 binding (matched by protocol+port,
  never by replacing the site's entire bindings collection - the same
  discipline Phase 6's own `Confirm-DeltaIisWebsiteBinding` already
  established for the HTTP binding), always with SNI (`-SslFlags 1`)
  enabled. The certificate is associated by thumbprint via the binding
  object's own `AddSslCertificate` method - confirmed directly against a
  real IIS binding that calling it again with a *different* thumbprint on
  an already-bound binding correctly replaces the association in place
  (no duplicate binding), so one call handles both "no certificate yet"
  and "replace the existing certificate."
- `Confirm-DeltaIisSslConfigurationResult` - independent post-
  configuration verification: re-reads the certificate store and IIS from
  scratch and checks certificate presence, binding existence, thumbprint
  match, host header match, and SNI enablement, collecting every failure
  at once (the same shape `Confirm-DeltaIisWebsiteConfigurationResult`,
  Phase 6, already established) rather than stopping at the first.
- `Show-DeltaIisSslSummary` - this phase's own "Summary" example, with an
  "Existing certificate retained" vs. "Imported" distinction (matching
  Phase 3/4/6's own "never claim to have just done something that was
  already there" convention) that the example itself doesn't show but the
  underlying Design Philosophy already implies.
- `Invoke-DeltaIisSslCertificateSetup` - the orchestrator (the Certificate
  Wizard). Reuses `Show-DeltaIisInstallCancelledNotice` (Phase 3) verbatim
  for the Cancel case - its wording is already completely generic.

### Bug found during real validation: unsuppressed cmdlet/method output corrupting a return value

`Confirm-DeltaIisHttpsBinding` called `New-WebBinding`/`Set-WebBinding`
and the binding object's own `AddSslCertificate` method as bare
statements, without piping to `Out-Null` or casting to `[void]`. A .NET
method call's return value (even when the value itself is `$null`) is
still written to PowerShell's output stream when left unsuppressed -
unlike a cmdlet that genuinely produces zero output records, this
silently added an extra element to `Invoke-DeltaIisSslCertificateSetup`'s
own returned value, turning what should have been a single
`[PSCustomObject]` into a multi-element array. The caller's own
`$sslResult.HttpsConfigured` property access then failed under
`Set-StrictMode -Version Latest` with "The property... cannot be found on
this object." Caught immediately during real validation (the "Fresh
certificate import" scenario) precisely because this phase's own
orchestrator - unlike Phase 6's analogous `Invoke-DeltaIisWebsiteConfiguration`,
which happens to never have its return value destructured by a caller -
actually returns a value real callers depend on. Phase 6's own
`Confirm-DeltaIisWebsiteBinding` had the exact same latent pattern
(unsuppressed `New-WebBinding`/`Set-WebBinding`) and was fixed at the same
time even though it had not yet caused an observable failure, since it is
the identical bug waiting to surface the moment a future caller inspects
its own return value.

### Certificate Store strategy

`Cert:\LocalMachine\My` only, identified exclusively by thumbprint -
never a friendly name lookup, never a file copied into the DELTA
application directory. Replacing a certificate never deletes the
previous one from the store (only the binding's association changes) -
consistent with this project's own "never delete something without being
asked" conservatism; an administrator who wants the old certificate
actually removed does so by hand.

### Thumbprint verification

`Confirm-DeltaIisSslConfigurationResult` re-reads `Cert:\LocalMachine\My\<thumbprint>`
and the HTTPS binding's own `certificateHash` independently after every
configuration - never trusts `Import-PfxCertificate`'s returned object or
`AddSslCertificate`'s lack of a thrown error alone.

### HTTPS binding reconciliation

Matched by protocol (`https`) and port (`443`) only - never by replacing
the bindings collection - so any other HTTPS binding an administrator
added by hand (a different port, a different host header) is left
completely untouched, per this phase's own "Do not disturb unrelated
HTTPS bindings" / "Do not remove administrator-created bindings"
requirements.

### Validation

Performed almost entirely with real operations against this development
machine's real IIS/DELTA website, using safe, throwaway self-signed test
certificates (`New-SelfSignedCertificate` + `Export-PfxCertificate`) -
never anything sensitive. Only the GUI file-picker
(`Select-DeltaSslFile`, which requires an interactive desktop dialog) and
the numbered-choice prompts were mocked; every certificate-store/IIS
operation (`Import-PfxCertificate`, `New-WebBinding`, `AddSslCertificate`,
and all verification reads) ran for real.

- **HTTP-only deployment** - declining ("No") reported "HTTPS has not
  been configured" and returned `HttpsConfigured = $false`, no binding
  created.
- **Fresh certificate import** - a real self-signed `.pfx` was imported
  into `Cert:\LocalMachine\My`, a real HTTPS binding was created with SNI
  enabled, the certificate was associated by thumbprint, and
  verification passed - independently re-confirmed via a direct
  `Get-WebBinding` call showing the correct `certificateHash`.
- **Existing certificate replaced** - choosing "Replace" against the
  already-configured certificate imported a second real self-signed
  certificate and correctly updated the *same* binding's
  `certificateHash` to the new thumbprint (confirmed no duplicate binding
  was created).
- **Existing certificate retained** - choosing "Keep" left the binding
  and its thumbprint completely unchanged, reporting `Source = 'Existing'`.
- **Cancel path** - choosing "Cancel" against an already-configured
  certificate returned `Cancelled = $true` with no changes - confirmed
  directly that the binding's `certificateHash` was identical before and
  after.
- **Invalid password** - a real `Import-PfxCertificate` call with the
  wrong password stopped the installer with Windows's own clear error
  message, no retry loop.
- **Invalid .pfx** - tested both ways: a wrong file extension was
  rejected before any import was even attempted, and a `.pfx`-named file
  with corrupt/non-certificate content failed at `Import-PfxCertificate`
  itself with a clear "not a valid PFX file" error.
- **Missing file** - a mocked file-dialog cancellation (`Select-DeltaSslFile`
  returning `$null`, the real dialog's own behavior when an administrator
  closes it without choosing a file) stopped the installer with a clear
  message, before any password prompt.
- **Idempotent reruns** - re-running the fresh-import path a second time,
  then "Keep" a third time, left exactly one HTTPS binding on the site
  throughout (confirmed via a direct `Get-WebBinding` count) - no
  duplicate bindings ever created.
- **HTTPS binding verification** - covered by every scenario above that
  reaches `Confirm-DeltaIisSslConfigurationResult`; also validated that
  it independently re-reads state rather than trusting prior steps (the
  bug described above was caught specifically because verification and
  the orchestrator's own return value are two genuinely independent
  checks).

A full end-to-end real run of `setup-iis.ps1` (Phases 1 through 7,
declining SSL) also completed successfully, exit code 0, with the new
"HTTPS / Not Configured" summary section displayed correctly. All test
certificates were removed from `Cert:\LocalMachine\My` and the HTTPS
binding was removed afterward, leaving the real DELTA website in the
same HTTP-only baseline state Phase 6 already established.

## Enhancement: Certificate + Private Key input (BouncyCastle)

**Status: Completed.** `setup-iis.ps1` now accepts the same certificate
inputs `setup-nginx.ps1` has always accepted (a `.crt`/`.cer`/`.pem`
certificate + a `.key`/`.pem` private key) in addition to the original
`.pfx` input - the administrator chooses which at wizard time, and the
final installed state is identical either way. This is an enhancement to
the existing SSL Certificate phase, not a redesign - the original `.pfx`
workflow's own implementation is untouched.

### Preceding investigation

Before implementing this, a standalone investigation (documented in full
in this repository's own conversation history, summarized here) empirically
confirmed on this exact Windows Server 2025 / PowerShell 5.1 / .NET
Framework 4.8.1 runtime that:

- `RSA`/`RSACng`/`ECDsaCng` expose only `ExportParameters`/`ImportParameters`
  - the PEM/DER convenience methods (`ImportFromPem`, `ImportPkcs8PrivateKey`,
  `ImportEncryptedPkcs8PrivateKey`, etc.) that a first guess might expect
  are **.NET 5+/.NET Core 3.0+ only** and are genuinely absent from this
  runtime (confirmed via direct reflection on the loaded types, not
  merely documentation).
- A hand-written ASN.1 DER parser (built and verified working, end to
  end, during that investigation) **can** cover unencrypted PKCS#1/PKCS#8
  RSA keys using only `RSA.ImportParameters`/`RSACertificateExtensions.CopyWithPrivateKey`
  - no third-party library needed for that narrow case.
- The same approach **cannot** reasonably or safely cover encrypted
  private keys (PBES2 PKCS#8, or OpenSSL's own legacy PKCS#1 encryption
  scheme with its own undocumented-in-.NET `EVP_BytesToKey`-based KDF)
  without reimplementing meaningful parts of a crypto library by hand -
  exactly what this phase's own requirements explicitly rule out ("Do
  not implement custom PBES2 or OpenSSL-compatible decryption").

This is why BouncyCastle - a mature library that already implements all
of the above correctly - is the conversion engine, per this phase's own
explicit requirement, rather than extending the hand-written parser.

### BouncyCastle package and license

- **Package:** `BouncyCastle.Cryptography` (the current, actively-
  maintained official NuGet package from the Bouncy Castle project -
  supersedes the older, unmaintained `BouncyCastle`/`Portable.BouncyCastle`
  packages).
- **Version:** `2.7.0` (latest stable at the time this was implemented).
- **Assembly vendored:** `lib/net461/BouncyCastle.Cryptography.dll` from
  inside the package - the build specifically targeting .NET Framework
  4.6.1, loadable directly via `Add-Type -Path` on this project's own
  PowerShell 5.1/.NET Framework 4.8 runtime, with no indirection through
  `netstandard2.0`.
- **License:** MIT (confirmed directly from the package's own NuGet
  metadata AND its bundled `LICENSE.md`, copied verbatim) - fully
  compatible with this project's own distribution; permissive, no
  copyleft, no obligation beyond retaining the copyright/license notice.
- **Vendored, not downloaded at install time:** committed directly into
  `lib/BouncyCastle/` (DLL + `LICENSE.md` + a `README.md` documenting the
  exact package/version/source/rationale and how to update it) rather
  than following the `installers\`-cache-and-download pattern
  `setup-nginx.ps1`/`setup-iis.ps1`'s own ARR/URL-Rewrite/NGINX downloads
  use - see `lib/BouncyCastle/README.md`'s own "Why vendored, not
  downloaded" section for the full reasoning (in short: this is a
  library dependency of the script itself, not a separate product being
  installed onto the target machine, and removing the network dependency
  from a certificate-import code path matters more here).

### Supported certificate/key formats

Whatever BouncyCastle's own `PemReader` supports - this project does not
maintain or need to enumerate an exhaustive list, since no format-
specific logic was written here (the whole point of using BouncyCastle
rather than the hand-written parser). Confirmed directly, via real
generated test material, all of the following combine into a working,
importable PFX:

- RSA, unencrypted, PKCS#1 (`-----BEGIN RSA PRIVATE KEY-----`)
- RSA, unencrypted, PKCS#8 (`-----BEGIN PRIVATE KEY-----`)
- RSA, encrypted, PKCS#8/PBES2 (`-----BEGIN ENCRYPTED PRIVATE KEY-----`)
- RSA, encrypted, the **legacy OpenSSL PKCS#1 scheme**
  (`-----BEGIN RSA PRIVATE KEY-----` + `Proc-Type: 4,ENCRYPTED` +
  `DEK-Info: DES-EDE3-CBC,...`) - genuinely produced and re-read by
  BouncyCastle itself during validation, confirming it handles a format
  a hand-rolled PBES2-only decryptor would have missed entirely.
- EC (P-256), unencrypted, PKCS#8 - BouncyCastle parses and combines this
  correctly (see "Known limitation: EC certificates" below for what does
  *not* work downstream of BouncyCastle's own output).

### Known limitation: EC certificates

BouncyCastle correctly parses EC certificates/keys and correctly builds
a PKCS#12 containing them - confirmed directly: the resulting `.pfx`
loads successfully via a raw `X509Certificate2` constructor, with a
working private key. However, Windows' own `Import-PfxCertificate`
cmdlet - the **existing, unmodified** import step this enhancement
deliberately reuses rather than replacing - silently fails to import a
BouncyCastle-produced EC PFX (returns nothing, no thrown exception).
Multiple BouncyCastle-side configurations were tried (default PBE
algorithm, DER encoding, legacy PBE algorithms) with the identical
result each time. Critically, this is **not** a blanket "Windows can't
import EC PFX files" limitation - a `.NET`-native (`New-SelfSignedCertificate`
+ `Export-PfxCertificate`) EC `.pfx` imports via the same cmdlet without
issue - so the issue is specific to a structural difference in how
BouncyCastle's PKCS#12 writer encodes an EC key bag versus how .NET's
own PFX export does it, not to EC support in general.

Per this phase's own "Do not artificially restrict the implementation to
RSA" requirement, EC was **not** hard-blocked in code - the Certificate +
Private Key path accepts EC certificates/keys exactly like RSA ones, and
`Confirm-DeltaIisSslConfigurationResult`'s own existing, unmodified
verification logic already catches the resulting failure cleanly (a
clear "Certificate import reported success but no usable certificate was
returned" `Stop-Setup`, not a crash or a silent false success). RSA is
the fully-validated, recommended choice for the Certificate + Private
Key path; EC administrators should either supply an EC `.pfx` built by
another tool directly (Option 1, which does not go through BouncyCastle
at all) or be aware this specific combination currently fails cleanly
rather than succeeding.

### Temporary PKCS#12 handling

- **Filename:** `[System.IO.Path]::GetRandomFileName()` (a
  cryptographically unpredictable name), under the system temp directory.
- **Password:** the new shared `New-DeltaRandomPassword`
  (`RNGCryptoServiceProvider`-backed, not `[guid]::NewGuid()` - a GUID is
  not documented or guaranteed to be cryptographically unpredictable, and
  this value stands in for a real credential however short-lived) -
  never shown to, or asked of, the administrator.
- **Import immediately, then always removed:** `Import-DeltaIisSslCertificate`
  wraps the entire supply-method branch in a `try`/`finally` -
  `Remove-DeltaTemporaryFileSecurely` (lib\DeltaInstaller.Common.ps1,
  generic) runs in the `finally`, so the temporary file is removed
  whether the subsequent `Import-PfxCertificate` call succeeds or fails.
  A *second*, independent cleanup also exists inside
  `New-DeltaIisTemporaryPfxFromCertificateAndKey` itself, for the case
  where the BouncyCastle conversion step fails before a file even exists
  to hand back - confirmed directly (see Validation below) that zero
  `.pfx` files are ever left behind in the temp directory, on success or
  on any tested failure path.
- **Secure delete:** `Remove-DeltaTemporaryFileSecurely` overwrites the
  file's own bytes with fresh `RNGCryptoServiceProvider` output before
  removing it - documented as best-effort (SSD wear-leveling means even
  this is inherently weaker than on a spinning disk; this is stated
  plainly rather than overclaiming a stronger guarantee than the
  mechanism actually provides).
- **The `.pfx` (Option 1) path never creates or touches any temporary
  file** - it is not a "special case of 0 temp files," it simply never
  enters the code path that creates one at all.

### Implementation

- `Install-DeltaBouncyCastleTypes` (lib\DeltaInstaller.Common.ps1) -
  idempotently loads the vendored `BouncyCastle.Cryptography.dll` and
  registers `DeltaBouncyCastlePasswordFinder`, a small compiled C# class
  implementing BouncyCastle's own `IPasswordFinder` interface (PowerShell
  cannot implement a .NET interface directly - a tiny `Add-Type
  -TypeDefinition` class is the standard, minimal bridge).
- `Test-DeltaPrivateKeyEncrypted` (lib\DeltaInstaller.Common.ps1) -
  detects encryption via the same two textual PEM markers real tooling
  uses (`BEGIN ENCRYPTED PRIVATE KEY`, or a `Proc-Type: 4,ENCRYPTED`
  header line) - never a blind decryption attempt - so
  `Import-DeltaIisSslCertificate` can honor "If the key is not encrypted:
  Do not prompt" precisely.
- `ConvertTo-DeltaPfxFromCertificateAndKey` (lib\DeltaInstaller.Common.ps1)
  - the actual BouncyCastle-based conversion: reads the certificate and
  key via `PemReader`, builds a `Pkcs12Store`, saves it to the
  destination path. Deliberately generic (no IIS-specific knowledge at
  all), per this enhancement's own "They should be generic certificate
  helpers rather than IIS-specific helpers" requirement - a future
  `setup-nginx.ps1` enhancement could reuse it identically.
- `New-DeltaRandomPassword`/`Remove-DeltaTemporaryFileSecurely`
  (lib\DeltaInstaller.Common.ps1) - the generic secure-random-value and
  secure-delete helpers described above.
- `Read-DeltaIisCertificateSupplyMethod` (setup-iis.ps1) - the new
  "How would you like to provide your certificate?" question, default
  `2) Certificate + Private Key`. Asked only after
  `Read-DeltaIisSslCertificateChoice`'s own "Yes" (or an existing
  certificate's own "Replace") - the original Yes/No gate deciding
  whether to configure HTTPS **at all**, and its "No" -> HTTP-only
  outcome, are completely unchanged. This was a genuine design decision
  during implementation (confirmed with the requester before writing
  code): the new question is a second, inner question, not a replacement
  for the outer gate.
- `Select-DeltaIisCertificateFile`/`Select-DeltaIisPrivateKeyFile`
  (setup-iis.ps1) - reuse the existing shared `Select-DeltaSslFile`/
  `Test-DeltaSslFileExtension`, restricted to `.crt`/`.cer`/`.pem` and
  `.key`/`.pem` respectively.
- `New-DeltaIisTemporaryPfxFromCertificateAndKey` (setup-iis.ps1) - pure
  orchestration (prompts, picks files, calls the shared conversion
  helper, returns the temp path + password) - owns no conversion logic
  itself, per this enhancement's own "the IIS installer should
  orchestrate the workflow rather than own the certificate conversion
  logic" requirement.
- `Import-DeltaIisSslCertificate` (setup-iis.ps1) - restructured to ask
  the new supply-method question and branch on it, but the
  `Import-PfxCertificate` call and its own result-validation logic are
  **byte-for-byte unchanged** from before this enhancement - only how
  `$pfxPath`/`$securePassword` get populated differs between the two
  branches.
- `Invoke-DeltaIisSslCertificateSetup`, `Confirm-DeltaIisHttpsBinding`,
  `Confirm-DeltaIisSslConfigurationResult`, `Show-DeltaIisSslSummary` -
  **zero changes.** The orchestrator already called
  `Import-DeltaIisSslCertificate` with no parameters; that function now
  internally asks one more question before doing what it already did.
  Verification and the summary have no reason to know or care which
  supply method produced the certificate they're reporting on - and
  `Show-DeltaIisSslSummary` already never referenced a supply method, so
  the "summary must not reveal which input method was used" requirement
  was satisfied by construction, not by an explicit code change.

### Validation

Performed almost entirely with real operations - real BouncyCastle
parsing/PKCS#12 building, real `Import-PfxCertificate` calls, real IIS
binding changes - using safe, throwaway self-signed test certificates
generated via BouncyCastle itself (mirroring the preceding investigation's
own approach). Only the GUI file-picker (`Select-DeltaSslFile`) and the
numbered-choice prompts were mocked, since neither can be driven
non-interactively in this environment.

- **Existing PFX workflow still works unchanged** - validated live
  twice: once against a fresh HTTP-only site, once against the "Replace"
  branch of an already-configured site (a real scenario this
  enhancement's own new question could have disturbed if implemented
  carelessly) - both produced the exact same behavior as before this
  enhancement, confirmed via the returned thumbprint matching the
  administrator-selected `.pfx`'s own certificate exactly.
- **Unencrypted CRT/KEY** - validated with both PKCS#1 and PKCS#8 RSA
  keys; both imported and verified successfully with no passphrase
  prompt shown (confirmed `Test-DeltaPrivateKeyEncrypted` correctly
  reported `$false` for both before the wizard even ran).
- **Encrypted CRT/KEY** - validated with an encrypted PKCS#8 RSA key:
  the passphrase prompt appeared (only because the key was actually
  encrypted), the correct passphrase produced a successful import, and a
  deliberately wrong passphrase stopped the installer with a clear
  message and left zero temporary files behind.
- **RSA certificates** - the primary, fully-validated case throughout.
- **EC certificates** - validated to the extent this exact combination
  actually behaves (see "Known limitation: EC certificates" above) -
  BouncyCastle-side parsing/combining succeeds; the existing,
  unmodified `Import-PfxCertificate` step fails cleanly and is caught by
  the existing, unmodified verification logic, exactly as it would for
  any other import failure.
- **PKCS#1** / **PKCS#8** - both validated explicitly, unencrypted.
- **Automatic temporary PKCS#12 cleanup** - validated on both a
  successful import and a deliberate failure (wrong passphrase) - zero
  `.pfx` files remained in the temp directory afterward in either case.
- **Rerunnable installs** - re-running the Certificate + Private Key
  path a second time against an already-configured site (via "Replace")
  produced exactly one HTTPS binding throughout, no duplicates.
- **Existing Replace/Keep/Cancel flows remain unchanged** - all three
  validated explicitly; Keep and Cancel in particular take a code path
  that never reaches `Read-DeltaIisCertificateSupplyMethod` at all (this
  enhancement's own new question), so they were trivially unaffected by
  construction, confirmed anyway.

A full real run of the actual `setup-iis.ps1` entry point (not the test
harness) against a live "existing certificate" state, answering "Keep,"
completed successfully end to end, exit code 0, with the summary
correctly showing "Existing certificate retained" - with no indication
anywhere in the output of which supply method had originally produced
that certificate (it had, in fact, originally come from the Certificate
+ Private Key path in an earlier step of the same validation session).

All test certificates were removed from `Cert:\LocalMachine\My`, the
HTTPS binding was removed, and all temporary files were cleaned up
afterward, leaving the real DELTA website back in the same HTTP-only
baseline state established before this validation began.

## Objective

Document the recommended Windows-native approach. This phase differs from `setup-nginx.ps1`'s own Phase 2/3 more than any other, because NGINX and IIS fundamentally disagree about where a TLS certificate lives.

## Why NGINX's own approach does not translate

`setup-nginx.ps1` copies an administrator-selected certificate/private-key pair into `C:\nginx\certs\` and references that fixed path directly from the generated config - correct for NGINX, which reads certificate material straight off disk. IIS does not work this way: HTTPS bindings reference a certificate already sitting in the **Windows Certificate Store**, identified by **thumbprint**, not a file path. Storing a certificate under the DELTA application directory the way NGINX does would not even be usable by IIS.

## Recommended approach

- **Windows Certificate Store:** `Cert:\LocalMachine\My` is the canonical location for a server's own HTTPS certificates - the direct IIS analogue of `C:\nginx\certs\`.
- **Input format:** unlike NGINX's separate `.crt` (certificate) + `.key` (private key) pair, IIS/Windows fundamentally wants a single password-protected `.pfx` bundling both together. Requiring a `.pfx` from the administrator (rather than introducing a new OpenSSL-style dependency this project does not currently have, purely to combine a `.crt`/`.key` pair into one) is the simpler, more Windows-native choice, and should be documented as a deliberate difference from NGINX's own wizard rather than a limitation to work around later.
- **Import:**

```powershell
Import-PfxCertificate -FilePath $selectedPfxPath -CertStoreLocation Cert:\LocalMachine\My -Password $securePassword
```

  returns the imported certificate object, whose `.Thumbprint` is what the Existing Certificate Handling section below and the binding step below actually consume.

- **HTTPS binding, by thumbprint:**

```powershell
New-WebBinding -Name $Script:DeltaIisSiteName -Protocol https -Port 443 `
    -HostHeader $Script:DeltaWebsiteDomain -SslFlags 1

(Get-Item "Cert:\LocalMachine\My\$thumbprint") |
    New-Item -Path "IIS:\SslBindings\0.0.0.0!443!$($Script:DeltaWebsiteDomain)"
```

  `-SslFlags 1` enables Server Name Indication (SNI) - required for a host-header-based binding to coexist with any other HTTPS site already on the same IP/port, mirroring the same "this installer never assumes it owns the whole box" posture Phase 5 already establishes.

## Wizard shape

The prompt flow (already-have-a-certificate Yes/No, standard Windows file selection dialog rather than a manually-typed path, validate the selection before proceeding) should mirror `Read-SslCertificateChoice`/`Select-DeltaSslFile` as closely as the `.pfx`-vs-`.crt`+`.key` difference above allows - the *shape* of the wizard is reusable even though the underlying file format and storage mechanism are not.

## Existing Certificate Handling

Originally its own standalone Phase 9 in the roadmap - merged into this
phase (see the Status table's own renumbering note) for the same reason
`setup-nginx.ps1`'s own `Install-DeltaSslCertificate` implements "import a
certificate" and "handle an already-imported certificate on rerun" as one
wizard, not two separate phases: IIS's own version follows the identical
shape, and there was never a clean seam to split it at.

### Objective

Provide the same safe-rerun guarantee `setup-nginx.ps1`'s own SSL Certificate Wizard provides: never overwrite or replace an existing IIS HTTPS binding/imported certificate without explicit confirmation.

### Detecting "already configured"

Check whether the DELTA site (Phase 5) already has an HTTPS binding, and whether the certificate store already contains a certificate presented for that binding's thumbprint - the two-part check is deliberate, mirroring `Test-DeltaSslCertificateFilesExist`'s own "only treat this as an existing certificate when BOTH halves are genuinely present" requirement (there, both the `.crt` and `.key` file; here, both the binding *and* a resolvable certificate behind it - a binding pointing at a thumbprint no longer present in the store is closer to `setup-nginx.ps1`'s own `Broken` state concept than to "an existing certificate," and should be surfaced as a distinct, clearly-explained case rather than silently treated as either "none" or "existing").

### Behavior

The same three actions, offered the same way (`Read-ExistingSslCertificateChoice`'s own no-bare-Enter-default shape, since this is exactly as consequential a decision here as it is for NGINX):

- **Replace existing certificate** - import the newly-selected `.pfx` and update the binding to the new thumbprint.
- **Keep existing certificate** - leave the binding and certificate store entry untouched; still ensure the site itself is otherwise correctly configured (mirrors `Install-DeltaSslCertificate`'s own "Keep" path setting `$Script:SslCertificateConfigured` without touching a single file").
- **Cancel** - exit immediately, nothing written or reconfigured, mirroring `Show-SslCertificateCancelledNotice` + `exit 0`.

---

# 8. Runtime Management

**Note - narrower precursor implemented:** `Show-DeltaIisManagementMenu` now exists in `setup-iis.ps1` (called from the orchestration block immediately once `Get-DeltaIisManagedWebsiteResult` confirms a managed site exists, in place of falling through to Phase 6/Phase 7) - the direct IIS analogue of `Show-DeltaNginxManagementMenu`, offering Start/Stop/Restart Website, Restart Application Pool, Browse Website, Validate Configuration, and Exit. This was a UX/orchestration-only request, explicitly scoped to *not* redesign the installer - it does **not** implement the three-signal (service/website/app pool) `Broken`-state model described below; status is read as a single `(Get-Website).State` value only. The fuller model below remains **Not Started**.

## Objective

Investigate and define how `setup-iis.ps1` determines runtime state - directly informed by `TODO-setup-nginx-enhancements.md`'s own Phase 7 (Managed Runtime State), whose central lesson generalizes here even though the underlying mechanism does not: **never trust a single signal as proof of a healthy managed instance; cross-validate multiple independent sources of truth, and report any disagreement between them as `Broken` rather than silently picking one.** For NGINX that meant the pid file vs. the process list. For IIS, there are three independent signals instead of two, and they can disagree with each other in exactly the same spirit as NGINX's pid file could disagree with `Get-Process`.

## The three signals

- **Service state** - the World Wide Web Publishing Service (`W3SVC`), a genuine Windows Service: `Get-Service -Name W3SVC`. The same primitive `setup.ps1` already uses for PostgreSQL's own service (`Wait-ForPostgresServiceRunning`, `lib\DeltaInstaller.Common.ps1`) - direct reuse of an established pattern in this project, not a new one.
- **Website state** - `(Get-Website -Name $Script:DeltaIisSiteName).State` (`Started`/`Stopped`), independent of whether the W3SVC service as a whole is running.
- **Application pool state** - `Get-WebAppPoolState -Name $Script:DeltaIisAppPoolName` (`Started`/`Stopped`), independent of the website's own state.

## Proposed state model

Mirroring `Get-DeltaNginxRuntimeState`'s own four-state shape as closely as IIS's architecture allows:

- **`NotInstalled`** - the DELTA site itself does not exist (Phase 5 found nothing).
- **`Stopped`** - the site exists; W3SVC/website/app pool are all cleanly stopped, with nothing contradicting that.
- **`Running`** - W3SVC is running, **and** the website reports `Started`, **and** the application pool reports `Started` - all three, not any one alone. A running W3SVC service with the DELTA website itself `Stopped` is not `Running`, exactly as a `nginx.exe` process existing without a valid pid file was never `Running` for NGINX.
- **`Broken`** - everything else, always with a specific, human-readable reason, never silently normalized - concrete examples worth naming explicitly (the direct IIS analogues of NGINX's own stale-pid-file/orphan-process examples):
  - the website reports `Started` but its application pool is `Stopped` (nothing will actually serve a request in this state, despite the website "looking" started);
  - **Rapid-Fail Protection** - a well-known, common real IIS failure mode where the application pool automatically stops itself after the worker process crashes repeatedly within a short window. This should be its own named, recognizable `Broken` reason (detectable via the app pool's own state plus, where available, the `WAS`/Application Pool event log entries), not lumped into a generic "stopped" message - an administrator who has seen this before will recognize the name immediately.
  - W3SVC itself stopped while the website/app pool report `Started` (the reverse inconsistency).

## Recovery action

The direct analogue of `Invoke-DeltaNginxForceStop` - explicit confirmation, never silent, and scoped only to the DELTA site's own application pool/website (e.g. `Restart-WebAppPool`, or clearing Rapid-Fail Protection's stopped state), never to W3SVC as a whole or to any other site it happens to be hosting - the same "terminate only what is actually managed here, never anything unrelated" boundary `Invoke-DeltaNginxForceStop` already holds for NGINX, translated to "only this site/app pool," since W3SVC itself is shared, unrelated-site-affecting infrastructure this installer must never assume it owns (the same principle Phase 5 already establishes for the website itself, applied again here to the service layer).

---

# 9. Port Prerequisite Validation

## Objective

Reuse the fail-fast philosophy `TODO-setup-nginx-enhancements.md`'s own Phase 8 established: the installer should refuse to proceed if a required port is already owned by something unrelated, before any change is made to the system.

## How this differs once IIS is already installed

This is the one phase where directly reusing NGINX's own mechanism (`Get-ListeningTcpPortOwner`/`Test-RequiredPortAvailability`, raw `Get-NetTCPConnection` socket ownership) would be **actively wrong**, not merely different, and needs to be documented clearly so it isn't ported over unmodified by mistake:

- **Before IIS is installed** (a clean machine, or a machine where Phase 2 found IIS missing): the raw port-ownership check is still exactly right, and should be reused verbatim - if some other application (Apache, a dev server, NGINX itself, anything) already owns port 80/443 before IIS is ever installed, that is a genuine, fail-fast-worthy conflict, checked the identical way `Test-DeltaNginxPortPrerequisites` already checks it.
- **Once IIS is installed:** IIS does not bind ports directly the way `nginx.exe` does. All IIS sites share Windows's own kernel-mode HTTP.SYS listener - the process actually shown "owning" port 80/443 via `Get-NetTCPConnection` will generically be `System`/an `svchost.exe` hosting the HTTP service, **regardless of which site or how many sites are using that port**. Checking "is port 80 already in use" against a machine already running IIS is therefore always true and never meaningful - every existing IIS site already "uses" port 80 in exactly that sense, and that is completely normal, never a conflict.

  The check that is actually meaningful here is a **binding-level** one, not a socket-level one: is there already a *different* website bound to this exact port **and host header** combination? (`Get-WebBinding` / `Get-Website`, cross-referenced against `$Script:DeltaWebsiteDomain` from Phase 6.) Two different IIS sites sharing port 80 with two different host headers is normal, expected multi-tenancy, not a conflict - only a genuine collision (the same port **and** the same host header already claimed by a site that is not the DELTA site itself) is the real, fail-fast-worthy failure here.

## Managed NGINX Exception's IIS analogue

The equivalent of `Test-RequiredPortAvailability`'s "already owned by our own managed instance is not a conflict" rule becomes, for IIS: a binding collision against the DELTA site *itself* (Phase 5's own identity check) is expected and fine - re-running this installer against its own already-existing site should never report a conflict against its own binding. A collision against a *different, unrelated* site's binding is the real failure case this phase exists to catch, mirroring the exact same "distinguish the managed instance from anything else" principle, implemented through binding/host-header comparison instead of executable-path comparison.

## Addendum: implementation had drifted from this phase's own design - now corrected

The design above (`## How this differs once IIS is already installed`) already correctly specified a **binding-level** check, not a socket-level one - but the actual shipped implementation of `Test-DeltaIisRequiredPortAvailability` (`setup-iis.ps1`) never followed it: it special-cased `$owner.ServiceName -eq 'W3SVC'` on the raw `Get-ListeningTcpPortOwner` result instead. Confirmed via real testing against a live IIS installation actually serving the real DELTA site: HTTP.SYS-owned listeners are attributed to PID 4 ("System") by Windows, which resolves to no `Win32_Service` entry at all, so `ServiceName` is empty and the `-eq 'W3SVC'` comparison can never match - `Available` was reported `False` for ports IIS itself legitimately owned. This is now fixed by implementing exactly what this phase's own design already called for:

- `Get-DeltaIisPortBindingOwnership` (`lib\DeltaDoctor.IIS.ps1`) - the binding-level check this phase's design describes, built from the exact same primitives `Get-DeltaIisReverseProxyHandoverPlan` already uses for the reverse direction (a different provider asking whether IIS occupies its ports): `Get-DeltaIisSiteBoundPorts` for the binding scan, `Get-DeltaIisManagedWebsiteResult`/`Test-DeltaIisStockDefaultWebSite` for the same "DELTA-owned or verified stock Default Web Site is safe, anything else is a real conflict" classification already established for the Reverse Proxy Handover Plan. Never a second, independent binding parser.
- `Test-DeltaIisRequiredPortAvailability` now consults this instead of the raw owner's `ServiceName`: a port with no listener at all is available; a port bound by the DELTA site itself or a verified stock Default Web Site is available (IIS's own normal operation, never a conflict with itself); a port bound by a genuinely different, unrelated IIS website remains a real conflict, now reported by that website's own name (`Show-DeltaIisPortConflictNotice`'s new "IIS Website" field) rather than a useless `PID 4`/`System`; a port held by something outside IIS entirely remains a real conflict, reported exactly as before (process name/PID/executable).

### A second, related bug in the same feature: stale reverse-proxy state and an unconditional NGINX handover plan

Found during the same investigation, in the Manual Reverse Proxy Handover feature this phase's port check hands off to:

- `Show-DeltaIisManagementMenu` accepted a single `Get-DeltaReverseProxyState` snapshot from its caller (computed once, before the menu was ever entered) and reused that same object at both points that actually attempt to bind a port (Start Website, Restart Website) - even though the menu can stay open indefinitely and another provider's own runtime state can genuinely change while it does. It no longer takes a `-ReverseProxyState` parameter at all; Start Website/Restart Website each call `Get-DeltaReverseProxyState` (`lib\DeltaDoctor.ReverseProxy.ps1`) fresh, immediately before `Test-DeltaIisPortPrerequisites` - the same read-only, non-printing detection primitive `Invoke-DeltaReverseProxyDetection` itself already calls internally.
- Independently of that staleness, `Get-DeltaNginxReverseProxyHandoverPlan` (`lib\DeltaDoctor.NGINX.ps1`) returned `Actions = @('Stop NGINX')` unconditionally whenever NGINX was merely DELTA-managed - never checking whether NGINX was actually running. Since the Handover Plan dispatcher (`Get-DeltaReverseProxyHandoverPlan`, `lib\DeltaDoctor.ReverseProxy.ps1`) deliberately selects a DELTA-managed candidate regardless of its own `Active` classification (by design - an IIS site can still occupy a port while `Stopped`), this meant `Invoke-DeltaReverseProxyHandover`'s own empty-plan fast path could never trigger for NGINX, and a stopped/standby NGINX installation was always presented as "the current active DELTA reverse proxy," prompting to stop it even though there was nothing to stop. Fixed by having `Get-DeltaNginxReverseProxyHandoverPlan` check `Get-DeltaNginxRuntimeState` (the same authoritative runtime-state helper NGINX's own management menu already uses) and only include `Stop NGINX` when NGINX is both actually `Running` and its own required ports (`Get-DeltaNginxRequiredPorts`) overlap the requesting provider's. `Invoke-DeltaReverseProxyHandover`'s own empty-plan fast path (`lib\DeltaInstaller.Common.ps1`) is unchanged - this fix makes the NGINX plan actually produce the empty-`Actions` result that fast path was always designed to receive.

Validated live on a real Windows Server IIS installation already serving the real DELTA site: `Test-DeltaIisRequiredPortAvailability` correctly reported ports 80/443 as available once bound to the DELTA site's own binding (previously `False`); a simulated Stopped-NGINX handover plan produced `Actions = @()` with no prompt; a simulated Running-NGINX handover plan (overlapping ports) produced exactly `Actions = @('Stop NGINX')`.

---

# 10. Installation Summary

## Objective

Provide a detailed summary at the end of a successful run, matching `Show-DeltaNginxSummary`'s own level of detail and its "retain every existing section, this is the final output" convention, translated section-by-section into IIS-native concepts:

| `Show-DeltaNginxSummary` section | `setup-iis.ps1` equivalent |
|---|---|
| NGINX version installed | **IIS Version** (Phase 2) |
| NGINX Home / Main Configuration / DELTA Virtual Host paths | **Website Name** / physical path / generated `web.config` path (Phase 6) |
| Detected DELTA Backend (installation, environment file, backend port) | Unchanged - identical section, same data, same `Resolve-DeltaBackendPort` |
| Public Website / Frontend | Unchanged in spirit - the resolved domain and `https://`/`http://` frontend URL (Phase 6) |
| SSL Certificate (newly installed vs. existing certificate retained) | Unchanged in spirit, but reporting a **certificate thumbprint** rather than file paths (Phase 7) |
| HTTPS enabled/not enabled | Unchanged |
| Useful Commands (`nginx -t` / `-s reload` / `-s quit`) | IIS-native equivalents: `iisreset`, `Restart-WebAppPool -Name <pool>`, `Get-Website -Name <site>` |
| *(new)* | **Application Pool** - name, .NET CLR version, pipeline mode (Phase 6) |
| *(new)* | **Website Status** - the Phase 8 runtime state (`Running`/`Stopped`/`Broken`, with its `Reason` if `Broken`) |

Nothing from `Show-DeltaNginxSummary`'s own section list should be dropped merely because it doesn't map perfectly - a section with no direct IIS equivalent should still be considered for inclusion in spirit rather than silently omitted, the same "do not remove any existing information" instruction that already governs `setup-nginx.ps1`'s own summary.

---

# Design Principles

- No hardcoded DELTA installation path - `Get-DeltaInstallPath` is the only discovery mechanism, exactly as for NGINX.
- An existing, unrelated IIS installation (or unrelated website) is never assumed to belong to this installer - "IIS is installed" and "a DELTA site already exists" are independently checked facts, unlike NGINX where the whole installation directory is a single fact.
- A fixed, well-known site name (never inferred, never guessed from host header) is the primary way this installer identifies its own managed site, cross-validated against the resolved DELTA installation path as a defense-in-depth secondary signal - the same "match by an owned identifier, never by name alone" principle `Get-DeltaNginxManagedProcesses` already holds, applied to a different kind of identifier.
- Certificates live in the Windows Certificate Store, identified by thumbprint - never copied into the DELTA application directory the way NGINX's own `certs\` convention works. This is a deliberate, documented divergence from NGINX's approach, not an oversight.
- An already-configured HTTPS binding is never silently replaced or silently reused - the administrator always chooses explicitly (Replace/Keep/Cancel), exactly as for NGINX's own certificate handling.
- Runtime state is never decided from a single signal - W3SVC service state, website state, and application pool state must all agree before this installer reports `Running`; any disagreement between them is `Broken`, with a specific, named reason (Rapid-Fail Protection included by name, not genericized) - the same discipline `Get-DeltaNginxRuntimeState` already holds for the pid file vs. the process list.
- Recovery actions are always scoped to the DELTA site/application pool specifically, never to W3SVC as a whole or to any other site or pool it happens to be hosting.
- A port/binding conflict is an operational prerequisite failure, detected before any change is made to the system - implemented as a raw socket-ownership check before IIS exists, and as a binding/host-header collision check once it does; these are genuinely different mechanisms serving the same fail-fast principle, not the same code reused unmodified.
- Shared, engine-agnostic logic (DELTA discovery, backend port detection, website domain resolution and validation, and the token-substitution template-writing mechanism) lives in `lib\DeltaInstaller.Common.ps1` and is reused verbatim by both `setup-nginx.ps1` and `setup-iis.ps1` - only genuinely IIS-specific behavior belongs inside `setup-iis.ps1` itself.
- **Status of this promotion:** a preparatory refactoring pass (ahead of `setup-iis.ps1` Phase 1) has already moved every currently-known engine-agnostic piece out of `setup-nginx.ps1` and into `lib\DeltaInstaller.Common.ps1`:
  - `Resolve-DeltaInstallation` (Phase 1 above) - DELTA discovery/stop-if-missing.
  - `Write-DeltaTemplateFile` (Phase 6 above; was `Install-NginxConfigFile`) - load/substitute/write template rendering, with no knowledge of nginx.conf or web.config. **Confirmed (Phase 6):** `setup-iis.ps1`'s own `New-DeltaIisWebConfig` now calls this directly for `templates\iis\web.config` generation, exactly as anticipated here - no second template-rendering implementation was written.
  - `Read-DeltaYesNoConfirmation` - the shared rule/prompt/rule frame behind every Y/N confirmation (`setup-nginx.ps1`'s own install/start/force-stop confirmations all now call it with their own NGINX-specific body text); `setup-iis.ps1`'s own confirmation prompts (install, existing-certificate Replace/Keep/Cancel, force-recovery) should call this directly rather than re-writing the rule/prompt/rule boilerplate.
  - `Resolve-DeltaWebsiteDomain`/`Test-DeltaWebsiteDomain` and `Resolve-DeltaBackendPort`'s own dependency, `Get-EnvFileValue`, were already shared before this pass.
  - **Update (Phase 5):** `Resolve-DeltaBackendPort` itself (plus its `Test-ValidTcpPort` dependency and the `$Script:DefaultDeltaBackendPort` constant) has now also been promoted, once Phase 5 became a second real caller - see that phase's own "`Resolve-DeltaBackendPort` promoted to the shared library" section above for the full details, including the one behavior change (the invalid-`PORT` error message no longer names `setup-nginx.ps1` specifically).
  - Reviewed and found to have nothing further worth extracting: `setup-nginx.ps1`'s summary output (`Show-DeltaNginxSummary`) already composes entirely from the generic `Write-PhaseBanner`/`Write-Detail`/`Write-SetupBanner`/`Write-Success` primitives that were already shared - its own section *content* (NGINX version, vhost paths, `nginx -s reload`, etc.) is inherently NGINX-specific and correctly stays in `setup-nginx.ps1`. Likewise, no generic "create directory then copy a file" helper exists separately from `Write-DeltaTemplateFile` (which already does exactly that internally) - `setup-nginx.ps1`'s other file-handling code (`Install-NginxFromZip`'s zip-extraction, `Install-DeltaSslCertificateFiles`'s certificate copy) is genuinely NGINX/certificate-specific and was left in place per this document's own "Do not move certificate-specific logic" guidance.
  - Still only inside `setup-nginx.ps1`, correctly: the runtime state machine, PID handling, port ownership checks, the SSL certificate wizard, HTTP/HTTPS template selection, the NGINX management menu, and every direct `nginx.exe` invocation - these are NGINX implementation details with no IIS analogue in the same shape (see Phases 7-9 above for how IIS's own equivalents differ structurally, not just in name).
- Future enhancements should build upon the shared `Get-DeltaInstallPath()` helper, exactly as `TODO-setup-nginx-enhancements.md` already states for `setup-nginx.ps1`.

---

# Roadmap

Phases 1 through 6 are implemented (see the Status table at the top of this document for the current, authoritative phase count and numbering - kept up to date there rather than duplicated here). Implementation proceeds in order, exactly as `TODO-setup-nginx-enhancements.md`'s own phases were built one at a time - each phase above is written assuming every earlier phase already exists.

Once complete, `setup-iis.ps1` should provide: shared DELTA installation discovery and backend/domain resolution (reused, not reimplemented, from `lib\DeltaInstaller.Common.ps1`), automatic IIS installation on both Windows Server and Windows 11, an ARR/URL Rewrite-based reverse proxy, safe website discovery that never disturbs an unrelated IIS site, a Windows Certificate Store-based SSL wizard with the same safe-rerun guarantees as NGINX's own, a three-signal (service/website/app pool) managed runtime state model with the same "never trust one signal alone" discipline `setup-nginx.ps1` already applies to its pid file, a port/binding prerequisite check adapted to IIS's shared-listener architecture, and a detailed installation summary matching `Show-DeltaNginxSummary`'s own level of detail.

This document itself should be kept up to date the same way `TODO-setup-nginx-enhancements.md` is - each phase marked `Completed` (with the same "what was actually built, what was verified, and how" level of detail already established there) as it lands, never several at once, and never out of order.

# TODO - setup-nginx.ps1 Enhancements

## Overview

The initial implementation of `setup-nginx.ps1` successfully installs and configures NGINX for DELTA.

The following enhancements are planned to improve flexibility, support custom installation locations, and provide a better administrator experience.

Phases are implemented one at a time, in order. Do not start a phase before the previous one is marked Completed below.

---

## Status

| Phase | Description | Status |
|-------|--------------|--------|
| 1 | Use Shared DELTA Installation Discovery | Completed |
| 2 | SSL Certificate Wizard | Completed |
| 3 | Separate HTTP and HTTPS Templates | Completed |
| 4 | Automatic DELTA Backend Port Detection | Completed |
| 5 | Website Domain Configuration | Completed |
| 6 | Existing Certificate Handling | Completed |
| 7 | Managed Runtime State | Completed |
| 8 | Port Prerequisite Check | Completed |

**All currently planned phases are complete.** There is no pending phase at this time - any further work on `setup-nginx.ps1` requires a new phase to be added to this document (and its own Design Principles/roadmap updated) before implementation starts, per this file's own "do not start a phase before the previous one is marked Completed" rule.

---

# 1. Use Shared DELTA Installation Discovery

**Status: Completed** - `Resolve-DeltaInstallation` in `setup-nginx.ps1` calls the shared `Get-DeltaInstallPath` helper (`lib\DeltaInstaller.Common.ps1`) before anything else runs, and stops with a clear message if no installation is found. No hardcoded `C:\DELTA` path remains in this script.

## Objective

Remove the hardcoded `C:\DELTA` dependency.

Instead, resolve the DELTA installation by calling:

```powershell
Get-DeltaInstallPath
```

This helper already supports:

1. Windows Registry (`HKLM\SOFTWARE\PreventionWeb\DELTA`)
2. Legacy installation (`C:\DELTA` if `.env` exists)
3. Return `$null` if DELTA is not installed

If no installation is found:

- stop the installer
- display a clear message instructing the administrator to install DELTA first

---

# 2. SSL Certificate Wizard

**Status: Completed** - `Install-DeltaSslCertificate` in `setup-nginx.ps1` prompts the administrator (`Read-SslCertificateChoice`), opens standard Windows file selection dialogs for the certificate and private key (`Select-DeltaSslFile`), validates both (selected, exist, supported extension), and copies them into `C:\nginx\certs\delta.crt` / `C:\nginx\certs\delta.key`, setting `$Script:SslCertificateConfigured`. That flag now drives Phase 3's automatic HTTP/HTTPS template selection. The actual select/validate/copy work now lives in its own `Install-DeltaSslCertificateFiles` function, factored out so Phase 6 ("Existing Certificate Handling") could reuse it verbatim for its own "Replace" option rather than duplicating it - see Phase 6 below.

Instead of assuming an SSL certificate exists, prompt the administrator.

Example:

```
Do you already have an SSL certificate?

( ) Yes
( ) No
```

---

## If Yes

Prompt for:

- SSL Certificate
- Private Key

Prefer a standard Windows file selection dialog instead of manually entering paths.

Supported certificate formats:

- `.crt`
- `.cer`
- `.pem`

Supported private key formats:

- `.key`
- `.pem`

Validate that both selected files exist.

---

## Certificate Storage

Copy the selected files into the NGINX installation.

Example:

```
C:\nginx\
    certs\
        delta.crt
        delta.key
```

Do not reference the original file locations.

The generated NGINX configuration should always reference:

```nginx
ssl_certificate     C:/nginx/certs/delta.crt;
ssl_certificate_key C:/nginx/certs/delta.key;
```

---

# 3. Separate HTTP and HTTPS Templates

**Status: Completed** - `templates\nginx\delta.conf` has been replaced by two dedicated templates, `templates\nginx\delta-http.conf` (no SSL directives at all, not even commented out) and `templates\nginx\delta-https.conf` (a redirect-from-80 server block plus a `listen 443 ssl` block referencing the fixed `C:/nginx/certs/delta.crt` / `C:/nginx/certs/delta.key` paths - never the original certificate selection paths). `New-DeltaNginxConfiguration` in `setup-nginx.ps1` automatically picks between them based on `$Script:SslCertificateConfigured` (set by Phase 2's `Install-DeltaSslCertificate`, and by Phase 6 whenever an existing certificate is kept) - the administrator never selects a template manually. `Show-DeltaNginxSummary`'s output (virtual host mode, frontend URL, HTTPS section) now accurately reflects whichever template was actually generated; the old "HTTPS is not yet wired into the generated NGINX configuration" placeholder message has been removed.

Instead of maintaining one template with conditional SSL directives, maintain two dedicated templates.

Example:

```
templates/
    nginx/
        delta-http.conf
        delta-https.conf
```

Installer behavior:

If SSL certificate is provided:

- generate `delta-https.conf`

Otherwise:

- generate `delta-http.conf`

The HTTP template should contain no SSL directives.

The HTTPS template should contain the complete SSL configuration.

---

# 4. Automatic DELTA Backend Port Detection

**Status: Completed** - `Resolve-DeltaBackendPort` in `setup-nginx.ps1` reads `PORT` from `<DELTA InstallPath>\.env` (`$Script:DeltaEnvPath`, resolved via `Get-DeltaInstallPath` - no hardcoded `C:\DELTA` assumption) using the new, reusable `Get-EnvFileValue` helper (`lib\DeltaInstaller.Common.ps1` - ignores blank/comment lines, trims whitespace, strips matching quotes, case-insensitive key lookup, and is not DELTA- or PORT-specific so future `.env` values can reuse it). A missing `PORT` falls back to `$Script:DefaultDeltaBackendPort` (3000); a `PORT` value that fails `Test-ValidTcpPort` (not an integer, or outside 1-65535 - covers `PORT=abc`, `PORT=-1`, `PORT=70000`) stops the installer outright via `Stop-Setup` rather than silently defaulting. The detected `$Script:DeltaBackendPort` is baked into the selected vhost template's `proxy_pass` directive (and its new self-documenting "DELTA Backend" comment block, naming the source `.env` path and the detected port) by `Install-NginxConfigFile`'s new `-Replacements` token-substitution mode - `__DELTA_BACKEND_PORT__`/`__DELTA_ENV_PATH__` in `templates\nginx\delta-http.conf`/`delta-https.conf`. `Show-DeltaNginxSummary` now displays a "Detected DELTA Backend" section (installation, environment file, backend port) and the generated `proxy_pass` line. Confirmed directly during implementation: `Install-NginxConfigFile`'s substitution path must write with a BOM-less UTF-8 encoding ([System.IO.File]::WriteAllText with `UTF8Encoding($false)`, not `Set-Content -Encoding utf8`) - Windows PowerShell 5.1's `-Encoding utf8` prepends a byte-order mark that nginx does not skip, which fails `nginx -t` with "unknown directive" pointing at the file's own first line; verified both the missing-PORT and valid-PORT vhost output pass `nginx -t` after that fix. Still deliberately out of scope, reserved for later phases: website domain configuration (Phase 5) and existing-certificate overwrite handling (Phase 6).

Determine the backend application port by reading the DELTA `.env` file.

Example:

```
<InstallPath>\.env
```

Read:

```
PORT=
```

Behavior:

- valid port → use it
- missing → default to `3000`
- invalid → stop installation with a clear error

The generated NGINX configuration should use:

```
proxy_pass http://localhost:<PORT>;
```

instead of assuming port 3000.

---

# 5. Website Domain Configuration

**Status: Completed** - `Resolve-DeltaWebsiteDomain` (`lib\DeltaInstaller.Common.ps1`, alongside its `Test-DeltaWebsiteDomain` validator and `$Script:DefaultDeltaWebsiteDomain` default of `localhost`) prompts for the public hostname, trims it, and re-prompts with a specific rejection reason until it gets `localhost`, a blank answer (defaults to `localhost`), or a valid DNS hostname - never silently correcting anything. Placed in the shared lib file rather than `setup-nginx.ps1` itself, since it has no NGINX-specific knowledge and this phase's own requirements call out reuse by a future `setup-iis.ps1`. `setup-nginx.ps1` calls it after `Resolve-DeltaBackendPort` and stores the result in `$Script:DeltaWebsiteDomain`, which `New-DeltaNginxConfiguration` feeds into the same `-Replacements` token-substitution mechanism Phase 4 introduced - a new `__DELTA_SERVER_NAME__` token in `templates\nginx\delta-http.conf`/`delta-https.conf` (both `server_name` directives in the HTTPS template's redirect-and-443 pair), each accompanied by a self-documenting "Public Website" comment block naming the resolved domain. `Show-DeltaNginxSummary` now shows a "Public Website" section and a "Frontend" line built from the actual configured domain and template mode (`https://<domain>` vs `http://<domain>`) instead of a hardcoded `localhost`. Verified directly: `Test-DeltaWebsiteDomain` against every valid/invalid example in this phase's own requirements (localhost, `delta.example.org`, `delta.ncscm.gov.jo` accepted; `https://`/`http://` schemes, a trailing path, a port, a wildcard, and an embedded space all rejected with the intended specific reason); the interactive re-prompt loop via piped stdin (invalid input redisplays the reason and reprompts, blank input resolves to `localhost`); and both HTTP and HTTPS vhost templates, rendered with a real domain and with the `localhost` default, pass `nginx -t`.

## Objective

Prompt the administrator for the public website domain name during setup.

Example prompt:

```
Enter the public domain name for this website.

Examples:

delta.example.org
delta.ncscm.gov.jo

Leave blank to use localhost.
```

## Validation Rules

- trim whitespace
- accept blank (use `localhost`)
- reject protocols (`http://` or `https://`)
- reject ports
- reject paths
- reject spaces

## Usage

Store the validated domain name and use it when generating the NGINX virtual host.

Example:

```nginx
server_name delta.example.org;
```

instead of:

```nginx
server_name localhost;
```

This phase should only configure the generated NGINX `server_name` directive. It does not modify SSL certificate selection, certificate storage,
or backend port detection. Those are owned by Phases 2, 4, and 6 (Phase 6: see its own "Status: Completed" note above).

---

# 6. Existing Certificate Handling

**Status: Completed** - `Install-DeltaSslCertificate` in `setup-nginx.ps1` now checks `Test-DeltaSslCertificateFilesExist` (both `C:\nginx\certs\delta.crt` AND `delta.key` must be present - a half-present pair is treated as "no existing certificate") before ever prompting. No existing certificate: behavior is byte-for-byte unchanged from Phase 2 (`Read-SslCertificateChoice`). An existing certificate: `Read-ExistingSslCertificateChoice` presents Replace/Keep/Cancel (no bare-Enter default) instead of the original Yes/No question. Replace and Phase 2's original "Yes" both hand off to the same `Install-DeltaSslCertificateFiles` - the select/validate/copy workflow was factored out of `Install-DeltaSslCertificate` specifically so this phase would not duplicate it, per its own requirements. Keep sets `$Script:SslCertificateConfigured = $true` and `$Script:SslCertificateSource = 'Existing'` directly, without touching the certificate files or opening a file picker. Cancel (`Show-SslCertificateCancelledNotice` followed by `exit 0`) exits immediately with no failure banner - confirmed directly that `exit` called from a nested function bypasses the orchestration block's own `try`/`catch` entirely (the same mechanism the top-level existing-NGINX check already relies on), so nothing downstream (config generation, `nginx -t`, starting NGINX) ever runs. `Show-DeltaNginxSummary` gained a dedicated "SSL Certificate" section reading the new `$Script:SslCertificateSource` to report "Newly installed" vs "Existing certificate retained". Verified directly via an isolated test harness driving `Install-DeltaSslCertificate` (with `Select-DeltaSslFile` stubbed to avoid a real file dialog) through all four scenarios: no existing certificate unchanged (both "No" and "Yes" answers behave exactly as Phase 2); existing + Replace overwrites the certificate content and reports `SslCertificateSource=New`; existing + Keep leaves the original file content byte-for-byte untouched and reports `SslCertificateSource=Existing`; existing + Cancel exits with code 0, prints no further output, and leaves the certificate files unmodified. The generated HTTPS vhost, rendered against a real kept certificate, passes `nginx -t`.

If the destination already contains:

```
C:\nginx\certs\delta.crt
C:\nginx\certs\delta.key
```

prompt the administrator before overwriting.

Possible actions:

- Replace existing certificate
- Keep existing certificate
- Cancel

This prevents accidental replacement of a working production certificate.

---

# 7. Managed Runtime State

**Status: Completed** - A production report ("Status: Running", but `nginx -s quit` failing with `CreateFile() "C:\nginx\logs\nginx.pid" failed (2: The system cannot find the file specified)`) traced to a root cause: `setup-nginx.ps1` treated "a process named nginx.exe exists at `C:\nginx\nginx.exe`" as proof of a healthy, controllable instance, while `nginx.exe`'s own `-s <signal>` mechanism on Windows has no relationship to `Get-Process` at all - it locates its master process exclusively by reading the pid file. Those are two independent facts that can disagree (an externally deleted pid file, an incomplete prior shutdown, an instance started outside this script's control, etc.), and the script had no way to notice.

This phase makes the pid file the primary source of truth, exactly the way NGINX itself decides who its master process is:

- `templates\nginx\nginx.conf` now pins an explicit `pid logs/nginx.pid;` directive - the location is a documented fact this installer owns, never NGINX's undocumented compiled-in default.
- `Get-DeltaNginxRuntimeState` is the one function everything else (the management menu, `Start-DeltaNginx`, `Invoke-DeltaNginxReload`/`Stop`/`Restart`) calls to decide what state NGINX is actually in. It returns exactly one of `NotInstalled` / `Stopped` / `Running` / `Broken`:
  - `Running` requires the pid file to exist, parse to a real process ID, **and** `Test-DeltaManagedNginx` to confirm that ID is a live process whose executable path is `C:\nginx\nginx.exe` - a process existing is never sufficient by itself.
  - `Stopped` requires no pid file **and** no managed process - a genuinely clean state.
  - `Broken` is everything else (a stale pid file with nothing running, a process running with no pid file - the exact reported bug, a PID silently reused by an unrelated program, etc.), always reported with a specific, human-readable `Reason` - never silently normalized to `Stopped` or `Running`.
- Process enumeration (`Get-DeltaNginxManagedProcesses`, matched by exact executable path, never process name alone) is used only to distinguish a clean `Stopped` state from a `Broken` one, and to supply the Force Stop recovery action's target - never to decide `Running` by itself.
- Startup Validation: after `Start-DeltaNginx`'s fresh-start `Start-Process` call, `Test-DeltaNginxStartupHealth` must confirm all of: a live process, a pid file, that pid file's PID matching the live process, and every port this configuration should be listening on (80, plus 443 when a certificate is configured) actually listening - before "NGINX started successfully." is ever printed. Any failure stops the installer with a clear explanation instead of continuing.
- The existing-installation management menu now branches on `Get-DeltaNginxRuntimeState` instead of raw process detection: the full Validate/Reload/Restart/Stop/Exit menu when `Running`, just Start/Exit when cleanly `Stopped`, and a specific explanation plus a "Force Stop Managed Process" recovery action (never a silent one - it always requires an explicit Y/N confirmation, and terminates *only* the exact processes matched by executable path, never anything else) when `Broken`.
- Confirmed directly, against a real installation, that `nginx -t` on this Windows build creates an empty pid file as a side effect whenever no managed process is running - even though it only tests the configuration. Left in place, that would make `Get-DeltaNginxRuntimeState` report a false `Broken` verdict immediately after every routine validation. `Test-DeltaNginxConfiguration` now snapshots the runtime state before calling `nginx -t` and cleans up only that exact self-inflicted side effect (never a pre-existing inconsistency) - confirmed separately that an already-running instance's own valid pid file is untouched by `nginx -t` regardless, so this cleanup path never triggers for a live instance.

Validated end-to-end against a real NGINX installation on the development machine, including a live reproduction of the originally reported bug (orphaned worker processes with no pid file) resolved cleanly through the new Force Stop menu action, plus fresh start, graceful reload, restart (master PID changes), graceful stop, a stale pid file, a pid file referencing a live but unrelated process, and a corrupted (non-numeric) pid file - each classified and explained correctly.

---

# 8. Port Prerequisite Check

**Status: Completed** - An operational safety enhancement: `Test-DeltaNginxPortPrerequisites` runs immediately after `Resolve-DeltaInstallation`, before the orchestration block's own top-level "does nginx.exe already exist" branch - deliberately in front of BOTH the fresh-install workflow and the existing-installation management menu, not only the former.

- Required ports are determined by `Get-DeltaNginxRequiredPorts`, which reuses `Get-DeltaNginxVHostSummary.IsHttps` (the same helper the management menu already uses) rather than `$Script:SslCertificateConfigured` - that flag is only set once the SSL wizard actually runs, which happens well after this check. An existing installation's real, already-configured deployment mode is checked as-is (80, or 80+443 for HTTPS); a fresh install (no vhost written yet) naturally falls back to port 80 alone - the one port required regardless of which mode the not-yet-run SSL wizard ends up choosing.
- `Get-ListeningTcpPortOwner` resolves whoever is bound to a required port (PID, process name, executable path via the existing `Get-DeltaProcessById`, and - diagnostic only, best-effort - a Windows Service Name via CIM `Win32_Service`, confirmed directly to legitimately come back empty for services that fork/re-exec, such as PostgreSQL, or for kernel-hosted listeners under the `System` process; the notice omits the Service line entirely when unavailable rather than showing misleading information).
- `Test-RequiredPortAvailability` treats a port as available when it is genuinely free OR already owned by this installer's own managed NGINX instance - matched by exact executable path against `$Script:NginxExePath`, the same standard `Test-DeltaManagedNginx` already holds throughout the Runtime state section (Phase 7), never a process-name-only check. This is what lets an already-Running managed installation continue straight into the existing management menu without a false conflict.
- A genuine conflict (`Show-DeltaNginxPortConflictNotice`) exits immediately (exit code 1, a real prerequisite failure) with its own dedicated notice - before installation confirmation, before anything is downloaded, extracted, or configured, and before the existing-installation management menu ever runs either. Nothing about the runtime-state management or the management menu itself was touched by this phase.
- The "Available" success banner (`Show-DeltaNginxPortsAvailableNotice`) is only shown on the fresh-install side of the check - an already-existing managed installation proceeds silently into the management menu exactly as before, since that screen already conveys its own Status.

Validated directly against the real installation on the development machine: the existing Running instance's own ports correctly recognized as non-conflicting (managed exception); an unrelated process (a real, independent listener) occupying port 80 correctly reported with its PID/name/executable path and a clean exit before any change was made; the same for port 443 specifically while port 80 was free, confirming per-port attribution in a multi-port (HTTPS) check; and the "no vhost yet" fallback correctly narrowing the requirement to port 80 alone.

---

# Design Principles

- No hardcoded DELTA installation path.
- Registry is the primary installation discovery mechanism.
- Legacy installations remain supported.
- NGINX should use its own dedicated `certs` directory.
- HTTP deployments should not contain SSL directives.
- HTTPS deployments should use a dedicated configuration template.
- The generated `server_name` should reflect the administrator-provided public domain, defaulting to `localhost` when none is given.
- An already-installed certificate at the fixed `certs\` location is never silently replaced or silently reused - the administrator always chooses explicitly (Replace/Keep/Cancel).
- The pid file is the primary source of truth for NGINX's runtime state, exactly as NGINX itself uses it - process enumeration only ever validates or recovers, it never originates the runtime state verdict on its own.
- A running process is never, by itself, reported as a healthy managed instance - an inconsistency between the pid file and the process list is always surfaced as `Broken` with a specific reason, never silently normalized away.
- Recovery actions that terminate a process (Force Stop) always require explicit confirmation and only ever target processes matched by exact executable path - never process name alone, and never anything unrelated.
- A port conflict is an operational prerequisite failure, detected before any change is made to the system - never assumed to only matter for a fresh install, since an existing managed installation is just as entitled to a fail-fast check before it is asked to bind a port something else already owns.
- Future enhancements should build upon the shared `Get-DeltaInstallPath()` helper.

---

# Roadmap

All phases originally planned for this document (1 through 8) are **Completed**. `setup-nginx.ps1` now covers: shared DELTA installation discovery, an SSL certificate wizard with safe handling of an already-installed certificate, dedicated HTTP/HTTPS templates chosen automatically, automatic backend port detection from the DELTA `.env` file, an administrator-configured public website domain, a managed runtime state model (pid file as source of truth, cross-validated against the process list) driving both startup verification and the existing-installation management menu, and a fail-fast port prerequisite check that runs before any change is made - all baked into a single, self-documenting generated NGINX configuration that is validated with `nginx -t` before NGINX is ever started or reloaded.

There is no pending phase. Any further enhancement to `setup-nginx.ps1` requires a new phase to be added to this document first - see this file's own "Phases are implemented one at a time, in order" rule at the top.
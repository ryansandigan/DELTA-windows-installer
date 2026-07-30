# Windows Deployment

**Status:** Procedural guide. Runtime compatibility for this path has been established by static analysis ([05](05-windows-compatibility-assessment.md)); end-to-end operational validation on a real Windows Server is still pending — track it via [07 — Proof of Concept](07-windows-poc.md).
**Target:** Windows Server 2022, Node.js 24.x, PostgreSQL + PostGIS, Nginx for Windows.
**Related:** [01 — Runtime Architecture](01-runtime-architecture.md) · [04 — Database](04-database.md) · [05 — Compatibility Assessment](05-windows-compatibility-assessment.md) · [06 — Deployment Risks](06-deployment-risks.md)

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Windows Server 2022 | x64 |
| Node.js 24.x (Windows x64 build) | No version is pinned by the artifact — see [06 #10](06-deployment-risks.md#node-version-unpinned). Validate against this artifact before treating any specific 24.x build as final. |
| PostgreSQL for Windows | The EDB distribution is the standard choice; ships a Stack Builder companion tool for extensions. `setup.ps1`'s `Install-PostgreSql` function (Phase 2A) now automates this step — see [§Automated installer status](#automated-installer-status). |
| PostGIS extension for that PostgreSQL install | Installed via Stack Builder, **before** running database initialization — see [06 #6](06-deployment-risks.md#postgis-installation). `CREATE EXTENSION` cannot install PostGIS itself. Not yet automated (Phase 2B, planned) — see [§Automated installer status](#automated-installer-status). |
| Nginx for Windows | Any recent stable release; used purely as a reverse proxy, no Windows-specific module requirements. |
| NSSM or WinSW | For running the Node process as a Windows Service. NSSM is simpler for a single instance; WinSW suits a versioned XML/YAML service definition. |

## Installation order

1. Install Node.js 24.x.
2. Install PostgreSQL for Windows, then add PostGIS via Stack Builder.
3. Choose the DELTA application directory (default `C:\DELTA`) and unpack the `dts_shared_binary` artifact into it — separate from wherever this installer repository itself was checked out. `setup.ps1`'s `Resolve-DeltaAppRoot` (the prompt) and `Install-DeltaRuntime` (the deployment) automate this step; see [§Deployment layout](#deployment-layout) below.
4. Run `init_website.bat` (installs Yarn, project dependencies, `dotenv-cli`).
5. Run `init_db.bat` (creates the database, loads the schema — see [04](04-database.md#initialization-fresh-install)).
6. Create and populate `.env` in the application directory.
7. Smoke-test with `start.bat`.
8. Register and start the Windows Service.
9. Install and configure Nginx.
10. Validate — see [07](07-windows-poc.md#validation-checklist).

This document covers steps 4–9 in reference depth; [07 — Proof of Concept](07-windows-poc.md) is the same sequence expressed as a lean runbook.

## Deployment layout

Two directories matter, and they are never the same one:

| Directory | Contents | Owned by |
|---|---|---|
| The installer repository (wherever it was cloned/copied to) | `setup.ps1`, `init_db.ps1`, `upgrade_database.ps1`, `lib\`, `dts_shared_binary\` (the shipped artifact source), `.env.example` | This repository — installer code only, never executed as the running application |
| The DELTA application directory (**`C:\DELTA` by default — administrators may choose another location**) | The deployed DELTA runtime: everything from `dts_shared_binary\` (schema/upgrade SQL, compiled `build\`, `locales\`, `package.json`), plus the generated `.env`, plus `uploads\`/`logs\` | The DELTA application — this is what the Windows Service actually runs from |

**The application directory is configurable, not fixed.** A source code audit confirmed the application resolves `uploads/`, `logs/`, `translations/`, and markdown content relative to its own working directory (`process.cwd()`) rather than assuming any specific path — so the installer doesn't assume one either. The very first thing `setup.ps1` does (`Resolve-DeltaAppRoot`) is prompt:

```text
Enter DELTA application directory
(Default: C:\DELTA)

>
```

Pressing Enter accepts the default; any other absolute path is accepted instead (a relative path is rejected and re-prompted). The answer is stored once, in `$Script:DeltaRuntimeRoot`, and every later phase — runtime deployment, `uploads\`/`logs\` creation and permissions, `.env` generation, dependency installation, the eventual Windows Service working directory — derives its paths from that one variable. Nothing in the installer hardcodes `C:\DELTA` as an actual path; it only ever appears as the displayed default.

`Install-DeltaRuntime` creates the chosen directory and copies `dts_shared_binary`'s contents into it directly (not into a nested `dts_shared_binary\` subfolder — the application directory itself *is* the unpacked artifact root). The Linux-only `*.sh` scripts (`init_db.sh`, `init_website.sh`, `start.sh`, `upgrade_database.sh`) are deliberately not copied — they cannot execute on Windows, and `init_db.sh`/`upgrade_database.sh` are already fully replaced by this repository's own `init_db.ps1`/`upgrade_database.ps1`. `init_website.bat`/`start.bat` are still copied and still needed: `setup.ps1` (Phase 3, [08 — Development Roadmap](08-development-roadmap.md#phase-3--yarn--dependencies)) invokes `init_website.bat` itself rather than replacing it with native PowerShell logic, and `start.bat` remains a manual, operator-run step for this validation phase (see [§Smoke test](#smoke-test)).

**No `public\` directory is created, and this is intentional, not an omission.** The archived Docker design copied `build/client/` into a separate `/data/public/` directory; the native deployment here does not reproduce that step. `react-router-serve` (the `start` script) serves compiled client assets directly out of `build\client\` — confirmed by the compiled bundle's own exported `assetsBuildDirectory = "build/client"` — and the bundle contains no `express.static()` call of its own to require anything different. See [01 — Static asset serving](01-runtime-architecture.md#static-asset-serving--no-public-directory-required) for the full evidence trail, including why this also holds for user uploads (served through an authenticated route, not a static webroot). The same source audit that identified `uploads/`/`logs/`/`translations/`/markdown content as `cwd`-relative found no requirement for a `public\` directory either.

### Runtime directory permissions and validation

Immediately after deployment, `Initialize-DeltaRuntimeDirectories` prepares `<AppRoot>\uploads` and `<AppRoot>\logs`:

1. **Create** each directory if it doesn't already exist (idempotent — a repeat run doesn't disturb one that already has real content in it).
2. **Grant Modify permission**, inherited to child files and folders, to the account actually running the installer — not a hardcoded account like `Administrator`. Phase 5 (Windows Service) doesn't exist yet, so there is no separate configured service account to target; once it does, this will grant to that account instead.
3. **Validate write access** by creating a temporary file, writing to it, reading it back, and deleting it — a real functional check, not just an ACL inspection. If any directory fails this check, the installer stops immediately with a clear error naming the specific directory, rather than letting the problem surface later at the application's first upload or log write.

Nothing in this deployment path should ever hardcode the installer repository's own location — every script resolves it via `$PSScriptRoot`. The application directory works the same way in spirit: `C:\DELTA` is only a default (`$Script:DefaultDeltaRuntimeRoot` in `lib\DeltaInstaller.Common.ps1`), never assumed to be the actual value — every script resolves the real location into its own `$Script:DeltaRuntimeRoot`, set by the prompt described above.

## Automated installer status

Steps 1–2 above are being replaced by a PowerShell installer (`setup.ps1`), built incrementally — see [08 — Development Roadmap](08-development-roadmap.md) for the full phase breakdown. As of this writing:

| Step | Automated by | Status |
|---|---|---|
| DELTA runtime artifact (`dts_shared_binary`) acquisition/update | `setup.ps1` — `Update-DeltaRuntimeArtifact` (**Phase 0**, `lib\DeltaRuntimeArtifact.ps1`) | ✅ Implemented — runs first, before every other phase. Checks the bundled artifact against the [DELTA GitHub Releases API](https://api.github.com/repos/PreventionWeb/delta/releases/latest); downloads automatically if missing, prompts (default: keep bundled) if a newer release exists, and continues on GitHub connectivity failure as long as a bundled artifact already exists. See [08 — Phase 0](08-development-roadmap.md#phase-0--delta-runtime-artifact-management). |
| Node.js 24.x installation | `setup.ps1` — `Install-NodeJs` (Phase 1) | ✅ Implemented |
| PostgreSQL server installation | `setup.ps1` — `Install-PostgreSql` (**Phase 2A**) | ✅ Implemented — detects an existing install, silently installs via the EDB installer's own unattended mode, validates the service and `psql`/`postgres` binaries. If a matching install is already running, offers to reuse it instead — see [§Reusing an existing PostgreSQL installation](#reusing-an-existing-postgresql-installation). |
| PostGIS installation | Not yet automated (**Phase 2B**, planned) | ⬜ Still manual — install via Stack Builder as described in [Prerequisites](#prerequisites) above |
| DELTA database initialization | Not yet automated (**Phase 2C**, planned) | ⬜ Still manual — continue using `init_db.bat` per [§Running the installer scripts](#running-the-installer-scripts) below |
| Application dependency installation (Yarn, `node_modules`, `dotenv-cli`) | `setup.ps1` — `Install-DeltaDependencies` (**Phase 3**) | ✅ Implemented, idempotently — skips `init_website.bat` entirely if dependencies are already present. **Not yet a from-scratch fix**: it wraps the shipped `init_website.bat` as-is rather than correcting its known gaps at the source — see [08 §Phase 3](08-development-roadmap.md#phase-3--yarn--dependencies). Also applies a permanent, idempotent `dotenv-cli` PATH fix (`Add-YarnGlobalBinToPersistentPath`) — see [§Running the installer scripts](#running-the-installer-scripts) below. |
| Application startup (`start.bat`) | Not automated — deliberate, for this validation phase | ⬜ Manual by design. `setup.ps1` ends by detecting and stopping any DELTA instance left running from a previous run, then reports the runtime is ready and tells the operator to run `start.bat` themselves. Wiring startup in is deferred to Phase 5 (Windows Service). |

Do not assume PostGIS or the DELTA database are handled by running `setup.ps1` today — only run it for Node.js and the bare PostgreSQL server, then continue the rest of this guide manually until Phases 2B and 2C land. This section will be updated as each phase completes; the authoritative status lives in [08](08-development-roadmap.md#progress-dashboard), not here.

## Reusing an existing PostgreSQL installation

When `setup.ps1` finds a PostgreSQL installation matching the required major version (16.x) with its service already running, it does not silently skip past it — it asks:

```text
An existing PostgreSQL installation was detected.

Version:      16.6
Service status: Running
Host:         localhost
Port:         5432

1) Reuse the existing PostgreSQL installation (recommended)
2) Install a new PostgreSQL instance
```

**Choosing "Reuse"** prompts for the superuser password and validates it live (a real `psql` connection, not just "typed twice consistently"). If authentication succeeds, `setup.ps1` then checks whether the configured DELTA database already exists on that instance and offers:

1. **Recreate** — drops the existing DELTA database (if present) and recreates it via `init_db.ps1`.
2. **Upgrade** — runs `upgrade_database.ps1` against the existing database, applying the self-selecting `upgrade_from_*.sql` chain (see [04 — Upgrade mechanism](04-database.md#upgrade-mechanism)).
3. **Keep** — leaves the database completely untouched.

The application directory's `.env` (`C:\DELTA\.env` by default — see [§Deployment layout](#deployment-layout)) is regenerated with the resulting `DATABASE_URL` regardless of which of the three is chosen. If the database doesn't exist yet on the reused instance, it's simply created — no menu needed.

**If authentication fails**, the installer does not abort:

```text
Authentication failed.

1) Try again
2) Reset the PostgreSQL superuser password
3) Cancel installation
```

**Resetting the password** is aimed at development/POC machines the operator already administers, not production — it warns explicitly that it changes credentials for the *existing* server (other applications using that instance may need updating too), requires confirmation, and only proceeds afterward. Mechanically, it's the standard "forgot the postgres password" recovery: a temporary trust rule is added to the top of `pg_hba.conf`, the service is restarted, the new password is set, then the original `pg_hba.conf` is restored and the service restarted again — the net effect is only the password changes, not the instance's authentication policy. This assumes the default EDB data directory layout (`<install dir>\data`); a custom data directory needs a manual reset instead.

**Choosing "Install a new instance"** (either from the initial prompt or after declining to reuse) falls through to the same unattended installation `setup.ps1` already performs for a genuinely fresh machine — nothing about the fresh-install path changes.

## Running the installer scripts

When run via `setup.ps1`, `init_website.bat` and `init_db.bat` are invoked automatically — `Install-DeltaDependencies` (Phase 3) runs `init_website.bat` only if Yarn, `node_modules`, and `dotenv-cli` aren't already all present, and `Complete-DatabaseSetup` runs `init_db.ps1` (which does what `init_db.bat` does, natively). The manual commands below are for running them standalone, outside `setup.ps1`:

```powershell
.\init_website.bat
.\init_db.bat
```

`init_website.bat` installs Yarn globally and runs `yarn install --production`. **Known gaps in this script** — missing `--force` on the Yarn install, and PATH handling that targets npm's global folder rather than Yarn Classic's own global bin (where `dotenv-cli`, needed by `start.bat`, actually lands) — are documented in [06 — Installation tooling gaps](06-deployment-risks.md#installation-tooling-gaps) and not yet fixed at the source (see [08 §Phase 3](08-development-roadmap.md#phase-3--yarn--dependencies)). Verify manually after running it standalone that a **new** shell can resolve the `dotenv` command:

```powershell
where dotenv
```

If it fails, resolve the actual install location and add it to PATH persistently:

```powershell
yarn global bin
setx PATH "%PATH%;<path printed above>"
```

**When `setup.ps1` runs `init_website.bat` itself**, it performs the equivalent of this `setx` step automatically (`Add-YarnGlobalBinToPersistentPath`): it appends Yarn's global bin directory to the *persistent User PATH* (via `[Environment]::SetEnvironmentVariable(...,'User')`, not just `$env:Path`), then refreshes the current session so `dotenv` resolves immediately without needing a new shell. This was previously a session-only workaround — confirmed during end-to-end validation to leave `dotenv` unresolvable in any new console or after a reboot — and is now a permanent, idempotent fix: a repeat run detects the directory is already on the User PATH and does nothing further.

`init_db.bat` prompts interactively for host, port, database name, and username, then runs `createdb` followed by `psql -f dts_database\dts_db_schema.sql`. It does not pass encoding/locale flags — see [06 — UTF-8 and locale](06-deployment-risks.md#utf-8-and-locale-at-database-creation) if deploying for a non-English-locale audience. Full detail on what the schema does: [04 — Database](04-database.md).

Both scripts end in `pause` and are meant to be run interactively, not from an unattended pipeline, as shipped — see [06 #2](06-deployment-risks.md#installation-tooling-gaps).

## Environment variables

Create `.env` in the application directory (`C:\DELTA` by default, or whatever was chosen at the `Resolve-DeltaAppRoot` prompt — see [§Deployment layout](#deployment-layout)). When `setup.ps1` is used, `Install-DeltaRuntime` creates that directory and the database stage generates this file automatically from `.env.example`; only `DATABASE_URL` is populated for you, so the other variables below still need to be filled in. The full variable reference (purpose, required/optional) lives in [05 — Environment variable compatibility](05-windows-compatibility-assessment.md#environment-variable-compatibility) — this section lists only what's specific to a Windows deployment:

```env
DATABASE_URL=postgresql://<user>:<password>@localhost:5432/<database>
SESSION_SECRET=<random-secret>
NODE_ENV=production
PUBLIC_URL=https://<externally-visible-host>
HOSTNAME=%COMPUTERNAME%
LOG_DIR=logs
```

- `PUBLIC_URL` must be the externally-visible `https://` address Nginx serves — not the internal Node listen address — or outbound links (e.g. in emails) will point at the wrong host.
- `HOSTNAME` is not populated automatically on Windows the way it is on Linux; set it explicitly if per-instance log correlation matters ([06 #9](06-deployment-risks.md#hostname-log-field)).
- `NODE_ENV=production` marks session cookies `Secure` — this **requires** Nginx to be terminating HTTPS in front of the app for login to persist. See [§Reverse proxy configuration](#reverse-proxy-configuration).

## Smoke test

```powershell
.\start.bat
```

Confirms the app boots and connects to PostgreSQL before wrapping it as a service. `start.bat` wraps `dotenv -e .env -- yarn start`, which runs `react-router-serve ./build/server/index.js` — a plain Node CLI invocation with no OS-conditional behavior.

**This step is always manual, even when `setup.ps1` was used for everything before it.** For this validation phase, application startup is deliberately isolated from the installer — `setup.ps1` never invokes `start.bat` itself. What it does do, at the very end of a run, is detect whether a DELTA instance from a *previous* run is still active (matched specifically to `C:\DELTA\build\server\index.js` in a process's command line — never a blanket sweep of every `node.exe`) and stop it, so re-running `setup.ps1` can't leave two instances bound to the same port. It then reports the runtime is ready and prints the exact `start.bat` path to run. This isolation is intentional, not an oversight — see [08 §Repeat-run safety](08-development-roadmap.md#phase-3--yarn--dependencies) — and is expected to change once Phase 5 (Windows Service) wires startup in properly.

## Windows Service installation

Wrap the Node process directly — do not point the service at `start.bat` itself, since its trailing `pause` will hang the service indefinitely on every start. Substitute the actual application directory for `C:\DELTA` below if a different one was chosen at install time (see [§Deployment layout](#deployment-layout)) — future automation of this step (Phase 5) will use `$Script:DeltaRuntimeRoot` directly rather than a literal path.

```powershell
nssm install DeltaApp "C:\Program Files\nodejs\node.exe" "node_modules\@react-router\serve\dist\cli.js .\build\server\index.js"
nssm set DeltaApp AppDirectory "C:\DELTA"
nssm set DeltaApp AppEnvironmentExtra DATABASE_URL=... SESSION_SECRET=... NODE_ENV=production PUBLIC_URL=...
nssm set DeltaApp AppExit Default Restart
nssm set DeltaApp AppStdout "C:\DELTA\logs\service-out.log"
nssm set DeltaApp AppStderr "C:\DELTA\logs\service-err.log"
nssm start DeltaApp
```

| Setting | Value | Why |
|---|---|---|
| Working directory | Install root | Relative `uploads`/`logs` paths resolve from here — see [01 — Statelessness](01-runtime-architecture.md#statelessness). |
| Environment | Service environment block or `.env` in the working directory | Either avoids needing `dotenv-cli` as a wrapper in production. |
| Restart strategy | `AppExit Default Restart`, with `AppThrottle` to avoid crash-loop flapping | Standard NSSM crash recovery. |
| Application-level logging | Handled by `winston-daily-rotate-file` into `LOG_DIR` regardless of service manager | Point NSSM's stdout/stderr redirection at a separate file for anything logged before Winston initializes. |
| Shutdown behavior | **Not yet empirically verified** — see [06 #5](06-deployment-risks.md#windows-service-shutdown-behavior) | Confirm during [07 — Validation checklist](07-windows-poc.md#validation-checklist) before relying on graceful shutdown in production. |

## Reverse proxy configuration

The application reads `x-forwarded-for`/`x-real-ip` headers directly and derives cookie security from `NODE_ENV` rather than `req.secure` (full detail: [05 — Reverse proxy compatibility](05-windows-compatibility-assessment.md#reverse-proxy-compatibility)) — no Express `trust proxy` setting is needed, and Nginx for Windows requires no non-standard configuration:

```nginx
server {
    listen 443 ssl;
    server_name delta.example.org;

    ssl_certificate     C:/nginx/certs/delta.crt;
    ssl_certificate_key C:/nginx/certs/delta.key;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**This step is not optional.** With `NODE_ENV=production` and no TLS-terminating front end, the browser will refuse the `Secure` session cookie and login will not persist — this is a property of the application, true on every platform, not a Windows-specific bug.

## Current limitations (as assessed)

These are carried forward from [05](05-windows-compatibility-assessment.md) and [06](06-deployment-risks.md) — listed here so this guide doesn't imply more certainty than currently exists:

- No end-to-end Windows Server deployment has been executed yet; everything above reflects static analysis plus standard platform practice, not an observed run. See [07 — Proof of Concept](07-windows-poc.md).
- The shipped `.bat` scripts have real correctness gaps (quoting, PATH, `--force`, blocking `pause`) — see [06 #2](06-deployment-risks.md#installation-tooling-gaps).
- Graceful shutdown under a Windows Service has not been confirmed to actually invoke the app's cleanup handler — see [06 #5](06-deployment-risks.md#windows-service-shutdown-behavior).
- No `yarn.lock` ships with the artifact, so installs are not currently reproducible — see [06 #1](06-deployment-risks.md#no-yarnlock).

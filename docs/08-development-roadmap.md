# Development Roadmap — Windows-Native Deployment

**Status:** Living document. Update this file as work lands — it is the team's primary tracker for this effort, not a one-time plan.
**Audience:** Engineers building the installer. This is internal engineering documentation, not an end-user guide — see [00 — Overview](00-overview.md) for the operator-facing documentation set this effort eventually feeds.
**Related:** [01 — Runtime Architecture](01-runtime-architecture.md) · [02 — Windows Deployment](02-windows-installation.md) · [05 — Compatibility Assessment](05-windows-compatibility-assessment.md) · [06 — Deployment Risks](06-deployment-risks.md) · [07 — Windows Proof of Concept](07-windows-poc.md)

---

## Overview

Windows deployment support for DELTA is being implemented **incrementally, one phase at a time**, each phase producing a working, idempotent PowerShell script that can be run standalone or chained into the next.

**Objective:** a fully automated deployment process, from a bare Windows Server 2022 machine to a running DELTA instance, covering:

- Node.js 24.x
- PostgreSQL
- PostGIS
- DELTA (`dts_shared_binary` artifact — dependencies, database, environment)
- Windows Service registration
- Nginx for Windows (reverse proxy)

**Scope note:** this roadmap tracks *deployment tooling* — scripts, installers, service configuration. It does not track DELTA application development. Findings about the application itself (what's Windows-compatible, what risks exist) live in [05](05-windows-compatibility-assessment.md) and [06](06-deployment-risks.md); this document tracks the response to those findings in installer code.

Each phase below corresponds to one function in the eventual orchestration script (see [`setup.ps1`](../setup.ps1) `# Future phases` block) — `Install-NodeJs`, `Install-PostgreSql`, `Install-PostGIS`, `Initialize-Database`, `Configure-Environment`, `Install-WindowsService`, `Validate-Deployment`, and so on.

**Deployment layout (added after Phase 2A/2B landed):** the installer repository and the running DELTA application live in two separate directories — this repository is installer code only; `Install-DeltaRuntime` deploys the `dts_shared_binary` artifact it ships with into `C:\DELTA`, a fixed runtime directory (`$Script:DeltaRuntimeRoot` in `lib\DeltaInstaller.Common.ps1`) independent of wherever this repository itself is checked out. Every later phase that touches the running application — Phase 3's dependency install, Phase 4's `.env` generation, Phase 5's Windows Service `AppDirectory` — targets `C:\DELTA`, never a path inside the installer repository. See [02 — Deployment layout](02-windows-installation.md#deployment-layout) for the full detail.

**Why PostgreSQL is split into three sub-phases (2A/2B/2C):** installing the PostgreSQL server, making PostGIS available to it, and initializing DELTA's own database are three operations with different failure modes, different idempotency rules, and different blast radii if something goes wrong partway through:

- **Phase 2A** touches only the PostgreSQL server installation itself — a Windows Service plus a set of binaries. It can be validated in complete isolation (does `psql` work, is the service running) before anything DELTA-specific exists.
- **Phase 2B** touches the extension layer. PostGIS is version-matched to the specific PostgreSQL major version from 2A, so it has its own detection/validation logic and its own failure modes (e.g., installing a PostGIS build for the wrong PostgreSQL major version).
- **Phase 2C** touches DELTA's actual data — database creation, encoding, schema import. This is the one sub-phase with real consequences if re-run carelessly against an existing installation, and it's the one that should absorb the [UTF-8/locale fix](06-deployment-risks.md#utf-8-and-locale-at-database-creation) already identified as a known risk.

Keeping these as three separate functions (rather than one large `Install-PostgreSQL`) means a failure in 2C doesn't require re-running 2A, and troubleshooting "PostgreSQL won't start" (2A) stays entirely separate from troubleshooting "the schema didn't import cleanly" (2C) — each sub-phase has one job and one set of things that can go wrong.

---

## Progress Dashboard

| Phase | Status | Notes |
|---|---|---|
| Phase 0 — DELTA Runtime Artifact Management | ✅ Completed | `lib\DeltaRuntimeArtifact.ps1`, called by `setup.ps1` before every other phase. Keeps the bundled `dts_shared_binary` current against the [DELTA GitHub Releases API](https://api.github.com/repos/PreventionWeb/delta/releases/latest) — see phase detail below. |
| Phase 1 — Node.js | ✅ Completed | `setup.ps1` implemented. Not yet executed end-to-end against a real Windows Server target — see [07 — Proof of Concept](07-windows-poc.md). |
| Phase 2A — PostgreSQL Installation | ✅ Completed | `setup.ps1` extended. Not yet executed end-to-end — see [07](07-windows-poc.md). |
| Phase 2B — PostGIS Installation | ⬜ Planned | |
| Phase 2C — Database Initialization | ⬜ Planned | Absorbs the [UTF-8/locale risk](06-deployment-risks.md#utf-8-and-locale-at-database-creation). |
| Phase 3 — Yarn & Dependencies | 🔶 In progress | Renumbered from Phase 4 when PostgreSQL split into 2A/2B/2C. Wraps `init_website.bat` idempotently rather than fixing it directly — see phase detail below. |
| Phase 4 — Environment Configuration | ⬜ Planned | Renumbered from Phase 6. |
| Phase 5 — Windows Service | ⬜ Planned | Renumbered from Phase 7. |
| Phase 6 — Validation | ⬜ Planned | Renumbered from Phase 8. |

Legend: ✅ Completed · 🔶 In progress · ⬜ Planned

---

## Phase 0 — DELTA Runtime Artifact Management

**Status:** ✅ Completed

**Objective:** ensure the `dts_shared_binary` artifact this repository ships (`$Script:DeltaRuntimeSourceDirectory` in `setup.ps1` — the *source* copy `Install-DeltaRuntime` later deploys into `C:\DELTA`, not the deployed copy itself) is the latest one available, automatically, before any other phase runs — rather than leaving the operator to notice a stale bundled artifact after the fact.

**Dependencies:** None — runs first, before `Resolve-DeltaAppRoot`, and reads none of that phase's or any later phase's state. Deliberately independent of the rest of the installer (see `lib\DeltaRuntimeArtifact.ps1`'s own header): it takes the runtime directory and project root as parameters rather than script-scoped state, and no other phase depends on anything it defines.

**Deliverables:**

- `lib\DeltaRuntimeArtifact.ps1` — a separate, self-contained dot-sourced file (alongside `lib\DeltaInstaller.Common.ps1`), with a single entry point, `Update-DeltaRuntimeArtifact`
- `Get-DeltaLatestReleaseInfo` — queries the [GitHub Releases API](https://api.github.com/repos/PreventionWeb/delta/releases/latest) (never the HTML releases page), locates the `dts_binary.zip` asset by exact filename match (never array position), and reads its published SHA-256 digest
- `Expand-DeltaRuntimeArtifact` — extracts into a private `%TEMP%` staging directory first, validates `package.json` is present, and only then removes/replaces the existing runtime — see [Safe replacement](#safe-replacement-phase-0) below
- Three handled scenarios: no bundled artifact (download automatically, no prompt), bundled artifact already latest (report, continue), newer release available (prompt — default keeps the bundled runtime)

**Checklist:**

- [x] Read the local version from `dts_shared_binary\package.json`
- [x] Query the GitHub Releases API and normalize `tag_name` for comparison
- [x] Locate the runtime asset by filename, not position
- [x] Download to a `.download` staging name, verify SHA-256 before ever renaming/extracting it
- [x] Never remove the existing runtime until a replacement has been fully downloaded, verified, and extracted
- [x] Degrade to "keep the bundled runtime" on GitHub connectivity failure, missing asset, or SHA-256 mismatch — but only when a bundled runtime actually exists to fall back to; abort otherwise
- [x] Verified end-to-end against the real `PreventionWeb/delta` repository (fresh install, replace, digest-mismatch fallback and abort, missing-asset fallback, up-to-date, GitHub-unreachable fallback and abort)

**Implementation notes:**

- **No PAT required.** The repository is public; only a `User-Agent` header is sent (GitHub's API rejects anonymous requests without one).
- **Digest source.** Verified against the `digest` field the Releases API publishes per-asset (`sha256:<64 hex chars>`), not a separately-fetched checksum file the way [PostGIS's installer integrity check](#phase-2b--postgis-installation) works — the API already provides one directly.
- **No installer cache.** Unlike Node/PostgreSQL/PostGIS (`$Script:InstallersDirectory` in `setup.ps1`), the downloaded zip is always deleted after a successful extraction — this artifact is meant to always reflect "latest," not to be reused across runs the way a pinned installer version is.
- <a id="safe-replacement-phase-0"></a>**Safe replacement.** `Expand-Archive` cannot itself guarantee "never touch the destination until the source is known good," so extraction always targets a fresh staging directory under `%TEMP%` first; the existing `dts_shared_binary` is only ever removed after staging is confirmed to contain a readable `package.json`. A failed download, a failed SHA-256 check, or a failed extraction therefore all leave a pre-existing bundled runtime completely untouched.

---

## Phase 1 — Node.js Installation

**Status:** ✅ Completed

**Objective:** Automate installation and validation of Node.js v24.18.0 and npm, idempotently.

**Dependencies:** None — first phase.

**Deliverables:**

- [`setup.ps1`](../setup.ps1)
- `Find-NodeExecutable` — version detection independent of PATH (registry + well-known install paths as fallback)
- `Install-NodeMsi` — silent MSI installation via `msiexec /qn /norestart`
- Post-install validation (`node -v`, `npm -v`)
- Installer cleanup

**Checklist:**

- [x] Detect existing Node.js installation (PATH → registry → well-known paths, in that order)
- [x] Exact-version match short-circuits the whole phase (no download, no install)
- [x] Download official MSI (`Invoke-WebRequest`, TLS 1.2 forced, temp working directory — never a hardcoded path)
- [x] Silent installation (`msiexec /qn /norestart`, admin-rights check before attempting)
- [x] Validate installation (exact version match + npm presence, re-resolved via a refreshed session PATH)
- [x] Cleanup installer (MSI deleted after successful validation; install log kept for audit)
- [x] Handle reboot-required exit code (3010) — treated as success, logged as a note, does not block the phase
- [ ] Automated upgrade path testing (installed version ≠ required version → reinstall) — implemented, not yet exercised against a real prior install
- [ ] Verify downloaded MSI integrity (SHA256 against Node.js's published `SHASUMS256.txt`) before executing it
- [ ] End-to-end run against a real Windows Server 2022 target (tracked in [07](07-windows-poc.md), not duplicated here)

**Implementation notes:**

- `Stop-Setup` + a single top-level `try/catch` own all error formatting and the process exit code — no function calls `exit` directly, which matters once this becomes one call among several in the full orchestration sequence.
- Elevation is checked lazily, only when an install is actually about to happen — a non-admin operator can still run the script when Node.js is already correct.

---

## Phase 2A — PostgreSQL Installation

**Status:** ✅ Completed

**Objective:** Automate installation and validation of the PostgreSQL *server* only — service running, `psql`/`postgres` binaries present, correct major version. Nothing about PostGIS or DELTA's own database happens in this sub-phase; see [Phase 2B](#phase-2b--postgis-installation) and [Phase 2C](#phase-2c--database-initialization).

**Dependencies:** None — independent of Phase 1, developed in parallel.

**Deliverables:**

- `setup.ps1` extended with an `Install-PostgreSql` function
- `Find-PostgresInstallation` — multi-signal detection (PATH → well-known install roots → Windows service name pattern), matching the approach established for Node.js in Phase 1
- `Install-PostgresServer` — unattended install via the EDB installer's own `--mode unattended` support (**not** msiexec — the EDB installer is a BitRock/InstallBuilder executable, a different technology from Node's MSI)
- Secure, interactive superuser password prompt (never hardcoded, never defaulted)
- Post-install validation (service running, `psql`/`postgres.exe` present, major version match)
- **Existing-installation reuse UX** — when a matching, running instance is already present, `Read-ExistingPostgresChoice` offers reuse (recommended) instead of always installing fresh; `Resolve-ExistingPostgresCredentials` validates the supplied superuser password live (`Test-PostgresCredentials`) rather than assuming it, with retry/reset/cancel on an authentication failure. `Reset-PostgresSuperuserPassword` (`lib\DeltaInstaller.Common.ps1`) covers the "forgot the password" recovery path via a temporary `pg_hba.conf` trust rule — aimed at dev/POC machines the operator already administers, gated on the same admin check as every other install action in this script. See [02 §Reusing an existing PostgreSQL installation](02-windows-installation.md#reusing-an-existing-postgresql-installation) for the operator-facing walkthrough.

**Checklist:**

- [x] Detect existing PostgreSQL installation (PATH → well-known `Program Files\PostgreSQL\*` roots → `Get-Service postgresql*`, in that order)
- [x] Major-version match short-circuits the phase (any 16.x installed satisfies "16 required" — see implementation notes below for why this differs from Node's exact-version rule)
- [x] Download official installer (`Invoke-WebRequest`, TLS 1.2 forced, same temp working directory as Phase 1)
- [x] Silent installation (`--mode unattended --unattendedmodeui none`, only officially-documented EDB flags — see the research summary below)
- [x] Secure superuser password prompt (`Read-Host -AsSecureString`, entered twice and compared) — the installer's own documented default (`enterprisedb`) is never allowed to apply
- [x] Validate installation (service exists and is `Running`, `psql.exe` and `postgres.exe` both present, major version matches)
- [x] Cleanup installer (deleted only after full validation passes; install log kept)
- [x] Reuse an existing, already-running PostgreSQL installation instead of forcing a fresh install, with live credential validation and a guided recovery path (retry/reset/cancel) on authentication failure
- [ ] Automated re-run testing against a machine with a *different* major version already installed (implemented as "install alongside," not exercised)
- [ ] Verify downloaded installer integrity (EDB does not publish per-file checksums the way Node.js does — see risk register)
- [ ] End-to-end run against a real Windows Server 2022 target (tracked in [07](07-windows-poc.md), not duplicated here)

**Research summary — EDB PostgreSQL Windows installer (verified before writing any code):**

| Question | Finding | Confidence |
|---|---|---|
| Is unattended installation officially supported? | Yes — `--mode unattended --unattendedmodeui none`, documented at [enterprisedb.com/docs](https://www.enterprisedb.com/docs/supported-open-source/postgresql/installing/command_line_parameters/) | Verified (official docs) |
| Installer technology | BitRock/VMware InstallBuilder `.exe` — not MSI. `msiexec` flags/conventions from Phase 1 do not apply. | Verified |
| Documented parameters used | `--mode`, `--unattendedmodeui`, `--prefix`, `--datadir`, `--serverport`, `--servicename`, `--superaccount`, `--superpassword`, `--enable-components`, `--debugtrace` — every flag in `Install-PostgresServer` traces to this table | Verified (official docs) |
| Default superuser password if `--superpassword` omitted | Literal string `enterprisedb` — EDB's own docs warn this is guessable | Verified (official docs) — this is why the script *always* prompts and never lets this default apply |
| Exit code meaning | Only `0 = success` is documented anywhere. No table of non-zero codes, no documented reboot-required code (unlike msiexec's `3010`). | Verified absence — confirmed by checking EDB's docs and their own GitHub issue tracker, not just an oversight in this research |
| Stable direct-download URL | **Not officially published.** The real download page (`enterprisedb.com/downloads/...`) routes through opaque `sbp.enterprisedb.com/getfile.jsp?fileid=NNNNNN` redirects with no discoverable version→fileid mapping. The `get.enterprisedb.com/postgresql/postgresql-{version}-{build}-windows-x64.exe` pattern is community-known, not an EDB-guaranteed contract — it was confirmed to currently resolve (`HTTP 200`, correct content-type, ~349 MB) by direct request before being used here. | Verified by direct request, not officially guaranteed — tracked as a risk, see [06](06-deployment-risks.md) |
| Password exposure | `--superpassword` is passed as a plaintext command-line argument, visible to other processes for the life of the installer process — an inherent property of this installer's design, not something a wrapper script can fully close | Verified (general Windows process-visibility behavior) |

**Implementation notes:**

- **Major-version matching, not exact-version matching.** Unlike Node.js (Phase 1), where an unpinned application version made exact-pin-and-match the safer default, DELTA's schema is minor-version-tolerant within PostgreSQL 16.x (see [04 — Database](04-database.md)). Requiring an exact patch match here would force reinstalls on every routine PostgreSQL security update for no compatibility benefit — so detection succeeds on any 16.x.
- Installing a *different* major version does not attempt an in-place upgrade or removal — PostgreSQL major versions are designed to install side by side. The script installs the required major version alongside whatever else is present rather than claiming to "update" an installation it isn't actually touching.
- `Install-PostgresServer` reuses `Test-IsAdministrator` and `Update-SessionEnvironmentPath` from Phase 1 rather than duplicating them.
- Component selection is `--enable-components server,commandlinetools` — pgAdmin and Stack Builder are explicitly excluded, since neither is needed for an unattended service deployment.

---

## Phase 2B — PostGIS Installation

**Status:** ⬜ Planned

**Objective:** Ensure the PostgreSQL instance from Phase 2A has PostGIS available. See [04 — Why PostGIS is mandatory](04-database.md#why-postgis-is-mandatory) and [06 — PostGIS installation](06-deployment-risks.md#postgis-installation) for why this can't be skipped or deferred.

**Dependencies:** Phase 2A (a PostgreSQL instance must exist first).

**Expected output:** `Install-PostGIS` function; `CREATE EXTENSION postgis` succeeds against a scratch database on the target instance afterward.

**Work items:**

- [ ] Detect whether PostGIS is already available to the target instance (`SELECT postgis_version();` against a scratch DB, or check Stack Builder's installed-components registry)
- [ ] Automate installation where possible — Stack Builder is GUI-first; evaluate its silent/CLI install support, or use the standalone PostGIS bundle installer as a fallback. Do not assume a `--mode unattended` flag exists for it without verifying against its own documentation, the same way this was verified for Phase 2A.
- [ ] Verify extension availability post-install (not just "installer exited 0")
- [ ] Compatibility check against the PostgreSQL major version installed in Phase 2A (PostGIS releases are version-matched to specific PostgreSQL major versions)

**Checklist:**

- [ ] Detect extension availability
- [ ] Automate installation
- [ ] Verify extension
- [ ] Compatibility checks against the PostgreSQL version from Phase 2A

---

## Phase 2C — Database Initialization

**Status:** ⬜ Planned

**Objective:** Automate what `init_db.bat`/`upgrade_database.bat` currently do interactively — see [04 — Database](04-database.md) for the schema/upgrade mechanics this phase is scripting. This is the sub-phase that actually creates DELTA's database and touches real data; keep it isolated from 2A/2B so it can be re-run or troubleshot without re-touching the server or extension install.

**Dependencies:** Phase 2A and 2B (PostgreSQL + PostGIS must both be ready); Phase 4 for `DATABASE_URL` if credentials are generated there rather than here.

**Expected output:** `Initialize-Database` function; a schema-loaded, correctly versioned database ready for the application to connect to.

**Work items:**

- [ ] Database creation (`createdb` equivalent, parameterized instead of interactive prompts)
- [ ] **Pass `-E UTF8 --locale=<target>` explicitly** — this is where [06 — UTF-8 and locale](06-deployment-risks.md#utf-8-and-locale-at-database-creation) gets closed in script form, not just documented
- [ ] Extension verification (PostGIS + pgcrypto actually registered in the new database, not assumed from 2A/2B succeeding)
- [ ] Schema import (`dts_db_schema.sql`)
- [ ] Upgrade path (script the `upgrade_database.sql` self-selecting chain non-interactively; validate the multi-version-behind cascading-`\if` behavior noted as unverified in [04](04-database.md#upgrade-mechanism))
- [ ] Validation (`dts_system_info.version_no` matches the artifact's `package.json` version after init)

**Checklist:**

- [ ] Database creation
- [ ] Verify UTF-8 (encoding/locale passed explicitly, not inherited from cluster default)
- [ ] Create extensions (verified, not assumed)
- [ ] Import schema
- [ ] Future upgrade path (non-interactive)
- [ ] Validation

---

## Phase 3 — Yarn & Dependencies

**Status:** 🔶 In progress

**Objective:** Install the DELTA artifact's Node dependencies reliably — this is where the gaps identified in [05](05-windows-compatibility-assessment.md#existing-windows-tooling) and [06 — Installation tooling gaps](06-deployment-risks.md#installation-tooling-gaps) get fixed in script form, not just documented.

**Dependencies:** Phase 1 (Node.js must be installed); runs after `Install-DeltaRuntime` has deployed `dts_shared_binary` into `C:\DELTA`, since `init_website.bat` has to run with `C:\DELTA` as its working directory.

**Expected output:** `Install-DeltaDependencies` function; a working `node_modules/` and a resolvable `dotenv` command in the current session.

**What's actually implemented (validation-phase approach, not the original plan):** `Install-DeltaDependencies` currently **wraps and invokes `init_website.bat` unmodified** rather than porting corrected logic into PowerShell — this was a deliberate, explicit choice during first-round Windows validation to unblock the fresh-install/repeat-install flow now, with the `.bat` file's own known gaps (missing `--force`, no lockfile check) still open. Two things it does add:

- **Idempotency** (`Test-DeltaRuntimeDependenciesInstalled`): checks Yarn is resolvable, `C:\DELTA\node_modules` exists and is non-empty, and dotenv-cli is present in Yarn's own global bin (`yarn global bin`, resolved via `Get-YarnGlobalBinDirectory`) — only runs `init_website.bat` when one of those isn't already true, so a repeat `setup.ps1` run doesn't reinstall every time.
- **The dotenv-cli PATH fix** (`Add-YarnGlobalBinToPersistentPath`): confirmed during Windows validation that dotenv-cli lands in Yarn Classic's own global bin, not npm's (the latter is already on PATH via Node's own installer) — nothing else puts Yarn's global bin on PATH, so `start.bat`'s `dotenv -e .env -- yarn start` failed to resolve `dotenv` not just in a fresh session but in *any* session after the one that ran `init_website.bat`, including after a reboot. A first version of this function only updated the current process's `$env:Path`, which is exactly why that gap survived past the run that installed dotenv-cli — confirmed by a full end-to-end validation pass that reproduced `start.bat` failing in a brand-new console even though `yarn global list` showed `dotenv-cli` genuinely installed. The fix now appends Yarn's global bin directory to the persistent *User* PATH (`[Environment]::SetEnvironmentVariable(...,'User')`, not just `$env:Path`) — idempotently, skipping the write entirely if the directory is already present — then refreshes the current session via `Update-SessionEnvironmentPath` so this run doesn't need a new shell either.

**Work items still open:**

- [ ] Port corrected Yarn-install logic into PowerShell (or patch `init_website.bat` directly) instead of invoking it as-is — close the `--force` gap at the source, per [06](06-deployment-risks.md#installation-tooling-gaps), rather than working around it from `setup.ps1`. The PATH-handling half of that same gap is now mitigated from `setup.ps1` (`Add-YarnGlobalBinToPersistentPath`, permanent and idempotent — see above) without needing `init_website.bat` itself touched, so it's no longer blocking; `init_website.bat` still has the underlying gap if ever run standalone.
- [ ] Lockfile verification — fail loudly and early if `yarn.lock` is absent (see [06 #1](06-deployment-risks.md#no-yarnlock)) rather than silently doing an unpinned install
- [ ] Dependency validation beyond existence checks (spot-check that the app's own entry point actually resolves, not just that `node_modules`/dotenv-cli are present)

**Checklist:**

- [x] Dependency installation (via `init_website.bat`, idempotent)
- [ ] Lockfile verification (fail-fast if missing, until [06 #1](06-deployment-risks.md#no-yarnlock) is closed at the artifact level)
- [x] Production installation
- [ ] Dependency validation (beyond presence checks)

**Repeat-run safety — DELTA process detection (added alongside this phase):** `setup.ps1` now also ends with `Confirm-DeltaRuntimeNotRunning`, which detects a DELTA server process left over from a previous run (matched by `build\server\index.js` appearing in a `node.exe` process's own command line, scoped to `C:\DELTA` specifically — never a blanket `node.exe` sweep) and stops it, attempting a graceful `taskkill` before escalating to a forceful one. This exists purely so a repeat `setup.ps1` run can't leave two instances bound to the same port; it does **not** start the application back up — `start.bat` remains a manual, operator-run step for this validation phase (see [02 §Running the application](02-windows-installation.md#smoke-test)), deliberately isolated from everything `setup.ps1` itself does.

---

## Phase 4 — Environment Configuration

**Status:** ⬜ Planned

**Objective:** Generate a correct `.env` for the target deployment instead of relying on manual editing — full variable reference already documented in [05 — Environment variable compatibility](05-windows-compatibility-assessment.md#environment-variable-compatibility).

**Dependencies:** Phases 2A/2B/2C (needs the resolved `DATABASE_URL`); ideally runs before Phase 5 (the service needs a valid `.env` or environment block to start against).

**Expected output:** `Configure-Environment` function; a `.env` file (or service environment block, if `.env` is dropped in favor of that — decide here) containing every required variable.

**Work items:**

- [ ] `.env` generation from a template + collected values (`DATABASE_URL`, `PUBLIC_URL`, `NODE_ENV=production`, `HOSTNAME`, etc.)
- [ ] Secret generation for `SESSION_SECRET` (cryptographically random, not a placeholder left for the operator to forget to change) — reuse the `SecureString` handling pattern established in Phase 2A rather than reinventing it
- [ ] Validation — confirm required variables are non-empty and well-formed (e.g. `PUBLIC_URL` is a valid `https://` URL) before Phase 5 starts the service against them
- [ ] Configuration verification against the application's own startup checks, if any are observable (the app performs internal config validation on boot — confirm zero errors, not just that the process stays alive)

**Checklist:**

- [ ] `.env` generation
- [ ] Secret generation/handling
- [ ] Validation
- [ ] Configuration verification

---

## Phase 5 — Windows Service

**Status:** ⬜ Planned

**Objective:** Run the DELTA Node process as a supervised Windows Service — see [02 — Windows Service installation](02-windows-installation.md#windows-service-installation) for the manual reference procedure this phase automates, and [06 — Windows Service shutdown behavior](06-deployment-risks.md#windows-service-shutdown-behavior) for the one open risk this phase must specifically resolve, not just wrap.

**Dependencies:** Phases 1, 2C, 3, 4 (Node.js, the database, dependencies, and environment must all be ready before the service can start successfully).

**Expected output:** `Install-WindowsService` function; a running Windows Service that survives a reboot and restarts on crash.

**Work items:**

- [ ] NSSM vs. WinSW evaluation — pick one as the standard, document why (a versioned service definition file favors WinSW; simpler single-instance setups favor NSSM)
- [ ] Service registration (wrap `node.exe` directly, per [02](02-windows-installation.md#windows-service-installation) — never `start.bat`, whose trailing `pause` would hang the service on every start)
- [ ] Automatic restart on crash, with a bounded retry/throttle policy
- [ ] Logging — application-level logging is already handled by Winston regardless of service wrapper; this item is specifically about stdout/stderr capture for anything logged before Winston initializes
- [ ] **Graceful shutdown validation** — empirically confirm the app's `SIGTERM`/`SIGINT` cleanup handler (`build/server/index.js:57586-57594`) actually fires when the service is stopped. This is currently an open, Inferred-not-Verified risk ([06 #5](06-deployment-risks.md#windows-service-shutdown-behavior)) and this phase is where it gets closed one way or the other — do not mark this checklist item done on "the service starts and stops," only on "the log shows the cleanup handler ran."

**Checklist:**

- [ ] NSSM or WinSW evaluation (decision recorded here once made)
- [ ] Service registration
- [ ] Automatic restart
- [ ] Logging
- [ ] Graceful shutdown validation

---

## Phase 6 — Validation

**Status:** ⬜ Planned

**Objective:** A final, scripted end-to-end check that a deployment produced by Phases 1–5 actually works — not a new set of checks invented here, but automation of the same checklist already defined in [07 — Proof of Concept § Validation checklist](07-windows-poc.md#validation-checklist). Do not duplicate that table here; extend it there if new checks are needed.

**Dependencies:** All prior phases.

**Expected output:** `Validate-Deployment` function; a pass/fail report against each item below, with the real underlying error surfaced on failure rather than a generic message.

**Work items (mirrors [07](07-windows-poc.md#validation-checklist), scripted):**

- [ ] Application starts and stays running
- [ ] Database connectivity confirmed
- [ ] PostGIS available (`SELECT postgis_version();` succeeds from the app's own connection, not just `psql`)
- [ ] Uploads round-trip (write + read back through the app, not just filesystem permissions)
- [ ] Authentication flow works (login persists across a reload — the `secure-cookie-https` check)
- [ ] HTTPS termination confirmed at the reverse proxy
- [ ] Reverse proxy header forwarding confirmed (`X-Forwarded-For`/`X-Forwarded-Proto` reaching the app correctly)
- [ ] Logging confirmed (log directory populated, rotation configured)
- [ ] Health check (basic HTTP reachability probe, suitable for wiring into monitoring later)

**Checklist:**

- [ ] Application starts
- [ ] Database connectivity
- [ ] PostGIS available
- [ ] Uploads
- [ ] Authentication
- [ ] HTTPS
- [ ] Reverse proxy
- [ ] Logging
- [ ] Health check

---

## Future Enhancements

Explicitly out of scope for the first working implementation (Phases 1–6, with PostgreSQL's 2A/2B/2C above). Listed so they aren't forgotten, not because they're expected next:

- [ ] Unattended/fully non-interactive installation mode (no console prompts anywhere in the chain — Phase 2A's superuser password prompt is deliberately interactive-only for now; see [06](06-deployment-risks.md) for why a non-interactive credential path needs its own security review before it's added)
- [ ] Offline installer (bundled installers/packages, no internet access required at install time)
- [ ] Automatic PostGIS download (Phase 2B may end up manual/semi-automated only, depending on what Stack Builder's CLI support turns out to be — see Phase 2B work items)
- [ ] A resolvable, EDB-guaranteed PostgreSQL download URL — not attainable by this project (EDB doesn't publish one), but worth periodically re-checking whether that changes
- [ ] Upgrade automation (re-running the full chain safely against an already-deployed instance)
- [ ] Rollback support
- [ ] Structured installer logging (a single consolidated log across all phases, not per-phase log files)
- [ ] Interactive configuration wizard
- [ ] GUI installer

Do not begin implementing any of the above until Phases 1–6 are complete and have real operational experience behind them — consistent with this project's general preference for letting actual usage drive scope rather than designing ahead of it.

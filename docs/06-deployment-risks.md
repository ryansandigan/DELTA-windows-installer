# Deployment Risks

**Status:** Risk register. Each item traces to a Verified or Inferred finding in [05](05-windows-compatibility-assessment.md); this document adds severity and mitigation, which [05](05-windows-compatibility-assessment.md) deliberately does not.
**Related:** [02 — Windows Deployment](02-windows-installation.md) · [04 — Database](04-database.md) · [08 — Development Roadmap](08-development-roadmap.md)

---

| # | Risk | Severity | Platform | Mitigation |
|---|---|---|---|---|
| 1 | [No `yarn.lock` ships with the artifact](#no-yarnlock) | High | Both | Generate a lockfile on the target Node version and commit it to the release artifact before deployment. |
| 2 | [Installation tooling gaps in `.bat` scripts](#installation-tooling-gaps) | Medium | Windows | Patch quoting, `--force`, and PATH handling; strip or gate `pause` for automated use. See below. |
| 3 | [PATH handling for Yarn's global bin](#installation-tooling-gaps) | Medium | Windows | ✅ Mitigated at the installer level: `setup.ps1`'s `Add-YarnGlobalBinToPersistentPath` (Phase 3) resolves `yarn global bin` and appends it to the persistent User PATH. `init_website.bat` itself is unmodified and still has the underlying gap — see below. |
| 4 | [UTF-8 and locale at database creation](#utf-8-and-locale-at-database-creation) | Medium | Both | Pass `-E UTF8 --locale=<target>` explicitly to `createdb`. |
| 5 | [Windows Service shutdown may bypass graceful cleanup](#windows-service-shutdown-behavior) | Medium | Windows | Verify the shutdown path empirically; keep the service console-attached unless a headless config is confirmed to still deliver the signal. |
| 6 | [PostGIS is a manual prerequisite, not auto-installed](#postgis-installation) | Medium | Both | Document/script the PostGIS install step explicitly; nothing in `init_db` verifies it beforehand. |
| 7 | [No reproducible build — `node_modules` absent](#no-reproducible-build) | Medium | Both | Downstream of Risk 1; resolved together. |
| 8 | [`scripts/build_binary.*` referenced but not shipped](#referenced-but-missing-build-tooling) | Low | Both | Non-blocking for the documented install/run path; note it if source rebuild is ever attempted from this artifact. |
| 9 | [`HOSTNAME` not populated on Windows](#hostname-log-field) | Low | Windows | Set `HOSTNAME` explicitly in the service environment if log correlation by host matters. |
| 10 | [Node.js version unpinned](#node-version-unpinned) | Low | Both | Add an `engines.node` field once a specific Node 24.x build has been validated against this artifact. |
| 11 | [EDB installer has no stable, guaranteed download URL](#edb-installer-has-no-stable-download-url) | Medium | Windows | Verify the URL against the current EDB downloads page before each release of `setup.ps1`; fail loudly and point to the manual page on download failure. |
| 12 | [EDB installer defaults to a known superuser password if unspecified](#edb-installer-default-superuser-password) | High | Windows | Never invoke the installer without an explicit `--superpassword`; always prompt interactively, never hardcode or silently default. |
| 13 | [EDB installer exit codes are undocumented beyond `0`](#edb-installer-exit-codes-are-undocumented) | Low | Windows | Treat any non-zero exit code as failure; validate actual post-install state (service, binaries, version) rather than trusting exit-code semantics. |
| 14 | [PostgreSQL superuser password is exposed via process command line](#postgresql-superuser-password-process-exposure) | Medium | Windows | Documented, accepted limitation of the installer's design; revisit if EDB's `--optionfile` mechanism is verified as a safer alternative. |
| 15 | [Yarn Classic's 30-second default network timeout](#yarn-network-timeout) | Medium | Both | ✅ Mitigated at the installer level (Windows): `setup.ps1`'s `Invoke-DeltaWebsiteInit` (Phase 3) sets `YARN_NETWORK_TIMEOUT=300000` for the duration of the `init_website.bat` call only. `init_website.bat`/`.sh` are unmodified; a standalone or Linux run still has the underlying gap — see below. |

---

## No `yarn.lock`

**Verified**, see [05](05-windows-compatibility-assessment.md#nodejs--packages). Without a committed lockfile, `yarn install` resolves fresh semver ranges from `package.json` at install time — two installs weeks apart can silently pull different transitive dependency versions. This directly conflicts with the "idempotent installation steps" expectation for this project. It is also the same general area (Yarn dependency resolution) implicated in a previously logged Docker-build install failure on this project — that failure was in a source rebuild using devDependencies (vite/vitest), not this pre-built artifact's production install path, but it's reason enough to pin explicitly rather than assume a fresh resolve behaves identically twice.

**Mitigation:** generate `yarn.lock` on a clean install using the exact Node.js version targeted for production, and ship it as part of the release artifact going forward.

## Installation tooling gaps

**Verified**, see [05](05-windows-compatibility-assessment.md#existing-windows-tooling). Four distinct, concrete gaps in the shipped `.bat` scripts relative to their `.sh` counterparts:

| Gap | File | Fix |
|---|---|---|
| Blocking `pause` on every path, including errors | all four `.bat` files | Remove, or gate behind an interactive-only flag, before any script is called from an automated installer. |
| Unquoted `%DB_HOST%`/`%DB_PORT%`/`%PGUSERNAME%` | `init_db.bat`, `upgrade_database.bat` | Quote every interpolated variable, matching the `.sh` versions. |
| Missing `--force` on `npm install --global yarn` | `init_website.bat` | Add `--force` to match `init_website.sh`'s behavior against a stale prior install. |
| PATH fix targets npm's global folder, not Yarn's | `init_website.bat` | Resolve `yarn global bin` after installing Yarn, and add that specific path — not `%USERPROFILE%\AppData\Roaming\npm` — to PATH persistently (e.g. via `setx`). **Mitigated outside the script** — see below. |

None of these block a human operator running the scripts interactively and correctly, which is how `README.md` documents them being used today. They become blocking the moment any part of installation is expected to run unattended.

**The PATH-handling gap (row 4) is mitigated at the `setup.ps1` level, not by patching `init_website.bat`.** `Add-YarnGlobalBinToPersistentPath` (Phase 3, see [08 §Phase 3](08-development-roadmap.md#phase-3--yarn--dependencies)) runs after `init_website.bat` regardless of whether that run actually invoked it, resolves `yarn global bin` itself, and appends it to the persistent User PATH (`[Environment]::SetEnvironmentVariable(...,'User')`) if not already present — the exact `setx`-equivalent fix this row originally called for — then refreshes the current session's PATH so `dotenv` resolves immediately. This closes the end-user-visible symptom (`start.bat` failing with `'dotenv' is not recognized...` in a new console or after a reboot) without touching `init_website.bat` itself, which still has the underlying gap if run standalone (see [02 — Running the installer scripts](02-windows-installation.md#running-the-installer-scripts)).

## Yarn network timeout

**Verified**, reproduced by a tester during Windows validation and confirmed against the installed Yarn Classic 1.22.22 bundle. `yarn install` failed part-way through dependency fetching with:

```
error Error: https://registry.yarnpkg.com/drizzle-orm/-/drizzle-orm-0.45.2.tgz: ESOCKETTIMEDOUT
```

This is not an installer timeout — `Invoke-DeltaWebsiteInit` runs `init_website.bat` under `Start-Process -Wait`, with no time limit of its own. It is Yarn's own TCP socket timeout, which **defaults to 30 seconds** (`NETWORK_TIMEOUT = 30 * 1000` in Yarn's bundle). Yarn does classify `ESOCKETTIMEDOUT` as a retryable "possible offline" error, but each retry re-uses the same 30-second ceiling, so retrying does not rescue a consistently slow or throttled link — only raising the ceiling does.

Both registry-fetching commands in `init_website.bat` are exposed to this, not just one:

| Line | Command | Governed by |
|---|---|---|
| 15 | `CALL npm install --global yarn` | npm's `fetch-timeout` (defaults to 300 s — not the failure seen here) |
| 34 | `CALL yarn install --production` | Yarn `network-timeout` (defaults to **30 s**) |
| 43 | `CALL yarn global add dotenv-cli` | Yarn `network-timeout` (defaults to **30 s**) |

Row 43 matters as much as row 34: `dotenv-cli` is what `start.bat` depends on (`dotenv -e .env -- yarn start`), so a timeout there breaks startup rather than dependency installation.

**Mitigated at the `setup.ps1` level, not by patching `init_website.bat`.** `Invoke-DeltaWebsiteInit` (Phase 3) sets `$env:YARN_NETWORK_TIMEOUT = '300000'` immediately before invoking the script and restores the previous value (normally: removes the variable) in a `finally` block, so it applies to that one call and does not leak into the DELTA runtime the installer later starts. Yarn Classic merges any `YARN_*` environment variable into its own configuration — `BaseRegistry.mergeEnv('yarn_')`, which strips the prefix and maps `_` to `-` — so `YARN_NETWORK_TIMEOUT` resolves as the `network-timeout` option that `RequestManager` uses for its socket timeout. Verified directly against 1.22.22: `yarn config get network-timeout` reports `undefined` normally and `300000` with the variable set.

Because Yarn builds this configuration the same way for every subcommand, one environment variable covers both `yarn install --production` and `yarn global add dotenv-cli` — which a per-command edit to the `.bat` file would not, and which is the main reason this was chosen over rewriting the script or running a patched temporary copy of it. An explicit `--network-timeout` flag would still take precedence if `init_website.bat` ever grows one, which is the correct ordering. The value is a ceiling on an *idle socket*, not on total install duration, so a healthy network never reaches it; the only cost is that a genuinely dead connection takes 5 minutes to surface instead of 30 seconds.

**Residual risk:** `init_website.sh` on Linux, and either script run standalone outside `setup.ps1`, still use Yarn's 30-second default. Committing `yarn.lock` (Risk 1) reduces exposure by removing the resolution round-trips, but does not remove the tarball fetches themselves.

## UTF-8 and locale at database creation

**Inferred**, full detail in [04 — Database](04-database.md#utf-8-and-locale). Neither `createdb` invocation passes `-E UTF8`/`--locale`, so the new database silently inherits the PostgreSQL cluster's default. Given DELTA ships Arabic, Chinese, Russian, and Serbian locale files, a non-UTF8 cluster default is a real risk, not a theoretical one — and Windows PostgreSQL installers can default `initdb`'s locale to the host OS locale rather than a UTF8-guaranteed default some Linux distro packages use.

**Mitigation:** update `init_db.sh`/`init_db.bat` to pass `-E UTF8 --locale=<target-locale>` explicitly, on both platforms.

## Windows Service shutdown behavior

**RESOLVED — verified empirically.** This was previously *Inferred*: the concern was that the app's `SIGTERM`/`SIGINT` cleanup handler might not fire under a headless service wrapper, since Windows has no native SIGTERM and a stop can fall through to a hard `TerminateProcess`.

**What was actually observed**, against WinSW 2.12.0 running `node.exe` directly under the same configuration the installer now generates:

- Stopping the service delivers a console CTRL+C, which Node surfaces as **`SIGINT`**. A dedicated signal-probe service recorded `SIGINT received` → `cleanup ran` → `exit handler ran code=0`.
- Running DELTA itself under the service, WinSW logged `Process <pid> canceled with code 0` on a graceful stop. Exit code 0 is only reachable through the application's own `process.exit(0)` inside that handler — a `TerminateProcess` kill does not produce it.
- The handler closes all cached Winston loggers plus `winston.loggers.close()` (and remote transports when `ENABLE_REMOTE_LOGGING` is set), so log flushing does occur on stop.
- No orphaned `node.exe` remained after any stop, and the configured port was released.

The service is therefore configured with a 30-second `<stoptimeout>` as the ceiling before WinSW would escalate — in practice the process exits in milliseconds.

**Residual risk:** a stop that exceeds `<stoptimeout>` still escalates to a forced termination, as it must. That is the intended safety valve, not a defect.

## PostGIS installation

**Verified**, see [04 — Database](04-database.md#why-postgis-is-mandatory). `CREATE EXTENSION IF NOT EXISTS postgis` only registers an already-installed extension — it does not install PostGIS itself. Neither `init_db.sh` nor `init_db.bat` checks for its presence before running; a missing PostGIS install produces a schema-load failure at `createdb`/`psql` time with no earlier warning.

**Mitigation:** treat the PostGIS install step (via Stack Builder on Windows, or the platform package manager on Linux) as a hard prerequisite documented and checked *before* `init_db` runs — see [02](02-windows-installation.md#prerequisites) / [03](03-linux-installation.md#prerequisites).

## No reproducible build

**Verified.** `node_modules/` is absent from the artifact in addition to `yarn.lock` — confirmed by direct inspection, not assumed. The first production run on any target requires a full, network-dependent, unpinned `yarn install --production`. This compounds Risk 1 rather than being independent of it; both are resolved by the same lockfile-generation step.

## Referenced but missing build tooling

**Verified.** `package.json` defines `"build:binary:win": ".\\scripts\\build_binary.bat"` and `"build:binary:linux": "cat ./scripts/build_binary.sh | bash"`, but this artifact contains no `scripts/` directory. Neither command is reachable from what's shipped.

**Mitigation:** none required for the documented install/run path (unpack → initialize → start, operating on the pre-built `build/` folder already present). Relevant only if someone assumes this artifact supports rebuilding from source — it currently does not.

## `HOSTNAME` log field

**Verified**, see [05](05-windows-compatibility-assessment.md#environment-variable-compatibility). Cosmetic: Windows doesn't populate `HOSTNAME` the way POSIX shells do, so the structured-logging metadata field reads `"unknown"` unless set explicitly.

**Mitigation:** set `HOSTNAME` in the service's environment block if per-instance log correlation matters.

## Node version unpinned

**Verified**, see [05](05-windows-compatibility-assessment.md#nodejs--packages). No `engines` field constrains which Node.js version is used, on any platform.

**Mitigation:** once a specific Node 24.x build has been run against this artifact and confirmed working (see [07 — Proof of Concept](07-windows-poc.md)), add `engines.node` to `package.json` to prevent silent drift.

## EDB installer has no stable download URL

**Verified**, by direct research during [08 — Phase 2A](08-development-roadmap.md#phase-2a--postgresql-installation). Unlike `nodejs.org/dist`, EnterpriseDB does not publish a predictable, version-parameterized download URL. Their own downloads page routes through opaque `sbp.enterprisedb.com/getfile.jsp?fileid=NNNNNN` redirects with no discoverable mapping from version number to fileid — confirmed by direct inspection, including one case where an AI-summarized page read produced a fileid that actually pointed at the *macOS* installer, not Windows, until checked with a direct HTTP request. The community-known pattern `get.enterprisedb.com/postgresql/postgresql-{version}-{build}-windows-x64.exe` was confirmed live via `curl -I` (HTTP 200, correct content type, correct size) for the version this project targets, but EDB does not document or guarantee this pattern will continue to work for future versions.

**Mitigation:** `setup.ps1` treats a download failure as an expected, clearly-explained possible outcome, not a mysterious bug — the error message points the operator at the official downloads page to obtain a current link. Whoever bumps `POSTGRES_VERSION`/`POSTGRES_INSTALLER`/`POSTGRES_URL` in `.env.installer` (see `lib\DeltaInstaller.Configuration.ps1`) in the future must re-verify the URL resolves before shipping, the same way a version bump would need re-verification for Node.js if `nodejs.org`'s URL scheme ever changed.

## EDB installer default superuser password

**Verified**, from EDB's own documentation: if `--superpassword` is omitted during an unattended install, it defaults to the literal string `enterprisedb`. EDB's own docs explicitly warn this default is easily guessed. This is a real, officially-documented footgun, not a theoretical one — an installer script that "just works" without prompting for a password would silently ship a well-known default credential on every deployment.

**Mitigation:** `setup.ps1` never installs without first prompting interactively for the superuser password (entered twice, compared, rejected if empty) and always passes it explicitly via `--superpassword`. There is no code path that invokes the installer without this value set. A future non-interactive/unattended mode for `setup.ps1` itself (see [08 — Future Enhancements](08-development-roadmap.md#future-enhancements)) will need its own explicit mechanism for supplying this — not a fallback to the installer's own default.

## EDB installer exit codes are undocumented

**Verified absence.** Unlike `msiexec` (0 = success, 3010 = success/reboot-required, documented broadly), EDB's installer documentation contains no table of exit codes anywhere — confirmed by checking multiple official pages and EDB's own GitHub issue tracker. Only "0 = success" can be relied upon; no reboot-required code is documented at all, unlike Node.js's MSI-based install in Phase 1.

**Mitigation:** `setup.ps1` treats any non-zero exit code as a failed attempt (no special-casing, since there's nothing documented to special-case), and — more importantly — never trusts the exit code alone in either direction. Post-install validation independently confirms the Windows service exists and is running, `psql.exe`/`postgres.exe` are present, and the reported version matches, regardless of what the installer's own exit code claimed.

Observed in practice: the EDB installer can return a non-zero exit code during extraction on an otherwise healthy machine and leave an incomplete install directory — no service registered, no initialized data directory — where an immediately repeated clean attempt succeeds. `setup.ps1` recovers from this class of transient failure automatically via a strictly bounded retry (`Invoke-DeltaComponentInstallWithRetry`, `lib\DeltaInstaller.Common.ps1`; at most 2 attempts, applied consistently to Node.js, PostgreSQL, and PostGIS): after a non-zero exit code it first re-runs the component's own validation (a working component is never retried), then — only for a confirmed fresh installation whose target prefix, data directory, and service name all provably did not exist before the setup run, with no service registered and no `PG_VERSION` present now (`Test-PostgresFreshInstallCleanupSafe`) — removes the incomplete directory the failed attempt created and retries once, with attempt-specific installer logs preserved for both attempts. Pre-existing installations, registered services, and initialized clusters are never removed by any retry path.

## PostgreSQL superuser password: process command-line exposure

**Verified**, general Windows behavior, not specific to this artifact. `--superpassword` is passed as a plaintext command-line argument to the installer process. For the lifetime of that process, the password is visible to anything with sufficient privilege to inspect process command lines on the machine (e.g. `Get-CimInstance Win32_Process`). This is an inherent property of how the EDB installer accepts this parameter — there is no environment-variable or stdin-based alternative documented.

**Mitigation:** none fully closes this within Phase 2A's scope — `setup.ps1` uses `SecureString` for the interactive prompt and only converts to plaintext immediately before building the installer's argument list, minimizing the exposure window, but the fundamental CLI-argument exposure during the installer's own run is inherent to the tool. EDB's `--optionfile` parameter (a file containing configuration options) may offer a safer alternative, but its exact format wasn't documented in what this research could verify — tracked as a documented, accepted limitation rather than guessed at. Revisit if `--optionfile`'s format is confirmed in the future.

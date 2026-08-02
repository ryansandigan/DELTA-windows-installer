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

## UTF-8 and locale at database creation

**Inferred**, full detail in [04 — Database](04-database.md#utf-8-and-locale). Neither `createdb` invocation passes `-E UTF8`/`--locale`, so the new database silently inherits the PostgreSQL cluster's default. Given DELTA ships Arabic, Chinese, Russian, and Serbian locale files, a non-UTF8 cluster default is a real risk, not a theoretical one — and Windows PostgreSQL installers can default `initdb`'s locale to the host OS locale rather than a UTF8-guaranteed default some Linux distro packages use.

**Mitigation:** update `init_db.sh`/`init_db.bat` to pass `-E UTF8 --locale=<target-locale>` explicitly, on both platforms.

## Windows Service shutdown behavior

**Inferred**, full detail in [05 — Windows service considerations](05-windows-compatibility-assessment.md#windows-service-considerations). The app's `SIGTERM`/`SIGINT` cleanup handler (`build/server/index.js:57586-57594`) may not fire under a headless NSSM/WinSW service configuration, since Windows has no native SIGTERM and NSSM's default stop escalation can fall through to a hard `TerminateProcess`.

**Mitigation:** during the [proof-of-concept validation](07-windows-poc.md#validation-checklist), explicitly stop the service and confirm the log-flush cleanup actually runs before relying on this in production. If it doesn't fire reliably, keep the service console-attached (NSSM's default) rather than configuring `AppNoConsole=1`.

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

**Mitigation:** `setup.ps1` treats any non-zero exit code as an unconditional failure (no special-casing, since there's nothing documented to special-case), and — more importantly — never trusts the exit code alone as proof of success. Post-install validation independently confirms the Windows service exists and is running, `psql.exe`/`postgres.exe` are present, and the reported version matches, regardless of what the installer's own exit code claimed.

## PostgreSQL superuser password: process command-line exposure

**Verified**, general Windows behavior, not specific to this artifact. `--superpassword` is passed as a plaintext command-line argument to the installer process. For the lifetime of that process, the password is visible to anything with sufficient privilege to inspect process command lines on the machine (e.g. `Get-CimInstance Win32_Process`). This is an inherent property of how the EDB installer accepts this parameter — there is no environment-variable or stdin-based alternative documented.

**Mitigation:** none fully closes this within Phase 2A's scope — `setup.ps1` uses `SecureString` for the interactive prompt and only converts to plaintext immediately before building the installer's argument list, minimizing the exposure window, but the fundamental CLI-argument exposure during the installer's own run is inherent to the tool. EDB's `--optionfile` parameter (a file containing configuration options) may offer a safer alternative, but its exact format wasn't documented in what this research could verify — tracked as a documented, accepted limitation rather than guessed at. Revisit if `--optionfile`'s format is confirmed in the future.

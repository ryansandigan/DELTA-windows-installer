# DELTA — Application Assessment

**Status:** Living reference — reflects the DELTA production artifact as analyzed.
**Charter:** This document documents the existing DELTA application (`dts_shared_binary/`) as it behaves today. It discovers and records application-level constraints relevant to deployment. **It does not prescribe deployment architecture or implementation.** Deployment decisions are recorded in `docker-containerization-design.md`; implementation is described in `deployment-automation-v1.md`.
**Subject artifact:** `dts_shared_binary/` (DELTA v0.2.3 production build)
**Design Principles:** governed centrally in `docker-containerization-design.md` — not restated here.

---

## Application Constraints

The findings in this document include some that have an identified, concrete deployment consequence. Those, and only those, are indexed below with a stable identifier. The identifier — not a section number — is what `docker-containerization-design.md`'s "Deployment Responses to Application Constraints" section uses to record the corresponding decision, so the link between the two documents survives either one being edited or renumbered.

Not every true fact about the application belongs here. Internal framework details (Express middleware internals, React Router internals generally) are intentionally excluded unless they surface as one of the specific, narrower items below. A constraint earns an entry here because it produced a deployment decision — not because it's true.

| ID | Constraint | Analyzed in |
|---|---|---|
| `secure-cookie-https` | Session cookies are marked `Secure` whenever `NODE_ENV=production`; without HTTPS in front of the deployment, the login/session flow silently fails | §1.2 |
| `translation-import-startup-race` | Content-locale import runs automatically, unawaited, at every server boot, with no visible `.catch()` at the call site | §1.8 |
| `port-host-binding` | The application's listening port/host is controlled by `@react-router/serve` via `PORT`/`HOST`, not by application code directly | §1.9 |
| `uploads-filesystem-persistence` | Uploaded files live on the filesystem at a CWD-relative `uploads/` path — not in the database or object storage | §1.10 |
| `node-version-unpinned` | No `engines` field pins a Node.js version | §1.2 |
| `dependency-reproducibility` | No lockfile (`yarn.lock`) ships with the artifact | §1.2 |

This document does not state what the deployment does about any of these — see `docker-containerization-design.md` §"Deployment Responses to Application Constraints" for the recorded decision on each.

---

## 1. Current Application Architecture

### 1.1 Runtime

- **Application type:** Server-rendered React application built with **React Router v7** (framework mode), running under **Express 5** via the `@react-router/serve` runtime.
- **Entry point:** `build/server/index.js` — a pre-bundled SSR server (~4.4 MB, ~112k lines, esbuild-bundled, not minified/name-mangled, so it is legible for static analysis).
- **Client assets:** `build/client/` — static JS/CSS/font assets served alongside SSR output.
- **Start command** (`package.json:16`): `react-router-serve ./build/server/index.js`, invoked via `start.bat` / `start.sh` through `dotenv -e .env -- yarn start`.
- **Language/tooling:** Node.js (version unpinned — see `node-version-unpinned`), package manager **Yarn**.
- **No supervisor/process manager** is present (no pm2, no systemd unit, no Windows Service wrapper). `start.bat` runs in the foreground and ends with `pause`, i.e., it is designed to be run interactively in a console window, not as a background service.

### 1.2 Dependencies

- **Database driver/ORM:** `drizzle-orm` + `postgres`/`pg` — connects via a single `DATABASE_URL` connection string (`build/server/index.js:1382-1393`). Throws synchronously if `DATABASE_URL` is unset.
- **Database engine:** **PostgreSQL 16.6** (per `pg_dump` header in `dts_db_schema.sql:5-6`) with two required extensions:
  - `pgcrypto` (used for `gen_random_uuid()` primary keys throughout the schema)
  - `postgis` (used for real spatial columns — `geom`/`bbox` as `geometry(Geometry,4326)`, `dts_db_schema.sql:650-651` — this is a genuine dependency, not vestigial, consistent with the OpenLayers/`ol` and Turf.js GIS libraries in `dependencies`)
- **Session handling:** Stateless, **signed cookie sessions** (`createCookieSessionStorage`, `build/server/index.js:1461-1479`) — no server-side session store (Redis, DB-backed sessions, sticky sessions). This is favorable for containerization: the app is horizontally stateless aside from the database and uploaded files.
  - Note: cookies are marked `secure: true` whenever `NODE_ENV=production` (`build/server/index.js:1470`). See constraint `secure-cookie-https`.
- **Email:** `nodemailer`, SMTP or file transport (`EMAIL_TRANSPORT`).
- **Logging:** `winston` + `winston-daily-rotate-file`, writing to a directory controlled by `LOG_DIR` (`build/server/index.js:57457`).
- **No `node_modules/` and no lockfile (`yarn.lock`) are shipped in the artifact.** `package.json` has no `engines` field pinning a Node version. This means:
  - Every install (Windows or Docker) resolves dependency versions fresh against the npm registry at install time.
  - Builds are **not reproducible** — two installs a month apart can silently pull different transitive versions.
  - Internet/registry access is mandatory at install time. See constraints `node-version-unpinned` and `dependency-reproducibility`.

### 1.3 Startup Process

Documented in `README.md` and implemented as four scripts, meant to be run **in order, in the extracted `dts_shared_binary` directory** (all scripts use relative paths — none anchor to their own location via `%~dp0` or `$(dirname "$0")`, so working directory discipline is required):

1. `init_db.bat` / `init_db.sh` — interactive; prompts for DB host/port/name/username, runs `createdb`, then `psql -f dts_database/dts_db_schema.sql` to load the full schema dump (563 KB, includes extensions, types, functions, tables, and seed/reference data such as hazard taxonomies).
2. `init_website.bat` / `init_website.sh` — installs Node.js prerequisites: verifies `npm` is on PATH, installs `yarn` globally, runs `yarn install --production`, installs `dotenv-cli` globally. This is really an **environment bootstrap script**, not an app-specific init step.
3. Manual edit of `.env` (particularly `DATABASE_URL`).
4. `start.bat` / `start.sh` — runs `dotenv -e .env -- yarn start`, which launches `react-router-serve`.

### 1.4 Existing Windows BAT Scripts

| Script | Purpose | Interactivity |
|---|---|---|
| `init_db.bat` | Create DB + load schema via `createdb`/`psql` | Prompts for host, port, DB name, username; prompts for password via `psql -W` |
| `init_website.bat` | Install Node/Yarn toolchain + `yarn install --production` | Non-interactive except `pause` on completion/error |
| `start.bat` | `dotenv -e .env -- yarn start`, then `pause` | Foreground console session |
| `upgrade_database.bat` | Confirm (Y/N), prompt for credentials, run `upgrade_database.sql` | Interactive confirmation + credential prompts |

All four assume `psql`, `createdb`, `npm`, and (for `start.bat`) a working Yarn/Node install are already on `PATH`. None validate PostgreSQL version or extension availability before running.

### 1.5 Existing Linux Shell Scripts

Functionally identical to the `.bat` counterparts (`init_db.sh`, `init_website.sh`, `start.sh`, `upgrade_database.sh`), using `read -p` for prompts and POSIX `createdb`/`psql`. `init_website.sh` is the only script with a shebang plus explicit `chmod +x`-style execute bit already set on disk. Behaviorally a straight port — no macOS/Linux-specific divergence beyond shell syntax.

### 1.6 Database Initialization Flow

- Fresh install: `createdb` → `psql -f dts_db_schema.sql`. The schema dump itself creates the `pgcrypto`/`postgis` extensions (`CREATE EXTENSION IF NOT EXISTS ...`), all tables/types/functions, and **seed data** (e.g., hazard taxonomy reference rows such as HIP hazard codes) plus a single-row `dts_system_info` table recording `version_no` (currently seeded as `'0.2.3'`, `dts_db_schema.sql:1848`).
- The extensions require the target Postgres instance to have the PostGIS package installed at the OS/image level (`CREATE EXTENSION` only registers an already-installed extension; it cannot install PostGIS itself). This must be satisfied by the Postgres image/host, not by the app.
- `dts_system_info` is the **single source of truth for schema version** — the upgrade mechanism reads `version_no` from this table to decide what to apply next.

### 1.7 Upgrade Mechanism

- `upgrade_database.bat`/`.sh` is a thin interactive wrapper: confirms intent, prompts for credentials, then runs `psql --set ON_ERROR_STOP=on -f dts_database/upgrade_database.sql`.
- `upgrade_database.sql` is a **self-selecting migration chain**: it reads `version_no` from `dts_system_info`, and for each recognized version uses `psql`'s `\if`/`\gset` meta-commands to conditionally `\ir` (include relative) the matching incremental SQL file:
  - `0.1.1 → 0.1.3` (via `upgrade_from_0.1.2_to_0.1.3.sql` — note the filename/version mismatch documented inline: "app version was named here 0.1.2 but the version in db was saved as 0.1.1")
  - `0.1.3 → 0.2.0`
  - `0.2.0 → 0.2.1`
  - `0.2.1 → 0.2.2`
  - `0.2.2 → 0.2.3`
- This is **not idempotent-by-design across arbitrary jumps** — it only advances one recognized step per invocation per the current `version_no`, but the `\if` blocks are not chained/looped, so upgrading from a version several releases behind requires running the script and confirming the version advanced, in principle sequentially. In practice, given the current chain, a single run of `upgrade_database.sql` will cascade correctly through consecutive `\if` blocks in one `psql` session since each subsequent `\if` re-reads `version_no` — this has not been executed/tested against a real multi-version-behind database and should be validated whenever upgrade automation is designed.
- **No down-migrations** exist. Rollback = restore from backup only.
- The README explicitly calls out that this upgrade path has no automatic protection beyond `ON_ERROR_STOP=on`; backup is a manual, human responsibility stated in documentation, not enforced by tooling.
- **Application-level version:** the app also reads `process.env.APP_VERSION` (found in `build/server/index.js`) — the relationship between this env var and `dts_system_info.version_no` is not established in the artifact and remains an open question for the DELTA development team.
- Upgrade automation is out of scope for V1 (see `docker-containerization-design.md` § Out of Scope) — this section is retained as factual grounding for when it is designed.

### 1.8 Locale Import Mechanism

Two independent locale mechanisms exist, both directory-based and both resolved **relative to `process.cwd()` at runtime** (`build/server/index.js:1642`, `:1836`) — i.e., the process must be started with its working directory set to the DELTA install root (or a directory containing a sibling `locales/` folder), which is exactly how `start.bat`/`start.sh` invoke it today (no `cd` needed because they already run from that directory):

1. **UI string translations** — `locales/app/{lang}.json` (ar, en, es, fr, ru, sr, zh). Loaded lazily and cached in memory per-language on first request (`loadLang`, `build/server/index.js:1645+`). Purely file-based; no DB involvement.
2. **Content/data translations** — `locales/content/{lang}.json`. These feed an **automatic, startup-time DB import**:
   - `initServer()` (`build/server/index.js:1972-1981`) runs synchronously at module load — i.e., **every time the server process starts** — and calls `initDB()`, `initCookieStorage()`, then `importTranslationsIfNeeded()` (fire-and-forget, not awaited).
   - `shouldImportTranslations()` compares each `locales/content/*.json` file's mtime against `dts_system_info.last_translation_import_at`. If any file is newer (or no import has ever run), it re-imports.
   - Import walks translatable DB columns (hazard types, clusters, hazards, sectors, assets, categories) and merges translated strings via JSONB `||` concatenation, then updates `last_translation_import_at`.
   - **This has a startup-ordering risk**: `importTranslationsIfNeeded()` is called without `await` and, from what is visible in the bundle, without a `.catch()` at the call site. If the database is not yet reachable when the app boots, the resulting promise rejection is unhandled and, depending on the Node major version's unhandled-rejection policy, can crash the process. See constraint `translation-import-startup-race`.

### 1.9 Environment Variables

Extracted directly from `build/server/index.js` (authoritative — more complete than `.env`, which only documents a subset):

| Variable | Purpose | Required? |
|---|---|---|
| `DATABASE_URL` | Postgres connection string | Yes — throws if missing |
| `SESSION_SECRET` | Cookie signing secret | Yes — throws if missing |
| `NODE_ENV` | `development`/`production`; also flips cookie `secure` flag | Effectively yes |
| `PUBLIC_URL` | Used in outbound links (emails, etc.) | Recommended |
| `EMAIL_TRANSPORT` | `smtp` or `file` | Yes if email features used |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_SECURE`, `EMAIL_FROM` | SMTP config | Conditional |
| `AUTHENTICATION_SUPPORTED` | `form`, `sso_azure_b2c`, or both | Yes |
| `SSO_AZURE_B2C_TENANT`, `_CLIENT_ID`, `_CLIENT_SECRET`, `_USERFLOW_LOGIN[...]`, `_USERFLOW_EDIT[...]`, `_USERFLOW_RESET[...]` | Azure B2C SSO | Conditional on SSO use |
| `HTTP_PROXY` | Outbound proxy (README notes HTTPS proxying doesn't work) | Optional |
| `SUPPORT_URL` / `SUPPORT_EMAIL` | Error-page contact info | Optional |
| `LOG_DIR`, `LOG_LEVEL`, `LOG_RETENTION_DAYS` | Winston logging config | Optional, has code-level defaults presumed |
| `ENABLE_LOG_METRICS`, `ENABLE_REMOTE_LOGGING`, `REMOTE_LOG_ENDPOINT`, `REMOTE_LOG_API_KEY` | Remote/metrics logging | Optional |
| `DEPLOYMENT_REGION`, `INSTANCE_ID`, `HOSTNAME` | Presumably log/metric tagging | Optional |
| `APP_VERSION` | App version string (relationship to DB `version_no` unclear) | Unclear — open question |
| `VITE_SERVER_PORT` | Used only for an internal loopback API self-call (`http://localhost:${port}`) — **not** confirmed to be the actual HTTP listen port | Needs clarification |
| `REACT_APP_CSS_NONCE` | CSP nonce for styles | Optional |

The actual HTTP listen port/host is controlled by `react-router-serve` itself via `PORT`/`HOST` (see constraint `port-host-binding`) — not confirmable by static analysis of this bundle alone, since that package is external to it.

### 1.10 Persistent Data Locations

| Data | Location | Notes |
|---|---|---|
| Database | External PostgreSQL instance (not part of this artifact) | Connection via `DATABASE_URL` |
| Uploaded files | `./uploads/` relative to CWD, with subpaths `uploads/hazardous-event`, `uploads/disaster-event`, `uploads/disaster-record[/losses\|/disruptions\|/damages]`, `uploads/temp` (`build/server/index.js:16796-16805`) | Filesystem-based, **not** stored in DB or object storage. Must persist across upgrades/restarts. See constraint `uploads-filesystem-persistence`. |
| Logs | `LOG_DIR` (env-configurable) | Daily-rotating files via `winston-daily-rotate-file` |
| Locale content | `./locales/app/*.json`, `./locales/content/*.json` relative to CWD | Read at runtime; content locales also drive a one-way DB import |
| Legacy uploads | Code contains a fallback path for "legacy file (outside uploads folder)" (`build/server/index.js:89168`) | Indicates at least one prior storage layout existed; relevant only if migrating a very old installation |

---

## 2. Dockerization Feasibility & Compatibility Findings

Findings only — what the deployment does in response to any of these is recorded in `docker-containerization-design.md`, not here.

### 2.1 What Can Be Containerized

- **Application (Node/Express/React Router SSR process)** — stateless aside from the DB connection, uploads directory, log directory, and locale files.
- **PostgreSQL + PostGIS** — a standard, well-supported container workload; official `postgis/postgis` images ship Postgres 16 + PostGIS pre-installed, which removes the "extension not installed at OS level" failure mode entirely.
- **Locale files** — static JSON, can be baked into an image or mounted.
- **Schema initialization** — `dts_db_schema.sql` is a plain SQL script compatible with Postgres's official image's `/docker-entrypoint-initdb.d/` first-boot convention.

### 2.2 What Cannot Run Unmodified

- **The interactive `init_db`/`upgrade_database` scripts** are written for a human at a terminal (`read -p`, `set /p`, Y/N confirmation, password prompts via `psql -W`). They cannot run inside a non-interactive orchestration flow without being re-expressed as parameterized (env-var/CLI-arg driven) invocations.
- **The "copy/symlink the uploads folder after upgrade" step** is manual by design in the current architecture (see constraint `uploads-filesystem-persistence`).
- **`node_modules` install at "build" time is not currently reproducible** (see constraint `dependency-reproducibility`).

### 2.3 Compatibility Notes

1. **DB-not-ready race at boot** — see constraint `translation-import-startup-race`.
2. **`NODE_ENV=production` forces `Secure` cookies** — see constraint `secure-cookie-https`.
3. **PostGIS/pgcrypto version compatibility** — the schema was dumped from Postgres 16.6. A materially different Postgres/PostGIS minor version could theoretically introduce dump/restore incompatibilities, though this risk is low for a schema-only (non-binary) SQL script.
4. **File upload size/type validation is enforced in-app** (`maxFileSize = 10MB`, extension allow-list, `build/server/index.js:16786-16794`), independent of whatever sits in front of the application at the network layer.
5. **Windows path separators**: `normalizeTenantRelativePath()` (`build/server/index.js:1809`) explicitly normalizes `\` to `/` — the application is already somewhat Windows-path-aware for upload handling.
6. **Line endings**: all `.bat` files are DOS-formatted and all `.sh` files are Unix-formatted correctly in the artifact as shipped (verified via `file`) — no CRLF/LF corruption present today, but this is a property of the artifact, not a guarantee about future releases.
7. **Case sensitivity**: `locales/{app,content}` and `uploads/*` use consistent lowercase naming in code — low risk on case-sensitive filesystems.

### 2.4 Open Questions for the DELTA Development Team

- Confirmation of `react-router-serve`'s default listen port and whether it honors a `PORT` env var (see constraint `port-host-binding`).
- Whether `importTranslationsIfNeeded()` truly has no `.catch()` at the call site, and whether this is known/accepted upstream or something the DELTA team would want patched independently of this containerization effort (see constraint `translation-import-startup-race` — this project accommodates it, it does not patch application code).
- Relationship between `APP_VERSION` env var and `dts_system_info.version_no`.
- Whether a `yarn.lock` (or npm/pnpm equivalent) exists in the source repository but was excluded from this **binary distribution** artifact.
- Whether the `upgrade_database.sql` cascading `\if` chain correctly advances a database that is more than one version behind, in a single invocation — relevant only once upgrade automation is designed.

---

*This document documents the existing application only. Deployment decisions are recorded in `docker-containerization-design.md`; implementation is described in `deployment-automation-v1.md`.*

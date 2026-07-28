# DELTA — Docker Containerization Design

**Status:** Approved technical design.
**Charter:** This document records the deployment's response to every deployment-relevant application constraint discovered in `windows-docker-installer-assessment.md` — accommodated, accepted as a documented limitation, or explicitly deferred. It owns this project's Design Principles, V1 Success Criteria, Out-of-Scope boundary, and Roadmap. `deployment-automation-v1.md` implements the decisions recorded here; it introduces no new architecture of its own.
**Primary source of truth for application facts:** `windows-docker-installer-assessment.md`. This document does not repeat that analysis — it assumes it as background and focuses on the deployment's response to it.
**Secondary reference (image-build patterns only):** `DELTA-image-builder/` — reviewed strictly for how it builds the application image (§1 below). Its Azure/ACR/CI/webapp-deployment tooling is out of scope and not discussed here.

---

## Design Principles

- Solve today's deployment problem only — automate deploying the existing `dts_shared_binary` artifact, not a hypothetical future one.
- Avoid premature abstraction; prefer procedural implementation over frameworks, plugins, or generic engines.
- Build one successful deployment before extracting any reusable component — extract only once duplication actually appears (rule of three), not in anticipation of it.
- Let operational experience drive future architecture, not assumptions about what might be needed.
- Every deployment-relevant application constraint (`windows-docker-installer-assessment.md` § Application Constraints) gets exactly one recorded response in § Deployment Responses below. Automation implements that response; it does not decide it.

---

## 1. Reference Review — How DELTA-image-builder Builds the Application Image

### 1.1 What it does today

`DELTA-image-builder/Dockerfile` builds a single, monolithic image:

- **Base image:** `node:22-bookworm-slim`. This is a materially useful data point: it is the base image an actual running DELTA deployment has been built from, not a guess. It resolved the "which Node version" question in Node 22's favor at the time — that has since been superseded by this project's explicit runtime standard of **Node.js v24.18.0** (see §2.1a); Node 22 is noted here only as historical context for the reference image.
- **`WORKDIR /data`**, with system packages installed in one layer: `nginx vim joe git ca-certificates cron supervisor openssh-server curl unzip dos2unix postgresql-client`.
- **Yarn via Corepack** (`corepack enable && corepack prepare yarn@stable --activate`).
- **Artifact copy:** selectively copies `build/`, `package.json`, `init_website.sh`, `build/client/` (into `/data/public/`), `locales/`, `upgrade_database.sh`, and `dts_database/` from the shared-binary artifact — not the whole zip.
- **Dependency install happens at image-build time**, inside a single `RUN` layer: it locates `init_website.sh`, runs `dos2unix` on it, `chmod +x`, executes it (which itself does `npm install --global --force yarn`, `yarn install --production`, `yarn global add dotenv-cli`), then cleans Yarn/npm caches. This bakes `node_modules` into the image layer rather than installing at container start — the right instinct, even though the specific script it delegates to has issues (§1.2).
- **Environment-specific config baked in at build time** via `ARG ENV=dev`: copies `config/${ENV}/sshd.conf`, `config/${ENV}/nginx.conf`, `config/${ENV}/supervisord.conf` into the image, meaning a `dev` image and a `prod` image are two different image builds.
- **Three processes run inside one container**, supervised by `supervisord`: `sshd` on port 2222 (remote shell access), `nginx` on port 80 (reverse-proxies to `127.0.0.1:3000`), and the DELTA app itself (`PORT=3000 yarn start`).
- **`entrypoint.sh`** dumps the container's environment variables into `/etc/profile.d/export_envvars.sh` (so any cron job would inherit them) before `exec`-ing `supervisord`.
- **`docker-compose.yml`** (the self-hosted variant) runs this image as a single service, alongside a `postgis/postgis:16-3.4` database service — the same Postgres major version and PostGIS combination our schema was dumped from, and, like the base Node image, a combination that has actually been run, not merely selected on paper.

### 1.2 Why it looks the way it does, and what no longer applies

This container shape is a direct consequence of its actual deployment target: **Azure App Service for Containers**, which expects one container, one exposed port, no sibling containers — so everything the deployment needed (a reverse proxy, a way to get a shell for debugging, the app itself) had to be crammed into that single container, supervised by something.

**None of those constraints apply to a self-hosted Docker Compose deployment.** Compose gives us multiple containers, a private network between them, and `docker exec`/`docker logs` for operational access, for free. Most of the internal complexity of the existing image solves a problem that does not exist in this project's target architecture.

### 1.3 Reuse / Modernize / Drop — Summary

| Concept | Verdict |
|---|---|
| `node:22-bookworm-slim` base image | **Superseded** by this project's Node.js v24.18.0 standard (§2.1a) — the reference image's choice is noted only as validation that the `*-bookworm-slim` family works for this app. |
| `postgis/postgis:16-3.4` for the database | **Reused unchanged** — matches the schema's Postgres 16.6 origin, already validated in a running deployment. |
| Corepack for Yarn provisioning | **Reused** — standard, ships with Node. |
| Copying only the runtime-necessary artifact subset into the image | **Reused** — also independently confirms `express.static("public")` needs a `public/` copy of `build/client/`, a real requirement, not a Docker artifact. |
| Installing dependencies at image-build time | **Reused as a principle** — produces an immutable, fast-starting image. |
| `init_website.sh` as the install mechanism | **Modernized** — only `yarn install --production` is carried forward, invoked directly rather than via a script that also fights Corepack and installs an unneeded `dotenv-cli`. |
| `dos2unix` on shipped shell scripts | **Reused, broadened** to any shell script still copied into the new image. |
| `sshd`, `nginx`, `supervisord`, `cron`, editors (`vim`/`joe`) in the app container | **Dropped** — all existed solely to satisfy Azure App Service's single-process-per-container constraint, which does not apply here. `docker exec`/`docker logs` cover the operational need. |
| `entrypoint.sh`'s env-export shim | **Dropped** — existed only for a cron job that never existed. |
| `postgresql-client` baked into the app image | **Dropped from the app image** — the app talks to Postgres over the network via its own driver, never by shelling out to `psql`. |
| `ARG ENV=dev/prod` build-time config baking | **Dropped, replaced by runtime configuration** — one image, promoted unchanged across environments, configured via Compose `environment:`/`env_file:`. |
| `docker-entrypoint-initdb.d` schema auto-load | **Reused and completed** — the reference repo had this prepared (two SQL files under `data/postgresql-initdb/`) but never wired into its committed compose file; this design completes that pattern (§4). |

---

## 2. DELTA Application Docker Image Architecture

### 2.1a Runtime Standard (Project Decision)

This project's standard Node.js runtime is **v24.18.0**, targeting the **Bookworm** Debian base. The application image is built from `node:24.18.0-bookworm-slim`, superseding the Node 22 line used by the `DELTA-image-builder` reference image (§1).

This is a deliberate project decision, not something derived from evidence in either artifact reviewed:

- **Node 22 was a validated combination** (an actual running deployment was built and operated on it). **Node 24.18.0 is not yet validated against this specific application artifact** — nothing in `dts_shared_binary`'s `package.json` pins an `engines` range (constraint `node-version-unpinned`), and no test run on Node 24 has been performed. Treat the first build/run on it as a validation step, not known-good.
- Because `yarn.lock` does not yet exist for this artifact (constraint `dependency-reproducibility`), generating that lockfile should itself be done **using Node 24.18.0**, so the pinned dependency resolution matches the runtime it will actually run on.

### 2.1 Design Goals

- **Immutable, reproducible image**: dependencies resolved and installed once, at build time, from a pinned lockfile. A `yarn.lock` must exist before this image is considered release-ready (constraint `dependency-reproducibility`, § Deployment Responses).
- **Single responsibility per container**: the app image runs the DELTA Node process and nothing else.
- **Runs as a non-root user.** The reference image implicitly runs as `root`, needed for `sshd`/`nginx`. With those dropped, there is no remaining reason to run as `root`.
- **No environment baked in.** The same image is deployed to every environment; everything that differs is a runtime environment variable, not a build-time `ARG`.

### 2.2 Conceptual Layer Structure

1. **Base layer** — `node:24.18.0-bookworm-slim`, with Corepack enabled and Yarn activated.
2. **Dependency layer** — copy only `package.json` (and, once available, `yarn.lock`) first, then run `yarn install --production` directly, so this layer only invalidates when dependencies actually change, not on every artifact rebuild.
3. **Application layer** — copy `build/`, `locales/`, `dts_database/`, then create `public/` from `build/client/`.
4. **Runtime user layer** — create an unprivileged system user/group, `chown` the application directory to it, switch to it before the final `CMD`.
5. **Metadata** — `EXPOSE <port>` (internal app port), a `HEALTHCHECK` hitting that same port, and a `CMD` that starts the app directly in the foreground — no supervisor, no shell-script wrapper beyond what's strictly needed to set the listening port.

### 2.3 Open Points

- **`yarn.lock` must be sourced or generated before this image is release-ready** — blocking prerequisite, independent of anything else in this design.
- **`PORT`/`HOST` handling of `@react-router/serve`** (constraint `port-host-binding`) — treated as high-confidence (set `PORT` explicitly; leave `HOST` unset for all-interfaces) but not yet independently verified against this exact artifact version; validate in the first build.

### 2.4 What Deliberately Stays Out of the Application Image

- **The interactive `init_db.*`/`upgrade_database.*`/`start.*`/`init_website.*` scripts** are not copied into the app image at all. Schema initialization is handled by the `db` service's own `docker-entrypoint-initdb.d` mechanism (§4).
- **`postgresql-client`** — not needed; the app talks to Postgres over the network via its own driver.

---

## 3. Docker Compose Architecture

### 3.1 Services

| Service | Image | Responsibility |
|---|---|---|
| `app` | Built from the Dockerfile in §2 | Runs the DELTA Node process; serves HTTP; owns session/locale/upload logic. |
| `db` | `postgis/postgis:16-3.4` | Postgres 16 + PostGIS + pgcrypto; owns all persistent relational/spatial data. |

No `proxy` service is shipped as part of V1 — see constraint `secure-cookie-https` in § Deployment Responses. No `sshd` service, no `cron` service — neither has a job to do in this architecture; `docker compose exec`/`docker compose logs` cover the operational need the reference project's in-container `sshd` was working around.

### 3.2 Networking

- A single **private, internal Compose network** shared by `app` and `db`. Services address each other by Compose service name (`db`), which is what `DATABASE_URL` in `app`'s environment points at.
- **`db` does not need a host port mapping** in production — only `app` needs to be reachable from outside the Compose network.
- `app`'s own port is exposed directly to the host in V1 (no proxy in front of it — see § Deployment Responses).

### 3.3 Configuration Strategy

- Environment variables are supplied to `app` via Compose `environment:`/`env_file:`, populated from the variable table in `windows-docker-installer-assessment.md` §1.9 — `DATABASE_URL`, `SESSION_SECRET`, `NODE_ENV`, `PUBLIC_URL`, SMTP/email settings, `AUTHENTICATION_SUPPORTED`, optional SSO variables, logging variables, and `PORT`.
- **No environment-specific image builds.** Dev/staging/prod all run the *same* image; only the env-file contents differ.
- `db`'s own credentials (`POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB`) are supplied the same way, kept consistent with `app`'s `DATABASE_URL` via the same env-file.

---

## 4. PostgreSQL/PostGIS Integration

### 4.1 Image Choice

`postgis/postgis:16-3.4` (reused unchanged from the reference project, §1.3) — matches the Postgres 16.6 origin of `dts_db_schema.sql` and ships PostGIS pre-installed.

### 4.2 Schema Initialization (Fresh Install)

Postgres's official image convention — executing every `*.sql`/`*.sh` file in `/docker-entrypoint-initdb.d/`, in filename-sorted order, but only when the data directory is empty — is the mechanism for turning `dts_db_schema.sql` into an automatic first-boot step, naturally satisfying "only run once, on a genuinely fresh database."

This completes a pattern the reference project had partially prepared (`data/postgresql-initdb/01_dts_db_schema.sql`) but never wired into its committed `docker-compose.yml`:

- Mount `dts_database/dts_db_schema.sql` into `/docker-entrypoint-initdb.d/01_dts_db_schema.sql` on the `db` service.
- The extensions (`pgcrypto`, `postgis`) are created by the schema file itself; the `postgis/postgis` image's default superuser has sufficient privilege.

### 4.3 Upgrades

Out of scope for V1 (§ Out of Scope). The existing SQL migration chain (`upgrade_database.sql`, self-selecting based on `dts_system_info.version_no`) is preserved unmodified in the artifact for when upgrade automation is designed — not invoked by any part of this V1 design.

### 4.4 Credentials

`db`'s superuser/app credentials are supplied via Compose environment variables, sourced from an env-file kept outside version control.

---

## 5. Container Startup Sequence and Dependency Ordering

### 5.1 The Core Risk

Constraint `translation-import-startup-race`: the application's `initServer()` runs synchronously at module load and calls `importTranslationsIfNeeded()` without awaiting it and without a visible `.catch()`. That function immediately queries the database. If `app` starts before `db` is actually ready to accept queries, this is a plausible unhandled-promise-rejection crash on first boot — precisely the scenario Compose's plain `depends_on: [db]` (which only waits for the container to *start*, not for Postgres to be *ready*) does not protect against, and precisely the gap the reference project's own compose file also leaves open.

### 5.2 Ordering Design (Deployment Response)

1. **`db` starts first.** Its `HEALTHCHECK` (§7) uses `pg_isready`, matching the reference project's own healthcheck — reused as-is, since `pg_isready` is the standard, correct tool for this.
2. **`app` declares `depends_on: db: condition: service_healthy`**, rather than the reference project's plain `depends_on`. `app` will not even start until `db`'s healthcheck reports healthy, closing most of the race window.
3. **`app`'s own restart policy** (`restart: on-failure`, bounded retry count) is a second line of defense for the residual race window a healthy-DB gate can't fully close.
4. **Locale import remains fully automatic and unchanged.** No new orchestration step is needed for it beyond the above — it already runs on every app boot, comparing file mtimes to `dts_system_info.last_translation_import_at`.

### 5.3 What This Design Deliberately Does Not Attempt

Patching `importTranslationsIfNeeded()` itself (adding a `.catch()`/retry) is an application source-code change, not a container-orchestration one — out of this project's scope. The application remains owned by the DELTA development team; this design accommodates its behavior rather than modifying it.

---

## 6. Persistent Storage Strategy

| Data | Owner service | Volume type | Notes |
|---|---|---|---|
| Postgres data directory | `db` | Named volume | Never touched by an `app` image upgrade. |
| `uploads/` | `app` | Named volume/bind mount, at the CWD-relative `uploads` path the app expects | Deployment response to constraint `uploads-filesystem-persistence` — retires the artifact's manual copy/symlink-after-upgrade step structurally, from the first deployment. |
| `logs/` (`$LOG_DIR`) | `app` | Named volume/bind mount | Recommended for local troubleshooting independent of `docker compose logs`. |
| `locales/` | `app` | Baked into the image, not a volume | Part of the versioned application artifact; no operational need to override independently of an image rebuild. |
| `dts_database/` (schema SQL) | `db` (via `docker-entrypoint-initdb.d` mount) | Read-only mount | An input to `db`'s first-boot init, not mutable state. |

---

## 7. Health Checks

| Service | Probe |
|---|---|
| `db` | `pg_isready -U $POSTGRES_USER -d $POSTGRES_DB -h localhost` — reused as-is from the reference project. |
| `app` | HTTP probe against the app's **own internal port directly** — modernized from the reference project's check, which curled port 80 through the in-container nginx that no longer exists here. |

Both use conservative `interval`/`timeout`/`retries` values in the same spirit as the reference project's own settings, tunable during implementation once real startup timing is observed.

---

## 8. Deployment Responses to Application Constraints

Per the governance principle stated above: every deployment-relevant constraint from `windows-docker-installer-assessment.md` § Application Constraints has exactly one recorded response here. Automation (`deployment-automation-v1.md`) implements these; it does not decide them.

| Constraint ID | Response Type | Recorded Decision |
|---|---|---|
| `secure-cookie-https` | **Accepted (environment-provided)** | V1 does not ship a TLS-terminating component. The deployment is designed to operate behind the operator's own TLS-terminating reverse proxy, WAF, IIS, NGINX, or equivalent infrastructure already present in the hosting environment. This project does not modify the application's session/cookie implementation. **Consequence, stated plainly:** accessed over plain HTTP with no such front end in place, login will not persist — this is a documented characteristic of V1, not a defect to be diagnosed. § V1 Success Criteria below reflects this honestly rather than assuming it away. |
| `translation-import-startup-race` | **Accommodated** | `db`'s `pg_isready` healthcheck combined with `app`'s `depends_on: condition: service_healthy` (§5) closes the startup race at the orchestration level. `app`'s `restart: on-failure` policy is a second line of defense. Application code is not modified. |
| `port-host-binding` | **Accommodated** | `PORT` is set explicitly in `app`'s environment (never left to fall back to a scanned free port); `HOST` is left unset (binds all interfaces), correct since `app` is reached via the Compose network. |
| `uploads-filesystem-persistence` | **Accommodated** | `uploads/` is a first-class persistent volume from the first deployment (§6), eliminating the artifact's manual copy/symlink-after-upgrade step structurally rather than replicating it. |
| `node-version-unpinned` | **Accepted (project standard imposed)** | This project fixes the runtime at Node.js v24.18.0 (§2.1a) rather than leaving it to drift; the first build/run on it is treated as a validation step, not assumed known-good. |
| `dependency-reproducibility` | **Deferred (blocking prerequisite)** | A `yarn.lock` must be generated, using Node 24.18.0, before the image is considered release-ready. Tracked as a prerequisite work item, not a deployment-architecture decision — it blocks §2's image build, but is not itself part of this design. |

---

## 9. V1 Success Criteria

Given the `dts_shared_binary` release artifact, executing `install.ps1` must produce a deployment where **all** of the following hold:

1. The Docker image builds successfully from the artifact.
2. The `db` service initializes PostgreSQL/PostGIS and reports healthy.
3. The `app` service starts only after `db` is healthy, and itself reports healthy.
4. `dts_system_info.version_no` is present and matches the artifact's `package.json` version — confirming the schema actually loaded, not merely that Postgres is running.
5. The automatic content-locale import completes without error on first boot (`last_translation_import_at` is set).
6. The application's own internal configuration validation reports zero errors.
7. DELTA is reachable, and the login flow works correctly **when accessed through the environment's TLS-terminating front end**, per the `secure-cookie-https` response in §8. Accessing over plain HTTP with no such front end is a documented limitation of V1 (§8), not a defect.
8. Uploaded files and database contents survive a `docker compose down` / `up` cycle intact — not just first boot.
9. Re-running `install.ps1` against an already-successful deployment behaves safely (no data loss, no duplicate schema load).

This list is the exit criteria for **Phase 1 — Working Deployment** in § Roadmap below. `deployment-automation-v1.md` references this list rather than restating it.

---

## 10. Out of Scope for V1

Intentionally not implemented in this design. These are not implicit requirements to be discovered later — they are deliberately deferred until real operational experience justifies designing them:

- Backup automation
- Restore automation
- Upgrade automation (the existing SQL migration chain, §4.3, is preserved unmodified but its non-interactive invocation is not part of V1)
- Windows installer GUI (EULA, resumable multi-reboot install flows, uninstaller)
- Generic deployment SDK / reusable deployment framework / plugin architecture
- Kubernetes
- Multiple deployment targets / multi-environment configuration layering (e.g. separate base/override Compose files)
- Air-gapped / offline image distribution
- A bundled TLS-terminating reverse proxy — see constraint `secure-cookie-https` in §8; V1 assumes this is provided by the operating environment
- Windows Task Scheduler auto-start-on-reboot wiring
- Any `stop`/`restart`/`logs`/`shell` operator convenience scripts beyond `install.ps1` itself

Removed content that previously explored some of these is not preserved in a separate document — this project's own git history is the record, consistent with the principle of avoiding unnecessary documentation.

---

## 11. Roadmap

Organized around outcomes, not technology work-breakdown.

**Phase 1 — Working Deployment**
Goal: given `dts_shared_binary`, executing `install.ps1` produces a working DELTA deployment satisfying every item in § V1 Success Criteria. Nothing else is in scope until this milestone is met.

**Phase 2 — Operational Confidence** *(not designed yet — begins only after Phase 1 has real operational experience behind it)*
Candidate scope: backup/restore automation, upgrade automation, additional operator convenience scripts. What (if anything) becomes a shared/reusable component is decided from duplication that actually appears, not designed in advance — per this project's Design Principles.

---

## 12. Summary of Key Decisions

1. **Base images**: `node:24.18.0-bookworm-slim` for `app` (this project's runtime standard — supersedes the reference deployment's validated-but-superseded Node 22 line), and `postgis/postgis:16-3.4` for `db`, reused unchanged from the validated reference deployment.
2. **The app image is a single process** — `nginx`, `sshd`, `supervisord`, and `cron` are all dropped; the Azure App Service constraint that necessitated them does not apply here.
3. **One image, all environments** — environment-specific behavior moves entirely to Compose-supplied runtime environment variables.
4. **Schema auto-init via `docker-entrypoint-initdb.d` is completed**, not re-invented.
5. **The existing SQL upgrade chain is reused unmodified**; its non-interactive invocation is deferred to Phase 2.
6. **`depends_on: condition: service_healthy` closes the most concrete startup risk** identified in the assessment.
7. **`uploads/` becomes a first-class persistent volume from the first deployment.**
8. **Every deployment-relevant application constraint has exactly one recorded response** (§8), including a now-formal decision on the previously open `secure-cookie-https` question: V1 assumes TLS termination is provided by the operating environment and does not ship its own.

This document is the approved technical design. `deployment-automation-v1.md` implements it; no new architecture is introduced during implementation.

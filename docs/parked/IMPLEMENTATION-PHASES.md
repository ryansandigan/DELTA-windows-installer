# DELTA — Implementation Phases

**Status:** Execution tracking document.
**Purpose:** Tracks implementation progress against the frozen, approved architecture. **This document contains no architecture of its own.** Every deliverable and checklist item below implements a decision already recorded in `docker-containerization-design.md` and sequenced per `deployment-automation-v1.md`. If executing any phase surfaces a decision not already recorded in those documents, implementation stops on that item and the decision is routed back to `docker-containerization-design.md` — it is not resolved here, inline.
**Source of truth:** `windows-docker-installer-assessment.md` (application facts), `docker-containerization-design.md` (deployment architecture, Design Principles, V1 Success Criteria, Out of Scope, Roadmap), `deployment-automation-v1.md` (automation implementation). This document does not restate their content — each phase below cites the section it implements.
**Scope guardrail:** Phases 0–6 implement `docker-containerization-design.md` § Roadmap "Phase 1 — Working Deployment" in its entirety. Nothing in § Out of Scope (design doc §10) is scheduled here.

---

## How to use this document

Each phase below is a unit of execution tracking, not a design unit. Mark checklist items complete as work lands. A phase's Exit Criteria must be fully met before the next dependent phase begins — dependency order is stated explicitly per phase.

---

## Phase 0 — Dependency Lockfile Generation

**Objective:** Produce the `yarn.lock` blocking prerequisite identified in `docker-containerization-design.md` §2.1a, §2.3, and §8 (constraint `dependency-reproducibility`), so the application image build in Phase 1 resolves reproducible dependency versions.

**Deliverables:**
- `yarn.lock`, generated using Node.js **v24.18.0** (the project's standard runtime, §2.1a), stored alongside the `dts_shared_binary` artifact inputs used for the image build.

**Prerequisites:**
- Node.js v24.18.0 available in the environment used to generate the lockfile.
- Access to the `dts_shared_binary` artifact's `package.json`.
- Registry access (npm/Yarn) at generation time.

**Exit Criteria:**
- `yarn.lock` exists and was generated on Node.js v24.18.0, per design §2.1a.
- Lockfile is treated as release-blocking — no image build in Phase 1 proceeds without it (design §2.1, §2.3).

**Checklist:**
- [ ] Install/select Node.js v24.18.0 in the build environment.
- [ ] Run dependency resolution against the artifact's `package.json` on that Node version to produce `yarn.lock`.
- [ ] Confirm the lockfile is available to the Phase 1 build context.

**Risks (implementation only):**
- First dependency resolution on Node 24.18.0 is unvalidated against this artifact (design §2.1a) — a resolution or install-time failure here is a legitimate finding, not a process error, and should be captured as evidence rather than worked around.
- Registry unavailability at generation time blocks this phase entirely; there is no offline fallback (design §10, air-gapped distribution is out of scope).

---

## Phase 1 — Application Docker Image

**Objective:** Build the `app` image per the five-layer structure in `docker-containerization-design.md` §2.2, using the Reuse/Modernize/Drop decisions in §1.3.

**Deliverables:**
- `Dockerfile` for the `app` service implementing all five layers in §2.2: base, dependency, application, runtime user, metadata.

**Prerequisites:**
- Phase 0 complete (`yarn.lock` available).

**Exit Criteria:**
- Image builds successfully from `node:24.18.0-bookworm-slim`.
- Image runs as a non-root user (design §2.1).
- No environment-specific values are baked into the image (design §2.1, §3.3).
- `HEALTHCHECK` targets the app's own internal port directly (design §7).
- Image contains no dropped components: no `nginx`, `sshd`, `supervisord`, `cron`, `vim`/`joe`, no `postgresql-client`, no `ARG ENV` build-time config, no `entrypoint.sh` env-export shim, no interactive `init_db.*`/`upgrade_database.*`/`start.*`/`init_website.*` scripts (design §1.3, §2.4).

**Checklist:**
- [ ] Base layer: `node:24.18.0-bookworm-slim`, Corepack enabled, Yarn activated (§2.2.1).
- [ ] Dependency layer: copy `package.json` + `yarn.lock` first, then `yarn install --production` directly — no `init_website.sh` wrapper (§2.2.2, §1.3).
- [ ] Application layer: copy `build/`, `locales/`, `dts_database/`; create `public/` from `build/client/` (§2.2.3).
- [ ] Runtime user layer: create unprivileged system user/group, `chown` application directory, switch user before final `CMD` (§2.2.4).
- [ ] Metadata: `EXPOSE` internal app port, `HEALTHCHECK` against that port, foreground `CMD` with no supervisor/wrapper beyond what's needed to set the listening port (§2.2.5).
- [ ] Apply `dos2unix` to any shell script still copied into the image (§1.3).
- [ ] Confirm nothing from § Deliberately Stays Out of the Application Image (§2.4) is present.

**Risks (implementation only):**
- `PORT`/`HOST` handling of `@react-router/serve` is treated as high-confidence but not independently verified against this artifact version (design §2.3) — validate during this phase's first build, not assume correct.
- First build/run on Node 24.18.0 is a validation step, not known-good (design §2.1a) — build failures here are expected-possible outcomes to record, not necessarily implementation mistakes.

---

## Phase 2 — Database Service Integration

**Objective:** Stand up the `db` service and complete the schema auto-init pattern per `docker-containerization-design.md` §3.1 and §4.

**Deliverables:**
- Compose service definition for `db` (image, environment, healthcheck, volume, init mount).
- `docker-entrypoint-initdb.d` wiring for `dts_db_schema.sql`.

**Prerequisites:**
- None beyond artifact access (`dts_database/dts_db_schema.sql`). Independent of Phase 1 — may be executed in parallel with it.

**Exit Criteria:**
- `db` initializes PostgreSQL/PostGIS and reports healthy on a fresh volume (design §9 item 2).
- `dts_system_info.version_no` is present after first boot and matches the artifact's `package.json` version (design §9 item 4).
- No host port mapping is present on `db` in the production configuration (design §3.2).

**Checklist:**
- [ ] Pin `db` image to `postgis/postgis:16-3.4` (design §1.3, §4.1).
- [ ] Mount `dts_database/dts_db_schema.sql` to `/docker-entrypoint-initdb.d/01_dts_db_schema.sql` (design §4.2).
- [ ] Configure `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` via env-file, kept consistent with `app`'s `DATABASE_URL` (design §3.3, §4.4).
- [ ] Configure `db` `HEALTHCHECK` using `pg_isready -U $POSTGRES_USER -d $POSTGRES_DB -h localhost` (design §7).
- [ ] Attach a named volume for the Postgres data directory (design §6).
- [ ] Confirm no host port mapping is exposed for `db` in production (design §3.2).

**Risks (implementation only):**
- None specific to this phase beyond the schema/PostGIS minor-version compatibility risk already characterized as low in the assessment (§2.3 item 3) — no new mitigation is designed here.

---

## Phase 3 — Compose Orchestration, Networking, and Persistence

**Objective:** Wire `app` and `db` into a single Compose stack implementing the startup-ordering design (§5), networking (§3.2), and persistent storage strategy (§6).

**Deliverables:**
- `docker-compose.yml` defining both services, the shared network, dependency ordering, restart policy, and all volumes.
- Env-file template covering the variable set in `windows-docker-installer-assessment.md` §1.9.

**Prerequisites:**
- Phase 1 (app image buildable) and Phase 2 (db service definition) both complete.

**Exit Criteria:**
- `app` starts only after `db` reports healthy, and itself reports healthy (design §9 item 3).
- Uploaded files and database contents survive a `docker compose down`/`up` cycle intact (design §9 item 8).
- Re-running the stack against an already-successful deployment causes no data loss and no duplicate schema load (design §9 item 9).

**Checklist:**
- [ ] Create a single private internal Compose network shared by `app` and `db` (design §3.2).
- [ ] Set `app`'s `depends_on: db: condition: service_healthy` (design §5.2).
- [ ] Set `app`'s `restart: on-failure` with a bounded retry count (design §5.2).
- [ ] Expose `app`'s port directly to the host; no `proxy` service (design §3.2, §8 `secure-cookie-https`).
- [ ] Attach named volume/bind mount for `uploads/` at the CWD-relative path the app expects (design §6).
- [ ] Attach named volume/bind mount for `logs/` (`$LOG_DIR`) (design §6).
- [ ] Wire `app` environment variables via Compose `environment:`/`env_file:` from the table in assessment §1.9: `DATABASE_URL`, `SESSION_SECRET`, `NODE_ENV`, `PUBLIC_URL`, SMTP/email settings, `AUTHENTICATION_SUPPORTED` (+ SSO variables if used), logging variables, `PORT` (design §3.3).
- [ ] Confirm one image is used across all environments — only env-file contents differ (design §3.3).

**Risks (implementation only):**
- The healthy-DB gate narrows but does not fully close the `translation-import-startup-race` window (design §5.1, §5.3) — the residual window is accepted by design, not something to "fix" at this stage; do not patch application code (§5.3).
- Healthcheck `interval`/`timeout`/`retries` values are conservative starting points and may need tuning once real startup timing is observed (design §7).

---

## Phase 4 — `install.ps1` / `install.bat` Automation

**Objective:** Implement the single operator-facing entry point per `deployment-automation-v1.md` §2–§3.

**Deliverables:**
- `install.ps1` — single linear procedural script, internally decomposed into named functions (e.g. `Test-Prerequisites`, `Build-Image`, `Start-Stack`, `Test-Deployment`).
- `install.bat` — thin launcher only.

**Prerequisites:**
- Phase 3 complete (Compose stack functions correctly when invoked directly).

**Exit Criteria:**
- Executing `install.ps1` against the `dts_shared_binary` release artifact produces a working deployment (design §9, in full — verified in Phase 5).
- `install.bat` contains no deployment logic beyond invoking `install.ps1`.

**Checklist:**
- [ ] `Test-Prerequisites`: verify Docker/Docker Compose present, daemon reachable, runtime up (automation §2 step 1).
- [ ] `Build-Image`: run `docker compose build` (automation §2 step 2).
- [ ] `Start-Stack`: run `docker compose up -d` (automation §2 step 3). No separate schema-init step — confirm this is not re-implemented here (automation §2 step 3 note).
- [ ] Wait-for-healthy step: block until both services report healthy per the `depends_on: condition: service_healthy` design (automation §2 step 4).
- [ ] `Test-Deployment`: verify each item in design §9 V1 Success Criteria (automation §2 step 5).
- [ ] Pass/fail reporting: on failure, surface real underlying Docker/Compose output rather than a generic error message (automation §2 step 6).
- [ ] `install.bat`: invokes `powershell.exe -ExecutionPolicy Bypass -File install.ps1`, passing through all arguments, and nothing else (automation §3).
- [ ] Confirm no out-of-scope scripts are introduced: no `stop`/`restart`/`logs`/`shell-app`/`shell-db`/`backup`/`restore`/`upgrade` scripts, no shared PowerShell module, no step-registry/plugin/templating mechanism (automation §4).

**Risks (implementation only):**
- Health-check wait logic needs a bounded timeout with clear failure reporting — an indefinite wait is an implementation bug, not a design gap.
- Surfacing "real underlying Docker/Compose output" (automation §2 step 6) requires care not to swallow stderr/stdout from child processes.

---

## Phase 5 — V1 Verification Against Success Criteria

**Objective:** Verify all nine items of `docker-containerization-design.md` §9 hold end-to-end when `install.ps1` is executed against the `dts_shared_binary` artifact. This phase is verification only — it introduces no new checks beyond §9.

**Deliverables:**
- A verification pass confirming each of the 9 criteria below, run against a real execution of `install.ps1`.

**Prerequisites:**
- Phase 4 complete (`install.ps1`/`install.bat` implemented).
- A TLS-terminating front end available for criterion 7 (design §8 `secure-cookie-https` — this project does not ship one; it must be provided by the test environment, consistent with the documented V1 limitation).

**Exit Criteria (verbatim from design §9 — this phase adds no new criteria):**
- [ ] 1. The Docker image builds successfully from the artifact.
- [ ] 2. The `db` service initializes PostgreSQL/PostGIS and reports healthy.
- [ ] 3. The `app` service starts only after `db` is healthy, and itself reports healthy.
- [ ] 4. `dts_system_info.version_no` is present and matches the artifact's `package.json` version.
- [ ] 5. The automatic content-locale import completes without error on first boot (`last_translation_import_at` is set).
- [ ] 6. The application's own internal configuration validation reports zero errors.
- [ ] 7. DELTA is reachable, and the login flow works correctly when accessed through the environment's TLS-terminating front end.
- [ ] 8. Uploaded files and database contents survive a `docker compose down` / `up` cycle intact.
- [ ] 9. Re-running `install.ps1` against an already-successful deployment behaves safely (no data loss, no duplicate schema load).

**Checklist:**
- [ ] Run `install.ps1` on a clean environment and confirm criteria 1–7 in sequence.
- [ ] Perform a `docker compose down` / `up` cycle and confirm criterion 8.
- [ ] Re-run `install.ps1` against the already-successful deployment and confirm criterion 9.
- [ ] Record results against each criterion (pass/fail with evidence), not just an overall pass/fail.

**Risks (implementation only):**
- Testing criterion 7 without a TLS front end will produce the documented failure mode (login does not persist) — this is expected per §8 and must not be misdiagnosed as a defect.
- Criterion 9 (safe re-run) depends on Postgres's empty-data-directory init convention behaving as expected on a non-empty volume — verify explicitly rather than assuming.

---

## Phase 6 — V1 Release Readiness

**Objective:** Close out Roadmap "Phase 1 — Working Deployment" (design §11) once Phase 5 verification passes in full.

**Deliverables:**
- Final release bundle: `install.ps1`, `install.bat`, `Dockerfile`, `docker-compose.yml`, env-file template.
- A short operator-facing note (or README section) stating the documented V1 limitation from design §8 (`secure-cookie-https`) in plain terms, so operators know a TLS-terminating front end is required for login to persist.

**Prerequisites:**
- Phase 5 fully passed (all 9 criteria confirmed).

**Exit Criteria:**
- A fresh-machine execution of `install.ps1` succeeds without any manual intervention beyond providing the env-file.
- Every item in design §10 (Out of Scope) remains genuinely unimplemented — no scope crept in during Phases 1–5.
- Design §9 is satisfied in full, per Phase 5's recorded results.

**Checklist:**
- [ ] Fresh-machine (or fresh-VM) run of `install.ps1` from the release bundle, start to finish.
- [ ] Confirm Out-of-Scope boundary (design §10) was not silently expanded during implementation.
- [ ] Publish the operator-facing TLS/front-end note.
- [ ] Tag/record this as the completion of Roadmap Phase 1 (design §11).

**Risks (implementation only):**
- Scope creep risk: any convenience script or abstraction added "while we're in there" during Phases 1–5 must be rejected or routed back to `docker-containerization-design.md` before this phase closes (per Design Principles — rule of three, no premature abstraction).
- Operator misunderstanding of the `secure-cookie-https` limitation is a support-burden risk, not a functional defect — mitigated only by the documentation deliverable above.

---

## Phase 7 — Operational Confidence (Not Yet Scheduled)

Per `docker-containerization-design.md` §11 Roadmap, Phase 2 ("Operational Confidence") **begins only after Phase 1 has real operational experience behind it** and is explicitly **not designed yet**. It is listed here only as a placeholder so this tracking document reflects the full roadmap; it is deliberately left without Objective/Deliverables/Prerequisites/Exit Criteria/Checklist/Risks detail, since populating those would mean designing architecture that does not yet exist.

Candidate scope, per design §11: backup/restore automation, upgrade automation, additional operator convenience scripts. What (if anything) becomes a shared/reusable component is decided from duplication that actually appears, not designed in advance.

**Do not begin detailed planning of this phase until `docker-containerization-design.md` is amended to record its design** — consistent with this document's charter of implementing, not extending, the approved architecture.

---

*This document tracks implementation of the architecture approved in `docker-containerization-design.md` and `deployment-automation-v1.md`. It introduces no new architecture, technology choices, or scope. Any gap discovered during execution is routed back to `docker-containerization-design.md` for a decision before implementation proceeds.*

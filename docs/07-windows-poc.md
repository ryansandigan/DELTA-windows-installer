# Windows Proof of Concept

**Status:** Runbook. This is the sequence that, once executed, converts the findings in [05 — Compatibility Assessment](05-windows-compatibility-assessment.md) from static analysis into operational fact. As of this writing it has **not** been executed — the summary line at the end of [05](05-windows-compatibility-assessment.md#summary) is the honest current state.
**Target:** Windows Server 2022, Node.js 24.x, PostgreSQL + PostGIS, Nginx for Windows.
**Related:** [02 — Windows Deployment](02-windows-installation.md) *(full reference detail for each step)* · [06 — Deployment Risks](06-deployment-risks.md)

This document is deliberately lean — it is a checklist to execute, not a reference to read. Every step links back to [02](02-windows-installation.md) for the "why" and the full command reference; nothing here is explained twice.

---

## Procedure

1. **Install PostgreSQL for Windows.**
   EDB distribution. Confirm with `psql --version`.

2. **Install PostGIS via Stack Builder**, against the PostgreSQL instance from step 1.
   Confirm with `psql -c "SELECT postgis_version();"` against a scratch database. See [06 #6](06-deployment-risks.md#postgis-installation) for why this can't be skipped or deferred.

3. **Install Node.js 24.x (Windows x64).**
   Confirm with `node -v` and `npm -v` in a fresh shell.

4. **Unpack the artifact and install dependencies.**
   Run `init_website.bat` per [02 §Running the installer scripts](02-windows-installation.md#running-the-installer-scripts). Immediately verify `where dotenv` succeeds in a **new** shell — this is the specific gap flagged in [06 #3](06-deployment-risks.md#installation-tooling-gaps); do not proceed past this step assuming it worked.

5. **Initialize the database.**
   Run `init_db.bat` per [02 §Running the installer scripts](02-windows-installation.md#running-the-installer-scripts) / [04 — Database](04-database.md#initialization-fresh-install). Record whether the target cluster's default encoding was UTF-8 — this is currently unverified in general (see [06 #4](06-deployment-risks.md#utf-8-and-locale-at-database-creation)) and this is the first opportunity to observe it directly.

6. **Configure the environment.**
   Create `.env` per [02 §Environment variables](02-windows-installation.md#environment-variables). At minimum: `DATABASE_URL`, `SESSION_SECRET`, `NODE_ENV=production`, `PUBLIC_URL` (the externally-visible HTTPS host, not the internal Node address).

7. **Start the application.**
   Run `start.bat` per [02 §Smoke test](02-windows-installation.md#smoke-test). Confirm the process boots, connects to PostgreSQL, and serves a response on the configured port before proceeding.

8. **Configure the Windows Service.**
   Follow [02 §Windows Service installation](02-windows-installation.md#windows-service-installation) exactly — wrap `node.exe` directly, not `start.bat`. Do not skip the shutdown-behavior check in the validation checklist below.

9. **Configure Nginx.**
   Follow [02 §Reverse proxy configuration](02-windows-installation.md#reverse-proxy-configuration). This step is not optional — see the warning in that section about `Secure` cookies and plain HTTP.

10. **Run the validation checklist below.**

## Validation checklist

Each row closes a specific open item from [05](05-windows-compatibility-assessment.md) or [06](06-deployment-risks.md) — check the item, not just "does the app load."

| Check | Confirms | Reference |
|---|---|---|
| App loads through the Nginx URL, not the raw Node port | Reverse proxy config is correct | [02 §Reverse proxy configuration](02-windows-installation.md#reverse-proxy-configuration) |
| Login persists across a page reload | Session cookie `Secure` flag + HTTPS termination are both working together | [05 §Reverse proxy compatibility](05-windows-compatibility-assessment.md#reverse-proxy-compatibility) |
| A file upload writes to and is retrievable from `uploads\` | Filesystem path handling works under the service's actual working directory | [02 §Windows Service installation](02-windows-installation.md#windows-service-installation) |
| `logs\dts-*.log` is being written and rotates | Winston logging + `LOG_DIR` resolution work under the service context | [01 — Runtime Architecture](01-runtime-architecture.md) |
| Stopping the service via its normal stop command, then checking the log, shows the cleanup handler ran | Graceful shutdown actually fires under NSSM/WinSW — **the single biggest open unknown in this whole assessment** | [06 #5](06-deployment-risks.md#windows-service-shutdown-behavior) |
| Restarting the service after a simulated crash brings the app back automatically | Restart policy is correctly configured | [02 §Windows Service installation](02-windows-installation.md#windows-service-installation) |
| A non-ASCII value (e.g. an accented or Arabic test string) round-trips correctly through a form save | Database encoding/locale is actually UTF-8, not just assumed | [06 #4](06-deployment-risks.md#utf-8-and-locale-at-database-creation) |
| `where dotenv` succeeds in a fresh shell after installation | PATH gap in `init_website.bat` either doesn't manifest or has been patched | [06 #3](06-deployment-risks.md#installation-tooling-gaps) |

## After this runs once

Update [05 — Compatibility Assessment §Summary](05-windows-compatibility-assessment.md#summary) to reflect which findings moved from Inferred/Recommended to Verified as a result of this execution, and update [06 — Deployment Risks](06-deployment-risks.md) to close out any row whose mitigation was applied and confirmed. This runbook's value is in producing that update — treat a completed run that doesn't feed back into those two documents as unfinished.

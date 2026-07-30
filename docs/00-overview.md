# DELTA — Documentation Overview

**Status:** Primary documentation set.
**Supersedes:** The Docker-first deployment documentation previously at the top level of `docs/` has been archived, unmodified, under [`docs/parked/`](parked/). This series replaces it as the primary reference. See [§ Relationship to the archived Docker design](#relationship-to-the-archived-docker-design) below.
**Subject artifact:** `dts_shared_binary/` (DELTA v0.2.3 production build).

---

## What DELTA is

DELTA is a server-rendered web application for tracking disaster and hazardous-event data, built on **React Router v7** (framework mode) with an **Express**-based Node.js runtime, backed by **PostgreSQL with PostGIS**. It is distributed as a pre-built artifact (`dts_shared_binary`) containing a compiled server bundle, static client assets, database schema/migration SQL, locale files, and operator scripts.

This documentation set describes how to run that artifact — natively on Windows or Linux — without assuming a specific containerization strategy.

## Document index

| # | Document | Covers |
|---|---|---|
| 00 | [Overview](00-overview.md) *(this document)* | Architecture at a glance, supported deployment models |
| 01 | [Runtime Architecture](01-runtime-architecture.md) | React Router, Express, Node.js, PostgreSQL, PostGIS, Nginx — and the distinction between runtime, installation tooling, and deployment tooling |
| 02 | [Windows Deployment](02-windows-installation.md) | Full install/run guide for Windows Server 2022 |
| 03 | [Linux Deployment](03-linux-installation.md) | Equivalent guide for Linux, with Windows deltas called out |
| 04 | [Database](04-database.md) | PostgreSQL, PostGIS, pgcrypto, initialization, upgrades |
| 05 | [Windows Compatibility Assessment](05-windows-compatibility-assessment.md) | Findings from static inspection of the artifact, graded Verified / Inferred / Recommended |
| 06 | [Deployment Risks](06-deployment-risks.md) | Every known open risk and its mitigation |
| 07 | [Windows Proof of Concept](07-windows-poc.md) | A single, sequential runbook for a first Windows Server deployment |
| 08 | [Development Roadmap](08-development-roadmap.md) | Internal engineering tracker for building the Windows deployment tooling itself — phase-by-phase, living document |

## Supported deployment models

| Model | Status | Reference |
|---|---|---|
| **Native Windows Server** | Runtime compatibility established by static analysis; operational validation via a real deployment is still pending. | [02](02-windows-installation.md), [05](05-windows-compatibility-assessment.md), [07](07-windows-poc.md) |
| **Native Linux** | The artifact's own scripts and documentation were originally written for this model; treated here as the reference case. | [03](03-linux-installation.md) |
| **Docker Compose** | A complete design exists but is not this document set's subject — see below. | [`docs/parked/`](parked/) |

Nothing in this series claims that native Windows deployment has been operated in production. **"Runtime-compatible" and "production-proven" are different claims** — this series is careful to keep them distinct; see [05](05-windows-compatibility-assessment.md) for exactly which findings carry which confidence level.

## Runtime vs. installation tooling vs. deployment tooling

A recurring source of confusion in deployment discussions is treating "the application" and "the scripts that install the application" as one thing. They are not, and this documentation set treats them separately throughout:

- **Runtime** — the compiled Node.js/Express server (`build/server/index.js`) and its production dependencies. This is what actually runs, and its Windows compatibility is a property of the code itself, not of any installer.
- **Installation tooling** — the `init_db`/`init_website`/`upgrade_database` scripts (shipped as both `.sh` and `.bat`). These bootstrap a working environment; they are not part of the running application.
- **Deployment tooling** — whatever orchestrates the above for a specific target: a Windows Service wrapper and Nginx config for native Windows, systemd + Nginx for native Linux, or Docker Compose for the containerized path.

[01 — Runtime Architecture](01-runtime-architecture.md) develops this distinction in full; every other document in the series relies on it rather than re-explaining it.

## Relationship to the archived Docker design

`docs/parked/` contains three documents recording a complete, previously-approved Docker Compose deployment design (`docker-containerization-design.md`, `deployment-automation-v1.md`) built on an independent application assessment (`windows-docker-installer-assessment.md`), plus an execution-tracking document (`IMPLEMENTATION-PHASES.md`). That design remains architecturally sound and is not superseded on its own terms — it is parked because this documentation effort's mandate is native deployment, not because the Docker path was found lacking.

Several factual findings in the archived assessment (e.g., the missing `yarn.lock`, the unpinned Node version, the `secure-cookie-https` cookie behavior) are independently confirmed in this series — see [05](05-windows-compatibility-assessment.md) and [06](06-deployment-risks.md) — since they are properties of the application artifact itself, not of any particular deployment target.

If a Docker-based deployment is pursued again, resume from `docs/parked/docker-containerization-design.md` rather than restarting that design from scratch.

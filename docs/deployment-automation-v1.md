# DELTA — Deployment Automation (V1)

**Status:** Approved for implementation.
**Scope:** Implements only the deployment decisions recorded in `docker-containerization-design.md`. **This document introduces no new architecture.** If implementing any part of this reveals a decision not already recorded there, that decision must be added to `docker-containerization-design.md` first — it is not made here, inline, under implementation pressure.
**Design Principles:** governed centrally in `docker-containerization-design.md` — not restated here.
**Primary deliverable:** a single operator-facing entry point, `install.ps1`, with `install.bat` as a thin launcher — consistent with the Windows-first operator experience established for this project.

---

## 1. Scope

The complete V1 objective: given the `dts_shared_binary` release artifact, executing `install.ps1` produces a working DELTA deployment satisfying every item in `docker-containerization-design.md` § V1 Success Criteria.

**This is the only deliverable of V1.** No other operator scripts are designed or built in this phase — see § Out of Scope below, which mirrors and does not duplicate `docker-containerization-design.md` §10.

## 2. `install.ps1` Pipeline

A single, linear, procedural script. Internal decomposition into named functions (e.g. `Test-Prerequisites`, `Build-Image`, `Start-Stack`, `Test-Deployment`) is ordinary code hygiene, not the kind of abstraction this project avoids — those functions live inside `install.ps1` itself, not in a shared module, since there is no second script yet to share them with (Design Principles: rule of three).

Each step implements a decision already recorded in `docker-containerization-design.md` — this section does not restate the "why," only the sequence:

1. **Validate prerequisites** — Docker/Docker Compose present, daemon reachable, runtime up.
2. **Build the application image** — `docker compose build`, per §2 of the design.
3. **Bring up the stack** — `docker compose up -d`, per §3–§4. Schema initialization on `db` happens automatically via `docker-entrypoint-initdb.d` on first start; no separate step is needed.
4. **Wait for both services to report healthy** — per §5/§7's healthcheck and `depends_on: condition: service_healthy` design.
5. **Verify the deployment** against each item in § V1 Success Criteria: schema version matches the artifact, locale import completed, application config validation reports zero errors, the app is reachable.
6. **Report pass/fail clearly** — on failure, surface the real underlying Docker/Compose output rather than a generic error message.

## 3. `install.bat`

A thin launcher only: invokes `powershell.exe -ExecutionPolicy Bypass -File install.ps1`, passing through any arguments. Contains no deployment logic of its own — any behavior beyond "launch the PowerShell script" belongs in `install.ps1`, not here.

## 4. Out of Scope for V1 Automation

No other operator scripts are designed or built in this phase:

- `stop`, `restart`, `logs`, `shell-app`, `shell-db` convenience scripts
- `backup`, `restore`, `upgrade` automation
- Any shared PowerShell module — there is exactly one script; a shared module has no second consumer yet
- Any generic step-registry, plugin, or templating mechanism

These may be designed later, from actual operational experience, per `docker-containerization-design.md` § Roadmap. They are not implicit requirements of this document.

---

*This document implements decisions recorded in `docker-containerization-design.md`. It records no new architecture.*

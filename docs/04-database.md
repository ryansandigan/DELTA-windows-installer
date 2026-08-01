# Database

**Status:** Conceptual + procedural reference, platform-independent. Windows- and Linux-specific installer steps live in [02](02-windows-installation.md) and [03](03-linux-installation.md); this document covers what's true regardless of OS.
**Related:** [01 — Runtime Architecture](01-runtime-architecture.md) · [06 — Deployment Risks](06-deployment-risks.md#utf-8-and-locale-at-database-creation)

---

## Required components

| Component | Version basis | Required? |
|---|---|---|
| PostgreSQL | Schema was dumped from **16.6** (`dts_database/dts_db_schema.sql:5-6`) | Yes |
| PostGIS | `CREATE EXTENSION IF NOT EXISTS postgis` (`dts_db_schema.sql:37`) | Yes — see below |
| pgcrypto | `CREATE EXTENSION IF NOT EXISTS pgcrypto` (`dts_db_schema.sql:23`) | Yes — bundled with core PostgreSQL, no extra install |

No other extensions appear anywhere in the schema.

## Why PostGIS is mandatory

This is not a defensive dependency or a leftover from an earlier design — the schema defines real spatial columns:

```sql
geom public.geometry(Geometry,4326)   -- dts_db_schema.sql:650
bbox public.geometry(Geometry,4326)   -- dts_db_schema.sql:651
```

`4326` is WGS 84 (standard latitude/longitude). These columns back the application's mapping features, consistent with the `ol` (OpenLayers) client dependency and the `@turf/*` geometry-processing dependencies in `package.json`. `CREATE EXTENSION` only *registers* an already-installed extension — it cannot install PostGIS itself, so the target PostgreSQL instance must have the PostGIS package present at the OS level before schema initialization runs. This applies identically on Windows and Linux.

## Connection model

The application connects over plain TCP via a single `DATABASE_URL` connection string, consumed directly by Drizzle ORM (`build/server/index.js:1386`). There is no Unix-domain-socket dependency and no OS-conditional connection logic — `DATABASE_URL` is the only thing that needs to be correct:

```text
DATABASE_URL=postgresql://<user>:<password>@<host>:<port>/<database>
```

The application throws synchronously at startup if `DATABASE_URL` is unset.

## Initialization (fresh install)

Schema initialization is two steps, wrapped by `init_db.sh`/`init_db.bat`:

1. `createdb` — creates an empty database.
2. `psql -f dts_database/dts_db_schema.sql` — loads the full schema dump (extensions, types, functions, tables, and seed/reference data such as hazard taxonomies), and seeds `dts_system_info.version_no` (currently `'0.2.3'`).

Platform-specific invocation (prompts, exact command syntax) is documented in [02 §Database initialization](02-windows-installation.md#database-initialization) and [03 §Database initialization](03-linux-installation.md#database-initialization) — this document covers only what the SQL itself does.

`dts_system_info` is the single source of truth for schema version; the upgrade mechanism reads `version_no` from this table to decide what to apply next.

## Upgrade mechanism

`upgrade_database.sql` is a **self-selecting migration chain**. It reads `version_no` from `dts_system_info` and, for each recognized version, uses `psql`'s `\if`/`\gset` meta-commands to conditionally `\ir` (include relative) the matching incremental SQL file:

| From | To | File |
|---|---|---|
| 0.1.1 | 0.1.3 | `upgrade_from_0.1.2_to_0.1.3.sql` *(filename/version naming mismatch is documented inline in the SQL itself)* |
| 0.1.3 | 0.2.0 | `upgrade_from_0.1.3_to_0.2.0.sql` |
| 0.2.0 | 0.2.1 | `upgrade_from_0.2.0_to_0.2.1.sql` |
| 0.2.1 | 0.2.2 | `upgrade_from_0.2.1_to_0.2.2.sql` |
| 0.2.2 | 0.2.3 | `upgrade_from_0.2.2_to_0.2.3.sql` |

These `\if` meta-commands are interpreted by `psql.exe`/`psql` itself, not by the calling shell — behavior is identical whether invoked from Bash or from `cmd.exe`/PowerShell, since the same binary does the branching either way. This is one of the few pieces of tooling in the artifact that is genuinely OS-agnostic without modification.

`upgrade_database.sql` itself is unmodified and untouched by the installer tooling — `upgrade_database.ps1` (the Windows wrapper `setup.ps1` and standalone operators both invoke) does not trust the chain's own exit code as proof of success. Before running anything, it classifies `dts_system_info.version_no` into one of three outcomes, positively, against two lists audited from this table and from the version `dts_db_schema.sql` seeds (`$Script:DeltaLatestSupportedSchemaVersion` / `$Script:DeltaUpgradableSchemaVersions` in `upgrade_database.ps1`):

- **Already at `0.2.3`** (the latest supported version) — reported as already current; the chain is not run at all.
- **A known upgradable version** (`0.1.1`, `0.1.3`, `0.2.0`, `0.2.1`, `0.2.2`) — the chain runs, and the resulting version is re-read afterward and checked equals `0.2.3` before the upgrade is reported successful. A chain that exits `0` but leaves the database on some other version — a hole in the `\if` chain, for example — is a hard failure, not a silent success.
- **Anything else** — refused outright, with the unrecognized version named in the error. An unrecognized version is never treated as "already current" just because no `\if` branch matched it.

It also distinguishes, before ever trusting `version_no`, whether `$DatabaseName` doesn't exist at all, or exists but was never initialized (`dts_system_info` itself missing) — both fail with a message pointing at `init_db.ps1`, never silently initializing the database itself (that stays `init_db.ps1`'s responsibility only).

**Operational notes, true on both platforms:**

- No down-migrations exist. Rollback is restore-from-backup only.
- `ON_ERROR_STOP=on` halts the script on the first SQL error, but backup before upgrading is a manual, human responsibility — not enforced by any tooling.
- The single-hop step (one version behind, e.g. `0.2.2` → `0.2.3`) and the zero-hop "already current" path (fresh `init_db.ps1` immediately followed by `upgrade_database.ps1`) have both been verified end-to-end against a real PostgreSQL 16 instance. A genuine multi-hop upgrade (e.g. `0.1.1` all the way to `0.2.3`) could **not** be verified end-to-end from this repository alone: only the final, cumulative `dts_db_schema.sql` dump ships here, not a real historical `0.1.1`-era database to upgrade from. Simulating one by taking the current dump and rewriting `version_no` back to `0.1.1` is not equivalent and was confirmed directly to fail (`\ir upgrade_from_0.1.2_to_0.1.3.sql` errors with `type "entity_validation_type" already exists`, since that type is already in the current dump) — this failure is an artifact of the simulation, not evidence the real chain is broken, but it means the multi-hop path genuinely remains unverified. Treat it as something to validate during a rehearsal upgrade against a real old backup, not an assumption. See [06](06-deployment-risks.md).

## Authentication

Both `init_db` and `upgrade_database` scripts prompt for a username and use `psql -W` (force password prompt) rather than relying on trust/peer authentication. Since the application and scripts always connect over TCP with an explicit host (never falling back to a local Unix socket), this behaves identically on Windows PostgreSQL and Linux PostgreSQL installations — neither depends on POSIX-only authentication mechanisms.

## UTF-8 and locale

Neither `init_db.sh` nor `init_db.bat` passes `-E UTF8` or `--locale` to `createdb` — the new database silently inherits whatever encoding/locale the PostgreSQL cluster's `template1` was initialized with. `dts_db_schema.sql` itself sets `SET client_encoding = 'UTF8';` at the top of the dump, but that governs only the *restore session's* encoding, not the encoding the database was actually created with.

This matters because DELTA ships UI and content locale files for Arabic, Chinese, Russian, and Serbian (`locales/app/{ar,zh,ru,sr}.json`) alongside English, French, and Spanish — non-English deployments are an expected use case, not an edge case. If the target cluster's default isn't UTF-8, multi-byte content can be silently corrupted or fail to write. This risk is identical on Windows and Linux; see [06 — UTF-8 and locale at database creation](06-deployment-risks.md#utf-8-and-locale-at-database-creation) for the recommended mitigation.

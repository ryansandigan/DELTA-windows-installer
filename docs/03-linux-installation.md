# Linux Deployment

**Status:** Procedural guide. This is the platform the artifact's own scripts and `README.md` were originally written for — treated here as the reference case that [02 — Windows Deployment](02-windows-installation.md) is compared against.
**Related:** [01 — Runtime Architecture](01-runtime-architecture.md) · [04 — Database](04-database.md) · [05 — Compatibility Assessment](05-windows-compatibility-assessment.md)

---

## Prerequisites

| Requirement | Notes |
|---|---|
| A current Linux distribution | Debian/Ubuntu or RHEL-family both work; package manager commands below use `apt` as the example. |
| Node.js 24.x | Same caveat as Windows — no version is pinned by the artifact, validate before treating any specific build as final. |
| PostgreSQL 16.x | Distribution package or the PostgreSQL project's own apt/yum repository. |
| PostGIS extension package | E.g. `postgresql-16-postgis-3` on Debian/Ubuntu — a separate package install, same requirement as Windows. See [06 #6](06-deployment-risks.md#postgis-installation). |
| Nginx | Distribution package. |
| A process supervisor | `systemd` is the natural choice on any modern distribution; no third-party tool needed (unlike Windows, which has no first-party equivalent — see [§Differences from Windows](#differences-from-windows)). |

## Installation order

Identical sequence to [Windows §Installation order](02-windows-installation.md#installation-order), substituting `.sh` scripts for `.bat` and `systemd` for NSSM/WinSW:

1. Install Node.js 24.x.
2. Install PostgreSQL and PostGIS.
3. Unpack the `dts_shared_binary` artifact.
4. Run `init_website.sh`.
5. Run `init_db.sh`.
6. Create and populate `.env`.
7. Smoke-test with `start.sh`.
8. Create and start a systemd unit.
9. Install and configure Nginx.
10. Validate.

## Running the installer scripts

```bash
chmod +x init_website.sh init_db.sh
./init_website.sh
./init_db.sh
```

`init_website.sh` installs Yarn globally (`npm install --global --force yarn`), runs `yarn install --production`, and installs `dotenv-cli` globally, explicitly adding Yarn's own global bin (`$HOME/.yarn/bin`) to `PATH` for the current session. Per [05](05-windows-compatibility-assessment.md#existing-windows-tooling), this script is the one the Windows `.bat` version was diffed against and found to diverge from — the Linux version is the correct reference behavior for the `--force` flag and PATH target.

`init_db.sh` prompts for host, port, database name, and username, then runs `createdb` followed by `psql -f dts_database/dts_db_schema.sql`. As on Windows, no encoding/locale flags are passed — see [06 — UTF-8 and locale](06-deployment-risks.md#utf-8-and-locale-at-database-creation), which applies identically here. Full schema detail: [04 — Database](04-database.md).

## Environment variables

Same variable set as Windows — see [05 — Environment variable compatibility](05-windows-compatibility-assessment.md#environment-variable-compatibility) for the full reference. `.env` in the install root:

```env
DATABASE_URL=postgresql://<user>:<password>@localhost:5432/<database>
SESSION_SECRET=<random-secret>
NODE_ENV=production
PUBLIC_URL=https://<externally-visible-host>
LOG_DIR=logs
```

`HOSTNAME` does not need to be set explicitly on Linux — most shells populate it automatically, unlike Windows (see [06 #9](06-deployment-risks.md#hostname-log-field)).

## Smoke test

```bash
./start.sh
```

Wraps `dotenv -e .env -- yarn start`, same as the Windows path — `react-router-serve ./build/server/index.js` under the hood, with no platform-conditional behavior.

## Running as a systemd service

```ini
# /etc/systemd/system/delta.service
[Unit]
Description=DELTA application
After=network.target postgresql.service

[Service]
Type=simple
WorkingDirectory=/opt/delta
EnvironmentFile=/opt/delta/.env
ExecStart=/usr/bin/node node_modules/@react-router/serve/dist/cli.js ./build/server/index.js
Restart=on-failure
StandardOutput=append:/opt/delta/logs/service-out.log
StandardError=append:/opt/delta/logs/service-err.log

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now delta
```

## Reverse proxy configuration

Identical requirement and identical Nginx configuration shape to [Windows §Reverse proxy configuration](02-windows-installation.md#reverse-proxy-configuration) — the application's header-based IP detection and `NODE_ENV`-driven cookie security make it agnostic to which OS Nginx runs on:

```nginx
server {
    listen 443 ssl;
    server_name delta.example.org;

    ssl_certificate     /etc/nginx/certs/delta.crt;
    ssl_certificate_key /etc/nginx/certs/delta.key;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

The same warning applies: without HTTPS in front of the app, `NODE_ENV=production`'s `Secure` cookie flag will silently break login persistence.

## Differences from Windows

| Aspect | Linux | Windows | Notes |
|---|---|---|---|
| Signal-based graceful shutdown | `SIGTERM` is a real POSIX signal; systemd delivers it directly and the app's cleanup handler fires reliably. | Windows has no native SIGTERM; NSSM/WinSW emulate it, with caveats. | See [06 #5](06-deployment-risks.md#windows-service-shutdown-behavior) — this is the one area where the two platforms genuinely diverge in behavior, not just tooling syntax. |
| Process supervision | `systemd` is a first-party OS component. | Requires a third-party tool (NSSM or WinSW). | Neither is part of the application; both are deployment tooling per [01](01-runtime-architecture.md#runtime-vs-installation-tooling-vs-deployment-tooling). |
| Installer script correctness | Reference/baseline behavior — fully quoted, uses `--force`, targets the correct PATH. | Diverges in several places from the `.sh` scripts it was ported from. | Full list: [06 #2](06-deployment-risks.md#installation-tooling-gaps). |
| `HOSTNAME` env var | Populated automatically. | Not populated; must be set explicitly. | Cosmetic, log metadata only — [06 #9](06-deployment-risks.md#hostname-log-field). |
| Everything else (runtime, dependencies, database, reverse proxy behavior) | Identical | Identical | Per [05 — Compatibility Assessment](05-windows-compatibility-assessment.md), the application itself has no Linux-only dependency to begin with. |

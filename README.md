# DELTA Windows Installer

## TL;DR (Quick Start)

You have a fresh Windows Server or Windows 11 VM. Here's the whole process:

1. Download the latest release ZIP from the [Releases page](https://github.com/ryansandigan/DELTA-windows-installer/releases).
2. **Unblock the ZIP** before extracting it (right-click → Properties → check **Unblock** → Apply).
3. Extract the archive.
4. Open **PowerShell as Administrator**.
5. Run `setup.ps1`.
6. Follow the installer prompts (application directory, database credentials, etc.).
7. When offered, optionally configure a reverse proxy — **NGINX** or **IIS**.
8. Browse to the DELTA URL shown in the installation summary.

```powershell
cd DELTA-windows-installer
.\setup.ps1
```

That's it. Everything else in this document is reference material — see [Before You Begin](#before-you-begin) if step 2 needs more explanation, or [Installation Workflow](#installation-workflow) for what `setup.ps1` actually does.

## Overview

This repository contains the Windows installer for [DELTA](https://github.com/PreventionWeb/delta), a server-rendered web application for tracking disaster and hazardous-event data. **It is not the DELTA application itself** — it is a bootstrap installer that automates the installation, configuration, and deployment of DELTA on Windows.

The installer is intentionally lightweight. Large runtime components — the Node.js runtime, PostgreSQL, PostGIS, and the DELTA application artifact itself — are downloaded during installation rather than bundled into the repository or its release packages.

See [Supported Platforms](#supported-platforms) for validated operating systems.

## Before You Begin

> **Windows may block the installer scripts immediately after you download and extract the release ZIP.** This is expected Windows security behavior, not a bug in the installer — unblock the ZIP before extracting it, as described below.

Download the latest official release from the [Releases page](https://github.com/ryansandigan/DELTA-windows-installer/releases). Always download the **release ZIP** (e.g. `DELTA-windows-installer-<version>.zip`) from that page — not the repository's "Source code (zip)" download — since only the release ZIP contains the packaged, production-ready installer.

Windows marks files downloaded from the Internet — including ZIP files downloaded from GitHub or other Internet sources — with a hidden **Mark of the Web** (a `Zone.Identifier` marker). As a result, PowerShell may refuse to run the installer scripts under the default `RemoteSigned` execution policy once the ZIP has been extracted.

Unblock the ZIP **before** extracting it:

1. Right-click the downloaded ZIP.
2. Select **Properties**.
3. Check **Unblock**.
4. Click **Apply**.
5. Extract the ZIP.
6. Run `setup.ps1`.

> Windows adds a "Mark of the Web" (`Zone.Identifier`) to files downloaded from the Internet. If the ZIP is extracted before being unblocked, PowerShell may prevent unsigned scripts from running under the default `RemoteSigned` execution policy. Unblocking the ZIP before extraction removes this mark from the extracted files — without changing PowerShell's execution policy or disabling any Windows security feature.

> **Note:** Unblocking only needs to be done once for each downloaded release ZIP. Files extracted from an already-unblocked ZIP do not need to be unblocked individually.

If PowerShell still refuses to run the scripts after unblocking (for example, on a machine whose execution policy is more restrictive than `RemoteSigned`), run this once as Administrator:

```powershell
Set-ExecutionPolicy RemoteSigned
```

## Features

- Automated, scripted installation via a single entry point (`setup.ps1`)
- Automatic acquisition and update-checking of the DELTA runtime artifact (`dts_shared_binary`) against the DELTA GitHub Releases API
- Node.js installation
- PostgreSQL installation, including detection and optional reuse of an existing instance
- PostGIS installation for the target PostgreSQL instance
- DELTA runtime deployment to a configurable application directory
- Environment configuration (`.env` generation from `.env.example`)
- Database initialization
- Optional native reverse proxy configuration (NGINX or IIS) in front of DELTA
- Administrator password reset for an existing DELTA installation, without a full reinstall
- Database upgrade utility for existing DELTA installations
- Diagnostic and repair utility for an existing reverse proxy configuration
- Uninstall utility for the prerequisites installed by `setup.ps1`
- Idempotent installation steps — safe to run `setup.ps1` more than once against the same machine

## Supported Platforms

| Operating System | Status | Intended Use |
|---|---|---|
| Windows Server 2025 | Supported | Production |
| Windows Server 2022 | Supported | Production |
| Windows 11 | Supported | Development, testing, proof-of-concept |

Only the platforms listed above have been validated. Other Windows versions and editions are not currently supported.

## Repository Structure

| Path | Purpose |
|---|---|
| `setup.ps1` | Main installation orchestrator. Coordinates Node.js, PostgreSQL, and PostGIS installation, DELTA runtime deployment, environment configuration, and database initialization. Also offers administrator password reset for an existing installation. |
| `setup-nginx.ps1` | Installs and configures NGINX as an optional reverse proxy for DELTA. Runs standalone, or from the prompt `setup.ps1` offers after a first-time installation. |
| `setup-iis.ps1` | Installs and configures Microsoft IIS as an optional reverse proxy for DELTA, for administrators who standardize on IIS instead of NGINX. |
| `doctor.ps1` | Diagnoses and repairs an existing DELTA deployment's reverse proxy configuration (IIS or NGINX) without requiring an uninstall/reinstall cycle. |
| `init_db.ps1` | Creates the DELTA database and restores its schema against an existing PostgreSQL/PostGIS installation. Can be run standalone or invoked by `setup.ps1`. |
| `upgrade_database.ps1` | Applies the DELTA SQL upgrade chain to an existing DELTA database. Can be run standalone or invoked by `setup.ps1`. |
| `uninstall.ps1` | Removes the prerequisites installed by `setup.ps1` (Node.js, PostgreSQL, PostGIS). Does not remove the deployed DELTA runtime or its database unless explicitly instructed. |
| `lib/` | Shared PowerShell helper functions used by every script above. |
| `templates/` | Configuration templates (IIS `web.config`, NGINX site/config files) used by `setup-iis.ps1` and `setup-nginx.ps1` when configuring a reverse proxy. |
| `docs/` | Technical documentation covering runtime architecture, installation procedures, database management, and deployment considerations. |
| `.env.example` | Template for the DELTA application's environment configuration, used to generate `.env` during installation. |

Two directories are populated automatically by `setup.ps1` at install time and are not part of the repository's tracked content:

| Path | Purpose |
|---|---|
| `installers/` | Downloaded installer binaries for Node.js, PostgreSQL, and PostGIS. |
| `dts_shared_binary/` | The DELTA runtime artifact, downloaded from the DELTA GitHub Releases API and later deployed to the target application directory. |

Both directories are excluded from GitHub release packages and from version control.

## Prerequisites

- Administrator privileges on the target machine
- Internet connectivity, to download runtime components during installation
- PowerShell 5.1 or later
- A supported Windows version (see [Supported Platforms](#supported-platforms))

## Installation Workflow

```
Run setup.ps1
      │
      ▼
Validate environment
      │
      ▼
Download runtime components
      │
      ▼
Install Node.js
      │
      ▼
Install PostgreSQL
      │
      ▼
Install PostGIS
      │
      ▼
Deploy DELTA
      │
      ▼
Generate configuration
      │
      ▼
Start and verify DELTA
      │
      ▼
Installation summary
      │
      ▼
Configure a reverse proxy? (optional, first-time install only)
      │
      ├── NGINX
      ├── IIS
      └── Skip
      │
      ▼
DELTA ready to use
```

`setup.ps1` is designed to be safe to run more than once: steps that are already satisfied (a component already installed, a database already present) are detected and skipped or handled interactively rather than repeated blindly.

The reverse proxy prompt only appears immediately after a first-time installation completes — an Update or Reinstall skips it, since a reverse proxy may already be configured. To configure, change, or repair a reverse proxy afterward, run `setup-nginx.ps1`, `setup-iis.ps1`, or `doctor.ps1` directly.

## Additional Utilities

Beyond the installation workflow above, the following scripts can be run independently at any time:

| Script | Purpose |
|---|---|
| `setup-nginx.ps1` | Installs, configures, or manages an NGINX reverse proxy in front of DELTA. |
| `setup-iis.ps1` | Installs, configures, or manages an IIS reverse proxy in front of DELTA. |
| `doctor.ps1` | Diagnoses reverse proxy configuration issues on an existing deployment and offers to repair them. |
| `init_db.ps1` | Initializes the DELTA database — creates the database and loads its schema against an existing PostgreSQL/PostGIS installation. |
| `upgrade_database.ps1` | Upgrades an existing DELTA database by applying the application's SQL upgrade chain. |
| `uninstall.ps1` | Removes the components `setup.ps1` installs (Node.js, PostgreSQL, PostGIS) from the machine. |

Forgot the DELTA administrator password? No need to run any of these — `setup.ps1` itself offers a **Reset administrator password** option whenever it detects an existing installation.

## Release Philosophy

GitHub Releases for this repository contain only the installer itself — the PowerShell scripts and supporting library code. Large runtime payloads (the Node.js, PostgreSQL, and PostGIS installers, and the DELTA runtime artifact) are intentionally excluded and are instead downloaded during installation. This keeps releases small while ensuring the components installed are current at install time.

Maintainers cut a release by running `.\release.ps1`, which bumps the installer version and pushes a `vX.Y.Z` tag; that tag push triggers GitHub Actions to build and publish the release ZIP via `tools\build-release.ps1`.

## Documentation

Additional technical documentation, including runtime architecture, platform-specific installation procedures, and database management, is available under [`docs/`](docs/).

## License

Licensing information for this repository has not yet been finalized. This section will be updated once a license is selected.

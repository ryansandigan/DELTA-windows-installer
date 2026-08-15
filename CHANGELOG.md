# Changelog

All notable changes to the DELTA Windows Installer will be documented in this file.

## [Unreleased]

### Added

- DELTA now runs as a Windows Service (`DeltaApp`) and starts automatically after a reboot, with no interactive login required. Logging out or disconnecting an RDP session no longer stops DELTA. Startup type is `Automatic` — DELTA begins starting as soon as Windows can start it, with startup ordering handled by its PostgreSQL service dependency and its bounded restart policy rather than by a deliberate delay.
- The service supervises DELTA and restarts it automatically if it crashes, with bounded, escalating retries so a persistent failure stops rather than looping forever.
- The management menu now reports the service state alongside DELTA's own process, port, and readiness evidence, and its Start / Stop / Restart controls operate through the service.
- An existing DELTA deployment whose Windows Service is missing, damaged, or misconfigured is now detected and repaired automatically. No manual `sc.exe` cleanup, and no need to choose "Update DELTA", just to obtain the service.
- Dependency installers are now reused from neighbouring installer directories instead of being downloaded again. When a required file is missing from `installers\`, setup checks the `installers\` directory of every folder sitting beside this one — whatever those folders are named — for that exact filename, and copies it in automatically. Only an exact filename match is accepted, so pinned versions are unaffected, and a copy that fails a component's checksum is discarded in favour of the normal download. Keeping a previous unpacked release beside the current one is now enough to avoid re-downloading the ~350 MB PostgreSQL installer. Applies to Node.js, PostgreSQL, PostGIS, NGINX, the IIS reverse-proxy components, and the WinSW service wrapper.

### Changed

- The service runs `node.exe` directly and loads `.env` through Node's own `--env-file`, replacing the previous `cmd.exe` → `dotenv` → `yarn` launch chain. `start.bat` remains available for manual troubleshooting.
- The service runs under the least-privileged virtual account `NT SERVICE\DeltaApp` rather than an administrator or `LocalSystem`, with only the file access DELTA actually needs.
- Existing installations are migrated automatically the next time `setup.ps1` runs; no manual cleanup is required. A missing service is repaired in place — the application, its dependencies, its configuration, and the database are not redeployed or modified, and a running DELTA is only restarted after you confirm.
- A service that a previous uninstall deliberately stopped and disabled is now recognised as such and re-enabled only after confirmation, so an intentional "do not run" is never silently overturned.

### Fixed

- `.env` and its timestamped backups are no longer readable by ordinary local users. They contain the database password, session secret, and SMTP credentials, and previously inherited read access for `BUILTIN\Users`.
- DELTA initialization now uses a 300-second Yarn network timeout when installing dependencies, replacing Yarn's 30-second default, so a slow or unstable connection to the package registry no longer fails the installation with `ESOCKETTIMEDOUT`. This applies for the duration of that step only, and `init_website.bat` itself is unchanged.

## [1.0.12]

### Changed

- The generated `.env` now defaults `PUBLIC_URL` to `http://localhost:3000`, matching the default `PORT`, so a fresh installation is usable immediately without editing configuration. Set `PUBLIC_URL` to the externally-visible address before exposing DELTA publicly.
- When the installer has to move DELTA onto a different backend port, it now keeps that localhost `PUBLIC_URL` in step with the new port. A `PUBLIC_URL` that has been customized — a public domain, any `https://` address, or any other non-default value — is never rewritten, and existing installations keep their configuration on update.

### Fixed

- Improved DELTA startup verification to prevent false setup failures during longer first-run initialization.

### Added

- Added DELTA Start, Stop, and Restart controls to the management menu.
- Added DELTA Access Guide with local application, administrator, and user login URLs.
- Added Email / SMTP configuration with support for `file` and `smtp` transports.
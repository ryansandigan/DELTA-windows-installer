# Changelog

All notable changes to the DELTA Windows Installer will be documented in this file.

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
# Changelog

All notable changes to the DELTA Windows Installer will be documented in this file.

## [1.0.12]

### Added

- Added DELTA Start, Stop, and Restart controls to the management menu.
- Added runtime status and configured application port display.
- Added DELTA Access Guide with local application, administrator, and user login URLs.
- Added Email / SMTP configuration with support for `file` and `smtp` transports.

### Changed

- Improved DELTA startup readiness handling for slower first-run initialization.
- Improved runtime and port ownership checks to avoid conflicts with unrelated processes.
- Improved `.env` handling for quoted values and inline comments.

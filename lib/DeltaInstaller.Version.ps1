<#
.SYNOPSIS
    Single source of truth for the DELTA Windows Installer's own version
    (the installer, not the DELTA application it deploys).

.DESCRIPTION
    Dot-sourced by entry-point scripts that need to display or reason
    about the installer's version - today just setup.ps1, but any other
    entry point (uninstall.ps1, init_db.ps1, upgrade_database.ps1) can
    dot-source it the same way lib\DeltaInstaller.Common.ps1 already is,
    without duplicating the value. A plain dot-sourced variable file, not
    a .psm1/.psd1 module, for the same reason lib\DeltaInstaller.Common.ps1
    is one - see that file's own header.

    This value is maintained by hand, not derived from git. It must be
    bumped in the same commit that prepares a release, to match the
    "vX.Y.Z" tag tools/build-release.ps1 is later invoked against by
    .github/workflows/release.yml - the two are not wired together
    automatically, so keeping them in sync is a release-checklist step,
    not something this file enforces on its own.

    lib\ is copied into every release package as-is (see
    tools/build-release.ps1's $Script:RequiredDirectories) - placing the
    version here, rather than at the repository root, means it ships
    inside the release ZIP automatically, with no packaging-script
    changes required to keep it there.
#>

$Script:DeltaInstallerVersion = '1.0.0'

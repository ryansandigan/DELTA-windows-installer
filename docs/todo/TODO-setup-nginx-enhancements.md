# TODO - setup-nginx.ps1 Enhancements

## Overview

The initial implementation of `setup-nginx.ps1` successfully installs and configures NGINX for DELTA.

The following enhancements are planned to improve flexibility, support custom installation locations, and provide a better administrator experience.

Phases are implemented one at a time, in order. Do not start a phase before the previous one is marked Completed below.

---

## Status

| Phase | Description | Status |
|-------|--------------|--------|
| 1 | Use Shared DELTA Installation Discovery | Completed |
| 2 | SSL Certificate Wizard | Completed |
| 3 | Separate HTTP and HTTPS Templates | **Pending (next)** |
| 4 | Automatic DELTA Backend Port Detection | Pending |
| 5 | Existing Certificate Handling | Pending |

---

# 1. Use Shared DELTA Installation Discovery

**Status: Completed** - `Resolve-DeltaInstallation` in `setup-nginx.ps1` calls the shared `Get-DeltaInstallPath` helper (`lib\DeltaInstaller.Common.ps1`) before anything else runs, and stops with a clear message if no installation is found. No hardcoded `C:\DELTA` path remains in this script.

## Objective

Remove the hardcoded `C:\DELTA` dependency.

Instead, resolve the DELTA installation by calling:

```powershell
Get-DeltaInstallPath
```

This helper already supports:

1. Windows Registry (`HKLM\SOFTWARE\PreventionWeb\DELTA`)
2. Legacy installation (`C:\DELTA` if `.env` exists)
3. Return `$null` if DELTA is not installed

If no installation is found:

- stop the installer
- display a clear message instructing the administrator to install DELTA first

---

# 2. SSL Certificate Wizard

**Status: Completed** - `Install-DeltaSslCertificate` in `setup-nginx.ps1` prompts the administrator (`Read-SslCertificateChoice`), opens standard Windows file selection dialogs for the certificate and private key (`Select-DeltaSslFile`), validates both (selected, exist, supported extension), and copies them into `C:\nginx\certs\delta.crt` / `C:\nginx\certs\delta.key`. Deliberately still out of scope, reserved for later phases below: HTTP/HTTPS template selection (Phase 3), automatic PORT detection (Phase 4), and existing-certificate overwrite handling (Phase 5) - `New-DeltaNginxConfiguration` always writes the plain HTTP template regardless of whether a certificate was just installed.

Instead of assuming an SSL certificate exists, prompt the administrator.

Example:

```
Do you already have an SSL certificate?

( ) Yes
( ) No
```

---

## If Yes

Prompt for:

- SSL Certificate
- Private Key

Prefer a standard Windows file selection dialog instead of manually entering paths.

Supported certificate formats:

- `.crt`
- `.cer`
- `.pem`

Supported private key formats:

- `.key`
- `.pem`

Validate that both selected files exist.

---

## Certificate Storage

Copy the selected files into the NGINX installation.

Example:

```
C:\nginx\
    certs\
        delta.crt
        delta.key
```

Do not reference the original file locations.

The generated NGINX configuration should always reference:

```nginx
ssl_certificate     C:/nginx/certs/delta.crt;
ssl_certificate_key C:/nginx/certs/delta.key;
```

---

# 3. Separate HTTP and HTTPS Templates

**Status: Pending (next phase to implement)**

Instead of maintaining one template with conditional SSL directives, maintain two dedicated templates.

Example:

```
templates/
    nginx/
        delta-http.conf
        delta-https.conf
```

Installer behavior:

If SSL certificate is provided:

- generate `delta-https.conf`

Otherwise:

- generate `delta-http.conf`

The HTTP template should contain no SSL directives.

The HTTPS template should contain the complete SSL configuration.

---

# 4. Automatic DELTA Backend Port Detection

Determine the backend application port by reading the DELTA `.env` file.

Example:

```
<InstallPath>\.env
```

Read:

```
PORT=
```

Behavior:

- valid port → use it
- missing → default to `3000`
- invalid → stop installation with a clear error

The generated NGINX configuration should use:

```
proxy_pass http://localhost:<PORT>;
```

instead of assuming port 3000.

---

# 5. Existing Certificate Handling

If the destination already contains:

```
C:\nginx\certs\delta.crt
C:\nginx\certs\delta.key
```

prompt the administrator before overwriting.

Possible actions:

- Replace existing certificate
- Keep existing certificate
- Cancel

This prevents accidental replacement of a working production certificate.

---

# Design Principles

- No hardcoded DELTA installation path.
- Registry is the primary installation discovery mechanism.
- Legacy installations remain supported.
- NGINX should use its own dedicated `certs` directory.
- HTTP deployments should not contain SSL directives.
- HTTPS deployments should use a dedicated configuration template.
- Future enhancements should build upon the shared `Get-DeltaInstallPath()` helper.
# BouncyCastle.Cryptography (vendored)

This directory vendors a single third-party assembly, committed directly
into this repository rather than downloaded at install time - see
"Why vendored, not downloaded" below.

## Package

- **NuGet package:** `BouncyCastle.Cryptography`
- **Version:** `2.7.0` (latest stable at the time this was vendored)
- **Source:** https://api.nuget.org/v3-flatcontainer/bouncycastle.cryptography/2.7.0/bouncycastle.cryptography.2.7.0.nupkg
- **Project:** https://www.bouncycastle.org/stable/nuget/csharp/website
- **Assembly used:** `lib/net461/BouncyCastle.Cryptography.dll` from inside
  the package - the build specifically targeting .NET Framework 4.6.1,
  which Windows PowerShell 5.1's own .NET Framework runtime (4.7.2+ on
  every Windows Server version this project targets) can load directly
  via `Add-Type -Path`. The package also ships `net6.0` and
  `netstandard2.0` builds; `net461` was chosen as the most directly
  targeted, least-indirection option for this specific runtime.

## Why BouncyCastle

`setup-iis.ps1`'s SSL Certificate phase needs to combine an
administrator-supplied certificate + private key pair (`.crt`/`.cer`/
`.pem` + `.key`/`.pem`) into a PKCS#12 (`.pfx`) before it can be imported
into the Windows Certificate Store - Windows has no native cmdlet for
this, and .NET Framework 4.8's own `RSA`/`ECDsa` classes do not expose
the PEM/DER convenience methods (`ImportFromPem`, `ImportPkcs8PrivateKey`,
etc.) that only exist in .NET 5+/.NET Core 3.0+ (confirmed empirically
against this exact runtime - see
`docs/todo/TODO-setup-iis-enhancements.md`'s own Phase 7 investigation
notes). A hand-written ASN.1 parser can cover plain, unencrypted
PKCS#1/PKCS#8 keys, but cannot reasonably or safely cover encrypted
keys (PBES2, or OpenSSL's own legacy PKCS#1 encryption scheme) without
reimplementing meaningful parts of a crypto library by hand - exactly
the outcome this project's own SSL Certificate phase was asked to avoid.

BouncyCastle is the mature, widely-used, actively-maintained library that
already handles all of this correctly - `PemReader` transparently reads
PKCS#1, PKCS#8, and encrypted PKCS#8 keys, RSA and EC, and (confirmed
directly, see Phase 7's own validation notes) the legacy OpenSSL
`Proc-Type: 4,ENCRYPTED` PKCS#1 format too, using its own actual
decryption implementation rather than anything hand-rolled here.

## License

MIT (`LICENSE.md` in this directory is the exact license file shipped
inside the NuGet package, copied verbatim - required for redistribution).
Fully compatible with this project's own distribution - permissive,
no copyleft, no additional obligations beyond retaining the copyright/
license notice, which this file and `LICENSE.md` together satisfy.

## Why vendored, not downloaded

Unlike NGINX, ARR, or URL Rewrite (`setup-nginx.ps1`/`setup-iis.ps1`'s
own `installers\` download-and-cache pattern), this is not a separate
product being installed onto the target machine - it is a library
dependency of the installer script itself, needed to do its own work.
Committing it directly:

- removes a network dependency from a certificate-import code path an
  administrator may need to run without outbound internet access;
- keeps the exact, tested version pinned - no "latest available at
  install time" drift;
- matches the small, permissively-licensed nature of this specific
  dependency - a few megabytes, MIT-licensed, not something that needs
  a separate download-and-verify step the way a multi-hundred-megabyte
  NGINX distribution does.

## Updating

To bump the version: download the new `.nupkg` from
`https://api.nuget.org/v3-flatcontainer/bouncycastle.cryptography/<version>/bouncycastle.cryptography.<version>.nupkg`,
extract `lib/net461/BouncyCastle.Cryptography.dll`, replace the file in
this directory, replace `LICENSE.md` with the new package's copy (rarely
changes, but verify), and update the version/date noted above.

# Windows Compatibility Assessment

**Status:** Findings document — static analysis of the `dts_shared_binary` artifact. Records facts and their confidence level; does not prescribe deployment procedure. See [02](02-windows-installation.md) for the procedure that responds to these findings.
**Method:** Full-text search of `build/server/index.js` (4.4 MB compiled server bundle), line-by-line diff of every `.sh`/`.bat` script pair, and inspection of `dts_database/*.sql`. No execution was performed on Windows as part of this assessment.
**Related:** [01 — Runtime Architecture](01-runtime-architecture.md) · [06 — Deployment Risks](06-deployment-risks.md)

---

## How to read this document

Every finding below is labeled with one of three tags. This distinction is load-bearing — do not treat an Inferred or Recommended item as if it were Verified:

| Tag | Meaning |
|---|---|
| **Verified** | Confirmed directly against the artifact — a grep match, a read line, a diff. Reproducible by anyone with the artifact. |
| **Inferred** | A reasoned conclusion from verified facts plus general platform knowledge (e.g., how Node.js or NSSM behave on Windows), not itself executed against this artifact. |
| **Recommended** | An engineering recommendation responding to a Verified or Inferred finding — a judgment call, not a fact. |

Overall conclusion: **the compiled runtime is compatible with native Windows Node.js.** The application has been verified to have no Linux-only runtime dependency. What remains open is entirely in *operational validation* — no one has yet executed this artifact end-to-end on a real Windows Server. Statements below are careful to say "compatible" only where that's been established, and "not yet validated" where it hasn't.

## Runtime inspection

**Verified** — Searching the full server bundle for `chmod`, `chown`, `/bin/sh`, `/bin/bash`, `child_process`, `execSync`, `spawn(`, `process.getuid`/`getgid`, and `symlink` returns zero matches, across two independent passes. The application never shells out to an OS command.

**Verified** — File paths route through Node's `path.join`/`path.resolve` throughout (e.g. upload deletion and file-serving code). A dedicated helper, `normalizeTenantRelativePath()` (`build/server/index.js:16805-16814`), explicitly strips backslashes before comparing paths — evidence the code already anticipates Windows-style separators reaching it.

**Verified** — The server registers `process.on("SIGINT", ...)` and `process.on("SIGTERM", ...)` (`build/server/index.js:57586-57594`) to flush log transports before exiting. These are standard Node.js APIs, not Linux-only — but see [§Windows service considerations](#windows-service-considerations) below for why *how reliably they fire* differs by platform.

## Linux-only API search

**Verified** — No Unix-socket usage, no UID/GID access, no `os.platform()`/`process.platform` branching anywhere in the bundle. No hardcoded `/tmp`, `/var`, or `/etc` paths. Extension checks lowercase before comparing against an allow-list, which is safe on both case-sensitive and case-insensitive filesystems.

## Native dependency inspection

**Verified** — Every production dependency was checked individually, not by name alone: `bcryptjs`, `pg`, `postgres`, `drizzle-orm`, `express`, `winston`, `winston-daily-rotate-file`, `ol` are all pure JavaScript. No `binding.gyp`, no node-gyp indicator, anywhere in the dependency tree as declared. `bcryptjs` specifically avoids the native `bcrypt` package that would otherwise require compilation.

**Verified** — The only `package.json` lifecycle script is `"prepare": "husky"` (a Git-hooks installer for contributors), which does not run under `yarn install --production`.

**Inferred** — `esbuild` is pinned under `resolutions` (`package.json:125`) and ships prebuilt platform binaries via npm `optionalDependencies` rather than node-gyp compilation. It is a transitive dependency of `vite`, itself a devDependency — a production install should never resolve it. This is inference from how Yarn's `--production` flag works generally, not a Windows install that was actually executed and observed.

## Node.js & packages

**Verified** — `package.json` declares no `engines` field. No Node.js version is pinned by the artifact itself.

**Verified** — No `node_modules/` and no `yarn.lock` ship with the artifact. The first production install on any platform resolves dependency versions fresh against the registry, and is not reproducible run-to-run as shipped.

## Filesystem compatibility

**Verified** — Uploads (`BASE_UPLOAD_PATH = "uploads"` and its subpaths, `build/server/index.js:16796-16803`) and logs (`LOG_DIR`, default `logs`, created via `fs.mkdirSync(..., { recursive: true })` at `~57333`) are always relative paths resolved through Node's `path` module — confirmed safe on NTFS by inspection of the actual resolution code, not just the constant declarations.

**Verified** — No symlink creation or dereferencing exists in the server bundle. The only symlink reference in the whole artifact is in `README.md`, describing an *optional* Linux convenience for preserving `uploads/` across upgrades — explicitly framed as an alternative to the default (copy the folder), not a hard dependency.

## Environment variable compatibility

**Verified** — All configuration is read via `process.env.*` and loaded from a flat `.env` file by `dotenv-cli`, which parses the file in JavaScript rather than relying on POSIX shell `export` syntax. The full variable set (`DATABASE_URL`, `SESSION_SECRET`, `NODE_ENV`, `PUBLIC_URL`, SMTP/email settings, SSO settings, logging settings, and others) behaves identically on Windows.

**Verified** — `process.env.HOSTNAME` is read at `build/server/index.js:57371` for log metadata, with a fallback to `"unknown"`. Windows does not populate `HOSTNAME` automatically the way POSIX shells do (it uses `COMPUTERNAME` instead) — cosmetic only, affects a single log field, not application behavior.

## Reverse proxy compatibility

**Verified** — Client IP is read directly from `x-forwarded-for`/`x-real-ip` headers (`build/server/index.js:76582`) rather than via Express's `req.ip` + `trust proxy` configuration — behavior is identical regardless of which reverse proxy implementation sits in front of the app.

**Verified** — The session cookie's `Secure` flag is driven by `NODE_ENV === "production"` (`build/server/index.js:1471, 1484`), not by `req.secure`. This sidesteps the classic reverse-proxy pitfall where a backend behind a TLS-terminating proxy sees plain HTTP and refuses to mark cookies `Secure` — but it also means **the operator, not the app, is responsible for ensuring HTTPS is actually in front of the deployment.** Running with `NODE_ENV=production` behind plain HTTP (no reverse proxy, or a misconfigured one) will silently break login persistence, since the browser will refuse a `Secure` cookie over an insecure connection. This is true on every platform — not a Windows-specific defect, but worth stating plainly given how easy it is to skip the reverse-proxy step during a first deployment attempt.

## Existing Windows tooling

**Verified** — `init_db.bat`, `init_website.bat`, `start.bat`, and `upgrade_database.bat` already exist alongside their `.sh` counterparts. They are not new work — this assessment reviews their correctness, not their existence.

**Verified, gaps found** — A direct diff against the `.sh` originals surfaced real correctness gaps, not just cosmetic differences:

- Every `.bat` script ends in (or contains) `pause`, including on error paths — blocking unattended/automated execution.
- `init_db.bat` and `upgrade_database.bat` quote only the database-name/file-path argument; `%DB_HOST%`, `%DB_PORT%`, and `%PGUSERNAME%` are interpolated unquoted, unlike the fully-quoted `.sh` versions.
- `init_website.bat` omits the `--force` flag on `npm install --global yarn` that `init_website.sh` uses.
- `init_website.bat` only adds npm's global folder to `PATH`, not Yarn Classic's own global bin folder (where `yarn global add dotenv-cli` actually installs `dotenv`) — the `.sh` version correctly targets `$HOME/.yarn/bin`.

Full detail and recommended fixes for each: [06 — Deployment Risks](06-deployment-risks.md#installation-tooling-gaps).

## Windows service considerations

**Inferred** — Windows has no native SIGTERM. Node.js emulates a subset of POSIX signal behavior via console control events; `SIGINT` can fire reliably when the process has an attached console, but external process managers cannot deliver a true SIGTERM the way systemd does on Linux. NSSM's documented default stop sequence escalates through console Ctrl+C → window messages → a hard `TerminateProcess` — and if the service is configured to run headless (no console window, a common choice for background services), the graceful-shutdown log-flush handler verified above may never actually run. This is general platform knowledge about Node-on-Windows and NSSM, not something reproduced against this specific artifact.

**Recommended** — Explicitly verify the shutdown path during the [proof-of-concept deployment](07-windows-poc.md#validation-checklist) rather than assuming NSSM's default configuration invokes the app's cleanup handler. Do not treat "the app has a SIGTERM handler" as equivalent to "the app shuts down gracefully as a Windows Service" until that's actually observed.

## Summary

| Area | Confidence | Basis |
|---|---|---|
| No Linux-only runtime dependency | High | Verified |
| No native/node-gyp production dependency | High | Verified |
| PostGIS/pgcrypto install cleanly via EDB/Stack Builder | High | Recommended, standard practice — not tested against this specific DB |
| `.bat` scripts are correctness-equivalent to `.sh` | Low | Verified — real gaps found, see above |
| esbuild's platform-binary step never runs in production install | Medium | Inferred |
| `createdb` may inherit a non-UTF8 cluster default on Windows | Medium | Inferred — see [04](04-database.md#utf-8-and-locale) |
| NSSM headless services may bypass the app's SIGTERM cleanup | Medium | Inferred |
| End-to-end Windows Server deployment succeeds | **Not yet established** | No execution has been performed — this is precisely what [07 — Proof of Concept](07-windows-poc.md) exists to close |

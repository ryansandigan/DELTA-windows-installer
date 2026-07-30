# Runtime Architecture

**Status:** Conceptual reference. Describes what DELTA *is*, not how to install it — see [02](02-windows-installation.md)/[03](03-linux-installation.md) for procedure.
**Related:** [00 — Overview](00-overview.md) · [04 — Database](04-database.md) · [05 — Compatibility Assessment](05-windows-compatibility-assessment.md)

---

## Component map

```text
                    ┌────────────────────────┐
   Browser  ───────▶│  Nginx (reverse proxy) │───────▶ terminates TLS, forwards
                    │  Windows or Linux       │         X-Forwarded-* headers
                    └───────────┬─────────────┘
                                │  plain HTTP, internal network
                                ▼
                    ┌────────────────────────┐
                    │  Node.js 24.x process   │
                    │  react-router-serve     │
                    │  → build/server/index.js│
                    │  (Express under the hood)│
                    └───────────┬─────────────┘
                                │  DATABASE_URL, TCP
                                ▼
                    ┌────────────────────────┐
                    │  PostgreSQL 16.x        │
                    │  + PostGIS + pgcrypto   │
                    └────────────────────────┘
```

Alongside the process, two filesystem locations matter operationally: `uploads/` (user-submitted files, must persist across restarts and upgrades) and `LOG_DIR` (application logs, rotated by the app itself). Both are covered in the deployment guides.

## The four technologies, and what each is actually responsible for

### React Router v7 (framework mode)

The application layer. Renders pages server-side and defines the route tree that maps URLs to data loaders/actions. Compiled ahead of time into `build/server/index.js` (SSR bundle) and `build/client/` (static assets) — nothing about React Router is present at runtime as a separate process or dependency to install; it is baked into the bundle you already have.

### Express 5

The HTTP layer React Router runs on top of. `react-router-serve` (the `start` script's entry point) is a thin CLI that wires the compiled server bundle into an Express app and calls `listen()`. There is no separate Express configuration to manage in deployment — it is fully contained in the bundle.

#### Static asset serving — no `public/` directory required

`build/server/index.js` itself contains **zero** `express.static()`/`.static()` calls (verified by exhaustive search of the compiled bundle) — it never serves a static file directly. All of that is delegated to `react-router-serve`, driven entirely by fields the compiled bundle exports as part of react-router's standard `ServerBuild` contract:

```js
const assetsBuildDirectory = "build/client";
const basename = "/";
...
export { assetsBuildDirectory, basename, entry, ... }
```

`react-router-serve`'s own (external, `@react-router/serve` package) static-file middleware reads `assetsBuildDirectory` and serves it directly — relative to the process's working directory, i.e. the install root (`C:\DELTA` on Windows). This is why `build/client/` (which already contains `favicon.ico`, `assets/`, everything the client needs) is sufficient on its own; nothing needs to be copied out of it into a differently-named directory for it to be served.

User-uploaded files are not served through static-file middleware either — they go through an authenticated resource route (`build/server/index.js` — the file-viewer handler around the `FileViewer request:` log line) that checks `userSession.countryAccountsId` against the requested tenant before streaming the file back with `fs.readFileSync`. Uploads live under `<install root>/uploads/tenant-<id>/...`, resolved from `process.cwd()`, not from any `public/` directory.

**Why this matters for the Docker vs. native Windows/Linux comparison:** the archived Docker design (`docs/parked/docker-containerization-design.md`) copies `build/client/` into a separate `/data/public/` directory, citing "`express.static("public")` needs a `public/` copy of `build/client/`, a real requirement." That claim does not hold against the artifact examined in this documentation series (`dts_shared_binary` v0.2.3): the compiled bundle has no such call today, and the *only* remaining references to a literal `public/` path anywhere in the bundle are legacy fallback candidates in the tenant-upload-cleanup code (checking whether old uploads still live under `public/uploads/tenant-<id>` from some earlier version, purely so cleanup can find and remove them) — evidence the application used to store/serve uploads under `public/` and has since moved that behind an authenticated route instead, not evidence that a `public/` directory is still load-bearing. Native Windows/Linux deployment (`react-router-serve` directly, no Nginx-in-front-of-Express layer) never needed the extra copy in the first place; treat the Docker design's `public/` step as specific to whatever artifact version it was written against, not as a requirement carried forward here. See [02 — Deployment layout](02-windows-installation.md#deployment-layout) for how this plays out in the actual installed directory structure.

### Node.js

The JavaScript runtime executing the above. This is the one component with a real version decision to make at deployment time, because `package.json` does not pin an `engines` field — see [05 §Node.js & packages](05-windows-compatibility-assessment.md#nodejs--packages) for what was verified about dependency compatibility, and [06](06-deployment-risks.md) for the recommendation to pin a version explicitly once validated.

### PostgreSQL + PostGIS

The persistence layer. PostGIS is not optional tooling bolted on for convenience — the schema itself defines `geometry(Geometry,4326)` columns used by the application's mapping features (backed by OpenLayers and Turf.js on the client/server respectively). See [04 — Database](04-database.md#why-postgis-is-mandatory) for the full explanation and exact schema references.

### Nginx

Not part of the application at all — it is deployment infrastructure, sitting in front of the Node process to terminate TLS and reverse-proxy plain HTTP internally. The application reads `x-forwarded-for`/`x-real-ip` headers directly rather than relying on an Express `trust proxy` setting, which makes it agnostic to which reverse proxy implementation (Nginx for Windows, Nginx for Linux, IIS, or otherwise) sits in front of it. See [02 §Reverse proxy](02-windows-installation.md#reverse-proxy-configuration) / [03 §Reverse proxy](03-linux-installation.md#reverse-proxy-configuration).

## Runtime vs. installation tooling vs. deployment tooling

This distinction is used consistently across the whole documentation set — worth being precise about it once, here.

| Layer | What it is | Examples | Where it's documented |
|---|---|---|---|
| **Runtime** | The code that actually executes to serve requests. Its platform compatibility is a property of the code, verifiable by static inspection. | `build/server/index.js`, its production `node_modules` | [05](05-windows-compatibility-assessment.md) |
| **Installation tooling** | One-time (or per-upgrade) scripts that prepare an environment for the runtime to execute in. Not invoked while the app is running. | `init_db.{sh,bat}`, `init_website.{sh,bat}`, `upgrade_database.{sh,bat}` | [02](02-windows-installation.md), [03](03-linux-installation.md), [04](04-database.md) |
| **Deployment tooling** | Whatever keeps the runtime running, restarts it on failure, and exposes it to the network, for a specific target platform. | NSSM/WinSW + Nginx for Windows (native); systemd + Nginx for Linux (native); Docker Compose (parked) | [02](02-windows-installation.md), [03](03-linux-installation.md), [`docs/parked/`](parked/) |

A finding about one layer does not automatically transfer to another. For instance: the runtime has no Linux-only dependency (a runtime fact), but the shipped installation tooling has real correctness gaps on Windows (an installation-tooling fact) — see [05](05-windows-compatibility-assessment.md) and [06](06-deployment-risks.md) for both, kept separate rather than conflated into a single verdict.

## Statelessness

Session state lives entirely in signed, client-side cookies — there is no server-side session store (no Redis, no DB-backed sessions). Combined with the filesystem-based `uploads/` directory and the database itself being the only other state, the Node process itself is horizontally stateless: multiple instances can run behind the same reverse proxy as long as they share the same database and the same `uploads/` directory. Neither deployment guide in this series currently documents a multi-instance topology — this is noted as a capability, not a configured scenario.

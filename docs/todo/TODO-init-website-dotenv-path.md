# TODO-init-website-dotenv-path.md

# TODO: Remove Temporary dotenv-cli PATH Workaround

## Status

**Open**

Temporary workaround currently implemented in `setup.ps1`.

---

## Summary

During end-to-end validation on a clean Windows Server 2022 installation, a startup issue was identified in the current Windows runtime initialization process.

`init_website.bat` successfully installs `dotenv-cli` using:

```bat
yarn global add dotenv-cli
```

However, it assumes that the Yarn global binary directory is automatically available on PATH.

This assumption is not true on a clean Windows installation.

As a result, `start.bat` fails with:

```
'dotenv' is not recognized as an internal or external command,
operable program or batch file.
```

even though `dotenv-cli` has been installed successfully.

---

## Root Cause

`yarn global add dotenv-cli` installs the executable into the Yarn global bin directory.

Example:

```
C:\Users\<User>\AppData\Local\Yarn\bin
```

The current implementation of `init_website.bat` only appends:

```
%USERPROFILE%\AppData\Roaming\npm
```

to PATH so that `yarn.cmd` becomes available.

It never exposes the Yarn global bin directory that contains:

```
dotenv.cmd
```

Therefore:

- `dotenv-cli` is installed correctly
- `dotenv.cmd` exists
- `start.bat` cannot locate it

---

## Validation Evidence

Verified during Windows Server 2022 deployment.

Confirmed:

```
yarn global list
```

shows:

```
dotenv-cli@11.x
```

Confirmed:

```
Get-Command dotenv
```

works immediately after adding the Yarn global bin directory to the current PowerShell session.

Confirmed:

```
start.bat
```

starts successfully once the session PATH includes the Yarn global bin directory.

---

## Current Temporary Workaround

`setup.ps1` temporarily performs a session-only PATH update after runtime initialization.

This workaround:

- dynamically discovers the Yarn global bin directory
- updates only the current PowerShell session
- does not modify the machine or user environment variables

This workaround exists solely to allow end-to-end validation to continue.

---

## Recommended Permanent Fix

One of the following approaches should replace the temporary workaround.

### Option A (Preferred)

Stop relying on a global installation.

Install `dotenv-cli` as a project dependency and invoke it through Yarn/package scripts.

Benefits:

- no global dependency
- no PATH dependency
- reproducible runtime
- simpler installer

---

### Option B

Keep the global installation but modify `init_website.bat` to:

1. Discover the Yarn global bin directory.
2. Add it to PATH.
3. Verify that `dotenv` is resolvable before completing.

---

## Removal Criteria

The temporary workaround in `setup.ps1` can be removed once:

- `init_website.bat` correctly exposes the required runtime environment

or

- `dotenv-cli` is migrated to a project-local dependency.

Until then, the workaround should remain to ensure successful Windows deployments.
# DriftBuild Security Checklist

## Sensitive Surfaces

- `PairingRequest.tokenHash`: server should only receive and persist hashes.
- `~/.driftbuild/config.json`: client stores bearer tokens locally.
- `auth/clients.json`: server stores token hashes and revocation timestamps.
- `TokenAuthMiddleware`: protects build, log, artifact, and cancel APIs.
- `RepoValidator`: gate before `git clone`.
- `BuildWorker.runCommand`: logs command name and arguments, then executes without a shell.
- `workspace`, `project`, `scheme`, `branch`, `commit`: client-controlled build inputs.

## Review Questions

- Could this input escape the cloned repo or server data directory?
- Could this value appear in `build.log`, `summary.txt`, or `result.zip`?
- Does revocation affect the next request without server restart?
- Does a public unauthenticated route reveal more than discovery or pairing requires?
- Does a new subprocess invocation pass user input as separate arguments?
- Does a new URL scheme permit local file reads or unintended protocols?

## Current Trust Model

DriftBuild is intentionally scoped to trusted local networks. It is not a multi-tenant SaaS build service and should not be exposed directly to the internet without additional hardening such as TLS, account-level authorization, request quotas, stronger repository allowlists, and audit logging.

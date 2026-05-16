---
name: driftbuild-security-review
description: Review or harden DriftBuild security-sensitive behavior. Use when changing authentication, bearer tokens, token hashing, pairing approval, revocation, repo URL validation, subprocess execution, command logging, artifact access, local storage, LAN exposure, or any code path that accepts untrusted client input.
---

# DriftBuild Security Review

## Review Stance

Assume DriftBuild runs on a trusted LAN but receives build requests from paired clients. Protect the build Mac from accidental command injection, token disclosure, broad file access, and confusing auth behavior.

## Checklist

- Bearer tokens must never be printed, stored on the server in plaintext, or included in artifacts.
- Server-side auth must reject revoked tokens immediately.
- Pairing codes must expire and require explicit approval unless demo-only auto-approval is enabled.
- Repository URLs must be validated before any `git clone`.
- Subprocesses must use executable paths and argument arrays, not shell strings.
- Client-controlled paths such as workspace and project should remain relative to the cloned repository.
- Artifact and log endpoints must require auth and resolve only through the job id.
- Command logs should avoid secrets embedded in URLs or arguments.
- New files under the server data directory should be created by predictable code paths.
- Any new network listener must be scoped to the LAN trust model and documented.

## When Changing Risky Code

1. Identify the external input source and the trust boundary.
2. Check validation before persistence or subprocess execution.
3. Add or adjust tests for pure validators and auth-adjacent model behavior.
4. Update README when the operator's security responsibility changes.

Read `references/security-checklist.md` for DriftBuild-specific review notes and current sensitive surfaces.

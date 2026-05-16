---
name: driftbuild-diagnostics
description: Diagnose DriftBuild remote iOS simulator build failures. Use when analyzing drift job status, streamed build.log output, result.zip artifacts, summary.txt, errors.txt, warnings.txt, meta.json, Build.xcresult, xcodebuild failures, CocoaPods install failures, Swift Package resolution, checkout issues, missing schemes, or artifact download problems.
---

# DriftBuild Diagnostics

## Workflow

Gather the smallest set of evidence first:

1. `drift status --job-id <id>`
2. `drift logs --job-id <id>`
3. `drift artifact --job-id <id> --output <dir>` when `artifactReady` is true
4. Inspect `summary.txt`, `errors.txt`, `warnings.txt`, `meta.json`, and `build.log` inside `result.zip`
5. Request `Build.xcresult` only when text logs do not explain the failure

Treat the remote Mac as the source of truth for Xcode, CocoaPods, SPM cache, simulator SDK, network access, SSH keys, and repository permissions.

## Diagnosis Heuristics

- Failure before `[drift] building` usually belongs to Git checkout, submodules, CocoaPods, or repository permissions.
- `No .xcworkspace or .xcodeproj found` means the project is not at repo root or the caller must pass `--workspace` or `--project`.
- `Multiple Xcode containers found` means the caller must pass exactly one of `--workspace` or `--project`.
- Scheme errors usually require shared schemes in the repository or a corrected `--scheme`.
- SPM errors usually require server-side network access to package hosts and valid credentials for private packages.
- Code signing failures are unexpected for simulator builds because DriftBuild passes `CODE_SIGNING_ALLOWED=NO`; inspect project scripts and build phases.
- Missing artifact after terminal state is a server packaging issue, not an xcodebuild issue.

## Output

When reporting a diagnosis, include:

- job id and terminal status
- failing stage
- most relevant log excerpt or artifact file
- likely root cause
- exact CLI or repository change to try next

Read `references/job-artifacts.md` for artifact layout and triage order.

# DriftBuild Architecture Reference

## Current Package Shape

- `DriftCore`: shared protocol models, version constants, path helpers, hashing, repo validation, JSON persistence, log chunk reads.
- `DriftCLI`: `drift` command, discovery client, pairing flow, local config, authenticated HTTP client, submit/status/logs/artifact/cancel/server management commands.
- `DriftServer`: `drift-server` command, Vapor routes, state store, token auth middleware, build queue, process runner, build worker, Bonjour publisher, UDP discovery responder.

## Build Pipeline

The server creates one job directory per job id:

```text
jobs/<jobId>/
  state.json
  build.log
  source/
  DerivedData/
  output/
    build.log
    meta.json
    summary.txt
    errors.txt
    warnings.txt
    Build.xcresult
  result.zip
```

The worker runs:

1. `git clone --recursive <repo> <source>`
2. `git checkout <branch>`
3. optional `git reset --hard <commit>`
4. `git submodule update --init --recursive`
5. optional `pod install` when `Podfile` exists
6. `xcodebuild clean build ... CODE_SIGNING_ALLOWED=NO`
7. package output into `result.zip`

## Invariants

- CLI can run without full Xcode.
- Server requires Xcode and repository network access.
- Every terminal job should attempt artifact packaging.
- Log reads use byte offsets and should not retransmit old output.
- Build subprocesses should not run through a shell.
- Same repo should not build concurrently.
- Default server concurrency is 1.

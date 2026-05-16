---
name: driftbuild-implementation
description: Implement, debug, or extend DriftBuild, a Swift LAN remote iOS simulator build system. Use when working on the DriftBuild Swift Package, drift CLI, drift-server, Vapor HTTP API, ArgumentParser commands, Bonjour or UDP discovery, pairing, build queue, xcodebuild invocation, log streaming, artifact packaging, or tests.
---

# DriftBuild Implementation

## Workflow

Start by reading the files that own the requested behavior:

- Shared models and utilities: `Sources/DriftCore/Models.swift`, `Sources/DriftCore/Utilities.swift`
- CLI commands and client HTTP behavior: `Sources/DriftCLI/main.swift`
- Server routes, state, queue, worker, discovery publisher: `Sources/DriftServer/main.swift`
- Server command wrappers: `Sources/DriftServer/Commands.swift`
- Tests: `Tests/DriftBuildTests/DriftBuildTests.swift`

Keep changes consistent with the current package: Swift 5.10, macOS 13+, `Foundation`, `ArgumentParser`, `Vapor`, and no shell execution for build-critical subprocesses.

## Implementation Rules

- Keep protocol structs in `DriftCore` when both CLI and server need them.
- Keep user-facing command options in the relevant `ArgumentParser` command.
- Keep server endpoint behavior in `configureRoutes` unless the route surface becomes large enough to justify extraction.
- Use `Process.executableURL` and `arguments`; do not introduce `sh -c` for Git, CocoaPods, xcodebuild, ditto, or zip.
- Preserve the job lifecycle: `queued`, `preparing`, `fetching`, `installingDependencies`, `building`, `packaging`, terminal status.
- Preserve offset-based log reads with monotonically increasing `nextOffset`.
- Preserve artifact creation on failure, timeout, and success.
- Prefer focused XCTest coverage for shared model/utility behavior and pure validation logic.

## Common Tasks

When adding a CLI option, update all of these surfaces if applicable:

1. Add the stored property to the `ArgumentParser` command in `Sources/DriftCLI/main.swift`.
2. Add the field to `BuildRequest` or another shared `DriftCore` model when the server needs it.
3. Update server validation and build-worker use.
4. Update README examples and tests.

When changing build behavior:

1. Make the smallest change in `BuildWorker.run(jobId:)` or its helper methods.
2. Log the selected stage or command clearly, without logging bearer tokens.
3. Keep generated outputs under the job directory and `output/`.
4. Keep `result.zip` shape compatible with existing docs.

Read `references/architecture.md` for a compact map of current responsibilities and invariants.

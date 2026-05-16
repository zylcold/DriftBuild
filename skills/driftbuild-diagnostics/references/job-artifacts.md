# DriftBuild Job Artifact Reference

## Triage Order

1. `meta.json`: confirms request parameters, final status, exit code, timing, and server-side error.
2. `summary.txt`: quick human-readable status plus first error and warning lines.
3. `errors.txt`: filtered lines containing common xcodebuild and compiler failure markers.
4. `warnings.txt`: filtered warnings; useful for warning-as-error projects.
5. `build.log`: full combined stdout/stderr from Git, CocoaPods, xcodebuild, and packaging.
6. `Build.xcresult`: optional detailed Xcode result bundle when the job was submitted with `--include-xcresult`.

## Stage Interpretation

- `queued`: job has not started. Check server concurrency and same-repo serialization.
- `preparing`: job directory setup. Failures here are filesystem or permissions issues on the server data directory.
- `fetching`: Git clone, checkout, reset, or submodule failure.
- `installingDependencies`: CocoaPods failure, missing `pod`, private spec repo access, or Podfile script issue.
- `building`: xcodebuild, scheme, simulator SDK, project configuration, SPM, compiler, linker, or build phase failure.
- `packaging`: zip/ditto failure or output filesystem issue.

## Common Fixes

- Pass `--workspace` when a Pods workspace should be used.
- Pass `--project` or `--workspace` when multiple Xcode containers exist.
- Ensure schemes are shared and committed.
- Ensure the build Mac can authenticate to private Git, SPM, and CocoaPods hosts.
- Re-submit with `--include-xcresult` when text logs are ambiguous.

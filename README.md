# DriftBuild

DriftBuild is a Swift based LAN remote build system for iOS simulator builds.

It has two executables:

- `drift-server`: runs on a trusted macOS build machine with Xcode installed.
- `drift`: runs on a developer machine with the Swift toolchain or Command Line Tools. It does not require full Xcode.

The CLI discovers a server on the local network, pairs with a short approval code, submits a Git repository build, streams logs by byte offset, and downloads `result.zip`.

## Architecture

```text
Developer machine                         Mac build machine
-----------------                         -----------------
drift CLI                                 drift-server
  discover  --------------------------->  Bonjour + UDP responder
  pair      --------------------------->  pairing code + token hash
  submit    --------------------------->  FIFO build queue
  logs      <---------------------------  build.log offset chunks
  artifact  <---------------------------  result.zip

Build worker:
  git clone --recursive
  git checkout <branch>
  git reset --hard <commit>
  git submodule update --init --recursive
  default: pod install when Podfile exists, then xcodebuild clean build for Debug iOS Simulator
  optional: delegate the build to codex, claude, or opencode on the build machine
```

The first version intentionally does not archive, export IPA files, manage certificates, or provide a web UI.

## Requirements

Server:

- macOS 13 or later
- Xcode installed
- Network access to the Git repositories that should be built
- CocoaPods installed only if submitted projects use `Podfile`

Client:

- macOS with Swift toolchain or Command Line Tools
- No full Xcode requirement for normal CLI use

## Project Skills

Repository-local Codex skills live under `skills/`:

- `skills/driftbuild-implementation`: implement or debug the Swift/Vapor server, CLI, discovery, pairing, queue, logs, artifacts, and tests.
- `skills/driftbuild-diagnostics`: diagnose failed remote iOS simulator builds from job status, logs, and `result.zip`.
- `skills/driftbuild-security-review`: review authentication, tokens, repo validation, subprocess execution, artifacts, and LAN exposure.

## Build From Source

```sh
swift build -c release
```

The release binaries are produced at:

```text
.build/release/drift
.build/release/drift-server
```

Install locally:

```sh
sudo cp .build/release/drift /usr/local/bin/
sudo cp .build/release/drift-server /usr/local/bin/
```

## GitHub Release Install

Tagged pushes matching `v*` run `.github/workflows/release.yml` and publish an arm64 macOS archive:

```sh
curl -L https://github.com/{owner}/DriftBuild/releases/latest/download/driftbuild-macos-arm64.tar.gz -o driftbuild.tar.gz
tar -xzf driftbuild.tar.gz
sudo cp driftbuild-macos-arm64/drift /usr/local/bin/
sudo cp driftbuild-macos-arm64/drift-server /usr/local/bin/
```

## Run Server

On the Mac build machine:

```sh
drift-server serve --host 0.0.0.0 --port 8000
```

Useful options:

```sh
drift-server serve --data-dir ~/ios-build-server
drift-server serve --name mac-mini-01
drift-server serve --public-url http://192.168.1.20:8000
drift-server serve --concurrency 1
```

State is stored under `~/ios-build-server` by default:

```text
auth/clients.json
auth/pairings.json
jobs/<jobId>/state.json
jobs/<jobId>/build.log
jobs/<jobId>/output/meta.json
jobs/<jobId>/output/summary.txt
jobs/<jobId>/output/errors.txt
jobs/<jobId>/output/warnings.txt
jobs/<jobId>/result.zip
```

## Discover

```sh
drift discover
drift discover --timeout 5
drift discover --json
```

Discovery first uses Bonjour service type `_driftbuild._tcp.local.` and falls back to UDP broadcast on port `37987`.

## Pair

```sh
drift pair
drift pair --server http://192.168.1.20:8000 --name alice-macbook
```

The CLI generates a bearer token locally and sends only `sha256(token)` to the server. The server prints a six digit pairing code and stores only token hashes.

Approve on the build Mac:

```sh
drift-server approve --code 482913
```

The CLI polls until the code is approved, then saves the server URL and bearer token to:

```text
~/.driftbuild/config.json
```

List paired servers:

```sh
drift servers
drift servers --set-default mac-mini-01
drift servers --remove mac-mini-01
```

## Submit Build

```sh
drift submit \
  --repo git@gitlab.example.com:ios/YourApp.git \
  --branch feature/test \
  --commit abc123 \
  --scheme YourScheme \
  --wait \
  --download
```

Optional Xcode container hints:

```sh
drift submit \
  --repo git@gitlab.example.com:ios/YourApp.git \
  --branch main \
  --workspace YourApp.xcworkspace \
  --scheme YourScheme \
  --include-xcresult \
  --timeout 3600 \
  --wait
```

Agent build mode:

```sh
drift submit \
  --repo git@gitlab.example.com:ios/YourApp.git \
  --branch main \
  --workspace YourApp.xcworkspace \
  --scheme YourScheme \
  --agent codex \
  --wait \
  --download
```

Supported agent values are `codex`, `claude`, and `opencode`. The selected agent CLI must be installed on the build machine and available in `PATH`, `/Applications/Codex.app/Contents/Resources`, `~/.opencode/bin`, `~/.local/bin`, `~/.npm-global/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, or `/bin`.

Server build behavior:

- validates the repo URL
- runs subprocesses without a shell
- checks out the requested branch and optional commit
- updates submodules
- default mode runs `pod install` when `Podfile` exists
- default mode lets `xcodebuild` resolve Swift Package Manager dependencies
- default mode runs `xcodebuild clean build`
- default mode sets `CODE_SIGNING_ALLOWED=NO`
- default mode targets `iphonesimulator` and `generic/platform=iOS Simulator`
- agent mode invokes the selected agent in the checked-out source directory with DriftBuild's simulator build instructions

## Logs

```sh
drift logs --job-id 20260516_120000_ab12cd
drift logs --job-id 20260516_120000_ab12cd --follow
```

The API reads `build.log` with byte offsets, so repeated polling only transfers new output.

## Artifact

```sh
drift artifact --job-id 20260516_120000_ab12cd --output ./remote-build-output
```

Every job attempts to produce `result.zip`, even when the build fails or times out. The archive contains:

- `build.log`
- `summary.txt`
- `errors.txt`
- `warnings.txt`
- `meta.json`
- `Build.xcresult`, only when requested with `--include-xcresult`

## Cancel

```sh
drift cancel --job-id 20260516_120000_ab12cd
```

Queued jobs are marked canceled. Running jobs terminate the active subprocess and then produce a final artifact.

## HTTP API

Anonymous:

- `GET /api/health`
- `POST /api/auth/pairings`
- `GET /api/auth/pairings/:id`

Authenticated with `Authorization: Bearer <token>`:

- `POST /api/builds`
- `GET /api/builds/:id`
- `GET /api/builds/:id/logs?offset=0`
- `GET /api/builds/:id/artifact`
- `POST /api/builds/:id/cancel`
- `DELETE /api/builds/:id`

## Security Notes

- DriftBuild is intended for trusted LANs, not public internet exposure.
- Bearer tokens are never sent in query strings.
- The server stores only token hashes in `auth/clients.json`.
- `drift-server revoke --client-id <id>` immediately invalidates a client.
- Build subprocesses use `Process` with argument arrays and do not invoke a shell.
- Repo URLs are restricted to `https`, `http`, `ssh`, `git`, and scp-style `git@host:path.git`.
- Avoid embedding credentials in Git URLs because build logs include command lines.

## FAQ

`drift discover` finds nothing:

Check that both machines are on the same LAN, the server is running, and macOS firewall allows incoming connections. Use `drift pair --server http://host:8000` as a manual fallback.

`xcodebuild not found`:

Install Xcode on the server and run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

`pod install` fails:

Install CocoaPods on the build Mac. DriftBuild only runs `pod install` when `Podfile` exists.

Scheme not found:

Pass the exact shared scheme name and, if needed, pass `--workspace` or `--project`.

Token stopped working:

The token may have been revoked. Run `drift pair` again.

`result.zip` is large:

Avoid `--include-xcresult` unless the result bundle is needed for diagnostics.

## Self Check

- Swift Package with `drift` and `drift-server` executable products: yes.
- `drift discover`: Bonjour plus UDP fallback implemented.
- `drift pair`: local token generation, server hash storage, five minute pairing code implemented.
- Unauthenticated `submit`: rejected by bearer token middleware.
- Token hash only on server: implemented.
- `submit` creates queued jobs: implemented.
- `build.log` real time writes: subprocess stdout and stderr append to the log.
- Timeout terminates subprocess: implemented for build commands.
- Failed builds still create `result.zip`: packaging runs after failure paths.
- CLI does not require full Xcode: CLI uses Foundation, ArgumentParser, and local network APIs only.
- GitHub Actions release: `.github/workflows/release.yml` builds and publishes macOS arm64 archive.
- Shell injection avoided: subprocesses use executable paths and argument arrays.

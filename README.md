# macVR

`macVR` is an experimental macOS VR runtime toolkit. It now ships a bundled native runtime service, an experimental OpenXR runtime shim, a graphical macOS control center, a graphical macOS viewer/receiver, and the bridge ingest tools needed to feed external renderers into the transport stack.

Current release: `0.4.0`

This project is still experimental, but the current release is no longer limited to CLI-only transport probes. It includes:

- `macvr-runtime`, a bundled bridge-first runtime service for macOS.
- `MacVROpenXRRuntime`, an experimental OpenXR runtime shim with manifest generation support.
- `macvr-control-center`, a packaged SwiftUI desktop control center with hover tooltips on every control.
- `macvr-viewer`, a packaged SwiftUI receiver that connects to the transport stack, decodes live frames, and shows a stereo preview with connection metrics.
- Existing host, client, bridge simulator, static JPEG sender, and live display capture sender tools for validation and interoperability work.

Support the project: [buymeacoffee.com/einnovoeg](https://buymeacoffee.com/einnovoeg)

## What It Does

- Streams mock, display-captured, or externally bridged JPEG frames over UDP.
- Negotiates client and host control traffic over a simple JSON-line TCP protocol.
- Accepts bridge-producer control traffic plus authenticated UDP frame ingestion.
- Accepts local length-prefixed JPEG frames directly into the bundled runtime over localhost TCP.
- Captures the live macOS desktop directly into the runtime with `macvr-capture-sender`.
- Connects to the runtime or host with `macvr-viewer` and renders a live stereo preview of the received stream.
- Generates an OpenXR runtime manifest that points to the included experimental runtime shim.
- Ships graphical control center and viewer apps for runtime management and live transport validation.

## Included Tools

- `macvr-host`: host runtime for `mock`, `display-jpeg`, and `bridge-jpeg` modes.
- `macvr-client`: client transport probe that receives stream data and can save JPEG frames.
- `macvr-bridge-sim`: bridge producer shim with generated, file, directory, and TCP JPEG input modes.
- `macvr-jpeg-sender`: portable helper that repeatedly sends `uint32_be length + JPEG bytes` to a local input socket.
- `macvr-capture-sender`: native macOS display capture sender that pushes live desktop frames into the runtime over localhost TCP.
- `macvr-runtime`: bundled runtime that combines bridge ingest, local JPEG ingest, and host streaming in one process.
- `macvr-control-center`: SwiftUI control center for runtime launch, manifest writing, and live status inspection.
- `macvr-viewer`: SwiftUI transport receiver that negotiates sessions, receives UDP frames, and displays a stereo preview with logs and throughput metrics.
- `libMacVROpenXRRuntime.dylib`: experimental OpenXR runtime shim for loader integration tests.

## System Requirements

- macOS 13 or later
- Xcode command line tools with Swift 6.2 support
- Screen Recording permission if you use `display-jpeg` or `macvr-capture-sender`

Optional tools:

- `wine64` and `winetricks` for Wine-based workflows
- `x86_64-w64-mingw32-gcc` or `zig` to cross-compile `macvr-jpeg-sender.exe`

See [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) for the full dependency list.

## Install

```bash
git clone https://github.com/Einnovoeg/macVR.git
cd macVR
swift build
swift test
```

## Build A Versioned Release Bundle

Create the versioned `.app` bundles, CLI binaries, dylib, release notes, and zip asset locally:

```bash
scripts/release/build-release.sh
```

By default this writes a release directory under `dist/` and produces a zip named like `macVR-$(cat VERSION)-macos-arm64.zip`.

## Quick Start

### Bundled Runtime, Control Center, And Viewer

Launch the packaged control center from a release build:

```bash
open "dist/macVR-$(cat VERSION)-macos-$(uname -m)/macVR Control Center.app"
```

Open the packaged viewer from the same release bundle:

```bash
open "dist/macVR-$(cat VERSION)-macos-$(uname -m)/macVR Viewer.app"
```

Or run the control center directly from source:

```bash
swift run macvr-control-center
```

Or run the viewer directly from source:

```bash
swift run macvr-viewer --auto-connect --stream-mode bridge-jpeg
```

For scripted transport checks without opening a window:

```bash
swift run macvr-viewer --headless --stream-mode bridge-jpeg --quit-after 8 --verbose
```

Or launch the bundled runtime directly:

```bash
swift run macvr-runtime --verbose
```

Write an OpenXR manifest that points to the local build output:

```bash
swift run macvr-runtime \
  --write-openxr-manifest "$HOME/.config/openxr/1/active_runtime.json" \
  --manifest-only
```

### Runtime Smoke Test With Live Display Capture And GUI Receive

Terminal 1:

```bash
swift run macvr-runtime \
  --control-port 42000 \
  --bridge-port 43000 \
  --jpeg-input-port 44000 \
  --verbose
```

Terminal 2:

```bash
swift run macvr-viewer \
  --host 127.0.0.1 \
  --control-port 42000 \
  --udp-port 9944 \
  --stream-mode bridge-jpeg \
  --auto-connect \
  --verbose
```

Terminal 3:

```bash
swift run macvr-capture-sender \
  --host 127.0.0.1 \
  --port 44000 \
  --fps 15 \
  --count 90 \
  --scale 0.50 \
  --jpeg-quality 60 \
  --verbose
```

For a terminal-only receive probe, replace Terminal 2 with:

```bash
swift run macvr-client \
  --host 127.0.0.1 \
  --control-port 42000 \
  --stream-mode bridge-jpeg \
  --save-jpeg-every 0 \
  --verbose
```

### Static JPEG Injection Smoke Test

```bash
swift run macvr-jpeg-sender \
  --host 127.0.0.1 \
  --port 44000 \
  --jpeg-file /tmp/macvr-bridge-frame.jpg \
  --fps 30 \
  --count 90 \
  --verbose
```

### Bridge Simulator Workflow

Terminal 1:

```bash
swift run macvr-host --stream-mode bridge-jpeg --bridge-port 43000 --verbose
```

Terminal 2:

```bash
swift run macvr-bridge-sim \
  --host 127.0.0.1 \
  --bridge-port 43000 \
  --jpeg-input-port 44000 \
  --prefer-transport udp-chunked \
  --verbose
```

Terminal 3:

```bash
swift run macvr-client --host 127.0.0.1 --stream-mode bridge-jpeg --save-jpeg-every 0 --verbose
```

Terminal 4:

```bash
swift run macvr-capture-sender \
  --host 127.0.0.1 \
  --port 44000 \
  --fps 15 \
  --count 90 \
  --scale 0.50 \
  --jpeg-quality 60 \
  --verbose
```

## Local JPEG Input Protocol

Both `macvr-runtime --jpeg-input-port <port>` and `macvr-bridge-sim --jpeg-input-port <port>` listen on `127.0.0.1:<port>` and expect repeated frames encoded as:

```text
uint32_be length
<length bytes of JPEG payload>
```

The bundled runtime validates the JPEG with ImageIO, records width and height metadata, and makes the latest accepted frame available to bridge-jpeg clients.

## Live macOS Capture Sender

- `macvr-capture-sender` captures the selected macOS display, optionally scales it down, JPEG-encodes it, and pushes the result into `macvr-runtime` or `macvr-bridge-sim`.
- Use `--list-displays` to discover available display IDs.
- Lower `--scale` or `--jpeg-quality` if your frames exceed the runtime's `--jpeg-max-bytes` limit.
- Screen Recording permission must be granted to the terminal or packaged app that launches the sender.

## GUI Receiver Notes

- `macvr-viewer` uses the same TCP control and UDP frame transport as `macvr-client`, but renders the newest JPEG frame inside a polished macOS GUI with hover tooltips, rolling throughput metrics, and stereo split/duplicate preview modes.
- `macvr-viewer --headless` runs the same receiver stack without opening a window, which is useful for automated smoke tests and release verification.
- Use duplicate mode when your sender is mono.
- Use split mode when the incoming frame already contains left and right eye views side by side.
- The control center can launch the packaged viewer directly from a release bundle.

## OpenXR Runtime Notes

- The included OpenXR runtime is experimental and headless-first.
- It supports loader negotiation, instance and system creation, headless session creation, reference spaces, frame timing, and stereo view location.
- It does not yet implement production graphics API integration or swapchain rendering.
- The fastest way to point an OpenXR loader at it is to write a manifest with `macvr-runtime --write-openxr-manifest ...`.

## Wine Helpers

Initialize a Wine prefix:

```bash
scripts/wine/setup-wine-vr-prefix.sh "$HOME/.macvr/wineprefix"
```

Launch Steam inside that prefix:

```bash
scripts/wine/run-steam-with-macvr.sh "$HOME/.macvr/wineprefix"
```

Build a Windows sender executable from the same portable source used by the native sender:

```bash
scripts/wine/build-jpeg-sender-win32.sh "$PWD/.build/win/macvr-jpeg-sender.exe"
wine64 "$PWD/.build/win/macvr-jpeg-sender.exe" \
  --host 127.0.0.1 \
  --port 44000 \
  --jpeg-file 'Z:\tmp\macvr-bridge-frame.jpg' \
  --fps 30 \
  --count 90 \
  --verbose
```

## Versioning

- Project release version: `0.4.0`
- Wire protocol version: `1`
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Release notes: [docs/releases/v0.4.0.md](docs/releases/v0.4.0.md)
- Release packager: `scripts/release/build-release.sh`

## Licensing And Credits

- Project license: [MIT](LICENSE)
- Third-party notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
- Research notes used to scope interoperability work: [docs/native-macos-vr-research.md](docs/native-macos-vr-research.md)

Referenced interoperability and research projects credited in this release include FEX (Ryan Houdek and contributors), Proton (Valve Corporation), Wine (the Wine project authors), OpenXR-SDK-Source (Khronos Group and contributors), Monado contributors, and ALVR (polygraphene and alvr-org).

## Current Limits

- The included OpenXR runtime is not yet a full graphics-capable production runtime.
- SteamVR, Wine, Proton, ALVR, Virtual Desktop, and Apple Game Porting Toolkit remain optional external tools; they are not bundled or redistributed by this repository.
- The shipped sender/receiver path now covers native macOS capture, runtime ingest, network transport, and GUI receive, but it is still a desktop preview pipeline rather than a Quest-ready headset compositor with tracked controller input.
- The release now includes macOS `.app` bundles for both the control center and the viewer, but they are ad-hoc signed for local use and are not notarized with an Apple Developer ID certificate.

# macVR

`macVR` is an experimental macOS toolkit for VR streaming and interoperability work. It provides a native macOS host/client transport stack, a bridge ingest path for externally produced frames, and tooling for feeding Wine or Game Porting Toolkit workflows into that bridge.

Current release: `0.1.0`

This project is CLI-first. It is not yet a full OpenXR runtime replacement, and it does not bundle SteamVR, Wine, Proton, ALVR, Virtual Desktop, or Apple Game Porting Toolkit.

Support the project: [buymeacoffee.com/einnovoeg](https://buymeacoffee.com/einnovoeg)

## What It Does

- Streams mock, display-captured, or externally bridged JPEG frames over UDP.
- Negotiates client/host control traffic over a simple JSON-line TCP protocol.
- Accepts bridge-producer control traffic plus authenticated UDP frame ingestion.
- Provides a local TCP JPEG ingest seam so external tooling can push frames into the bridge path.
- Ships a portable JPEG sender stub that can be used natively on macOS or cross-compiled for Windows/Wine experiments.

## Included Tools

- `macvr-host`: host runtime for `mock`, `display-jpeg`, and `bridge-jpeg` modes.
- `macvr-client`: client transport probe that receives stream data and can save JPEG frames.
- `macvr-bridge-sim`: bridge producer shim with generated, file, directory, and TCP JPEG input modes.
- `macvr-jpeg-sender`: portable helper that repeatedly sends `uint32_be length + JPEG bytes` to the bridge simulator input socket.

## System Requirements

- macOS 13 or later
- Xcode command line tools with Swift 6.2 support
- Screen Recording permission if you use `display-jpeg`

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

## Quick Start

### Mock Transport Smoke Test

Terminal 1:

```bash
swift run macvr-host --stream-mode mock --fps 72 --verbose
```

Terminal 2:

```bash
swift run macvr-client --stream-mode mock --verbose
```

### Bridge JPEG Smoke Test

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
swift run macvr-jpeg-sender \
  --host 127.0.0.1 \
  --port 44000 \
  --jpeg-file /tmp/macvr-bridge-frame.jpg \
  --fps 30 \
  --verbose
```

## Bridge Input Protocol

`macvr-bridge-sim --jpeg-input-port <port>` listens on `127.0.0.1:<port>` and expects repeated frames encoded as:

```text
uint32_be length
<length bytes of JPEG payload>
```

If no fresh input arrives for about two seconds, the bridge simulator falls back to its file, directory, or generated-frame sources.

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
  --verbose
```

## Versioning

- Project release version: `0.1.0`
- Wire protocol version: `1`
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Release notes: [docs/releases/v0.1.0.md](docs/releases/v0.1.0.md)

## Licensing And Credits

- Project license: [MIT](LICENSE)
- Third-party notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
- Research notes used to scope interoperability work: [docs/native-macos-vr-research.md](docs/native-macos-vr-research.md)

## Known Limits

- No headset runtime is bundled.
- No graphical desktop UI is included in this release.
- `display-jpeg` is intended for transport validation, not low-latency production PCVR.
- Wine, GPTK, SteamVR, and Quest ecosystem tools remain external user-supplied components.

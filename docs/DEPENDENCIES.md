# Dependencies

## Required To Build

- macOS 13 or later
- Xcode command line tools with Swift 6.2 support
- Apple system frameworks used by the source:
  - Foundation
  - Network
  - CoreGraphics
  - ImageIO
  - UniformTypeIdentifiers
  - AppKit
  - SwiftUI

## Required To Run The Included Tools

- No third-party Swift packages are required.
- `macvr-host`, `macvr-client`, `macvr-bridge-sim`, `macvr-jpeg-sender`, `macvr-capture-sender`, `macvr-runtime`, `macvr-control-center`, and `macvr-viewer` all build from the sources in this repository.
- `MacVROpenXRRuntime` builds from the vendored Khronos OpenXR headers plus the C source in this repository.
- Screen Recording permission is required if you run `macvr-host --stream-mode display-jpeg` or `macvr-capture-sender`.

## Optional Runtime Dependencies

- `wine64`
  - Needed only for Wine-based Windows application experiments.

- `winetricks`
  - Needed only for `scripts/wine/setup-wine-vr-prefix.sh`.

- `x86_64-w64-mingw32-gcc` or `zig`
  - Needed only to build `macvr-jpeg-sender.exe` with `scripts/wine/build-jpeg-sender-win32.sh`.

## Optional Release Packaging Tools

- `codesign`
  - Used by `scripts/release/build-release.sh` to ad-hoc sign the generated `.app` bundles when the tool is available.

- `ditto`
  - Used to produce the macOS zip artifact from the staged release directory.

- `shasum`
  - Used to generate the release checksum file for the packaged zip artifact.

## Optional Ecosystem Software

- Apple Game Porting Toolkit
  - Optional user-supplied tooling for Windows game evaluation and porting.

- Steam for Windows inside Wine or GPTK
  - Optional user workflow component.

- Quest streaming and display tooling
  - Optional and user-supplied. Not bundled by this repository.

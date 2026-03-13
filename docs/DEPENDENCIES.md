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

## Required To Run Core Tools

- No third-party Swift packages are required.
- `macvr-host`, `macvr-client`, `macvr-bridge-sim`, and `macvr-jpeg-sender` build from the sources in this repository.

## Optional Runtime Dependencies

- `wine64`
  - Needed only for Wine-based Windows application experiments.

- `winetricks`
  - Needed only for `scripts/wine/setup-wine-vr-prefix.sh`.

- `x86_64-w64-mingw32-gcc` or `zig`
  - Needed only to build `macvr-jpeg-sender.exe` with `scripts/wine/build-jpeg-sender-win32.sh`.

## Optional Ecosystem Software

- Apple Game Porting Toolkit
  - Optional user-supplied tooling for Windows game evaluation and porting.

- Steam for Windows inside Wine or GPTK
  - Optional user workflow component.

- Quest streaming/display tooling
  - Optional and user-supplied. Not bundled by this repository.

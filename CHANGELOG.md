# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project uses Semantic Versioning for public releases.

## [0.2.0] - 2026-03-15

### Added

- Bundled `macvr-runtime` service that combines bridge ingest, local JPEG input, and host streaming into one native macOS runtime process.
- `macvr-control-center`, a SwiftUI desktop control center with hover tooltips on every interactive control.
- `MacVROpenXRRuntime`, an experimental OpenXR runtime shim that negotiates with the loader and supports headless session flow.
- OpenXR manifest generation helpers and CLI support through `macvr-runtime --write-openxr-manifest`.
- Runtime integration tests that exercise manifest generation and the experimental OpenXR headless session path.
- Versioned macOS release packaging that produces a `.app` bundle, CLI tool set, zip archive, and SHA-256 checksum file.

### Changed

- Promoted the public release line from `0.1.x` to `0.2.0` to reflect the new bundled runtime and GUI surface.
- Extended the shared host logger so the GUI mirrors the same runtime log lines emitted by the CLI tools.
- Reworked the README and release metadata to describe the bundled runtime, the control center, and the experimental OpenXR shim.
- Updated dependency and third-party notice documentation to cover the vendored Khronos OpenXR headers now included in the source tree.
- Updated the control center so its copied sender command prefers packaged binaries when running from a release bundle.

### Fixed

- Removed the current-release limitation that no OpenXR runtime, bundled runtime, or graphical control center was shipped.
- Verified the new runtime path with an end-to-end smoke test using `macvr-runtime`, `macvr-client`, and `macvr-jpeg-sender`.
- Verified exported OpenXR runtime symbols and manifest generation against the built dylib.
- Verified the packaged `.app` bundle launches cleanly from the generated release directory.

## [0.1.1] - 2026-03-14

### Added

- Release consistency test that checks the checked-in `VERSION` file against the Swift release constant.
- Patch release notes for the 0.1.1 cleanup, metadata, and shutdown-handling update.

### Changed

- Removed personal support and repository URLs from the README in favor of neutral public-publishing instructions.
- Loaded the JPEG sender release string from `VERSION` through the package manifest so C-target metadata is less likely to drift.
- Expanded public attribution text in the README and third-party notices.

### Fixed

- `macvr-host` now handles `Ctrl+C` and termination signals with the same clean shutdown path as the other CLI tools.
- Host JPEG quality clamping now matches the documented `1-100` CLI range.

## [0.1.0] - 2026-03-13

### Added

- Native macOS host/client transport scaffold for `mock`, `display-jpeg`, and `bridge-jpeg` modes.
- Authenticated bridge ingest service with TCP control and UDP chunk transport.
- Bridge simulator reconnect logic, keepalive handling, file/directory JPEG sources, and local TCP JPEG ingest.
- Portable `macvr-jpeg-sender` helper for pushing JPEG frames into the bridge seam.
- Wine helper scripts for prefix setup, Steam launch, and Windows sender cross-build.
- Public release metadata including version file, MIT license, dependency list, third-party notices, and release notes.

### Changed

- Cleaned repository metadata for public publishing.
- Improved CLI release metadata with `--version` support.
- Reworked README for installation, usage, limitations, and compliance details.

### Fixed

- Bridge simulator reconnect handling after host restarts.
- Host stale-frame dropping for disconnected bridge producers.
- Client control-channel reconnect behavior after host restarts.

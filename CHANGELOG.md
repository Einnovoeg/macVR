# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project uses Semantic Versioning for public releases.

## [0.7.0] - 2026-04-08

### Added

- Trusted-client persistence in `MacVRRuntimeCore` via `TrustedClientStore` with JSON-backed allowlist entries.
- Runtime trust-policy enforcement (`RuntimeTrustPolicy`) that can require explicit trust before a client hello handshake is accepted.
- Host-core authorization seam (`ClientIdentity`, `ClientAuthorizationDecision`, and `HostClientAuthorizer`) so runtime policy can gate session startup.
- Runtime CLI trust-management commands:
  - `--require-trusted-clients`
  - `--no-auto-trust-loopback`
  - `--trusted-clients-path`
  - `--trust-client <client@host>`
  - `--untrust-client <client@host>`
  - `--list-trusted-clients`
- Control-center trusted-client GUI workflow with hover-tooltips on all new controls:
  - strict-trust toggles
  - trusted-clients path field
  - add/remove trusted-client entry management
- Runtime integration tests covering trusted-client store persistence and strict-trust policy decisions.

### Changed

- Promoted the public release line from `0.6.0` to `0.7.0`.
- Expanded runtime status snapshots and periodic CLI status lines to include trusted-client inventory and denied-untrusted counts.
- Updated viewer stream-state handling so server error messages surface clearly in the GUI state panel.
- Updated README quick-start documentation with trusted-client policy usage and trust-store management examples.

### Fixed

- Fixed trusted-client JSON reload behavior by aligning date decoding with the persisted ISO-8601 encoding strategy.
- Verified clean `swift build` and `swift test` with strict trust-path code included in default targets.

## [0.6.0] - 2026-04-07

### Added

- ALVR-style UDP runtime discovery protocol (`RuntimeDiscoveryProbe` and `RuntimeDiscoveryAnnouncement`) in `MacVRProtocol`.
- Runtime discovery listener in `macvr-runtime` with configurable `--discovery-port` and `--server-name`.
- Viewer-side discovery client and GUI controls to discover runtimes and apply discovered host/port values without manual entry.
- Discovery protocol coverage in wire tests and a runtime integration test that verifies a live discovery reply path.
- Packaged app icon asset (`assets/macvr.icns`) and release bundling support so GUI apps ship with a visible icon.
- Continuity file `AGENTS.md` for future agent handoff.

### Changed

- Promoted the public release line from `0.5.0` to `0.6.0`.
- Moved incomplete runtime-core tracking plugin experiments out of `Sources/MacVRRuntimeCore/` so the default build remains stable.
- Updated release packager Info.plist generation to include `CFBundleIconFile` and stage icon resources for both GUI apps.
- Refined runtime and viewer network host-string decoding to avoid deprecated `String(cString:)` usage.
- Renamed `Sources/MacVRViewerApp/main.swift` to `Sources/MacVRViewerApp/ViewerApp.swift` to keep SwiftPM entrypoint behavior stable once multiple viewer source files are present.

### Fixed

- Restored clean `swift build` and `swift test` execution after discovery and viewer changes.
- Verified end-to-end runtime/viewer streaming with discovery listener active and live JPEG frame ingress.

## [0.5.0] - 2026-03-23

### Added

- Binary tracking-state handoff in `MacVRHostCore` so the bundled runtime and standalone host can persist the latest validated head pose for the OpenXR runtime shim.
- `macvr-runtime --tracking-state-path` and `macvr-host --tracking-state-path` for explicit pose-handoff file control during testing and packaging.
- OpenXR integration coverage that verifies `xrLocateSpace` and `xrLocateViews` consume the tracking-state file instead of always returning the synthetic fallback pose.

### Changed

- Promoted the public release line from `0.4.0` to `0.5.0` to reflect transport-driven head tracking reaching the shipped OpenXR runtime path.
- Normalized incoming pose quaternions before writing tracking-state snapshots so OpenXR callers receive unit-orientation data even if a client sends approximate values.
- Updated the viewer and CLI client synthetic pose generators to emit proper yaw quaternions instead of denormalized placeholder values.
- Expanded the README quick start to document the tracking-state path and `MACVR_TRACKING_STATE_PATH` override.
- Release packaging now stages the raw `macvr-control-center` executable in `dist/.../bin/` alongside the packaged `.app` bundles.

### Fixed

- Fixed build failures caused by app-target references to host-core tracking helpers without the correct dependency boundary.
- Fixed runtime pose handoff so the OpenXR shim can answer view and space location calls from live transport data instead of only a hard-coded head pose.
- Verified a live runtime + viewer smoke flow that writes the tracking-state file at the configured path.

## [0.4.0] - 2026-03-23

### Added

- `macvr-viewer`, a native SwiftUI GUI receiver that connects to the macVR control channel, receives UDP frame traffic, decodes incoming JPEG frames, and displays a stereo preview with live transport metrics.
- `macvr-viewer --headless`, a deterministic non-GUI verification mode for automated transport and release smoke tests.
- Packaged `macVR Viewer.app` output in the release builder alongside the existing `macVR Control Center.app`.
- Control-center integration for launching the packaged viewer directly from the release bundle or local build output.

### Changed

- Promoted the public release line from `0.3.0` to `0.4.0` to reflect the new end-to-end sender/runtime/receiver workflow.
- Reworked the README quick start so the primary smoke path uses the GUI viewer instead of only the terminal probe.
- Removed the reviewed-but-unintegrated experimental renderer, audio, controller, and tracking files from the build so the public package only ships code that is documented and verified.

### Fixed

- Eliminated build warnings introduced by unintegrated experimental runtime-core files.
- Removed a custom unlicensed `xr_metal.h` experiment that did not match the shipped OpenXR runtime surface and should not have been part of a release.
- Cleaned Finder metadata artifacts from the repository tree.

## [0.3.0] - 2026-03-15

### Added

- `macvr-capture-sender`, a native macOS live display capture sender that pushes JPEG frames into the bundled runtime or bridge simulator over the existing localhost TCP seam.
- Shared `DisplayCapture` helper in `MacVRHostCore` so the host `display-jpeg` mode and the new capture sender reuse the same scaling and JPEG-encoding logic.
- Release packaging now includes `macvr-capture-sender` alongside the existing GUI, runtime, and CLI binaries.
- Release notes for the new live-capture workflow in `docs/releases/v0.3.0.md`.

### Changed

- Promoted the public release line from `0.2.0` to `0.3.0` to reflect the new native live-capture sender workflow.
- Updated the control center so its copy-to-clipboard command now prefers the new live capture sender instead of the static JPEG file sender.
- Reworked the README quick-start flow to document live macOS display capture directly into `macvr-runtime`.
- Clarified dependency notes so Screen Recording permission is explicitly called out for both `display-jpeg` and `macvr-capture-sender`.

### Fixed

- Verified a full end-to-end live capture path using `macvr-runtime`, `macvr-client`, and `macvr-capture-sender`.
- Removed duplicated display capture and JPEG encoding logic between the host frame source and the new sender path.
- Corrected stale fallback version text in the portable C JPEG sender so non-package builds no longer report an outdated release.

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

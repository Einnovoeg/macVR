# Project Continuity Notes

## 1. Point Of This Project

`macVR` is an experimental macOS-native VR runtime toolkit aimed at ALVR-style usability on macOS: runtime discovery, stable session negotiation, transport, and viewer/control-center tooling. The long-term target is deeper OpenXR runtime capability for VR applications launched from Steam/Wine/GPTK-like workflows.

## 2. What Has Been Done

Current working state in workspace:
- Runtime and viewer build cleanly with discovery support.
- End-to-end verified flow is working:
  - `macvr-runtime` running
  - `macvr-viewer --headless --auto-connect`
  - `macvr-jpeg-sender` pushing JPEG frames
  - Runtime status shows increasing `inputFrames` and `bridgeFrames`
  - Viewer receives live frames
- Trusted-client flow is implemented and verified:
  - JSON-backed trusted-client store
  - optional strict trust enforcement on runtime hello handshakes
  - control-center trusted-client management panel
  - CLI trust management flags (`--trust-client`, `--untrust-client`, `--list-trusted-clients`)

Implemented features:
- Bundled runtime service (`macvr-runtime`) with bridge ingest and local JPEG ingress.
- Experimental OpenXR runtime shim (`libMacVROpenXRRuntime.dylib`) with headless session flow and tracking-state handoff.
- ALVR-style UDP discovery protocol and runtime discovery listener:
  - `RuntimeDiscoveryProbe`
  - `RuntimeDiscoveryAnnouncement`
  - runtime flags: `--discovery-port`, `--server-name`
- Viewer discovery UX:
  - discovery port field
  - `Discover Runtimes` action
  - discovered runtime list with `Use` action
- GUI apps with hover tooltips:
  - `macvr-control-center`
  - `macvr-viewer`
- Runtime trust controls:
  - `--require-trusted-clients`
  - `--no-auto-trust-loopback`
  - `--trusted-clients-path`
  - trusted-client status counters in runtime snapshots
- App icon assets and release packaging wiring:
  - `assets/macvr-icon-1024.png`
  - `assets/macvr.icns`
  - `scripts/release/build-release.sh` includes icon in both GUI app bundles

Stability and test state:
- `swift build` passes.
- `swift test` passes.
- Discovery protocol and discovery integration tests are present and passing.
- Trusted-client persistence and strict-trust policy tests are present and passing.

Repository structure changes:
- Incomplete tracking plugin experiments were moved out of the default runtime target to avoid breaking builds:
  - now in `experimental/runtime-core/`

## 3. Steps That Need To Be Taken Next

Highest-priority engineering steps:
1. Add robust codec/session negotiation path beyond JPEG (staged interfaces first, then actual encoder integration).
2. Expand OpenXR runtime path toward graphics/swapchain support.
3. Add controller input/action path and map to OpenXR action sets.
4. Add richer transport telemetry (jitter/loss/frame-drop) in viewer and control center.
5. Add LAN pairing UX for trusted-client onboarding to avoid manual host/client entry.

Release management next steps:
1. Finalize `0.7.0` release commit and tag once all docs are reviewed.
2. Run `scripts/release/build-release.sh` and validate packaged apps and binaries.
3. Publish release artifacts and release notes.

Important constraints:
- The project is not yet full SteamVR/ALVR parity. Discovery and transport are improved, but production compositor/runtime/controller parity is still incomplete.
- Keep experimental plugin files in `experimental/runtime-core/` unless they are fully integrated behind a separate target or completed implementation.

# Native macOS VR: Resource Findings (2026-03-03)

## Scope

This note summarizes what FEX, Proton, Wine, Game Porting Toolkit, and related open-source XR projects imply for building a **native macOS VR application**.

## 1) FEX

- FEX is described as a fast usermode x86/x86-64 emulator for **Arm64 Linux**.
- Its README states it runs x86 applications on **ARM64 Linux devices** and lists Linux distro prerequisites.
- Practical implication: not a native macOS execution path.

## 2) Proton

- Proton is defined by Valve as a tool for Steam Play that allows Windows games to run on **Linux**.
- It is Wine-based and tuned for Steam/Linux compatibility.
- Practical implication: Proton is not a native macOS runtime strategy.

## 3) Wine

- Wine wiki content states support for macOS Catalina (10.15.4)+ and Apple Silicon via Rosetta 2.
- Wine can run many Windows binaries on macOS, but this is still compatibility-layer behavior, not native macOS XR runtime behavior.
- Practical implication: useful as a bridge/prototyping layer, but not sufficient by itself for robust PCVR runtime parity on macOS.

## 4) Game Porting Toolkit (GPTK)

- Apple positions GPTK as a toolkit to bring games to Apple platforms.
- Apple specifically describes running an unmodified Windows binary in an **evaluation environment for Windows games** to estimate performance and validate shaders.
- Apple also highlights migration tools (Metal shader converter, examples for converting display/input/audio APIs).
- Practical implication: GPTK is valuable for evaluation and porting workflow, but the long-term target remains native Apple platform integration.

## 5) Other relevant open-source / ecosystem projects

### OpenXR SDK

- Khronos OpenXR-SDK-Source provides OpenXR loader/layers/sample code.
- Practical implication: this is foundational, but does not by itself provide a full headset runtime.

### Monado (OpenXR runtime)

- Monado describes itself as an open-source OpenXR runtime.
- Its README states development is currently focused on GNU/Linux, with other OS support as a future goal.
- Practical implication: not currently a strong native macOS runtime foundation.

### ALVR

- ALVR’s support table lists streamer PC OS support as Windows/Linux, with macOS marked unsupported.
- Requirements include SteamVR.
- Practical implication: ALVR does not currently provide a native macOS host path for PCVR streaming.

### KinectToVR

- KinectToVR (`k2vr`) is an open-source full-body tracking project that can inform tracker fusion and body-input architecture.
- Practical implication: useful as a tracking-pipeline reference, but not a complete macOS OpenXR runtime or SteamVR replacement.

### Virtual Desktop

- Virtual Desktop’s official site states PCVR game streaming requires a VR-ready **Windows** PC.
- Practical implication: macOS streamer support is useful for virtual displays, not full PCVR game pipeline replacement.

## Synthesis

- **Inference from the above sources:** FEX/Proton/Wine/GPTK are useful compatibility or migration tools, but none provides a complete native macOS Quest-class PCVR runtime path today.
- **Inference from OpenXR ecosystem sources:** Native macOS VR work should center on OpenXR-facing architecture, but runtime/device support on macOS remains the hard blocker.

## Recommended direction for this project

1. Keep using bridge-based architecture (macOS host + external producer path) for near-term experimentation.
2. Treat Wine/GPTK as compatibility probes for Windows binaries, not final runtime architecture.
3. Build native components where possible (render, transport, input abstraction), with OpenXR-compatible interfaces so runtime options can be swapped later.
4. Keep Quest transport as a separate concern from game compatibility (already aligned with current `macVR` architecture).

## Sources

- FEX README: https://github.com/FEX-Emu/FEX
- Proton README: https://github.com/ValveSoftware/Proton
- Wine macOS wiki content (GitLab wiki import/diff view): https://gitlab.winehq.org/wine/wine/-/wikis/MacOS/diff?version_id=cf5ca410bb6c41f16803033df5548a4aa5d7a057
- Wine wiki home text (platform statement): https://gitlab.winehq.org/wine/wine/-/wikis/home/diff?version_id=79b2ce5a03b4127fc7c5a049d63c8437d041827b
- Apple Game Porting Toolkit page: https://developer.apple.com/games/game-porting-toolkit
- OpenXR SDK source: https://github.com/KhronosGroup/OpenXR-SDK-Source
- Monado upstream project: https://gitlab.freedesktop.org/monado/monado
- ALVR README/support table: https://github.com/alvr-org/ALVR
- KinectToVR upstream project: https://github.com/KinectToVR/k2vr
- Virtual Desktop official site (requirements): https://www.vrdesktop.net/

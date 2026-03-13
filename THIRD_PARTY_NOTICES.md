# Third-Party Notices

This repository is primarily original `macVR` source code. It does not vendor or redistribute source code or binaries from the external projects listed below unless a future release explicitly says otherwise.

These projects are referenced for interoperability research, optional user workflows, or compatibility experiments. If you redistribute those projects or their binaries separately, you must comply with their original licenses in full.

## Referenced Open-Source Projects

- FEX
  - Role: Research reference for cross-architecture execution ideas.
  - Upstream: https://github.com/FEX-Emu/FEX
  - License: MIT License
  - Upstream credit: Ryan Houdek and FEX contributors

- Proton
  - Role: Research reference for Windows compatibility and Steam integration.
  - Upstream: https://github.com/ValveSoftware/Proton
  - Top-level upstream license: BSD 3-Clause license for the top-level Proton project contents.
  - Upstream copyright notice: `Copyright (c) 2018-2022, Valve Corporation`
  - Note: Proton contains many components with their own licenses. See upstream `LICENSE`, `LICENSE.proton`, and per-directory notices when redistributing Proton itself.

- Wine
  - Role: Optional user-supplied runtime for Windows application experiments.
  - Upstream: https://gitlab.winehq.org/wine/wine
  - License: GNU Lesser General Public License 2.1 or later
  - Upstream copyright notice: `Copyright (c) 1993-2026 the Wine project authors`

- OpenXR-SDK-Source
  - Role: Reference implementation and API ecosystem research for future interoperability work.
  - Upstream: https://github.com/KhronosGroup/OpenXR-SDK-Source
  - License: Apache License 2.0
  - Upstream licensor: Khronos Group and contributors

- Monado
  - Role: OpenXR runtime reference for architecture research.
  - Upstream: https://gitlab.freedesktop.org/monado/monado
  - License: Boost Software License 1.0
  - Upstream project: Monado contributors

- ALVR
  - Role: Streaming architecture reference.
  - Upstream: https://github.com/alvr-org/ALVR
  - License: MIT License
  - Upstream copyright notices:
    - `Copyright (c) 2018-2019 polygraphene`
    - `Copyright (c) 2020-2024 alvr-org`

## Referenced Proprietary Software

- Apple Game Porting Toolkit
  - Role: Optional user-supplied evaluation and porting tool.
  - Upstream: https://developer.apple.com/games/game-porting-toolkit
  - Status: Proprietary Apple software. Not redistributed by this repository.

- Virtual Desktop
  - Role: Ecosystem reference for Quest desktop/PCVR streaming behavior.
  - Upstream: https://www.vrdesktop.net/
  - Status: Proprietary software. Not redistributed by this repository.

## Compliance Notes

- This repository's own source code is released under the MIT License.
- Referencing, launching, or interoperating with external software does not transfer that software's license into this repository.
- If future releases vendor source code, binaries, headers, assets, or copied documentation from any third-party project, this notices file must be updated before release.

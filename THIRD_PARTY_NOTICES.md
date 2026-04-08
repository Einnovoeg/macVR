# Third-Party Notices

This repository is primarily original `macVR` source code. It references several external projects for interoperability work, and it now vendors a small subset of Khronos OpenXR header files in `Sources/MacVROpenXRRuntime/include/openxr/` so the included runtime shim matches the upstream loader ABI.

If you redistribute any third-party project separately from this repository, you must comply with that project's original license terms in full.

## Credit Summary

This release explicitly credits the primary upstream authors and organizations referenced or partially vendored by the project:

- FEX: Ryan Houdek and FEX contributors
- Proton: Valve Corporation
- Wine: the Wine project authors
- OpenXR-SDK-Source: Khronos Group and contributors
- Monado: Monado contributors
- ALVR: polygraphene and alvr-org contributors

## Vendored Third-Party Source

- OpenXR headers and loader negotiation declarations
  - Location in this repository:
    - `Sources/MacVROpenXRRuntime/include/openxr/openxr.h`
    - `Sources/MacVROpenXRRuntime/include/openxr/openxr_loader_negotiation.h`
    - `Sources/MacVROpenXRRuntime/include/openxr/openxr_platform_defines.h`
  - Upstream source: https://github.com/KhronosGroup/OpenXR-SDK
  - Upstream copyright notice:
    - `Copyright 2017-2026 The Khronos Group Inc.`
  - SPDX license identifier carried by the vendored headers:
    - `Apache-2.0 OR MIT`
  - License texts shipped in this repository:
    - `licenses/Khronos-OpenXR-Headers-Apache-2.0.txt`
    - `licenses/Khronos-OpenXR-Headers-MIT.txt`
  - Role in this repository:
    - Provides the exact OpenXR loader/runtime ABI declarations used by the experimental `MacVROpenXRRuntime` dylib.

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
  - Role: Reference implementation, specification ecosystem, and source of the vendored OpenXR headers used by the runtime shim.
  - Upstream: https://github.com/KhronosGroup/OpenXR-SDK-Source
  - License: Apache License 2.0 or MIT for the vendored header subset as marked by upstream SPDX identifiers.
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

- KinectToVR
  - Role: Full-body tracking pipeline reference for input/pose architecture exploration.
  - Upstream: https://github.com/KinectToVR/k2vr
  - License: GNU General Public License v3.0 (as declared by the upstream repository)
  - Upstream project: KinectToVR contributors

## Referenced Proprietary Software

- Apple Game Porting Toolkit
  - Role: Optional user-supplied evaluation and porting tool.
  - Upstream: https://developer.apple.com/games/game-porting-toolkit
  - Status: Proprietary Apple software. Not redistributed by this repository.

- Virtual Desktop
  - Role: Ecosystem reference for Quest desktop and PCVR streaming behavior.
  - Upstream: https://www.vrdesktop.net/
  - Status: Proprietary software. Not redistributed by this repository.

## Compliance Notes

- This repository's original source code is released under the MIT License.
- The vendored Khronos OpenXR headers retain their upstream copyright notices and SPDX identifiers.
- The accompanying Apache 2.0 and MIT license texts for the vendored Khronos header subset are shipped in the `licenses/` directory.
- Referencing, launching, or interoperating with external software does not transfer that software's license into this repository.
- If future releases vendor additional source code, binaries, headers, assets, or copied documentation from any third-party project, this notices file must be updated before release.

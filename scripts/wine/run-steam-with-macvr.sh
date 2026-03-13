#!/usr/bin/env bash
set -euo pipefail

PREFIX_PATH="${1:-$HOME/.macvr/wineprefix}"
WINE_BIN="${WINE_BIN:-wine64}"
STEAM_EXE="${STEAM_EXE:-C:\\Program Files (x86)\\Steam\\steam.exe}"

# Optional bridge DLL paths. If provided, they are copied into the prefix and
# wired with DLL overrides for OpenVR/OpenXR interception.
OPENVR_BRIDGE_DLL="${OPENVR_BRIDGE_DLL:-}"
OPENXR_BRIDGE_DLL="${OPENXR_BRIDGE_DLL:-}"

if ! command -v "$WINE_BIN" >/dev/null 2>&1; then
  echo "error: $WINE_BIN not found in PATH (set WINE_BIN=... to override)." >&2
  exit 1
fi

export WINEPREFIX="$PREFIX_PATH"
export WINEARCH=win64

if [[ -n "$OPENVR_BRIDGE_DLL" ]]; then
  cp "$OPENVR_BRIDGE_DLL" "$WINEPREFIX/drive_c/windows/system32/openvr_api.dll"
  "$WINE_BIN" reg add "HKCU\\Software\\Wine\\DllOverrides" /v openvr_api /d native,builtin /f >/dev/null
  echo "Installed OpenVR bridge override: openvr_api.dll"
fi

if [[ -n "$OPENXR_BRIDGE_DLL" ]]; then
  cp "$OPENXR_BRIDGE_DLL" "$WINEPREFIX/drive_c/windows/system32/openxr_loader.dll"
  "$WINE_BIN" reg add "HKCU\\Software\\Wine\\DllOverrides" /v openxr_loader /d native,builtin /f >/dev/null
  echo "Installed OpenXR bridge override: openxr_loader.dll"
fi

echo "Launching Steam in prefix: $WINEPREFIX"
exec "$WINE_BIN" "$STEAM_EXE"

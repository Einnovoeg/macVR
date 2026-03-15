#!/usr/bin/env bash
set -euo pipefail

# Build a reproducible macOS release directory containing the packaged control
# center app, CLI tools, runtime shim, public docs, and a zip artifact.

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
VERSION=$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")
ARCH=$(uname -m)
PRODUCT_NAME="macVR"
RELEASE_DIR=${1:-"$ROOT_DIR/dist/${PRODUCT_NAME}-${VERSION}-macos-${ARCH}"}
BUILD_DIR="$ROOT_DIR/.build/release"
APP_NAME="macVR Control Center.app"
APP_DIR="$RELEASE_DIR/$APP_NAME"
APP_MACOS_DIR="$APP_DIR/Contents/MacOS"
APP_RESOURCES_DIR="$APP_DIR/Contents/Resources"
BIN_DIR="$RELEASE_DIR/bin"
DOCS_DIR="$RELEASE_DIR/docs"
ZIP_PATH="${RELEASE_DIR}.zip"
CHECKSUM_PATH="${ZIP_PATH}.sha256"

if [[ -z "$VERSION" ]]; then
  echo "VERSION file is empty" >&2
  exit 1
fi

rm -rf "$RELEASE_DIR" "$ZIP_PATH" "$CHECKSUM_PATH"
mkdir -p "$APP_MACOS_DIR" "$APP_RESOURCES_DIR" "$BIN_DIR" "$DOCS_DIR"

swift build -c release --disable-sandbox --package-path "$ROOT_DIR"

# The control center expects the runtime shim next to its executable when it
# resets manifest paths inside the packaged .app.
cp "$BUILD_DIR/macvr-control-center" "$APP_MACOS_DIR/macvr-control-center"
cp "$BUILD_DIR/libMacVROpenXRRuntime.dylib" "$APP_MACOS_DIR/libMacVROpenXRRuntime.dylib"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>macvr-control-center</string>
  <key>CFBundleIdentifier</key>
  <string>com.macvr.controlcenter</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>macVR Control Center</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

cp "$BUILD_DIR/macvr-host" "$BIN_DIR/"
cp "$BUILD_DIR/macvr-client" "$BIN_DIR/"
cp "$BUILD_DIR/macvr-bridge-sim" "$BIN_DIR/"
cp "$BUILD_DIR/macvr-jpeg-sender" "$BIN_DIR/"
cp "$BUILD_DIR/macvr-runtime" "$BIN_DIR/"
cp "$BUILD_DIR/libMacVROpenXRRuntime.dylib" "$BIN_DIR/"

cp "$ROOT_DIR/README.md" "$RELEASE_DIR/"
cp "$ROOT_DIR/LICENSE" "$RELEASE_DIR/"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RELEASE_DIR/"
cp "$ROOT_DIR/CHANGELOG.md" "$RELEASE_DIR/"
cp "$ROOT_DIR/VERSION" "$RELEASE_DIR/"
cp "$ROOT_DIR/docs/DEPENDENCIES.md" "$DOCS_DIR/"
cp "$ROOT_DIR/docs/releases/v${VERSION}.md" "$DOCS_DIR/RELEASE_NOTES.md"
cp -R "$ROOT_DIR/licenses" "$RELEASE_DIR/"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR"
fi

find "$RELEASE_DIR" -name '.DS_Store' -delete
xattr -cr "$RELEASE_DIR"

ditto -c -k --sequesterRsrc --keepParent "$RELEASE_DIR" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"

printf 'Release directory: %s\n' "$RELEASE_DIR"
printf 'Release zip: %s\n' "$ZIP_PATH"
printf 'Checksum file: %s\n' "$CHECKSUM_PATH"

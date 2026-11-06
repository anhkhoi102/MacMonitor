#!/usr/bin/env bash
#
# Builds MacMonitor with Swift Package Manager and wraps the binary in a
# standard macOS app bundle:
#
#   build/MacMonitor.app/
#   └── Contents/
#       ├── Info.plist        <- app metadata (name, bundle id, min macOS…)
#       ├── MacOS/MacMonitor  <- the compiled executable
#       └── Resources/
#           └── AppIcon.icns  <- drawn by Scripts/make-icon.swift
#
# An .app is just a folder with this layout – no Xcode needed to create one.
#
# Usage:
#   Scripts/build.sh            # release build (optimised)
#   Scripts/build.sh debug      # debug build (faster to compile)
#   Scripts/build.sh release --open   # build, then launch the app

set -euo pipefail

CONFIG="${1:-release}"
OPEN_AFTER="${2:-}"

if [[ "$CONFIG" != "release" && "$CONFIG" != "debug" ]]; then
    echo "Usage: $0 [release|debug] [--open]" >&2
    exit 1
fi

# Always run from the project root, wherever the script is called from.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

APP_NAME="MacMonitor"
BUNDLE_ID="local.macmonitor.MacMonitor"
VERSION="1.5.0"          # Pre-release: Information, Power, US English
BUILD_NUMBER="16"
MIN_MACOS="14.0"

BUILD_DIR="$PROJECT_ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "==> Compiling ($CONFIG, arm64)…"
swift build -c "$CONFIG" --arch arm64

BIN_PATH="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: executable not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_DIR"
# Remove only our own previous build output, never anything else.
if [[ -d "$APP_DIR" && "$APP_DIR" == "$BUILD_DIR/"*.app ]]; then
    rm -r "$APP_DIR"
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

# App icon: drawn by Scripts/make-icon.swift, packed by Apple's `iconutil`.
# Regenerated only when the drawing script changes (cached in build/).
ICON_SCRIPT="$PROJECT_ROOT/Scripts/make-icon.swift"
ICON_CACHE="$BUILD_DIR/AppIcon.icns"
if [[ ! -f "$ICON_CACHE" || "$ICON_SCRIPT" -nt "$ICON_CACHE" ]]; then
    echo "==> Drawing app icon"
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    if [[ -d "$ICONSET" && "$ICONSET" == "$BUILD_DIR/AppIcon.iconset" ]]; then
        rm -r "$ICONSET"
    fi
    swift "$ICON_SCRIPT" "$ICONSET"
    iconutil -c icns "$ICONSET" -o "$ICON_CACHE"
fi
cp "$ICON_CACHE" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>          <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>           <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>       <string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSPrincipalClass</key>             <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSAppleEventsUsageDescription</key><string>MacMonitor sends Restart, Shut Down and Sleep requests to macOS only when you click those buttons on the Power page.</string>
    <key>NSLocationUsageDescription</key>   <string>macOS only shares the name of your Wi-Fi network with apps that have Location Services permission. MacMonitor uses it for nothing else and never reads or stores your location.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>macOS only shares the name of your Wi-Fi network with apps that have Location Services permission. MacMonitor uses it for nothing else and never reads or stores your location.</string>
</dict>
</plist>
PLIST

# Validate the plist we just wrote.
plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

echo "==> Ad-hoc code signing"
# "-" = ad-hoc signature: no Apple Developer account needed. Apple Silicon
# requires every executable to be signed at least this way. It is fine for
# running on YOUR Mac, but not for distributing to others (that needs a
# Developer ID certificate + notarization).
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"

SIZE="$(du -sh "$APP_DIR" | cut -f1)"
echo "==> Done: $APP_DIR ($SIZE)"
echo "    Run it with:  open \"$APP_DIR\""

if [[ "$OPEN_AFTER" == "--open" ]]; then
    open "$APP_DIR"
fi

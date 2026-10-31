#!/bin/bash
# 构建主程序、HiDPI 助手与风扇服务；支持本地或 Developer ID 签名。
# 用法：scripts/build-app.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULES="$ROOT/Modules"
CONFIG="${1:-release}"
APP="$ROOT/dist/Meridian.app"
# Keep a stable local signing identity by default. macOS privacy permissions
# are tied to the code-signing requirement; ad-hoc signing creates a new
# identity on every rebuild and makes Accessibility/Screen Recording appear
# to require authorization again.
IDENTITY="${MERIDIAN_SIGN_IDENTITY:-Toolbox Local Signing}"

cd "$ROOT"
swift build -c "$CONFIG" --product Meridian
swift build -c "$CONFIG" --package-path "$MODULES/Display" --product DisplayLabHelper
swift build -c "$CONFIG" --package-path "$MODULES/Thermal" --product FanControlLabDaemon

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
DISPLAY_BIN="$(swift build -c "$CONFIG" --package-path "$MODULES/Display" --show-bin-path)"
FAN_BIN="$(swift build -c "$CONFIG" --package-path "$MODULES/Thermal" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchServices"
cp "$BIN/Meridian" "$APP/Contents/MacOS/Meridian"
cp "$DISPLAY_BIN/DisplayLabHelper" "$APP/Contents/MacOS/DisplayLabHelper"
cp "$FAN_BIN/FanControlLabDaemon" "$APP/Contents/Library/LaunchServices/app.meridian.thermal.daemon"
cp "$MODULES/Display/Resources/helper-launchd.plist" "$APP/Contents/Resources/"
cp "$MODULES/Thermal/Resources/daemon-launchd.plist" "$APP/Contents/Resources/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

ICONSET="$ROOT/.build/AppIcon.iconset"
if [ ! -f "$ROOT/.build/AppIcon.icns" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ROOT/.build/AppIcon.icns" ]; then
    rm -rf "$ICONSET"
    swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
    iconutil -c icns "$ICONSET" -o "$ROOT/.build/AppIcon.icns"
fi
cp "$ROOT/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Developer ID distribution requires hardened runtime and a secure timestamp.
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" --identifier app.meridian.display.helper "$APP/Contents/MacOS/DisplayLabHelper"
codesign "${SIGN_ARGS[@]}" --identifier app.meridian.thermal.daemon \
    "$APP/Contents/Library/LaunchServices/app.meridian.thermal.daemon"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --deep "$APP"
echo "built $APP"

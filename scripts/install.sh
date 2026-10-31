#!/bin/bash
# 安装 dist/Meridian.app 到 /Applications 并启动（--no-open 只安装）；旧版本先退出并移到废纸篓。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/Meridian.app"
DEST="/Applications/Meridian.app"
[ -d "$SRC" ] || { echo "先运行 scripts/build-app.sh"; exit 1; }

osascript -e 'tell application id "app.meridian.control" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
    pgrep -f "$DEST/Contents/MacOS/Meridian" >/dev/null || break
    sleep 0.5
done
pkill -f "$DEST/Contents/MacOS/Meridian" 2>/dev/null || true

if [ -d "$DEST" ]; then
    mv "$DEST" "$HOME/.Trash/Meridian-$(date +%Y%m%d-%H%M%S).app"
fi
ditto "$SRC" "$DEST"
codesign --verify --strict --deep "$DEST"
if [ "${1:-}" != "--no-open" ]; then open "$DEST"; fi
echo "installed $DEST"

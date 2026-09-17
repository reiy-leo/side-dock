#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/MultiDock.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MultiDock"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MultiDock"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "已生成 $APP"

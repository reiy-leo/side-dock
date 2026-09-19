#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/MultiDock.app"

# ⚠️ 必须带 `--disable-sandbox`：SwiftPM 自己的 `sandbox-exec` 在本机报
# `sandbox_apply: Operation not permitted`，manifest 编译失败，错误信息伪装成
# `error: 'multi-dock': Invalid manifest`（看着像 Package.swift 坏了，其实是环境问题）。
# 见 AGENTS.md §5。
swift build -c "$CONFIG" --disable-sandbox
BIN="$(swift build -c "$CONFIG" --disable-sandbox --show-bin-path)/MultiDock"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MultiDock"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "已生成 $APP"

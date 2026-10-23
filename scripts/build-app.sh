#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
# 2026-10-23 改名 Side Dock：包名带空格，下面所有路径都要加引号。
# 可执行文件、图标文件名、bundle id（local.multidock）保持旧名：登录项与配置不受影响。
APP="build/Side Dock.app"

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
cp Support/MultiDock.icns "$APP/Contents/Resources/MultiDock.icns"
# 显示名本地化（2026-10-24）：中文系统里 Finder / 启动台显示「侧边坞」，其它语言显示 Side Dock。
# 包名本身仍是「Side Dock.app」（配合 Info.plist 的 LSHasLocalizedDisplayName）。
for lproj in Support/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
done
codesign --force --sign - "$APP"

echo "已生成 $APP"

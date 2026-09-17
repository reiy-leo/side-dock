#!/bin/bash
# 客观验收「切换桌面 toast」（docs/PLAN.md §3.10）。
#
# 本机**没有屏幕录制权限**，screencapture 只返回壁纸，截图不能用来验收
# （见 AGENTS.md §4）。所以改读**窗口元数据**：CGWindowListCopyWindowInfo 读
# layer / alpha / bounds **不需要任何权限**，只有抓图（kCGWindowImage）才需要。
# 这与 P1 验证菜单栏图标（layer 25）是同一手法。
#
# 用法：
#   scripts/check-toast-window.sh                 打印 MultiDock 的所有窗口
#   scripts/check-toast-window.sh --watch [秒数]   连续观察，报告 toast 出现/消失的时刻（默认 6 秒）
#
# toast 的判别式（四条同时满足）：
#   layer == 25（.statusBar，高于 Dock 的 20）
#   onscreen == true（orderOut 后窗口还会在 CG 列表里滞留数秒，不滤掉会晚报「消失」）
#   高度 >= 30（排除菜单栏图标，它只有 ~24 高）
#   水平居中（|窗口中心 - 主屏中心| < 60pt）——菜单栏图标在屏幕角落，天然被排除

set -euo pipefail

CACHE_DIR="${TMPDIR:-/tmp}/multidock-window-dump"
BIN="$CACHE_DIR/window-dump"

build_helper() {
    mkdir -p "$CACHE_DIR"
    cat > "$CACHE_DIR/window-dump.swift" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

// stdout 重定向到文件时是块缓冲的，观察模式下会一行都看不到 —— 关掉缓冲。
setvbuf(stdout, nil, _IONBF, 0)

/// 一个候选窗口的可读快照。
struct WindowSnapshot: Equatable {
    var layer: Int
    var alpha: Double
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var onscreen: Bool

    var centerX: Double { x + width / 2 }

    var line: String {
        String(
            format: "layer=%d alpha=%.2f onscreen=%@ x=%.0f y=%.0f w=%.0f h=%.0f",
            layer, alpha, onscreen ? "yes" : "no", x, y, width, height
        )
    }
}

let arguments = CommandLine.arguments
let pid = Int32(arguments.count > 1 ? arguments[1] : "") ?? -1
let watchIndex = arguments.firstIndex(of: "--watch")
let watchSeconds = watchIndex.flatMap { arguments.count > $0 + 1 ? Double(arguments[$0 + 1]) : 6 } ?? 0

guard pid > 0 else {
    print("用法：window-dump <pid> [--watch <秒数>]")
    exit(2)
}

let mainBounds = CGDisplayBounds(CGMainDisplayID())
let mainMidX = mainBounds.midX

/// 只取本进程的窗口；toast 判别式见脚本头部注释。
///
/// **必须带 `onscreen`**：`orderOut` 之后窗口只是被标记为不在屏上，CG 窗口列表里还会
/// 滞留好几秒才真正消失（实测）。不滤掉的话「消失」时刻会晚报好几秒，1 秒时长就核对不准了。
func snapshots(toastOnly: Bool) -> [WindowSnapshot] {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [WindowSnapshot] = []
    for window in raw {
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { continue }
        let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let snapshot = WindowSnapshot(
            layer: (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
            alpha: (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1,
            x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
            y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
            width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
            height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0,
            onscreen: (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        )
        if toastOnly {
            let looksLikeToast = snapshot.layer == 25
                && snapshot.onscreen
                && snapshot.height >= 30
                && abs(snapshot.centerX - mainMidX) < 60
            guard looksLikeToast else { continue }
        }
        out.append(snapshot)
    }
    return out.sorted { ($0.layer, $0.x) < ($1.layer, $1.x) }
}

if watchSeconds > 0 {
    print("观察 \(Int(watchSeconds)) 秒（主屏 midX=\(Int(mainMidX))，每 50 ms 采样一次）…")
    let started = Date()
    var previous: [WindowSnapshot] = []
    var everSeen = false

    while Date().timeIntervalSince(started) < watchSeconds {
        let current = snapshots(toastOnly: true)
        if current != previous {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            if current.isEmpty {
                print("+\(elapsed)ms  消失")
            } else {
                everSeen = true
                for snapshot in current { print("+\(elapsed)ms  出现  \(snapshot.line)") }
            }
            previous = current
        }
        usleep(50_000)
    }

    print(everSeen ? "结论：toast 窗口出现过。" : "结论：整段观察里没看到 toast 窗口 —— 要么没切桌面，要么窗口没建出来。")
} else {
    let all = snapshots(toastOnly: false)
    print("MultiDock（PID \(pid)）的窗口共 \(all.count) 个：")
    for snapshot in all {
        let isToast = snapshot.layer == 25 && snapshot.height >= 30 && abs(snapshot.centerX - mainMidX) < 60
        print("  \(snapshot.line)\(isToast ? "   ← 疑似 toast" : "")")
    }
    if all.isEmpty { print("  （无。菜单栏图标在自动隐藏菜单栏时可能不在列表里，属正常）") }
}
SWIFT
    echo "编译窗口探测工具（只需一次）…" >&2
    swiftc -O -o "$BIN" "$CACHE_DIR/window-dump.swift"
}

[ -x "$BIN" ] || build_helper

PID="${MULTIDOCK_PID:-}"
if [ -z "$PID" ]; then
    PID="$(pgrep -f 'MultiDock\.app/Contents/MacOS/MultiDock' | head -1 || true)"
fi
if [ -z "$PID" ]; then
    PID="$(pgrep -x MultiDock | head -1 || true)"
fi
if [ -z "$PID" ]; then
    echo "找不到运行中的 MultiDock。先 ./scripts/build-app.sh && open build/MultiDock.app" >&2
    exit 1
fi

if [ "${1:-}" = "--watch" ]; then
    "$BIN" "$PID" --watch "${2:-6}"
    echo ""
    echo "--- multidock.log 里的 toast 记录（最近 10 条）---"
    LOG="$HOME/Library/Application Support/MultiDock/multidock.log"
    [ -f "$LOG" ] && grep -E "toast (显示|隐藏)" "$LOG" | tail -10 || echo "（没有日志文件）"
else
    "$BIN" "$PID"
fi

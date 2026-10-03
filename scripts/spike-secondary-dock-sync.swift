// 实验 22：次级 Dock 条与原生 Dock 的可见性同步信号（docs/spikes.md 实验 22）。
//
// 要回答的问题：
//   Q1 自动隐藏的 Dock「临时显出」（鼠标到底边）时，visibleFrame 内缩会不会变化？
//      —— 会变 → 次级条只要跟着 face 走就够；不变 → 需要别的信号。
//   Q2 一个贴在 Dock 腹地的微型探针窗口，其 occlusionState 能不能跟踪 Dock 的在屏与否？
//      —— Dock 遮挡探针（显出）= 丢 .visible；Dock 滑走（隐藏）= 拿回 .visible。
//
// 手段与风险（全部零权限）：
//   - CoreDockSetAutoHideEnabled(true/false)（实验 20 实测可用的 typed setter，Dock 自己持久化）
//     —— ⚠️ 会真的改用户 Dock 的自动隐藏设置，脚本结束时还原原值；
//   - CGWarpMouseCursorPosition —— 移动真实光标到底边触发临时显出（不投递事件，不走 TCC）；
//   - 只读采样：NSScreen.visibleFrame 内缩 / 探针窗口 occlusionState / CGWindowList（已知看不到 Dock）。
//   - ⚠️ MultiDock App 若在运行，其 DockWatcher 会把这两次 autohide 翻转当「手动改动」回存——
//     先后写回同一值，最终收敛，无净副作用。

import AppKit
import CoreGraphics
import Darwin

@_silgen_name("CoreDockSetAutoHideEnabled")
func CoreDockSetAutoHideEnabled(_ on: Bool) -> OSStatus

@_silgen_name("CoreDockGetAutoHideEnabled")
func CoreDockGetAutoHideEnabled() -> Bool

setvbuf(stdout, nil, _IONBF, 0)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.main else { print("没有主屏"); exit(1) }
let screenFrame = screen.frame
// 探针位置：Dock 区（bottom 内缩 ≈ 53）的下半段——低于半露条的下沿（条只占 Dock 区上部 ~28pt），
// 水平居中（原生 Dock 面板一定覆盖中线）。
let probePoint = CGPoint(x: screenFrame.midX - 1, y: screenFrame.minY + 14)

let probe = NSWindow(
    contentRect: NSRect(origin: probePoint, size: NSSize(width: 2, height: 2)),
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
probe.isOpaque = false
probe.backgroundColor = .clear
probe.alphaValue = 0.05           // 全透明窗口可能不参与遮挡计算，留一点点
probe.level = .init(rawValue: 19) // 低于 Dock（20）：Dock 在屏时应遮挡它
probe.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
probe.ignoresMouseEvents = true
probe.isReleasedWhenClosed = false
probe.orderFrontRegardless()

func dockWindowCount() -> Int {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerName as String] as? String) == "Dock" }.count
}

func inset() -> CGFloat {
    // 主屏 bottom 内缩（Dock 区高度）
    let visible = screen.visibleFrame
    return visible.minY - screenFrame.minY
}

func occluded() -> Bool {
    // .visible 缺席 = 被（Dock）盖住
    !probe.occlusionState.contains(.visible)
}

var lastLine = ""
func sample(_ tag: String) {
    let line = "\(tag) inset=\(String(format: "%.0f", inset())) probe被遮挡=\(occluded() ? "是" : "否") autohide=\(CoreDockGetAutoHideEnabled()) dockWin=\(dockWindowCount())"
    guard line != lastLine else { return }
    lastLine = line
    let t = String(format: "%.2f", Date().timeIntervalSince(start))
    print("[\(t)s] \(line)")
}

func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        sample("")
    }
}

let start = Date()
let originalMouse = NSEvent.mouseLocation
let cgHeight = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))

// ---- 先把光标甩离 Dock 区（否则 autohide 开了 Dock 也不会滑走）----
print("== 光标先甩到屏幕顶部中央 ==")
_ = CGWarpMouseCursorPosition(CGPoint(x: screenFrame.midX, y: 40))
pump(0.5)

// ---- 基线：autohide 关，Dock 在屏，探针应被遮挡 ----
print("== 基线（autohide 关）==")
pump(1.5)

// ---- 打开 autohide：Dock 滑走，探针应拿回可见 ----
print("== SetAutoHideEnabled(true) ==")
print("Set status=\(CoreDockSetAutoHideEnabled(true))")
pump(2.5)

// ---- 光标甩到底边：触发临时显出？ ----
print("== 光标 warp 到底边 ==")
for i in 0..<3 {
    let p = CGPoint(x: screenFrame.midX + CGFloat(i), y: cgHeight - 1)
    let err = CGWarpMouseCursorPosition(p)
    print("warp→(\(Int(p.x)),\(Int(p.y))) err=\(err.rawValue)")
    pump(0.8)
}
pump(1.5)

// ---- 光标回屏幕中央：Dock 应缩回 ----
print("== 光标 warp 回中央 ==")
_ = CGWarpMouseCursorPosition(CGPoint(x: screenFrame.midX, y: cgHeight / 2))
pump(2.5)

// ---- 还原 autohide ----
print("== 还原 SetAutoHideEnabled(false) ==")
print("Set status=\(CoreDockSetAutoHideEnabled(false))")
pump(1.5)
_ = CGWarpMouseCursorPosition(CGPoint(x: originalMouse.x, y: cgHeight - originalMouse.y))
print("== 结束（autohide 已还原）==")

// 实验 25 spike A：空间过渡进行中，对层级 19 单空间窗口下发 frame 下沉动画
//
// 验证 v3.7「沉入-拉回-升起」编排的两个前提：
//   ① 过渡动画期间改 window frame 是否即时生效、流畅（此前从未测过）；
//   ② 「沉没」与「横移」两个动画的合成观感；
//   ③ 编排终点：拉回时 frame 先置于沉没位（alpha 保持 1），升起动画回半露位。
//
// 事件源（与生产 SpaceObserver 同构，先到先触发，互为兜底）：
//   - SkyLight 16 ms 轮询（Timer.scheduledTimer——RunLoop Timer；
//     ⚠️ 第一版用 DispatchSourceTimer 挂 GCD main queue，在 RunLoop.main.run() 下
//     一次都不 fire，真机复现，见本实验日志）；
//   - NSWorkspace 通知（过渡结束后触发）。
//
// 窗口配方复刻现行 SecondaryDockWindow：level 19（低于 Dock 的 20）、
// 单空间配方 [.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]、
// borderless、不抢焦点、半露位 = visibleFrame 底边上探一半（下半被原生 Dock 盖住）。
//
// 编译运行：
//   swiftc -O -o /tmp/spike-sink-during-transition scripts/spike-sink-during-transition.swift
//   /tmp/spike-sink-during-transition
// 前提：原生 Dock 在底部、非自动隐藏；至少 2 个桌面。

import AppKit
import CoreGraphics
import Foundation
import QuartzCore

setvbuf(stdout, nil, _IONBF, 0)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MARK: - 几何：半露位 / 沉没位

let stripSize = NSSize(width: 420, height: 84)
let visibleFrame = NSScreen.main!.visibleFrame
let restFrame = NSRect(
    x: visibleFrame.midX - stripSize.width / 2,
    y: visibleFrame.minY - stripSize.height / 2,
    width: stripSize.width,
    height: stripSize.height
)
let sunkFrame = NSRect(
    x: visibleFrame.midX - stripSize.width / 2,
    y: visibleFrame.minY - stripSize.height - 6,
    width: stripSize.width,
    height: stripSize.height
)
print(String(format: "主屏 visibleFrame = %@", NSStringFromRect(visibleFrame)))
print(String(format: "半露位（起点）    = %@  [下半被原生 Dock 盖住]", NSStringFromRect(restFrame)))
print(String(format: "沉没位            = %@  [整条在原生 Dock 上缘以下]", NSStringFromRect(sunkFrame)))

// MARK: - 测试窗口（复刻 SecondaryDockWindow 配方）

final class SpikePanel: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

let window = SpikePanel(
    contentRect: restFrame,
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
window.isOpaque = false
window.backgroundColor = .clear
window.hasShadow = false
window.level = NSWindow.Level(rawValue: 19)
window.collectionBehavior = [.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]
window.isReleasedWhenClosed = false
window.isMovable = false
window.animationBehavior = .none
window.ignoresMouseEvents = true
window.alphaValue = 1

let view = NSView(frame: NSRect(origin: .zero, size: stripSize))
view.wantsLayer = true
view.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.9).cgColor
// 上缘一条亮线，让「半露边界」看得清：它在原生 Dock 上缘以上。
let edge = NSView(frame: NSRect(x: 0, y: stripSize.height - 3, width: stripSize.width, height: 3))
edge.wantsLayer = true
edge.layer?.backgroundColor = NSColor.systemYellow.cgColor
view.addSubview(edge)
let label = NSTextField(labelWithString: "SINK SPIKE：过渡中下沉 → 拉回(alpha=1) → 升起")
label.alignment = .center
label.textColor = .white
label.font = .systemFont(ofSize: 13, weight: .medium)
label.frame = NSRect(x: 0, y: 28, width: stripSize.width, height: 24)
view.addSubview(label)
window.contentView = view

window.orderFrontRegardless()
print("窗口已显示（半露位）\n")

// MARK: - 编排：下沉 → 拉回 → 升起

let sinkDuration = 0.25
let riseDuration = 0.25
var generation = 0
var lastOrchestratedSpace: UInt64?
var pollDetectedAt: Double?
var lastTriggeredByPoll = false

func runOrchestration(trigger: String, toSpace: UInt64) {
    guard lastOrchestratedSpace != toSpace else { return }
    lastOrchestratedSpace = toSpace
    generation += 1
    let gen = generation
    let t0 = CACurrentMediaTime()
    print("[\(trigger)] 编排开始：下沉 \(sinkDuration)s → 拉回(alpha=1) → 升起 \(riseDuration)s")

    // ① 下沉动画：此刻窗口仍属旧空间。若过渡动画还在进行，
    //    能看到「横移 + 下潜」的合成——这是本 spike 的核心观察点。
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = sinkDuration
        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        window.animator().setFrame(sunkFrame, display: true)
    }
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(Int((sinkDuration + 0.03) * 1000)))
        guard gen == generation else {
            print("  → 编排被新事件取代（连切），剩余步骤放弃")
            return
        }
        // ② 拉回：与生产同配方，但 alpha 全程保持 1（用沉没位代替透明隐藏）。
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(16))
        guard gen == generation else { return }
        window.collectionBehavior = [.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        print("  → 已拉回当前空间（alpha=\(window.alphaValue)，frame 已在沉没位）")
        // ③ 升起动画：从原生 Dock 身后探回半露位。
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = riseDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(restFrame, display: true)
        } completionHandler: {
            let dt = (CACurrentMediaTime() - t0) * 1000
            print(String(format: "  → 编排完成，总耗时 %.0fms", dt))
        }
    }
}

// MARK: - 事件源 ①：SkyLight 16ms 轮询（抢在过渡动画早期）

var spaceIDProbe: (() -> UInt64)?

let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
if let handle = dlopen(frameworkPath, RTLD_NOW),
   let p = dlsym(handle, "CGSMainConnectionID"),
   let g = dlsym(handle, "CGSGetActiveSpace") {
    let cid = unsafeBitCast(p, to: (@convention(c) () -> UInt32).self)()
    let getSpaceFn = unsafeBitCast(g, to: (@convention(c) (UInt32) -> UInt64).self)
    spaceIDProbe = { getSpaceFn(cid) }
    let initial = spaceIDProbe!()
    print("SkyLight 轮询已启动（16ms Timer），当前 space = \(initial)")

    var pollCount = 0
    Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
        guard let probe = spaceIDProbe else { return }
        pollCount += 1
        if pollCount == 50 { print("  [轮询自检] 50 拍 ≈ 0.8s，轮询活着") }
        let cur = probe()
        if cur != lastOrchestratedSpace ?? initial {
            pollDetectedAt = CACurrentMediaTime()
            lastTriggeredByPoll = true
            runOrchestration(trigger: "SkyLight 轮询", toSpace: cur)
        }
    }
} else {
    print("❌ SkyLight 加载失败（生产环境不会发生），仅剩通知路径")
}

// MARK: - 事件源 ②：NSWorkspace 通知（兜底 + 量到达时差）

let center = NSWorkspace.shared.notificationCenter
let token = center.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil,
    queue: .main
) { _ in
    let now = CACurrentMediaTime()
    if let tPoll = pollDetectedAt, lastTriggeredByPoll {
        print(String(format: "[NSWorkspace 通知] 到达（比轮询晚 %.0fms）", (now - tPoll) * 1000))
    } else {
        print("[NSWorkspace 通知] 到达（轮询未先行）")
    }
    pollDetectedAt = nil
    lastTriggeredByPoll = false
    if let probe = spaceIDProbe {
        runOrchestration(trigger: "NSWorkspace 通知", toSpace: probe())
    }
}

print("""

=== 等待用户手测 ===
请按顺序观察并记下结论：

① 【核心】手势左右滑动切桌面：紫色条是否在「横移的同时平滑下潜」进原生 Dock？
   —— 有无卡顿 / 跳帧 / 动画失效（条直挺挺横移或干脆消失）？
② 切换完成后：条是否从原生 Dock 后面平滑升起回半露位（黄色顶线重新可见）？
③ 对照：菜单栏点击 / ⌃→ 键盘切换（无横移动画）：下沉-升起是否依然流畅？
④ 连续快速切换 2–3 个桌面：编排是否稳定（日志「被新事件取代」为预期行为）？

判定：①若动画失效或明显卡顿 → v3.7 回退维持现行淡入编排；
      ①②流畅 → Layer 1 进入实现。
Ctrl+C 退出。

""")

withExtendedLifetime(token) {}
RunLoop.main.run()

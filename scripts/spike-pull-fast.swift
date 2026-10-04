// Spike：优化延迟版本
//
// 改动：
// 1. SkyLight 轮询从 300ms → 30ms（更快检测空间变化）
// 2. pullToActiveSpace 去掉 DispatchQueue.main.async，直接同步设回 .managed
// 3. 不依赖 NSWorkspace 通知（太慢），全靠 SkyLight 轮询
//
// 注意：轮询间隔太短会增加 CPU 占用，30ms 是个折中。

import AppKit
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let window = NSWindow(
    contentRect: NSRect(x: 300, y: 300, width: 300, height: 80),
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
window.isOpaque = false
window.backgroundColor = .clear
window.level = NSWindow.Level(rawValue: 19)
window.collectionBehavior = [.managed, .ignoresCycle]
window.isReleasedWhenClosed = false
window.isMovable = false
window.animationBehavior = .none
window.ignoresMouseEvents = true

let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
view.wantsLayer = true
view.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.85).cgColor
let label = NSTextField(labelWithString: "Secondary Dock (fast pull)\n30ms 轮询 + 无 async 延迟")
label.alignment = .center
label.textColor = .white
label.font = .systemFont(ofSize: 13, weight: .medium)
label.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
view.addSubview(label)
window.contentView = view

window.orderFrontRegardless()
print("窗口已显示")

var lastPullTime = Date()

func pullToActiveSpace() {
    // 临时 canJoinAllSpaces 让窗口可见，然后立即设回 .managed 钉在当前空间
    // 去掉 DispatchQueue.main.async，直接同步操作，减少延迟
    window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
    window.orderFrontRegardless()
    window.collectionBehavior = [.managed, .ignoresCycle]
    let now = Date()
    let elapsed = now.timeIntervalSince(lastPullTime) * 1000
    print("  → pulled (距上次 \(String(format: "%.0f", elapsed))ms)")
    lastPullTime = now
}

// SkyLight 轮询（30ms，快速检测空间变化）
let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
if let handle = dlopen(frameworkPath, RTLD_NOW),
   let p = dlsym(handle, "CGSMainConnectionID"),
   let g = dlsym(handle, "CGSGetActiveSpace") {
    let cid = unsafeBitCast(p, to: (@convention(c) () -> UInt32).self)()
    let getSpace = unsafeBitCast(g, to: (@convention(c) (UInt32) -> UInt64).self)
    var lastSpace = getSpace(cid)
    print("SkyLight 轮询已启动（30ms），当前 space = \(lastSpace)")

    Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
        let cur = getSpace(cid)
        if cur != lastSpace {
            print("SkyLight 空间变化 \(lastSpace) → \(cur)")
            lastSpace = cur
            pullToActiveSpace()
        }
    }
} else {
    print("❌ SkyLight 加载失败")
}

print("\n=== 等待用户测试 ===")
print("用触控板滑动切桌面，观察紫色窗口出现的延迟是否更小。")
print("Ctrl+C 退出。")

RunLoop.main.run()

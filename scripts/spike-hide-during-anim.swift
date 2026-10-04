// Spike：动画期间隐藏窗口，动画结束后显示
//
// 思路：
// 1. SkyLight 轮询检测到空间变化（动画刚开始，~30ms 内）
// 2. 立即 orderOut 隐藏窗口（用户看不到滑动）
// 3. 等一小段时间（动画差不多结束）后 pullToActiveSpace + orderFront
//
// 关键：隐藏后窗口不参与滑动，出现时动画已结束。

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
view.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.85).cgColor
let label = NSTextField(labelWithString: "Secondary Dock (hide during anim)\n动画期间隐藏")
label.alignment = .center
label.textColor = .black
label.font = .systemFont(ofSize: 13, weight: .medium)
label.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
view.addSubview(label)
window.contentView = view

window.orderFrontRegardless()
print("窗口已显示")

var pullWorkItem: DispatchWorkItem?
var isHidden = false

func pullToActiveSpace() {
    pullWorkItem?.cancel()
    window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
    window.orderFrontRegardless()
    DispatchQueue.main.async {
        window.collectionBehavior = [.managed, .ignoresCycle]
        isHidden = false
        print("  → pulled & shown")
    }
}

func hideAndPullAfterDelay(_ delay: TimeInterval) {
    // 立即隐藏
    window.orderOut(nil)
    isHidden = true
    pullWorkItem?.cancel()
    let item = DispatchWorkItem {
        pullToActiveSpace()
    }
    pullWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    print("  → hidden, will pull after \(Int(delay*1000))ms")
}

// SkyLight 轮询
let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
if let handle = dlopen(frameworkPath, RTLD_NOW),
   let p = dlsym(handle, "CGSMainConnectionID"),
   let g = dlsym(handle, "CGSGetActiveSpace") {
    let cid = unsafeBitCast(p, to: (@convention(c) () -> UInt32).self)()
    let getSpace = unsafeBitCast(g, to: (@convention(c) (UInt32) -> UInt64).self)
    var lastSpace = getSpace(cid)
    print("SkyLight 轮询已启动，当前 space = \(lastSpace)")

    Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
        let cur = getSpace(cid)
        if cur != lastSpace {
            print("空间变化 \(lastSpace) → \(cur)")
            lastSpace = cur
            // 150ms 后拉窗口（动画约 200-300ms，150ms 时差不多结束）
            hideAndPullAfterDelay(0.15)
        }
    }
}

// NSWorkspace 通知兜底（防止 SkyLight 没检测到）
let center = NSWorkspace.shared.notificationCenter
let token = center.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil,
    queue: .main
) { _ in
    if isHidden {
        print("NSWorkspace 通知 → 立即拉窗口")
        pullWorkItem?.cancel()
        pullToActiveSpace()
    }
}

print("\n=== 等待用户测试 ===")
print("用触控板滑动切桌面，观察黄色窗口：")
print("  - 是否滑动？")
print("  - 出现延迟是否更小？")
print("Ctrl+C 退出。")

withExtendedLifetime(token) {}
RunLoop.main.run()

// Spike：保持 canJoinAllSpaces，切换时隐藏，结束后显示
//
// 思路：
// - 窗口一直是 .canJoinAllSpaces（所有空间可见）
// - SkyLight 检测到空间变化 → 立即 orderOut 隐藏（动画期间不可见，不滑动）
// - NSWorkspace 通知（动画结束）→ 立即 orderFront 显示
// - 不用 pullToActiveSpace，延迟最小
//
// 零权限、不改系统。

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
// 保持 canJoinAllSpaces，这样显示时在所有空间可见
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
window.isReleasedWhenClosed = false
window.isMovable = false
window.animationBehavior = .none
window.ignoresMouseEvents = true

let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
view.wantsLayer = true
view.layer?.backgroundColor = NSColor.magenta.withAlphaComponent(0.85).cgColor
let label = NSTextField(labelWithString: "Secondary Dock (hide/show)\n切换时隐藏，结束显示")
label.alignment = .center
label.textColor = .white
label.font = .systemFont(ofSize: 13, weight: .medium)
label.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
view.addSubview(label)
window.contentView = view

window.orderFrontRegardless()
window.alphaValue = 1.0
print("窗口已显示")

// SkyLight 轮询：检测到变化立即隐藏
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
            print("空间变化 \(lastSpace) → \(cur) → 隐藏")
            lastSpace = cur
            window.alphaValue = 0.0
        }
    }
}

// NSWorkspace 通知：动画结束后显示
let center = NSWorkspace.shared.notificationCenter
let token = center.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil,
    queue: .main
) { _ in
    print("NSWorkspace 通知 → 显示")
    window.alphaValue = 1.0
}

print("\n=== 等待用户测试 ===")
print("用触控板滑动切桌面，观察品红色窗口：")
print("  - 是否滑动？（应该不滑动，因为切换时隐藏了）")
print("  - 延迟是否更小？")
print("Ctrl+C 退出。")

withExtendedLifetime(token) {}
RunLoop.main.run()

// Spike：NSWorkspace 通知 + 优化 pullToActiveSpace
//
// 关键：只用 NSWorkspace.activeSpaceDidChangeNotification（动画结束后触发），
// 不用 SkyLight 轮询（会在动画期间触发导致滑动）。
// pullToActiveSpace 用 asyncAfter 0.01s 设回 .managed（比 async 一帧更可控）。

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
view.layer?.backgroundColor = NSColor.systemCyan.withAlphaComponent(0.85).cgColor
let label = NSTextField(labelWithString: "Secondary Dock (NSWorkspace + fast)\n通知触发 + 短延迟")
label.alignment = .center
label.textColor = .white
label.font = .systemFont(ofSize: 13, weight: .medium)
label.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
view.addSubview(label)
window.contentView = view

window.orderFrontRegardless()
print("窗口已显示")

var pullWorkItem: DispatchWorkItem?

func pullToActiveSpace() {
    pullWorkItem?.cancel()
    window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
    window.orderFrontRegardless()
    // 10ms 后设回 .managed，确保 orderFront 已把窗口拉到当前空间
    let item = DispatchWorkItem {
        window.collectionBehavior = [.managed, .ignoresCycle]
        print("  → pulled to active space")
    }
    pullWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: item)
}

// 只用 NSWorkspace 通知（动画结束后触发，不滑动）
let center = NSWorkspace.shared.notificationCenter
let token = center.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil,
    queue: .main
) { _ in
    print("NSWorkspace 空间变化 → pullToActiveSpace()")
    pullToActiveSpace()
}

print("\n=== 等待用户测试 ===")
print("用触控板滑动切桌面，观察青色窗口：")
print("  - 是否滑动？")
print("  - 延迟是否可接受？")
print("Ctrl+C 退出。")

withExtendedLifetime(token) {}
RunLoop.main.run()

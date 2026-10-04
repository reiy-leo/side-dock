// Spike：纯 .managed（默认）窗口，不用 canJoinAllSpaces
// 测试：窗口是否还会滑动？切桌面后能否被拉到当前空间？
//
// 关键改动：完全不碰 canJoinAllSpaces。窗口初始 collectionBehavior = [.managed]（默认）。
// 空间切换后只调用 orderFrontRegardless，看能否把窗口拉到当前空间。

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
// 纯默认：.managed，不用 canJoinAllSpaces / moveToActiveSpace / stationary
window.collectionBehavior = [.managed, .ignoresCycle]
window.isReleasedWhenClosed = false
window.isMovable = false
window.animationBehavior = .none
window.ignoresMouseEvents = true

let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
view.wantsLayer = true
view.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.85).cgColor
let label = NSTextField(labelWithString: "Secondary Dock (.managed only)\n不用 canJoinAllSpaces")
label.alignment = .center
label.textColor = .white
label.font = .systemFont(ofSize: 13, weight: .medium)
label.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
view.addSubview(label)
window.contentView = view

window.orderFrontRegardless()
print("窗口已显示，collectionBehavior = [.managed, .ignoresCycle]（不用 canJoinAllSpaces）")

// 空间切换后只调用 orderFrontRegardless，看能否拉到当前空间
let center = NSWorkspace.shared.notificationCenter
let token = center.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil,
    queue: .main
) { _ in
    print("NSWorkspace 空间变化 → orderFrontRegardless()")
    window.orderFrontRegardless()
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

    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        let cur = getSpace(cid)
        if cur != lastSpace {
            print("SkyLight 空间变化 \(lastSpace) → \(cur) → orderFrontRegardless()")
            lastSpace = cur
            window.orderFrontRegardless()
        }
    }
}

print("\n=== 等待用户测试 ===")
print("用触控板滑动切桌面，观察绿色窗口：")
print("  1. 是否还滑动？")
print("  2. 切到新桌面后窗口是否还在（还是消失了）？")
print("Ctrl+C 退出。")

withExtendedLifetime(token) {}
RunLoop.main.run()

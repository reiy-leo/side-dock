// Spike：窗口只属当前空间，空间切换动画结束后拉到新空间
//
// 思路：
// - 窗口初始 .managed（只属一个空间，不参与 canJoinAllSpaces 的跨空间滑动）
// - 空间切换动画期间，窗口留在源空间被滑走（用户切到新空间后看不到旧窗口）
// - NSWorkspace.activeSpaceDidChangeNotification 在动画结束后触发，
//   此时把窗口拉到新空间：临时设 .canJoinAllSpaces → orderFront → 设回 .managed
// - SkyLight 轮询用于程序化切换（瞬时无动画，不会滑动）
//
// 预期效果：切桌面时次级条不跟着滑，而是在新空间"出现"。

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
view.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.85).cgColor
let label = NSTextField(labelWithString: "Secondary Dock (pull after anim)\n切桌面看是否'出现'而非'滑动'")
label.alignment = .center
label.textColor = .white
label.font = .systemFont(ofSize: 13, weight: .medium)
label.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
view.addSubview(label)
window.contentView = view

window.orderFrontRegardless()
print("窗口已显示，collectionBehavior = [.managed, .ignoresCycle]")

// 把窗口拉到当前空间
func pullToActiveSpace() {
    // 临时 canJoinAllSpaces 让窗口在所有空间可见，orderFront 后钉到当前空间
    window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
    window.orderFrontRegardless()
    DispatchQueue.main.async {
        window.collectionBehavior = [.managed, .ignoresCycle]
    }
    print("  → pulled to active space")
}

// NSWorkspace 通知（用户手势切换，动画结束后触发）
let center = NSWorkspace.shared.notificationCenter
let token = center.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil,
    queue: .main
) { _ in
    print("NSWorkspace 空间变化 → pullToActiveSpace()")
    pullToActiveSpace()
}

// SkyLight 轮询（程序化切换，瞬时无动画）
let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
if let handle = dlopen(frameworkPath, RTLD_NOW),
   let p = dlsym(handle, "CGSMainConnectionID"),
   let g = dlsym(handle, "CGSGetActiveSpace") {
    let cid = unsafeBitCast(p, to: (@convention(c) () -> UInt32).self)()
    let getSpace = unsafeBitCast(g, to: (@convention(c) (UInt32) -> UInt64).self)
    var lastSpace = getSpace(cid)
    print("SkyLight 轮询已启动，当前 space = \(lastSpace)")

    Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
        let cur = getSpace(cid)
        if cur != lastSpace {
            print("SkyLight 空间变化 \(lastSpace) → \(cur) → pullToActiveSpace()")
            lastSpace = cur
            pullToActiveSpace()
        }
    }
}

print("\n=== 等待用户测试 ===")
print("用触控板滑动切桌面，观察橙色窗口：")
print("  - 是否跟着桌面滑动？")
print("  - 还是在新桌面'出现'（不滑动）？")
print("Ctrl+C 退出。")

withExtendedLifetime(token) {}
RunLoop.main.run()

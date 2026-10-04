// Spike：测试不用 canJoinAllSpaces 的方案 —— 切桌面后把窗口拉到当前空间
//
// 思路：canJoinAllSpaces 让窗口参与空间过渡动画（滑动）。
// 改用 .moveToActiveSpace：窗口只属一个空间，切换时留在源空间（不可见），
// 切换完成后通过通知/SkyLight 轮询把它拉到新空间。
// 拉的方法：临时设 .canJoinAllSpaces → orderFront → 设回 .moveToActiveSpace。
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
window.collectionBehavior = [.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]
window.isReleasedWhenClosed = false
window.isMovable = false
window.animationBehavior = .none
window.ignoresMouseEvents = true

let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
view.wantsLayer = true
view.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
let label = NSTextField(labelWithString: "Secondary Dock (moveToActiveSpace)\n切桌面看是否消失再出现")
label.alignment = .center
label.textColor = .white
label.font = .systemFont(ofSize: 13, weight: .medium)
label.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
view.addSubview(label)
window.contentView = view

window.orderFrontRegardless()
print("窗口已显示，collectionBehavior = [.moveToActiveSpace, .stationary, ...]")

// 把窗口拉到当前空间：临时 canJoinAllSpaces → orderFront → 设回 moveToActiveSpace
func pullToActiveSpace() {
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    window.orderFrontRegardless()
    // 下一帧设回 moveToActiveSpace，让窗口"钉"在当前空间
    DispatchQueue.main.async {
        window.collectionBehavior = [.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
}

// 监听空间变化
let center = NSWorkspace.shared.notificationCenter
let token = center.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil,
    queue: .main
) { _ in
    print("NSWorkspace 检测到空间变化 → pullToActiveSpace()")
    pullToActiveSpace()
}

// SkyLight 轮询兜底
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
            print("SkyLight 检测到空间变化 \(lastSpace) → \(cur) → pullToActiveSpace()")
            lastSpace = cur
            pullToActiveSpace()
        }
    }
} else {
    print("⚠️ SkyLight 加载失败，仅靠 NSWorkspace 通知")
}

print("\n=== 等待用户测试 ===")
print("用触控板滑动切桌面，观察蓝色窗口是'滑动'还是'消失再出现'。")
print("Ctrl+C 退出。")

withExtendedLifetime(token) {}
RunLoop.main.run()

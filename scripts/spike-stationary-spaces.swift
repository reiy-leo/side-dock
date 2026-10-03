// Spike：验证 `.stationary` 去掉 `.canJoinAllSpaces` 后，窗口是否仍在所有空间可见。
//
// 背景：次级 Dock 条目前 `collectionBehavior = [.canJoinAllSpaces, .stationary, ...]`，
// 用户报告切桌面时条会随桌面滑动。怀疑 `.canJoinAllSpaces` 让窗口参与了空间过渡动画。
// 原生 Dock 只用 `.stationary`（不属任何空间、浮在所有空间之上、切换时不动）。
//
// 本脚本回答：只设 `.stationary`（不带 `.canJoinAllSpaces`）时，窗口跨空间是否仍可见？
// 手段：
//   - 建一个带颜色的小窗，分别测两组 collectionBehavior；
//   - 用 SkyLight 程序化切桌面（CGSManagedDisplaySetCurrentSpace，硬切 0–6ms）；
//   - 每次切完读 `window.isOnActiveSpace` + 用 CGWindowList 看窗口是否在屏。
//
// 零权限、不改系统、不碰 Dock。结束自动还原原桌面。

import AppKit
import CoreGraphics
import Foundation

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> UInt32
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: UInt32) -> Unmanaged<CFArray>?
@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: UInt32) -> UInt64
@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ cid: UInt32, _ uuid: CFString, _ space: UInt64)

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]],
      let first = displays.first,
      let displayUUID = first["Display Identifier"] as? String,
      let spaces = first["Spaces"] as? [[String: Any]]
else { print("拿不到空间列表"); exit(1) }

// 只取用户桌面（type == 0），全屏/系统空间不算。
let userSpaces = spaces.filter { ($0["type"] as? Int) == 0 }
guard userSpaces.count >= 2 else { print("需要至少 2 个用户桌面，当前 \(userSpaces.count) 个"); exit(1) }
let originalID = CGSGetActiveSpace(CGSMainConnectionID())
print("显示器 \(displayUUID.prefix(8))… 共 \(userSpaces.count) 个桌面，原活动 = \(originalID)")

func makeWindow(behavior: NSWindow.CollectionBehavior, color: NSColor) -> NSWindow {
    let w = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 220, height: 120),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    w.isOpaque = false
    w.backgroundColor = .clear
    w.level = .statusBar
    w.collectionBehavior = behavior
    w.ignoresMouseEvents = true
    w.isReleasedWhenClosed = false
    let v = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
    v.wantsLayer = true
    v.layer?.backgroundColor = color.cgColor
    w.contentView = v
    return w
}

func windowOnScreen(_ wid: CGWindowID) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { ($0[kCGWindowNumber as String] as? Int32) == Int32(wid) }
}

func runCase(_ name: String, behavior: NSWindow.CollectionBehavior, color: NSColor) {
    print("\n=== \(name) ===")
    print("behavior raw = \(behavior.rawValue)")
    let w = makeWindow(behavior: behavior, color: color)
    w.orderFrontRegardless()
    let wid = CGWindowID(w.windowNumber)
    // 等窗真正上屏
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    for sp in userSpaces {
        let id = (sp["id64"] as? UInt64) ?? 0
        CGSManagedDisplaySetCurrentSpace(CGSMainConnectionID(), displayUUID as CFString, id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let onActive = w.isOnActiveSpace
        let onScreen = windowOnScreen(wid)
        print("  切到 \(id) → isOnActiveSpace=\(onActive) 在屏=\(onScreen)")
    }
    w.orderOut(nil)
}

// Case A：当前配方（含 canJoinAllSpaces）
runCase("A: canJoinAllSpaces + stationary",
        behavior: [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle],
        color: .systemBlue.withAlphaComponent(0.8))

// Case B：去掉 canJoinAllSpaces，只留 stationary
runCase("B: 仅 stationary（无 canJoinAllSpaces）",
        behavior: [.stationary, .fullScreenAuxiliary, .ignoresCycle],
        color: .systemRed.withAlphaComponent(0.8))

// 还原
CGSManagedDisplaySetCurrentSpace(CGSMainConnectionID(), displayUUID as CFString, originalID)
print("\n已还原到原桌面 \(originalID)")

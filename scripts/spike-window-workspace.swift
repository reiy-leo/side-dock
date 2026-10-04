// Spike：探查 SkyLight 里窗口级私有 API 的可用性 + 测试 CGSSetWindowWorkspace 防滑动
//
// 背景：.stationary 是 Exposé 组的行为，不管 Spaces 过渡动画（Apple 文档原文）。
// .canJoinAllSpaces 让窗口出现在所有空间，但参与过渡动画 → 滑动。
// 没有公开 API 能同时"全空间可见"+"不滑动"。原生 Dock/菜单栏靠系统特权窗口身份。
// 本脚本探查 SkyLight 私有 API 是否能填补这个空白。
//
// 零权限、不改系统、不碰 Dock。建一个有色测试窗，用户可以触控板滑动切桌面看是否钉住。

import AppKit
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
    print("❌ 无法加载 SkyLight：\(String(cString: dlerror()))")
    exit(1)
}
print("✅ SkyLight 已加载")

func checkSymbol(_ name: String) -> Bool {
    return dlsym(handle, name) != nil
}

// 探查符号
let symbols = [
    "CGSMainConnectionID",
    "CGSSetWindowWorkspace",
    "CGSGetWindowWorkspace",
    "CGSSetWindowTags",
    "CGSGetWindowTags",
    "CGSOrderWindow",
    "CGSSetWindowLevel",
    "CGSSetWindowAlpha",
    "SLSSetWindowWorkspace",
    "SLSSetWindowLevel",
    "SLSSetWindowAlpha",
    "CGSWindowWorkspaceIDForWindow",
    "CGSSetWindowWorkspaceID",
]
print("\n=== 符号探查 ===")
for sym in symbols {
    print("  \(checkSymbol(sym) ? "✅" : "❌") \(sym)")
}

// CGSMainConnectionID
typealias MainConnFn = @convention(c) () -> UInt32
guard let p = dlsym(handle, "CGSMainConnectionID") else { print("❌ 无 CGSMainConnectionID"); exit(1) }
let cid = unsafeBitCast(p, to: MainConnFn.self)()
print("\nCID = \(cid)")

// 建测试窗
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let window = NSWindow(
    contentRect: NSRect(x: 400, y: 400, width: 300, height: 80),
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
window.isOpaque = false
window.backgroundColor = .clear
window.level = NSWindow.Level(rawValue: 19)
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
window.isReleasedWhenClosed = false
window.isMovable = false
window.animationBehavior = .none
window.ignoresMouseEvents = true

let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
view.wantsLayer = true
view.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
let label = NSTextField(labelWithString: "Secondary Dock Sticky Test\nCGSSetWindowWorkspace → 0")
label.alignment = .center
label.textColor = .white
label.font = .systemFont(ofSize: 14, weight: .medium)
label.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
view.addSubview(label)
window.contentView = view

window.orderFrontRegardless()
let wid = CGWindowID(window.windowNumber)
print("窗已建立：wid = \(wid)")

// 尝试 CGSSetWindowWorkspace
if checkSymbol("CGSSetWindowWorkspace") {
    typealias SetWorkspaceFn = @convention(c) (UInt32, CGWindowID, UInt32) -> Void
    let fn = unsafeBitCast(dlsym(handle, "CGSSetWindowWorkspace")!, to: SetWorkspaceFn.self)

    // workspace = 0 通常意味着「不属任何空间 / 浮在所有空间之上」
    fn(cid, wid, 0)
    print("✅ 已调用 CGSSetWindowWorkspace(\(cid), \(wid), 0)")

    // 读回来验证
    if checkSymbol("CGSGetWindowWorkspace") {
        typealias GetWorkspaceFn = @convention(c) (UInt32, CGWindowID) -> UInt32
        let getFn = unsafeBitCast(dlsym(handle, "CGSGetWorkspace")!, to: GetWorkspaceFn.self)
        let ws = getFn(cid, wid)
        print("  读回 workspace = \(ws)")
    }
} else if checkSymbol("SLSSetWindowWorkspace") {
    typealias SetWorkspaceFn = @convention(c) (UInt32, CGWindowID, UInt32) -> Void
    let fn = unsafeBitCast(dlsym(handle, "SLSSetWindowWorkspace")!, to: SetWorkspaceFn.self)
    fn(cid, wid, 0)
    print("✅ 已调用 SLSSetWindowWorkspace(\(cid), \(wid), 0)")
} else {
    print("⚠️ CGSSetWindowWorkspace 和 SLSSetWindowWorkspace 都不存在")
}

// 尝试 CGSSetWindowTags（设窗口标签位）
if checkSymbol("CGSSetWindowTags") {
    typealias SetTagsFn = @convention(c) (UInt32, CGWindowID, UnsafePointer<Int32>, Int) -> Void
    let fn = unsafeBitCast(dlsym(handle, "CGSSetWindowTags")!, to: SetTagsFn.self)
    // kCGSNeverFlattenSurfacesDuringSwipesTagBit = bit 16 of second Int32
    var tags: [Int32] = [0x0, (1 << 16)]
    fn(cid, wid, &tags, 0x40)
    print("✅ 已调用 CGSSetWindowTags（bit 16 = NeverFlattenSurfacesDuringSwipes）")
}

print("\n=== 等待用户测试 ===")
print("请用触控板滑动切桌面，观察红色测试窗是否钉在原地不滑动。")
print("测试完按 Ctrl+C 退出。")

RunLoop.main.run()

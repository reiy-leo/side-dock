// Spike：每个桌面一个独立窗口
//
// 思路：为每个桌面创建一个专属窗口（.managed，只属该桌面）。
// 切桌面时，旧桌面的窗口跟着旧桌面滑走，新桌面的窗口已经在新桌面显示。
// 效果：既不滑动，也无延迟。
//
// 零权限、不改系统。

import AppKit
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
guard let handle = dlopen(frameworkPath, RTLD_NOW) else { exit(1) }

func load<T>(_ name: String, as type: T.Type) -> T {
    guard let p = dlsym(handle, name) else { print("❌ \(name)"); exit(1) }
    return unsafeBitCast(p, to: T.self)
}

typealias MainConnFn = @convention(c) () -> UInt32
typealias CopySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?
typealias GetActiveFn = @convention(c) (UInt32) -> UInt64
typealias SetSpaceFn = @convention(c) (UInt32, CFString, UInt64) -> Void

let cid = load("CGSMainConnectionID", as: MainConnFn.self)()
let copySpaces = load("CGSCopyManagedDisplaySpaces", as: CopySpacesFn.self)
let getActive = load("CGSGetActiveSpace", as: GetActiveFn.self)
let setSpace = load("CGSManagedDisplaySetCurrentSpace", as: SetSpaceFn.self)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// 获取所有桌面
guard let displays = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]],
      let first = displays.first,
      let displayUUID = first["Display Identifier"] as? String,
      let spaces = first["Spaces"] as? [[String: Any]]
else { print("❌ 拿不到空间列表"); exit(1) }

let userSpaces = spaces.filter { ($0["type"] as? Int) == 0 }
let originalID = getActive(cid)
print("共 \(userSpaces.count) 个桌面，原活动 = \(originalID)")

// 为每个桌面创建一个窗口
var windows: [UInt64: NSWindow] = [:]
let colors: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemCyan, .systemYellow, .systemPink]

for (i, sp) in userSpaces.enumerated() {
    let id = (sp["id64"] as? UInt64) ?? 0
    // 切到该桌面（程序化，无动画）
    setSpace(cid, displayUUID as CFString, id)
    // 等一下让切换生效
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))

    let color = colors[i % colors.count]
    let w = NSWindow(
        contentRect: NSRect(x: 300, y: 300, width: 300, height: 80),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    w.isOpaque = false
    w.backgroundColor = .clear
    w.level = NSWindow.Level(rawValue: 19)
    w.collectionBehavior = [.managed, .ignoresCycle]
    w.isReleasedWhenClosed = false
    w.isMovable = false
    w.animationBehavior = .none
    w.ignoresMouseEvents = true

    let v = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    v.wantsLayer = true
    v.layer?.backgroundColor = color.withAlphaComponent(0.85).cgColor
    let label = NSTextField(labelWithString: "桌面 \(i+1) 的窗口")
    label.alignment = .center
    label.textColor = .white
    label.font = .systemFont(ofSize: 14, weight: .bold)
    label.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
    v.addSubview(label)
    w.contentView = v

    w.orderFrontRegardless()
    windows[id] = w
    print("  桌面 \(id) → 创建窗口（\(color.accessibilityName ?? "color")）")
}

// 切回原桌面
setSpace(cid, displayUUID as CFString, originalID)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))

print("\n=== 等待用户测试 ===")
print("用触控板滑动切桌面，观察：")
print("  - 每个桌面是否显示对应颜色的窗口？")
print("  - 切桌面时窗口是否滑动？（应该是旧窗口滑走，新窗口已在新桌面）")
print("Ctrl+C 退出。")

RunLoop.main.run()

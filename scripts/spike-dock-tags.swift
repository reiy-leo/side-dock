// Spike：读原生 Dock 窗口的 tags，复制到测试窗上看能否防滑动
//
// 零权限、不改系统、不碰 Dock 偏好。

import AppKit
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
    print("❌ 无法加载 SkyLight")
    exit(1)
}

func load<T>(_ name: String, as type: T.Type) -> T {
    guard let p = dlsym(handle, name) else {
        print("❌ 符号缺失：\(name)")
        exit(1)
    }
    return unsafeBitCast(p, to: T.self)
}

typealias MainConnFn = @convention(c) () -> UInt32
typealias GetTagsFn = @convention(c) (UInt32, CGWindowID, UnsafeMutablePointer<Int32>, Int) -> Int32
typealias SetTagsFn = @convention(c) (UInt32, CGWindowID, UnsafePointer<Int32>, Int) -> Int32

let cid = load("CGSMainConnectionID", as: MainConnFn.self)()
let getTags = load("CGSGetWindowTags", as: GetTagsFn.self)
let setTags = load("CGSSetWindowTags", as: SetTagsFn.self)

print("CID = \(cid)")

// 找 Dock 窗口——用所有选项列出，找 owner = "Dock" 且 layer ≈ 20
func findDockWindow() -> (CGWindowID, Int)? {
    let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], kCGNullWindowID) as? [[String: Any]] ?? []
    var found: [(CGWindowID, Int)] = []
    for info in list {
        guard let ownerName = info[kCGWindowOwnerName as String] as? String,
              ownerName == "Dock" else { continue }
        if let wid = info[kCGWindowNumber as String] as? Int32 {
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            found.append((CGWindowID(wid), layer))
        }
    }
    print("Dock 窗口候选: \(found.map { "wid=\($0.0) layer=\($0.1)" })")
    return found.first
}

// 读某窗口的 tags
func readTags(_ wid: CGWindowID) -> [Int32] {
    var tags: [Int32] = [0, 0]
    let ret = getTags(cid, wid, &tags, 64)
    print("  readTags(\(wid)) ret=\(ret) → [0x\(String(tags[0], radix: 16)), 0x\(String(tags[1], radix: 16))]")
    return tags
}

func writeTags(_ wid: CGWindowID, _ tags: [Int32]) {
    var t = tags
    let ret = setTags(cid, wid, t, 64)
    print("  setTags(\(wid)) ret=\(ret)")
}

// Step 1: 找 Dock 窗口
guard let (dockWID, dockLayer) = findDockWindow() else {
    print("❌ 找不到 Dock 窗口——尝试列全部窗口")
    let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in list.prefix(20) {
        let name = info[kCGWindowOwnerName as String] as? String ?? "?"
        let wid = info[kCGWindowNumber as String] as? Int32 ?? -1
        let layer = info[kCGWindowLayer as String] as? Int ?? -1
        print("  \(name) wid=\(wid) layer=\(layer)")
    }
    exit(1)
}
print("Dock 窗口：wid=\(dockWID) layer=\(dockLayer)")

// Step 2: 读 Dock 的 tags
print("\n=== 读 Dock tags ===")
let dockTags = readTags(dockWID)
print("Dock tags: [0x\(String(dockTags[0], radix: 16)), 0x\(String(dockTags[1], radix: 16))]")
print("  tag[0] 二进制: \(String(dockTags[0], radix: 2))")
print("  tag[1] 二进制: \(String(dockTags[1], radix: 2))")

// Step 3: 建测试窗
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func makeWindow(_ label: String, _ color: NSColor, _ y: CGFloat, _ tags: [Int32]?) -> NSWindow {
    let frame = NSRect(x: 200, y: y, width: 260, height: 50)
    let w = NSWindow(
        contentRect: frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    w.isOpaque = false
    w.backgroundColor = .clear
    w.level = NSWindow.Level(rawValue: 19)
    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    w.isReleasedWhenClosed = false
    w.isMovable = false
    w.animationBehavior = .none
    w.ignoresMouseEvents = true

    let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
    v.wantsLayer = true
    v.layer?.backgroundColor = color.cgColor
    let tf = NSTextField(labelWithString: label)
    tf.alignment = .center
    tf.textColor = .white
    tf.font = .systemFont(ofSize: 11, weight: .medium)
    tf.frame = NSRect(origin: .zero, size: frame.size)
    v.addSubview(tf)
    w.contentView = v

    w.orderFrontRegardless()
    let wid = CGWindowID(w.windowNumber)

    print("\n--- \(label) ---")
    let defaultTags = readTags(wid)
    if let tags {
        writeTags(wid, tags)
        let readback = readTags(wid)
        print("  设后 tags=[0x\(String(readback[0], radix: 16)), 0x\(String(readback[1], radix: 16))]")
    }
    return w
}

print("\n=== 建测试窗 ===")

// A: 对照组
_ = makeWindow("A: 对照", .systemRed, 500, nil)

// B: 复制 Dock 的 tags
_ = makeWindow("B: Dock tags", .systemBlue, 430, dockTags)

// C: 只设 NeverFlatten 位
_ = makeWindow("C: NeverFlatten", .systemGreen, 360, [0x0, (1 << 16)])

// D: Dock tags | NeverFlatten
_ = makeWindow("D: Dock+NeverFlatten", .systemOrange, 290, [dockTags[0], dockTags[1] | (1 << 16)])

print("\n=== 等待用户测试 ===")
print("请用触控板滑动切桌面，观察哪个色块钉住不动：")
print("  红 = 对照（预计会滑）")
print("  蓝 = Dock tags 复制")
print("  绿 = NeverFlatten 位")
print("  橙 = Dock tags | NeverFlatten")
print("测试完按 Ctrl+C 退出。")

RunLoop.main.run()

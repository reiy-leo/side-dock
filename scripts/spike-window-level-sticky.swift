// Spike：试 CGSSetWindowLevel 把窗口设到 Dock 级别（或更高）看能否防滑动
//
// 思路：WindowServer 可能不动画 Dock 级别（kCGDockWindowLevelKey=20）及以上的窗口。
// 设 4 个不同 level 的测试窗，用户滑动切桌面看哪个钉住。
// 零权限、不改系统。

import AppKit
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
guard let handle = dlopen(frameworkPath, RTLD_NOW) else { exit(1) }

typealias MainConnFn = @convention(c) () -> UInt32
typealias SetLevelFn = @convention(c) (UInt32, CGWindowID, Int) -> Int32

let cid = unsafeBitCast(dlsym(handle, "CGSMainConnectionID")!, to: MainConnFn.self)()
let setLevel = unsafeBitCast(dlsym(handle, "CGSSetWindowLevel")!, to: SetLevelFn.self)

print("CID = \(cid)")

// CGWindowLevelKey 的原始值
//  kCGDesktopWindowLevelKey = -2147483623
//  kCGNormalWindowLevelKey  = 0
//  kCGDockWindowLevelKey     = 20
//  kCGMainMenuWindowLevelKey = 24
//  kCGStatusWindowLevelKey   = 25
//  kCGPopUpMenuWindowLevelKey = 101
//  kCGFloatingWindowLevelKey = 3
//  但这些是 CGWindowLevelKey enum 的值，实际 CGSSetWindowLevel 用的可能是 NSWindow.Level 的 rawValue

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func makeWindow(_ label: String, _ color: NSColor, _ y: CGFloat, nsLevel: Int, cgsLevel: Int?) -> NSWindow {
    let frame = NSRect(x: 200, y: y, width: 280, height: 50)
    let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.level = NSWindow.Level(rawValue: nsLevel)
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

    if let cgsLevel {
        let ret = setLevel(cid, wid, cgsLevel)
        print("\(label): NSLevel=\(nsLevel) CGSSetWindowLevel(\(cgsLevel)) ret=\(ret) wid=\(wid)")
    } else {
        print("\(label): NSLevel=\(nsLevel) (无 CGSSetWindowLevel) wid=\(wid)")
    }
    return w
}

print("\n=== 建测试窗 ===")

// A: 对照（NSWindow.level = 19，不调 CGSSetWindowLevel）
_ = makeWindow("A: 对照 level=19", .systemRed, 600, nsLevel: 19, cgsLevel: nil)

// B: CGSSetWindowLevel = 20（Dock 级别）
_ = makeWindow("B: CGS level=20", .systemBlue, 530, nsLevel: 19, cgsLevel: 20)

// C: CGSSetWindowLevel = 24（菜单栏级别）
_ = makeWindow("C: CGS level=24", .systemGreen, 460, nsLevel: 19, cgsLevel: 24)

// D: CGSSetWindowLevel = 25（状态栏级别）
_ = makeWindow("D: CGS level=25", .systemOrange, 390, nsLevel: 19, cgsLevel: 25)

// E: 不用 canJoinAllSpaces，只用 stationary + CGS level=20
let frame = NSRect(x: 200, y: 320, width: 280, height: 50)
let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
w.isOpaque = false; w.backgroundColor = .clear; w.level = NSWindow.Level(rawValue: 19)
w.collectionBehavior = [.stationary, .fullScreenAuxiliary, .ignoresCycle]
w.isReleasedWhenClosed = false; w.isMovable = false; w.animationBehavior = .none; w.ignoresMouseEvents = true
let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
v.wantsLayer = true; v.layer?.backgroundColor = NSColor.systemPurple.cgColor
let tf = NSTextField(labelWithString: "E: stationary only + CGS=20"); tf.alignment = .center; tf.textColor = .white; tf.font = .systemFont(ofSize: 11, weight: .medium); tf.frame = NSRect(origin: .zero, size: frame.size); v.addSubview(tf); w.contentView = v
w.orderFrontRegardless()
let wid = CGWindowID(w.windowNumber)
_ = setLevel(cid, wid, 20)
print("E: stationary only + CGS=20 wid=\(wid)")

print("\n=== 等待用户测试 ===")
print("触控板滑动切桌面，观察哪个钉住：")
print("  红 = 对照 NS level=19")
print("  蓝 = CGS level=20（Dock级）")
print("  绿 = CGS level=24（菜单栏级）")
print("  橙 = CGS level=25（状态栏级）")
print("  紫 = stationary only + CGS=20")
print("Ctrl+C 退出。")

RunLoop.main.run()

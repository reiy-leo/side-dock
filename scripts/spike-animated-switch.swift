// 实验 28 探针：合成键盘事件能不能借到系统「切桌面」的过渡动画？
//
// 结论（2026-10-06，macOS 15.8.1）：**不能**。事件在投递层被系统拦下 ——
//   AXIsProcessTrusted = true、CGPreflightPostEventAccess = true、CGEventSource 创建成功，
//   但合成 ⌃→ 空间不切；**阳性对照 Cmd+Tab 同样不生效**（决定性判据）。
//   编译成独立二进制（非 swift 脚本）复测结论相同 → 与进程身份/权限无关。
//   替代路 AppleScript（System Events）返回 -1743（未授权 Apple Events）。
// 用法：swift scripts/spike-animated-switch.swift   （会真的尝试切空间，注意当前桌面）
import ApplicationServices
import CoreGraphics
import Foundation

let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)!
typealias ConnFn = @convention(c) () -> UInt32
typealias GetSpaceFn = @convention(c) (UInt32) -> UInt64
typealias CopySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?
let cid = unsafeBitCast(dlsym(handle, "CGSMainConnectionID")!, to: ConnFn.self)()
let getSpace = unsafeBitCast(dlsym(handle, "CGSGetActiveSpace")!, to: GetSpaceFn.self)
let copySpaces = unsafeBitCast(dlsym(handle, "CGSCopyManagedDisplaySpaces")!, to: CopySpacesFn.self)
func active() -> UInt64 { getSpace(cid) }
func uuid() -> String {
    let arr = copySpaces(cid)!.takeRetainedValue() as! [[String: Any]]
    return arr.first!["Display Identifier"] as! String
}

print("AXIsProcessTrusted:", AXIsProcessTrusted())
guard AXIsProcessTrusted() else {
    print("❌ 未授权 —— 请先在「系统设置 → 隐私与安全性 → 辅助功能」里勾选本终端 App，然后重跑")
    exit(0)
}

let before = active()
print("起点 space =", before)
// 合成 ⌃→（与产品同一套：keycode 124 + control）
let src = CGEventSource(stateID: .hidSystemState)!
let down = CGEvent(keyboardEventSource: src, virtualKey: 124, keyDown: true)!
down.flags = .maskControl
let up = CGEvent(keyboardEventSource: src, virtualKey: 124, keyDown: false)!
up.flags = .maskControl
let t0 = Date()
down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)

var flip: Double? = nil
while Date().timeIntervalSince(t0) < 1.5 {
    if active() != before { flip = Date().timeIntervalSince(t0); break }
    usleep(2_000)
}
if let flip {
    let ms = flip * 1000
    print(String(format: "✅ 合成生效：空间翻转于 +%.0f ms", ms))
    print(ms > 150 ? "→ 这个延迟说明**有过渡动画**（硬切是 0–6ms）" : "→ 太快，疑似仍是硬切")
} else {
    print("❌ 1.5s 内未翻转")
}
// 收尾：切回去
if active() != before {
    usleep(400_000)
    let arr = copySpaces(cid)!.takeRetainedValue() as! [[String: Any]]
    _ = arr
    let src2 = CGEventSource(stateID: .hidSystemState)!
    let d2 = CGEvent(keyboardEventSource: src2, virtualKey: 123, keyDown: true)!
    d2.flags = .maskControl
    let u2 = CGEvent(keyboardEventSource: src2, virtualKey: 123, keyDown: false)!
    u2.flags = .maskControl
    d2.post(tap: .cghidEventTap); u2.post(tap: .cghidEventTap)
    usleep(600_000)
    print("已切回，active =", active(), "(期望", before, ")")
}

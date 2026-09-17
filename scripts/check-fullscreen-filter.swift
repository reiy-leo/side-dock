// P5 回归：全屏 App 空间必须被过滤掉（type != 0），否则每次进全屏都会被当成"切了桌面"。
//
// 之前只有合成数据的单测（`SpaceParsingTests`），没有真机回归 —— 因为本机平时没有全屏空间。
// 这个脚本**自己造一个**：把本进程的一个窗口切成全屏，SkyLight 就会多出一个 type=4 的空间。
// 零权限（这是本进程自己的窗口，不需要辅助功能），结束后自动退出全屏。
//
// 用法：swiftc -O -o /tmp/md-fullscreen scripts/check-fullscreen-filter.swift && /tmp/md-fullscreen
//
// ⚠️ 会短暂占满屏幕（约 5 秒），期间别操作。

import AppKit
import CoreGraphics
import Foundation

private typealias CGSConnectionID = UInt32
private let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

private typealias MainConnectionFn = @convention(c) () -> CGSConnectionID
private typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
private typealias GetActiveSpaceFn = @convention(c) (CGSConnectionID) -> UInt64

guard let handle = dlopen(skyLightPath, RTLD_NOW) else {
    print("错误：dlopen SkyLight 失败")
    exit(1)
}
func sym<T>(_ name: String, as type: T.Type) -> T? {
    guard let p = dlsym(handle, name) else { return nil }
    return unsafeBitCast(p, to: type)
}
guard
    let mainConn = sym("CGSMainConnectionID", as: MainConnectionFn.self),
    let copySpaces = sym("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self),
    let getActive = sym("CGSGetActiveSpace", as: GetActiveSpaceFn.self)
else {
    print("错误：SkyLight 符号缺失")
    exit(2)
}

struct Space {
    let displayUUID: String
    let spaceUUID: String
    let id64: UInt64
    let type: Int
}

/// 原始快照：包含所有 type 的空间。
func allSpaces() -> (spaces: [Space], active: UInt64) {
    let cid = mainConn()
    let active = getActive(cid)
    var list: [Space] = []
    if let cf = copySpaces(cid) {
        let displays = cf.takeRetainedValue() as? [[AnyHashable: Any]] ?? []
        for d in displays {
            let displayUUID = d["Display Identifier"] as? String ?? "?"
            for s in (d["Spaces"] as? [[AnyHashable: Any]] ?? []) {
                list.append(
                    Space(
                        displayUUID: displayUUID,
                        spaceUUID: s["uuid"] as? String ?? "?",
                        id64: (s["id64"] as? NSNumber)?.uint64Value ?? 0,
                        type: (s["type"] as? NSNumber)?.intValue ?? -1
                    )
                )
            }
        }
    }
    return (list, active)
}

/// App 的口径：只留 type == 0，并按显示器各自从 1 开始编号。
func userDesktops() -> [Space] {
    let all = allSpaces().spaces
    var result: [Space] = []
    var seen = Set<String>()
    for s in all {
        // 与 `SkyLightSpaceProvider.userDesktops` 同一口径：只留 type == 0。
        guard s.type == 0 else { continue }
        let key = "\(s.displayUUID)#\(s.spaceUUID)"
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        result.append(s)
    }
    return result
}

func spin(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

// MARK: - 主流程

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

print("=== P5 全屏过滤回归 ===")
let before = allSpaces()
let userBefore = before.spaces.filter { $0.type == 0 }
print("进入全屏前：空间总数 \(before.spaces.count)，其中 type=0 的 \(userBefore.count) 个")
print("  活动 id64 = \(before.active)（属于用户桌面：\(userBefore.contains { $0.id64 == before.active })）")
print("")

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled, .closable, .resizable],
    backing: .buffered,
    defer: false
)
window.collectionBehavior = [.fullScreenPrimary]
window.title = "MultiDock 全屏过滤回归（约 5 秒后自动关闭）"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
spin(0.4)

print("→ 进入全屏 …")
window.toggleFullScreen(nil)
spin(2.5)

let during = allSpaces()
let userDuring = during.spaces.filter { $0.type == 0 }
let nonUser = during.spaces.filter { $0.type != 0 }
print("全屏中：空间总数 \(during.spaces.count)，type=0 的 \(userDuring.count) 个，非 0 的 \(nonUser.count) 个")
for s in nonUser {
    print("  非用户空间：uuid=\(s.spaceUUID) id64=\(s.id64) type=\(s.type)")
}
print("  活动 id64 = \(during.active)")
print("  活动空间属于用户桌面：\(userDuring.contains { $0.id64 == during.active })（期望 false）")
print("")

// —— 核心判据 ——
var failures: [String] = []

if nonUser.isEmpty {
    failures.append("没有造出非 0 类型的空间 → 这次回归无效（窗口没真正进入独立全屏空间）")
}
if userDuring.count != userBefore.count {
    failures.append("全屏期间 type=0 的用户桌面数变了（\(userBefore.count) → \(userDuring.count)）")
}
// App 的口径里不该出现任何非 0 空间
if userDesktops().contains(where: { $0.type != 0 }) {
    failures.append("过滤后仍混入非 0 空间")
}
// 活动空间命中非用户空间 → observer 应该返回 nil，不触发任何切换/应用
if userDuring.contains(where: { $0.id64 == during.active }) {
    failures.append("全屏期间活动空间仍被认成用户桌面 → 会被误判成切桌面")
}

print("→ 退出全屏 …")
window.toggleFullScreen(nil)
spin(2.5)
window.orderOut(nil)

let after = allSpaces()
let userAfter = after.spaces.filter { $0.type == 0 }
print("")
print("退出全屏后：空间总数 \(after.spaces.count)，type=0 的 \(userAfter.count) 个")
print("  活动 id64 = \(after.active)（属于用户桌面：\(userAfter.contains { $0.id64 == after.active })）")

if userAfter.count != userBefore.count {
    failures.append("退出全屏后用户桌面数没回到 \(userBefore.count)")
}
if after.active != before.active {
    failures.append("退出全屏后没有回到原来的桌面（\(before.active) → \(after.active)）")
}

print("")
print("=== 结论 ===")
if failures.isEmpty {
    print("✅ 全屏过滤真实回归通过：")
    print("   · 全屏期间确实出现了非 0 空间（type=\(nonUser.first?.type ?? -1)，id64=\(nonUser.first?.id64 ?? 0)）")
    print("   · 它没有被算进用户桌面，活动空间也不再命中任何用户桌面 → observer 返回 nil，不会切 Dock")
    print("   · 退出全屏后桌面数与活动桌面都回到原样")
} else {
    print("❌ 回归失败：")
    for f in failures { print("   · \(f)") }
    exit(3)
}

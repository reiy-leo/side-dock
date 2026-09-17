// P0 实验：CGSManagedDisplaySetCurrentSpace 能否真的主动切换桌面？
// 用法：swift scripts/spike-switch.swift [目标序号，默认 1]
//
// 验证四件事：
//   1. 调用前后 CGSGetActiveSpace 是否真的变了
//   2. NSWorkspaceActiveSpaceDidChangeNotification 是否照常触发
//   3. 切换耗时（是否等动画）
//   4. 结束后自动切回原桌面
//
// 注意：这个实验会真的切换你的桌面，属 P0 预期内行为。

import AppKit
import CoreGraphics
import Foundation

private typealias CGSConnectionID = UInt32
private let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

private typealias MainConnectionFn = @convention(c) () -> CGSConnectionID
private typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
private typealias GetActiveSpaceFn = @convention(c) (CGSConnectionID) -> UInt64
private typealias ManagedDisplaySetCurrentSpaceFn = @convention(c) (CGSConnectionID, CFString, UInt64) -> Void

guard let handle = dlopen(skyLightPath, RTLD_NOW) else {
    print("错误：dlopen SkyLight 失败")
    exit(1)
}
func sym<T>(_ name: String, as: T.Type) -> T? {
    guard let p = dlsym(handle, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}
guard
    let mainConn = sym("CGSMainConnectionID", as: MainConnectionFn.self),
    let copySpaces = sym("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self),
    let getActive = sym("CGSGetActiveSpace", as: GetActiveSpaceFn.self),
    let setCurrent = sym("CGSManagedDisplaySetCurrentSpace", as: ManagedDisplaySetCurrentSpaceFn.self)
else {
    print("错误：SkyLight 符号缺失（CGSManagedDisplaySetCurrentSpace 不可用）→ 主动切桌面需降级")
    exit(2)
}

struct Space {
    let displayUUID: String
    let spaceUUID: String
    let id64: UInt64
    let type: Int
}

func snapshot() -> (spaces: [Space], active: UInt64) {
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

// 通知计数
final class NotifyCounter: @unchecked Sendable {
    var count = 0
    var lastTimestamp: Date?
}
let counter = NotifyCounter()
let observer = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil,
    queue: .main
) { _ in
    counter.count += 1
    counter.lastTimestamp = Date()
    print("   [通知] NSWorkspaceActiveSpaceDidChangeNotification 第 \(counter.count) 次触发")
}

let targetIndex = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 1 : 1

print("=== P0-2 主动切桌面实验 ===")
let before = snapshot()
let userSpaces = before.spaces.filter { $0.type == 0 }
print("显示器上的用户桌面（type==0）共 \(userSpaces.count) 个：")
for (i, s) in userSpaces.enumerated() {
    print("  [\(i)] space=\(s.spaceUUID) id64=\(s.id64)")
}
let currentIndex = userSpaces.firstIndex { $0.id64 == before.active } ?? -1
print("当前活动桌面：索引 \(currentIndex)（id64=\(before.active)）")

guard userSpaces.count >= 2 else {
    print("只有 1 个用户桌面，无法测试切换")
    exit(0)
}
let target = userSpaces[targetIndex % userSpaces.count]
print("目标桌面：索引 \(targetIndex % userSpaces.count)（id64=\(target.id64)）")
print("")

// 让主线程 runloop 转起来，才能收到通知
private let cid = mainConn()

// 先空转 1.5s 建立通知基线，确认"没有空间变化时不会有通知"
print("空转 1.5s 建立通知基线 …")
let baseDeadline = Date().addingTimeInterval(1.5)
while Date() < baseDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
print("基线通知次数    : \(counter.count)")
print("")

print("调用 CGSManagedDisplaySetCurrentSpace(cid=\(cid), display=\(target.displayUUID), space=\(target.id64)) …")
let t0 = Date()
setCurrent(cid, target.displayUUID as CFString, target.id64)

// 观察窗口：固定 2.5s，期间持续转 runloop 收通知
var switched = false
var elapsed: TimeInterval = 0
let observeDeadline = Date().addingTimeInterval(2.5)
while Date() < observeDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    elapsed = Date().timeIntervalSince(t0)
    if !switched, snapshot().active == target.id64 { switched = true }
}

print("")
print("切换生效        : \(switched ? "是" : "否")")
print("生效耗时        : \(String(format: "%.0f", elapsed * 1000)) ms（含 2.5s 观察窗口）")
print("通知触发次数    : \(counter.count)")
let after = snapshot()
print("切换后活动 id64 : \(after.active)（期望 \(target.id64)）")

// 切回原桌面，同样观察 2.5s
if switched, currentIndex >= 0 {
    let original = userSpaces[currentIndex]
    print("")
    print("切回原桌面 id64=\(original.id64) …")
    let countBeforeBack = counter.count
    setCurrent(cid, original.displayUUID as CFString, original.id64)
    let backDeadline = Date().addingTimeInterval(2.5)
    while Date() < backDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        if snapshot().active == original.id64 && Date().timeIntervalSince(backDeadline) > -1.5 { break }
    }
    print("已切回，当前活动 id64=\(snapshot().active)（期望 \(original.id64)）")
    print("切回过程通知次数: \(counter.count - countBeforeBack)")
}

NSWorkspace.shared.notificationCenter.removeObserver(observer)
print("")
print("结论：")
print("  主动切桌面：\(switched ? "可用（CGSManagedDisplaySetCurrentSpace 生效）" : "不可用或未生效 → 菜单栏切换需降级")")
print("  切换通知  ：\(counter.count > 0 ? "会触发（\(counter.count) 次）" : "未触发 → SpaceObserver 不能只依赖该通知，必须有轮询兜底")")

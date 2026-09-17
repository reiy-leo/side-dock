// P0 实验用的探测工具：一次性打印"当前桌面 + Dock 进程 + Dock 窗口几何"。
// 用法：swift scripts/spike-probe.swift [--json]
// 目的：给 spike-reload.sh 提供客观的前后对比信号，避免只靠肉眼判断。

import AppKit
import CoreGraphics
import Foundation

// MARK: - SkyLight 私有 API（dlopen 运行时加载，不链接私有框架）

private typealias CGSConnectionID = UInt32
private typealias MainConnectionFn = @convention(c) () -> CGSConnectionID
private typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
private typealias GetActiveSpaceFn = @convention(c) (CGSConnectionID) -> UInt64

private let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

private func loadSkyLight() -> (mainConnection: MainConnectionFn, copySpaces: CopyManagedDisplaySpacesFn, getActiveSpace: GetActiveSpaceFn)? {
    guard let handle = dlopen(skyLightPath, RTLD_NOW) else { return nil }
    func sym<T>(_ name: String, as: T.Type) -> T? {
        guard let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    guard
        let main = sym("CGSMainConnectionID", as: MainConnectionFn.self),
        let copy = sym("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self),
        let active = sym("CGSGetActiveSpace", as: GetActiveSpaceFn.self)
    else { return nil }
    return (main, copy, active)
}

// MARK: - 数据结构

struct SpaceInfo {
    var displayUUID: String
    var spaceUUID: String
    var id64: UInt64
    var type: Int
}

struct DockWindowInfo {
    var layer: Int
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

// MARK: - 采集

func collectDockWindows(dockPID: Int32) -> [DockWindowInfo] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [DockWindowInfo] = []
    for w in raw {
        // 用 PID 匹配而不是 ownerName：ownerName 会被系统语言本地化（中文下是「程序坞」）。
        guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == dockPID else { continue }
        guard let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
        let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        out.append(
            DockWindowInfo(
                layer: layer,
                x: (b["X"] as? NSNumber)?.doubleValue ?? 0,
                y: (b["Y"] as? NSNumber)?.doubleValue ?? 0,
                width: (b["Width"] as? NSNumber)?.doubleValue ?? 0,
                height: (b["Height"] as? NSNumber)?.doubleValue ?? 0
            )
        )
    }
    return out.sorted { $0.layer < $1.layer }
}

func collectSpaces() -> (active: String?, list: [SpaceInfo]) {
    guard let api = loadSkyLight() else { return (nil, []) }
    let cid = api.mainConnection()
    var activeUUID: String?
    let activeID = api.getActiveSpace(cid)
    var list: [SpaceInfo] = []
    if let cf = api.copySpaces(cid) {
        let displays = cf.takeRetainedValue() as? [[AnyHashable: Any]] ?? []
        for display in displays {
            let displayUUID = display["Display Identifier"] as? String ?? "?"
            // 活动桌面也可以从 display["Current Space"] 直接读，这里用 id64 与 CGSGetActiveSpace 对齐。
            let spaces = display["Spaces"] as? [[AnyHashable: Any]] ?? []
            for s in spaces {
                // 实测键名是 "uuid"（不是 ManagedSpaceUUID），另有 ManagedSpaceID / id64 / type。
                let uuid = s["uuid"] as? String ?? "?"
                let id64 = (s["id64"] as? NSNumber)?.uint64Value ?? 0
                let type = (s["type"] as? NSNumber)?.intValue ?? -1
                if id64 == activeID { activeUUID = uuid }
                list.append(SpaceInfo(displayUUID: displayUUID, spaceUUID: uuid, id64: id64, type: type))
            }
        }
    }
    return (activeUUID, list)
}

// MARK: - 主流程

let wantJSON = CommandLine.arguments.contains("--json")
let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? -1
let spaceSnapshot = collectSpaces()
let dockWindows = collectDockWindows(dockPID: dockPID)
let timestamp = ISO8601DateFormatter().string(from: Date())

if wantJSON {
    var spaceDicts: [[String: Any]] = []
    for s in spaceSnapshot.list {
        spaceDicts.append(["displayUUID": s.displayUUID, "spaceUUID": s.spaceUUID, "id64": s.id64, "type": s.type])
    }
    var windowDicts: [[String: Any]] = []
    for w in dockWindows {
        windowDicts.append(["layer": w.layer, "x": w.x, "y": w.y, "width": w.width, "height": w.height])
    }
    var dict: [String: Any] = [:]
    dict["timestamp"] = timestamp
    dict["dockPID"] = Int(dockPID)
    dict["activeSpaceUUID"] = spaceSnapshot.active ?? "nil"
    dict["spaces"] = spaceDicts
    dict["dockWindows"] = windowDicts
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else {
    print("timestamp        : \(timestamp)")
    print("dockPID          : \(dockPID)")
    print("activeSpaceUUID  : \(spaceSnapshot.active ?? "nil")")
    print("spaces (\(spaceSnapshot.list.count)):")
    for s in spaceSnapshot.list {
        print("  - display=\(s.displayUUID) space=\(s.spaceUUID) id64=\(s.id64) type=\(s.type)")
    }
    print("dockWindows (\(dockWindows.count)):")
    for w in dockWindows {
        print(String(format: "  - layer=%d x=%.1f y=%.1f w=%.1f h=%.1f", w.layer, w.x, w.y, w.width, w.height))
    }
}

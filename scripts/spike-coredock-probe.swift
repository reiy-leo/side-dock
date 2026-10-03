// 实验 17 探针：CoreDock 私有 API 通道（HIServices → MIG com.apple.dock.server）。
// 签名全部来自 lldb 反汇编 HIServices 桩函数（见 docs/spikes.md 实验 17.2），不是猜的。
//
// 模式与风险等级：
//   read / notify / state / domain   —— 只读或无副作用探测（notify 曾实测无效果）
//   settilesize <int32>              —— ⚠️ 会真的改 Dock 图标大小（参数按 float 位型解释，越界被钳制）
//   setprefs <binary-plist>          —— 推整份偏好字典（实测 Dock 对整域字典无响应，保留待复测）
//   addfile <path> [flags]           —— ⚠️ 会真的往 Dock 加图标（实测 CFURL 载荷无响应，保留待复测）
//
// ⚠️ 写模式必须先 defaults export com.apple.dock 备份，并在结束时 defaults import + SIGHUP 还原。
// ⚠️ 沙箱里 CFPreferencesCopyMultiple(nil,…) 只回 1 个键 —— 读域一律逐键 CFPreferencesCopyAppValue。

import CoreFoundation
import Darwin
import AppKit

@_silgen_name("CoreDockSendNotification")
func CoreDockSendNotification(_ name: CFString, _ flags: Int32) -> OSStatus

@_silgen_name("CoreDockGetTileSize")
func CoreDockGetTileSize() -> Float

@_silgen_name("CoreDockGetOrientationAndPinning")
func CoreDockGetOrientationAndPinning(_ o: UnsafeMutablePointer<Int32>, _ p: UnsafeMutablePointer<Int32>) -> OSStatus

@_silgen_name("CoreDockCopyPreferences")
func CoreDockCopyPreferences(_ request: CFTypeRef?, _ out: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus

@_silgen_name("CoreDockSetPreferences")
func CoreDockSetPreferences(_ prefs: CFDictionary) -> OSStatus

@_silgen_name("CoreDockSetTileSize")
func CoreDockSetTileSize(_ size: Int32) -> OSStatus

@_silgen_name("CoreDockAddFileToDock")
func CoreDockAddFileToDock(_ file: CFTypeRef, _ flags: Int32) -> OSStatus

func dockPID() -> Int {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
       app.processIdentifier > 0 { return Int(app.processIdentifier) }
    return -1
}

func tileState(label: String) -> String {
    guard let apps = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? Array<Any> else { return "persistent-apps缺失" }
    for tile in apps {
        guard let td = (tile as? [String: Any])?["tile-data"] as? [String: Any] else { continue }
        if (td["file-label"] as? String) == label {
            return "在场 guid=\(td["GUID"] != nil ? "yes" : "no")"
        }
    }
    return "不在场 apps=\(apps.count)"
}

setvbuf(stdout, nil, _IONBF, 0)

let args = CommandLine.arguments
guard args.count >= 2 else { print("用法: read | notify | state | domain | settilesize <n> | setprefs <plist> | addfile <path> [flags]"); exit(2) }

switch args[1] {
case "read":
    print("dockPID=\(dockPID())")
    print("GetTileSize=\(CoreDockGetTileSize())")
    var orient: Int32 = -1, pin: Int32 = -1
    print("GetOrientationAndPinning status=\(CoreDockGetOrientationAndPinning(&orient, &pin)) orientation=\(orient) pinning=\(pin)")
    // CopyPreferences 的 request 参数不能为 nil（SerializeCFType 不判空），签名未定，跳过
case "notify":
    let st = CoreDockSendNotification("com.apple.dock.prefchanged" as CFString, 0)
    print("SendNotification status=\(st) dockPID=\(dockPID())")
case "domain":
    let multi = CFPreferencesCopyMultiple(nil, "com.apple.dock" as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    print("CopyMultiple 键数=\(CFDictionaryGetCount(multi))")
    let apps = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString)
    if CFGetTypeID(apps) == CFArrayGetTypeID() { print("CopyAppValue persistent-apps 条数=\(CFArrayGetCount(apps as! CFArray))") } else { print("CopyAppValue persistent-apps 非数组 (type=\(CFGetTypeID(apps)))") }
    let size = CFPreferencesCopyAppValue("tilesize" as CFString, "com.apple.dock" as CFString)
    print("CopyAppValue tilesize=\(size as? Float ?? -1)")
case "setprefs":
    guard args.count >= 3 else { print("需要 plist 路径"); exit(2) }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[2])) else { print("读不了 \(args[2])"); exit(1) }
    var err: Unmanaged<CFError>?
    guard let plU = CFPropertyListCreateWithData(nil, data as CFData, CFOptionFlags(0), nil, &err) else {
        print("plist 解析失败: \(err.map { $0.takeRetainedValue().localizedDescription } ?? "?")"); exit(1)
    }
    let pl = plU.takeRetainedValue()
    guard CFGetTypeID(pl) == CFDictionaryGetTypeID() else { print("顶层不是字典"); exit(1) }
    let st = CoreDockSetPreferences(pl as! CFDictionary)
    print("SetPreferences status=\(st) dockPID=\(dockPID())")
case "settilesize":
    guard args.count >= 3, let v = Int32(args[2]) else { print("需要整数"); exit(2) }
    let st = CoreDockSetTileSize(v)
    print("SetTileSize(\(v)) status=\(st) dockPID=\(dockPID())")
case "addfile":
    guard args.count >= 3 else { print("需要路径"); exit(2) }
    let url = URL(fileURLWithPath: args[2]) as CFURL
    let flags: Int32 = args.count >= 4 ? Int32(args[3]) ?? 0 : 0
    let st = CoreDockAddFileToDock(url, flags)
    print("AddFileToDock status=\(st) dockPID=\(dockPID())")
case "state":
    print("dockPID=\(dockPID()) \(tileState(label: "MultiDockLiveTest"))")
default:
    print("未知模式")
    exit(2)
}

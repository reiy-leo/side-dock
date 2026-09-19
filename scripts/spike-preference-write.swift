// 实验 14：把「写偏好 + SIGHUP」这个组合单独拎出来测。
//
// 前两个实验都是**否定结论**，把嫌疑范围收窄到只剩这一个变量：
//   · 实验 12（`spike-restart-spacing.swift`）：uptime 6/12/20/60 s 全是 37–68 ms → "uptime 门槛"假说**推翻**。
//   · 实验 13（`spike-pid-detection.swift`）：两条 PID 探测路径同量级（41–116 ms），
//     6 次连发（间隔 2 s）也全部正常 → "探测路径分叉"假说**推翻**。
//   · 两者都**只发信号、不写偏好**；而 App 的 `DockController.apply` 是
//     「读全量域 → 覆盖白名单键 → 原子写 → SIGHUP」。差别只剩这一步。
//
// 做法：**幂等写入** —— 把当前真实域里白名单键的值**原样写回**（语义不变，只触发一次写事务），
// 紧接着 SIGHUP，测归位时长。重复 N 轮，轮间隔默认 2 s（贴近用户快速连切）。
//
// 用法：swift scripts/spike-preference-write.swift [轮数] [轮间隔秒]
//   默认：5 轮，间隔 2 秒
//
// ⚠️ 会真的写 `com.apple.dock`（写的是它自己的当前值，幂等）并重启 Dock N 次。
//    跑前请先 `defaults export com.apple.dock <备份路径>`。

import Darwin
import Foundation

/// 与 `DockPreferences` 的白名单一致（本机真实存在的那些）。
let whitelist = [
    "persistent-apps", "persistent-others", "orientation", "tilesize",
    "magnification", "largesize", "autohide", "mineffect", "minimize-to-application",
]

let appID = "com.apple.dock" as CFString

func processName(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let name = buffer.prefix(Int(length)).prefix { $0 != 0 }
    guard !name.isEmpty else { return nil }
    return String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func dockPID() -> pid_t? {
    var capacity = 1024
    for _ in 0..<3 {
        var buffer = [pid_t](repeating: 0, count: capacity)
        let bytes = buffer.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
        }
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        if count >= capacity { capacity = count * 2; continue }
        for pid in buffer.prefix(count) where pid > 0 && processName(of: pid) == "Dock" { return pid }
        return nil
    }
    return nil
}

func readDomain() -> [String: Any] {
    (CFPreferencesCopyMultiple(nil, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]) ?? [:]
}

/// 幂等写：把当前域里白名单键的值原样写回。返回写进去的键名。
@discardableResult
func writeBackIdenticalWhitelist() -> [String] {
    let domain = readDomain()
    var toWrite: [CFString: Any] = [:]
    for key in whitelist where domain[key] != nil {
        toWrite[key as CFString] = domain[key]
    }
    guard !toWrite.isEmpty else { return [] }
    CFPreferencesSetMultiple(toWrite as CFDictionary, nil, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesAppSynchronize(appID)
    return toWrite.keys.map { $0 as String }.sorted()
}

func now() -> Double { Date().timeIntervalSince1970 }

let args = CommandLine.arguments
let rounds = args.count > 1 ? (Int(args[1]) ?? 5) : 5
let gap = args.count > 2 ? (Double(args[2]) ?? 2.0) : 2.0
let perRoundTimeout = 40.0

print("「写偏好 + SIGHUP」实验 — \(rounds) 轮，轮间隔 \(gap) s，单轮上限 \(Int(perRoundTimeout)) s\n")

guard let startPID = dockPID() else {
    print("错误：Dock 未运行")
    exit(1)
}
let before = readDomain()
print("起始 Dock PID \(startPID)；域里 \(before.count) 个键\n")

var rows: [(round: Int, wrote: Int, recovery: Double?, pid: pid_t?)] = []
var aborted = false

for round in 1...rounds {
    guard let oldPID = dockPID() else {
        print("⚠️ 第 \(round) 轮：Dock 不在，停手")
        aborted = true
        break
    }

    let keys = writeBackIdenticalWhitelist()
    let t0 = now()
    guard kill(oldPID, SIGHUP) == 0 else {
        print("⚠️ 第 \(round) 轮：信号发不出去")
        aborted = true
        break
    }

    var newPID: pid_t?
    while now() - t0 < perRoundTimeout {
        if let pid = dockPID(), pid != oldPID { newPID = pid; break }
        usleep(15_000)
    }

    let elapsed = newPID != nil ? now() - t0 : nil
    print("第 \(round) 轮  写 \(keys.count) 个键 → SIGHUP  " +
          (elapsed.map { String(format: "归位 %.0f ms", $0 * 1000) } ?? "⚠️ \(Int(perRoundTimeout)) s 内未归位"))
    rows.append((round, keys.count, elapsed, newPID))
    if newPID == nil { aborted = true; break }
    if round < rounds { Thread.sleep(forTimeInterval: gap) }
}

// 收尾：确认 Dock 活着；顺便确认域没被我们改坏（幂等写不该改值）。
if dockPID() == nil {
    print("\nDock 不在，用 launchctl kickstart 拉回…")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["kickstart", "gui/\(getuid())/com.apple.Dock.agent"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let deadline = now() + 90
    while now() < deadline, dockPID() == nil { usleep(200_000) }
}

let after = readDomain()
var changed: [String] = []
for key in Set(before.keys).union(after.keys) {
    let a = before[key].map { "\($0)" } ?? "<nil>"
    let b = after[key].map { "\($0)" } ?? "<nil>"
    if a != b { changed.append(key) }
}

var lines: [String] = []
lines.append("")
lines.append("轮次  写入键数  归位耗时")
lines.append("----  --------  --------")
for row in rows {
    let e = row.recovery.map { String(format: "%6.0f ms", $0 * 1000) } ?? "  超时"
    lines.append(String(format: "%4d  %8d  %@", row.round, row.wrote, e as NSString))
}
lines.append("")
if let worst = rows.compactMap({ $0.recovery }).max() {
    if worst > 5 {
        lines.append(String(format: "结论：**复现了**。最坏 %.0f ms，明显慢于纯信号路径的 37–116 ms。", worst * 1000))
        lines.append("→ 慢的是「写偏好 + 重启」这个组合，不是单纯的重启。")
    } else {
        lines.append(String(format: "结论：**没有复现**。最坏也只有 %.0f ms，与纯信号路径同量级。", worst * 1000))
        lines.append("→ 写偏好这一步不是原因，26 秒另有来源（可能需要真实 App 的完整上下文）。")
    }
}
lines.append("")
lines.append("幂等写之后域里发生变化的键：\(changed.isEmpty ? "无（符合预期）" : changed.joined(separator: ", "))")
if aborted { lines.append("⚠️ 本次被中断，结论不完整。") }
let text = lines.joined(separator: "\n")
print(text)
try? text.write(toFile: "/tmp/multidock-spike/preference-write.txt", atomically: true, encoding: .utf8)

// 决定性实验：Dock 重启窗口里，两条 PID 探测路径会不会分叉？
//
// 背景：`docs/spikes.md` 实验 11 里，用户真机日志显示两次重启"归位"花了 26 046 / 31 039 ms。
// 但实验 12（`spike-restart-spacing.swift`）用 **`proc_listpids` + `proc_name`** 测同样的场景，
// uptime 6 / 12 / 20 / 60 s 全是 37–68 ms —— 一次都没被罚。**"uptime 门槛"假说被推翻。**
//
// 两条路径的差别是唯一的嫌疑：
//   · `RealDockProcessControl.dockPID()` **优先** `NSRunningApplication.runningApplications(withBundleIdentifier:)`
//   · 实验 12 的脚本只用 `proc_listpids` + `proc_name`
// 如果 LaunchServices 在 Dock 重启窗口里返回一个**陈旧的、PID 还是旧值**的实例，
// App 就会一直以为"Dock 还没回来"，而 Dock 其实早就回来了。
//
// 做法：连续做 N 次重启（模仿用户快速连切桌面），每一轮**同时**记录两条路径各自看到新 PID 的时刻。
//
// 用法：swift scripts/spike-pid-detection.swift [轮数] [轮间隔秒]
//   默认：6 轮，轮间隔 2 秒（贴近"用户快速连切"）
//
// ⚠️ 会真的重启 Dock N 次，**只重启、不写偏好**。跑完确认 Dock 活着。

import AppKit
import Darwin
import Foundation

func processName(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let name = buffer.prefix(Int(length)).prefix { $0 != 0 }
    guard !name.isEmpty else { return nil }
    return String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// 路径 A：`proc_listpids` + `proc_name`（实验 12 用的那条，实测 0.02 ms）。
func procPathPID() -> pid_t? {
    var capacity = 1024
    for _ in 0..<3 {
        var buffer = [pid_t](repeating: 0, count: capacity)
        let bytes = buffer.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
        }
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        if count >= capacity {
            capacity = count * 2
            continue
        }
        for pid in buffer.prefix(count) where pid > 0 && processName(of: pid) == "Dock" {
            return pid
        }
        return nil
    }
    return nil
}

/// 路径 B：`NSRunningApplication`（`RealDockProcessControl.dockPID()` 的首选，实测 0.6–1.4 ms）。
/// 过滤条件与产品代码**逐字一致**，否则测的不是同一条路。
func launchServicesPathPID() -> pid_t? {
    NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.dock")
        .first(where: { !$0.isTerminated && $0.processIdentifier > 0 })?
        .processIdentifier
}

/// 诊断用：列出 LaunchServices 此刻报告的**全部** Dock 实例。
func allDockInstances() -> [(pid: pid_t, terminated: Bool)] {
    NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.dock")
        .map { ($0.processIdentifier, $0.isTerminated) }
}

func now() -> Double { Date().timeIntervalSince1970 }

let args = CommandLine.arguments
let rounds = args.count > 1 ? (Int(args[1]) ?? 6) : 6
let gap = args.count > 2 ? (Double(args[2]) ?? 2.0) : 2.0
let perRoundTimeout = 40.0

print("PID 探测路径分叉实验 — \(rounds) 轮，轮间隔 \(gap) s，单轮观测上限 \(Int(perRoundTimeout)) s")
print("路径 A = proc_listpids + proc_name ／ 路径 B = NSRunningApplication（产品代码的首选）\n")

guard let firstProc = procPathPID() else {
    print("错误：Dock 未运行")
    exit(1)
}
print("起始 Dock PID（A 路径）\(firstProc)；B 路径看到 \(allDockInstances())\n")

var rows: [(round: Int, a: Double?, b: Double?, aPID: pid_t?, bPID: pid_t?)] = []
var divergedAt: Int?

for round in 1...rounds {
    guard let oldPID = procPathPID() else {
        print("⚠️ 第 \(round) 轮：Dock 不在，停手")
        break
    }
    let t0 = now()
    guard kill(oldPID, SIGHUP) == 0 else {
        print("⚠️ 第 \(round) 轮：信号发不出去")
        break
    }

    var aElapsed: Double?
    var bElapsed: Double?
    var aPID: pid_t?
    var bPID: pid_t?

    while now() - t0 < perRoundTimeout {
        let elapsed = now() - t0
        if aElapsed == nil, let pid = procPathPID(), pid != oldPID {
            aElapsed = elapsed; aPID = pid
        }
        if bElapsed == nil, let pid = launchServicesPathPID(), pid != oldPID {
            bElapsed = elapsed; bPID = pid
        }
        if aElapsed != nil && bElapsed != nil { break }
        usleep(15_000)
    }

    func fmt(_ v: Double?) -> String {
        v.map { String(format: "%.0f ms", $0 * 1000) } ?? "未看到（\(Int(perRoundTimeout)) s 超时）"
    }
    print("第 \(round) 轮  旧 PID \(oldPID)   A 路径 \(fmt(aElapsed))    B 路径 \(fmt(bElapsed))")
    if bElapsed == nil {
        print("            B 路径此刻看到：\(allDockInstances())")
    }
    rows.append((round, aElapsed, bElapsed, aPID, bPID))

    // 判定分叉：A 已经看到新 Dock，B 却迟迟看不到。
    if let a = aElapsed, a < 1.0, (bElapsed == nil || (bElapsed ?? 0) > 5.0) {
        divergedAt = round
        print("\n⚠️ **确认分叉**：A 路径 \(fmt(a)) 就看到新 Dock，B 路径 \(fmt(bElapsed))。停手。")
        break
    }
    if round < rounds { Thread.sleep(forTimeInterval: gap) }
}

// 收尾：确保 Dock 活着
if procPathPID() == nil {
    print("\nDock 不在，用 launchctl kickstart 拉回…")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["kickstart", "gui/\(getuid())/com.apple.Dock.agent"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let deadline = now() + 90
    while now() < deadline, procPathPID() == nil { usleep(200_000) }
}

var lines: [String] = []
lines.append("")
lines.append("轮次  A 路径（proc_listpids）        B 路径（NSRunningApplication）")
lines.append("----  --------------------------  --------------------------------")
for row in rows {
    let a = row.a.map { String(format: "%8.0f ms", $0 * 1000) } ?? "  未看到"
    let b = row.b.map { String(format: "%8.0f ms", $0 * 1000) } ?? "  未看到"
    lines.append(String(format: "%4d  %@                  %@", row.round, a as NSString, b as NSString))
}
lines.append("")
if let round = divergedAt {
    lines.append("结论：**两条路径分叉**（第 \(round) 轮）。")
    lines.append("→ 说明 `dockPID()` 优先走 `NSRunningApplication` 会在 Dock 重启窗口里返回陈旧实例，")
    lines.append("  于是 `waitForRestart` 看不到新 PID，把几十毫秒误报成几十秒。")
    lines.append("→ 修法方向：把 `proc_listpids` + `proc_name` 提到首选，或两条路径取并集。")
} else {
    lines.append("结论：本轮没有观察到分叉（两条路径的归位时刻同量级）。")
}
let text = lines.joined(separator: "\n")
print(text)
try? text.write(toFile: "/tmp/multidock-spike/pid-detection.txt", atomically: true, encoding: .utf8)

// A8 定向测量：**launchd 的重启延迟会不会随"连续快速重启"累积**。
//
// 为什么要这个脚本（2026-09-20）：实验 12–14 把四个假说证伪了，其中"连续快速重启触发退避"
// 那一条是这么测的 —— **"6 次连发（间隔 2 s）全部正常"**。可是 `com.apple.Dock.plist` 里
// `ThrottleInterval` 本来就是 **1 s**：**间隔 2 s 的重启根本不构成节流违规**。
// 也就是说，这个假说**从来没有在真正的违规条件下被测过**。
//
// 真机那两次 26 / 31 秒的失败恰好落在这个没测过的形状上：故障前后的重启是**挤在一起**的
// （05:32:12 一次、05:32:18 又要在 6.5 s 内再来一次），而不是隔开 2 秒。
//
// 本脚本只回答一个问题：**把 Dock 的存活时间压到 1 秒以内、连续重启 N 次，
// launchd 的归位延迟会不会一路涨上去**（1 s → 2 s → 4 s … → 26 s）。
//
// 附加问题：**在延迟涨起来的时候踢一发 `launchctl kickstart`，能不能立刻救回来**。
// 这直接决定"等 500 ms 就催一发"这个修法（`DockReloader.nudgeAfter`）有没有效。
//
// 用法：swiftc -O -o /tmp/md-backoff scripts/measure-launchd-backoff.swift && /tmp/md-backoff [轮数]
//
// ⚠️ 每轮都会真的给 Dock 发 SIGHUP（= 重启 Dock），而且**轮与轮之间不等待** ——
// 这正是本实验的目的（把 Dock 存活时间压到 1 秒以内）。跑 10 轮约 20–40 秒，期间 Dock 会反复闪。
// ⚠️ **`kickstartAfter` 秒还没归位就自动催一发 `kickstart`**（不带 `-k`，无害），
// 免得把用户的 Dock 真的挂在那儿几十秒 —— 这同时也是在测修法本身。
// ⚠️ 不发 SIGKILL、**不写任何偏好域、不改 Dock 配置** —— 只读 + 发信号 + kickstart。
// ⚠️ 安全闸门与产品代码一致：只对确认进程名是 `Dock` 的**正数 PID** 发信号。

import Darwin
import Foundation

private let dockProcessName = "Dock"

private func processName(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let name = buffer.prefix(Int(length)).prefix { $0 != 0 }
    guard !name.isEmpty else { return nil }
    return String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// 直接扫内核进程表（`proc_listpids` + `proc_name`，约 0.02 ms）。
/// **刻意不用 `NSRunningApplication`**：它在重启窗口里会返回 -1 或陈旧实例（实验 13/15.3），
/// 本实验要测的是 launchd 什么时候把新 Dock 放出来，不能被探测侧的滞后污染。
private func scanForDockPID() -> pid_t? {
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
        for pid in buffer.prefix(count) where pid > 0 {
            if processName(of: pid) == dockProcessName { return pid }
        }
        return nil
    }
    return nil
}

/// Dock 进程的启动时刻（`proc_pidinfo(PROC_PIDTBSDINFO)`，与产品代码同构）。
private func startTime(of pid: pid_t) -> TimeInterval? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
    guard written == Int32(size) else { return nil }
    return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
}

private func signalDock(_ pid: pid_t, _ sig: Int32) -> Bool {
    guard pid > 0 else { return false }
    guard processName(of: pid) == dockProcessName else { return false }
    return Darwin.kill(pid, sig) == 0
}

/// 催一发 `launchctl kickstart`（**不带 `-k`**）。**不等待**：真机实测这条命令在 launchd
/// 处于退避时能阻塞几十秒，等它会把测量本身搞乱。
private func kickstartDock() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["kickstart", "gui/\(getuid())/com.apple.Dock.agent"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

private func now() -> Double { Date().timeIntervalSince1970 }

/// 自 `since` 起的毫秒数。
private func elapsedMs(_ since: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000
}

// MARK: - 主流程

let rounds = max(1, CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 10 : 10)
let pollInterval: useconds_t = 5_000   // 5 ms
let maxWait: Double = 30               // 每轮最多等 30 s
let kickstartAfter: Double = 3         // 3 s 还没归位就催一发

print("""
[A8 退避] 连续快速重启测量：\(rounds) 轮，轮间**不等待**（刻意把 Dock 存活时间压到 1 s 以内）
[A8 退避] 每轮最多等 \(Int(maxWait)) s；超过 \(kickstartAfter) s 未归位就催一发 kickstart
""")

struct Round {
    var index: Int
    var oldPID: pid_t
    var uptime: Double        // 旧 Dock 的存活时长（s）—— 判定有没有构成节流违规
    var latency: Double       // SIGHUP → 看到新 PID（ms）
    var kickedAt: Double?     // 催 kickstart 的时刻（ms，自 SIGHUP 起）
    var newPID: pid_t?
}

var results: [Round] = []

for index in 1...rounds {
    guard let oldPID = scanForDockPID(), oldPID > 0 else {
        print("[A8 退避] 第 \(index) 轮：拿不到 Dock PID，终止")
        break
    }
    let uptime = startTime(of: oldPID).map { now() - $0 } ?? -1

    let t0 = DispatchTime.now()
    guard signalDock(oldPID, SIGHUP) else {
        print("[A8 退避] 第 \(index) 轮：SIGHUP 没发出去（PID \(oldPID)），终止")
        break
    }

    var kickedAt: Double?
    var newPID: pid_t?
    while elapsedMs(t0) < maxWait * 1000 {
        if let pid = scanForDockPID(), pid != oldPID, pid > 0 {
            newPID = pid
            break
        }
        let e = elapsedMs(t0)
        if kickedAt == nil, e >= kickstartAfter * 1000 {
            kickedAt = e
            kickstartDock()
        }
        usleep(pollInterval)
    }

    let latency = elapsedMs(t0)
    let row = Round(index: index, oldPID: oldPID, uptime: uptime,
                    latency: latency, kickedAt: kickedAt, newPID: newPID)
    results.append(row)

    let uptimeText = uptime >= 0 ? String(format: "%.1fs", uptime) : "?"
    let kickText = kickedAt.map { String(format: "　⚠️ %.0f ms 处催了 kickstart", $0) } ?? ""
    let pidText = newPID.map { "→ \($0)" } ?? "→ **一直没回来**"
    print(String(format: "[A8 退避] 第 %2d 轮：旧 PID %d（存活 %@）%@　延迟 %.0f ms%@",
                 index, oldPID, uptimeText, pidText, latency, kickText))

    if newPID == nil { break }
}

// MARK: - 汇总

print("\n[A8 退避] === 汇总 ===")
let latencies = results.map(\.latency)
let series = latencies.map { String(format: "%.0f", $0) }.joined(separator: ", ")
print("[A8 退避] 延迟序列（ms）：[\(series)]")

if !latencies.isEmpty {
    let sorted = latencies.sorted()
    print(String(format: "[A8 退避] 最小 %.0f ms　中位 %.0f ms　最大 %.0f ms",
                 sorted.first!, sorted[sorted.count / 2], sorted.last!))
    // 判据：如果延迟随轮次单调上涨，"连续重启累积退避"这个假说就成立。
    let firstHalf = latencies.prefix(latencies.count / 2)
    let secondHalf = latencies.suffix(latencies.count - latencies.count / 2)
    let avgFirst = firstHalf.reduce(0, +) / Double(max(1, firstHalf.count))
    let avgSecond = secondHalf.reduce(0, +) / Double(max(1, secondHalf.count))
    print(String(format: "[A8 退避] 前半程均值 %.0f ms　后半程均值 %.0f ms", avgFirst, avgSecond))
    if avgSecond > avgFirst * 2 && avgSecond > 500 {
        print("[A8 退避] ⇒ **延迟随轮次显著上涨**：连续快速重启会累积退避（假说 ③ 成立）")
    } else {
        print("[A8 退避] ⇒ 延迟没有随轮次上涨：连续快速重启**不**累积退避")
    }
}

let kicked = results.filter { $0.kickedAt != nil }
print("[A8 退避] 需要 kickstart 的轮数：\(kicked.count) / \(results.count)")
for row in kicked {
    let recover = row.kickedAt.map { row.latency - $0 } ?? 0
    print(String(format: "[A8 退避] 第 %d 轮：%.0f ms 处催，%.0f ms 后归位（催办前已等了 %.0f ms）",
                 row.index, row.kickedAt ?? 0, recover, row.kickedAt ?? 0))
}
print("""

[A8 退避] 读法：
  · 延迟一路 40–130 ms      → 连续快速重启不是成因，假说 ③ 才算真被证伪
  · 延迟随轮次涨到秒级/几十秒 → **复现了 A8**，根因 = launchd 的重启退避
  · 有 kickstart 的轮次恢复很快 → "等 500 ms 就催一发"这个修法有效
""")

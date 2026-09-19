// A8 线索定向测量：`NSRunningApplication`（LaunchServices）在 Dock 重启窗口里**滞后多久**。
//
// 为什么要这个脚本：2026-09-20 的真机取证仪表（`docs/spikes.md` 实验 15.2）在**一次正常重启**里
// 就抓到了两路分叉 —— `0ms LS=<旧 PID> scan=nil`，`36ms LS=nil scan=<新 PID>`。
// 也就是说：**发完 SIGHUP 之后，LS 有一段时间仍然在报那个正在退出的旧 Dock。**
//
// 这正好命中 `RealDockProcessControl.dockPID()` 的结构：它**优先 LS**，只有 LS 返回 nil 才退回
// 进程表。于是只要 LS 还在报旧 PID，`dockPID()` 就返回**旧 PID**，而
// `DockReloader.waitForRestart()` 的判据是 `pid != oldPID` —— **它看不见重启已经发生**，
// 会一直等到 LS 松手。如果 LS 的滞后是毫秒级，这只是一个无害的几十毫秒尾巴；
// 如果它能滞后到秒级，**这就是 A8「偶发慢重启」的机制**（实验 12–14 把四个假说都证伪了，
// 恰好没测过这一个）。
//
// 本脚本只回答一个问题：**LS 滞后多久**。分位、分布、上界，都测出来。
//
// 用法：swiftc -O -o /tmp/md-ls-lag scripts/measure-launchservices-lag.swift && /tmp/md-ls-lag [轮数]
//
// ⚠️ 每轮会真的给 Dock 发一次 SIGHUP（= 重启 Dock，约 100 ms 不可用），这是 MultiDock 的常规操作。
// ⚠️ 不发 SIGKILL、不写任何偏好域、不改 Dock 配置 —— **只读 + 发信号**。
// ⚠️ 唯一的安全闸门和产品代码一致：只对确认进程名是 `Dock` 的**正数 PID** 发信号。

import AppKit
import Darwin
import Foundation

private let dockBundleIdentifier = "com.apple.dock"
private let dockProcessName = "Dock"

/// 首选路径：LaunchServices。
private func launchServicesDockPID() -> pid_t? {
    NSRunningApplication
        .runningApplications(withBundleIdentifier: dockBundleIdentifier)
        .first(where: { !$0.isTerminated && $0.processIdentifier > 0 })?
        .processIdentifier
}

/// 进程名。拿不到返回 nil。
private func processName(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let name = buffer.prefix(Int(length)).prefix { $0 != 0 }
    guard !name.isEmpty else { return nil }
    return String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// 兜底路径：直接扫内核进程表（`proc_listpids` + `proc_name`，约 0.02 ms）。
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

/// 与产品代码 `RealDockProcessControl.dockPID()` 逐字同构：LS 优先，LS 给不出才扫进程表。
private func dockPID() -> pid_t? {
    if let pid = launchServicesDockPID() { return pid }
    return scanForDockPID()
}

private func ms(_ since: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000
}

private func signalDock(_ pid: pid_t, _ sig: Int32) -> Bool {
    guard pid > 0 else { return false }
    guard processName(of: pid) == dockProcessName else { return false }
    return Darwin.kill(pid, sig) == 0
}

// MARK: - 主流程

let rounds = max(1, CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 5 : 5)
let sampleInterval: useconds_t = 1_000   // 1 ms
let watchFor: Double = 1500              // 每轮最多观察 1.5 s

print("""
=== LaunchServices 滞后测量（\(rounds) 轮，采样 \(sampleInterval / 1000) ms）===
每轮：读 old PID → 发 SIGHUP → 每 1 ms 同时问两条路径，直到两路都看到新 PID 或超时 \(Int(watchFor)) ms
""")

/// 一轮的结论。
struct Round {
    var oldPID: pid_t
    var newPID: pid_t
    /// 进程表第一次看到新 PID 的时刻（ms，相对发信号）。
    var scanSawNew: Double?
    /// LS 第一次不再返回旧 PID 的时刻。
    var lsLetGoOld: Double?
    /// LS 第一次看到新 PID 的时刻。
    var lsSawNew: Double?
    /// `dockPID()`（LS 优先）第一次返回新 PID 的时刻 —— **这才是产品真正感知到重启的时刻**。
    var effectiveSawNew: Double?
    /// 进程表已经看到新 PID、但 `dockPID()` 还在报旧 PID 的危险窗口长度。
    var blindWindow: Double?
    var timeline: [String]
}

var results: [Round] = []

for round in 1...rounds {
    guard let oldPID = dockPID(), oldPID > 0 else {
        print("第 \(round) 轮：拿不到 Dock PID，中止")
        exit(1)
    }

    let start = DispatchTime.now()
    guard signalDock(oldPID, SIGHUP) else {
        print("第 \(round) 轮：SIGHUP 发不出去（安全闸门拦下），中止")
        exit(1)
    }

    var r = Round(oldPID: oldPID, newPID: 0, timeline: [])
    var lastLS: pid_t?? = nil     // 双层可选：区分"没采样过"和"采到 nil"
    var lastScan: pid_t?? = nil

    while ms(start) < watchFor {
        let ls = launchServicesDockPID()
        let scan = scanForDockPID()
        let effective = ls ?? scan
        let t = ms(start)

        if lastLS == nil || lastLS! != ls {
            r.timeline.append("\(Int(t))ms LS=\(ls.map(String.init) ?? "nil")")
            lastLS = .some(ls)
        }
        if lastScan == nil || lastScan! != scan {
            r.timeline.append("\(Int(t))ms scan=\(scan.map(String.init) ?? "nil")")
            lastScan = .some(scan)
        }

        if let scan, scan != oldPID {
            if r.scanSawNew == nil { r.scanSawNew = t }
            if let effective, effective != oldPID, r.effectiveSawNew == nil {
                r.effectiveSawNew = t
                r.newPID = effective
                r.blindWindow = t - (r.scanSawNew ?? t)
                // 两路都到齐了就可以收工 —— 但 LS 也得看过新 PID，否则"滞后"没测到上界。
                if r.lsSawNew != nil { break }
            }
        }
        if let ls, ls != oldPID {
            if r.lsSawNew == nil { r.lsSawNew = t }
        } else if ls == nil {
            if r.lsLetGoOld == nil { r.lsLetGoOld = t }
        }
        usleep(sampleInterval)
    }

    results.append(r)
    print("""
    第 \(round) 轮：\(oldPID) → \(r.newPID == 0 ? "未确认" : String(r.newPID))
      scan 看到新 PID：\(r.scanSawNew.map { "\(Int($0))ms" } ?? "超时未见")
      LS 松手（不再报旧 PID）：\(r.lsLetGoOld.map { "\(Int($0))ms" } ?? "超时仍报旧 PID")
      LS 看到新 PID：\(r.lsSawNew.map { "\(Int($0))ms" } ?? "超时未见")
      dockPID()（LS 优先）感知到重启：\(r.effectiveSawNew.map { "\(Int($0))ms" } ?? "超时未见")
      危险窗口（进程表已知新、LS 还报旧）：\(r.blindWindow.map { "\(Int($0))ms" } ?? "无")
      时间线：\(r.timeline.joined(separator: "｜"))
    """)
    usleep(1_200_000)   // 1.2 s，错开 launchd 的重启节流（见 AGENTS.md §4）
}

// MARK: - 汇总

let lag = results.compactMap(\.blindWindow).sorted()
let lsLag = results.compactMap { r -> Double? in
    guard let a = r.lsSawNew, let b = r.scanSawNew else { return nil }
    return a - b
}.sorted()

func describe(_ values: [Double], _ label: String) {
    guard !values.isEmpty else { print("  \(label)：无样本"); return }
    let min = values.first!
    let max = values.last!
    let mid = values[values.count / 2]
    print("  \(label)：min \(Int(min))ms / 中位 \(Int(mid))ms / max \(Int(max))ms（\(values.count) 个样本）")
}

print("""
=== 汇总 ===
危险窗口（进程表看到新 PID 起，到 dockPID() 也看到为止）:
""")
describe(lag, "LS 优先造成的额外等待")
print("LS 看到新 PID 相对进程表的滞后:")
describe(lsLag, "LS 滞后")
let never = results.filter { $0.lsSawNew == nil }.count
if never > 0 { print("  ⚠️ \(never) 轮里 LS 在 \(Int(watchFor)) ms 内始终没看到新 PID") }
print("""
---
判读：
- 危险窗口都在**几十毫秒**量级 → LS 滞后不是 A8（偶发 26–31 秒）的成因，这条线索可以结案。
- 出现**秒级**样本 → 高度可疑：`waitForRestart` 的判据会一直等 LS 松手，
  修法是让重启判定**以进程表为准**（`dockPID()` 里把 scan 提到前面，或 `waitForRestart` 直接扫进程表）。
""")

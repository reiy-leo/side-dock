// 测「Dock 重启前至少要活多久」——launchd 在什么 uptime 以下会把重启算成崩溃并加重退避。
//
// 背景：`docs/spikes.md` 实验 11 从用户真机日志里发现，Dock 的 uptime 只有 6.5 s 时重启，
// 归位要 **26 046 ms**；uptime 1 s 时 **31 039 ms**；而 uptime ≥ 30 s 的 4 次只要 50–126 ms。
// `com.apple.Dock.plist` 里写的 `ThrottleInterval = 1`，所以"10 秒节流"是推断、不是实测。
// 这个脚本就是为了把那个门槛量出来，好决定 `DockReloader.minimumSpacing` 该设多少。
//
// 用法：swift scripts/spike-restart-spacing.swift [uptime 秒数 ...]
//   例：swift scripts/spike-restart-spacing.swift 30 12 5
//   默认：30 12 5（**从大到小**，避免先踩退避把后面的点全污染）
//
// ⚠️ 会真的重启 Dock，每次可能让 Dock 消失几十毫秒到几十秒。**只重启、不写任何偏好**，
//    所以配置是安全的；跑完会确认 Dock 还活着，不在就 kickstart 拉回。
// ⚠️ 不用 `NSRunningApplication`（脚本不是 `.app`，查不到 Dock），走 `proc_listpids` + `proc_name`。

import Darwin
import Foundation

// MARK: - 进程探测（与 RealDockProcessControl 同一套手法）

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

/// 进程启动时刻（Unix 秒）。与 `RealDockProcessControl.startTime(of:)` 同源。
func startTime(of pid: pid_t) -> TimeInterval? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
    guard written == Int32(size) else { return nil }
    return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
}

func dockAge() -> TimeInterval? {
    guard let pid = dockPID(), let started = startTime(of: pid) else { return nil }
    return Date().timeIntervalSince1970 - started
}

func sleep(seconds: Double) {
    guard seconds > 0 else { return }
    Thread.sleep(forTimeInterval: seconds)
}

func now() -> Double { Date().timeIntervalSince1970 }

/// 发 SIGHUP，轮询等新 PID。返回 (新 PID, 不可用时长秒)；超时返回 (nil, 观测时长)。
func restartAndMeasure(timeout: Double) -> (pid_t?, Double) {
    guard let oldPID = dockPID() else { return (nil, 0) }
    let t0 = now()
    guard kill(oldPID, SIGHUP) == 0 else { return (nil, 0) }
    while now() - t0 < timeout {
        if let pid = dockPID(), pid != oldPID {
            return (pid, now() - t0)
        }
        usleep(15_000)
    }
    return (nil, now() - t0)
}

// MARK: - 主流程

let args = Array(CommandLine.arguments.dropFirst()).compactMap(Double.init)
let targets = args.isEmpty ? [20.0, 12.0, 6.0] : args
let safeAge = 60.0       // 「Dock 老到这个年龄」才敢做重置重启（实验 11 里 34 s 是干净的）
let timeout = 120.0      // 单点观测上限；超了就停手，不再加深退避

print("Dock 重启间距实验 — 目标 uptime：\(targets.map { String(format: "%.0f", $0) }.joined(separator: " / ")) 秒")
print("每个测点前先等 Dock 活到 \(Int(safeAge)) s，再做一次「重置重启」，然后等到目标 uptime 才测。")
print("单点观测上限 \(Int(timeout)) 秒\n")

guard let firstPID = dockPID() else {
    print("错误：Dock 未运行，先把它拉回来再跑")
    exit(1)
}
print("起始 Dock PID \(firstPID)，年龄 \(String(format: "%.1f", dockAge() ?? -1)) s\n")

/// 等到 Dock 的年龄达到 `age`（读不到就返回实际观测值）。
func waitUntilAge(_ age: Double) {
    guard let current = dockAge(), current < age else { return }
    sleep(seconds: age - current)
}

var rows: [(label: String, uptime: Double, recovery: Double, pid: pid_t?)] = []
var aborted = false

for (index, target) in targets.enumerated() {
    if index > 0 { print("") }

    // 1) 先让 Dock 活够 safeAge，这样"重置重启"本身不会吃退避。
    waitUntilAge(safeAge)
    let resetAge = dockAge() ?? safeAge
    let (resetPID, resetElapsed) = restartAndMeasure(timeout: timeout)
    guard let resetPID else {
        print("⚠️ 重置重启在 \(Int(timeout)) s 内没归位 —— 停手")
        aborted = true
        break
    }
    print(String(format: "对照（重置重启，uptime %.0f s）：%.0f ms", resetAge, resetElapsed * 1000))
    rows.append(("对照", resetAge, resetElapsed, resetPID))

    // 2) 等这个新 Dock 长到目标年龄。
    waitUntilAge(target)
    let actualAge = dockAge() ?? target
    let (newPID, elapsed) = restartAndMeasure(timeout: timeout)
    if newPID != nil {
        print(String(format: "测量（uptime %.1f s）：%.0f ms", actualAge, elapsed * 1000))
    } else {
        print(String(format: "测量（uptime %.1f s）：⚠️ %.0f s 内没归位 —— 停手", actualAge, timeout))
        aborted = true
    }
    rows.append((String(format: "%.0f s", target), actualAge, elapsed, newPID))
    if aborted { break }
}

// MARK: - 收尾：确保 Dock 活着

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

// MARK: - 结论

var lines: [String] = []
lines.append("")
lines.append("测点      uptime(s)  归位耗时(ms)  判定")
lines.append("------  ---------  ------------  ----------------")
for row in rows {
    let verdict: String
    if row.pid == nil {
        verdict = "超时未归位"
    } else if row.recovery < 0.5 {
        verdict = "正常（未吃退避）"
    } else if row.recovery < 5 {
        verdict = "轻微延迟"
    } else {
        verdict = "吃了退避"
    }
    lines.append(String(format: "%-6@  %9.1f  %12.0f  %@",
                        row.label as NSString, row.uptime, row.recovery * 1000, verdict))
}
lines.append("")
lines.append("判据：归位耗时 < 500 ms 视为「没被罚」；≥ 5 s 视为「被 launchd 退避罚了」。")
lines.append("门槛落在**最后一个「正常」与第一个「吃了退避」之间**。")
if aborted {
    lines.append("⚠️ 本次被中断（有点超时未归位），结论不完整。")
}
let text = lines.joined(separator: "\n")
print(text)
try? text.write(toFile: "/tmp/multidock-spike/restart-spacing.txt", atomically: true, encoding: .utf8)

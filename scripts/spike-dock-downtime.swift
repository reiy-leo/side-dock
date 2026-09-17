// 测量 Dock 在收到信号后的停机时长（毫秒级）。
// 用法：swift scripts/spike-dock-downtime.swift <SIGNAL> [输出文件]
// 例：  swift scripts/spike-dock-downtime.swift TERM /tmp/downtime.txt
// 原理：先记录旧 PID，发信号，然后以 1ms 间隔轮询 Dock 是否在跑，直到新 PID 稳定出现。

import AppKit
import Darwin
import Foundation

let args = CommandLine.arguments
let signalName = args.count > 1 ? args[1] : "TERM"
let outPath = args.count > 2 ? args[2] : "/tmp/multidock-spike/downtime.txt"
let signalNumber = signalName == "HUP" ? SIGHUP : (signalName == "KILL" ? SIGKILL : SIGTERM)

func dockPID() -> pid_t {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return 0 }
    return app.processIdentifier
}

let oldPID = dockPID()
guard oldPID > 0 else {
    print("错误：Dock 未运行")
    exit(1)
}

let t0 = DispatchTime.now().uptimeNanoseconds
kill(oldPID, signalNumber)

var vanishedAt: Double = -1
var returnedAt: Double = -1
var newPID: pid_t = 0
let deadline = t0 + 10_000_000_000  // 10s

while DispatchTime.now().uptimeNanoseconds < deadline {
    let now = DispatchTime.now().uptimeNanoseconds
    let pid = dockPID()
    if pid == 0 {
        if vanishedAt < 0 { vanishedAt = Double(now - t0) / 1e6 }
    } else if pid != oldPID {
        if returnedAt < 0 { returnedAt = Double(now - t0) / 1e6; newPID = pid }
        break
    }
    usleep(1000)
}

var lines: [String] = []
lines.append("信号            : \(signalName)")
lines.append("旧 PID          : \(oldPID)")
lines.append("新 PID          : \(newPID)")
if vanishedAt >= 0 {
    lines.append("进程消失于      : +\(String(format: "%.1f", vanishedAt)) ms")
} else {
    lines.append("进程消失于      : 未观察到（采样未捕获空档）")
}
if returnedAt >= 0 {
    lines.append("Dock 归位       : +\(String(format: "%.1f", returnedAt)) ms")
    let down = vanishedAt >= 0 ? returnedAt - vanishedAt : returnedAt
    lines.append("停机时长        : \(String(format: "%.0f", down)) ms")
    lines.append("不可用窗口(含重启): \(String(format: "%.0f", returnedAt)) ms")
} else {
    lines.append("Dock 归位       : 10 秒内未归位（需 launchctl kickstart 兜底）")
}

let text = lines.joined(separator: "\n")
print(text)
try? text.write(toFile: outPath, atomically: true, encoding: .utf8)

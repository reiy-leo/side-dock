// 实验 18（B7）：真人在 Dock / 触控板手动切桌面时，NSWorkspaceActiveSpaceDidChangeNotification
// 到底触发不触发？
//
// 背景：P0（spikes.md 实验 2）证伪了「程序化切桌面（CGSManagedDisplaySetCurrentSpace）触发通知」——
// 不触发，所以 SpaceObserver 改成 300 ms 轮询为主。但**真人手势**走 WindowServer 的正常路径，
// 可能触发公开通知；若触发，用户手动切桌面的跟随延迟能从 300 ms 降到接近 0。
//
// 方法：同时观察 ① 公开通知 ② SkyLight 活动空间高频轮询（50 ms，只读）。
// 每次轮询发现空间变化时，回看 ±0.5 s 内有没有通知伴随 —— 这就是判定。
//
// 零权限：公开 API 通知 + SkyLight 只读，不写任何偏好、不发信号、不切桌面。
//
// 用法：
//   swiftc -O -o /tmp/md-notify-watch scripts/spike-space-notify-watch.swift
//   /tmp/md-notify-watch 120        # 观察 120 秒；期间请用 ⌃←/⌃→ 或触控板手势手动切桌面几次
//                                   # （别用 MultiDock 菜单栏 —— 那是程序化切换，预期不触发）
import AppKit

setvbuf(stdout, nil, _IONBF, 0)
let seconds: TimeInterval = {
    if CommandLine.arguments.count > 1, let v = TimeInterval(CommandLine.arguments[1]) { return v }
    return 120
}()

func stamp(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: d)
}

_ = NSApplication.shared
let lock = NSLock()
var notifyTimes: [Date] = []

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
) { _ in
    let t = Date()
    lock.withLock { notifyTimes.append(t) }
    print("\(stamp(t))  NOTIFY   activeSpaceDidChange 触发")
}

guard
    let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
    let symConn = dlsym(handle, "CGSMainConnectionID"),
    let symActive = dlsym(handle, "CGSGetActiveSpace")
else {
    print("SkyLight 符号缺失，无法做轮询对照")
    exit(1)
}
typealias MainConnFn = @convention(c) () -> Int32
typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64
let mainConn = unsafeBitCast(symConn, to: MainConnFn.self)
let activeSpace = unsafeBitCast(symActive, to: ActiveSpaceFn.self)

var last: UInt64 = activeSpace(mainConn())
var pollChanges = 0
var withNotify = 0
print("=== 观察 \(Int(seconds))s：请用 ⌃←/⌃→ 或触控板手势手动切桌面几次 ===")
print("初始空间 id64=\(last)")

let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let now = activeSpace(mainConn())
    guard now != last else { continue }
    let t = Date()
    pollChanges += 1
    let matched = lock.withLock {
        notifyTimes.contains { gap in
            let d = t.timeIntervalSince(gap)
            return d >= -0.1 && d <= 0.5
        }
    }
    if matched { withNotify += 1 }
    print("\(stamp(t))  POLL     空间变化 id64 \(last) → \(now)\(matched ? "（±0.5s 内有 NOTIFY）" : "（无通知）")")
    last = now
}

print("=== 汇总：轮询观察到 \(pollChanges) 次切换；其中 \(withNotify) 次伴随 activeSpaceDidChange；通知共 \(lock.withLock { notifyTimes.count }) 次 ===")
print("判定：手势切换若全部伴随 NOTIFY → SpaceObserver 可加通知为强信号（跟随延迟 ≈ 0）；")
print("      若均无 → 维持 300 ms 轮询，B7 关闭。程序化切换（MultiDock 菜单/脚本）预期无通知，不算数。")

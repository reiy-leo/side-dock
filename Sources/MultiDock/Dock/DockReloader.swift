import AppKit
import Darwin
import Foundation

/// Dock 进程操作的能力抽象。
///
/// 抽出来是为了让「重启判定与兜底顺序」能脱离真实 Dock 单测 —— 与 `SpaceProviding` 隔离私有 API 同理。
protocol DockProcessControlling: Sendable {
    /// 当前 Dock 进程 PID；Dock 不在时返回 nil。
    func dockPID() -> pid_t?
    /// 给 Dock 发信号。返回是否投递成功（Dock 已死时返回 false，不算异常）。
    @discardableResult func signal(_ pid: pid_t, _ sig: Int32) -> Bool
    /// `launchctl kickstart -k` 兜底。**只表示命令发出去了**，不表示 Dock 回来了，
    /// 而且实现必须是非阻塞的（见 `RealDockProcessControl.kickstart()`）。
    /// 已经有一发 launchctl 在飞时返回 false，不叠加。
    @discardableResult func kickstart() -> Bool
    /// 某个 PID 的启动时刻（Unix 秒）。拿不到返回 nil。
    ///
    /// 用来推算 launchd 的重启节流窗口（见 `DockReloader`）——
    /// 那个窗口是 **Dock 进程年龄**的函数，不是"我们记不记得自己重启过"的函数。
    func startTime(of pid: pid_t) -> TimeInterval?
}

extension DockProcessControlling {
    /// 替身默认拿不到启动时刻 → `DockReloader` 退回用内存里的 `lastRestartAt` 推算。
    func startTime(of pid: pid_t) -> TimeInterval? { nil }
}

/// `launchctl` 子进程的收纳处。
///
/// `kickstart` 必须**发完就走**（原因见 `RealDockProcessControl.kickstart()`），
/// 所以 `Process` 对象要在它退出前一直有人持有，否则会在子进程还活着时被释放。
/// 这里同时兼任「有没有一发 launchctl 还在飞」的判据 —— 叠着发正是退避的成因。
private final class LaunchctlParking: @unchecked Sendable {

    static let shared = LaunchctlParking()

    private let lock = NSLock()
    private var running: [Process] = []

    var hasOutstanding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !running.isEmpty
    }

    func park(_ process: Process) {
        lock.lock()
        running.append(process)
        lock.unlock()
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.lock.lock()
            self.running.removeAll { $0 === finished }
            self.lock.unlock()
        }
    }
}

/// 真实实现。
struct RealDockProcessControl: DockProcessControlling {

    static let dockBundleIdentifier = "com.apple.dock"
    /// `launchctl` 的服务名。Dock 由这个 LaunchAgent 拉起。
    static let dockServiceName = "com.apple.Dock.agent"
    /// Dock 的进程名，用于发信号前的身份确认。
    static let dockProcessName = "Dock"

    func dockPID() -> pid_t? {
        // 首选：LaunchServices 查询（实测单次 0.6–1.4 ms）。
        //
        // **必须过滤 `processIdentifier > 0`**：实测在 Dock 重启的窗口里，这里会返回一个
        // **正在退出**的实例，它的 `processIdentifier` 是 **-1**。把 -1 当成有效 PID 的后果
        // 见 `signal(_:_:)` 里的安全闸门说明 —— 那是能毁掉用户整个图形会话的。
        if let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.dockBundleIdentifier)
            .first(where: { !$0.isTerminated && $0.processIdentifier > 0 }) {
            return app.processIdentifier
        }
        // 兜底：非 .app 进程（例如 `swift test` 的 xctest runner）里上一条可能查不到，
        // 但 Dock 一定在跑。直接扫进程表，避免误判成"Dock 不在"。
        return Self.scanForDockPID()
    }

    /// 扫进程表找 Dock。
    ///
    /// **不用 `pgrep` 子进程**：实测 `/usr/bin/pgrep` 单次约 **110 ms**，
    /// 而 `proc_listpids` + `proc_name` 只要 **0.02 ms**。重启判定是 15 ms 一轮的轮询热路径，
    /// 每次 110 ms 会把"等 Dock 回来"从 0.1 秒拖到 1 秒以上（实测踩过：连切 20 次每次约 1.08 s）。
    private static func scanForDockPID() -> pid_t? {
        // 进程数会变，所以拿到的字节数等于缓冲上限时加倍重试，而不是直接放弃。
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

    /// 进程名。拿不到（进程已死、无权限）返回 nil。
    private static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        // 先截到 NUL 再解码：`String(cString:)` 已废弃。
        let name = buffer.prefix(Int(length)).prefix { $0 != 0 }
        guard !name.isEmpty else { return nil }
        return String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    @discardableResult
    func signal(_ pid: pid_t, _ sig: Int32) -> Bool {
        // ⚠️ **安全闸门，绝不能去掉。**
        //
        // `kill(-1, sig)` 的语义是"发给**当前用户的全部进程**"，`kill(0, sig)` 是"发给整个进程组"。
        // 一次误传就可能让用户当场丢掉整个图形会话。而 `NSRunningApplication` 在 Dock 重启
        // 窗口里**真的会**返回 -1（实测复现），所以这个值不是理论风险。
        guard pid > 0 else { return false }
        // 再确认一次这个 PID 真的是 Dock。只对确认过身份的 PID 发信号。
        guard Self.processName(of: pid) == Self.dockProcessName else { return false }
        return Darwin.kill(pid, sig) == 0
    }

    @discardableResult
    func kickstart() -> Bool {
        // ⚠️ **绝不能 `waitUntilExit()`。** 真机实测（2026-09-19）：launchd 处在重启退避里时
        // `/bin/launchctl kickstart` 会阻塞**几十秒**才返回（日志里是 54 / 60 / 64 s），
        // 而这条调用跑在 `@MainActor` 上 —— 整个 App 连带冻住那么久，存活监视器、桌面轮询、
        // toast、设置窗口全部停摆（表现为「切一次桌面，Dock 消失两分钟」）。
        // 返回值只说明"命令发出去了"，Dock 有没有回来由调用方轮询判定。
        guard !LaunchctlParking.shared.hasOutstanding else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "kickstart", "-k",
            "gui/\(getuid())/\(Self.dockServiceName)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        LaunchctlParking.shared.park(process)
        return true
    }

    /// Dock 进程的启动时刻。实测 `proc_pidinfo(PROC_PIDTBSDINFO)` 返回 136 字节 = 结构体大小。
    ///
    /// 拿不到（进程已死、无权限、结构体尺寸对不上）就返回 nil —— 调用方会退回用内存里的记忆推算。
    func startTime(of pid: pid_t) -> TimeInterval? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        // 尺寸对不上说明结构体布局变了（跨系统版本），宁可返回 nil 也别读错字段。
        guard written == Int32(size) else { return nil }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    }
}

/// 一次重载的结果。耗时与所用手段都要能被记录（计划 §3.4 第 6 条）。
struct ReloadOutcome: Sendable, Equatable {

    enum Method: String, Sendable {
        /// 主路径：约 101 ms 不可用。
        case sighup = "SIGHUP"
        /// 兜底：Dock 会先做约 255 ms 退出清理，总计约 367–395 ms。
        case sigterm = "SIGTERM"
        /// launchd 拉回。
        case kickstart = "kickstart"
        case failed = "失败"
    }

    var method: Method
    var oldPID: pid_t?
    var newPID: pid_t?
    /// **Dock 真正不可用的时长**（不含 `spacingWait`）。
    var elapsed: TimeInterval
    /// 为了错开 launchd 的重启节流而主动等待的时间。这段等待里 **Dock 是可用的**，
    /// 所以不能算进"不可用时长"，否则日志会吓人。
    var spacingWait: TimeInterval = 0

    var succeeded: Bool { newPID != nil }

    var description: String {
        let wait = spacingWait > 0.01
            ? String(format: "（先等了 %.0f ms 错开节流，期间 Dock 可用）", spacingWait * 1000)
            : ""
        guard succeeded else {
            return String(format: "%@ 失败（%.0f ms，旧 PID %@）%@", method.rawValue, elapsed * 1000,
                          oldPID.map(String.init) ?? "无", wait)
        }
        return String(format: "%@ 成功：PID %@ → %@，Dock 不可用 %.0f ms%@",
                      method.rawValue, oldPID.map(String.init) ?? "?", String(newPID!), elapsed * 1000, wait)
    }
}

/// 让写入的 Dock 偏好生效。
///
/// **Dock 没有热重载**（P0 实测：post 任何通知都无效），只能让 Dock 进程重启。
/// 主路径 `SIGHUP`（约 101 ms 不可用），兜底 `SIGTERM` + `launchctl kickstart`。
///
/// ⚠️ **绝不用 AppleEvent 优雅退出**：`/System/Library/LaunchAgents/com.apple.Dock.plist` 是
/// `KeepAlive = {AfterInitialDemand:1, SuccessfulExit:0}`，退出码 0 时 launchd **不会**把 Dock 拉回来，
/// 用户会当场失去 Dock。只走信号路径。
///
/// ⚠️ **只对确认过身份的 PID 发信号**。`kill(-1, sig)` 会发给当前用户的全部进程，
/// `kill(0, sig)` 会发给整个进程组 —— 而 Dock 重启窗口里 `NSRunningApplication` 真的会返回 -1。
/// 闸门在 `RealDockProcessControl.signal(_:_:)`，改动时不要绕过它。
///
/// ⚠️ **重启要错开 `minimumSpacing`**。实测（`docs/spikes.md` 实验 5）：
/// 两次重启间隔 **< 1 s** 时 Dock 要等 **约 1070 ms** 才归位；间隔 **≥ 1 s** 时只要 **约 70 ms**。
/// 这是 launchd 的重启节流。所以"先等一会儿再重启"严格优于"立刻重启" ——
/// 等待期间 Dock 还能用，而立刻重启会让 Dock 消失一秒多。
@MainActor
final class DockReloader {

    private let process: any DockProcessControlling
    /// 等 Dock 归位的上限。**必须明显长于 launchd 的退避尺度**（真机实测几十秒，见
    /// `docs/spikes.md` 实验 8.5），否则一次正常的慢拉起会被我们误判成"SIGHUP 失败"，
    /// 紧接着升级到 `SIGTERM` + `kickstart -k` —— 那一发 `-k` 会把 launchd 正要拉起的
    /// Dock 再杀一次，把 1 秒的节流滚成两分钟的 Dock 死亡。2026-09-19 就是这么踩的。
    private let timeout: Duration
    private let pollInterval: Duration
    /// 发完 SIGTERM 后、动 `kickstart` 之前给的宽限。等的是「launchd 自己把 Dock 拉回来」，
    /// 免得正常机器上也白等一次 `kickstart`。
    private let fallbackGrace: Duration
    /// 两次重启之间的最小间隔，用来错开 launchd 的重启节流（见类文档）。
    private let minimumSpacing: Duration
    /// 上一次重启**归位**的时刻。节流窗口从这一刻算起。
    private var lastRestartAt: ContinuousClock.Instant?

    init(
        process: any DockProcessControlling = RealDockProcessControl(),
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(15),
        fallbackGrace: Duration = .milliseconds(500),
        minimumSpacing: Duration = .milliseconds(1000)
    ) {
        self.process = process
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.fallbackGrace = fallbackGrace
        self.minimumSpacing = minimumSpacing
    }

    /// Dock 进程此刻在不在。
    ///
    /// 给「别在 Dock 缺失期间读它的偏好域」用（见 `DockWatcher.tick()`）——
    /// 那个窗口里域读回来的是残缺内容。
    var isDockAlive: Bool {
        guard let pid = process.dockPID() else { return false }
        return pid > 0
    }

    /// 重启 Dock。
    ///
    /// - Parameter strategy: `.auto` 先 SIGHUP；`.sigterm` 直接走 SIGTERM。
    ///   两条路失败都落到 `kickstart`。
    func reload(strategy: ReloadStrategy = .auto) async -> ReloadOutcome {
        // 先错开节流窗口。这段时间 Dock 是**可用**的，所以不计入"不可用时长"。
        let spacingWait = await waitForSpacing()

        let started = Date()
        guard let oldPID = process.dockPID() else {
            return ReloadOutcome(method: .failed, oldPID: nil, newPID: nil,
                                 elapsed: Date().timeIntervalSince(started),
                                 spacingWait: spacingWait)
        }

        if strategy == .auto {
            process.signal(oldPID, SIGHUP)
            if let newPID = await waitForRestart(after: oldPID) {
                return outcome(.sighup, oldPID: oldPID, newPID: newPID,
                               started: started, spacingWait: spacingWait)
            }
        } else {
            process.signal(oldPID, SIGTERM)
            if let newPID = await waitForRestart(after: oldPID) {
                return outcome(.sigterm, oldPID: oldPID, newPID: newPID,
                               started: started, spacingWait: spacingWait)
            }
        }

        // 兜底：确保 Dock 以信号致死，再用 launchd 拉回。
        let dyingPID = process.dockPID() ?? oldPID
        process.signal(dyingPID, SIGTERM)
        // 给它一点时间死透；这段时间内 launchd 可能自己就把它拉回来了。
        if let newPID = await waitForRestart(after: dyingPID, timeout: fallbackGrace) {
            return outcome(.sigterm, oldPID: oldPID, newPID: newPID,
                           started: started, spacingWait: spacingWait)
        }
        process.kickstart()
        if let newPID = await waitForRestart(after: dyingPID) {
            return outcome(.kickstart, oldPID: oldPID, newPID: newPID,
                           started: started, spacingWait: spacingWait)
        }

        return ReloadOutcome(method: .failed, oldPID: oldPID, newPID: nil,
                             elapsed: Date().timeIntervalSince(started),
                             spacingWait: spacingWait)
    }

    /// 睡到 Dock 的「年龄」超过 `minimumSpacing` 为止。返回实际等待时长。
    ///
    /// **判据是 Dock 进程的真实年龄，不是我们自己的记忆。** 这是被验收实测逼出来的：
    /// P4 验收里前一条用例刚重启完 Dock，紧接着 P3 用例新建了一个 `DockReloader`
    /// （`lastRestartAt` 为 nil，它以为"从没重启过"），于是第一次重启直接被节流到
    /// **1030 ms**，Dock 消失了一秒多。
    ///
    /// 教训：launchd 的节流是**按服务**算的，与我们记不记得自己重启过无关。
    /// 所以"别人刚重启过 Dock"（用户 `killall Dock`、别的 App、我们的存活监视器 `kickstart`）
    /// 同样会让我们的下一次重启变慢。按进程年龄算就把这些情况全覆盖了。
    ///
    /// 拿不到启动时刻（替身进程、跨系统版本结构体变化）才退回内存里的 `lastRestartAt`。
    private func waitForSpacing() async -> TimeInterval {
        let spacing = Self.seconds(minimumSpacing)

        if let pid = process.dockPID(), pid > 0, let startedAt = process.startTime(of: pid) {
            let age = Date().timeIntervalSince1970 - startedAt
            let remaining = spacing - age
            guard remaining > 0.001 else { return 0 }
            let started = Date()
            try? await Task.sleep(for: .seconds(remaining))
            return Date().timeIntervalSince(started)
        }

        guard let last = lastRestartAt else { return 0 }
        let target = last + minimumSpacing
        let remaining = ContinuousClock.now.duration(to: target)
        guard remaining > .zero else { return 0 }
        let started = Date()
        try? await Task.sleep(for: remaining)
        return Date().timeIntervalSince(started)
    }

    /// `Duration` → 秒。只用于和 `Date` 的墙钟做差，不参与计时精度敏感的地方。
    private static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18
    }

    /// 轮询等待一个**不同于** `oldPID` 的 Dock 进程出现。
    ///
    /// 只接受**正数** PID：`NSRunningApplication` 在 Dock 重启窗口里会返回 -1，
    /// 若把它当成"新 Dock 回来了"，`ReloadOutcome` 会谎报成功（Dock 其实还没回来）。
    /// `RealDockProcessControl` 里已有一道闸门，这里是第二道 —— 两层都便宜，都留着。
    private func waitForRestart(after oldPID: pid_t, timeout: Duration? = nil) async -> pid_t? {
        let deadline = ContinuousClock.now + (timeout ?? self.timeout)
        while ContinuousClock.now < deadline {
            if let pid = process.dockPID(), pid > 0, pid != oldPID {
                // 节流窗口从"新 Dock 归位"这一刻算起。
                lastRestartAt = ContinuousClock.now
                return pid
            }
            try? await Task.sleep(for: pollInterval)
        }
        return nil
    }

    private func outcome(
        _ method: ReloadOutcome.Method,
        oldPID: pid_t,
        newPID: pid_t,
        started: Date,
        spacingWait: TimeInterval
    ) -> ReloadOutcome {
        ReloadOutcome(method: method, oldPID: oldPID, newPID: newPID,
                      elapsed: Date().timeIntervalSince(started), spacingWait: spacingWait)
    }
}

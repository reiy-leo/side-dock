import AppKit
import Darwin
import Foundation

/// 诊断快照：两条 PID 探测路径**此刻各自**的答案。
///
/// 存在的唯一理由，是把「Dock 重启偶发慢到 26–31 秒」这个未解故障变成**能自证**的。
/// 真机上那两次慢重启的日志只写了结果（`Dock 不可用 26046 ms`），没写**过程** ——
/// 于是四种解释都能套上去，四个假说全被实验 12–14 证伪之后仍然定不了案。
///
/// 这一层仪表要区分的是**两种截然不同的病因**：
/// - `procScan` 早就看到新 PID、`launchServices` 迟迟看不到 → **探测分叉**（我们的 bug）；
/// - 两条路径都只看到 `nil` → **Dock 真的没回来**（launchd 的事，我们改不了）。
///
/// 只有第一种才该改代码。见 `docs/spikes.md` 实验 11.6 与实验 15。
struct DockPIDProbe: Sendable, Equatable {
    /// `NSRunningApplication`（`dockPID()` 的首选路径）。
    var launchServices: pid_t?
    /// `proc_listpids` + `proc_name`（内核进程表，实测 0.02 ms，是事实来源）。
    var procScan: pid_t?

    /// 给日志用的一小段。`nil` 是有效信息（"这条路径此刻查不到 Dock"）。
    var summary: String {
        "LS=\(launchServices.map(String.init) ?? "nil") scan=\(procScan.map(String.init) ?? "nil")"
    }
}

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
    /// 诊断用：两条探测路径各自的答案。**只为慢重启取证**，正常路径不调用。
    ///
    /// 刻意做成带默认实现的可选能力：测试替身没有"两条路径"这回事，
    /// 返回 nil 就表示"这个替身不支持取证"，`DockReloader` 会照常工作、只是不带时间线。
    func pidProbe() -> DockPIDProbe?
}

extension DockProcessControlling {
    /// ⚠️⚠️ **这个扩展里的每个方法都是一个陷阱入口，加新方法前先读完这段。**
    ///
    /// 有默认实现的协议要求，具体实现的返回类型**必须与协议要求逐字相同** ——
    /// Swift 不做返回类型协变匹配，写成非可选（或任何不同形状）会被当成**另一个重载**，
    /// 于是协议要求的见证位**由这里的默认实现满足**，经 `any` 协议调用永远拿到默认值。
    /// 实测（2026-09-20）：`pidProbe()` 就是这么让 A8 的取证仪表在生产路径上完全没接线的 ——
    /// 而所有替身单测照样全绿。完整复盘见 `docs/spikes.md` 实验 15.2。
    ///
    /// **规矩**：每加一个有默认实现的要求，就必须在 `DockProcessSafetyTests` 里补一条
    /// **经 `any DockProcessControlling` 调用**的守卫测试（经具体类型调用测不出来）。
    /// 目前两条要求都有守卫：`pidProbe()` 与 `startTime(of:)`。

    /// 替身默认拿不到启动时刻 → `DockReloader` 退回用内存里的 `lastRestartAt` 推算。
    func startTime(of pid: pid_t) -> TimeInterval? { nil }

    /// 替身默认不支持取证 → 慢重启只会记下"Dock 不可用多久"，不记两条路径的分叉。
    func pidProbe() -> DockPIDProbe? { nil }
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
        if let pid = Self.launchServicesDockPID() { return pid }
        // 兜底：非 .app 进程（例如 `swift test` 的 xctest runner）里上一条可能查不到，
        // 但 Dock 一定在跑。直接扫进程表，避免误判成"Dock 不在"。
        return Self.scanForDockPID()
    }

    /// 首选路径：LaunchServices。
    ///
    /// **必须过滤 `processIdentifier > 0`**：实测在 Dock 重启的窗口里，这里会返回一个
    /// **正在退出**的实例，它的 `processIdentifier` 是 **-1**。把 -1 当成有效 PID 的后果
    /// 见 `signal(_:_:)` 里的安全闸门说明 —— 那是能毁掉用户整个图形会话的。
    private static func launchServicesDockPID() -> pid_t? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.dockBundleIdentifier)
            .first(where: { !$0.isTerminated && $0.processIdentifier > 0 })?
            .processIdentifier
    }

    /// 取证：**同时**问两条路径，不做任何短路。
    ///
    /// 与 `dockPID()` 的区别就是"不短路"—— `dockPID()` 只要首选路径有答案就不会去扫进程表，
    /// 所以从它的返回值里**看不出**两条路径有没有分叉。慢重启要的正是这个分叉信息。
    ///
    /// ⚠️ **返回类型必须与协议要求逐字相同（`DockPIDProbe?`），不能写成非可选的 `DockPIDProbe`。**
    /// 实测（2026-09-20）：写成非可选时 Swift 认为它是**另一个重载**，协议要求转而由扩展里的
    /// 默认实现（返回 `nil`）满足 —— 于是**通过协议调用永远拿到 nil**，仪表在生产路径上完全是死的，
    /// 而所有单测都过（替身的签名是对的）。最小复现：
    /// ```swift
    /// protocol P { func probe() -> Probe? }
    /// extension P { func probe() -> Probe? { nil } }
    /// struct Real: P { func probe() -> Probe { Probe() } }   // 协变返回
    /// (Real() as any P).probe()   // → nil，默认实现抢到了见证位
    /// ```
    /// 回归守卫：`DockProcessSafetyTests.testRealControlIsWiredAsTheProtocolWitness`。
    func pidProbe() -> DockPIDProbe? {
        DockPIDProbe(launchServices: Self.launchServicesDockPID(), procScan: Self.scanForDockPID())
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
        //
        // ⚠️ **不带 `-k`。** `man launchctl`：`-k` = "若服务已在运行，先杀掉正在跑的实例再重启"。
        // 而这条兜底只在"我们已经把 Dock 弄没了、launchd 可能正要把它拉回来"时才会走到 ——
        // 带上 `-k` 就等于把 launchd 刚拉活的 Dock 再杀一次，并加深它的递增退避。
        // 真机 2026-09-19 那天每次 100–126 s 的 Dock 死亡都起源于这样一发。
        // 不带 `-k` 时这条命令只做一件事：让没在跑的服务立刻跑起来。
        guard !LaunchctlParking.shared.hasOutstanding else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "kickstart",
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

/// 退出流程里一次重启的结果。见 `DockReloader.reloadForQuit(strategy:deadline:)`。
enum QuitRestart: Sendable, Equatable {
    /// Dock 在期限内归位了。
    case revived(oldPID: pid_t, newPID: pid_t, elapsed: TimeInterval)
    /// 信号发了，期限内没看到新 Dock。偏好已经落盘，launchd 把 Dock 拉回来时会读到它 ——
    /// 所以这**不是失败**，只是"我们没来得及看一眼"。
    case signaled(oldPID: pid_t)
    /// Dock 进程本来就不在：什么信号都不发（发也没对象），也不 `kickstart`。
    case dockWasDown
    /// 信号没发出去（PID 身份确认失败）。偏好仍然已经落盘。
    case notDelivered(oldPID: pid_t)

    /// 给日志用的一句话。
    var description: String {
        switch self {
        case let .revived(oldPID, newPID, elapsed):
            return String(format: "SIGHUP 成功：PID %d → %d，Dock 不可用 %.0f ms", oldPID, newPID, elapsed * 1000)
        case let .signaled(oldPID):
            return "已发出重启信号，但 1.5 秒内没看到 Dock 归位（launchd 多半在退避）；"
                + "偏好已写回基准，Dock 下次启动会直接读到（旧 PID \(oldPID)）"
        case .dockWasDown:
            return "Dock 进程本来就不在，没有可重启的对象；偏好已写回基准，launchd 拉起时即生效"
        case let .notDelivered(oldPID):
            return "重启信号没能发出去（PID \(oldPID)）；偏好已写回基准，等 Dock 下次启动生效"
        }
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
    /// 慢重启的**取证时间线**（`pidProbe()` 的采样）。正常路径为空。
    ///
    /// 只在等待超过 `DockReloader.slowProbeThreshold`（默认 1 秒）之后才开始采样，
    /// 所以正常路径零开销。条目形如 `"1000ms LS=39129 scan=39143"`。
    ///
    /// 它存在的意义：把"Dock 不可用 26046 ms"从一个**结果**变成一条**过程记录**，
    /// 从而区分「探测分叉（我们的 bug）」与「Dock 真的没回来（launchd 的事）」。
    var probeTimeline: [String] = []
    /// 等归位期间**实际跑了几轮轮询**，以及最长的一次轮询间隔（ms）。
    ///
    /// 存在的理由：`elapsed` 是**墙钟**，而轮询循环跑在 `@MainActor` 上 ——
    /// 主线程若被别的东西冻住，我们会**根本没在看**，却照样把这段时间记成"Dock 不可用"。
    /// 两者在旧日志里长得一模一样（都是 `Dock 不可用 26046 ms`）。
    ///
    /// 有了这两个数就能当场分开：
    /// - 轮询次数 ≈ `elapsed / pollInterval`（默认 15 ms）、最长间隔十几毫秒
    ///   → 我们一直在看，**Dock 是真的不在**（launchd 侧）；
    /// - 次数远低于预期、最长间隔是**秒级**
    ///   → **观察窗口断了**，是我们的 bug，与 Dock 无关。
    var waitPolls: Int = 0
    var waitLongestGapMS: Int = 0

    var succeeded: Bool { newPID != nil }

    var description: String {
        let wait = spacingWait > 0.01
            ? String(format: "（先等了 %.0f ms 错开节流，期间 Dock 可用）", spacingWait * 1000)
            : ""
        // 存活性只在**慢重启**上记（`elapsed > 1`），保证快路径的日志行一个字节都不变。
        let liveness = (elapsed > 1 && waitPolls > 0)
            ? String(format: "；轮询 %d 次，最长间隔 %d ms", waitPolls, waitLongestGapMS)
            : ""
        let probe = probeTimeline.isEmpty
            ? ""
            : "；慢重启取证：" + probeTimeline.joined(separator: "｜")
        guard succeeded else {
            return String(format: "%@ 失败（%.0f ms，旧 PID %@）%@%@%@", method.rawValue, elapsed * 1000,
                          oldPID.map(String.init) ?? "无", wait, liveness, probe)
        }
        return String(format: "%@ 成功：PID %@ → %@，Dock 不可用 %.0f ms%@%@%@",
                      method.rawValue, oldPID.map(String.init) ?? "?", String(newPID!), elapsed * 1000,
                      wait, liveness, probe)
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
    /// 等待超过这么久才开始取证采样。默认 1 秒 —— 正常路径只要几十毫秒，永不触发。
    private let slowProbeThreshold: Duration
    /// 取证采样间隔。
    private let probeInterval: Duration
    /// 取证最多留多少条。一次 30 秒的慢重启按 100 ms 采样会有 300 条，会把日志灌爆。
    private let probeSampleCap: Int
    /// 上一次重启**归位**的时刻。节流窗口从这一刻算起。
    private var lastRestartAt: ContinuousClock.Instant?

    init(
        process: any DockProcessControlling = RealDockProcessControl(),
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(15),
        fallbackGrace: Duration = .milliseconds(500),
        minimumSpacing: Duration = .milliseconds(1000),
        slowProbeThreshold: Duration = .seconds(1),
        probeInterval: Duration = .milliseconds(100),
        probeSampleCap: Int = 24
    ) {
        self.process = process
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.fallbackGrace = fallbackGrace
        self.minimumSpacing = minimumSpacing
        self.slowProbeThreshold = slowProbeThreshold
        self.probeInterval = probeInterval
        self.probeSampleCap = max(1, probeSampleCap)
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
            let wait = await waitForRestart(after: oldPID)
            if let newPID = wait.pid {
                return outcome(.sighup, oldPID: oldPID, newPID: newPID,
                               started: started, spacingWait: spacingWait,
                               probeTimeline: wait.probeTimeline,
                               polls: wait.polls, longestGapMS: wait.longestGapMS)
            }
        } else {
            process.signal(oldPID, SIGTERM)
            let wait = await waitForRestart(after: oldPID)
            if let newPID = wait.pid {
                return outcome(.sigterm, oldPID: oldPID, newPID: newPID,
                               started: started, spacingWait: spacingWait,
                               probeTimeline: wait.probeTimeline,
                               polls: wait.polls, longestGapMS: wait.longestGapMS)
            }
        }

        // 兜底：确保 Dock 以信号致死，再用 launchd 拉回。
        let dyingPID = process.dockPID() ?? oldPID
        process.signal(dyingPID, SIGTERM)
        // 给它一点时间死透；这段时间内 launchd 可能自己就把它拉回来了。
        let grace = await waitForRestart(after: dyingPID, timeout: fallbackGrace)
        if let newPID = grace.pid {
            return outcome(.sigterm, oldPID: oldPID, newPID: newPID,
                           started: started, spacingWait: spacingWait,
                           probeTimeline: grace.probeTimeline,
                           polls: grace.polls, longestGapMS: grace.longestGapMS)
        }
        process.kickstart()
        let kicked = await waitForRestart(after: dyingPID)
        if let newPID = kicked.pid {
            return outcome(.kickstart, oldPID: oldPID, newPID: newPID,
                           started: started, spacingWait: spacingWait,
                           probeTimeline: kicked.probeTimeline,
                           polls: kicked.polls, longestGapMS: kicked.longestGapMS)
        }

        return ReloadOutcome(method: .failed, oldPID: oldPID, newPID: nil,
                             elapsed: Date().timeIntervalSince(started),
                             spacingWait: spacingWait,
                             probeTimeline: kicked.probeTimeline,
                             waitPolls: kicked.polls, waitLongestGapMS: kicked.longestGapMS)
    }

    /// 退出流程专用的重启：**只发一发信号，最多看它一眼，绝不升级**。
    ///
    /// 为什么不能复用 `reload()`：那条路是"发信号 → 等归位（30 s）→ 升级到 SIGTERM →
    /// 再 `kickstart` → 再等 30 s"。真机 2026-09-19 那天 launchd 处在递增退避里，
    /// 退出还原照这条走完就是 **53–54 秒**（用户看到的"退出时卡住、没有 Dock"）。
    /// 而退出场景里等归位**换不到任何东西**：
    /// - 偏好是原子写到 `com.apple.dock` 域里的，我们走了之后它还在；
    /// - Dock 每次启动都重读这个域 —— launchd 把它拉回来那一刻，读到的就是基准；
    /// - 唯一能纠正"升级也没用"的手段是**下次启动的自检**，而它不看这次等了多久。
    ///
    /// 所以这里只做三件事：发一发信号、最多等 `deadline` 看一眼、把结论如实带回去。
    /// **不等节流**（`minimumSpacing`）：那最多 1 秒的等待只为了让 Dock 少闪一下，
    /// 而我们正要离开，用户看不到；**不 `kickstart`**：Dock 不在时 launchd 自己会拉，
    /// 我们插一发只会加深退避。
    func reloadForQuit(
        strategy: ReloadStrategy = .auto,
        deadline: Duration = .milliseconds(1500)
    ) async -> QuitRestart {
        guard let oldPID = process.dockPID(), oldPID > 0 else { return .dockWasDown }
        let started = Date()
        guard process.signal(oldPID, strategy == .sigterm ? SIGTERM : SIGHUP) else {
            return .notDelivered(oldPID: oldPID)
        }
        // 退出路径刻意**不带取证**：`deadline` 只有 1.5 秒，而取证要等 1 秒才开始，
        // 采到的样本没有诊断价值（这条路的耗时早已被实验 10 定案）。时间线丢弃即可。
        if let newPID = await waitForRestart(after: oldPID, timeout: deadline).pid {
            return .revived(oldPID: oldPID, newPID: newPID, elapsed: Date().timeIntervalSince(started))
        }
        return .signaled(oldPID: oldPID)
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

    /// 一次「等 Dock 归位」的产物。
    private struct RestartWait {
        /// 看到的新 Dock PID；超时未归位为 nil。
        var pid: pid_t?
        /// 慢重启的取证时间线。正常路径为空数组。见 `ReloadOutcome.probeTimeline`。
        var probeTimeline: [String] = []
        /// 实际跑了几轮轮询。见 `ReloadOutcome.waitPolls`。
        var polls: Int = 0
        /// 最长的一次轮询间隔（ms）。见 `ReloadOutcome.waitLongestGapMS`。
        var longestGapMS: Int = 0
    }

    /// 轮询等待一个**不同于** `oldPID` 的 Dock 进程出现。
    ///
    /// 只接受**正数** PID：`NSRunningApplication` 在 Dock 重启窗口里会返回 -1，
    /// 若把它当成"新 Dock 回来了"，`ReloadOutcome` 会谎报成功（Dock 其实还没回来）。
    /// `RealDockProcessControl` 里已有一道闸门，这里是第二道 —— 两层都便宜，都留着。
    ///
    /// 等待超过 `slowProbeThreshold` 之后开始**取证**：每 `probeInterval` 问一次
    /// `pidProbe()`，只在**答案变化**时记一条（外加首尾各一条）。这样一次 30 秒的慢重启
    /// 通常只留 2–4 条，但足以定案「慢在探测还是慢在 launchd 拉起」。
    private func waitForRestart(after oldPID: pid_t, timeout: Duration? = nil) async -> RestartWait {
        let start = ContinuousClock.now
        let deadline = start + (timeout ?? self.timeout)
        let probeFrom = start + slowProbeThreshold
        var timeline: [String] = []
        var lastProbe: DockPIDProbe?
        var nextProbeAt = probeFrom
        // 存活性：轮询次数 + 最长一次间隔。用来区分「Dock 真的不在」与「我们没在看」。
        // 两个计数器都只是整数运算，正常路径（几轮）的开销可忽略。
        var polls = 0
        var lastIteration = start
        var longestGap = Duration.zero

        /// 记一条。`force` 为真时无视"答案没变"也记（用于首尾两条）。
        func sample(at instant: ContinuousClock.Instant, force: Bool) {
            guard instant >= probeFrom, timeline.count < probeSampleCap else { return }
            guard let probe = process.pidProbe() else { return }
            guard force || probe != lastProbe else { return }
            let ms = Int((Self.seconds(start.duration(to: instant)) * 1000).rounded())
            timeline.append("\(ms)ms \(probe.summary)")
            lastProbe = probe
        }

        while ContinuousClock.now < deadline {
            let now = ContinuousClock.now
            polls += 1
            let gap = lastIteration.duration(to: now)
            if gap > longestGap { longestGap = gap }
            lastIteration = now
            if let pid = process.dockPID(), pid > 0, pid != oldPID {
                lastRestartAt = now
                // 只在"已经慢过"的这次才补一条收尾记录，正常路径不产生任何开销。
                if !timeline.isEmpty { sample(at: now, force: true) }
                return RestartWait(pid: pid, probeTimeline: timeline,
                                   polls: polls, longestGapMS: Self.milliseconds(longestGap))
            }
            if now >= nextProbeAt {
                sample(at: now, force: false)
                nextProbeAt = now + probeInterval
            }
            try? await Task.sleep(for: pollInterval)
        }
        // 超时也要留一条收尾记录 —— "一直没归位"本身是最重要的结论。
        if !timeline.isEmpty { sample(at: ContinuousClock.now, force: true) }
        return RestartWait(pid: nil, probeTimeline: timeline,
                           polls: polls, longestGapMS: Self.milliseconds(longestGap))
    }

    /// `Duration` → 毫秒（四舍五入）。
    private static func milliseconds(_ duration: Duration) -> Int {
        Int((seconds(duration) * 1000).rounded())
    }

    private func outcome(
        _ method: ReloadOutcome.Method,
        oldPID: pid_t,
        newPID: pid_t,
        started: Date,
        spacingWait: TimeInterval,
        probeTimeline: [String] = [],
        polls: Int = 0,
        longestGapMS: Int = 0
    ) -> ReloadOutcome {
        ReloadOutcome(method: method, oldPID: oldPID, newPID: newPID,
                      elapsed: Date().timeIntervalSince(started), spacingWait: spacingWait,
                      probeTimeline: probeTimeline,
                      waitPolls: polls, waitLongestGapMS: longestGapMS)
    }
}

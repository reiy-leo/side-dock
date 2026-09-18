import Foundation
@testable import MultiDock

/// 测试替身与夹具。`DockControllerTests` 与 `DockReloaderTests` 共用。

/// 变长盒子：闭包里要写可变状态，Swift 6 的严格并发下不能直接捕获局部 `var`。
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// 模拟 `com.apple.dock` 偏好域。
///
/// 刻意照抄 `DockPreferences.writeWhitelisted` 的「只覆盖白名单键」语义 ——
/// 白名单本身的语义由 `DockPreferencesTests` 负责，这里只让调用方观察
/// 「写了几次、写了哪些键、域变成什么样」。
///
/// 放在 `TestSupport` 而不是某个测试类内部：`AppStateDockTests` 与
/// `StartupSelfHealTests` 都要用它，各写一份迟早会不一致。
final class FakePreferences: DockPreferenceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var domain: [String: PlistValue]
    private var writes = 0
    private var history: [[String: PlistValue]] = []
    private var mruWriteCount = 0
    /// 与 `FakeSpaceProvider` 共用的顺序记录，用来断言"预应用先于切换"。
    var events: Box<[String]>?

    init(domain: [String: PlistValue], events: Box<[String]>? = nil) {
        self.domain = domain
        self.events = events
    }

    func readDomain() -> [String: PlistValue] { lock.withLock { domain } }

    @discardableResult
    func writeWhitelisted(_ entries: [String: PlistValue]) -> Int {
        let count = lock.withLock {
            writes += 1
            history.append(entries)
            for (key, value) in entries where DockPreferences.whitelistedKeys.contains(key) {
                domain[key] = value
            }
            return entries.count
        }
        events?.value.append("write")
        return count
    }

    /// `mru-spaces` 是白名单之外的唯一例外，替身里照样只改这一个键。
    @discardableResult
    func writeMRUSpaces(_ enabled: Bool) -> Bool {
        lock.withLock {
            mruWriteCount += 1
            domain[DockPreferences.mruSpacesKey] = .bool(enabled)
        }
        return true
    }

    var writeCount: Int { lock.withLock { writes } }
    var lastEntries: [String: PlistValue]? { lock.withLock { history.last } }
    var mruWrites: Int { lock.withLock { mruWriteCount } }
    /// 当前域的快照，用来断言"到底写进去了什么"。
    var snapshot: [String: PlistValue] { lock.withLock { domain } }
}

/// 模拟 Dock 进程。
///
/// 关键能力是「哪些信号能让 Dock 回来」——用它可以精确构造 P0 实测里的两条路径
/// （SIGHUP 成功 / SIGHUP 失败后走 SIGTERM + kickstart）。
final class FakeDockProcess: DockProcessControlling, @unchecked Sendable {

    private let lock = NSLock()
    private var pid: pid_t?
    private var nextPID: pid_t = 1000
    private var restartsOn: Set<Int32>
    private var kickstartRestarts: Bool
    /// 收到信号后，还要被 `dockPID()` 问几次才返回新 PID。用来模拟"重启要花点时间"。
    private var restartDelayPolls: Int

    private var restartPending = false
    private var countdown = 0
    private var signalsSent: [(pid: pid_t, sig: Int32)] = []
    private var kickstarts = 0
    /// 替身"报告"的 Dock 启动时刻。nil = 报告不出来（`DockReloader` 会退回用内存里的记忆）。
    private var reportedStartTime: TimeInterval?

    init(
        pid: pid_t? = 100,
        restartsOn: Set<Int32> = [SIGHUP],
        kickstartRestarts: Bool = true,
        restartDelayPolls: Int = 0,
        startTime: TimeInterval? = nil
    ) {
        self.pid = pid
        self.restartsOn = restartsOn
        self.kickstartRestarts = kickstartRestarts
        self.restartDelayPolls = restartDelayPolls
        self.reportedStartTime = startTime
    }

    /// 改掉"报告"的启动时刻。用来构造「内存里记着刚重启过、但真实 Dock 已经跑了很久」这类场景。
    func reportStartTime(_ time: TimeInterval?) {
        lock.withLock { reportedStartTime = time }
    }

    /// 覆盖协议默认实现（默认返回 nil = 拿不到启动时刻）。
    func startTime(of pid: pid_t) -> TimeInterval? {
        lock.withLock { reportedStartTime }
    }

    func dockPID() -> pid_t? {
        lock.withLock {
            guard let current = pid else { return nil }
            guard restartPending else { return current }
            if countdown > 0 {
                countdown -= 1
                return current
            }
            restartPending = false
            nextPID += 1
            pid = nextPID
            return nextPID
        }
    }

    @discardableResult
    func signal(_ pid: pid_t, _ sig: Int32) -> Bool {
        lock.withLock {
            signalsSent.append((pid, sig))
            guard restartsOn.contains(sig) else { return true }
            restartPending = true
            countdown = restartDelayPolls
            return true
        }
    }

    @discardableResult
    func kickstart() -> Bool {
        lock.withLock {
            kickstarts += 1
            guard kickstartRestarts else { return true }
            restartPending = true
            countdown = 0
            return true
        }
    }

    var signals: [Int32] { lock.withLock { signalsSent.map(\.sig) } }
    var kickstartCount: Int { lock.withLock { kickstarts } }
}

/// 可编程的假空间提供者。
///
/// 存在的意义：`AppState.switchToNextDesktop` 要求**先预应用 Dock、再切空间**，
/// 这个顺序只能靠假提供者把 `setCurrentSpace` 记进事件流来断言（见 `AppStateDockTests`）。
final class FakeSpaceProvider: SpaceProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var desktops: [DesktopSpace]
    private var activeID: UInt64
    private var switches: [UInt64] = []
    private var switchesSucceed: Bool
    /// 与 `FakePreferences` 共用的顺序记录，用来断言"预应用先于切换"。
    var events: Box<[String]>?

    let isAvailable: Bool
    let unavailableReason: String?

    init(
        desktops: [DesktopSpace] = [],
        activeSpaceID: UInt64 = 0,
        isAvailable: Bool = true,
        reason: String? = nil,
        switchesSucceed: Bool = true,
        events: Box<[String]>? = nil
    ) {
        self.desktops = desktops
        self.activeID = activeSpaceID
        self.isAvailable = isAvailable
        self.unavailableReason = reason
        self.switchesSucceed = switchesSucceed
        self.events = events
    }

    func userDesktops() -> [DesktopSpace] { lock.withLock { desktops } }

    func activeSpaceID() -> UInt64 { lock.withLock { activeID } }

    @discardableResult
    func setCurrentSpace(_ space: DesktopSpace) -> Bool {
        let accepted = lock.withLock {
            guard switchesSucceed else { return false }
            switches.append(space.id64)
            activeID = space.id64
            return true
        }
        guard accepted else { return false }
        events?.value.append("switch:\(space.id64)")
        return true
    }

    /// 被切到过的桌面 id64 序列。
    var switchTargets: [UInt64] { lock.withLock { switches } }

    func setDesktops(_ list: [DesktopSpace]) { lock.withLock { desktops = list } }

    /// 造一批同一显示器上的用户桌面，序号从 1 起。
    static func desktops(
        count: Int,
        displayUUID: String = "DISP-1",
        baseID: UInt64 = 100
    ) -> [DesktopSpace] {
        (1...count).map { index in
            DesktopSpace(
                displayUUID: displayUUID,
                spaceUUID: "SPACE-\(index)",
                id64: baseID + UInt64(index),
                type: 0,
                ordinal: index
            )
        }
    }
}

/// 测试专用的日志落盘出口。**构造 `AppState` 时必须传它**。
///
/// 默认的 `FileLogSink` 写 `~/Library/Application Support/MultiDock/multidock.log`，
/// 而那份日志是用户核对真机行为的**唯一**凭据（本机无屏幕录制权限、`log show` 在沙箱里读不到）。
/// 不换掉它，一次 `swift test` 就会往里灌几千行假记录（假 PID `100 → 1001`、假的"退出还原"），
/// 把「连切十次看 `Dock 不可用` 是否回到 100 ms 量级」这类核对整个污染掉。
func makeTestFileLog() -> FileLogSink {
    FileLogSink(
        fileURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-testlog-\(UUID().uuidString).log")
    )
}

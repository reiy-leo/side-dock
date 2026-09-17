import Foundation
@testable import MultiDock

/// 测试替身与夹具。`DockControllerTests` 与 `DockReloaderTests` 共用。

/// 变长盒子：闭包里要写可变状态，Swift 6 的严格并发下不能直接捕获局部 `var`。
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
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

    init(
        pid: pid_t? = 100,
        restartsOn: Set<Int32> = [SIGHUP],
        kickstartRestarts: Bool = true,
        restartDelayPolls: Int = 0
    ) {
        self.pid = pid
        self.restartsOn = restartsOn
        self.kickstartRestarts = kickstartRestarts
        self.restartDelayPolls = restartDelayPolls
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

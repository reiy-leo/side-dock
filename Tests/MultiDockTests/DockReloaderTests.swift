import XCTest
@testable import MultiDock

/// Dock 重载策略。对应 `docs/PLAN.md` §3.5 与 `docs/spikes.md` 的 P0 结论。
///
/// 这里钉死的是**顺序**：SIGHUP 优先 → 失败才 SIGTERM → 再失败才 `launchctl kickstart`。
/// 真正"这台上多久恢复"只能实测（P0 已测得 101 ms / 395 ms）。
@MainActor
final class DockReloaderTests: XCTestCase {

    private func makeReloader(_ process: FakeDockProcess) -> DockReloader {
        DockReloader(
            process: process,
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(2),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .zero   // 测试不睡那 1 秒节流窗口
        )
    }

    func testAutoStrategyUsesSighupFirst() async {
        let process = FakeDockProcess(pid: 100, restartsOn: [SIGHUP])
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .sighup)
        XCTAssertEqual(process.signals, [SIGHUP], "主路径必须是 SIGHUP，且只发一次")
        XCTAssertEqual(process.kickstartCount, 0)
        XCTAssertEqual(outcome.oldPID, 100)
        XCTAssertNotNil(outcome.newPID)
        XCTAssertTrue(outcome.succeeded)
    }

    func testNeverUsesSigtermWhenSighupWorks() async {
        // 回归护栏：SIGTERM 会让 Dock 做约 255 ms 清理（总不可用约 395 ms），
        // 比 SIGHUP 慢 4 倍。SIGHUP 有效时绝不能发 SIGTERM。
        let process = FakeDockProcess(restartsOn: [SIGHUP, SIGTERM])
        _ = await makeReloader(process).reload(strategy: .auto)

        XCTAssertFalse(process.signals.contains(SIGTERM))
    }

    func testFallsBackToSigtermThenKickstart() async {
        // SIGHUP 不生效（模拟 Dock 卡住），SIGTERM 也不生效，最后靠 launchd 拉回。
        let process = FakeDockProcess(restartsOn: [], kickstartRestarts: true)
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertEqual(process.signals.first, SIGHUP, "先试主路径")
        XCTAssertTrue(process.signals.contains(SIGTERM), "主路径失败要补 SIGTERM")
        XCTAssertEqual(process.kickstartCount, 1, "最后才动 launchctl")
        XCTAssertEqual(outcome.method, .kickstart)
        XCTAssertTrue(outcome.succeeded)
    }

    func testStopsAtSigtermWhenItWorks() async {
        // SIGHUP 无效、SIGTERM 有效 → 不该再多此一举 kickstart。
        let process = FakeDockProcess(restartsOn: [SIGTERM])
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .sigterm)
        XCTAssertEqual(process.kickstartCount, 0)
    }

    func testSigtermStrategySkipsSighupEntirely() async {
        let process = FakeDockProcess(restartsOn: [SIGHUP, SIGTERM])
        let outcome = await makeReloader(process).reload(strategy: .sigterm)

        XCTAssertEqual(outcome.method, .sigterm)
        XCTAssertEqual(process.signals, [SIGTERM], "用户选了 SIGTERM 就别再试 SIGHUP")
    }

    func testFailsWhenDockIsNotRunning() async {
        let process = FakeDockProcess(pid: nil)
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .failed)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(process.signals.isEmpty, "没有 Dock 进程就没得发信号")
        XCTAssertEqual(process.kickstartCount, 0)
    }

    func testIsDockAliveReflectsTheProcessControl() {
        // `DockWatcher` 的回存闸门靠它：Dock 不在时读偏好域会读到残缺内容。
        // 这里只问存活，不重启，所以用默认构造（不会睡那 1 秒节流窗口）。
        XCTAssertTrue(DockReloader(process: FakeDockProcess(pid: 100, restartsOn: [SIGHUP])).isDockAlive)
        XCTAssertFalse(DockReloader(process: FakeDockProcess(pid: nil)).isDockAlive)

        // -1 是"正在退出"的谎报值（见 §4 的 PID 陷阱），不能算活着。
        XCTAssertFalse(DockReloader(process: LyingProcess(pid: -1, lies: .max)).isDockAlive,
                       "-1 不是有效的 Dock 进程")
    }

    func testReportsFailureWhenDockNeverComesBack() async {
        let process = FakeDockProcess(restartsOn: [], kickstartRestarts: false)
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .failed)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertNil(outcome.newPID)
        XCTAssertTrue(outcome.description.contains("失败"))
        XCTAssertGreaterThan(outcome.elapsed, 0)
    }

    func testWaitsForANewPIDNotJustAPID() async {
        // 关键：判据是"PID 变了"，不是"Dock 还在"。只看存在性会把还没重启完的旧进程
        // 当成重启成功，于是新配置根本没被读进去。
        let process = FakeDockProcess(pid: 100, restartsOn: [SIGHUP], restartDelayPolls: 5)
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .sighup)
        XCTAssertEqual(outcome.oldPID, 100)
        XCTAssertNotEqual(outcome.newPID, 100, "拿到的必须是新 PID")
    }

    func testOutcomeDescriptionIncludesPIDAndDuration() async {
        let process = FakeDockProcess(pid: 4242, restartsOn: [SIGHUP])
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertTrue(outcome.description.contains("4242"))
        XCTAssertTrue(outcome.description.contains("ms"), "日志里要有耗时，P2 验收靠它")
    }

    func testReloadIsIdempotentAcrossRepeatedCalls() async {
        let process = FakeDockProcess(restartsOn: [SIGHUP])
        let reloader = makeReloader(process)

        let first = await reloader.reload(strategy: .auto)
        let second = await reloader.reload(strategy: .auto)

        XCTAssertEqual(first.method, .sighup)
        XCTAssertEqual(second.method, .sighup)
        XCTAssertNotEqual(first.newPID, second.newPID, "每次都要真的换一个进程")
    }

    // MARK: - 非正数 PID 不能被当成"新 Dock 回来了"

    /// 谎报 -1 的替身：Dock 重启窗口里 `NSRunningApplication` 真的会返回 `processIdentifier == -1`。
    ///
    /// 如果 `waitForRestart` 把 -1 当成新 PID，`ReloadOutcome` 就会**谎报成功**
    /// （实际 Dock 还没回来），调用方会以为可以继续；更糟的是这个 -1 会被传进
    /// `signal(_:_:)`，而 `kill(-1, sig)` 是"发给当前用户的全部进程"。
    private final class LyingProcess: DockProcessControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var lies: Int
        private var pid: pid_t
        private var nextPID: pid_t
        private var seenFirstCall = false

        init(pid: pid_t = 100, lies: Int = 2) {
            self.pid = pid
            self.nextPID = pid
            self.lies = lies
        }

        func dockPID() -> pid_t? {
            lock.withLock {
                // 第一次调用是 reload() 开头取 oldPID，必须给真值。
                guard seenFirstCall else {
                    seenFirstCall = true
                    return pid
                }
                if lies > 0 {
                    lies -= 1
                    return -1
                }
                nextPID += 1
                return nextPID
            }
        }

        @discardableResult func signal(_ pid: pid_t, _ sig: Int32) -> Bool { true }
        @discardableResult func kickstart() -> Bool { true }
    }

    func testReloaderSkipsNegativePIDAndFindsTheRealRestart() async {
        let process = LyingProcess(pid: 100, lies: 2)
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(300),
            pollInterval: .milliseconds(2),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .zero   // 测试不睡那 1 秒节流窗口
        )

        let outcome = await reloader.reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .sighup, "谎报的 -1 不该让我们掉进兜底路径")
        XCTAssertEqual(outcome.newPID, 101, "应当跳过 -1，等到真正的 101")
        XCTAssertGreaterThan(outcome.newPID ?? -1, 0)
        XCTAssertTrue(outcome.succeeded)
    }

    func testReloaderFailsRatherThanAcceptingNegativePIDForever() async {
        // 一直谎报 -1 → 必须报失败，绝不能拿 -1 当成功。
        let process = LyingProcess(pid: 100, lies: .max)
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(120),
            pollInterval: .milliseconds(2),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .zero   // 测试不睡那 1 秒节流窗口
        )

        let outcome = await reloader.reload(strategy: .auto)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertNil(outcome.newPID)
        XCTAssertEqual(outcome.method, .failed)
    }

    // MARK: - 重启节流（`docs/spikes.md` 实验 5）

    func testSecondReloadWaitsOutTheThrottleWindow() async {
        // 实测：两次重启间隔 < 1 s 时 Dock 要等约 1070 ms 才归位，间隔 ≥ 1 s 时只要约 70 ms。
        // 所以第二次重启必须先等满窗口 —— 等待期间 Dock 还是可用的。
        let process = FakeDockProcess(restartsOn: [SIGHUP])
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(2),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .milliseconds(120)
        )

        let first = await reloader.reload(strategy: .auto)
        XCTAssertEqual(first.spacingWait, 0, "第一次没有上一次可错开，不该等")

        let started = Date()
        let second = await reloader.reload(strategy: .auto)
        let wallClock = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(second.spacingWait, 0.05, "第二次必须等掉剩下的节流窗口")
        XCTAssertGreaterThan(wallClock, 0.1)
        // 关键：等待时间**不算进 Dock 不可用时长**，否则日志会吓人。
        XCTAssertLessThan(second.elapsed, second.spacingWait,
                          "elapsed 只该含 Dock 真正不可用的时间")
        XCTAssertTrue(second.description.contains("期间 Dock 可用"),
                      "日志要说清这段等待里 Dock 是可用的：\(second.description)")
    }

    func testFirstReloadNeverWaits() async {
        let process = FakeDockProcess(restartsOn: [SIGHUP])
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(2),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .seconds(30)   // 故意设得极大：第一次也必须立刻走
        )

        let started = Date()
        let outcome = await reloader.reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .sighup)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "第一次重启不该等节流窗口")
        XCTAssertEqual(outcome.spacingWait, 0)
    }

    func testFailedReloadDoesNotArmTheThrottleWindow() async {
        // 重启失败时没有"新 Dock 归位"的时刻，所以不该记窗口 ——
        // 否则下一次重试会被毫无理由地推迟。
        let process = FakeDockProcess(restartsOn: [], kickstartRestarts: false)
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(80),
            pollInterval: .milliseconds(2),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .milliseconds(200)
        )

        let startedFirst = Date()
        let first = await reloader.reload(strategy: .auto)
        let firstWall = Date().timeIntervalSince(startedFirst)
        XCTAssertFalse(first.succeeded)

        let started = Date()
        let second = await reloader.reload(strategy: .auto)
        let secondWall = Date().timeIntervalSince(started)

        XCTAssertFalse(second.succeeded)
        XCTAssertEqual(second.spacingWait, 0, "上次没成功归位就不该等")
        // 失败路径本身要花时间（SIGHUP 超时 + 宽限 + kickstart 超时），所以不能设死上限，
        // 只能要求"第二次没有比第一次多出一个节流窗口"。
        XCTAssertLessThan(secondWall, firstWall + 0.1,
                          "第二次多等了：第一次 \(Int(firstWall * 1000)) ms，第二次 \(Int(secondWall * 1000)) ms")
    }

    // MARK: - 节流窗口按 **Dock 进程年龄** 算（P4 验收踩出来的回归）

    /// 回归护栏，来自一次真实验收失败：
    ///
    /// P4 验收里前一条用例刚重启完 Dock，紧接着 P3 用例**新建了一个 `DockReloader`**
    /// （`lastRestartAt` 为 nil，它以为自己从没重启过），于是第一次重启直接被 launchd
    /// 节流到 **1030 ms** —— Dock 当着用户的面消失了一秒多。
    ///
    /// 教训：launchd 的节流是**按服务**算的，与我们记不记得自己重启过无关。
    /// 判据必须落在 Dock 进程的真实年龄上。这条测试用一个"刚起来 50 ms"的替身来钉住它。
    func testFreshReloaderStillWaitsWhenTheDockIsYoung() async {
        let process = FakeDockProcess(
            restartsOn: [SIGHUP],
            startTime: Date().timeIntervalSince1970 - 0.05
        )
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(2),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .milliseconds(300)
        )

        let outcome = await reloader.reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .sighup)
        XCTAssertGreaterThan(
            outcome.spacingWait, 0.15,
            "Dock 才起来 50 ms，必须等掉剩下的约 250 ms；实际只等了 \(Int(outcome.spacingWait * 1000)) ms"
        )
    }

    func testOldDockIsNotWaitedFor() async {
        // Dock 已经跑了 10 分钟 → 早就过了节流窗口，一次都不该等。
        let process = FakeDockProcess(
            restartsOn: [SIGHUP],
            startTime: Date().timeIntervalSince1970 - 600
        )
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(2),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .milliseconds(300)
        )

        let outcome = await reloader.reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .sighup)
        XCTAssertEqual(outcome.spacingWait, 0)
    }

    func testProcessAgeWinsOverStaleInMemoryWindow() async {
        // 内存里记着"刚重启过"（第一次是我们自己重启的），但真实 Dock 已经跑了 10 分钟
        // —— 以进程年龄为准，不该再等。这条守的是"别把内存当成事实"。
        let process = FakeDockProcess(
            restartsOn: [SIGHUP],
            startTime: Date().timeIntervalSince1970 - 600
        )
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(2),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .milliseconds(300)
        )

        _ = await reloader.reload(strategy: .auto)
        // 刚归位的 Dock 在内存里把窗口打开了，但替身报告的启动时刻说它早就老了。
        let second = await reloader.reload(strategy: .auto)

        XCTAssertEqual(second.spacingWait, 0,
                       "拿得到进程年龄时，就该以年龄为准，别再等内存里那个窗口")
    }

    func testFallsBackToMemoryWhenProcessAgeIsUnavailable() async {
        // 拿不到启动时刻（替身、跨系统版本结构体变化）→ 退回内存里的 `lastRestartAt`。
        let process = FakeDockProcess(restartsOn: [SIGHUP])   // 不报告启动时刻
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(2),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .milliseconds(120)
        )

        let first = await reloader.reload(strategy: .auto)
        XCTAssertEqual(first.spacingWait, 0)

        let second = await reloader.reload(strategy: .auto)
        XCTAssertGreaterThan(second.spacingWait, 0.05, "拿不到年龄时必须靠内存里的窗口兜住")
    }
}

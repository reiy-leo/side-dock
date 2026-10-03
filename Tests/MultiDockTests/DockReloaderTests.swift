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
            // 这一组测的是「信号策略」本身，不是 A8 的催办。把 `nudgeAfter` 放到 `timeout` 之外，
            // 让「催 kickstart」那条路在这些用例里**不可能**被走到 —— 要测它请用下面专门的用例。
            nudgeAfter: .seconds(60),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .zero,   // 测试不睡那 1 秒节流窗口
            kickstartTimeout: .milliseconds(200)
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
            nudgeAfter: .seconds(60),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .zero,   // 测试不睡那 1 秒节流窗口
            kickstartTimeout: .milliseconds(120)
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
            nudgeAfter: .seconds(60),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .milliseconds(200),
            kickstartTimeout: .milliseconds(80)
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

    // MARK: - 退出流程专用：发一发就走，**绝不升级**

    /// 回归护栏，来自真机 2026-09-19：两次「菜单栏 → 退出」各耗时 **53 与 54 秒**，
    /// 期间没有 Dock、没有壁纸、触控板手势全废（Dock 就是壁纸和空间手势的实现者）。
    /// 根因是退出还原照 `reload()` 走完了一整条降级链：等归位 30 s → SIGTERM → `kickstart`
    /// → 再等 30 s，而 launchd 当时正处在递增退避里。
    ///
    /// 退出时等归位**换不到任何东西**：偏好是原子写进 `com.apple.dock` 域的，
    /// Dock 被 launchd 拉回来那一刻自然会读到基准。所以这里只发一发信号、最多看一眼。

    func testQuitReloadRevivesWithASingleSighup() async {
        let process = FakeDockProcess(pid: 4242, restartsOn: [SIGHUP])
        let result = await makeReloader(process).reloadForQuit()

        XCTAssertEqual(process.signals, [SIGHUP], "只发一发 SIGHUP")
        XCTAssertEqual(process.kickstartCount, 0)
        switch result {
        case let .revived(oldPID, newPID, _):
            XCTAssertEqual(oldPID, 4242)
            XCTAssertNotEqual(oldPID, newPID, "判据仍是「PID 变了」，不是「PID 还在」")
        default:
            XCTFail("替身的 Dock 对 SIGHUP 有反应，应该是 .revived，实得 \(result.description)")
        }
    }

    func testQuitReloadGivesUpWithoutEscalating() async {
        // Dock 对任何信号都不回应（launchd 退避期就是这样）：必须**就此收手**。
        // 升级到 SIGTERM / kickstart 正是把 100 ms 的缺失滚成两分钟的自我放大。
        let process = FakeDockProcess(pid: 100, restartsOn: [], kickstartRestarts: false)
        let started = Date()
        let result = await makeReloader(process).reloadForQuit(deadline: .milliseconds(80))
        let wall = Date().timeIntervalSince(started)

        XCTAssertEqual(process.signals, [SIGHUP], "不能补 SIGTERM")
        XCTAssertEqual(process.kickstartCount, 0, "不能动 launchctl")
        XCTAssertFalse(process.signals.contains(SIGTERM))
        switch result {
        case .signaled(let oldPID): XCTAssertEqual(oldPID, 100)
        default: XCTFail("期限内没归位就该报 .signaled（不是失败），实得 \(result.description)")
        }
        // 「偏好已写回基准」这句话是这条路径的全部依据，必须出现在给用户看的日志里。
        XCTAssertTrue(result.description.contains("基准"), result.description)
        XCTAssertLessThan(wall, 1.0, "等不到也必须立刻返回，把退出拖住就是这次 bug 本身")
    }

    func testQuitReloadIgnoresTheThrottleWindow() async {
        // 节流等待的目的是"少闪一下"。我们正要离开，用户看不到那一下 —— 所以不等。
        let process = FakeDockProcess(restartsOn: [SIGHUP])
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(2),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .seconds(30)   // 故意设得极大
        )

        let started = Date()
        let result = await reloader.reloadForQuit()

        switch result {
        case .revived: break
        default: XCTFail("实得 \(result.description)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "等节流窗口就是把退出拖成几十秒的另一种走法")
    }

    func testQuitReloadWithDockAlreadyDownSendsNothing() async {
        // Dock 本来就不在：发信号没有对象，`kickstart` 更插不得（launchd 自己会拉）。
        // 偏好仍然已经写下去了，所以这**不是失败** —— 只是"我们没看一眼"。
        let process = FakeDockProcess(pid: nil, restartsOn: [SIGHUP])
        let result = await makeReloader(process).reloadForQuit()

        XCTAssertTrue(process.signals.isEmpty, "没有 Dock 进程就没得发信号")
        XCTAssertEqual(process.kickstartCount, 0)
        switch result {
        case .dockWasDown: break
        default: XCTFail("实得 \(result.description)")
        }
    }

    // MARK: - 慢重启取证（A8：Dock 偶发 26–31 秒，见 `docs/spikes.md` 实验 11.6 与实验 15）
    //
    // 这一组钉死的不是"慢重启的成因"（成因还没定案），而是**下一次发生时能不能自证**：
    // 真机日志里只有结果（`Dock 不可用 26046 ms`），没有过程，所以四个假说都能往上套。
    // 取证要能区分两种病因 —— `procScan` 早看到新 PID 而 `launchServices` 没看到（我们的 bug），
    // 还是两条路径都只看到 nil（Dock 真的没回来，launchd 的事）。

    /// 带取证参数的 reloader。`slowProbeThreshold` 压到 20 ms，让"慢"在单测里可复现。
    ///
    /// `nudgeAfter` 默认**关掉**（60 秒）：这一组测的是取证与存活性，不该被"催 kickstart"
    /// 那条路抢先救活。要测催办请显式传一个小值。
    private func makeProbingReloader(
        _ process: FakeDockProcess,
        timeout: Duration = .milliseconds(300),
        pollInterval: Duration = .milliseconds(2),
        nudgeAfter: Duration = .seconds(60),
        nudgeInterval: Duration = .seconds(60),
        kickstartTimeout: Duration = .milliseconds(300),
        slowProbeThreshold: Duration = .milliseconds(20),
        probeInterval: Duration = .milliseconds(5),
        probeSampleCap: Int = 24
    ) -> DockReloader {
        DockReloader(
            process: process,
            timeout: timeout,
            pollInterval: pollInterval,
            nudgeAfter: nudgeAfter,
            nudgeInterval: nudgeInterval,
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .zero,
            kickstartTimeout: kickstartTimeout,
            slowProbeThreshold: slowProbeThreshold,
            probeInterval: probeInterval,
            probeSampleCap: probeSampleCap
        )
    }

    func testFastRestartDoesNotProbeAtAll() async {
        // **零开销护栏**：正常路径只要几十毫秒，绝不能因此多花一次 LaunchServices 查询。
        let process = FakeDockProcess(restartsOn: [SIGHUP])
        process.reportProbe([DockPIDProbe(launchServices: 1, procScan: 1)])

        let outcome = await makeProbingReloader(process).reload(strategy: .auto)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(outcome.probeTimeline.isEmpty, "快路径不该产生取证记录")
        XCTAssertEqual(process.probeCallCount, 0, "快路径一次都不该调用 pidProbe()")
    }

    func testSlowRestartRecordsBothPathsInTheTimeline() async {
        // 慢重启必须回答"慢在探测还是慢在 launchd" → 两条路径的答案都要进日志。
        let process = FakeDockProcess(restartsOn: [SIGHUP], restartDelayPolls: 40)
        process.reportProbe([
            DockPIDProbe(launchServices: 100, procScan: nil),    // 分叉：LS 说旧的还活着，内核表里没有 Dock
            DockPIDProbe(launchServices: 100, procScan: nil),
            DockPIDProbe(launchServices: 1000, procScan: 1000),  // 归位，两条路径一致
        ])

        let outcome = await makeProbingReloader(process).reload(strategy: .auto)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertFalse(outcome.probeTimeline.isEmpty, "慢重启必须留下取证时间线")
        XCTAssertTrue(outcome.probeTimeline.contains { $0.contains("LS=100 scan=nil") },
                      "两条路径的答案都要记：\(outcome.probeTimeline)")
        XCTAssertTrue(outcome.description.contains("慢重启取证："),
                      "时间线要挂在日志那一句里：\(outcome.description)")
        XCTAssertGreaterThan(process.probeCallCount, 0)
    }

    func testTimelineRecordsOnlyChangesPlusEndpoints() async {
        // 10 Hz × 30 秒 = 300 条会把日志灌爆。答案没变就不记。
        let process = FakeDockProcess(restartsOn: [SIGHUP], restartDelayPolls: 40)
        process.reportProbe([DockPIDProbe(launchServices: nil, procScan: nil)])

        let outcome = await makeProbingReloader(process).reload(strategy: .auto)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertLessThanOrEqual(outcome.probeTimeline.count, 2,
                                 "答案没变就不该反复记：\(outcome.probeTimeline)")
    }

    func testTimelineIsCapped() async {
        let process = FakeDockProcess(restartsOn: [SIGHUP], restartDelayPolls: 60)
        process.reportProbe((0..<300).map { DockPIDProbe(launchServices: pid_t($0), procScan: nil) })

        let outcome = await makeProbingReloader(process, probeSampleCap: 5).reload(strategy: .auto)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertLessThanOrEqual(outcome.probeTimeline.count, 5, "取证条数必须封顶")
    }

    func testSlowRestartWithoutProbeSupportStillWorks() async {
        // 协议默认实现返回 nil（老替身、将来别的实现）→ 照常工作，只是不带时间线。
        let process = FakeDockProcess(restartsOn: [SIGHUP], restartDelayPolls: 40)

        let outcome = await makeProbingReloader(process).reload(strategy: .auto)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(outcome.probeTimeline.isEmpty)
        XCTAssertEqual(process.probeCallCount, 0)
    }

    func testFailedSlowRestartStillCarriesTheTimeline() async {
        // 最该有取证的就是"一直没归位"：它直接回答"Dock 到底在不在"。
        let process = FakeDockProcess(restartsOn: [], kickstartRestarts: false)
        process.reportProbe([DockPIDProbe(launchServices: 100, procScan: nil)])

        let outcome = await makeProbingReloader(process).reload(strategy: .auto)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertFalse(outcome.probeTimeline.isEmpty, "超时未归位也要留时间线：\(outcome.description)")
        XCTAssertTrue(outcome.description.contains("慢重启取证："))
    }

    // MARK: - 存活性（"Dock 真的不在" vs "我们没在看"）
    //
    // `elapsed` 是**墙钟**，而轮询循环跑在 `@MainActor` 上。主线程若被别的东西冻住，
    // 我们会**根本没在看**，却照样把这段时间记成"Dock 不可用"—— 两者在旧日志里一模一样
    // （都是 `Dock 不可用 26046 ms`）。所以 outcome 里必须带上**实际跑了几轮、最长间隔多少**。
    //
    // 这条洞是 2026-09-20 复盘真机日志时发现的：那次 26 秒慢重启里，
    // 只有**前 10 秒**有 toast 准时开合可以证明主线程活着，后 16 秒毫无存活性证据。

    func testFastRestartReportsNoLiveness() async {
        // 快路径的日志行必须一个字节都不变 —— 存活性只在慢重启上记。
        let process = FakeDockProcess(restartsOn: [SIGHUP])

        let outcome = await makeProbingReloader(process).reload(strategy: .auto)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertFalse(outcome.description.contains("轮询"), "快路径不该多这一段：\(outcome.description)")
    }

    func testSlowRestartReportsPollCountAndLongestGap() async {
        // 慢重启要能自证"我一直在看"：轮询次数应该接近 elapsed / pollInterval。
        //
        // ⚠️ 这里**故意让 elapsed 真的超过 1 秒**（600 轮 × 2 ms）——
        // 存活性那一段是按 `elapsed > 1` 记的（保证快路径的日志行不变），
        // 用假的短"慢"去测会把闸门绕过去、测不到真东西。
        let process = FakeDockProcess(restartsOn: [SIGHUP], restartDelayPolls: 600)

        let outcome = await makeProbingReloader(process, timeout: .seconds(5)).reload(strategy: .auto)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertGreaterThan(outcome.elapsed, 1, "这条用例的前提就是「真的慢过 1 秒」")
        XCTAssertGreaterThan(outcome.waitPolls, 100, "1 秒多的等待应该跑了几百轮轮询")
        XCTAssertTrue(outcome.description.contains("轮询 \(outcome.waitPolls) 次"),
                      "存活性要挂在日志那一句里：\(outcome.description)")
        XCTAssertGreaterThanOrEqual(outcome.waitLongestGapMS, 0)
    }

    func testStarvedPollLoopIsDistinguishableFromAbsentDock() async {
        // **这条是本组的重点。** 让替身在第 3 次 `dockPID()` 上阻塞 80 ms ——
        // 等价于"轮询循环所在的线程被冻住了"。此时：
        //   - `elapsed` 照样是几十毫秒（墙钟）；
        //   - 但**轮询次数极少**、**最长间隔是几十毫秒**。
        // 真机上如果看到这个形状，就说明"26 秒"里大部分时间是**我们没在看**，不是 Dock 不在。
        let process = FakeDockProcess(restartsOn: [SIGHUP], restartDelayPolls: 40)
        process.stallDockPID(onCall: 3, for: 0.08)

        let outcome = await makeProbingReloader(process).reload(strategy: .auto)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertGreaterThanOrEqual(outcome.waitLongestGapMS, 70,
                                    "阻塞 80 ms 必须体现在最长间隔上：\(outcome.description)")
        // 对照：没有阻塞时最长间隔是个位/十几毫秒（pollInterval 是 2 ms）。
        let healthy = FakeDockProcess(restartsOn: [SIGHUP], restartDelayPolls: 40)
        let healthyOutcome = await makeProbingReloader(healthy).reload(strategy: .auto)
        XCTAssertLessThan(healthyOutcome.waitLongestGapMS, 70,
                          "没被冻住时最长间隔不该接近 80 ms：\(healthyOutcome.description)")
    }

    // MARK: - A8 的正解：**催一发 `kickstart`**（`docs/spikes.md` 实验 16）
    //
    // 真机日志里那两次 26 / 31 秒，关键线索不是"慢"，而是**后面那半截**：
    // `05:33:16` 那次 SIGHUP 等满 30 s 也没等到 Dock，紧接着的一发 `kickstart`
    // **0.5 秒**就把它拉回来了。也就是说 launchd 确实在拖，而 `kickstart` 正是绕过它
    // 重启节流的那条官方通道 —— 干等 30 s 换不到任何东西，只是把用户的缺失坐满。
    //
    // 所以现在：等超过 `nudgeAfter`（生产默认 500 ms）还没见到新 Dock，就催一发。
    // **安全性**：`kickstart`（**不带 `-k`**）在 Dock 已经跑着时是无害的 no-op ——
    // 2026-09-20 真机实测 PID `80643 → 80643` 未变、退出码 0。

    func testSlowRestartIsNudgedWithKickstart() async {
        // 替身要 600 轮（约 1.2 s）才把 Dock 放回来 —— 远超过 nudgeAfter。
        let process = FakeDockProcess(restartsOn: [SIGHUP], restartDelayPolls: 600)

        let outcome = await makeProbingReloader(
            process, timeout: .seconds(5), nudgeAfter: .milliseconds(50)
        ).reload(strategy: .auto)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(process.kickstartCount, 1, "该催、且只催一次（替身第一发就把 Dock 放回来了）")
        XCTAssertLessThan(outcome.elapsed, 0.5,
                          "催办要在几百毫秒内就把 Dock 拉回来，而不是干等满 1.2 s：\(outcome.description)")
        XCTAssertEqual(outcome.method, .sighup, "发出去的仍然是 SIGHUP，催办只是补刀")
        XCTAssertTrue(outcome.probeTimeline.contains { $0.contains("催 kickstart") },
                      "催办必须留痕，否则真机复发时看不出是它救的：\(outcome.probeTimeline)")
    }

    func testNudgeRepeatsWhileTheDockStaysAway() async {
        // ⚠️ **这条守的是"第一发白打了"这个真实窗口。**
        //
        // `nudgeAfter` 到点时 Dock 很可能**还活着**（正在处理 SIGHUP 退出），那一刻的
        // `kickstart` 对 launchd 来说是 no-op。而 A8 要防的恰恰是"launchd 之后不肯再拉它"。
        // 所以催办必须**重复**：`kickstartRestarts: false` 让替身对催办毫无反应，
        // 于是每过一个 `nudgeInterval` 就该再催一发。
        let process = FakeDockProcess(restartsOn: [], kickstartRestarts: false)

        let outcome = await makeProbingReloader(
            process,
            timeout: .milliseconds(500),
            nudgeAfter: .milliseconds(50),
            nudgeInterval: .milliseconds(100)
        ).reload(strategy: .auto)

        XCTAssertFalse(outcome.succeeded, "替身对任何信号都不回应，这条用例的前提")
        XCTAssertGreaterThanOrEqual(process.kickstartCount, 3,
                                    "500 ms 的等待里（50 ms 起、每 100 ms 一发）该催 4 发左右")
        XCTAssertTrue(outcome.probeTimeline.contains { $0.contains("催 kickstart #3") },
                      "每一发都要留痕并编号：\(outcome.probeTimeline)")
    }

    func testFastRestartIsNeverNudged() async {
        // **零开销护栏**：正常路径几十毫秒就回来了，绝不能因此白起一个 `launchctl` 进程。
        // `nudgeAfter` 压到 1 ms 让这条护栏最敏感 —— 而判定顺序是"先看新 PID、再考虑催"，
        // 所以快路径永远走不到催办那一步。
        let process = FakeDockProcess(restartsOn: [SIGHUP])

        let outcome = await makeProbingReloader(process, nudgeAfter: .milliseconds(1))
            .reload(strategy: .auto)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(process.kickstartCount, 0, "快路径一次都不该催")
        XCTAssertTrue(outcome.probeTimeline.isEmpty, "快路径也不该留催办记录")
    }

    func testNudgeDoesNotFireWhenTheDockReturnsFirst() async {
        // 替身 20 ms 就归位，`nudgeAfter` 设 200 ms → 催办来不及开口。
        let process = FakeDockProcess(restartsOn: [SIGHUP], restartDelayPolls: 10)

        let outcome = await makeProbingReloader(process, nudgeAfter: .milliseconds(200))
            .reload(strategy: .auto)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(process.kickstartCount, 0)
    }

    func testProductionDefaultsNudgeEarlyEnough() async {
        // 上面几条都传了自定义 `nudgeAfter`，所以还得有一条**钉住生产默认值**的用例：
        // 默认值被悄悄调大（或 `timeout` 被调小到催办之前）时，这里必须炸。
        // 生产默认 `pollInterval` 是 15 ms，所以 60 轮 ≈ 900 ms 的慢重启。
        let process = FakeDockProcess(restartsOn: [SIGHUP], restartDelayPolls: 60)

        let started = Date()
        let outcome = await DockReloader(process: process, minimumSpacing: .zero)
            .reload(strategy: .auto)
        let wall = Date().timeIntervalSince(started)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(process.kickstartCount, 1, "默认配置下就该催一发")
        XCTAssertLessThan(wall, 0.8,
                          "默认 nudgeAfter 是 500 ms，900 ms 的慢重启该在 500 ms 出头就结束：\(wall) s")
    }

    func testFallbackNeverSignalsAFreshlyRestartedDock() async {
        // ⚠️ **回归护栏。** 兜底路径原本写的是 `let dyingPID = process.dockPID() ?? oldPID`
        // 再对 `dyingPID` 发 SIGTERM —— 万一 launchd 恰好在超时前后把 Dock 拉回来了，
        // `dockPID()` 读到的就是**新** PID，那一发 SIGTERM 会把刚恢复的 Dock 再杀一次。
        // 超时从 30 s 缩到 3 s 之后这个窗口反而更容易撞上，所以必须挡住。
        //
        // 构造：`timeout: .zero` 让主路径一轮都不轮询就超时；替身 `restartDelayPolls: 0`
        // 表示"收到信号后立刻归位"，于是兜底的第一眼 `dockPID()` 就看到了**新** PID。
        // 这正是要防的那个瞬间。
        let process = FakeDockProcess(pid: 100, restartsOn: [SIGHUP], restartDelayPolls: 0)

        let reloader = DockReloader(
            process: process,
            timeout: .zero,
            pollInterval: .milliseconds(2),
            nudgeAfter: .seconds(60),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .zero,
            kickstartTimeout: .milliseconds(50)
        )
        let outcome = await reloader.reload(strategy: .auto)

        XCTAssertTrue(outcome.succeeded, "Dock 已经回来了，就该当成功：\(outcome.description)")
        XCTAssertEqual(outcome.newPID, 1001)
        XCTAssertEqual(process.signals, [SIGHUP],
                       "只该有主路径那一发 SIGHUP；对刚归位的 Dock 补 SIGTERM 会把它再杀一次")
        XCTAssertFalse(process.signals.contains(SIGTERM))
        XCTAssertEqual(process.kickstartCount, 0, "Dock 已经回来了，不该再催")
    }
}

extension DockReloaderTests {
    // MARK: - 自动隐藏三明治（实验 20，`docs/spikes.md`）

    /// 三明治的时序契约：hide 在发信号之前、reveal 在新 PID 归位之后，
    /// 结束态是调用方要的可见性（false），且 Outcome 记下 `hiddenRestart`。
    func testSandwichHidesBeforeSignalAndRevealsAfterNewPID() async {
        let events = Box<[String]>([])
        let process = EventRecordingProcess(FakeDockProcess(pid: 100, restartsOn: [SIGHUP]), events: events)
        let autoHide = FakeAutoHide(startingOn: false, events: events)
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(2),
            nudgeAfter: .seconds(60),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .zero,
            kickstartTimeout: .milliseconds(200),
            autoHide: autoHide
        )

        let outcome = await reloader.reload(strategy: .auto, sandwichRevealAutoHideTo: false)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(outcome.hiddenRestart, "三明治用过就要记进 Outcome")
        XCTAssertFalse(outcome.revealFailed)
        XCTAssertEqual(events.value, ["hide", "signal", "reveal"], "时序必须是 滑走 → 重启 → 滑回")
        XCTAssertFalse(autoHide.autoHideIsOn(), "结束态 = 调用方要的可见性（可见）")
    }

    /// 重载整体失败（Dock 一直没回来）时 reveal 也必须尝试——失败的兜底路径不能把
    /// Dock 留在隐藏态不管。
    func testSandwichRevealsEvenWhenReloadFails() async {
        let events = Box<[String]>([])
        let process = EventRecordingProcess(FakeDockProcess(restartsOn: [], kickstartRestarts: false), events: events)
        let autoHide = FakeAutoHide(events: events)
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(50),
            pollInterval: .milliseconds(2),
            nudgeAfter: .seconds(60),
            fallbackGrace: .milliseconds(10),
            minimumSpacing: .zero,
            kickstartTimeout: .milliseconds(50),
            autoHide: autoHide
        )

        let outcome = await reloader.reload(strategy: .auto, sandwichRevealAutoHideTo: false)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(events.value.last, "reveal", "失败路径也要尝试滑回")
        XCTAssertTrue(events.value.contains("hide"))
    }

    /// 不传 reveal（= 退出路径 / 配置本就要隐藏 / 能力不可用）时，绝不碰 autohide。
    func testNoSandwichWhenRevealParameterIsNil() async {
        let events = Box<[String]>([])
        let process = EventRecordingProcess(FakeDockProcess(pid: 100, restartsOn: [SIGHUP]), events: events)
        let autoHide = FakeAutoHide(events: events)
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(2),
            nudgeAfter: .seconds(60),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .zero,
            kickstartTimeout: .milliseconds(200),
            autoHide: autoHide
        )

        let outcome = await reloader.reload(strategy: .auto)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(events.value.allSatisfy { $0 == "signal" }, "只该有 signal，没有任何 autohide 调用")
        XCTAssertFalse(outcome.hiddenRestart)
    }

    /// 配置本就要求 Dock 隐藏（reveal = true）时不启用三明治——重启后的 Dock 天然以
    /// 隐藏态出现，不会闪；此时还去 Set(true)/Set(true) 纯属多余。
    func testNoSandwichWhenConfigWantsHiddenDock() async {
        let events = Box<[String]>([])
        let process = EventRecordingProcess(FakeDockProcess(pid: 100, restartsOn: [SIGHUP]), events: events)
        let autoHide = FakeAutoHide(startingOn: true, events: events)
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(2),
            nudgeAfter: .seconds(60),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .zero,
            kickstartTimeout: .milliseconds(200),
            autoHide: autoHide
        )

        let outcome = await reloader.reload(strategy: .auto, sandwichRevealAutoHideTo: true)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(events.value.allSatisfy { $0 == "signal" })
        XCTAssertTrue(autoHide.autoHideIsOn(), "结束态保持隐藏（用户配置如此）")
    }

    /// typed setter 失败（Dock 不认/符号缺失）→ 优雅退回老路径：照常重启，只是会闪。
    func testSandwichFallsBackToPlainRestartWhenHideFails() async {
        let events = Box<[String]>([])
        let process = EventRecordingProcess(FakeDockProcess(pid: 100, restartsOn: [SIGHUP]), events: events)
        let autoHide = FakeAutoHide(startingOn: false, setSucceeds: false, events: events)
        let reloader = DockReloader(
            process: process,
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(2),
            nudgeAfter: .seconds(60),
            fallbackGrace: .milliseconds(20),
            minimumSpacing: .zero,
            kickstartTimeout: .milliseconds(200),
            autoHide: autoHide
        )

        let outcome = await reloader.reload(strategy: .auto, sandwichRevealAutoHideTo: false)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(events.value.filter { $0 == "signal" }.count, 1, "hide 失败也要照常重启（恰好一发信号）")
        XCTAssertFalse(outcome.hiddenRestart)
        XCTAssertTrue(events.value.allSatisfy { $0 == "signal" }, "hide 失败就不会有 reveal")
    }
}

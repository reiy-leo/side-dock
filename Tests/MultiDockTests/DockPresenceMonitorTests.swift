import XCTest
@testable import MultiDock

/// Dock 存活监视：什么时候判定"Dock 不在了"、什么时候动手拉回。
///
/// 全部用替身，不会真的去杀用户的 Dock。真实杀掉 Dock 的那条验收在
/// `DockAcceptanceTests`（需显式开启）。
///
/// 测试里轮询周期设成 60 s 并且**手动调 `tick()`**：这样"第几次轮询判定、第几次拉回"
/// 是确定性的，不受轮询时机影响（与 `DockWatcherTests` 同一套路）。
@MainActor
final class DockPresenceMonitorTests: XCTestCase {

    /// 可以按需让 Dock「消失 / 回来」的替身。
    private final class FlakyDock: DockProcessControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t?
        private var nextPID: pid_t = 5000
        private var kickstarts = 0
        /// kickstart 之后还要被问几次才归位（模拟 launchd 拉起来需要一点时间）。
        private let recoverDelayPolls: Int
        /// false = kickstart 也拉不回来（模拟 launchd 彻底不管了）。
        private var recoversOnKickstart: Bool
        private var countdown = 0
        private var willRecover = false

        init(pid: pid_t? = 400, recoverDelayPolls: Int = 0, recoversOnKickstart: Bool = true) {
            self.pid = pid
            self.recoverDelayPolls = recoverDelayPolls
            self.recoversOnKickstart = recoversOnKickstart
        }

        /// 让 Dock 消失（等价于被 `kill -9`）。
        func vanish() {
            lock.withLock {
                pid = nil
                willRecover = false
                countdown = 0
            }
        }

        /// 改掉「kickstart 到底能不能拉回来」。用来构造「先拉不回来、后来又能拉回来」。
        func setRecoversOnKickstart(_ value: Bool) {
            lock.withLock { recoversOnKickstart = value }
        }

        func dockPID() -> pid_t? {
            lock.withLock {
                if let current = pid { return current }
                guard willRecover else { return nil }
                if countdown > 0 {
                    countdown -= 1
                    return nil
                }
                willRecover = false
                nextPID += 1
                pid = nextPID
                return nextPID
            }
        }

        @discardableResult
        func signal(_ pid: pid_t, _ sig: Int32) -> Bool { true }

        @discardableResult
        func kickstart() -> Bool {
            lock.withLock {
                kickstarts += 1
                willRecover = recoversOnKickstart
                countdown = recoverDelayPolls
                return true
            }
        }

        var kickstartCount: Int { lock.withLock { kickstarts } }
    }

    private func makeMonitor(
        process: FlakyDock,
        missThreshold: Int = 2,
        kickstartEvery: Int = 4,
        persistentFailureThreshold: Int = 12
    ) -> (DockPresenceMonitor, Box<[String]>) {
        let messages = Box<[String]>([])
        let monitor = DockPresenceMonitor(
            process: process,
            pollInterval: .seconds(60),
            missThreshold: missThreshold,
            kickstartEvery: kickstartEvery,
            persistentFailureThreshold: persistentFailureThreshold
        ) { message in
            messages.value.append(message)
        }
        return (monitor, messages)
    }

    func testPresentDockIsNeverTouched() {
        let process = FlakyDock(pid: 400)
        let (monitor, messages) = makeMonitor(process: process)

        for _ in 0..<10 { monitor.tick() }

        XCTAssertEqual(process.kickstartCount, 0, "Dock 在的时候一次都不该拉回")
        XCTAssertEqual(monitor.recoveryCount, 0)
        XCTAssertEqual(monitor.consecutiveMisses, 0)
        XCTAssertEqual(monitor.lastSeenPID, 400)
        XCTAssertTrue(messages.value.isEmpty, "一切正常时不该刷日志：\(messages.value)")
    }

    func testKickstartsOnlyAfterConsecutiveThreshold() {
        let process = FlakyDock(pid: 400)
        let (monitor, _) = makeMonitor(process: process, missThreshold: 3)

        process.vanish()
        monitor.tick()
        monitor.tick()
        XCTAssertEqual(process.kickstartCount, 0, "还没到阈值，不能动手 —— Dock 重启窗口里本来就会查不到一次")
        XCTAssertEqual(monitor.consecutiveMisses, 2)

        monitor.tick()
        XCTAssertEqual(process.kickstartCount, 1, "到阈值了必须动手")
        XCTAssertNil(monitor.lastSeenPID, "从头到尾没见过 Dock，lastSeenPID 该是 nil")
    }

    func testRecoversAndCountsOneRecovery() {
        let process = FlakyDock(pid: 400)
        let (monitor, messages) = makeMonitor(process: process)

        process.vanish()
        monitor.tick()          // 第 1 次缺失
        monitor.tick()          // 到阈值 → kickstart
        monitor.tick()          // Dock 已归位（recoverDelayPolls = 0）

        XCTAssertEqual(monitor.recoveryCount, 1, "恢复只该记一次")
        XCTAssertEqual(monitor.consecutiveMisses, 0)
        XCTAssertEqual(monitor.lastSeenPID, 5001, "归位后要记住新 PID")
        XCTAssertEqual(process.kickstartCount, 1)

        // 之后再 tick 不该重复记恢复。
        monitor.tick()
        monitor.tick()
        XCTAssertEqual(monitor.recoveryCount, 1, "Dock 一直在的时候不该重复记恢复")
        XCTAssertTrue(messages.value.contains { $0.contains("已归位") }, "日志：\(messages.value)")
    }

    func testDoesNotHammerLaunchctl() {
        // 拉不回来时也不能每轮都打 launchctl（那是子进程，一次约 10 ms）。
        let process = FlakyDock(pid: 400, recoversOnKickstart: false)
        let (monitor, _) = makeMonitor(process: process, missThreshold: 2, kickstartEvery: 4)

        process.vanish()
        for _ in 0..<10 { monitor.tick() }

        // 第 2、6、10 次缺失各打一次。
        XCTAssertEqual(process.kickstartCount, 3, "10 轮里只该打 3 次，实际 \(process.kickstartCount)")
        XCTAssertEqual(monitor.consecutiveMisses, 10)
        XCTAssertEqual(monitor.recoveryCount, 0)
    }

    func testWaitsForDockToActuallyComeBack() {
        // launchd 拉起来要几次轮询：中间那几次不算"已恢复"。
        let process = FlakyDock(pid: 400, recoverDelayPolls: 2)
        let (monitor, _) = makeMonitor(process: process)

        process.vanish()
        monitor.tick()      // 缺失 1
        monitor.tick()      // 缺失 2 → kickstart
        monitor.tick()      // countdown 2→1，还没回来
        monitor.tick()      // countdown 1→0，还没回来
        XCTAssertEqual(monitor.recoveryCount, 0, "Dock 还没回来就不该记恢复")

        monitor.tick()      // 这次真的回来了
        XCTAssertEqual(monitor.recoveryCount, 1)
        XCTAssertEqual(monitor.consecutiveMisses, 0)
    }

    func testStartStopTogglesRunningState() {
        let process = FlakyDock(pid: 400)
        let (monitor, _) = makeMonitor(process: process)

        XCTAssertFalse(monitor.isRunning)
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        monitor.start()     // 重复 start 不该起第二个循环
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        monitor.stop()      // 重复 stop 也不该炸
        XCTAssertFalse(monitor.isRunning)
    }

    func testMissingDockAtStartupIsRecovered() {
        // App 启动时 Dock 就已经不在（上一次会话把它弄死了）—— 也要能拉回来。
        let process = FlakyDock(pid: nil)
        let (monitor, _) = makeMonitor(process: process)

        monitor.tick()      // 缺失 1
        monitor.tick()      // 缺失 2 → kickstart
        monitor.tick()      // Dock 归位

        XCTAssertEqual(process.kickstartCount, 1)
        XCTAssertEqual(monitor.recoveryCount, 1)
        XCTAssertNotNil(monitor.lastSeenPID)
    }

    // MARK: - 「拉不回来」要吭声（计划 §3.9 第 3 条）

    func testReportsPersistentFailureOnceAfterThreshold() {
        let process = FlakyDock(pid: 400, recoversOnKickstart: false)
        let (monitor, _) = makeMonitor(process: process, persistentFailureThreshold: 5)

        let reports = Box<[String]>([])
        monitor.onPersistentlyDown = { reports.value.append($0) }

        process.vanish()
        for _ in 0..<4 { monitor.tick() }
        XCTAssertTrue(reports.value.isEmpty, "还没到阈值就不该报警：\(reports.value)")
        XCTAssertFalse(monitor.isPersistentlyDown)

        monitor.tick()
        XCTAssertEqual(reports.value.count, 1, "跨过阈值必须报一次")
        XCTAssertTrue(monitor.isPersistentlyDown)

        // 继续缺下去也只报一次 —— 每轮都报会把日志和 UI 刷爆。
        for _ in 0..<10 { monitor.tick() }
        XCTAssertEqual(reports.value.count, 1, "边沿触发，只报一次：\(reports.value)")
    }

    func testPersistentFailureMessageReadsAsSeconds() {
        // pollInterval 在夹具里是 60 s，阈值 5 轮 → 约 300 秒。文案必须说人话。
        let process = FlakyDock(pid: 400, recoversOnKickstart: false)
        let (monitor, _) = makeMonitor(process: process, persistentFailureThreshold: 5)

        let reports = Box<[String]>([])
        monitor.onPersistentlyDown = { reports.value.append($0) }

        process.vanish()
        for _ in 0..<5 { monitor.tick() }

        XCTAssertEqual(reports.value.count, 1)
        XCTAssertTrue(reports.value[0].contains("300 秒"), "文案：\(reports.value)")
    }

    func testPersistentlyDownClearsWhenDockFinallyComesBack() {
        let process = FlakyDock(pid: 400, recoversOnKickstart: false)
        let (monitor, _) = makeMonitor(process: process, persistentFailureThreshold: 5)

        let reports = Box<[String]>([])
        let revivals = Box<[Int]>([])
        monitor.onPersistentlyDown = { reports.value.append($0) }
        monitor.onRevived = { revivals.value.append($0) }

        process.vanish()
        for _ in 0..<5 { monitor.tick() }
        XCTAssertTrue(monitor.isPersistentlyDown)

        // launchd 后来又能拉回来了。
        process.setRecoversOnKickstart(true)
        monitor.tick()      // 到 kickstart 节奏就拉
        monitor.tick()      // 这次真的回来了

        XCTAssertFalse(monitor.isPersistentlyDown, "回来了就必须解除")
        XCTAssertEqual(revivals.value, [1], "恢复只报一次")
        XCTAssertEqual(monitor.recoveryCount, 1)
    }

    func testReviveNowDoesNotPrejudgeTheOutcome() {
        let process = FlakyDock(pid: 400, recoversOnKickstart: false)
        let (monitor, messages) = makeMonitor(process: process)

        XCTAssertTrue(monitor.reviveNow(), "launchctl 跑起来了就该返回 true")
        XCTAssertEqual(process.kickstartCount, 1)
        XCTAssertEqual(monitor.consecutiveMisses, 0, "手动重试不该改缺失计数 —— 拉没拉回来由下一次 tick 判定")
        XCTAssertFalse(monitor.isPersistentlyDown, "更不该预支「拉不回来」的结论")
        XCTAssertTrue(messages.value.contains { $0.contains("手动重试拉回") }, "日志：\(messages.value)")
    }

    func testPersistentThresholdIsForcedAboveMissThreshold() {
        // 阈值传得比 missThreshold 还小是配置错误：会在「还没到该动手的轮数」就先喊拉不回来。
        let process = FlakyDock(pid: 400, recoversOnKickstart: false)
        let (monitor, _) = makeMonitor(process: process, missThreshold: 6, persistentFailureThreshold: 1)

        let reports = Box<[String]>([])
        monitor.onPersistentlyDown = { reports.value.append($0) }

        process.vanish()
        for _ in 0..<6 { monitor.tick() }

        XCTAssertTrue(reports.value.isEmpty, "阈值被抬到 missThreshold+1=7，第 6 轮不该报警")
        XCTAssertEqual(process.kickstartCount, 1, "第 6 轮该动手拉回")
    }

    // MARK: - 生产默认值：不能和 launchd 的退避抢着动手

    func testDefaultWaitsFourSecondsOfAbsenceAndThenRests() {
        // 真机踩过（2026-09-19）：默认值曾经是「1 秒就动手 + 每 2 秒催一发 `kickstart -k`」。
        // 每一发 `-k` 都把 launchd 正要拉起的 Dock 再杀一次，一次慢恢复被自我放大成
        // 60–126 秒的 Dock 缺失（用户侧就是"切一次桌面黑屏几分钟"）。
        // 默认值现在的契约：缺失满 4 秒才动手，之后每 30 秒才催一发。
        let process = FlakyDock(pid: 400, recoversOnKickstart: false)
        let monitor = DockPresenceMonitor(process: process)

        process.vanish()
        for _ in 0..<7 { monitor.tick() }
        XCTAssertEqual(process.kickstartCount, 0, "缺失 3.5 秒还在 launchd 的正常恢复尺度里，不该动手")

        monitor.tick()
        XCTAssertEqual(process.kickstartCount, 1, "满 4 秒才补第一发")

        for _ in 0..<59 { monitor.tick() }
        XCTAssertEqual(process.kickstartCount, 1, "之后 30 秒内不该再催 —— 静置等待比反复 kickstart 更快")

        monitor.tick()
        XCTAssertEqual(process.kickstartCount, 2)
    }

    func testDefaultDoesNotWarnDuringLaunchdBackoff() {
        // 报警的尺度也对齐退避：几十秒的缺失在本机是"系统正在恢复"，那时报警等于报故障。
        let process = FlakyDock(pid: 400, recoversOnKickstart: false)
        let monitor = DockPresenceMonitor(process: process)
        let reports = Box<[String]>([])
        monitor.onPersistentlyDown = { reports.value.append($0) }

        process.vanish()
        for _ in 0..<119 { monitor.tick() }
        XCTAssertTrue(reports.value.isEmpty, "缺失 59.5 秒还在正常恢复窗口内")

        monitor.tick()
        XCTAssertEqual(reports.value.count, 1, "满 60 秒才吭声，且只吭一次")
    }
}

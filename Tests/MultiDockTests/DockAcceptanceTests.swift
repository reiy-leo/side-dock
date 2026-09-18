import Darwin
import XCTest
@testable import MultiDock

/// P2 验收：**真的**改写 `com.apple.dock`、**真的**重启 Dock，然后还原。
///
/// 因为会动用户真实的 Dock，默认**跳过**；显式开启才跑：
/// ```
/// MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --filter DockAcceptanceTests
/// ```
///
/// 验收标准（`docs/PLAN.md` §4 的 P2 行）：
/// 1. 写完之后，与操作前的全量域 diff，**除白名单键外无任何差异**；
/// 2. 新写进去的 tile 被 Dock **补上 `GUID`** —— 这是"Dock 真的读进去了"的客观判据（P0 实测）；
/// 3. 还原后**逐键等于**操作前的全量域。
///
/// 无论成败都会把操作前的全量域写回去，不会留下被改坏的 Dock。
///
/// ⚠️ **跑的时候别手动改 Dock**（拖图标、改大小、启动/退出 App 都可能让 Dock 回写偏好）。
/// 实测踩过：有一次测试窗口内 Dock 被外部改动，`persistent-others` 从 4 项变 1 项，
/// 于是"还原后仍有差异"报了假失败。差异里只有 `mod-count` / `recent-apps` 才算正常。
@MainActor
final class DockAcceptanceTests: XCTestCase {

    private static let enableFlag = "MULTIDOCK_DOCK_ACCEPTANCE"
    private static let dumpDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
    private static let calculatorPath = "/System/Applications/Calculator.app"

    func testApplyThenRestoreLeavesDockUntouched() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.enableFlag] == "1",
            "会真的重启 Dock；设 \(Self.enableFlag)=1 才跑"
        )

        let before = DockPreferences.readDomain()
        XCTAssertFalse(before.isEmpty, "读不到 com.apple.dock，验收无意义")
        try Self.dump(before, named: "before")

        // 断言失败不会抛错，所以正常路径一路跑到底；只有 XCTUnwrap 之类的 throw 会跳出。
        // 两条路都必须还原。
        do {
            try await runApplyPhase(before: before)
        } catch {
            await Self.writeBack(before, label: "异常还原")
            throw error
        }

        let restored = await Self.writeBack(before, label: "验收结束还原")
        try Self.dump(restored, named: "after-restore")

        let stillDifferent = Self.differences(between: before, and: restored)
        // Dock 自己会改的键：重启一次 `mod-count` 就 +1，`recent-apps` 是它自己的记账。
        // 这些不在白名单里、我们从不写，所以差异里出现它们是正常的。
        let illegal = stillDifferent.subtracting(DockPreferences.whitelistedKeys)
            .subtracting(Self.dockSelfMutatingKeys)
        XCTAssertTrue(illegal.isEmpty, "还原后白名单外的键仍有差异：\(illegal.sorted())")
        XCTAssertEqual(Set(before.keys), Set(restored.keys), "键集合必须完全一致")
        print("""
        [验收] 还原后仍有差异的键：\(stillDifferent.sorted())（只允许是 Dock 自己的计数器）
        [验收] 图标顺序 after-restore：\(Self.labels(of: restored))
        [验收] 还原后白名单键逐键一致，键集合一致（\(restored.count) 个键）
        """)
    }

    /// Dock 自己会改、我们从不写的键。重启 Dock 就会动。
    private static let dockSelfMutatingKeys: Set<String> = ["mod-count", "recent-apps", "trash-full"]

    // MARK: - P3 验收：两个桌面来回切，结果稳定

    /// P3 验收标准（`docs/PLAN.md` §4 的 P3 行）里可脚本化的部分：
    /// - 桌面 1 与桌面 2 配置不同，来回切 20 次，**每次真实 Dock 都等于目标那份**；
    /// - 两桌面配置相同时切换**无 Dock 刷新**（`mod-count` 不动）；
    /// - 我们自己的写入**不会被 `DockWatcher` 误判成用户手动改动**（这会让配置被污染）。
    ///
    /// 无法脚本化的两条（需要真的拖图标）留在 `AGENTS.md` §6.3 交给用户手测。
    func testSwitchingBetweenTwoDesktopConfigsIsStable() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.enableFlag] == "1",
            "会真的重启 Dock；设 \(Self.enableFlag)=1 才跑"
        )

        let before = DockPreferences.readDomain()
        XCTAssertFalse(before.isEmpty, "读不到 com.apple.dock，验收无意义")
        try Self.dump(before, named: "p3-before")

        do {
            try await runDesktopSwitchPhase(before: before)
        } catch {
            await Self.writeBack(before, label: "异常还原")
            throw error
        }

        let restored = await Self.writeBack(before, label: "P3 验收结束还原")
        try Self.dump(restored, named: "p3-after-restore")

        let illegal = Self.differences(between: before, and: restored)
            .subtracting(DockPreferences.whitelistedKeys)
            .subtracting(Self.dockSelfMutatingKeys)
        XCTAssertTrue(illegal.isEmpty, "还原后白名单外的键仍有差异：\(illegal.sorted())")
        XCTAssertEqual(Set(before.keys), Set(restored.keys), "键集合必须完全一致")
        print("""
        [P3 验收] 还原后差异键：\(Self.differences(between: before, and: restored).sorted())
        [P3 验收] 图标顺序 after-restore：\(Self.labels(of: restored))
        """)
    }

    private func runDesktopSwitchPhase(before: [String: PlistValue]) async throws {
        let controller = DockController(backup: {})   // 验收不写 App 的备份目录

        // 用真的 `DockWatcher`，但轮询周期拉长到 60 s —— 我们手动 `tick()`，
        // 这样"它有没有把我们的写入误判成用户改动"是确定性的，不受轮询时机影响。
        let misdetected = Box<[DockConfig]>([])
        let watcher = DockWatcher(
            pollInterval: .seconds(60),
            currentFingerprint: { controller.currentComparableFingerprint() },
            appliedFingerprint: { controller.appliedComparableFingerprint },
            readLiveConfig: { controller.captureLiveConfig() },
            onUserEdit: { misdetected.value.append($0) }
        )

        // ---- 两套明显不同的配置：图标大小与放大效果都不同 ----
        let base = DockConfig.read(from: before)
        var desktop1 = base
        desktop1.appearance.tilesize = 40
        desktop1.appearance.magnification = false
        var desktop2 = base
        desktop2.appearance.tilesize = 60
        desktop2.appearance.magnification = true
        XCTAssertNotEqual(desktop1.fingerprint, desktop2.fingerprint)

        let targets = [desktop1, desktop2]
        var switches = 0
        /// Dock **真正不可用**的时长（重载本身）。这才是用户能感觉到的那个数。
        var dockDownTimings: [Int] = []
        /// 一次应用的**总**耗时。包含为错开 launchd 节流而主动等待的时间（期间 Dock 可用）。
        var totalTimings: [Int] = []
        var lastApplied = desktop1

        // ---- 来回切 20 次，每次都核对真实 Dock 是否等于目标那份 ----
        for round in 0..<20 {
            let target = targets[round % targets.count]
            let outcome = await controller.apply(target, reason: "P3 验收 第 \(round + 1) 次")
            switches += 1
            lastApplied = target
            dockDownTimings.append(Int((outcome.reload?.elapsed ?? 0) * 1000))
            totalTimings.append(Int(outcome.elapsed * 1000))

            XCTAssertEqual(outcome.result, .applied, "第 \(round + 1) 次应用失败：\(outcome.summary)")
            XCTAssertEqual(outcome.verifyAttempts, 1, "第 \(round + 1) 次需要重试，不该发生")
            XCTAssertEqual(outcome.reload?.method, .sighup, "主路径必须是 SIGHUP")
            // 节流窗口错开后，Dock 每次只该消失几十毫秒。
            // 若这里出现约 1000 ms，说明 minimumSpacing 失效了，用户会看到 Dock 消失一秒。
            XCTAssertLessThan(outcome.reload?.elapsed ?? 99, 0.3,
                              "第 \(round + 1) 次 Dock 不可用 \(Int((outcome.reload?.elapsed ?? 0) * 1000)) ms，节流没被错开")

            let live = DockPreferences.readDomain()
            XCTAssertEqual(live["tilesize"]?.doubleValue, target.appearance.tilesize,
                           "第 \(round + 1) 次切换后真实 Dock 的 tilesize 不对")
            XCTAssertEqual(live["magnification"]?.boolValue, target.appearance.magnification,
                           "第 \(round + 1) 次切换后真实 Dock 的 magnification 不对")

            // 关键：我们刚写完，Dock 会规范化回写（补 GUID 等）。
            // 这次"变化"绝不能被当成用户手动改动 —— 否则配置会被污染成 Dock 的规范化结果。
            watcher.tick()
            watcher.acknowledge(controller.appliedComparableFingerprint)
        }

        XCTAssertEqual(switches, 20)
        XCTAssertEqual(misdetected.value.count, 0,
                       "我们的写入被误判成用户手动改动 \(misdetected.value.count) 次")
        XCTAssertEqual(watcher.detectedCount, 0)
        print("""
        [P3 验收] 来回切 \(switches) 次全部成功
        [P3 验收] Dock 不可用时长（ms）：\(dockDownTimings)　最坏 \(dockDownTimings.max() ?? 0) ms
        [P3 验收] 应用总耗时（ms）　：\(totalTimings)　最坏 \(totalTimings.max() ?? 0) ms
        [P3 验收] DockWatcher 误判次数：\(watcher.detectedCount)（必须为 0）
        """)

        // ---- 两桌面配置相同时，切换必须零开销（不重启 Dock） ----
        // 用循环里最后落点那份来试，它此刻正是真实 Dock 的内容。
        let modCountBefore = DockPreferences.readDomain()["mod-count"]?.intValue
        let identical = await controller.apply(lastApplied, reason: "P3 验收 内容相同")
        XCTAssertEqual(identical.result, .skippedIdentical, "内容相同必须短路")
        XCTAssertNil(identical.reload, "短路时不该重启 Dock")
        XCTAssertEqual(DockPreferences.readDomain()["mod-count"]?.intValue, modCountBefore,
                       "短路时 mod-count 不该变 —— 变了说明 Dock 其实被重启了")
        print("[P3 验收] 内容相同时短路：\(identical.summary)")
    }

    // MARK: - P4 验收：自愈幂等 + Dock 被杀死后拉回

    /// P4 验收标准 ⑤：**连开三次 App 并每次还原，结果稳定幂等**。
    ///
    /// 客观判据不只是"三次之后 Dock 是对的"（那太弱），而是：
    /// - 第一次必须**真的写回基准**（`.applied`）；
    /// - 第二、三次必须**短路**（`mod-count` 不动 = 没有白重启一次 Dock）。
    ///
    /// 后一条才是"幂等"的真意思：每次启动都白重启一遍 Dock 的话，
    /// 用户会看到每次开机 Dock 都闪一下。
    func testSelfHealIsIdempotentAcrossThreeLaunches() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.enableFlag] == "1",
            "会真的重启 Dock；设 \(Self.enableFlag)=1 才跑"
        )

        let before = DockPreferences.readDomain()
        XCTAssertFalse(before.isEmpty, "读不到 com.apple.dock，验收无意义")
        try Self.dump(before, named: "p4-before")

        do {
            try await runSelfHealPhase(before: before)
        } catch {
            await Self.writeBack(before, label: "异常还原")
            throw error
        }

        let restored = await Self.writeBack(before, label: "P4 验收结束还原")
        try Self.dump(restored, named: "p4-after-restore")

        let illegal = Self.differences(between: before, and: restored)
            .subtracting(DockPreferences.whitelistedKeys)
            .subtracting(Self.dockSelfMutatingKeys)
        XCTAssertTrue(illegal.isEmpty, "还原后白名单外的键仍有差异：\(illegal.sorted())")
        XCTAssertEqual(Set(before.keys), Set(restored.keys), "键集合必须完全一致")
        print("""
        [P4 验收] 还原后差异键：\(Self.differences(between: before, and: restored).sorted())
        [P4 验收] 图标顺序 after-restore：\(Self.labels(of: restored))
        """)
    }

    private func runSelfHealPhase(before: [String: PlistValue]) async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-p4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baselineStore = BaselineStore(
            baselineURL: directory.appendingPathComponent("baseline.plist"),
            markerURL: directory.appendingPathComponent("session.state"),
            backupsURL: directory.appendingPathComponent("backups", isDirectory: true)
        )
        // 基准 = 操作前的 Dock。直接落文件，不经过 App —— 免得它去抓"当前"的当基准。
        try Self.dump(before, named: "p4-baseline")
        try Data(contentsOf: Self.dumpDirectory.appendingPathComponent("multidock-acceptance-p4-baseline.plist"))
            .write(to: baselineStore.baselineURL)

        // ---- 1. 先把 Dock 弄脏：换一套明显不同的配置 ----
        var dirty = DockConfig.read(from: before)
        dirty.appearance.tilesize = dirty.appearance.tilesize == 52 ? 44 : 52
        dirty.appearance.magnification.toggle()
        let dirtyOutcome = await DockController(backup: {})
            .apply(dirty, reason: "P4 验收：先把 Dock 弄脏", force: true)
        XCTAssertEqual(dirtyOutcome.result, .applied, "弄脏失败：\(dirtyOutcome.summary)")
        XCTAssertNotEqual(DockPreferences.readDomain()["tilesize"], before["tilesize"],
                          "Dock 没被弄脏，后面的自愈验证就没意义")

        // ---- 2. 连开三次「App」，每次都应该把 Dock 还原回基准 ----
        var summaries: [String] = []
        var modCounts: [Int] = []
        for round in 1...3 {
            // 每次启动前都留一个"上次被强杀"的残留标记。
            try baselineStore.writeSessionMarker(
                BaselineStore.SessionMarker(
                    pid: 999_999,
                    startedAt: Date(),
                    appliedFingerprint: "dirty-round-\(round)",
                    appliedAt: Date()
                )
            )
            let state = AppState(
                configStore: ConfigStore(
                    fileURL: directory.appendingPathComponent("config-round-\(round).json")
                ),
                baselineStore: baselineStore,
                presenceMonitor: DockPresenceMonitor(
                    process: RealDockProcessControl(),
                    pollInterval: .seconds(60)      // 别让它在验收期间自己动手
                )
            )
            state.start()
            await state.waitForSelfHeal()
            summaries.append(state.selfHealSummary ?? "（没有自愈）")
            modCounts.append(DockPreferences.readDomain()["mod-count"]?.intValue ?? -1)
            state.stop()

            let live = DockPreferences.readDomain()
            for key in DockPreferences.whitelistedKeys where before[key] != nil {
                XCTAssertEqual(live[key], before[key], "第 \(round) 轮之后 \(key) 没回到基准")
            }
        }

        XCTAssertEqual(summaries[0], "已自动还原上次未还原的 Dock", "第一次必须真的写回基准")
        XCTAssertEqual(summaries[1], "Dock 已与原始状态一致，无需还原", "第二次该短路")
        XCTAssertEqual(summaries[2], "Dock 已与原始状态一致，无需还原", "第三次该短路")
        XCTAssertEqual(modCounts[1], modCounts[2],
                       "第二、三轮不该重启 Dock —— mod-count 变了说明白重启了一次")
        print("""
        [P4 验收] 三次自愈的结果：\(summaries)
        [P4 验收] mod-count 三次：\(modCounts)（第 2、3 次必须相同 = 没有白重启 Dock）
        """)
    }

    /// 新增报警的**反向守卫**：真实 Dock 健康时，监视器绝不能误报"拉不回来"。
    ///
    /// 为什么值得真机跑：新加的"持续拉不回来"判据是**连续 12 轮读不到正数 PID**。
    /// 如果真实的 `dockPID()`（`proc_listpids` + `proc_name`）会偶发返回 nil，
    /// 那么一台完全正常的机器也会在几秒后弹出红色的「Dock 拉不回来」横幅 —— 纯噪音。
    /// 单测里 `dockPID()` 是替身，永远验不到这一点。
    ///
    /// **只读**：不写偏好、不重启 Dock、不杀任何进程。
    func testHealthyRealDockNeverRaisesPersistentFailure() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.enableFlag] == "1",
            "真机读数；设 \(Self.enableFlag)=1 才跑"
        )

        let process = RealDockProcessControl()
        try XCTUnwrap(process.dockPID(), "拿不到 Dock PID，验收无意义")

        let monitor = DockPresenceMonitor(
            process: process,
            pollInterval: .milliseconds(50),   // 报警文案里的秒数按这个折算
            missThreshold: 2,
            kickstartEvery: 4,
            persistentFailureThreshold: 12
        )
        var alarms: [String] = []
        monitor.onPersistentlyDown = { alarms.append($0) }

        // 阈值是 12 轮，跑 40 轮留足余量（顺带覆盖一次 kickstartEvery 的整周期）。
        for _ in 0..<40 {
            monitor.tick()
            try? await Task.sleep(for: .milliseconds(20))
        }

        print("""
        [报警验收] 40 轮真实读数：连续缺失 \(monitor.consecutiveMisses) 次　拉回尝试 \(monitor.kickstartCount) 次
        [报警验收] 误报次数：\(alarms.count)（必须为 0）　isPersistentlyDown=\(monitor.isPersistentlyDown)
        """)

        XCTAssertTrue(alarms.isEmpty, "真实 Dock 健康却误报：\(alarms)")
        XCTAssertFalse(monitor.isPersistentlyDown, "不该判定为拉不回来")
        XCTAssertEqual(monitor.kickstartCount, 0, "Dock 在的时候一次都不该拉")
        XCTAssertEqual(monitor.recoveryCount, 0)
    }

    /// P4 验收标准 ④：**人为杀掉 Dock 后 3 秒内恢复**。
    ///
    /// ⚠️ 这条会**真的杀掉你的 Dock**（`SIGKILL`，等价于 `kill -9`）。
    /// launchd 的 `KeepAlive` 会把它拉回来，Dock 会闪一下、菜单栏图标短暂消失。
    /// 默认跳过，`MULTIDOCK_DOCK_ACCEPTANCE=1` 才跑。
    ///
    /// 说明：Dock 由 launchd 守护，正常机器上它自己就会在几十毫秒内回来 ——
    /// 所以这条验收证明的是"**3 秒内一定恢复**"，而不是"全靠我们的监视器才恢复"。
    /// 监视器的判定与拉回逻辑（含 launchd 也不管了的极端情况）在
    /// `DockPresenceMonitorTests` 里用替身覆盖。
    func testKillingDockRecoversWithinThreeSeconds() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.enableFlag] == "1",
            "会真的杀掉 Dock；设 \(Self.enableFlag)=1 才跑"
        )

        let process = RealDockProcessControl()
        let before = DockPreferences.readDomain()
        try Self.dump(before, named: "p4-kill-before")

        let originalPID = try XCTUnwrap(process.dockPID(), "拿不到 Dock PID，验收无意义")
        print("[P4 验收] 杀之前的 Dock PID：\(originalPID)")

        let started = ContinuousClock.now
        XCTAssertEqual(Darwin.kill(originalPID, SIGKILL), 0, "杀 Dock 失败")

        // 3 秒内必须看到一个新的、正数的 PID。
        var recoveredPID: pid_t?
        let deadline = started + .seconds(3)
        while ContinuousClock.now < deadline {
            if let pid = process.dockPID(), pid > 0, pid != originalPID {
                recoveredPID = pid
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = started.duration(to: ContinuousClock.now)
        let milliseconds = Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        let recovered = try XCTUnwrap(recoveredPID, "3 秒内 Dock 没回来 —— 用户会失去整个 Dock")
        XCTAssertLessThan(milliseconds, 3000)

        // Dock 重启后会重新读偏好域：白名单键必须原样还在（我们在它重启期间没写坏任何东西）。
        let after = DockPreferences.readDomain()
        for key in DockPreferences.whitelistedKeys where before[key] != nil {
            XCTAssertEqual(after[key], before[key], "Dock 重启后 \(key) 变了")
        }
        XCTAssertEqual(Set(before.keys), Set(after.keys), "键集合不该变")
        print("""
        [P4 验收] Dock 已恢复：PID \(originalPID) → \(recovered)，用时约 \(milliseconds) ms（上限 3000 ms）
        [P4 验收] 恢复后白名单键与键集合均与杀之前一致
        """)
    }

    // MARK: - P5+ 验收：外部改动真实 Dock → 识别并回存（覆盖 `AGENTS.md` §6.3 的 A4）

    /// 覆盖 `AGENTS.md` §6.3 的 **A4** —— 那条一直挂着"要手动拖一个图标进 Dock 才验得了"。
    ///
    /// **为什么不必手拖**：`DockWatcher` 的判据是"可比指纹变了、且不等于我们写下去的那份"
    /// （见 `DockWatcher.tick()`）。它**分不出**改动来自用户拖拽还是别的进程写偏好 ——
    /// 而且真实用户拖拽同样是 **Dock 进程**去写域的，所以"另一个进程改域 + 重启 Dock"
    /// 在 watcher 眼里与手拖完全等价。
    ///
    /// **这条测试真正想验的东西**：单测里的假偏好域**没有 `GUID` / `book` / `file-mod-date`
    /// 这些 Dock 会回写的字段**，而真实域有。所以"回存下来的配置到底等不等于真实 Dock"
    /// 只有真实域能验 —— 不等的话，用户"切走再切回"时他的改动就丢了。
    ///
    /// ⚠️ 会真的改 `com.apple.dock`、真的重启 Dock；默认跳过，
    /// `MULTIDOCK_DOCK_ACCEPTANCE=1` 才跑。
    func testExternalDockChangeIsCapturedBackToActiveDesktop() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.enableFlag] == "1",
            "会真的改 Dock 并重启；设 \(Self.enableFlag)=1 才跑"
        )

        let before = DockPreferences.readDomain()
        XCTAssertFalse(before.isEmpty, "读不到 com.apple.dock，验收无意义")
        try Self.dump(before, named: "capture-before")

        var report: [String] = []
        do {
            // 两条落点都要验：桌面**有**独立 Dock（回存进该桌面的 override）与**没有**（回存进默认 Dock）。
            // 前者才是这个 App 的常态用法（卖点就是逐桌面 Dock），所以不能只验后者。
            report.append(try await runCaptureScenario(before: before, seedOverride: false))
            report.append(try await runCaptureScenario(before: before, seedOverride: true))
        } catch {
            await Self.writeBack(before, label: "异常还原")
            throw error
        }

        let restored = await Self.writeBack(before, label: "回存验收结束还原")
        try Self.dump(restored, named: "capture-after-restore")

        let illegal = Self.differences(between: before, and: restored)
            .subtracting(DockPreferences.whitelistedKeys)
            .subtracting(Self.dockSelfMutatingKeys)
        XCTAssertTrue(illegal.isEmpty, "还原后白名单外的键仍有差异：\(illegal.sorted())")
        XCTAssertEqual(Set(before.keys), Set(restored.keys), "键集合必须完全一致")
        print(report.joined(separator: "\n"))
        print("[回存验收] 还原后差异键：\(Self.differences(between: before, and: restored).sorted())")
    }

    /// 跑一次"外部改动 → 回存"场景，返回一行报告。
    ///
    /// - Parameter seedOverride: `true` = 先给当前桌面建一份独立 Dock（回存应落在该桌面的 override 上）；
    ///   `false` = 不建（回存应落在默认 Dock 上）。
    private func runCaptureScenario(
        before: [String: PlistValue],
        seedOverride: Bool
    ) async throws -> String {
        // 用**临时目录**的 Store：绝不碰用户真实的 config.json / baseline.plist / session.state。
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("multidock-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 真实 DockController（会真的写 Dock），假 provider（让"当前桌面"确定可控）。
        let controller = DockController(backup: {})
        let spaces = FakeSpaceProvider.desktops(count: 1)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)

        let state = AppState(
            dockController: controller,
            configStore: ConfigStore(fileURL: scratch.appendingPathComponent("config.json")),
            baselineStore: BaselineStore(
                baselineURL: scratch.appendingPathComponent("baseline.plist"),
                markerURL: scratch.appendingPathComponent("session.state")
            ),
            provider: provider
        )
        state.start()
        defer { state.stop() }

        // 当前桌面必须已经识别出来 —— 回存落点靠它决定（有 override → 该桌面；否则 → 默认 Dock）。
        _ = await Self.wait("活动桌面被识别") { state.activeSpace != nil }
        let space = try XCTUnwrap(state.activeSpace, "没识别出活动桌面，回存落点无从谈起")
        XCTAssertNotNil(controller.appliedComparableFingerprint,
                        "启动时的 adoptLiveDockAsApplied 应已记下「我们写下去的那份」——"
                        + "watcher 没有它就不会回存（这是有意的保护）")

        if seedOverride {
            // 造 override 要写一份**与现状不同**的配置，否则内容相同会被指纹短路、Dock 根本不重启。
            var seed = DockConfig.read(from: before)
            seed.appearance.tilesize = (before["tilesize"]?.doubleValue ?? 52) == 44 ? 60 : 44
            state.setOverride(seed, for: space, reason: "回存验收：先建一份独立 Dock")
            await controller.waitForIdle()
            XCTAssertTrue(state.hasOverride(for: space), "夹具没建出 override")
        } else {
            XCTAssertFalse(state.hasOverride(for: space), "本场景不该有 override")
        }

        // ---- 外部改动：换一个进程改域，再重启 Dock 让它规范化回写 ----
        let originalTilesize = DockPreferences.readDomain()["tilesize"]?.doubleValue ?? 52
        let externalTilesize: Double = originalTilesize == 72 ? 56 : 72

        try Self.runDefaultsWrite(key: "tilesize", value: String(externalTilesize))

        // 关键前提取证：**我们进程读得到别的进程写的值吗**。
        // 真实用户拖拽也是 Dock 进程写域，所以这条不通的话 watcher 在真实场景里根本看不见改动。
        let visible = await Self.wait("跨进程写入对我们可见", timeout: .seconds(5)) {
            DockPreferences.readDomain()["tilesize"]?.doubleValue == externalTilesize
        }
        let readBack = DockPreferences.readDomain()["tilesize"]?.doubleValue
        XCTAssertTrue(visible,
                      "另一个进程写的 tilesize 在我们进程里读不到（读到的是 "
                      + (readBack.map { String(describing: $0) } ?? "nil")
                      + "）—— 这说明 DockWatcher 在真实场景里看不见用户改动")

        // 这一枪是我们自己开的（外部改动 + 让 Dock 规范化），**之后不该再有任何重启**。
        let reload = await DockReloader().reload(strategy: .auto)
        let pidAfterReload = try XCTUnwrap(RealDockProcessControl().dockPID(), "拿不到 Dock PID")
        let detectedBefore = state.dockWatcher?.detectedCount ?? 0

        // ---- 等真实的 2 s 轮询把它认出来（不手动 tick，验的就是真实轮询） ----
        let landed = await Self.wait("DockWatcher 识别并回存", timeout: .seconds(25)) {
            state.binding(for: space)?.override?.appearance.tilesize == externalTilesize
                || state.settings.defaultDock.appearance.tilesize == externalTilesize
        }
        let detected = (state.dockWatcher?.detectedCount ?? 0) - detectedBefore
        let landedIn = state.hasOverride(for: space) ? "该桌面的 override" : "默认 Dock"
        let capturedConfig = state.effectiveConfig(for: space)

        // ⚠️ **必须等排队中的应用跑完再读 PID**。`setOverride` 是**同步**更新 binding 的，
        // 而它触发的应用走 `request()` 异步排队 —— 不等就会在应用落地前读 PID，
        // 于是"没有白重启"这个结论会**假成立**（我第一版就踩了这个坑）。
        await controller.waitForIdle()
        try? await Task.sleep(for: .milliseconds(400))
        let pidAfterCapture = try XCTUnwrap(RealDockProcessControl().dockPID(), "拿不到 Dock PID")

        XCTAssertTrue(landed, "DockWatcher 没把外部改动回存（detectedCount 增量 \(detected)）")
        XCTAssertGreaterThanOrEqual(detected, 1, "detectedCount 应该至少 +1")
        XCTAssertEqual(capturedConfig.appearance.tilesize, externalTilesize,
                       "回存下来的 tilesize 不对（落点：\(landedIn)）")

        // ---- 决定性断言 1：回存下来的配置必须**等于真实 Dock** ----
        // 这是 A4 真正关心的事：不等的话，用户切走再切回就把自己的改动丢了。
        let matches = await Self.wait("回存内容与真实 Dock 一致", timeout: .seconds(10)) {
            guard let live = controller.currentComparableFingerprint() else { return false }
            return controller.comparableFingerprint(of: capturedConfig) == live
        }
        XCTAssertTrue(matches, "回存下来的配置与真实 Dock 对不上 —— 切走再切回会丢用户的改动")

        // ---- 决定性断言 2：回存**不该**白重启一次 Dock ----
        // 真实 Dock 已经是这份内容了。此刻还去写 + 重启，用户会看到一次毫无理由的闪烁。
        XCTAssertEqual(pidAfterCapture, pidAfterReload,
                       "回存过程白重启了一次 Dock（PID \(pidAfterReload) → \(pidAfterCapture)）")

        print("[回存验收] 外部改动已落盘（tilesize → \(externalTilesize)），\(reload.description)")
        return "[回存验收] 落点=\(landedIn)　识别=\(landed)　detectedCount +\(detected)　"
            + "回存 tilesize=\(capturedConfig.appearance.tilesize)　"
            + "回存期间 Dock PID \(pidAfterReload) → \(pidAfterCapture)（应相同）"
    }

    /// 在**另一个进程**里用 `/usr/bin/defaults` 改 `com.apple.dock`。
    /// 刻意不走 `DockPreferences` —— 要的就是"外部改动"。
    private static func runDefaultsWrite(key: String, value: String) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.dock", key, "-float", value]
        let pipe = Pipe()
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(task.terminationStatus, 0,
                       "外部 defaults write 失败（\(task.terminationStatus)）：\(message)")
    }

    /// 轮询等一个条件成立。返回它有没有在超时前成立。
    ///
    /// 刻意**不手动 `tick()` watcher**：这条验收要验的就是"真实 2 s 轮询能不能认出来"。
    private static func wait(
        _ label: String,
        timeout: Duration = .seconds(10),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        if !condition() { print("[回存验收] 超时未满足：\(label)") }
        return false
    }

    /// 写入 + 校验 + 差异核对。
    private func runApplyPhase(before: [String: PlistValue]) async throws {
        // ---- 1. 构造一套与现状不同的配置 ----
        var config = DockConfig.read(from: before)
        let originalTilesize = config.appearance.tilesize
        config.appearance.tilesize = originalTilesize == 52 ? 44 : 52
        config.appearance.magnification.toggle()

        // 加一个**全新的、不带 GUID** 的条目：只有它被 Dock 补上 GUID，才能证明写入被吃下。
        let probe = try XCTUnwrap(
            DockStripRules.tile(forAppAt: Self.calculatorPath),
            "找不到 \(Self.calculatorPath)"
        )
        config.pinnedApps = DockStripRules.normalizedApps(config.pinnedApps + [probe])
        XCTAssertEqual(config.pinnedApps.count, DockConfig.read(from: before).pinnedApps.count + 1)

        let controller = DockController(backup: {})   // 验收不写 App 的备份目录
        let outcome = await controller.apply(config, reason: "P2 验收", strategy: .auto)

        // ---- 2. 应用结果 ----
        XCTAssertEqual(outcome.result, .applied, "应用失败：\(outcome.summary)")
        XCTAssertEqual(outcome.verifyAttempts, 1, "不该需要重试")
        XCTAssertEqual(outcome.reload?.method, .sighup, "主路径必须是 SIGHUP")
        // 本机缺失的外观键只有 show-process-indicators。autohide-delay / autohide-time-modifier
        // 因为域里没有、读回来是 nil，压根不会进 domainEntries，所以不算"被跳过"。
        XCTAssertEqual(outcome.skippedKeys, ["show-process-indicators"],
                       "本机缺失的外观键，实际：\(outcome.skippedKeys)")
        print("[验收] 应用：\(outcome.summary)")

        // ---- 3. 差异只允许出现在白名单键上 ----
        let after = DockPreferences.readDomain()
        try Self.dump(after, named: "after-apply")

        let changed = Self.differences(between: before, and: after)
        let illegal = changed.subtracting(DockPreferences.whitelistedKeys)
        XCTAssertTrue(illegal.isEmpty, "白名单外的键被改动了：\(illegal.sorted())")
        XCTAssertTrue(changed.contains("tilesize"), "白名单键该改的必须真的改了")
        XCTAssertTrue(changed.contains("persistent-apps"))
        print("""
        [验收] 变化的键：\(changed.sorted())
        [验收] 图标顺序 before    ：\(Self.labels(of: before))
        [验收] 图标顺序 after-apply：\(Self.labels(of: after))
        """)

        // ---- 4. Dock 真的读进去了吗：新 tile 必须被补上 GUID ----
        // Dock 的回写是异步的，P0 是"重启后去看"；这里轮询等它落盘。
        let guid = await Self.waitForDockToBackfillGUID(of: probe, timeout: .seconds(8))
        XCTAssertNotNil(guid, "Dock 没给条目补 GUID → 说明它根本没读这份写入（P0 判据）")
        XCTAssertEqual(DockPreferences.readDomain()["tilesize"]?.doubleValue, config.appearance.tilesize)
        print("[验收] Dock 已为写入的条目补上 GUID：\(guid?.fingerprintToken ?? "?")")
    }

    // MARK: - 其他项验收：只搬 Dock 自己的条目（不合成）+ 移除后 Dock 仍健康

    /// 为什么单独验这一条：`persistent-others` 是**唯一**允许"原样搬运"的数组 ——
    /// 我们刻意不做新建（`docs/spikes.md` 实验 8：自拼的目录条目 Dock 不认领，
    /// 字段不全的形状还会让它直接 SIGABRT）。所以这里钉死两件事：
    /// 1. 用 Dock 自己写的 dict 做**移除**，Dock 接受、且进程还活着；
    /// 2. 搬运过程中 Dock 的字段（`GUID` / `book`）**一个都不能丢** —— 那是"只搬不造"的证据。
    func testOtherItemsRemovalAndReapplyKeepsDockHealthy() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.enableFlag] == "1",
            "会真的重启 Dock；设 \(Self.enableFlag)=1 才跑"
        )

        let before = DockPreferences.readDomain()
        XCTAssertFalse(before.isEmpty, "读不到 com.apple.dock，验收无意义")
        let originalOthers = DockConfig.read(from: before).otherItems
        try XCTSkipIf(originalOthers.isEmpty,
                      "真实 Dock 里没有 persistent-others 条目，无法验收移除路径")

        do {
            try await runOtherItemsPhase(before: before, originalOthers: originalOthers)
        } catch {
            await Self.writeBack(before, label: "其他项验收异常还原")
            throw error
        }

        let restored = await Self.writeBack(before, label: "其他项验收还原")
        let illegal = Self.differences(between: before, and: restored)
            .subtracting(DockPreferences.whitelistedKeys)
            .subtracting(Self.dockSelfMutatingKeys)
        XCTAssertTrue(illegal.isEmpty, "还原后白名单外的键仍有差异：\(illegal.sorted())")
        XCTAssertEqual(DockConfig.read(from: restored).otherItems.map(\.normalizedKey),
                       originalOthers.map(\.normalizedKey),
                       "还原后其他项必须与操作前逐项相同")
    }

    private func runOtherItemsPhase(
        before: [String: PlistValue],
        originalOthers: [DockTile]
    ) async throws {
        let controller = DockController(backup: {})   // 验收不写 App 的备份目录
        let control = RealDockProcessControl()
        let removed = try XCTUnwrap(originalOthers.last)

        // ---- 1. 移除最后一项：只删 Dock 自己写的那个 dict，不造任何新条目 ----
        var removal = DockConfig.read(from: before)
        removal.otherItems = Array(originalOthers.dropLast())
        let removalOutcome = await controller.apply(removal, reason: "其他项验收：移除", strategy: .auto)
        XCTAssertEqual(removalOutcome.result, .applied, "移除失败：\(removalOutcome.summary)")

        let afterRemoval = DockPreferences.readDomain()
        let remaining = DockConfig.read(from: afterRemoval).otherItems
        XCTAssertEqual(remaining.map(\.normalizedKey), originalOthers.dropLast().map(\.normalizedKey))
        XCTAssertFalse(remaining.contains { $0.normalizedKey == removed.normalizedKey })
        XCTAssertNotNil(afterRemoval["persistent-others"], "键本身不能被删掉，只是数组变短")
        XCTAssertNotNil(control.dockPID(), "移除之后 Dock 必须还活着")

        // ---- 2. 原样写回：Dock 自己补的字段必须一个字都不少 ----
        var reapply = DockConfig.read(from: afterRemoval)
        reapply.otherItems = originalOthers
        let outcome = await controller.apply(reapply, reason: "其他项验收：原样写回", strategy: .auto)
        XCTAssertEqual(outcome.result, .applied, "写回失败：\(outcome.summary)")
        XCTAssertEqual(outcome.verifyAttempts, 1, "不该需要重试")

        let afterReapply = DockConfig.read(from: DockPreferences.readDomain()).otherItems
        XCTAssertEqual(afterReapply.map(\.normalizedKey), originalOthers.map(\.normalizedKey))

        let keptGUIDs = afterReapply.compactMap { $0.raw["GUID"] }.count
        let expectedGUIDs = originalOthers.compactMap { $0.raw["GUID"] }.count
        XCTAssertEqual(keptGUIDs, expectedGUIDs, "Dock 自己补的 GUID 被我们弄丢了")
        let keptBooks = afterReapply.filter { $0.tileData?["book"] != nil }.count
        let expectedBooks = originalOthers.filter { $0.tileData?["book"] != nil }.count
        XCTAssertEqual(keptBooks, expectedBooks, "book 不能丢（Dock 靠它渲染堆栈预览）")
        XCTAssertNotNil(control.dockPID(), "写回之后 Dock 必须还活着")

        print("""
        [验收] 其他项移除：\(removalOutcome.summary)
        [验收] 移除后剩 \(remaining.count) 项；写回后 \(afterReapply.count) 项
        [验收] 保留的 Dock 字段：GUID \(keptGUIDs)/\(expectedGUIDs)、book \(keptBooks)/\(expectedBooks)
        """)
    }

    /// 域里所有 `persistent-apps` + `persistent-others` 条目的标签，按顺序。
    /// 用来把"顺序/成员变了"和"值变了"分开看 —— 用 `diff` 比对长数组会因为行错位产生假差异。
    private static func labels(of domain: [String: PlistValue]) -> [String] {
        let config = DockConfig.read(from: domain)
        return (config.pinnedApps + config.otherItems).map { $0.label }
    }

    /// 轮询等 Dock 把 `persistent-apps` 规范化回写（补 `GUID`）。
    ///
    /// P0 观测到的是"重启后就有了"，但没测具体延迟。Dock 回写是异步的，
    /// 所以这里必须等，不能读完立刻断言 —— 否则会误判成"写入没生效"。
    private static func waitForDockToBackfillGUID(
        of probe: DockTile,
        timeout: Duration
    ) async -> PlistValue? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let live = DockConfig.read(from: DockPreferences.readDomain()).pinnedApps
            if let tile = live.first(where: { $0.normalizedKey == probe.normalizedKey }),
               let guid = tile.raw["GUID"] {
                return guid
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// 两个全量域的差异键集合。
    private static func differences(
        between lhs: [String: PlistValue],
        and rhs: [String: PlistValue]
    ) -> Set<String> {
        Set(lhs.keys).union(rhs.keys).filter { lhs[$0] != rhs[$0] }
    }

    /// 把一份全量域里的白名单键写回真实 Dock，并回读。返回回读到的全量域。
    @discardableResult
    private static func writeBack(_ domain: [String: PlistValue], label: String) async -> [String: PlistValue] {
        let entries = DockPreferences.whitelistedKeys.reduce(into: [String: PlistValue]()) { result, key in
            if let value = domain[key] { result[key] = value }
        }
        DockPreferences.writeWhitelisted(entries)
        let outcome = await DockReloader().reload(strategy: .auto)
        print("[验收] \(label)：\(outcome.description)")
        return DockPreferences.readDomain()
    }

    private static func dump(_ domain: [String: PlistValue], named name: String) throws {
        var payload: [String: Any] = [:]
        for (key, value) in domain { payload[key] = value.anyValue }
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        try data.write(to: dumpDirectory.appendingPathComponent("multidock-acceptance-\(name).plist"))
    }
}

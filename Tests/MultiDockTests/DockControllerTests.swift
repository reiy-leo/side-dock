import XCTest
@testable import MultiDock

/// 应用流水线的行为。对应 `docs/PLAN.md` §3.4 与 §3.5。
///
/// 全部用测试替身，不碰真实 Dock —— 「真的写进去了吗」只能实测，见 AGENTS.md §7 的 P2 验收。
@MainActor
final class DockControllerTests: XCTestCase {

    // MARK: - 测试替身

    /// 模拟 `com.apple.dock` 域。
    ///
    /// `writesToDrop` 用来模拟「写进去了但 Dock 没吃下」（P0 实测里 SIGTERM 清理窗口的竞态）。
    /// 注意：这里**刻意照抄** `DockPreferences.writeWhitelisted` 的「只覆盖白名单键」语义，
    /// 真实语义由 `DockPreferencesTests` 负责，本文件只测 `DockController` 有没有把正确的键交给它。
    private final class FakePreferences: DockPreferenceAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var domain: [String: PlistValue]
        /// 前 N 次写入不生效。
        private var writesToDrop: Int
        private var writeCount = 0
        private var entriesHistory: [[String: PlistValue]] = []

        init(domain: [String: PlistValue], writesToDrop: Int = 0) {
            self.domain = domain
            self.writesToDrop = writesToDrop
        }

        func readDomain() -> [String: PlistValue] { lock.withLock { domain } }

        @discardableResult
        func writeWhitelisted(_ entries: [String: PlistValue]) -> Int {
            lock.withLock {
                writeCount += 1
                entriesHistory.append(entries)
                guard writesToDrop == 0 else {
                    writesToDrop -= 1
                    return entries.count
                }
                for (key, value) in entries where DockPreferences.whitelistedKeys.contains(key) {
                    domain[key] = value
                }
                return entries.count
            }
        }

        var writes: Int { lock.withLock { writeCount } }
        var lastEntries: [String: PlistValue]? { lock.withLock { entriesHistory.last } }
        var allEntryKeys: Set<String> {
            lock.withLock { entriesHistory.reduce(into: Set<String>()) { $0.formUnion($1.keys) } }
        }
        var snapshot: [String: PlistValue] { lock.withLock { domain } }

        /// `mru-spaces` 是白名单之外的唯一例外，替身里照样只改这一个键。
        @discardableResult
        func writeMRUSpaces(_ enabled: Bool) -> Bool {
            lock.withLock { domain[DockPreferences.mruSpacesKey] = .bool(enabled) }
            return true
        }
    }

    /// 模拟 Dock 进程。
    private final class FakeDockProcess: DockProcessControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t?
        private var nextPID: pid_t = 1000
        /// 哪些信号能让 Dock 回来。空集合 = 发了信号也不回来（走兜底）。
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

    // MARK: - 夹具

    /// 照抄本机真实域的形状：**故意不含** `show-process-indicators` /
    /// `autohide-delay` / `autohide-time-modifier`（P0 实测，见 `docs/spikes.md`）。
    private func baseDomain() -> [String: PlistValue] {
        [
            "orientation": .string("bottom"),
            "tilesize": .double(36),
            "magnification": .bool(true),
            "largesize": .double(98),
            "autohide": .bool(false),
            "mineffect": .string("scale"),
            "minimize-to-application": .bool(true),
            "persistent-apps": .array([]),
            "persistent-others": .array([]),
            // 以下全是**非白名单**键，必须原样活着。
            "mru-spaces": .bool(true),
            "wvous-bl-corner": .int(0),
            "recent-apps": .array([]),
            "mod-count": .int(1234),
        ]
    }

    private func makeConfig(tilesize: Double = 48, apps: [String] = ["com.apple.Safari"]) -> DockConfig {
        var config = DockConfig()
        config.pinnedApps = apps.map {
            DockTile.makeFileTile(url: URL(fileURLWithPath: "/Applications/\($0).app"),
                                  label: $0, bundleIdentifier: $0)
        }
        config.appearance.tilesize = tilesize
        return config
    }

    private func makeController(
        preferences: FakePreferences,
        process: FakeDockProcess = FakeDockProcess(),
        backup: @escaping @MainActor () throws -> Void = {},
        onOutcome: @escaping @MainActor (DockController.Outcome) -> Void = { _ in }
    ) -> DockController {
        DockController(
            preferences: preferences,
            reloader: DockReloader(
                process: process,
                timeout: .milliseconds(300),
                pollInterval: .milliseconds(2),
                nudgeAfter: .seconds(60),   // 关掉"催 kickstart"，让信号策略本身可测
                fallbackGrace: .milliseconds(20),
                minimumSpacing: .zero,   // 测试不睡那 1 秒节流窗口
                kickstartTimeout: .milliseconds(300)
            ),
            backup: backup,
            onOutcome: onOutcome
        )
    }

    // MARK: - 短路

    func testSecondApplyOfSameContentSkipsEverything() async {
        let prefs = FakePreferences(domain: baseDomain())
        let process = FakeDockProcess()
        let controller = makeController(preferences: prefs, process: process)
        let config = makeConfig()

        let first = await controller.apply(config, reason: "第一次")
        let second = await controller.apply(config, reason: "第二次")

        XCTAssertEqual(first.result, .applied)
        XCTAssertEqual(second.result, .skippedIdentical)
        XCTAssertEqual(prefs.writes, 1, "内容相同必须一次都不写")
        XCTAssertEqual(process.signals.count, 1, "内容相同必须不重启 Dock（不闪屏）")
        XCTAssertEqual(second.writtenKeys, 0)
    }

    func testForceBypassesShortCircuit() async {
        let prefs = FakePreferences(domain: baseDomain())
        let controller = makeController(preferences: prefs)
        let config = makeConfig()

        _ = await controller.apply(config, reason: "第一次")
        let second = await controller.apply(config, reason: "强制", force: true)

        XCTAssertEqual(second.result, .applied)
        XCTAssertEqual(prefs.writes, 2, "force 必须绕过指纹短路")
    }

    func testAppearanceOnlyDifferenceIsNotShortCircuited() async {
        let prefs = FakePreferences(domain: baseDomain())
        let controller = makeController(preferences: prefs)

        _ = await controller.apply(makeConfig(tilesize: 36), reason: "36")
        let second = await controller.apply(makeConfig(tilesize: 64), reason: "64")

        XCTAssertEqual(second.result, .applied, "只改外观也必须重新应用")
    }

    /// 短路第 1b 条：**真实 Dock 已经就是这份内容**时必须跳过，哪怕 `appliedFingerprint` 是空的。
    ///
    /// 这是 P4 后真机验收挖出来的 bug（`DockAcceptanceTests.testExternalDockChangeIsCapturedBackToActiveDesktop`）：
    /// 旧的短路只比「我们上次写下去的那份」，一旦发生过外部改动（用户手拖、别的 App 改、回存）
    /// 它就过期了 —— 此时再应用一份与真实 Dock 完全相同的配置，会白写一遍 + 白重启一次 Dock。
    /// 实测桌面**有独立 Dock** 时回存会闪一下（PID 68667 → 68672，约 50 ms），而逐桌面 Dock 正是本 App 的常态用法。
    func testSkipsWhenLiveDockAlreadyMatchesDespiteStaleFingerprint() async {
        let prefs = FakePreferences(domain: baseDomain())
        let config = makeConfig()

        // 先把域写成 config 的样子，然后**丢掉这个控制器** —— 模拟"新建的控制器 / 别的组件"。
        let writer = makeController(preferences: prefs)
        let written = await writer.apply(config, reason: "先把它写下去")
        XCTAssertEqual(written.result, .applied)

        let process = FakeDockProcess()
        let fresh = makeController(preferences: prefs, process: process)
        XCTAssertNil(fresh.appliedFingerprint, "新控制器的指纹必须是空的，否则本用例根本没走到 1b")

        let writesBefore = prefs.writes
        let outcome = await fresh.apply(config, reason: "内容与真实 Dock 相同")

        XCTAssertEqual(outcome.result, .skippedIdentical)
        XCTAssertEqual(prefs.writes, writesBefore, "真实 Dock 已经是这份内容，一次都不该写")
        XCTAssertEqual(process.signals.count, 0, "必须不重启 Dock（不能闪屏）")
        XCTAssertEqual(outcome.writtenKeys, 0)
    }

    /// 1b 跳过后要把"此刻真实 Dock"记成已应用 —— 否则 `DockWatcher` 的回存闸门
    /// （`appliedComparableFingerprint != nil`）一直是关着的，用户手拖图标不会被回存。
    func testSkipAdoptsLiveDockSoWriteBackGateOpens() async {
        let prefs = FakePreferences(domain: baseDomain())
        let config = makeConfig()
        let writer = makeController(preferences: prefs)
        _ = await writer.apply(config, reason: "先把它写下去")

        let fresh = makeController(preferences: prefs)
        XCTAssertNil(fresh.appliedComparableFingerprint, "新控制器还没采纳过任何状态")

        let outcome = await fresh.apply(config, reason: "内容与真实 Dock 相同")

        XCTAssertEqual(outcome.result, .skippedIdentical)
        XCTAssertEqual(fresh.appliedComparableFingerprint, fresh.currentComparableFingerprint(),
                       "跳过后必须采纳真实 Dock 的指纹，否则回存闸门打不开")
    }

    /// 反向守卫：真实域与目标**不一致**时必须真的写、真的重启 —— 1b 不能把该写的也吞掉。
    func testDoesNotSkipWhenLiveDockDiffersFromConfig() async {
        let prefs = FakePreferences(domain: baseDomain())   // 域里 tilesize = 36
        let process = FakeDockProcess()
        let controller = makeController(preferences: prefs, process: process)

        let outcome = await controller.apply(makeConfig(tilesize: 64), reason: "域里是 36")

        XCTAssertEqual(outcome.result, .applied)
        XCTAssertEqual(prefs.writes, 1)
        XCTAssertEqual(process.signals.count, 1, "内容确实不同，必须真的重启 Dock")
    }

    /// `force` 必须同时绕过第 1 条与第 1b 条 —— 「立即应用」按钮不能被短路吃掉。
    func testForceBypassesLiveMatchShortCircuit() async {
        let prefs = FakePreferences(domain: baseDomain())
        let config = makeConfig()
        let writer = makeController(preferences: prefs)
        _ = await writer.apply(config, reason: "先把它写下去")

        let process = FakeDockProcess()
        let fresh = makeController(preferences: prefs, process: process)
        let outcome = await fresh.apply(config, reason: "强制", force: true)

        XCTAssertEqual(outcome.result, .applied)
        XCTAssertEqual(process.signals.count, 1, "force 必须真的重启 Dock")
    }

    // MARK: - 只写白名单

    func testOnlyWhitelistedKeysAreEverHandedToTheWriter() async {
        let prefs = FakePreferences(domain: baseDomain())
        let controller = makeController(preferences: prefs)

        _ = await controller.apply(makeConfig(), reason: "写入")

        let handed = prefs.allEntryKeys
        XCTAssertFalse(handed.isEmpty)
        XCTAssertTrue(handed.isSubset(of: DockPreferences.whitelistedKeys),
                      "交给写入层的键必须全部在白名单内，实际多出：\(handed.subtracting(DockPreferences.whitelistedKeys))")
    }

    func testNonWhitelistedKeysSurviveApply() async {
        let prefs = FakePreferences(domain: baseDomain())
        let controller = makeController(preferences: prefs)

        _ = await controller.apply(makeConfig(), reason: "写入")

        let after = prefs.snapshot
        XCTAssertEqual(after["mru-spaces"], .bool(true))
        XCTAssertEqual(after["wvous-bl-corner"], .int(0))
        XCTAssertEqual(after["mod-count"], .int(1234))
        XCTAssertEqual(after["recent-apps"], .array([]))
    }

    func testEntriesSkipKeysAbsentFromTheLiveDomain() {
        let config = makeConfig()
        let present: Set<String> = ["persistent-apps", "orientation", "tilesize"]

        let entries = DockController.entries(for: config, restrictedTo: present)

        XCTAssertEqual(Set(entries.keys), present)
        XCTAssertFalse(entries.keys.contains("show-process-indicators"))
    }

    func testMissingAppearanceKeysAreReportedAsSkippedNotWritten() async {
        var config = makeConfig()
        config.appearance.showProcessIndicators = true
        config.appearance.autohideDelay = 0.5

        let prefs = FakePreferences(domain: baseDomain())
        let controller = makeController(preferences: prefs)
        let outcome = await controller.apply(config, reason: "缺键")

        XCTAssertEqual(outcome.skippedKeys, ["show-process-indicators", "autohide-delay"],
                       "本机没有的键要如实报告，UI 才能把对应控件禁用掉")
        XCTAssertFalse(prefs.lastEntries?.keys.contains("show-process-indicators") ?? true)
        XCTAssertFalse(prefs.lastEntries?.keys.contains("autohide-delay") ?? true)
        XCTAssertTrue(outcome.succeeded, "缺几个外观键不该让整次应用失败")
    }

    /// `persistent-others` 走与 `persistent-apps` 完全相同的"域里没有就不写"规则。
    ///
    /// 这段补的是计划 §3.6 的一处缺口：其他项以前在编辑器里**完全看不见**，
    /// 现在能显示/排序/移除 —— 但绝不能凭空造条目（`docs/spikes.md` 实验 8）。
    func testEntriesSkipOtherItemsWhenTheKeyIsAbsentFromTheLiveDomain() {
        let config = makeConfig()
        let present: Set<String> = ["persistent-apps", "orientation", "tilesize"]

        let entries = DockController.entries(for: config, restrictedTo: present)

        XCTAssertFalse(entries.keys.contains("persistent-others"))
    }

    func testOtherItemsAreWrittenWhenTheKeyExists() async {
        var config = makeConfig()
        config.otherItems = [directoryTile("/Users/apple/Downloads", label: "下载")]
        let prefs = FakePreferences(domain: baseDomain())
        let controller = makeController(preferences: prefs)

        let outcome = await controller.apply(config, reason: "带其他项")

        XCTAssertEqual(outcome.result, .applied, outcome.summary)
        XCTAssertEqual(prefs.lastEntries?["persistent-others"]?.arrayValue?.count, 1)
        let live = DockConfig.read(from: prefs.readDomain()).otherItems
        XCTAssertEqual(live.map(\.label), ["下载"])
    }

    /// 其他项的夹具：形状照抄真实域里的「下载」目录条目（`file-type = 2`、`directory-tile`），
    /// 只是不带 Dock 自己补的 `GUID` / `book` / `*mod-date`。
    private func directoryTile(_ path: String, label: String) -> DockTile {
        DockTile(raw: [
            "tile-type": .string("directory-tile"),
            "tile-data": .dictionary([
                "file-data": .dictionary([
                    "_CFURLString": .string("file://\(path)/"),
                    "_CFURLStringType": .int(15),
                ]),
                "file-label": .string(label),
                "file-type": .int(2),
            ]),
        ])
    }

    func testPresentWhitelistedKeysReflectsTheLiveDomain() {
        let prefs = FakePreferences(domain: baseDomain())
        let controller = makeController(preferences: prefs)

        let keys = controller.presentWhitelistedKeys()

        XCTAssertTrue(keys.contains("tilesize"))
        XCTAssertFalse(keys.contains("show-process-indicators"))
        XCTAssertFalse(keys.contains("mru-spaces"))
    }

    // MARK: - 校验与重试

    func testRetriesOnceWhenDockDidNotTakeTheWrite() async {
        // 第一次写被"吞掉"，读回不一致 → 重试一次 → 成功。
        let prefs = FakePreferences(domain: baseDomain(), writesToDrop: 1)
        let process = FakeDockProcess()
        let controller = makeController(preferences: prefs, process: process)

        let outcome = await controller.apply(makeConfig(), reason: "重试")

        XCTAssertEqual(outcome.result, .applied)
        XCTAssertEqual(outcome.verifyAttempts, 2)
        XCTAssertEqual(prefs.writes, 2)
        XCTAssertEqual(process.signals.count, 2, "重试要连带重载一次")
    }

    func testFailsAfterTwoUnsuccessfulVerifications() async {
        let prefs = FakePreferences(domain: baseDomain(), writesToDrop: 99)
        let controller = makeController(preferences: prefs)

        let outcome = await controller.apply(makeConfig(), reason: "必败")

        XCTAssertEqual(outcome.result, .failed)
        XCTAssertEqual(outcome.verifyAttempts, 2, "最多重试一次，不无限重试")
        XCTAssertEqual(prefs.writes, 2)
        XCTAssertNil(controller.appliedFingerprint, "校验没过就不能记指纹，否则下次会被错误短路")
    }

    func testVerificationIgnoresKeysThatWereNotWritten() async {
        // 回归：曾经把"本机缺失的外观键"算进比对，导致明明写成功却判定失败。
        var config = makeConfig()
        config.appearance.showProcessIndicators = true
        config.appearance.autohideDelay = 0.25

        let prefs = FakePreferences(domain: baseDomain())
        let controller = makeController(preferences: prefs)
        let outcome = await controller.apply(config, reason: "缺键校验")

        XCTAssertEqual(outcome.result, .applied)
        XCTAssertEqual(outcome.verifyAttempts, 1, "缺键不该触发重试")
    }

    // MARK: - 失败与降级

    func testEmptyDomainFailsWithoutWriting() async {
        let prefs = FakePreferences(domain: [:])
        let process = FakeDockProcess()
        let controller = makeController(preferences: prefs, process: process)

        let outcome = await controller.apply(makeConfig(), reason: "读不到域")

        XCTAssertEqual(outcome.result, .failed)
        XCTAssertEqual(prefs.writes, 0)
        XCTAssertEqual(process.signals.count, 0, "读不到域就不该重启 Dock")
        XCTAssertTrue(outcome.reason.contains("读不到"))
    }

    func testBackupFailureIsNonFatalButReported() async {
        struct BackupFailed: LocalizedError {
            var errorDescription: String? { "磁盘满了" }
        }
        let prefs = FakePreferences(domain: baseDomain())
        let controller = makeController(preferences: prefs, backup: { throw BackupFailed() })

        let outcome = await controller.apply(makeConfig(), reason: "备份失败")

        XCTAssertEqual(outcome.result, .applied, "备份失败不该阻断应用（基准快照才是最后一道防线）")
        XCTAssertNotNil(outcome.note)
        XCTAssertTrue(outcome.note?.contains("磁盘满了") ?? false)
    }

    func testReloadFailureDoesNotCrashApply() async {
        // Dock 彻底拉不回来：应用流程要如实返回失败，而不是崩或者假装成功。
        let prefs = FakePreferences(domain: baseDomain())
        let process = FakeDockProcess(restartsOn: [], kickstartRestarts: false)
        let controller = makeController(preferences: prefs, process: process)

        let outcome = await controller.apply(makeConfig(), reason: "Dock 不回")

        XCTAssertEqual(outcome.result, .applied, "偏好已经写进去了，所以算应用成功")
        XCTAssertEqual(outcome.reload?.succeeded, false, "但重载失败必须如实上报")
        XCTAssertTrue(process.kickstartCount > 0, "必须走过 launchctl 兜底")
    }

    // MARK: - 防抖与合并

    func testRapidRequestsCollapseIntoOneApply() async {
        let prefs = FakePreferences(domain: baseDomain())
        let process = FakeDockProcess()
        let outcomes = Box<[DockController.Outcome]>([])
        let controller = makeController(
            preferences: prefs,
            process: process,
            onOutcome: { outcomes.value.append($0) }
        )

        controller.request(makeConfig(tilesize: 36), reason: "1", strategy: .auto)
        controller.request(makeConfig(tilesize: 48), reason: "2", strategy: .auto)
        controller.request(makeConfig(tilesize: 64), reason: "3", strategy: .auto)
        await controller.waitForIdle()

        XCTAssertEqual(prefs.writes, 1, "连击只对最终落点写一次")
        XCTAssertEqual(process.signals.count, 1)
        XCTAssertEqual(outcomes.value.map(\.reason), ["3"])
        XCTAssertEqual(prefs.lastEntries?["tilesize"], .double(64), "落点必须是最新那一次")
    }

    func testRequestArrivingDuringApplyIsRunAfterwards() async {
        // 应用 A 的过程中用户又改了 → 本轮结束后立刻补跑 B，不能丢。
        let prefs = FakePreferences(domain: baseDomain())
        let process = FakeDockProcess(restartDelayPolls: 40)   // 重启要"花时间"，制造窗口
        let outcomes = Box<[DockController.Outcome]>([])
        let controller = makeController(
            preferences: prefs,
            process: process,
            onOutcome: { outcomes.value.append($0) }
        )

        controller.request(makeConfig(tilesize: 36), reason: "A", strategy: .auto)
        // 让 drain 先跑起来并卡在重启等待里。
        try? await Task.sleep(for: .milliseconds(30))
        controller.request(makeConfig(tilesize: 64), reason: "B", strategy: .auto)
        await controller.waitForIdle()

        XCTAssertEqual(outcomes.value.map(\.reason), ["A", "B"])
        XCTAssertEqual(prefs.writes, 2)
        XCTAssertEqual(prefs.snapshot["tilesize"], .double(64), "最终落点必须是 B")
    }

    func testOutcomeIsDeliveredToTheCallback() async {
        let prefs = FakePreferences(domain: baseDomain())
        let outcomes = Box<[DockController.Outcome]>([])
        let controller = makeController(preferences: prefs, onOutcome: { outcomes.value.append($0) })

        controller.request(makeConfig(), reason: "回调", strategy: .auto)
        await controller.waitForIdle()

        XCTAssertEqual(outcomes.value.count, 1)
        XCTAssertEqual(outcomes.value.first?.result, .applied)
        XCTAssertEqual(outcomes.value.first?.writtenKeys, prefs.lastEntries?.count)
        XCTAssertNotNil(outcomes.value.first?.reload)
    }

    // MARK: - 结果描述

    func testOutcomeCarriesReloadDetailForLogging() async {
        let prefs = FakePreferences(domain: baseDomain())
        let process = FakeDockProcess()
        let controller = makeController(preferences: prefs, process: process)

        let outcome = await controller.apply(makeConfig(), reason: "日志")

        let reload = try? XCTUnwrap(outcome.reload)
        XCTAssertEqual(reload?.method, .sighup)
        XCTAssertEqual(reload?.oldPID, 100)
        XCTAssertNotNil(reload?.newPID)
        XCTAssertTrue(reload?.description.contains("SIGHUP") ?? false)
    }

    // MARK: - 退出流程专用的应用（`forQuit`）

    func testQuitApplyNeverRetriesAndNeverEscalates() async {
        // 常规路径是「写 → 重启 → 校验 → 不一致重试一次」。退出流程**不能**重试：
        // 每一发重启都是 launchd 退避的入口，真机 2026-09-19 一次退出因此耗掉 53–54 秒。
        // 换掉的只是"当场验一眼"，而偏好是原子落盘的，Dock 下次启动自然读到。
        let prefs = FakePreferences(domain: baseDomain(), writesToDrop: 99)
        let process = FakeDockProcess()
        let controller = makeController(preferences: prefs, process: process)

        let outcome = await controller.apply(makeConfig(), reason: "退出还原", forQuit: true)

        XCTAssertEqual(prefs.writes, 1, "退出路径一次都不许多写")
        XCTAssertEqual(process.signals, [SIGHUP], "不能升级到 SIGTERM")
        XCTAssertEqual(process.kickstartCount, 0, "不能动 launchctl")
        XCTAssertEqual(outcome.verifyAttempts, 1)
        XCTAssertEqual(outcome.result, .failed, "写被吞掉 → 校验不过，如实报失败但不重试")
        XCTAssertNil(controller.appliedFingerprint, "校验没过就不能记指纹")
        XCTAssertNotNil(outcome.quitRestart)
    }

    func testQuitApplyReportsHowTheRestartWasLeft() async {
        // 退出路径**不产出** `reload`（那是"跑完整条降级链"的结果），收场方式改由
        // `quitRestart` 带回去。摘要里必须看得见，否则日志上退出还原和正常还原长得一样。
        let prefs = FakePreferences(domain: baseDomain())
        let process = FakeDockProcess(pid: 4242)
        let controller = makeController(preferences: prefs, process: process)

        let outcome = await controller.apply(makeConfig(), reason: "退出还原", forQuit: true)

        XCTAssertNil(outcome.reload, "退出路径不该有一次跑完整条 ladder 的 reload")
        guard let restart = outcome.quitRestart else {
            XCTFail("退出路径必须带回收场方式")
            return
        }
        switch restart {
        case let .revived(oldPID, newPID, _):
            XCTAssertEqual(oldPID, 4242)
            XCTAssertNotEqual(oldPID, newPID)
        case .signaled, .dockWasDown, .notDelivered:
            XCTFail("替身的 Dock 对 SIGHUP 有反应，应该是 .revived，实得 \(restart.description)")
        }
        XCTAssertTrue(outcome.summary.contains("SIGHUP 成功"), outcome.summary)
    }

    // MARK: - 带上限的等待（退出流程）

    func testWaitForIdleReportsTimeout() async {
        // `waitForIdle(upTo:)` 返回 false 时调用方**必须**当成"没干净"处理：
        // 那笔在飞的写入可能落在我们的还原之后。
        let prefs = FakePreferences(domain: baseDomain())
        let process = FakeDockProcess(pid: 100, restartsOn: [], kickstartRestarts: false)
        let controller = makeController(preferences: prefs, process: process)

        controller.request(makeConfig(tilesize: 60), reason: "在飞", strategy: .auto)
        let started = ContinuousClock.now
        let settled = await controller.waitForIdle(upTo: .milliseconds(20))
        let elapsed = started.duration(to: ContinuousClock.now)
        XCTAssertFalse(settled, "降级链要几百毫秒，20 ms 上限必须报超时")
        XCTAssertTrue(controller.isApplying)
        // ⚠️ 这条才是"上限真的存在"的守卫。只断言上面那个 Bool 发现不了
        // `withTaskGroup` 那个静默失效的写法 —— 它会等完整条 ladder 再返回 false，
        // 于是"2 秒上限"实际是几十秒（2026-09-19 退出卡住的根因）。
        XCTAssertLessThan(elapsed, .milliseconds(200), "上限 20 ms 不该等完整条降级链，实得 \(elapsed)")

        await controller.waitForIdle()
        let settledAfterwards = await controller.waitForIdle(upTo: .milliseconds(20))
        XCTAssertTrue(settledAfterwards, "跑完之后同样的上限就该报干净")
    }

    func testDropPendingRequestsSkipsWorkThatNeverStarted() async {
        // 还没起跑的待办可以直接丢（它的目标马上会被"还原到基准"取代）。
        let prefs = FakePreferences(domain: baseDomain())
        let controller = makeController(preferences: prefs)

        controller.request(makeConfig(tilesize: 60), reason: "排队", strategy: .auto)
        controller.dropPendingRequests()
        await controller.waitForIdle()

        XCTAssertEqual(prefs.writes, 0, "丢掉之后那笔绝不能落地")
        XCTAssertFalse(controller.isApplying)
    }
}

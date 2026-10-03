import XCTest
@testable import MultiDock

/// P4：无痕与自愈。
///
/// 覆盖真实使用里最容易出事、又最难复现的三件事：
/// 1. **强杀/崩溃后的启动自愈** —— 残留会话标记 → 启动后自动把基准写回真实 Dock；
/// 2. **退出还原的兜底** —— 还原没成功时会话标记必须留着，交给下次启动自愈；
/// 3. **白名单之外的两个例外**（`mru-spaces` 与备份恢复）不许越界写别的键。
///
/// 全部用替身，不会真的写用户的 Dock。真实 Dock 上的自愈验收在 `DockAcceptanceTests`。
@MainActor
final class StartupSelfHealTests: XCTestCase {

    // MARK: - 夹具

    /// 一个可控的「真实 Dock 现状」。
    ///
    /// 刻意带上白名单外的键（`wvous-br-corner` / `mod-count`），
    /// 这样"备份恢复只写白名单键"才有东西可断言。
    private static func liveDomain(tilesize: Double) -> [String: PlistValue] {
        [
            "orientation": .string("bottom"),
            "tilesize": .double(tilesize),
            "magnification": .bool(false),
            "persistent-apps": .array([]),
            "persistent-others": .array([]),
            "mru-spaces": .bool(true),
            "wvous-br-corner": .int(7),
            "mod-count": .int(22_538),
        ]
    }

    private struct Fixture {
        let state: AppState
        let preferences: FakePreferences
        let baselineStore: BaselineStore
        let directory: URL
    }

    private func makeFixture(
        name: String,
        live: [String: PlistValue]? = nil,
        baseline: [String: PlistValue]? = nil,
        marker: BaselineStore.SessionMarker? = nil
    ) throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-selfheal-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let baselineStore = BaselineStore(
            baselineURL: directory.appendingPathComponent("baseline.plist"),
            markerURL: directory.appendingPathComponent("session.state"),
            backupsURL: directory.appendingPathComponent("backups", isDirectory: true)
        )
        if let baseline { try Self.writePlist(baseline, to: baselineStore.baselineURL) }
        if let marker { try baselineStore.writeSessionMarker(marker) }

        let preferences = FakePreferences(domain: live ?? Self.liveDomain(tilesize: 64))
        let state = AppState(
            dockController: DockController(
                preferences: preferences,
                reloader: DockReloader(
                    process: FakeDockProcess(),
                    timeout: .milliseconds(200),
                    pollInterval: .milliseconds(2),
                    fallbackGrace: .milliseconds(20),
                    minimumSpacing: .zero   // 测试不睡那 1 秒节流窗口
                ),
                backup: {}
            ),
            configStore: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            baselineStore: baselineStore,
            provider: FakeSpaceProvider(isAvailable: false, reason: "测试替身"),
            // 真的监视器会去问系统的 Dock 进程；测试里换成替身。
            presenceMonitor: DockPresenceMonitor(
                process: FakeDockProcess(),
                pollInterval: .seconds(60)
            ),
            fileLog: makeTestFileLog()
        )
        // 冻结是产品默认值；自愈用例测的是还原链路本身，按「未冻结」跑。
        state.updateSettings { $0.freezeNativeDockSwitching = false }
        return Fixture(
            state: state,
            preferences: preferences,
            baselineStore: baselineStore,
            directory: directory
        )
    }

    private static func writePlist(_ domain: [String: PlistValue], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = domain.mapValues(\.anyValue)
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// 一个"上次被强杀"的残留标记。
    private func staleMarker(fingerprint: String? = "dirty-fingerprint") -> BaselineStore.SessionMarker {
        BaselineStore.SessionMarker(
            pid: 999_999,          // 一定不存在的 PID：`detectInterruptedSession` 会当成残留
            startedAt: Date(timeIntervalSinceNow: -3600),
            appliedFingerprint: fingerprint,
            appliedAt: Date(timeIntervalSinceNow: -3600)
        )
    }

    private func config(tilesize: Double = 52) -> DockConfig {
        var config = DockConfig()
        config.appearance.tilesize = tilesize
        config.pinnedApps = DockStripRules.normalizedApps([
            DockTile.makeFileTile(
                url: URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true),
                label: "Safari",
                bundleIdentifier: "com.apple.Safari"
            ),
        ])
        return config
    }

    // MARK: - 启动自愈

    func testStartupSelfHealRestoresBaseline() async throws {
        let baseline = Self.liveDomain(tilesize: 36)
        let fixture = try makeFixture(
            name: "restore",
            live: Self.liveDomain(tilesize: 64),    // 上次被写成了 64
            baseline: baseline,                     // 基准是 36
            marker: staleMarker()
        )
        fixture.state.start()
        defer { fixture.state.stop() }

        XCTAssertTrue(fixture.state.hasPendingSelfHeal, "启动自检应认出欠着一次自愈")
        XCTAssertEqual(fixture.state.interruptedSession?.pid, 999_999)

        await fixture.state.waitForSelfHeal()

        XCTAssertEqual(fixture.preferences.snapshot["tilesize"]?.doubleValue, 36,
                       "自愈必须把基准的 tilesize 写回去")
        XCTAssertEqual(fixture.state.selfHealSummary, "已自动还原上次未还原的 Dock")
        XCTAssertEqual(fixture.preferences.writeCount, 1, "只该写一次")
        XCTAssertTrue(fixture.state.log.contains { $0.message.contains("自愈还原完成") })
    }

    func testStartupSelfHealSkipsWhenAlreadyAtBaseline() async throws {
        // 上次虽然被强杀，但 Dock 其实已经在基准状态（例如用户手动还原过）。
        let baseline = Self.liveDomain(tilesize: 36)
        let fixture = try makeFixture(
            name: "already-clean",
            live: baseline,
            baseline: baseline,
            marker: staleMarker()
        )
        fixture.state.start()
        defer { fixture.state.stop() }

        await fixture.state.waitForSelfHeal()

        XCTAssertEqual(fixture.preferences.writeCount, 0, "已经一致就不该写、更不该重启 Dock")
        XCTAssertEqual(fixture.state.selfHealSummary, "Dock 已与原始状态一致，无需还原")
    }

    func testMarkerWithoutDirtyFlagDoesNotTriggerHeal() async throws {
        // 残留标记但上次没改过 Dock —— 绝不能去"还原"，那会把用户自己的改动抹掉。
        let fixture = try makeFixture(
            name: "clean-marker",
            live: Self.liveDomain(tilesize: 64),
            baseline: Self.liveDomain(tilesize: 36),
            marker: staleMarker(fingerprint: nil)
        )
        fixture.state.start()
        defer { fixture.state.stop() }

        XCTAssertFalse(fixture.state.hasPendingSelfHeal)
        await fixture.state.waitForSelfHeal()

        XCTAssertNil(fixture.state.selfHealSummary)
        XCTAssertEqual(fixture.preferences.writeCount, 0)
        XCTAssertTrue(fixture.state.log.contains { $0.message.contains("上次未改动过 Dock") })
    }

    func testInheritedSelfHealDebtTriggersHeal() async throws {
        // 上次启动继承了自愈债务、还没还完就又挂了：标记里只有 needsSelfHeal。
        let fixture = try makeFixture(
            name: "debt",
            live: Self.liveDomain(tilesize: 64),
            baseline: Self.liveDomain(tilesize: 36),
            marker: BaselineStore.SessionMarker(
                pid: 999_999,
                startedAt: Date(timeIntervalSinceNow: -60),
                needsSelfHeal: true
            )
        )
        fixture.state.start()
        defer { fixture.state.stop() }

        XCTAssertTrue(fixture.state.hasPendingSelfHeal, "继承来的债务也要触发自愈")
        await fixture.state.waitForSelfHeal()

        XCTAssertEqual(fixture.preferences.snapshot["tilesize"]?.doubleValue, 36)
    }

    func testHealFailsGracefullyWithoutUsableBaseline() async throws {
        // 基准快照坏了（磁盘错误、手改坏了）。不能崩，也不能瞎写 —— 记一条明确的错误。
        //
        // 注意这里写的是**损坏的**基准文件而不是不写：`runStartupSelfCheck` 在基准不存在时
        // 会立刻从当前 Dock 抓一份新的（首次运行逻辑），所以"没有基准文件"这个状态在
        // App 里根本到不了自愈那一步。真正会出问题的是"文件在、但读不出内容"。
        let fixture = try makeFixture(
            name: "bad-baseline",
            live: Self.liveDomain(tilesize: 64),
            marker: staleMarker()
        )
        try Data("这不是一个 plist".utf8).write(to: fixture.baselineStore.baselineURL)

        fixture.state.start()
        defer { fixture.state.stop() }

        await fixture.state.waitForSelfHeal()

        XCTAssertEqual(fixture.state.selfHealSummary, "自愈还原失败（读不到基准快照）")
        XCTAssertEqual(fixture.preferences.writeCount, 0, "基准读不出来就什么都别写")
        XCTAssertTrue(fixture.state.log.contains { $0.message.contains("读不到基准快照") })
    }

    // MARK: - 退出前收尾：丢掉未起跑的待办，只等有限久

    func testPrepareForTerminationDropsQueuedApply() async throws {
        // 语义在 2026-09-19 改过。旧版是「排队的应用必须在还原之前落地」，
        // 担忧仍然成立（那笔待办会在还原**之后**把 Dock 弄脏），但解法换了：
        // 紧接着的「还原到基准」**就是**最终目标，那笔待办的目标已被取代 —— 等它毫无意义，
        // 而代价可能很大：一次在飞的应用最坏要走完整条降级链（真机实测 53–54 秒）。
        // 所以现在：未起跑的**直接丢**，已经起跑的**只等 `settleLimit`**，等不到就留标记。
        let fixture = try makeFixture(name: "drop-pending", baseline: Self.liveDomain(tilesize: 36))
        fixture.state.start()
        defer { fixture.state.stop() }

        fixture.state.updateSettings { $0.defaultDock = self.config(tilesize: 52) }
        fixture.state.applyDefaultDock()
        // `request()` 是同步建任务的，所以这里写盘还没发生。
        XCTAssertEqual(fixture.preferences.writeCount, 0)
        XCTAssertTrue(fixture.state.dockController.isApplying, "前面那句必须真的排上了一笔待办")

        let settled = await fixture.state.prepareForTermination()

        XCTAssertTrue(settled, "没有卡在飞行中的应用时，收尾必须报告干净")
        XCTAssertEqual(fixture.preferences.writeCount, 0,
                       "未起跑的待办必须丢掉：它一旦落地就会在还原之后把 Dock 又弄脏")
        XCTAssertEqual(fixture.state.dockWatcher?.isRunning, false)
        XCTAssertEqual(fixture.state.dockPresenceMonitor?.isRunning, false)
    }

    func testQuitRestoreWritesOnceAndReadsBackTheBaseline() async throws {
        // 退出这条路（`forQuit`）与手动「立即还原」的唯一区别是重启怎么收场：
        // 写完偏好、发一发 SIGHUP、最多看一眼就返回。写入本身照旧。
        let fixture = try makeFixture(
            name: "quit-restore",
            live: Self.liveDomain(tilesize: 64),
            baseline: Self.liveDomain(tilesize: 36)
        )
        fixture.state.start()
        defer { fixture.state.stop() }

        let restored = await fixture.state.restoreToBaseline(forQuit: true)
        let outcome = try XCTUnwrap(restored)

        XCTAssertEqual(fixture.preferences.snapshot["tilesize"]?.doubleValue, 36)
        XCTAssertEqual(fixture.preferences.writeCount, 1, "退出还原只写一次，不重试")
        XCTAssertEqual(outcome.result, .applied)
        let restart = try XCTUnwrap(outcome.quitRestart, "退出路径必须带回收场方式，日志要靠它")
        switch restart {
        case let .revived(oldPID, newPID, _):
            XCTAssertNotEqual(oldPID, newPID, "SIGHUP 之后确实换了一个 Dock 进程")
        default:
            XCTFail("替身的 Dock 对 SIGHUP 有反应，应该是 .revived，实得 \(restart.description)")
        }
    }

    func testPrepareForTerminationReportsUnsettledWhenAnApplyIsTooSlow() async throws {
        // 已经起跑的那一笔如果超过上限，`prepareForTermination` 必须**如实返回 false** ——
        // 它可能在我们之后又写一次，调用方（`LifecycleController`）据此留下会话标记。
        //
        // 这里用 `reloadStrategy = .sigterm` 让它必然慢：替身的 Dock 只对 SIGHUP 有反应，
        // 于是这条降级链要等完 `timeout` + `fallbackGrace` 才靠 kickstart 收场（约 220 ms），
        // 而上限只给 20 ms。
        let fixture = try makeFixture(name: "unsettle", baseline: Self.liveDomain(tilesize: 36))
        fixture.state.start()
        defer { fixture.state.stop() }

        fixture.state.updateSettings {
            $0.defaultDock = self.config(tilesize: 52)
            $0.reloadStrategy = .sigterm
        }
        fixture.state.applyDefaultDock()
        // 让那笔应用真的起跑（跑到降级链里等着），才谈得上"在飞"。
        // 不 yield 的话它还躺在 pending 里，会被上界之外的第一步直接丢掉。
        await Task.yield()
        XCTAssertTrue(fixture.state.dockController.isApplying)

        let settled = await fixture.state.prepareForTermination(settleLimit: .milliseconds(20))

        XCTAssertFalse(settled, "应用还在飞时不能报告干净")
        XCTAssertEqual(fixture.state.dockWatcher?.isRunning, false, "即使没等完，两个监视器也必须先停")
        XCTAssertEqual(fixture.state.dockPresenceMonitor?.isRunning, false)

        // 收尾：让那笔应用在测试结束前自己落地，别留一个还在写的后台任务。
        await fixture.state.dockController.waitForIdle()
        XCTAssertEqual(fixture.preferences.writeCount, 1)
    }

    func testPrepareForTerminationBoundsTheSelfHealWait() async throws {
        // 自愈那一笔同样受上限约束 —— 而且**上限必须是真的上限**。
        //
        // 原先 `settle` 用 `withTaskGroup` 让 `await task.value` 和 `Task.sleep` 赛跑，
        // 但任务组在闭包返回时会等所有子任务收尾，而 `await task.value` 对取消毫无反应：
        // 于是"20 ms"实际等成了整条降级链，`prepareForTermination` 的 2 秒上限形同虚设
        // （2026-09-19 退出卡住几十秒的形状）。所以这里断言的是**墙钟**，不只看返回值。
        let fixture = try makeFixture(
            name: "selfheal-bound",
            live: Self.liveDomain(tilesize: 64),      // 与基准不一致 → 自愈真的会写
            baseline: Self.liveDomain(tilesize: 36),
            marker: staleMarker()
        )
        fixture.state.start()
        defer { fixture.state.stop() }
        // 让替身的 Dock 对我们的信号没反应（它只对 SIGHUP 动），自愈因此要走完整条降级链。
        fixture.state.updateSettings { $0.reloadStrategy = .sigterm }
        await Task.yield()

        let started = ContinuousClock.now
        let settled = await fixture.state.prepareForTermination(settleLimit: .milliseconds(20))
        let elapsed = started.duration(to: ContinuousClock.now)

        XCTAssertFalse(settled, "自愈还在飞时不能报告干净")
        XCTAssertLessThan(elapsed, .milliseconds(200), "上限 20 ms 不该等完自愈的降级链，实得 \(elapsed)")

        await fixture.state.waitForSelfHeal()
        XCTAssertEqual(fixture.preferences.snapshot["tilesize"]?.doubleValue, 36,
                       "等完之后自愈该把基准写回去")
    }

    // MARK: - 退出还原失败时的标记留存

    func testFailedRestoreKeepsMarkerAsInactiveSession() async throws {
        let fixture = try makeFixture(
            name: "quit-fail",
            live: Self.liveDomain(tilesize: 64),
            baseline: Self.liveDomain(tilesize: 36)
        )
        let lifecycle = LifecycleController(state: fixture.state, baselineStore: fixture.baselineStore)
        lifecycle.finishTermination = {}      // 测试进程没有真的在退出
        lifecycle.applicationDidFinishLaunching()
        lifecycle.restoreHandler = { nil }    // 模拟还原失败
        lifecycle.noteDockApplied(fingerprint: "fp-dirty")

        XCTAssertFalse(lifecycle.shouldTerminate(), "还原没完成前必须挂起退出")
        await lifecycle.waitForTermination()

        let kept = try XCTUnwrap(fixture.baselineStore.readSessionMarker(),
                                 "还原失败时标记必须留着，否则下次启动不会自愈")
        XCTAssertTrue(kept.impliesDirtyDock)
        XCTAssertEqual(kept.pid, 0, "留下的标记要标成非活动会话，否则下次启动会被当成还活着的实例忽略掉")
        XCTAssertEqual(kept.needsSelfHeal, true)
        XCTAssertTrue(fixture.state.log.contains { $0.message.contains("下次启动会自动重试") })
    }

    func testNextLaunchPicksUpTheKeptMarkerAndHeals() async throws {
        // 接着上一幕：还原失败留下了标记，新一次启动必须认出它并把 Dock 拉回基准。
        let fixture = try makeFixture(
            name: "retry",
            live: Self.liveDomain(tilesize: 64),
            baseline: Self.liveDomain(tilesize: 36)
        )
        let lifecycle = LifecycleController(state: fixture.state, baselineStore: fixture.baselineStore)
        lifecycle.finishTermination = {}
        lifecycle.applicationDidFinishLaunching()
        lifecycle.restoreHandler = { nil }
        lifecycle.noteDockApplied(fingerprint: "fp-dirty")
        _ = lifecycle.shouldTerminate()
        await lifecycle.waitForTermination()

        // 新一次启动：pid 为 0 的标记必须被当成残留（不能因为"进程还活着"被忽略）。
        let stale = try XCTUnwrap(fixture.baselineStore.detectInterruptedSession())
        XCTAssertEqual(stale.needsSelfHeal, true)

        await fixture.state.performSelfHeal(stale)

        XCTAssertEqual(fixture.preferences.snapshot["tilesize"]?.doubleValue, 36)
        XCTAssertEqual(fixture.state.selfHealSummary, "已自动还原上次未还原的 Dock")
    }

    func testSuccessfulRestoreClearsMarker() async throws {
        let baseline = Self.liveDomain(tilesize: 36)
        let fixture = try makeFixture(name: "quit-ok", live: baseline, baseline: baseline)
        let lifecycle = LifecycleController(state: fixture.state, baselineStore: fixture.baselineStore)
        lifecycle.finishTermination = {}
        lifecycle.applicationDidFinishLaunching()
        lifecycle.restoreHandler = { await fixture.state.restoreToBaseline() }
        lifecycle.noteDockApplied(fingerprint: "fp-1")

        XCTAssertFalse(lifecycle.shouldTerminate())
        await lifecycle.waitForTermination()

        XCTAssertNil(fixture.baselineStore.readSessionMarker(),
                     "还原成功后标记要清掉，否则每次启动都会白跑一次自愈")
    }

    // MARK: - mru-spaces（白名单之外的例外之一）

    func testSetMRUSpacesWritesOnlyThatKey() async throws {
        let fixture = try makeFixture(name: "mru", baseline: Self.liveDomain(tilesize: 36))
        fixture.state.start()
        defer { fixture.state.stop() }

        XCTAssertEqual(fixture.state.mruSpaces, true, "本机默认是开的")
        let whitelistWritesBefore = fixture.preferences.writeCount

        fixture.state.setMRUSpaces(false)

        XCTAssertEqual(fixture.preferences.mruWrites, 1)
        XCTAssertEqual(fixture.preferences.snapshot["mru-spaces"], .bool(false))
        XCTAssertEqual(fixture.state.mruSpaces, false)
        XCTAssertEqual(fixture.preferences.writeCount, whitelistWritesBefore,
                       "改 mru-spaces 不该顺手把白名单键重写一遍")
    }

    func testMRUSpacesIsNilWhenKeyIsMissing() async throws {
        var domain = Self.liveDomain(tilesize: 36)
        domain.removeValue(forKey: DockPreferences.mruSpacesKey)
        let fixture = try makeFixture(name: "mru-missing", live: domain, baseline: domain)
        fixture.state.start()
        defer { fixture.state.stop() }

        XCTAssertNil(fixture.state.mruSpaces, "域里没这个键就该是 nil，UI 据此禁用开关而不是做个假开关")
    }

    // MARK: - 备份恢复

    func testRestoreBackupWritesOnlyWhitelistedKeys() async throws {
        let fixture = try makeFixture(name: "backup", baseline: Self.liveDomain(tilesize: 36))
        fixture.state.start()
        defer { fixture.state.stop() }

        // 备份里故意混进白名单之外的键：它们**绝不能**被写回去。
        let tile = DockTile.makeFileTile(
            url: URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true),
            label: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let backup: [String: PlistValue] = [
            "tilesize": .double(44),
            "persistent-apps": .array([.dictionary(tile.raw)]),
            "persistent-others": .array([]),
            "wvous-br-corner": .int(99),
            "recent-apps": .array([]),
        ]
        try Self.writePlist(
            backup,
            to: fixture.baselineStore.backupsURL.appendingPathComponent("dock-20260918-010203.plist")
        )

        fixture.state.refreshBackups()
        XCTAssertEqual(fixture.state.backups.count, 1)
        let entry = try XCTUnwrap(fixture.state.backups.first)
        XCTAssertEqual(entry.fileName, "dock-20260918-010203.plist")

        fixture.state.restoreBackup(entry)
        await fixture.state.dockController.waitForIdle()

        XCTAssertEqual(fixture.preferences.snapshot["tilesize"]?.doubleValue, 44)
        XCTAssertEqual(fixture.preferences.snapshot["wvous-br-corner"], .int(7),
                       "白名单外的键绝不能被备份覆盖")
        XCTAssertEqual(fixture.preferences.snapshot["mod-count"], .int(22_538),
                       "Dock 自己的计数器也不能被备份覆盖")
    }

    func testRestoreBackupRefusesCorruptFile() async throws {
        let fixture = try makeFixture(name: "backup-bad", baseline: Self.liveDomain(tilesize: 36))
        fixture.state.start()
        defer { fixture.state.stop() }

        let bad = fixture.baselineStore.backupsURL.appendingPathComponent("dock-20260918-020304.plist")
        try FileManager.default.createDirectory(
            at: fixture.baselineStore.backupsURL,
            withIntermediateDirectories: true
        )
        try Data("这不是一个 plist".utf8).write(to: bad)

        fixture.state.refreshBackups()
        let entry = try XCTUnwrap(fixture.state.backups.first)
        fixture.state.restoreBackup(entry)
        await fixture.state.dockController.waitForIdle()

        XCTAssertEqual(fixture.preferences.writeCount, 0, "坏备份绝不能写进 Dock")
        XCTAssertTrue(fixture.state.log.contains { $0.message.contains("读不出来或已损坏") })
    }

    func testBackupListIsNewestFirst() async throws {
        let fixture = try makeFixture(name: "backup-order", baseline: Self.liveDomain(tilesize: 36))
        for name in ["dock-20260101-120000.plist", "dock-20260918-090000.plist", "dock-20260315-080000.plist"] {
            try Self.writePlist(["tilesize": .double(40)], to: fixture.baselineStore.backupsURL.appendingPathComponent(name))
        }

        fixture.state.refreshBackups()

        XCTAssertEqual(fixture.state.backups.map(\.fileName), [
            "dock-20260918-090000.plist",
            "dock-20260315-080000.plist",
            "dock-20260101-120000.plist",
        ])
    }
}

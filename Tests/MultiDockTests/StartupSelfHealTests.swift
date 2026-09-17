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
            )
        )
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

    // MARK: - 退出前等待待办清空

    func testPrepareForTerminationWaitsForPendingApply() async throws {
        let fixture = try makeFixture(name: "drain", baseline: Self.liveDomain(tilesize: 36))
        fixture.state.start()
        defer { fixture.state.stop() }

        fixture.state.updateSettings { $0.defaultDock = self.config(tilesize: 52) }
        fixture.state.applyDefaultDock()
        // `request()` 是同步建任务的，所以这里写盘还没发生。
        XCTAssertEqual(fixture.preferences.writeCount, 0)

        await fixture.state.prepareForTermination()

        XCTAssertEqual(fixture.preferences.writeCount, 1,
                       "排队的应用必须在退出还原之前落地，否则它会在还原之后把 Dock 又弄脏")
        XCTAssertEqual(fixture.state.dockWatcher?.isRunning, false)
        XCTAssertEqual(fixture.state.dockPresenceMonitor?.isRunning, false)
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

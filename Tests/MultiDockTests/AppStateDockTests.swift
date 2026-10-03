import XCTest
@testable import MultiDock

/// `AppState` 里「Dock 应用」这条路径 —— 也就是设置页那几个按钮点下去会发生什么。
///
/// 用测试替身替代真实偏好域与真实 Dock 进程，所以不会动用户的 Dock。
/// 真实写入链路由 `DockAcceptanceTests`（需显式开启）覆盖。
@MainActor
final class AppStateDockTests: XCTestCase {

    // 偏好域替身 `FakePreferences` 已移到 `TestSupport.swift`（`StartupSelfHealTests` 共用）。

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
            "mru-spaces": .bool(true),
            "mod-count": .int(1),
        ]
    }

    /// 每个测试一个独立目录，避免互相踩。
    private func makeStores(_ name: String) -> (ConfigStore, BaselineStore) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            BaselineStore(
                baselineURL: directory.appendingPathComponent("baseline.plist"),
                markerURL: directory.appendingPathComponent("session.state"),
                backupsURL: directory.appendingPathComponent("backups", isDirectory: true)
            )
        )
    }

    private func makeState(
        preferences: FakePreferences,
        process: FakeDockProcess = FakeDockProcess(),
        stores: (ConfigStore, BaselineStore),
        provider: FakeSpaceProvider? = nil
    ) -> AppState {
        // 注意：这里**不能**顺手 updateSettings（那会立刻落盘），否则
        // 「不落盘」断言与预置 config 的用例会被污染。要走逐桌面应用路径的用例，
        // 在 start() 后自行调 `unfreeze(_:)`。
        AppState(
            dockController: DockController(
                preferences: preferences,
                reloader: DockReloader(
                    process: process,
                    timeout: .milliseconds(200),
                    pollInterval: .milliseconds(2),
                    fallbackGrace: .milliseconds(20),
                    minimumSpacing: .zero   // 测试不睡那 1 秒节流窗口
                ),
                backup: {}
            ),
            configStore: stores.0,
            baselineStore: stores.1,
            // 默认给一个"私有 API 不可用"的提供者：这些用例大多不关心桌面切换，
            // 换成假的可以避免测试去读真实显示器上的桌面。
            provider: provider ?? FakeSpaceProvider(isAvailable: false, reason: "测试替身"),
            fileLog: makeTestFileLog()
        )
    }

    /// 冻结自 2026-10-04 起是产品默认值；要走逐桌面应用路径的用例在 start() 后调它。
    /// 只在确实要测「切换会应用 Dock」的用例里用 —— 别摊回 makeState。
    private func unfreeze(_ state: AppState) {
        state.updateSettings { $0.freezeNativeDockSwitching = false }
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

    // MARK: - 能力探测

    func testStartupReportsUnavailableAppearanceKeys() {
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("caps"))
        state.start()
        defer { state.stop() }

        // 域里没有 show-process-indicators；autohide-delay / autohide-time-modifier
        // 读回来是 nil，压根不进 domainEntries，所以不算"缺失"。
        XCTAssertEqual(state.unavailableAppearanceKeys, ["show-process-indicators"])
        XCTAssertTrue(state.availableWhitelistedKeys.contains("tilesize"))
        XCTAssertFalse(state.availableWhitelistedKeys.contains("mru-spaces"))
    }

    // MARK: - 立即应用

    func testApplyRefusesEmptyDefaultDock() async {
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("empty"))
        state.start()
        defer { state.stop() }

        state.applyDefaultDock()
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.writeCount, 0, "默认 Dock 是空的就绝不能写 —— 那会把 Dock 清空")
        XCTAssertTrue(state.log.contains { $0.message.contains("默认 Dock 还是空的") })
        XCTAssertFalse(state.hasAppliedDockConfig)
    }

    func testApplyWritesAndMarksSessionDirty() async {
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("apply"))
        state.start()
        defer { state.stop() }

        state.setDefaultDock(config(tilesize: 52))
        state.applyDefaultDock()
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.writeCount, 1)
        XCTAssertEqual(preferences.lastEntries?["tilesize"], .double(52))
        XCTAssertTrue(state.hasAppliedDockConfig)
        XCTAssertTrue(state.lastApplySummary.contains("applied"))
        XCTAssertTrue(state.log.contains { $0.message.hasPrefix("Dock 应用成功") })
    }

    func testApplyNotifiesLifecycleWithFingerprint() async {
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("notify"))
        state.start()
        defer { state.stop() }

        let reported = Box<[String]>([])
        state.onDockApplied = { reported.value.append($0) }

        state.setDefaultDock(config())
        state.applyDefaultDock()
        await state.dockController.waitForIdle()

        XCTAssertEqual(reported.value, [config().fingerprint],
                       "会话标记要拿到指纹，否则强杀自愈无法判断 Dock 是否被改过")
    }

    func testRepeatedApplyOfIdenticalContentDoesNotTouchDockAgain() async {
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("idem"))
        state.start()
        defer { state.stop() }

        state.setDefaultDock(config())
        state.applyDefaultDock()
        await state.dockController.waitForIdle()
        state.applyDefaultDock()
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.writeCount, 1, "第二次内容相同必须短路")
        XCTAssertTrue(state.log.contains { $0.message.contains("内容与当前一致") })
    }

    // MARK: - 编辑后立即应用

    func testEditAppliesWhenAutoApplyIsOn() async {
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("auto-on"))
        state.start()
        defer { state.stop() }

        state.setDefaultDock(config(tilesize: 64))
        state.dockConfigEdited(reason: "测试改动")
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.writeCount, 1)
        XCTAssertEqual(preferences.lastEntries?["tilesize"], .double(64))
    }

    func testEditDoesNotApplyWhenAutoApplyIsOff() async {
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("auto-off"))
        state.start()
        defer { state.stop() }

        state.updateSettings { $0.autoApplyOnEdit = false }
        state.setDefaultDock(config(tilesize: 64))
        state.dockConfigEdited(reason: "测试改动")
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.writeCount, 0, "关掉开关就只改本地配置，不碰 Dock")
        XCTAssertTrue(state.log.contains { $0.message.contains("改动只存在本地配置里") })
    }

    // MARK: - 落盘时机

    func testSetDefaultDockDoesNotPersistByItself() throws {
        // 拖拽排序的每一次 dropEntered 都会走 setDefaultDock；它不该写盘。
        let stores = makeStores("nopersist")
        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: stores)
        state.start()
        defer { state.stop() }

        state.setDefaultDock(config(tilesize: 64))

        XCTAssertFalse(FileManager.default.fileExists(atPath: stores.0.fileURL.path),
                       "setDefaultDock 不该落盘")
    }

    func testDockConfigEditedPersistsOnce() throws {
        let stores = makeStores("persist")
        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: stores)
        state.start()
        defer { state.stop() }

        state.setDefaultDock(config(tilesize: 64))
        state.dockConfigEdited(reason: "落盘")

        let data = try Data(contentsOf: stores.0.fileURL)
        let payload = try JSONDecoder().decode(ConfigStore.Payload.self, from: data)
        XCTAssertEqual(payload.settings.defaultDock.appearance.tilesize, 64)
    }

    // MARK: - 抓取

    func testCaptureCurrentDockReadsTheLiveDomain() {
        var domain = baseDomain()
        domain["tilesize"] = .double(72)
        domain["persistent-apps"] = .array([
            .dictionary(DockStripRules.makeLaunchpadTile().raw),
        ])
        let state = makeState(preferences: FakePreferences(domain: domain), stores: makeStores("capture"))
        state.start()
        defer { state.stop() }

        state.captureCurrentDockAsDefault()

        XCTAssertEqual(state.settings.defaultDock.appearance.tilesize, 72)
        XCTAssertEqual(state.settings.defaultDock.pinnedApps.map(\.label), ["启动台"])
    }

    func testCaptureRefusesWhenDomainIsUnreadable() {
        let state = makeState(preferences: FakePreferences(domain: [:]), stores: makeStores("capture-fail"))
        state.start()
        defer { state.stop() }

        state.captureCurrentDockAsDefault()

        XCTAssertTrue(state.settings.defaultDock.pinnedApps.isEmpty)
        XCTAssertTrue(state.log.contains { $0.message.contains("读不到 com.apple.dock") })
    }

    // MARK: - 还原

    func testRestoreWritesTheBaselineBack() async throws {
        let stores = makeStores("restore")
        var baseline = baseDomain()
        baseline["tilesize"] = .double(36)
        baseline["orientation"] = .string("left")
        try PropertyListSerialization
            .data(fromPropertyList: baseline.mapValues(\.anyValue), format: .xml, options: 0)
            .write(to: stores.1.baselineURL)

        var live = baseDomain()
        live["tilesize"] = .double(80)          // 被改坏了
        live["orientation"] = .string("bottom")
        let preferences = FakePreferences(domain: live)
        let state = makeState(preferences: preferences, stores: stores)
        state.start()
        defer { state.stop() }

        let outcome = await state.restoreToBaseline()

        XCTAssertEqual(outcome?.result, .applied)
        XCTAssertEqual(preferences.lastEntries?["tilesize"], .double(36))
        XCTAssertEqual(preferences.lastEntries?["orientation"], .string("left"))
        XCTAssertFalse(state.log.contains { $0.message.contains("找不到基准快照") })
    }

    func testRestoreFailsLoudlyWhenBaselineIsMissing() async throws {
        let stores = makeStores("restore-missing")
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: stores)
        state.start()
        defer { state.stop() }
        // `start()` 的启动自检会在首次运行时抓一份基准，这里删掉来构造"基准丢失"。
        try FileManager.default.removeItem(at: stores.1.baselineURL)

        let outcome = await state.restoreToBaseline()

        XCTAssertNil(outcome)
        XCTAssertEqual(preferences.writeCount, 0)
        XCTAssertTrue(state.log.contains { $0.message.contains("找不到基准快照") })
    }

    func testRestoreSkipsWhenLiveDockAlreadyMatchesBaseline() async throws {
        // 已经与基准一致就别再写一次：退出时白重启一次 Dock 是能被用户看见的。
        let stores = makeStores("restore-skip")
        try PropertyListSerialization
            .data(fromPropertyList: baseDomain().mapValues(\.anyValue), format: .xml, options: 0)
            .write(to: stores.1.baselineURL)

        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: stores)
        state.start()
        defer { state.stop() }

        let outcome = await state.restoreToBaseline()

        XCTAssertEqual(outcome?.result, .skippedIdentical)
        XCTAssertEqual(preferences.writeCount, 0, "与基准一致时不该写、不该重启 Dock")
        XCTAssertTrue(state.log.contains { $0.message.contains("已与基准一致，跳过还原") })
    }

    func testRestoreWritesAgainWhenLiveDockDriftsFromBaseline() async throws {
        let stores = makeStores("restore-drift")
        var baseline = baseDomain()
        baseline["tilesize"] = .double(36)
        try PropertyListSerialization
            .data(fromPropertyList: baseline.mapValues(\.anyValue), format: .xml, options: 0)
            .write(to: stores.1.baselineURL)

        var live = baseDomain()
        live["tilesize"] = .double(80)
        let preferences = FakePreferences(domain: live)
        let state = makeState(preferences: preferences, stores: stores)
        state.start()
        defer { state.stop() }

        let first = await state.restoreToBaseline()
        XCTAssertEqual(first?.result, .applied)
        XCTAssertEqual(preferences.writeCount, 1)

        // 还原完就与基准一致了，第二次应当跳过。
        let second = await state.restoreToBaseline()
        XCTAssertEqual(second?.result, .skippedIdentical)
        XCTAssertEqual(preferences.writeCount, 1, "第二次不该再写")
    }

    // MARK: - 退出还原的门槛

    func testQuitSkipsRestoreWhenNothingWasApplied() {
        let stores = makeStores("quit-clean")
        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: stores)
        state.start()
        defer { state.stop() }
        let lifecycle = LifecycleController(state: state, baselineStore: stores.1)
        lifecycle.applicationDidFinishLaunching()
        lifecycle.restoreHandler = {
            XCTFail("没改过 Dock 就不该触发还原")
            return nil
        }

        XCTAssertFalse(lifecycle.sessionChangedDock)
        // 用户可能在运行期间自己拖过图标；此时"还原"会把他的改动一起抹掉。
        XCTAssertTrue(lifecycle.shouldTerminate())
        XCTAssertTrue(state.log.contains { $0.message.contains("没有改动过 Dock，无需还原") })
    }

    func testQuitRestoresAfterAnApply() async {
        let stores = makeStores("quit-dirty")
        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: stores)
        state.start()
        defer { state.stop() }
        let lifecycle = LifecycleController(state: state, baselineStore: stores.1)
        lifecycle.applicationDidFinishLaunching()

        lifecycle.noteDockApplied(fingerprint: "fp-1")

        XCTAssertTrue(lifecycle.sessionChangedDock)
        XCTAssertTrue(lifecycle.sessionChangedDock, "指纹写进会话标记后要能读回来")
    }

    func testQuitSkipsRestoreWhenUserTurnedItOff() {
        let stores = makeStores("quit-off")
        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: stores)
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.restoreOnQuit = false }
        let lifecycle = LifecycleController(state: state, baselineStore: stores.1)
        lifecycle.applicationDidFinishLaunching()
        lifecycle.noteDockApplied(fingerprint: "fp-1")
        lifecycle.restoreHandler = {
            XCTFail("开关关掉就不该还原")
            return nil
        }

        XCTAssertTrue(lifecycle.shouldTerminate())
        XCTAssertTrue(state.log.contains { $0.message.contains("已关闭退出还原") })
    }

    // MARK: - 每个桌面的独立 Dock（P3）

    /// 两个桌面的夹具：桌面 1 是活动桌面。
    private func twoDesktops() -> (provider: FakeSpaceProvider, spaces: [DesktopSpace]) {
        let spaces = FakeSpaceProvider.desktops(count: 2)
        return (
            FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64),
            spaces
        )
    }

    func testEffectiveConfigFallsBackToDefaultDock() {
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("eff-default"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        state.setDefaultDock(config(tilesize: 52))

        XCTAssertFalse(state.hasOverride(for: fixture.spaces[0]))
        XCTAssertEqual(state.effectiveConfig(for: fixture.spaces[0]).appearance.tilesize, 52)
        XCTAssertEqual(state.effectiveConfig(for: fixture.spaces[1]).appearance.tilesize, 52)
    }

    func testOverrideWinsOverDefault() {
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("eff-override"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        state.setDefaultDock(config(tilesize: 52))
        state.setOverride(config(tilesize: 80), for: fixture.spaces[1], reason: "桌面 2 单独设置")

        XCTAssertTrue(state.hasOverride(for: fixture.spaces[1]))
        XCTAssertEqual(state.effectiveConfig(for: fixture.spaces[1]).appearance.tilesize, 80)
        XCTAssertEqual(state.effectiveConfig(for: fixture.spaces[0]).appearance.tilesize, 52,
                       "另一个桌面不该被带着改")
    }

    func testSetOverridePersistsToDisk() throws {
        let fixture = twoDesktops()
        let stores = makeStores("override-persist")
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: stores,
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        state.setOverride(config(tilesize: 80), for: fixture.spaces[1], reason: "落盘")

        let payload = try JSONDecoder().decode(
            ConfigStore.Payload.self,
            from: Data(contentsOf: stores.0.fileURL)
        )
        XCTAssertEqual(payload.bindings.count, 1)
        XCTAssertEqual(payload.bindings.first?.override?.appearance.tilesize, 80)
        XCTAssertEqual(payload.bindings.first?.spaceUUID, fixture.spaces[1].spaceUUID)
    }

    func testClearingOverrideRevertsToDefaultAndPrunesTheEmptyBinding() {
        // 取消独立 Dock 后，这条绑定既无名字也无 override，应当整条消失，
        // 而不是在 config.json 里留一行空壳。
        let fixture = twoDesktops()
        let stores = makeStores("override-clear")
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: stores,
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        state.setDefaultDock(config(tilesize: 52))
        state.setOverride(config(tilesize: 80), for: fixture.spaces[1], reason: "加上")
        XCTAssertEqual(state.bindings.count, 1)

        state.setOverride(nil, for: fixture.spaces[1], reason: "取消独立 Dock")

        XCTAssertTrue(state.bindings.isEmpty, "空绑定要清掉")
        XCTAssertEqual(state.effectiveConfig(for: fixture.spaces[1]).appearance.tilesize, 52)
    }

    func testClearingOverrideKeepsTheBindingWhenTheDesktopHasAName() {
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("override-named"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        state.setCustomName("工作", for: fixture.spaces[1])
        state.setOverride(config(), for: fixture.spaces[1], reason: "加上")
        state.setOverride(nil, for: fixture.spaces[1], reason: "取消独立 Dock")

        XCTAssertEqual(state.bindings.count, 1, "还有名字，绑定要留着")
        XCTAssertEqual(state.displayName(for: fixture.spaces[1]), "工作")
    }

    func testCopyDefaultToOverrideIsAnIndependentCopy() {
        // 复制完再改默认 Dock，不该带着这个桌面的独立配置一起变。
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("override-copy"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        state.setDefaultDock(config(tilesize: 52))
        state.copyDefaultToOverride(for: fixture.spaces[1])
        XCTAssertEqual(state.effectiveConfig(for: fixture.spaces[1]).appearance.tilesize, 52)

        state.setDefaultDock(config(tilesize: 96))

        XCTAssertEqual(state.effectiveConfig(for: fixture.spaces[1]).appearance.tilesize, 52,
                       "独立配置不该跟着默认 Dock 走")
        XCTAssertEqual(state.effectiveConfig(for: fixture.spaces[0]).appearance.tilesize, 96)
    }

    func testApplyConfigForDesktopUsesThatDesktopsOwnDock() async {
        let fixture = twoDesktops()
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(
            preferences: preferences,
            stores: makeStores("apply-per-desktop"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        state.setOverride(config(tilesize: 88), for: fixture.spaces[1], reason: "桌面 2")

        state.applyConfigForDesktop(fixture.spaces[1], reason: "测试")
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.lastEntries?["tilesize"], .double(88))
    }

    func testApplyConfigForDesktopRefusesAnEmptyOverride() async {
        // 空配置写下去会把 Dock 清空 —— 宁可什么都不做，也不能让用户失去 Dock。
        let fixture = twoDesktops()
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(
            preferences: preferences,
            stores: makeStores("apply-empty-override"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        state.setOverride(DockConfig(), for: fixture.spaces[1], reason: "空配置")
        state.applyConfigForDesktop(fixture.spaces[1], reason: "测试")
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.writeCount, 0)
        XCTAssertTrue(state.log.contains { $0.message.contains("的 Dock 是空的，跳过应用") })
    }

    // MARK: - 预应用（切桌面之前先把 Dock 推下去）

    func testPreApplyAppliesTheTargetDockWithoutWaitingForThePoll() async {
        // 「预应用」要解决的是：程序化切桌面**收不到**空间变化通知（P0 实测），
        // 如果等 300 ms 轮询发现变化才动 Dock，用户会先看到旧 Dock 再被刷新。
        //
        // 注意**不能**断言"写入发生在 setCurrentSpace 之前"：一次应用要先写偏好、
        // 再重启 Dock，而 Dock 重启本身就要约 101 ms（P0 实测），比 `setCurrentSpace`
        // 返回（实测 0–6 ms）慢一个量级。所以"切空间之前完成重启"物理上做不到。
        // 真正该保证的是：**发起**应用与切空间在同一拍，不等轮询。
        let events = Box<[String]>([])
        let spaces = FakeSpaceProvider.desktops(count: 2)
        let provider = FakeSpaceProvider(
            desktops: spaces,
            activeSpaceID: spaces[0].id64,
            events: events
        )
        let preferences = FakePreferences(domain: baseDomain(), events: events)
        let state = makeState(
            preferences: preferences,
            stores: makeStores("preapply"),
            provider: provider
        )
        state.start()
        unfreeze(state)
        defer { state.stop() }

        // 桌面 2 有自己的 Dock；先把它应用一遍，再把默认 Dock（桌面 1 用的）应用上去，
        // 这样切到桌面 2 时"目标 ≠ 当前"，预应用一定会真的写。
        state.setOverride(config(tilesize: 88), for: spaces[1], reason: "桌面 2 独立")
        await state.dockController.waitForIdle()
        state.setDockConfigInMemory(config(tilesize: 40), for: .defaultDock)
        state.dockEdited(.defaultDock, reason: "准备")
        await state.dockController.waitForIdle()

        events.value.removeAll()
        state.switchToNextDesktop()

        XCTAssertTrue(state.dockController.isApplying,
                      "切空间之前就该发起应用，不能等 300 ms 轮询")
        await state.dockController.waitForIdle()

        XCTAssertEqual(provider.switchTargets, [spaces[1].id64], "应当切到桌面 2")
        XCTAssertEqual(preferences.lastEntries?["tilesize"], .double(88),
                       "要应用目标桌面的 Dock，不是当前桌面的")
        // 用事件流数"这次切换写了几次"，不能用累计的 writeCount（前面准备阶段也写过）。
        XCTAssertEqual(events.value.filter { $0 == "write" }.count, 1,
                       "预应用与切空间后的 observer 回调必须合并成一次，否则 Dock 会重启两次")
    }

    /// ⇧+左键（上一个桌面）走的是同一条预应用链路：也要先算目标、把目标 Dock 推下去，再切空间。
    func testPreviousDesktopPreAppliesItsOwnDock() async {
        let events = Box<[String]>([])
        let spaces = FakeSpaceProvider.desktops(count: 3)
        let provider = FakeSpaceProvider(
            desktops: spaces,
            activeSpaceID: spaces[0].id64,
            events: events
        )
        let preferences = FakePreferences(domain: baseDomain(), events: events)
        let state = makeState(
            preferences: preferences,
            stores: makeStores("previous"),
            provider: provider
        )
        state.start()
        unfreeze(state)
        defer { state.stop() }

        // 桌面 3 有自己的 Dock，当前在桌面 1（用默认 40）→ 往前切一定真的要写。
        state.setOverride(config(tilesize: 88), for: spaces[2], reason: "桌面 3 独立")
        await state.dockController.waitForIdle()
        state.setDockConfigInMemory(config(tilesize: 40), for: .defaultDock)
        state.dockEdited(.defaultDock, reason: "准备")
        await state.dockController.waitForIdle()

        events.value.removeAll()
        state.switchToPreviousDesktop()

        XCTAssertTrue(state.dockController.isApplying, "上一个桌面同样要在切空间之前发起应用")
        await state.dockController.waitForIdle()

        XCTAssertEqual(provider.switchTargets, [spaces[2].id64], "第一个桌面再往前应回到最后一个")
        XCTAssertEqual(preferences.lastEntries?["tilesize"], .double(88),
                       "要应用目标桌面的 Dock，不是当前桌面的")
        XCTAssertEqual(events.value.filter { $0 == "write" }.count, 1)
    }

    func testSwitchingBetweenIdenticalDesktopsNeverRestartsDock() async {
        // P3 验收：两个桌面配置相同时，来回切不该有任何 Dock 刷新。
        let spaces = FakeSpaceProvider.desktops(count: 2)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(
            preferences: preferences,
            stores: makeStores("switch-identical"),
            provider: provider
        )
        state.start()
        unfreeze(state)
        defer { state.stop() }

        // 两个桌面都沿用默认 Dock，内容完全相同。
        state.setDefaultDock(config(tilesize: 52))
        state.applyDefaultDock()
        await state.dockController.waitForIdle()
        XCTAssertEqual(preferences.writeCount, 1)

        for _ in 0..<4 {
            state.switchToNextDesktop()
            await state.dockController.waitForIdle()
        }

        XCTAssertEqual(preferences.writeCount, 1, "内容相同就该被指纹短路，一次都不该多写")
        XCTAssertEqual(provider.switchTargets.count, 4)
        XCTAssertTrue(state.log.contains { $0.message.contains("内容与当前一致") })
    }

    func testSwitchingDoesNothingWhenOnlyOneDesktop() async {
        let spaces = FakeSpaceProvider.desktops(count: 1)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(
            preferences: preferences,
            stores: makeStores("switch-single"),
            provider: provider
        )
        state.start()
        defer { state.stop() }

        state.switchToNextDesktop()
        await state.dockController.waitForIdle()

        XCTAssertTrue(provider.switchTargets.isEmpty)
        XCTAssertEqual(preferences.writeCount, 0)
        XCTAssertTrue(state.log.contains { $0.message.contains("没有可切换的下一个桌面") })
    }

    func testSwitchReportsWhenProviderIsUnavailable() {
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("switch-unavailable")
        )
        state.start()
        defer { state.stop() }

        state.switchToNextDesktop()

        XCTAssertTrue(state.log.contains { $0.message.contains("桌面切换不可用") })
    }

    // MARK: - 回存手动改动（计划 §3.8）

    func testUserEditIsCapturedIntoTheCurrentDesktopsOverride() async {
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("capture-override"),
            provider: fixture.provider
        )
        state.start()
        unfreeze(state)
        defer { state.stop() }

        state.setOverride(config(tilesize: 40), for: fixture.spaces[0], reason: "桌面 1 独立")
        await state.dockController.waitForIdle()

        let edited = config(tilesize: 64)
        state.handleUserDockEdit(edited)
        await state.dockController.waitForIdle()

        XCTAssertEqual(state.binding(for: fixture.spaces[0])?.override?.appearance.tilesize, 64)
        XCTAssertEqual(state.effectiveConfig(for: fixture.spaces[0]).appearance.tilesize, 64)
        XCTAssertFalse(state.hasOverride(for: fixture.spaces[1]), "只改当前桌面，不碰另一个")
        XCTAssertEqual(state.bindings.count, 1)
    }

    func testUserEditIsCapturedIntoTheDefaultDockWhenThereIsNoOverride() async {
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("capture-default"),
            provider: fixture.provider
        )
        state.start()
        unfreeze(state)
        defer { state.stop() }

        state.handleUserDockEdit(config(tilesize: 64))
        await state.dockController.waitForIdle()

        XCTAssertEqual(state.settings.defaultDock.appearance.tilesize, 64)
        XCTAssertTrue(state.bindings.isEmpty, "没有 override 就不该凭空造一条绑定")
        XCTAssertTrue(state.log.contains { $0.message.contains("已回存到默认 Dock") })
    }

    func testUserEditIsCapturedIntoTheDefaultDockWhenNoDesktopIsActive() async {
        // 活动空间不是用户桌面（例如正处在全屏 App 里）时，改动只能落到默认 Dock。
        let provider = FakeSpaceProvider(desktops: [], activeSpaceID: 0)
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("capture-nospace"),
            provider: provider
        )
        state.start()
        unfreeze(state)
        defer { state.stop() }

        state.handleUserDockEdit(config(tilesize: 64))
        await state.dockController.waitForIdle()

        XCTAssertEqual(state.settings.defaultDock.appearance.tilesize, 64)
        XCTAssertTrue(state.log.contains { $0.message.contains("当前不在用户桌面上") })
    }

    func testUserEditIsIgnoredWhenTheToggleIsOff() async {
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("capture-off"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoCaptureUserEdits = false }

        state.handleUserDockEdit(config(tilesize: 64))
        await state.dockController.waitForIdle()

        XCTAssertTrue(state.settings.defaultDock.pinnedApps.isEmpty, "关掉开关就不该回存")
        XCTAssertTrue(state.log.contains { $0.message.contains("已关闭，忽略这次改动") })
    }

    // MARK: - watcher 的接线

    func testWatcherIsStartedByDefault() {
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("watcher-on")
        )
        state.start()
        defer { state.stop() }

        XCTAssertNotNil(state.dockWatcher)
        XCTAssertTrue(state.dockWatcher?.isRunning == true)
    }

    func testWatcherIsNotStartedWhenCaptureIsOffInTheSavedConfig() throws {
        // 开关是在 start() 里读配置决定的，所以要预先写好 config.json。
        let stores = makeStores("watcher-off")
        var settings = AppSettings()
        settings.autoCaptureUserEdits = false
        try stores.0.save(.init(bindings: [], settings: settings))

        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: stores)
        state.start()
        defer { state.stop() }

        XCTAssertNil(state.dockWatcher)
        XCTAssertTrue(state.log.contains { $0.message.contains("不启动监视") })
    }

    func testStopStopsTheWatcher() {
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("watcher-stop")
        )
        state.start()
        XCTAssertTrue(state.dockWatcher?.isRunning == true)

        state.stop()

        XCTAssertTrue(state.dockWatcher?.isRunning == false)
    }

    func testWatcherSeesNoDivergenceRightAfterStartup() {
        // 启动时 `adoptLiveDockAsApplied()` 会把现状记成"已应用"，
        // 否则 watcher 一启动就会把用户原来的 Dock 当成"我们该回存的改动"。
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("watcher-adopt"))
        state.start()
        defer { state.stop() }

        state.dockWatcher?.tick()

        XCTAssertEqual(state.dockWatcher?.detectedCount, 0)
        XCTAssertFalse(state.dockWatcher?.isDiverged ?? true)
    }

    // MARK: - 编辑器统一入口（默认 Dock / 逐桌面独立 Dock）

    func testInMemoryEditDoesNotPersistOrApply() async {
        // 滑杆每一步、拖拽每次 dropEntered 都会走内存写入。
        // 只要还没提交，就既不该写盘、也不该重启 Dock。
        let stores = makeStores("inmemory")
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: stores)
        state.start()
        defer { state.stop() }

        var appearance = state.dockAppearance(for: .defaultDock)
        appearance.tilesize = 72
        state.setDockAppearanceInMemory(appearance, for: .defaultDock)

        XCTAssertEqual(state.dockAppearance(for: .defaultDock).tilesize, 72)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stores.0.fileURL.path),
                       "没提交就不该落盘")
        await state.dockController.waitForIdle()
        XCTAssertEqual(preferences.writeCount, 0, "没提交就不该碰 Dock")
    }

    func testAppearanceCommitPersistsAndAppliesOnce() async throws {
        let stores = makeStores("appearance-commit")
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: stores)
        state.start()
        defer { state.stop() }

        // 先备好一份非空默认 Dock，否则会被"空配置拒绝应用"挡下。
        state.setDockConfigInMemory(config(tilesize: 52), for: .defaultDock)
        state.dockEdited(.defaultDock, reason: "准备")
        await state.dockController.waitForIdle()
        let writesAfterPrepare = preferences.writeCount

        // 模拟拖动滑杆：多次内存写入 + 一次提交。
        for size in [60.0, 64.0, 68.0] {
            var appearance = state.dockAppearance(for: .defaultDock)
            appearance.tilesize = size
            state.setDockAppearanceInMemory(appearance, for: .defaultDock)
        }
        state.dockEdited(.defaultDock, reason: "调整图标大小")
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.writeCount, writesAfterPrepare + 1,
                       "一次拖动只该产生一次写入")
        XCTAssertEqual(preferences.lastEntries?["tilesize"], .double(68))
        let payload = try JSONDecoder().decode(
            ConfigStore.Payload.self,
            from: Data(contentsOf: stores.0.fileURL)
        )
        XCTAssertEqual(payload.settings.defaultDock.appearance.tilesize, 68)
    }

    func testDesktopTargetRoutesToItsOwnOverride() async {
        let fixture = twoDesktops()
        let stores = makeStores("target-desktop")
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(
            preferences: preferences,
            stores: stores,
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        state.setDockConfigInMemory(config(tilesize: 88), for: .desktop(fixture.spaces[1]))
        state.dockEdited(.desktop(fixture.spaces[1]), reason: "桌面 2 的图标条")
        await state.dockController.waitForIdle()

        XCTAssertEqual(state.binding(for: fixture.spaces[1])?.override?.appearance.tilesize, 88)
        XCTAssertEqual(preferences.lastEntries?["tilesize"], .double(88))
        XCTAssertTrue(state.isOverridden(.desktop(fixture.spaces[1])))
        XCTAssertFalse(state.isOverridden(.defaultDock))
        XCTAssertEqual(state.dockConfig(for: .defaultDock).appearance.tilesize,
                       DockConfig().appearance.tilesize, "默认 Dock 不该被带着改")
    }

    func testAppearanceTargetsAreIndependent() {
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("target-independent"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        var defaultAppearance = state.dockAppearance(for: .defaultDock)
        defaultAppearance.tilesize = 40
        state.setDockAppearanceInMemory(defaultAppearance, for: .defaultDock)

        var desktopAppearance = state.dockAppearance(for: .desktop(fixture.spaces[0]))
        desktopAppearance.tilesize = 96
        state.setDockAppearanceInMemory(desktopAppearance, for: .desktop(fixture.spaces[0]))

        XCTAssertEqual(state.dockAppearance(for: .defaultDock).tilesize, 40)
        XCTAssertEqual(state.dockAppearance(for: .desktop(fixture.spaces[0])).tilesize, 96)
    }

    func testAppearanceCommitRespectsAutoApplyToggle() async {
        let stores = makeStores("appearance-auto-off")
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: stores)
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        state.setDockConfigInMemory(config(tilesize: 52), for: .defaultDock)
        state.dockEdited(.defaultDock, reason: "改了但开关关着")
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.writeCount, 0)
        XCTAssertTrue(state.log.contains { $0.message.contains("改动只存在本地配置里") })
        // 但内存里的改动要保留，用户下次点「立即应用」还能用上。
        XCTAssertEqual(state.dockConfig(for: .defaultDock).appearance.tilesize, 52)
    }

    // MARK: - 菜单栏「用当前 Dock 重置本桌面配置」（计划 §3.7）

    /// 域里放一套可辨认的 Dock，供抓取用。
    private func domainWithLiveDock(tilesize: Double) -> [String: PlistValue] {
        var domain = baseDomain()
        domain["tilesize"] = .double(tilesize)
        domain["persistent-apps"] = .array([
            .dictionary(DockStripRules.makeLaunchpadTile().raw),
        ])
        return domain
    }

    func testResetFromLiveDockOverwritesTheCurrentDesktopsOverride() {
        let fixture = twoDesktops()
        let preferences = FakePreferences(domain: domainWithLiveDock(tilesize: 72))
        let state = makeState(
            preferences: preferences,
            stores: makeStores("reset-live-override"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        state.setOverride(config(tilesize: 40), for: fixture.spaces[0], reason: "先给个独立配置")
        state.resetActiveDesktopConfigFromLiveDock()

        XCTAssertEqual(state.binding(for: fixture.spaces[0])?.override?.appearance.tilesize, 72)
        XCTAssertFalse(state.hasOverride(for: fixture.spaces[1]), "不该给别的桌面造绑定")
        XCTAssertEqual(state.bindings.count, 1)
    }

    func testResetFromLiveDockFallsBackToTheDefaultDock() {
        // 当前桌面沿用默认 Dock 时，重置的是默认 Dock —— 不能凭空造一条 override，
        // 否则这个桌面会悄悄脱离默认 Dock。
        let fixture = twoDesktops()
        let preferences = FakePreferences(domain: domainWithLiveDock(tilesize: 72))
        let state = makeState(
            preferences: preferences,
            stores: makeStores("reset-live-default"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        state.resetActiveDesktopConfigFromLiveDock()

        XCTAssertEqual(state.settings.defaultDock.appearance.tilesize, 72)
        XCTAssertTrue(state.bindings.isEmpty, "不该凭空造绑定")
        XCTAssertTrue(state.log.contains { $0.message.contains("已用当前 Dock 重置默认 Dock") })
    }

    func testResetFromLiveDockRefusesWhenDomainIsUnreadable() {
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: [:]),
            stores: makeStores("reset-live-fail"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        state.resetActiveDesktopConfigFromLiveDock()

        XCTAssertTrue(state.settings.defaultDock.pinnedApps.isEmpty)
        XCTAssertTrue(state.bindings.isEmpty)
        XCTAssertTrue(state.log.contains { $0.message.contains("读不到 com.apple.dock") })
    }
}

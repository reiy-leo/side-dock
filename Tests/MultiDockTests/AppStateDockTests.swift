import XCTest
@testable import MultiDock

/// `AppState` 里「Dock 应用」这条路径 —— 也就是设置页那几个按钮点下去会发生什么。
///
/// 用测试替身替代真实偏好域与真实 Dock 进程，所以不会动用户的 Dock。
/// 真实写入链路由 `DockAcceptanceTests`（需显式开启）覆盖。
///
/// 2026-10-06 起的内容模型（用户指令：去掉「最近添加的应用」整块逻辑）：
/// **本 App 不生成任何 Dock 内容、也不存在「默认 Dock」**——逐桌面差异只由 `DockBar`
/// （绑定 + 内容）承载，没绑栏的桌面原生 Dock 保持原样（什么都不写）；
/// 外观键不再出现在任何写入里。
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
        provider: FakeSpaceProvider? = nil,
        environment: @escaping () -> EnvironmentReading = {
            EnvironmentReading(stageManagerActive: false, dockSide: .bottom)
        }
    ) -> AppState {
        let state = AppState(
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
            fileLog: makeTestFileLog(),
            environmentReader: environment
        )
        // 本文件的用例各自管理写入次数，默认按「未冻结」起跑。
        state.updateSettings { $0.freezeNativeDockSwitching = false }
        return state
    }

    /// 冻结自 2026-10-04 起是产品默认值；要走逐桌面应用路径的用例在 start() 后调它。
    /// 只在确实要测「切换会应用 Dock」的用例里用 —— 别摊回 makeState。
    private func unfreeze(_ state: AppState) {
        state.updateSettings { $0.freezeNativeDockSwitching = false }
    }

    /// 生成 N 个互不相同的可写入条目（真实键名不同，避免归一化去重把条数压掉）。
    private static func apps(count: Int, prefix: String) -> [DockTile] {
        (0..<count).map { index in
            DockTile.makeFileTile(
                url: URL(fileURLWithPath: "/Applications/\(prefix)\(index).app", isDirectory: true),
                label: "\(prefix)\(index)",
                bundleIdentifier: "com.example.\(prefix.lowercased())\(index)"
            )
        }
    }

    private func apps(count: Int, prefix: String = "App") -> [DockTile] {
        Self.apps(count: count, prefix: prefix)
    }

    /// 给桌面 1（或指定桌面）绑一根内容为 `apps` 的栏。autoApply 由调用方自己控制。
    @discardableResult
    private func bindBar(
        _ state: AppState,
        to space: DesktopSpace?,
        apps barApps: [DockTile],
        name: String = "测试栏"
    ) -> UUID {
        let id = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: id, name: name, apps: DockStripRules.barApps(barApps)))
        if let space {
            state.bindDockBar(id, to: space.id)
        }
        return id
    }

    // MARK: - 应用当前桌面的 Dock 栏（替代旧的「立即应用默认 Dock」）

    /// 三个桌面的夹具：桌面 1 是活动桌面。用于「应用」按钮这条路径。
    private func activeDesktopFixture(_ name: String) -> (AppState, FakePreferences, DesktopSpace) {
        let spaces = FakeSpaceProvider.desktops(count: 2)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(
            preferences: preferences,
            stores: makeStores(name),
            provider: provider
        )
        return (state, preferences, spaces[0])
    }

    func testApplyActiveDesktopDockWritesTheBoundBar() async {
        let (state, preferences, space) = activeDesktopFixture("apply-active")
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        bindBar(state, to: space, apps: apps(count: 3, prefix: "Bar"), name: "工作栏")
        state.applyActiveDesktopDock()
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.writeCount, 1)
        let written = preferences.lastEntries ?? [:]
        XCTAssertEqual(written["persistent-apps"]?.arrayValue?.count, 3, "写的就是绑定栏里的 3 个图标")
        XCTAssertNil(written["tilesize"], "外观键（大小）不写入 —— 跟随系统")
        XCTAssertNil(written["orientation"], "外观键（位置）不写入 —— 跟随系统")
        XCTAssertTrue(state.hasAppliedDockConfig)
        XCTAssertTrue(state.lastApplySummary.contains("applied"))
        XCTAssertTrue(state.log.contains { $0.message.hasPrefix("Dock 应用成功") })
    }

    func testApplyActiveDesktopDockRefusesWithoutBoundBar() async {
        // 没绑栏 = 本 App 没有内容可写 —— 如实说明并**一个键都不写**（原生 Dock 归用户）。
        let (state, preferences, _) = activeDesktopFixture("apply-nobar")
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        XCTAssertNotNil(state.activeDesktopApplyBlockedReason, "按钮应显示禁用原因")
        state.applyActiveDesktopDock()
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.writeCount, 0, "没绑栏就什么都不写")
        XCTAssertTrue(state.log.contains { $0.message.contains("未绑定 Dock 栏") })
    }

    func testApplyNotifiesLifecycleWithFingerprint() async {
        let (state, _, space) = activeDesktopFixture("notify")
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        let id = bindBar(state, to: space, apps: apps(count: 1), name: "工作栏")
        let bar = state.dockBar(id: id)!
        let reported = Box<[String]>([])
        state.onDockApplied = { reported.value.append($0) }

        state.applyActiveDesktopDock()
        await state.dockController.waitForIdle()

        XCTAssertEqual(reported.value.count, 1, "会话标记要拿到指纹，否则强杀自愈无法判断 Dock 是否被改过")
        XCTAssertFalse(reported.value[0].isEmpty)
        XCTAssertEqual(bar.apps.count, 1)
    }

    func testRepeatedApplyOfIdenticalContentDoesNotTouchDockAgain() async {
        let (state, preferences, space) = activeDesktopFixture("idem")
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        bindBar(state, to: space, apps: apps(count: 2), name: "工作栏")
        state.applyActiveDesktopDock()
        await state.dockController.waitForIdle()
        state.applyActiveDesktopDock()
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.writeCount, 1, "第二次内容相同必须短路")
        XCTAssertTrue(state.log.contains { $0.message.contains("内容与当前一致") })
    }

    // MARK: - 落盘时机（Dock 栏编辑）

    func testInMemoryBarEditDoesNotPersistOrApply() async {
        // 拖拽排序的每一次 dropEntered 都会走 updateDockBarInMemory；它不该写盘也不该碰 Dock。
        let stores = makeStores("inmemory")
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: stores)
        state.start()
        defer { state.stop() }

        let id = state.addDockBar()
        var bar = state.dockBar(id: id)!
        bar.apps = DockStripRules.barApps(apps(count: 2))
        state.updateDockBarInMemory(bar)

        XCTAssertEqual(state.dockBar(id: id)?.apps.count, 2, "内存里的改动要立即可见")
        let payload = try? JSONDecoder().decode(
            ConfigStore.Payload.self,
            from: Data(contentsOf: stores.0.fileURL)
        )
        XCTAssertTrue(payload?.settings.dockBars.first { $0.id == id }?.apps.isEmpty ?? false,
                      "落盘的是添加栏时的空内容，不是这次内存改动")
        await state.dockController.waitForIdle()
        XCTAssertEqual(preferences.writeCount, 0, "没提交就不该碰 Dock")
    }

    func testDockBarEditedPersistsOnce() async throws {
        let stores = makeStores("bar-persist")
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: stores)
        state.start()
        defer { state.stop() }

        let id = state.addDockBar()
        var bar = state.dockBar(id: id)!
        bar.apps = DockStripRules.barApps(apps(count: 2))
        state.dockBarEdited(bar, reason: "落盘")

        let payload = try JSONDecoder().decode(
            ConfigStore.Payload.self,
            from: Data(contentsOf: stores.0.fileURL)
        )
        XCTAssertEqual(payload.settings.dockBars.first { $0.id == id }?.apps.count, 2)
        XCTAssertTrue(state.log.contains { $0.message.contains("已修改：落盘") })
    }

    // MARK: - 抓取

    func testCaptureLiveConfigReadsContentOnly() {
        var domain = baseDomain()
        domain["tilesize"] = .double(72)
        domain["persistent-apps"] = .array([
            .dictionary(DockTile.makeFileTile(
                url: URL(fileURLWithPath: "/System/Applications/Launchpad.app", isDirectory: true),
                label: "启动台",
                bundleIdentifier: "com.apple.launchpad.launcher"
            ).raw),
        ])
        let state = makeState(preferences: FakePreferences(domain: domain), stores: makeStores("capture"))
        state.start()
        defer { state.stop() }

        let live = state.captureLiveDockConfig()

        XCTAssertEqual(live?.pinnedApps.map(\.label), ["启动台"], "只取内容键")
    }

    func testCaptureRefusesWhenDomainIsUnreadable() {
        let state = makeState(preferences: FakePreferences(domain: [:]), stores: makeStores("capture-fail"))
        state.start()
        defer { state.stop() }

        XCTAssertNil(state.captureLiveDockConfig())
        XCTAssertTrue(state.log.contains { $0.message.contains("读不到 com.apple.dock") })
    }

    // MARK: - 还原

    func testRestoreWritesTheBaselineBackIncludingAppearanceKeys() async throws {
        // 还原是**收尾**：应用路径不写外观了，但旧版本写过 —— 还原必须把基准里的
        // 外观键一并写回，无痕原则才闭环（这是 2026-10-05 重构专门保留的行为）。
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
        XCTAssertEqual(preferences.lastEntries?["tilesize"], .double(36), "外观键随基准写回")
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

    // MARK: - Dock 栏绑定（2026-10-05 起替代逐桌面 override）

    /// 两个桌面的夹具：桌面 1 是活动桌面。
    private func twoDesktops() -> (provider: FakeSpaceProvider, spaces: [DesktopSpace]) {
        let spaces = FakeSpaceProvider.desktops(count: 2)
        return (
            FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64),
            spaces
        )
    }

    func testEffectiveConfigIsNilWithoutBoundBar() {
        // 2026-10-06：本 App 不生成内容 —— 没绑栏的桌面没有「生效配置」可应用。
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("eff-default"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        XCTAssertNil(state.dockBar(for: fixture.spaces[0]))
        XCTAssertNil(state.effectiveConfig(for: fixture.spaces[0]), "没绑栏就没有生效配置")
        XCTAssertNil(state.effectiveConfig(for: fixture.spaces[1]))
    }

    func testBoundBarProvidesTheEffectiveConfig() {
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("eff-bar"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        bindBar(state, to: fixture.spaces[1], apps: apps(count: 2, prefix: "Bar"))

        XCTAssertEqual(state.effectiveConfig(for: fixture.spaces[1])?.pinnedApps.map(\.label),
                       ["Bar0", "Bar1"], "绑了栏的桌面用栏的内容")
        XCTAssertNil(state.effectiveConfig(for: fixture.spaces[0]), "另一个桌面没绑栏，不该被带着改")
    }

    func testBindingPersistsToDisk() throws {
        let fixture = twoDesktops()
        let stores = makeStores("bind-persist")
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: stores,
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        bindBar(state, to: fixture.spaces[1], apps: apps(count: 1), name: "工作")

        let payload = try JSONDecoder().decode(
            ConfigStore.Payload.self,
            from: Data(contentsOf: stores.0.fileURL)
        )
        let bar = payload.settings.dockBars.first { $0.name == "工作" }
        XCTAssertEqual(bar?.spaceID, fixture.spaces[1].id)
        XCTAssertEqual(bar?.position, .bottom)
    }

    func testBindingOneBarDisplacesTheOtherOnTheSameDesktop() {
        // 一个桌面同时只挂一根栏：把第二根绑上去，第一根自动让出（应用保留）。
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("bind-displace"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        let first = bindBar(state, to: fixture.spaces[0], apps: apps(count: 1), name: "第一根")
        let second = bindBar(state, to: fixture.spaces[0], apps: apps(count: 2), name: "第二根")

        XCTAssertNil(state.dockBar(id: first)?.spaceID, "先到的让出桌面")
        XCTAssertEqual(state.dockBar(id: second)?.spaceID, fixture.spaces[0].id)
        XCTAssertFalse(state.dockBar(id: first)!.apps.isEmpty, "让出的栏应用保留")
        XCTAssertTrue(state.log.contains { $0.message.contains("让出桌面") })
    }

    func testUnbindingKeepsTheBarAndLeavesNoEffectiveConfig() {
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("unbind"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        let id = bindBar(state, to: fixture.spaces[1], apps: apps(count: 1), name: "临时")
        state.bindDockBar(id, to: nil)

        XCTAssertNil(state.dockBar(for: fixture.spaces[1]))
        XCTAssertNotNil(state.dockBar(id: id), "解绑不删栏")
        XCTAssertNil(state.effectiveConfig(for: fixture.spaces[1]), "解绑后没有生效配置（不写原生 Dock）")
    }

    func testAddAndRemoveBars() {
        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: makeStores("crud"))
        state.start()
        defer { state.stop() }

        let initial = state.dockBars.count
        let id = state.addDockBar()
        XCTAssertEqual(state.dockBars.count, initial + 1)
        XCTAssertNotNil(state.dockBar(id: id))

        state.removeDockBar(id: id)
        XCTAssertEqual(state.dockBars.count, initial)
        XCTAssertNil(state.dockBar(id: id))
    }

    func testBoundBarCannotBeRemovedUntilUnbound() {
        // 2026-10-06 用户规格：只有没绑定桌面的栏能删 —— 绑着的先解绑，
        // 否则那条桌面会突然什么都没有。
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("bound-remove"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }

        let id = state.addDockBar()
        state.bindDockBar(id, to: fixture.spaces[0].id)

        state.removeDockBar(id: id)
        XCTAssertNotNil(state.dockBar(id: id), "绑着桌面的栏删不掉")
        XCTAssertTrue(state.log.contains { $0.message.contains("先解绑才能删除") }, "拦下来要说明原因，不静默失败")

        state.bindDockBar(id, to: nil)
        state.removeDockBar(id: id)
        XCTAssertNil(state.dockBar(id: id), "解绑之后可以删")
    }

    func testRenameDockBarNormalizesAndPersists() throws {
        let stores = makeStores("bar-rename")
        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: stores)
        state.start()
        defer { state.stop() }

        let id = state.addDockBar()
        state.renameDockBar(id, to: "  一二三四五六七八九十甲乙  ")

        XCTAssertEqual(state.dockBar(id: id)?.name, "一二三四五六七八九十", "与桌面命名同一口径（10 字素簇）")
        let payload = try JSONDecoder().decode(
            ConfigStore.Payload.self,
            from: Data(contentsOf: stores.0.fileURL)
        )
        XCTAssertEqual(payload.settings.dockBars.first { $0.id == id }?.name, "一二三四五六七八九十")
    }

    func testOrphanedBarsAreListedAndCanBeUnbound() {
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("orphan-bars"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        let ghost = DesktopSpace(
            displayUUID: "DISP-GONE", spaceUUID: "SPACE-GONE", id64: 999, type: 0, ordinal: 1
        )
        bindBar(state, to: ghost, apps: apps(count: 1), name: "孤儿")
        XCTAssertEqual(state.orphanedBars.count, 1)

        XCTAssertEqual(state.unbindOrphanedBars(), 1)
        XCTAssertTrue(state.orphanedBars.isEmpty)
        XCTAssertEqual(state.dockBars.first { $0.name == "孤儿" }?.apps.count, 1, "解绑只解绑定，应用保留")
    }

    func testApplyConfigForDesktopUsesThatDesktopsBoundBar() async {
        let fixture = twoDesktops()
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(
            preferences: preferences,
            stores: makeStores("apply-per-desktop"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        bindBar(state, to: fixture.spaces[1], apps: apps(count: 2, prefix: "Bar"))

        state.applyConfigForDesktop(fixture.spaces[1], reason: "测试")
        await state.dockController.waitForIdle()

        XCTAssertTrue(
            preferences.lastEntries?["persistent-apps"]?.fingerprintToken.contains("Bar0") ?? false,
            "应用的是绑定栏的内容，不是默认 Dock"
        )
    }

    func testApplyConfigForDesktopRefusesAnEmptyBar() async {
        // 空配置写下去会把 Dock 清空 —— 宁可什么都不做，也不能让用户失去 Dock。
        let fixture = twoDesktops()
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(
            preferences: preferences,
            stores: makeStores("apply-empty-bar"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }
        await state.dockController.waitForIdle()   // start 时观察器首拍会异步应用默认内容
        state.updateSettings { $0.autoApplyOnEdit = false }
        let writesAtStart = preferences.writeCount

        let id = state.addDockBar()
        state.bindDockBar(id, to: fixture.spaces[1].id)   // 没放任何图标的空栏
        state.applyConfigForDesktop(fixture.spaces[1], reason: "测试")
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.writeCount, writesAtStart, "空栏拒绝应用，不产生新写入")
        XCTAssertTrue(state.log.contains { $0.message.contains("Dock 栏是空的，跳过应用") })
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
        state.updateSettings { $0.autoApplyOnEdit = false }

        // 两个桌面各绑一根内容不同的栏；先把桌面 1 的推上去，
        // 这样切到桌面 2 时"目标 ≠ 当前"，预应用一定会真的写。
        bindBar(state, to: spaces[0], apps: apps(count: 1, prefix: "Cur"), name: "当前栏")
        bindBar(state, to: spaces[1], apps: apps(count: 2, prefix: "Bar"), name: "目标栏")
        state.applyActiveDesktopDock()
        await state.dockController.waitForIdle()

        events.value.removeAll()
        state.switchToNextDesktop()

        XCTAssertTrue(state.dockController.isApplying,
                      "切空间之前就该发起应用，不能等 300 ms 轮询")
        await state.dockController.waitForIdle()

        XCTAssertEqual(provider.switchTargets, [spaces[1].id64], "应当切到桌面 2")
        XCTAssertTrue(
            preferences.lastEntries?["persistent-apps"]?.fingerprintToken.contains("Bar0") ?? false,
            "要应用目标桌面的 Dock，不是当前桌面的"
        )
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
        state.updateSettings { $0.autoApplyOnEdit = false }

        // 桌面 1 与桌面 3 各绑一根不同内容的栏（当前在桌面 1）→ 往前切一定真的要写。
        bindBar(state, to: spaces[0], apps: apps(count: 1, prefix: "Cur"), name: "当前栏")
        bindBar(state, to: spaces[2], apps: apps(count: 2, prefix: "Bar"), name: "目标栏")
        state.applyActiveDesktopDock()
        await state.dockController.waitForIdle()

        events.value.removeAll()
        state.switchToPreviousDesktop()

        XCTAssertTrue(state.dockController.isApplying, "上一个桌面同样要在切空间之前发起应用")
        await state.dockController.waitForIdle()

        XCTAssertEqual(provider.switchTargets, [spaces[2].id64], "第一个桌面再往前应回到最后一个")
        XCTAssertTrue(
            preferences.lastEntries?["persistent-apps"]?.fingerprintToken.contains("Bar0") ?? false,
            "要应用目标桌面的 Dock，不是当前桌面的"
        )
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
        state.updateSettings { $0.autoApplyOnEdit = false }

        // 两个桌面各绑一根**内容相同**的栏：来回切不该有任何 Dock 刷新。
        bindBar(state, to: spaces[0], apps: apps(count: 2, prefix: "Same"), name: "栏一")
        bindBar(state, to: spaces[1], apps: apps(count: 2, prefix: "Same"), name: "栏二")
        state.applyActiveDesktopDock()
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
        await state.dockController.waitForIdle()   // start 时观察器首拍会异步应用默认内容
        let writesAtStart = preferences.writeCount
        state.switchToNextDesktop()
        await state.dockController.waitForIdle()

        XCTAssertTrue(provider.switchTargets.isEmpty)
        XCTAssertEqual(preferences.writeCount, writesAtStart, "没有可切的桌面就不该有切换触发的写入")
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

    func testUserEditIsCapturedIntoTheBoundBarOfTheActiveDesktop() async {
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("capture-bar"),
            provider: fixture.provider
        )
        state.start()
        unfreeze(state)
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        bindBar(state, to: fixture.spaces[0], apps: apps(count: 1, prefix: "Bar"))

        let edited = DockConfig(pinnedApps: DockStripRules.barApps(apps(count: 2, prefix: "Manual")))
        state.handleUserDockEdit(edited)

        XCTAssertEqual(state.dockBar(for: fixture.spaces[0])?.apps.map(\.label),
                       ["Manual0", "Manual1"], "回存进活动桌面绑定的栏")
        XCTAssertNil(state.dockBar(for: fixture.spaces[1]), "只改当前桌面，不碰另一个")
        XCTAssertTrue(state.log.contains { $0.message.contains("已回存到 Dock 栏") })
    }

    func testUserEditIsNotCapturedWhenTheDesktopHasNoBar() async {
        // 没绑栏的桌面：改动无处可回，如实记日志（本 App 不生成内容）。
        let fixture = twoDesktops()
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("capture-nobar"),
            provider: fixture.provider
        )
        state.start()
        unfreeze(state)
        defer { state.stop() }

        state.handleUserDockEdit(DockConfig(pinnedApps: DockStripRules.barApps(apps(count: 3))))

        XCTAssertTrue(state.dockBars.allSatisfy { $0.spaceID == nil }, "不该凭空造绑定")
        XCTAssertTrue(state.log.contains { $0.message.contains("手动改动不回存") })
    }

    func testUserEditIsNotCapturedWhenNoDesktopIsActive() async {
        // 活动空间不是用户桌面（例如正处在全屏 App 里）时，改动无处可回。
        let provider = FakeSpaceProvider(desktops: [], activeSpaceID: 0)
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("capture-nospace"),
            provider: provider
        )
        state.start()
        unfreeze(state)
        defer { state.stop() }

        state.handleUserDockEdit(DockConfig(pinnedApps: DockStripRules.barApps(apps(count: 3))))

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

        let before = state.dockBars
        state.handleUserDockEdit(DockConfig(pinnedApps: DockStripRules.barApps(apps(count: 3))))

        XCTAssertEqual(state.dockBars, before, "关掉开关就不该回存")
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
        // 开关是在 start() 里读配置决定的。makeState 会先落一份默认设置（迁移 5 根栏），
        // 所以这份预置配置必须**在 makeState 之后、start 之前**写入。
        let stores = makeStores("watcher-off")
        var settings = AppSettings()
        settings.autoCaptureUserEdits = false
        try stores.0.save(.init(bindings: [], settings: settings))

        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: stores)
        try stores.0.save(.init(bindings: [], settings: settings))
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

    // MARK: - 菜单栏「用当前 Dock 重置本桌面配置」（计划 §3.7）

    /// 域里放一套可辨认的 Dock，供抓取用。
    private func domainWithLiveDock() -> [String: PlistValue] {
        var domain = baseDomain()
        // 2026-10-06：本 App 不再合成启动台 —— 抓取到的是什么就是什么。
        domain["persistent-apps"] = .array([
            .dictionary(apps(count: 1, prefix: "Live")[0].raw),
        ])
        return domain
    }

    func testResetFromLiveDockOverwritesTheBoundBar() {
        let fixture = twoDesktops()
        let preferences = FakePreferences(domain: domainWithLiveDock())
        let state = makeState(
            preferences: preferences,
            stores: makeStores("reset-live-bar"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }
        unfreeze(state)
        state.updateSettings { $0.autoApplyOnEdit = false }

        bindBar(state, to: fixture.spaces[0], apps: apps(count: 3, prefix: "Bar"))
        state.resetActiveDesktopConfigFromLiveDock()

        XCTAssertEqual(state.dockBar(for: fixture.spaces[0])?.apps.map(\.label),
                       ["Live0"], "重置的是活动桌面绑定的栏")
        XCTAssertTrue(state.dockBars.filter { $0.spaceID != nil }.count == 1, "不该给别的桌面造绑定")
    }

    func testResetFromLiveDockDoesNothingWhenTheDesktopHasNoBar() {
        // 没绑栏：没有「本桌面配置」可重置，如实记日志。
        let fixture = twoDesktops()
        let preferences = FakePreferences(domain: domainWithLiveDock())
        let state = makeState(
            preferences: preferences,
            stores: makeStores("reset-live-nobar"),
            provider: fixture.provider
        )
        state.start()
        defer { state.stop() }
        unfreeze(state)

        state.resetActiveDesktopConfigFromLiveDock()

        XCTAssertTrue(state.log.contains { $0.message.contains("当前桌面未绑定 Dock 栏") })
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

        XCTAssertTrue(state.dockBars.allSatisfy { $0.spaceID == nil })
        XCTAssertTrue(state.log.contains { $0.message.contains("读不到 com.apple.dock") })
    }

    // MARK: - 打开设置窗口的重扫与环境刷新（2026-10-06 用户规格）

    func testStageManagerChangeUpdatesAvailablePositions() {
        // 台前调度开/关要实时反映到位置选项（2 s 轮询 + 打开设置即刷）。
        let reading = Box(EnvironmentReading(stageManagerActive: true, dockSide: .bottom))
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("sm-change"),
            environment: { reading.value }
        )
        state.start()
        defer { state.stop() }

        XCTAssertEqual(state.availableBarPositions, [.bottom, .right], "台前调度开着：避开左")

        reading.value = EnvironmentReading(stageManagerActive: false, dockSide: .bottom)
        state.refreshEnvironment()

        XCTAssertEqual(state.availableBarPositions, [.bottom, .left, .right], "台前调度关了：左回来")
        XCTAssertTrue(state.log.contains { $0.message.contains("台前调度：关闭") })
    }

    func testDockSideChangeIsTrackedForSettingsHint() {
        let reading = Box(EnvironmentReading(stageManagerActive: false, dockSide: .bottom))
        let state = makeState(
            preferences: FakePreferences(domain: baseDomain()),
            stores: makeStores("dock-side"),
            environment: { reading.value }
        )
        state.start()
        defer { state.stop() }

        XCTAssertTrue(state.dockSideDescription.contains("底部"))

        reading.value = EnvironmentReading(stageManagerActive: false, dockSide: .right)
        state.refreshEnvironment()

        XCTAssertTrue(state.dockSideDescription.contains("右侧"))
        XCTAssertTrue(state.log.contains { $0.message.contains("原生 Dock 位置变化") })
    }

    // MARK: - 数据：导出 / 导入（数据 Tab，2026-10-06）

    func testExportThenImportRoundTripsTheWholeConfiguration() throws {
        let stores = makeStores("data-roundtrip")
        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: stores)
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        // 造一套可辨认的配置：一根绑定栏 + 命名 + 非默认个数。
        let barID = state.addDockBar()
        state.updateDockBarInMemory(DockBar(
            id: barID, name: "工作", position: .right,
            spaceID: FakeSpaceProvider.desktops(count: 1)[0].id,
            apps: DockStripRules.barApps(apps(count: 2, prefix: "Bar"))
        ))
        state.updateSettings { $0.menuBarIcon = .shell }

        let exportURL = stores.0.fileURL.deletingLastPathComponent()
            .appendingPathComponent("export-\(UUID().uuidString).json")
        XCTAssertTrue(state.exportConfiguration(to: exportURL))
        XCTAssertTrue(state.lastDataOperationMessage?.hasPrefix("已导出") ?? false)

        // 改乱当前状态，再导入回来，必须整份还原。
        state.updateSettings { $0.menuBarIcon = .parasol }
        state.bindDockBar(barID, to: nil)   // 绑着桌面的栏不能直接删（2026-10-06 规则）
        state.removeDockBar(id: barID)
        XCTAssertNotEqual(state.settings.menuBarIcon, .shell)

        XCTAssertTrue(state.importConfiguration(from: exportURL))
        XCTAssertEqual(state.settings.menuBarIcon, .shell)
        XCTAssertEqual(state.dockBar(id: barID)?.name, "工作")
        XCTAssertEqual(state.dockBar(id: barID)?.position, .right)
        XCTAssertEqual(state.dockBar(id: barID)?.apps.count, 2, "栏里的 2 个 App")
        XCTAssertTrue(state.log.contains { $0.message.contains("配置已导入") })

        // 导入要落盘：config.json 与导出的内容一致（整份替换）。
        let persisted = try JSONDecoder().decode(
            ConfigStore.Payload.self,
            from: Data(contentsOf: stores.0.fileURL)
        )
        XCTAssertEqual(persisted.settings.dockBars.count, state.settings.dockBars.count)
        XCTAssertTrue(persisted.settings.dockBars.contains { $0.id == barID })
    }

    func testImportRunsTheSameMigrationAsLoading() throws {
        // 导入一份旧版格式（bindings 带 override、没有 dockBars）：
        // 必须走与启动加载同一套归一化/迁移，而不是把旧格式原样塞进内存。
        let stores = makeStores("data-import-legacy")
        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: stores)
        state.start()
        defer { state.stop() }

        let spaces = FakeSpaceProvider.desktops(count: 1)[0]
        let legacy = ConfigStore.Payload(
            bindings: [DesktopBinding(
                displayUUID: spaces.displayUUID,
                spaceUUID: spaces.spaceUUID,
                customName: "旧桌面",
                override: DockConfig(pinnedApps: DockStripRules.barApps(apps(count: 1, prefix: "Legacy")))
            )],
            settings: AppSettings()
        )
        let legacyURL = stores.0.fileURL.deletingLastPathComponent()
            .appendingPathComponent("legacy-\(UUID().uuidString).json")
        try stores.0.encode(legacy).write(to: legacyURL)

        XCTAssertTrue(state.importConfiguration(from: legacyURL))

        XCTAssertEqual(state.settings.dockBars.count, DockBarCatalog.defaultBarCount, "旧格式迁移 + 补足默认 5 栏")
        let migrated = state.dockBars.first { $0.spaceID == spaces.id }
        XCTAssertEqual(migrated?.name, "旧桌面", "迁移沿用桌面名")
        XCTAssertEqual(migrated?.apps.count, 1, "1 个旧 override 的 App")
        XCTAssertTrue(state.bindings.allSatisfy { $0.override == nil }, "override 残留清空")
        XCTAssertEqual(state.lastDataOperationFailed, false, "导入成功")
    }

    func testImportRefusesInvalidFile() throws {
        let stores = makeStores("data-import-bad")
        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: stores)
        state.start()
        defer { state.stop() }

        let barsBefore = state.dockBars.count
        let badURL = stores.0.fileURL.deletingLastPathComponent()
            .appendingPathComponent("bad-\(UUID().uuidString).json")
        try Data("这不是一个配置文件".utf8).write(to: badURL)

        XCTAssertFalse(state.importConfiguration(from: badURL))
        XCTAssertEqual(state.dockBars.count, barsBefore, "导入失败不能动当前配置")
        XCTAssertEqual(state.lastDataOperationFailed, true)
        XCTAssertTrue(state.lastDataOperationMessage?.contains("不是有效的 MultiDock 配置文件") ?? false)
    }

    // MARK: - 更新检查（关于 Tab，2026-10-06）

    func testUpdateCheckReportsNewerRelease() async {
        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: makeStores("update-new"))
        state.configureUpdateChecking {
            .release(tag: "99.0.0", url: URL(string: "https://github.com/reiy-leo/side-dock/releases/tag/v99.0.0"))
        }
        state.checkForUpdates()
        await state.waitForUpdateCheck()

        XCTAssertEqual(state.updateCheckStatus,
                       .available(latest: "99.0.0",
                                  url: URL(string: "https://github.com/reiy-leo/side-dock/releases/tag/v99.0.0")))
        XCTAssertTrue(state.log.contains { $0.message.contains("发现新版本") })
    }

    func testUpdateCheckReportsUpToDateAndFailures() async {
        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: makeStores("update-same"))
        state.configureUpdateChecking { .release(tag: "0.0.0", url: nil) }
        state.checkForUpdates()
        await state.waitForUpdateCheck()
        XCTAssertEqual(state.updateCheckStatus, .upToDate(latest: "0.0.0"),
                       "本机开发版比较基线是 0.0.0，仓库 0.0.0 不算新")

        let failing = makeState(preferences: FakePreferences(domain: baseDomain()), stores: makeStores("update-fail"))
        failing.configureUpdateChecking { .failure("网络断了") }
        failing.checkForUpdates()
        await failing.waitForUpdateCheck()
        XCTAssertEqual(failing.updateCheckStatus, .failed(reason: "网络断了"))

        let empty = makeState(preferences: FakePreferences(domain: baseDomain()), stores: makeStores("update-empty"))
        empty.configureUpdateChecking { .noRelease }
        empty.checkForUpdates()
        await empty.waitForUpdateCheck()
        XCTAssertEqual(empty.updateCheckStatus, .failed(reason: "仓库还没有发布版"))
    }

    func testUpdateCheckWithoutConfigurationNeverTouchesNetwork() async {
        // 快照/单测环境不配置发布读取器：检查按钮只如实报告「未配置」，不发请求。
        let state = makeState(preferences: FakePreferences(domain: baseDomain()), stores: makeStores("update-none"))
        state.checkForUpdates()
        XCTAssertEqual(state.updateCheckStatus, .failed(reason: "更新检查未配置"))

        // 自动检查同样安全，且每次启动只自动跑一次。
        // 用 999.0.0 保证比任何运行环境的版本（xctest runner 自带 Info.plist 版本号）都新。
        state.configureUpdateChecking { .release(tag: "999.0.0", url: nil) }
        state.checkForUpdatesOncePerLaunch()
        await state.waitForUpdateCheck()
        state.checkForUpdatesOncePerLaunch()
        await state.waitForUpdateCheck()
        XCTAssertEqual(state.updateCheckStatus, .available(latest: "999.0.0", url: nil))
    }
}

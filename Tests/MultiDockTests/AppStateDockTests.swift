import XCTest
@testable import MultiDock

/// `AppState` 里「Dock 应用」这条路径 —— 也就是设置页那几个按钮点下去会发生什么。
///
/// 用测试替身替代真实偏好域与真实 Dock 进程，所以不会动用户的 Dock。
/// 真实写入链路由 `DockAcceptanceTests`（需显式开启）覆盖。
@MainActor
final class AppStateDockTests: XCTestCase {

    // MARK: - 替身

    private final class FakePreferences: DockPreferenceAccessing, @unchecked Sendable {
        private let lock = NSLock()
        private var domain: [String: PlistValue]
        private var writes = 0
        private var history: [[String: PlistValue]] = []

        init(domain: [String: PlistValue]) { self.domain = domain }

        func readDomain() -> [String: PlistValue] { lock.withLock { domain } }

        @discardableResult
        func writeWhitelisted(_ entries: [String: PlistValue]) -> Int {
            lock.withLock {
                writes += 1
                history.append(entries)
                for (key, value) in entries where DockPreferences.whitelistedKeys.contains(key) {
                    domain[key] = value
                }
                return entries.count
            }
        }

        var writeCount: Int { lock.withLock { writes } }
        var lastEntries: [String: PlistValue]? { lock.withLock { history.last } }
    }

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
        stores: (ConfigStore, BaselineStore)
    ) -> AppState {
        AppState(
            dockController: DockController(
                preferences: preferences,
                reloader: DockReloader(
                    process: process,
                    timeout: .milliseconds(200),
                    pollInterval: .milliseconds(2),
                    fallbackGrace: .milliseconds(20)
                ),
                backup: {}
            ),
            configStore: stores.0,
            baselineStore: stores.1
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
        lifecycle.restoreHandler = { XCTFail("没改过 Dock 就不该触发还原") }

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
        lifecycle.restoreHandler = { XCTFail("开关关掉就不该还原") }

        XCTAssertTrue(lifecycle.shouldTerminate())
        XCTAssertTrue(state.log.contains { $0.message.contains("已关闭退出还原") })
    }
}

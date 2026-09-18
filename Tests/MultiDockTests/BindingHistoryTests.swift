import XCTest
@testable import MultiDock

/// 孤儿绑定（`DesktopBinding` 对应的桌面已经不在了）与自动回存的撤销。
///
/// 两条都是 P5 补的：桌面被系统删掉/外接显示器被拔走后，绑定不能悄悄堆着，
/// 但也不能自动删（显示器插回来还要用）；回存误判时得能一步撤销。
@MainActor
final class BindingHistoryTests: XCTestCase {

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
        _ name: String,
        desktops: [DesktopSpace],
        activeSpaceID: UInt64
    ) -> (AppState, ConfigStore, FakeSpaceProvider) {
        let stores = makeStores(name)
        let provider = FakeSpaceProvider(desktops: desktops, activeSpaceID: activeSpaceID)
        let state = AppState(
            dockController: DockController(
                preferences: FakePreferences(domain: [
                    "orientation": .string("bottom"),
                    "tilesize": .double(36),
                    "persistent-apps": .array([]),
                    "persistent-others": .array([]),
                ]),
                reloader: DockReloader(
                    process: FakeDockProcess(),
                    timeout: .milliseconds(200),
                    pollInterval: .milliseconds(2),
                    fallbackGrace: .milliseconds(20),
                    minimumSpacing: .zero
                ),
                backup: {}
            ),
            configStore: stores.0,
            baselineStore: stores.1,
            provider: provider,
            fileLog: makeTestFileLog()
        )
        return (state, stores.0, provider)
    }

    private func config(tilesize: Double) -> DockConfig {
        var config = DockConfig()
        config.appearance.tilesize = tilesize
        return config
    }

    private func ghostSpace() -> DesktopSpace {
        DesktopSpace(displayUUID: "DISP-GONE", spaceUUID: "SPACE-GONE", id64: 999, type: 0, ordinal: 1)
    }

    // MARK: - DockEditHistory（纯逻辑）

    func testHistoryPopsThePushedConfig() {
        var history = DockEditHistory()
        XCTAssertFalse(history.canUndo(for: "k"))

        history.push(config(tilesize: 36), for: "k")
        XCTAssertTrue(history.canUndo(for: "k"))
        XCTAssertEqual(history.pop(for: "k")?.appearance.tilesize, 36)
        XCTAssertFalse(history.canUndo(for: "k"), "弹空之后不该还能撤销")
        XCTAssertNil(history.pop(for: "k"))
    }

    func testHistoryKeepsOnlyTheNewestVersions() {
        var history = DockEditHistory(depth: 2)
        history.push(config(tilesize: 1), for: "k")
        history.push(config(tilesize: 2), for: "k")
        history.push(config(tilesize: 3), for: "k")

        XCTAssertEqual(history.pop(for: "k")?.appearance.tilesize, 3)
        XCTAssertEqual(history.pop(for: "k")?.appearance.tilesize, 2)
        XCTAssertNil(history.pop(for: "k"), "超出 depth 的旧版本应被丢弃")
    }

    func testHistoryKeysAreIndependent() {
        var history = DockEditHistory()
        history.push(config(tilesize: 11), for: "a")
        history.push(config(tilesize: 22), for: "b")

        XCTAssertEqual(history.pop(for: "a")?.appearance.tilesize, 11)
        XCTAssertEqual(history.pop(for: "b")?.appearance.tilesize, 22)
    }

    func testDepthIsAtLeastOne() {
        var history = DockEditHistory(depth: 0)
        history.push(config(tilesize: 5), for: "k")
        XCTAssertEqual(history.pop(for: "k")?.appearance.tilesize, 5)
    }

    // MARK: - 孤儿绑定

    func testBindingForAMissingDesktopIsOrphaned() {
        let desktops = FakeSpaceProvider.desktops(count: 2)
        let (state, _, _) = makeState("orphan", desktops: desktops, activeSpaceID: 101)
        state.start()

        state.setCustomName("还在", for: desktops[0])
        state.setCustomName("没了", for: ghostSpace())

        XCTAssertEqual(state.orphanedBindings.count, 1)
        XCTAssertEqual(state.orphanedBindings.first?.customName, "没了")
    }

    /// 拔掉外接显示器时那台显示器上的桌面会整体消失 —— 这些绑定**绝不能**被自动删掉。
    func testOrphansAreNeverPrunedAutomatically() {
        let desktops = FakeSpaceProvider.desktops(count: 1)
        let (state, _, provider) = makeState("orphan-auto", desktops: desktops, activeSpaceID: 101)
        state.start()
        state.setCustomName("本机桌面", for: desktops[0])
        state.setCustomName("外接屏上的桌面", for: ghostSpace())

        provider.setDesktops([])          // 模拟：所有桌面都不见了（拔屏 / 系统重排）
        state.refreshDesktops()

        XCTAssertEqual(state.orphanedBindings.count, 2, "刷新后仍应列出来，一个都不许自动删")
    }

    func testPruneRemovesOrphansAndPersists() {
        let desktops = FakeSpaceProvider.desktops(count: 1)
        let (state, store, _) = makeState("orphan-prune", desktops: desktops, activeSpaceID: 101)
        state.start()
        state.setCustomName("保留", for: desktops[0])
        state.setCustomName("清理", for: ghostSpace())

        XCTAssertEqual(state.pruneOrphanedBindings(), 1)
        XCTAssertTrue(state.orphanedBindings.isEmpty)
        XCTAssertEqual(store.load().bindings.count, 1, "清理结果必须落盘")
        XCTAssertEqual(store.load().bindings.first?.customName, "保留")
        XCTAssertEqual(state.pruneOrphanedBindings(), 0, "没有孤儿时再清一次应为空操作")
    }

    // MARK: - 撤销自动回存

    func testUndoRestoresTheConfigBeforeAutoCapture() {
        let desktops = FakeSpaceProvider.desktops(count: 1)
        let (state, _, _) = makeState("undo-override", desktops: desktops, activeSpaceID: 101)
        state.start()

        state.setOverride(config(tilesize: 40), for: desktops[0], reason: "测试")
        XCTAssertEqual(state.effectiveConfig(for: desktops[0]).appearance.tilesize, 40)

        state.handleUserDockEdit(config(tilesize: 88))     // 模拟"用户在真实 Dock 上改了东西"
        XCTAssertEqual(state.effectiveConfig(for: desktops[0]).appearance.tilesize, 88)

        XCTAssertTrue(state.canUndoAutoCapture())
        XCTAssertTrue(state.undoLastAutoCapture())
        XCTAssertEqual(state.effectiveConfig(for: desktops[0]).appearance.tilesize, 40)
        XCTAssertFalse(state.canUndoAutoCapture(), "撤一次之后栈就空了")
    }

    /// 没有独立 Dock 的桌面，回存落点是默认 Dock —— 撤销也要撤到默认 Dock。
    func testUndoTargetsDefaultDockWhenDesktopInherits() {
        let desktops = FakeSpaceProvider.desktops(count: 1)
        let (state, _, _) = makeState("undo-default", desktops: desktops, activeSpaceID: 101)
        state.start()
        state.updateSettings { $0.defaultDock = self.config(tilesize: 30) }

        state.handleUserDockEdit(config(tilesize: 70))
        XCTAssertEqual(state.settings.defaultDock.appearance.tilesize, 70)

        XCTAssertTrue(state.undoLastAutoCapture())
        XCTAssertEqual(state.settings.defaultDock.appearance.tilesize, 30)
    }

    /// 关掉"识别手动改动"时根本不该产生可撤销的历史。
    func testNoHistoryWhenAutoCaptureIsDisabled() {
        let desktops = FakeSpaceProvider.desktops(count: 1)
        let (state, _, _) = makeState("undo-disabled", desktops: desktops, activeSpaceID: 101)
        state.start()
        state.updateSettings { $0.autoCaptureUserEdits = false }

        state.handleUserDockEdit(config(tilesize: 70))
        XCTAssertFalse(state.canUndoAutoCapture())
        XCTAssertFalse(state.undoLastAutoCapture())
    }
}

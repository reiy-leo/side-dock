import XCTest
@testable import MultiDock

/// 孤儿 Dock 栏（绑定的桌面已经不在了）与自动回存的撤销。
///
/// 两条都是 P5 补的：桌面被系统删掉/外接显示器被拔走后，栏不能悄悄悬空，
/// 但也不能自动删（显示器插回来还要用）；回存误判时得能一步撤销。
/// 2026-10-05 起 Dock 内容由 `DockBar` 承载，孤儿语义从「绑定」平移到「栏」。
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
        // 冻结是产品默认值；回存落点用例测的是「栏优先」的未冻结语义。
        state.updateSettings { $0.freezeNativeDockSwitching = false }
        return (state, stores.0, provider)
    }

    /// N 个互不相同的可写入条目（真实键名不同，避免归一化去重把条数压掉）。
    private func apps(_ labels: String..., prefix: String = "App") -> [DockTile] {
        labels.enumerated().map { index, label in
            DockTile.makeFileTile(
                url: URL(fileURLWithPath: "/Applications/\(label).app", isDirectory: true),
                label: label,
                bundleIdentifier: "com.example.\(prefix.lowercased())\(index)"
            )
        }
    }

    private func ghostSpace() -> DesktopSpace {
        DesktopSpace(displayUUID: "DISP-GONE", spaceUUID: "SPACE-GONE", id64: 999, type: 0, ordinal: 1)
    }

    // MARK: - DockEditHistory（纯逻辑）

    func testHistoryPopsThePushedConfig() {
        var history = DockEditHistory()
        XCTAssertFalse(history.canUndo(for: "k"))

        history.push(DockConfig(pinnedApps: apps("A")), for: "k")
        XCTAssertTrue(history.canUndo(for: "k"))
        XCTAssertEqual(history.pop(for: "k")?.pinnedApps.map(\.label), ["A"])
        XCTAssertFalse(history.canUndo(for: "k"), "弹空之后不该还能撤销")
        XCTAssertNil(history.pop(for: "k"))
    }

    func testHistoryKeepsOnlyTheNewestVersions() {
        var history = DockEditHistory(depth: 2)
        history.push(DockConfig(pinnedApps: apps("A1")), for: "k")
        history.push(DockConfig(pinnedApps: apps("A2")), for: "k")
        history.push(DockConfig(pinnedApps: apps("A3")), for: "k")

        XCTAssertEqual(history.pop(for: "k")?.pinnedApps.map(\.label), ["A3"])
        XCTAssertEqual(history.pop(for: "k")?.pinnedApps.map(\.label), ["A2"])
        XCTAssertNil(history.pop(for: "k"), "超出 depth 的旧版本应被丢弃")
    }

    func testHistoryKeysAreIndependent() {
        var history = DockEditHistory()
        history.push(DockConfig(pinnedApps: apps("A")), for: "a")
        history.push(DockConfig(pinnedApps: apps("B")), for: "b")

        XCTAssertEqual(history.pop(for: "a")?.pinnedApps.map(\.label), ["A"])
        XCTAssertEqual(history.pop(for: "b")?.pinnedApps.map(\.label), ["B"])
    }

    func testDepthIsAtLeastOne() {
        var history = DockEditHistory(depth: 0)
        history.push(DockConfig(pinnedApps: apps("A")), for: "k")
        XCTAssertEqual(history.pop(for: "k")?.pinnedApps.map(\.label), ["A"])
    }

    // MARK: - 孤儿栏

    func testBarBoundToAMissingDesktopIsOrphaned() {
        let desktops = FakeSpaceProvider.desktops(count: 2)
        let (state, _, _) = makeState("orphan", desktops: desktops, activeSpaceID: 101)
        state.start()
        state.updateSettings { $0.autoApplyOnEdit = false }

        let id = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: id, name: "孤儿", apps: DockStripRules.normalizedApps(apps("A"))))
        state.bindDockBar(id, to: ghostSpace().id)

        XCTAssertEqual(state.orphanedBars.count, 1)
        XCTAssertEqual(state.orphanedBars.first?.name, "孤儿")
    }

    /// 拔掉外接显示器时那台显示器上的桌面会整体消失 —— 这些栏**绝不能**被自动删掉。
    func testOrphanedBarsAreNeverRemovedAutomatically() {
        let desktops = FakeSpaceProvider.desktops(count: 1)
        let (state, _, provider) = makeState("orphan-auto", desktops: desktops, activeSpaceID: 101)
        state.start()
        state.updateSettings { $0.autoApplyOnEdit = false }

        let id = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: id, name: "外接屏", apps: DockStripRules.normalizedApps(apps("A"))))
        state.bindDockBar(id, to: desktops[0].id)

        provider.setDesktops([])          // 模拟：所有桌面都不见了（拔屏 / 系统重排）
        state.refreshDesktops()

        XCTAssertEqual(state.orphanedBars.count, 1, "刷新后仍应列出来，不许自动删")
        XCTAssertTrue(state.dockBars.contains { $0.name == "外接屏" }, "栏本体必须还在")
    }

    func testUnbindOrphansPersistsAndKeepsTheApps() {
        let desktops = FakeSpaceProvider.desktops(count: 1)
        let (state, store, provider) = makeState("orphan-unbind", desktops: desktops, activeSpaceID: 101)
        state.start()
        state.updateSettings { $0.autoApplyOnEdit = false }

        let id = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: id, name: "清理", apps: DockStripRules.normalizedApps(apps("A"))))
        state.bindDockBar(id, to: desktops[0].id)
        provider.setDesktops([])
        state.refreshDesktops()

        XCTAssertEqual(state.unbindOrphanedBars(), 1)
        XCTAssertTrue(state.orphanedBars.isEmpty)
        let saved = store.load().settings.dockBars.first { $0.id == id }
        XCTAssertEqual(saved?.spaceID, nil, "清理结果（解绑）必须落盘")
        XCTAssertEqual(saved?.apps.map(\.label), ["启动台", "A"], "栏的应用必须保留")
        XCTAssertEqual(state.unbindOrphanedBars(), 0, "没有孤儿时再清一次应为空操作")
    }

    // MARK: - 撤销自动回存

    func testUndoRestoresTheConfigBeforeAutoCapture() {
        let desktops = FakeSpaceProvider.desktops(count: 1)
        let (state, _, _) = makeState("undo-bar", desktops: desktops, activeSpaceID: 101)
        state.start()
        state.updateSettings { $0.autoApplyOnEdit = false }

        let id = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: id, name: "测试", apps: DockStripRules.normalizedApps(apps("A"))))
        state.bindDockBar(id, to: desktops[0].id)
        XCTAssertEqual(state.dockBar(for: desktops[0])?.apps.map(\.label), ["启动台", "A"])

        state.handleUserDockEdit(DockConfig(pinnedApps: apps("X", "Y", "Z")))   // 模拟"用户在真实 Dock 上改了东西"
        XCTAssertEqual(state.dockBar(for: desktops[0])?.apps.map(\.label), ["X", "Y", "Z"])

        XCTAssertTrue(state.canUndoAutoCapture())
        XCTAssertTrue(state.undoLastAutoCapture())
        XCTAssertEqual(state.dockBar(for: desktops[0])?.apps.map(\.label), ["启动台", "A"])
        XCTAssertFalse(state.canUndoAutoCapture(), "撤一次之后栈就空了")
    }

    /// 没绑栏的桌面，回存落点是「无处可回」（默认 Dock 是自动生成的）——
    /// 也就不该产生可撤销的历史。
    func testNoHistoryWhenTheDesktopHasNoBar() {
        let desktops = FakeSpaceProvider.desktops(count: 1)
        let (state, _, _) = makeState("undo-nobar", desktops: desktops, activeSpaceID: 101)
        state.start()

        state.handleUserDockEdit(DockConfig(pinnedApps: apps("X")))
        XCTAssertFalse(state.canUndoAutoCapture())
        XCTAssertFalse(state.undoLastAutoCapture())
        XCTAssertTrue(state.log.contains { $0.message.contains("手动改动不回存") })
    }

    /// 关掉"识别手动改动"时根本不该产生可撤销的历史。
    func testNoHistoryWhenAutoCaptureIsDisabled() {
        let desktops = FakeSpaceProvider.desktops(count: 1)
        let (state, _, _) = makeState("undo-disabled", desktops: desktops, activeSpaceID: 101)
        state.start()
        state.updateSettings { $0.autoCaptureUserEdits = false }

        state.handleUserDockEdit(DockConfig(pinnedApps: apps("X")))
        XCTAssertFalse(state.canUndoAutoCapture())
        XCTAssertFalse(state.undoLastAutoCapture())
    }
}

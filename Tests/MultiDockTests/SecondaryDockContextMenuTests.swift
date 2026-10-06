import XCTest
@testable import MultiDock

/// 次级条右键菜单（2026-10-06）：屏幕位置快捷切换。
///
/// 三层都验：菜单条目纯逻辑（`DockBarPosition.choices`，与设置页位置下拉**共用同一口径**——
/// 三条边都列出、不能用的灰掉）→ NSMenu 装配与 target 分发（真窗口见证位，rules.md
/// 「见证位」教训）→ `AppState.setDockBarPosition` 落点（与设置页同一 `dockBarEdited` 通路）。
@MainActor
final class SecondaryDockContextMenuTests: XCTestCase {

    // MARK: - 菜单条目（纯逻辑）

    func testChoicesOfferAllPositionsAndCheckmarkCurrent() {
        let choices = DockBarPosition.choices(
            current: .bottom,
            available: DockBarPosition.available(stageManagerActive: false)
        )
        XCTAssertEqual(choices.map(\.position), [.bottom, .left, .right])
        XCTAssertEqual(choices.map(\.isCurrent), [true, false, false], "勾标只在当前位置上")
        XCTAssertEqual(choices.map(\.isEnabled), [true, true, true], "三条边都可用")
    }

    func testChoicesGrayOutLeftWhileStageManagerActive() {
        let choices = DockBarPosition.choices(
            current: .bottom,
            available: DockBarPosition.available(stageManagerActive: true)
        )
        XCTAssertEqual(choices.map(\.position), [.bottom, .left, .right],
                       "不能用的选项**灰掉、不消失**（2026-10-06 用户规格）")
        XCTAssertEqual(choices.map(\.isEnabled), [true, false, true], "台前调度占左缘：左侧置灰")
    }

    func testChoicesKeepCurrentCheckedEvenWhenItIsNotAvailable() {
        // 台前调度开着，但这根栏本来就存着 .left：现状要如实展示（勾在左侧上、但灰掉），
        // 用户至少能改走。
        let choices = DockBarPosition.choices(
            current: .left,
            available: DockBarPosition.available(stageManagerActive: true)
        )
        XCTAssertEqual(choices.map(\.position), [.bottom, .left, .right])
        let left = choices.first { $0.position == .left }
        XCTAssertEqual(left?.isCurrent, true)
        XCTAssertEqual(left?.isEnabled, false)
    }

    // MARK: - 窗口装配（见证位：菜单真的接到 onPositionSelected）

    func testWindowMenuReflectsSnapshotAndDispatchesSelection() {
        let window = SecondaryDockWindow()
        window.availablePositionsProvider = { DockBarPosition.available(stageManagerActive: false) }

        var receivedID: UUID?
        var selected: [DockBarPosition] = []
        window.onPositionSelected = { id, position in
            receivedID = id
            selected.append(position)
        }

        let barID = UUID()
        window.updateContent(
            SecondaryDockContentSnapshot(items: [], iconSize: 36, position: .right, barID: barID),
            isVertical: true
        )

        let menu = window.makeContextMenu()
        XCTAssertEqual(menu.items.map(\.title), ["底部", "左侧", "右侧"])
        XCTAssertEqual(menu.items.map(\.state), [.off, .off, .on], "勾标跟快照带的当前位置走")
        XCTAssertEqual(menu.items.map(\.isEnabled), [true, true, true])

        // 走真实的 target/action 分发链（不走便利闭包），防「菜单装好了但动作没接上」的静默断线。
        _ = menu.items[0].target?.perform(menu.items[0].action!, with: menu.items[0])
        XCTAssertEqual(selected, [.bottom])
        XCTAssertEqual(receivedID, barID, "选择要带着快照里的栏 ID 落到 AppState")
    }

    func testWindowMenuGrayOutsLeftWhileStageManagerIsActive() {
        let window = SecondaryDockWindow()
        var stageManagerActive = false
        window.availablePositionsProvider = {
            DockBarPosition.available(stageManagerActive: stageManagerActive)
        }
        window.updateContent(
            SecondaryDockContentSnapshot(items: [], iconSize: 36, position: .bottom, barID: UUID()),
            isVertical: false
        )

        XCTAssertEqual(window.makeContextMenu().items.map(\.isEnabled), [true, true, true])
        stageManagerActive = true
        XCTAssertEqual(
            window.makeContextMenu().items.map(\.isEnabled), [true, false, true],
            "菜单每次右键现建 —— 台前调度开/关即时反映到可选位置（灰掉左侧、不消失）"
        )
    }

    // MARK: - AppState 落点

    func testSetDockBarPositionUpdatesBarAndPersists() throws {
        let stores = makeStores("menu-position")
        let state = makeState(stores: stores)
        let id = state.addDockBar()
        state.updateDockBarInMemory(
            DockBar(id: id, name: "测试栏", apps: DockStripRules.barApps(apps(count: 2)))
        )

        state.setDockBarPosition(id: id, to: .right)

        XCTAssertEqual(state.dockBar(id: id)?.position, .right)
        XCTAssertTrue(
            state.log.contains { $0.message.contains("位置改为右侧") && $0.message.contains("右键菜单") },
            "日志要说明改动来源：\(state.log.map(\.message))"
        )

        // 与设置页同一落点 ⇒ 落盘口径也必须一致：从存储读回核对。
        let persisted = stores.0.load().settings.dockBars.first { $0.id == id }
        XCTAssertEqual(persisted?.position, .right)
    }

    func testSetDockBarPositionIgnoresSamePositionAndUnknownBar() {
        let stores = makeStores("menu-noop")
        let state = makeState(stores: stores)
        let id = state.addDockBar()
        state.updateDockBarInMemory(
            DockBar(id: id, name: "测试栏", apps: DockStripRules.barApps(apps(count: 2)))
        )
        let editLogsBefore = state.log.filter { $0.message.contains("已修改") }.count

        state.setDockBarPosition(id: id, to: .bottom)   // 位置没变
        state.setDockBarPosition(id: UUID(), to: .right) // 栏不存在（快照滞后一拍的过期 ID）

        XCTAssertEqual(state.dockBar(id: id)?.position, .bottom)
        XCTAssertEqual(
            state.log.filter { $0.message.contains("已修改") }.count, editLogsBefore,
            "无变化的选择不该落盘也不该刷日志"
        )
    }

    func testSecondaryDockContentCarriesBarIDAndPosition() {
        let spaces = FakeSpaceProvider.desktops(count: 1)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let state = makeState(
            stores: makeStores("menu-content"),
            provider: provider
        )
        state.updateSettings { $0.autoApplyOnEdit = false }
        let id = state.addDockBar()
        state.updateDockBarInMemory(
            DockBar(id: id, name: "栏", position: .right, apps: DockStripRules.barApps(apps(count: 2)))
        )
        state.bindDockBar(id, to: spaces[0].id)

        let snapshot = state.secondaryDockContent(for: spaces[0])

        XCTAssertEqual(snapshot?.barID, id, "快照必须带栏 ID，右键菜单才知道改谁")
        XCTAssertEqual(snapshot?.position, .right)
    }

    // MARK: - 复用 AppStateDockTests 的装配口径

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
        stores: (ConfigStore, BaselineStore),
        provider: FakeSpaceProvider? = nil
    ) -> AppState {
        let injectedApps = apps(count: 1, prefix: "Default")
        let state = AppState(
            dockController: DockController(
                preferences: FakePreferences(domain: baseDomain()),
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
            provider: provider ?? FakeSpaceProvider(isAvailable: false, reason: "测试替身"),
            fileLog: makeTestFileLog(),
            environmentReader: {
                EnvironmentReading(stageManagerActive: false, dockSide: .bottom)
            }
        )
        // 默认按「未冻结」起跑（与其他测试文件同口径）。
        state.updateSettings { $0.freezeNativeDockSwitching = false }
        return state
    }

    private func apps(count: Int, prefix: String = "App") -> [DockTile] {
        (0..<count).map { index in
            DockTile.makeFileTile(
                url: URL(fileURLWithPath: "/Applications/\(prefix)\(index).app", isDirectory: true),
                label: "\(prefix)\(index)",
                bundleIdentifier: "com.example.\(prefix.lowercased())\(index)"
            )
        }
    }
}

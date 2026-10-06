import XCTest
@testable import MultiDock

/// 「原生 Dock 里已固定的 App 不在自定义 Dock 栏里重复显示」（2026-10-06 用户规格）——
/// `AppState` 侧的集成行为：自动剔除、触发点、未冻结不生效、落盘只走一道闸。
///
/// 规则层（身份键 / 剔除 / 添加拦截文案）在 `DockStripRulesTests` 里单独覆盖。
/// 全部用替身，不会碰用户的 Dock。
@MainActor
final class NativeDockExclusionTests: XCTestCase {

    private func baseDomain(nativeApps: [DockTile] = []) -> [String: PlistValue] {
        [
            "orientation": .string("bottom"),
            "tilesize": .double(36),
            "magnification": .bool(true),
            "largesize": .double(98),
            "autohide": .bool(false),
            "mineffect": .string("scale"),
            "minimize-to-application": .bool(true),
            "persistent-apps": .array(nativeApps.map { .dictionary($0.raw) }),
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

    private func tile(_ path: String, label: String, bundle: String? = nil) -> DockTile {
        DockTile.makeFileTile(
            url: URL(fileURLWithPath: path, isDirectory: true),
            label: label,
            bundleIdentifier: bundle ?? "com.example.\(label.lowercased())"
        )
    }

    /// 冻结（产品默认）起跑的夹具。`reloadLiveDomain` = 模拟"用户又改了原生 Dock"。
    private func makeState(
        _ name: String,
        nativeApps: [DockTile] = [],
        frozen: Bool = true,
        spaces: [DesktopSpace] = []
    ) -> (state: AppState, preferences: FakePreferences, stores: (ConfigStore, BaselineStore)) {
        let stores = makeStores(name)
        let preferences = FakePreferences(domain: baseDomain(nativeApps: nativeApps))
        let state = AppState(
            dockController: DockController(
                preferences: preferences,
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
            provider: spaces.isEmpty
                ? FakeSpaceProvider(isAvailable: false, reason: "测试替身")
                : FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64),
            fileLog: makeTestFileLog(),
            environmentReader: { EnvironmentReading(stageManagerActive: false, dockSide: .bottom) }
        )
        state.updateSettings { $0.freezeNativeDockSwitching = frozen }
        return (state, preferences, stores)
    }

    private func apps(count: Int, prefix: String = "App") -> [DockTile] {
        (0..<count).map { index in
            tile("/Applications/\(prefix)\(index).app", label: "\(prefix)\(index)")
        }
    }

    /// 一根装着 `apps` 的栏。`dockBarEdited` 会走落盘闸门 —— 想测"闸门"就得绕过它，
    /// 所以这里只写内存（`updateDockBarInMemory`），让测试显式选择要不要过闸。
    @discardableResult
    private func seedBar(_ state: AppState, apps barApps: [DockTile], name: String = "工作栏") -> UUID {
        let id = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: id, name: name, apps: barApps))
        return id
    }

    // MARK: - 启动载入即剔除

    /// 老配置里带着"原生 Dock 也有"的 App（规则上线前加的）→ 载入时就地剔除并落盘。
    func testLoadingConfigPrunesAppsPinnedInNativeDock() throws {
        let stores = makeStores("prune-on-load")
        let safari = tile("/Applications/Safari.app", label: "Safari", bundle: "com.apple.Safari")
        let barID = UUID()
        var settings = AppSettings()
        // 冻结也写进配置文件：`start()` 载入的就是这份（不能先 updateSettings —— 会落盘覆盖它）。
        settings.freezeNativeDockSwitching = true
        settings.dockBars = [DockBar(
            id: barID,
            name: "工作栏",
            apps: [
                tile("/Applications/Xcode.app", label: "Xcode"),
                safari,
                tile("/Applications/Notes.app", label: "Notes"),
            ]
        )]
        try stores.0.save(.init(bindings: [], settings: settings))

        let preferences = FakePreferences(domain: baseDomain(nativeApps: [safari]))
        let state = AppState(
            dockController: DockController(
                preferences: preferences,
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
            provider: FakeSpaceProvider(isAvailable: false, reason: "测试替身"),
            fileLog: makeTestFileLog(),
            environmentReader: { EnvironmentReading(stageManagerActive: false, dockSide: .bottom) }
        )
        state.start()
        defer { state.stop() }

        XCTAssertEqual(state.dockBar(id: barID)?.apps.map(\.label), ["Xcode", "Notes"],
                       "载入即剔除原生 Dock 里已有的 Safari，其余原样保序")
        XCTAssertTrue(state.isPinnedInNativeDock(safari), "排除集应已建立")
        XCTAssertTrue(state.log.contains { $0.message.contains("已自动剔除") },
                      "要如实告知剔除了什么：\(state.log.map(\.message))")

        // 剔除结果必须落盘 —— 否则下次启动又看到坏数据。
        let reloaded = try stores.0.load()
        XCTAssertEqual(reloaded.settings.dockBars.first { $0.id == barID }?.apps.map(\.label),
                       ["Xcode", "Notes"])
    }

    // MARK: - 手动改动原生 Dock

    /// 用户在原生 Dock 上钉了一个已在栏里的 App → 冻结模式下重算排除集并剔除。
    func testManualNativeDockChangePrunesTheBar() {
        let (state, preferences, _) = makeState("manual-prune")
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        let xcode = tile("/Applications/Xcode.app", label: "Xcode")
        let bar = seedBar(state, apps: [xcode])
        XCTAssertEqual(state.dockBar(id: bar)?.apps.count, 1, "前提：此刻原生 Dock 是空的")

        // 用户把 Xcode 拖进了原生 Dock → watcher 上报手动改动。
        preferences.replaceDomain(baseDomain(nativeApps: [xcode]))
        state.handleUserDockEdit(DockConfig(pinnedApps: [xcode], otherItems: []))

        XCTAssertEqual(state.dockBar(id: bar)?.apps.count, 0, "栏里的 Xcode 应被自动剔除")
        XCTAssertTrue(state.isPinnedInNativeDock(xcode))
    }

    /// 未冻结时不适用：原生 Dock 的内容就是我们写下去的栏内容，
    /// 拿它当排除集会把栏自己清空（自噬）—— 这条守着别把开关方向搞反。
    func testExclusionIsInertWhenNotFrozen() {
        let xcode = tile("/Applications/Xcode.app", label: "Xcode")
        let (state, _, _) = makeState("unfrozen", nativeApps: [xcode], frozen: false)
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        let bar = seedBar(state, apps: [xcode])
        state.dockBarEdited(state.dockBar(id: bar)!, reason: "测试")

        XCTAssertEqual(state.dockBar(id: bar)?.apps.count, 1, "未冻结时原生 Dock 的内容不算排除集")
        XCTAssertFalse(state.isPinnedInNativeDock(xcode))
    }

    /// 冻结开关两个方向：开 → 建立排除集并剔除；关 → 排除集清空（解冻后原生归我们写）。
    func testFreezeSwitchRecomputesTheExclusionSet() {
        let xcode = tile("/Applications/Xcode.app", label: "Xcode")
        let (state, _, _) = makeState("freeze-toggle", nativeApps: [xcode], frozen: false)
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        let bar = seedBar(state, apps: [xcode])
        XCTAssertEqual(state.dockBar(id: bar)?.apps.count, 1)

        state.setFreezeNativeDockSwitching(true)
        XCTAssertEqual(state.dockBar(id: bar)?.apps.count, 0, "开启冻结：栏里的重复项被剔除")

        state.setFreezeNativeDockSwitching(false)
        XCTAssertFalse(state.isPinnedInNativeDock(xcode), "关闭冻结：排除集清空")
    }

    // MARK: - 落盘闸门（任何入口都不许把重复项留在栏里）

    func testDockBarEditedRefusesPinnedApps() {
        let xcode = tile("/Applications/Xcode.app", label: "Xcode")
        let (state, _, _) = makeState("edited-gate", nativeApps: [xcode])
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        let bar = state.addDockBar()
        state.dockBarEdited(
            DockBar(id: bar, name: "工作栏", apps: [
                xcode,
                tile("/Applications/Notes.app", label: "Notes"),
            ]),
            reason: "测试"
        )

        XCTAssertEqual(state.dockBar(id: bar)?.apps.map(\.label), ["Notes"])
        XCTAssertTrue(state.log.contains { $0.level == .warning && $0.message.contains("已固定在原生 Dock") },
                      "拦下必须留痕：\(state.log.map(\.message))")
    }

    // MARK: - 展示路径

    /// 次级条内容也过一道：配置被外部改过时条上不该先冒出来再等剔除。
    func testSecondaryDockContentHidesPinnedApps() {
        let spaces = FakeSpaceProvider.desktops(count: 1)
        let xcode = tile("/Applications/Xcode.app", label: "Xcode")
        let (state, _, _) = makeState("content-path", nativeApps: [xcode], spaces: spaces)
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.autoApplyOnEdit = false }

        let notes = tile("/Applications/Notes.app", label: "Notes")
        let bar = seedBar(state, apps: [xcode, notes])
        state.bindDockBar(bar, to: spaces[0].id)

        XCTAssertEqual(state.secondaryDockContent(for: spaces[0])?.items.map(\.label), ["Notes"],
                       "排除集在展示路径同样生效")

        // 全是被排除的 → 没有可显示内容（条隐藏）。
        state.updateDockBarInMemory(DockBar(id: bar, name: "工作栏", apps: [xcode]))
        XCTAssertNil(state.secondaryDockContent(for: spaces[0]))
    }
}

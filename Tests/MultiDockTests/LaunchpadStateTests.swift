import XCTest
@testable import MultiDock

/// 「启动台」页在 `AppState` 侧的接线：读取状态、两个搬运动作、冻结模式的排除集。
///
/// 全部用替身（假的启动台数据源 + 假偏好域），不碰真实数据库、不碰用户的 Dock。
@MainActor
final class LaunchpadStateTests: XCTestCase {

    private func baseDomain(nativeApps: [DockTile] = []) -> [String: PlistValue] {
        [
            "orientation": .string("bottom"),
            "tilesize": .double(36),
            "persistent-apps": .array(nativeApps.map { .dictionary($0.raw) }),
            "persistent-others": .array([]),
            "mru-spaces": .bool(true),
            "mod-count": .int(1),
        ]
    }

    private func tile(_ name: String, bundle: String? = nil) -> DockTile {
        DockTile.makeFileTile(
            url: URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true),
            label: name,
            bundleIdentifier: bundle ?? "com.example.\(name.lowercased())"
        )
    }

    private func makeState(
        _ name: String,
        launchpad: LaunchpadLoader = makeFakeLaunchpadLoader(),
        nativeApps: [DockTile] = [],
        frozen: Bool = true
    ) -> (state: AppState, stores: (ConfigStore, BaselineStore)) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-lpstate-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stores = (
            ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            BaselineStore(
                baselineURL: directory.appendingPathComponent("baseline.plist"),
                markerURL: directory.appendingPathComponent("session.state"),
                backupsURL: directory.appendingPathComponent("backups", isDirectory: true)
            )
        )
        let state = AppState(
            dockController: DockController(
                preferences: FakePreferences(domain: baseDomain(nativeApps: nativeApps)),
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
            launchpadLoader: launchpad,
            environmentReader: { EnvironmentReading(stageManagerActive: false, dockSide: .bottom) }
        )
        state.updateSettings { $0.freezeNativeDockSwitching = frozen }
        state.refreshNativeDockPinnedApps(reason: "测试")
        return (state, stores)
    }

    private func loadedFolders(_ folders: [LaunchpadFolder]) -> LaunchpadLoader {
        makeFakeLaunchpadLoader(folders: folders)
    }

    // MARK: - 读取状态

    /// macOS 26+：状态是"系统没有启动台"，不碰数据库。
    func testUnsupportedSystemReportsStatus() {
        let (state, _) = makeState(
            "unsupported",
            launchpad: makeFakeLaunchpadLoader(isSystemSupported: false)
        )
        state.refreshLaunchpadFolders()
        XCTAssertEqual(state.launchpadStatus, .unsupportedSystem)
        XCTAssertTrue(state.launchpadFolders.isEmpty)
        XCTAssertTrue(
            state.log.contains { $0.message.contains("没有启动台") },
            "该有一条「本机没有启动台」的说明"
        )
    }

    /// 读不到数据库：状态带原因（供页面显示），不崩、不静默空列表。
    func testUnavailableDatabaseReportsReason() {
        let (state, _) = makeState(
            "unavailable",
            launchpad: makeFakeLaunchpadLoader(error: .missing("/tmp/nowhere/db"))
        )
        state.refreshLaunchpadFolders()
        XCTAssertEqual(state.launchpadStatus, .unavailable(LaunchpadDatabaseError.missing("/tmp/nowhere/db").userMessage))
        XCTAssertTrue(state.launchpadFolders.isEmpty)
    }

    func testLoadedFoldersArePublished() {
        let (state, _) = makeState("loaded", launchpad: loadedFolders([
            makeLaunchpadFolder(itemID: 1, name: "工具", apps: [("计算器", tile("Calc"))]),
            makeLaunchpadFolder(itemID: 2, name: "办公", apps: [("文档", tile("Docs"))]),
        ]))
        state.refreshLaunchpadFolders()
        XCTAssertEqual(state.launchpadStatus, .loaded)
        XCTAssertEqual(state.launchpadFolders.map(\.name), ["工具", "办公"])
    }

    /// 同一结果重复刷新只记一次日志（切回本页会反复调它，日志不该被灌满）。
    func testRepeatedRefreshLogsOnce() {
        let (state, _) = makeState("logs-once", launchpad: loadedFolders([
            makeLaunchpadFolder(itemID: 1, name: "工具", apps: [("计算器", tile("Calc"))]),
        ]))
        state.refreshLaunchpadFolders()
        let count = state.log.filter { $0.message.contains("启动台：读到") }.count
        state.refreshLaunchpadFolders()
        state.refreshLaunchpadFolders()
        XCTAssertEqual(state.log.filter { $0.message.contains("启动台：读到") }.count, count)
    }

    // MARK: - 添加到 Dock 栏

    func testAddFolderAppendsToBarAndPersists() throws {
        let folder = makeLaunchpadFolder(itemID: 1, name: "工具", apps: [
            ("A", tile("A")), ("B", tile("B")),
        ])
        let (state, stores) = makeState("add", launchpad: loadedFolders([folder]))
        let barID = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: barID, name: "目标栏", apps: [tile("Existing")]))
        state.persistConfiguration()

        let outcome = state.addLaunchpadFolder(folder, to: barID)
        XCTAssertFalse(outcome.failed)
        XCTAssertEqual(state.dockBar(id: barID)?.apps.map(\.label), ["Existing", "A", "B"])

        // 落了盘：重新读配置文件能看到三样东西。
        let payload = stores.0.load()
        XCTAssertEqual(
            payload.settings.dockBars.first { $0.id == barID }?.apps.map(\.label),
            ["Existing", "A", "B"]
        )
    }

    func testAddToMissingBarFails() {
        let folder = makeLaunchpadFolder(itemID: 1, name: "工具", apps: [("A", tile("A"))])
        let (state, _) = makeState("add-missing", launchpad: loadedFolders([folder]))
        let outcome = state.addLaunchpadFolder(folder, to: UUID())
        XCTAssertTrue(outcome.failed)
        XCTAssertTrue(outcome.message.contains("已不存在"))
    }

    /// 目标栏里已经有这个 App → 不重复加；结果里说明跳过了几个。
    func testAddSkipsDuplicatesAndSaysSo() {
        let folder = makeLaunchpadFolder(itemID: 1, name: "工具", apps: [
            ("A", tile("A")), ("B", tile("B")),
        ])
        let (state, _) = makeState("add-dup", launchpad: loadedFolders([folder]))
        let barID = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: barID, name: "目标栏", apps: [tile("A")]))

        let outcome = state.addLaunchpadFolder(folder, to: barID)
        XCTAssertFalse(outcome.failed)
        XCTAssertEqual(state.dockBar(id: barID)?.apps.map(\.label), ["A", "B"])
        XCTAssertTrue(outcome.message.contains("跳过"), "跳过的账要如实写进结果：\(outcome.message)")
    }

    /// 一个都加不进去（全被跳过）→ 当成失败如实说明，而不是静默"成功"。
    func testAddWithNothingEligibleReportsFailure() {
        let folder = makeLaunchpadFolder(itemID: 1, name: "工具", apps: [("A", tile("A"))])
        let (state, _) = makeState("add-none", launchpad: loadedFolders([folder]))
        let barID = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: barID, name: "目标栏", apps: [tile("A")]))

        let outcome = state.addLaunchpadFolder(folder, to: barID)
        XCTAssertTrue(outcome.failed)
        XCTAssertEqual(state.dockBar(id: barID)?.apps.map(\.label), ["A"], "内容不该变")
    }

    /// 冻结模式：已固定在原生 Dock 的 App 不重复加入（既有规则在搬运路径同样生效）。
    func testAddExcludesAppsPinnedInNativeDockWhenFrozen() {
        let safari = tile("Safari", bundle: "com.apple.Safari")
        let folder = makeLaunchpadFolder(itemID: 1, name: "工具", apps: [
            ("Xcode", tile("Xcode")), ("Safari", safari),
        ])
        let (state, _) = makeState("add-pinned", launchpad: loadedFolders([folder]), nativeApps: [safari])
        let barID = state.addDockBar()

        let outcome = state.addLaunchpadFolder(folder, to: barID)
        XCTAssertFalse(outcome.failed)
        XCTAssertEqual(state.dockBar(id: barID)?.apps.map(\.label), ["Xcode"])
        XCTAssertTrue(outcome.message.contains("原生 Dock"), "要说清为什么少了 Safari：\(outcome.message)")
    }

    /// 未冻结：排除集不适用（原生 Dock 里就是我们写的内容，拿它排除会把栏清空）。
    func testAddKeepsPinnedAppsWhenNotFrozen() {
        let safari = tile("Safari", bundle: "com.apple.Safari")
        let folder = makeLaunchpadFolder(itemID: 1, name: "工具", apps: [("Safari", safari)])
        let (state, _) = makeState(
            "add-unfrozen", launchpad: loadedFolders([folder]), nativeApps: [safari], frozen: false
        )
        let barID = state.addDockBar()
        _ = state.addLaunchpadFolder(folder, to: barID)
        XCTAssertEqual(state.dockBar(id: barID)?.apps.map(\.label), ["Safari"])
    }

    // MARK: - 替换 Dock 栏

    func testReplaceSwapsBarContents() {
        let folder = makeLaunchpadFolder(itemID: 1, name: "新内容", apps: [
            ("N1", tile("N1")), ("N2", tile("N2")),
        ])
        let (state, _) = makeState("replace", launchpad: loadedFolders([folder]))
        let barID = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: barID, name: "目标栏", apps: [tile("Old1"), tile("Old2")]))

        let outcome = state.replaceDockBar(barID, withLaunchpadFolder: folder)
        XCTAssertFalse(outcome.failed)
        XCTAssertEqual(state.dockBar(id: barID)?.apps.map(\.label), ["N1", "N2"])
        XCTAssertTrue(outcome.message.contains("2 个图标 → 2 个"), "结果要写清前后数量：\(outcome.message)")
    }

    /// 目标栏已经就是这个文件夹的内容 → 不落盘、如实说"未做改动"。
    func testReplaceIdenticalContentIsNoOp() {
        let folder = makeLaunchpadFolder(itemID: 1, name: "相同", apps: [
            ("A", tile("A")), ("B", tile("B")),
        ])
        let (state, _) = makeState("replace-same", launchpad: loadedFolders([folder]))
        let barID = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: barID, name: "目标栏", apps: [tile("A"), tile("B")]))

        let outcome = state.replaceDockBar(barID, withLaunchpadFolder: folder)
        XCTAssertFalse(outcome.failed)
        XCTAssertTrue(outcome.message.contains("未做改动"), outcome.message)
    }

    /// 文件夹里没有可搬的内容 → 失败，且**目标栏的内容一个都不动**（不做破坏性清空）。
    func testReplaceWithNothingUsableLeavesBarUntouched() {
        let folder = makeLaunchpadFolder(itemID: 1, name: "空", apps: [("无", nil)])
        let (state, _) = makeState("replace-empty", launchpad: loadedFolders([folder]))
        let barID = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: barID, name: "目标栏", apps: [tile("Keep")]))

        let outcome = state.replaceDockBar(barID, withLaunchpadFolder: folder)
        XCTAssertTrue(outcome.failed)
        XCTAssertEqual(state.dockBar(id: barID)?.apps.map(\.label), ["Keep"])
    }

    /// 未绑定栏被启动台替换后仍能正常工作（不碰绑定、不碰位置）。
    func testReplaceKeepsBarBindingAndPosition() {
        let folder = makeLaunchpadFolder(itemID: 1, name: "新", apps: [("A", tile("A"))])
        let (state, _) = makeState("replace-keeps", launchpad: loadedFolders([folder]))
        let barID = state.addDockBar()
        state.updateDockBarInMemory(DockBar(
            id: barID, name: "保留栏", position: .right, spaceID: "DISP#SPACE", apps: []
        ))
        _ = state.replaceDockBar(barID, withLaunchpadFolder: folder)
        let bar = state.dockBar(id: barID)
        XCTAssertEqual(bar?.position, .right)
        XCTAssertEqual(bar?.spaceID, "DISP#SPACE")
        XCTAssertEqual(bar?.name, "保留栏")
    }
}

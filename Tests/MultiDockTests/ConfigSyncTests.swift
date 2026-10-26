import AppKit
import XCTest
@testable import MultiDock

/// 配置同步到云盘文件夹（2026-10-26 用户规格：「每台电脑有一个单独的同步，互不干扰」）
/// 与配套的「缺 App 过滤」。
///
/// 全部在临时目录里跑：不碰真实云盘、不碰用户的 config.json、不碰真实 Dock。
@MainActor
final class ConfigSyncTests: XCTestCase {

    // MARK: - 夹具

    private func tempDirectory(_ name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-sync-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func tile(_ path: String, label: String, bundle: String? = nil) -> DockTile {
        DockTile.makeFileTile(
            url: URL(fileURLWithPath: path, isDirectory: true),
            label: label,
            bundleIdentifier: bundle ?? "com.example.\(label.lowercased())"
        )
    }

    private func space(_ display: String, _ uuid: String, ordinal: Int, id64: UInt64) -> DesktopSpace {
        DesktopSpace(displayUUID: display, spaceUUID: uuid, id64: id64, type: 0, ordinal: ordinal)
    }

    private func snapshot(
        deviceID: String = "DEVICE-A",
        writtenAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        bars: [DockBar] = [],
        bindings: [DesktopBinding] = [],
        ordinals: [String: SpaceOrdinal] = [:]
    ) -> SyncSnapshot {
        var settings = AppSettings()
        settings.dockBars = bars
        return SyncSnapshot(
            deviceID: deviceID,
            deviceName: "Mac \(deviceID)",
            appVersion: "0.2.1 (9)",
            writtenAt: writtenAt,
            spaceOrdinals: ordinals,
            config: ConfigStore.Payload(bindings: bindings, settings: settings)
        )
    }

    // MARK: - 设备文件名

    func testFileNameIsDeviceIDDotJSON() {
        XCTAssertEqual(
            ConfigSync.fileName(deviceID: "12345678-ABCD-4EF0-9999-000000000000"),
            "12345678-ABCD-4EF0-9999-000000000000.json"
        )
    }

    func testFileNameStripsPathSeparatorsAndLeadingDots() {
        XCTAssertEqual(ConfigSync.fileName(deviceID: "../evil/id"), "evil-id.json", "不能变成子目录或隐藏文件")
        XCTAssertFalse(ConfigSync.fileName(deviceID: ".hidden").hasPrefix("."))
        XCTAssertEqual(ConfigSync.fileName(deviceID: ""), "device.json")
    }

    // MARK: - 剔除本机专属字段

    func testSyncPayloadDropsLocalOnlyFields() {
        var settings = AppSettings()
        settings.dockBars = [DockBar(name: "工作", spaceID: "D#S1", apps: [tile("/Applications/A.app", label: "A")])]
        settings.secondaryDockRowPrefs = ["D#S1|bottom": SecondaryDockRowPref(anchorBarID: UUID())]
        let binding = DesktopBinding(
            displayUUID: "D", spaceUUID: "S1", customName: "写代码",
            override: DockConfig(pinnedApps: [tile("/Applications/B.app", label: "B")])
        )

        let synced = ConfigSync.syncPayload(from: .init(bindings: [binding], settings: settings))

        XCTAssertTrue(synced.settings.secondaryDockRowPrefs.isEmpty, "上次滚到哪一行是本机专属")
        XCTAssertNil(synced.bindings.first?.override, "废弃的迁移字段不带")
        XCTAssertEqual(synced.bindings.first?.customName, "写代码", "桌面命名要同步")
        XCTAssertEqual(synced.settings.dockBars.count, 1, "栏要同步")
        XCTAssertEqual(synced.settings.dockBars.first?.apps.count, 1)
    }

    func testImportKeepsLocalOnlyFields() {
        var local = AppSettings()
        let anchor = UUID()
        local.secondaryDockRowPrefs = ["L#S|bottom": SecondaryDockRowPref(anchorBarID: anchor)]
        var incoming = ConfigStore.Payload()
        incoming.settings.restoreOnQuit = false

        let merged = ConfigSync.keepingLocalOnlyFields(incoming, local: local)

        XCTAssertEqual(merged.settings.secondaryDockRowPrefs["L#S|bottom"]?.anchorBarID, anchor)
        XCTAssertFalse(merged.settings.restoreOnQuit, "其余设置照导入的来")
    }

    // MARK: - 桌面序号与映射

    func testOrdinalsPutMainDisplayFirst() {
        let desktops = [
            space("EXT", "E1", ordinal: 1, id64: 1),
            space("EXT", "E2", ordinal: 2, id64: 2),
            space("MAIN", "M1", ordinal: 1, id64: 3),
        ]
        let ordinals = ConfigSync.ordinals(for: desktops, mainDisplayUUID: "main")
        XCTAssertEqual(ordinals["MAIN#M1"], SpaceOrdinal(display: 1, desktop: 1), "主屏排第一（大小写不敏感）")
        XCTAssertEqual(ordinals["EXT#E2"], SpaceOrdinal(display: 2, desktop: 2))
    }

    func testOrdinalsTreatSkyLightMainAsMainDisplay() {
        let desktops = [space("EXT", "E1", ordinal: 1, id64: 1), space("Main", "M1", ordinal: 1, id64: 2)]
        XCTAssertEqual(ConfigSync.ordinals(for: desktops, mainDisplayUUID: nil)["Main#M1"]?.display, 1)
    }

    func testMapSpacesByDisplayAndDesktopOrder() {
        let source = [
            "SRC-MAIN#a": SpaceOrdinal(display: 1, desktop: 1),
            "SRC-MAIN#b": SpaceOrdinal(display: 1, desktop: 2),
            "SRC-MAIN#c": SpaceOrdinal(display: 1, desktop: 4),
            "SRC-EXT#x": SpaceOrdinal(display: 2, desktop: 1),
        ]
        var settings = AppSettings()
        settings.dockBars = [
            DockBar(name: "一", spaceID: "SRC-MAIN#b"),
            DockBar(name: "二", spaceID: "SRC-EXT#x"),
            DockBar(name: "三", spaceID: "SRC-MAIN#c"),
            DockBar(name: "四", spaceID: nil),
        ]
        let bindings = [
            DesktopBinding(displayUUID: "SRC-MAIN", spaceUUID: "b", customName: "写作", override: nil),
            DesktopBinding(displayUUID: "SRC-MAIN", spaceUUID: "c", customName: "第四", override: nil),
        ]
        let local = [
            space("LOCAL-EXT", "y1", ordinal: 1, id64: 10),
            space("LOCAL-MAIN", "m1", ordinal: 1, id64: 11),
            space("LOCAL-MAIN", "m2", ordinal: 2, id64: 12),
            space("LOCAL-MAIN", "m3", ordinal: 3, id64: 13),
        ]

        let (mapped, report) = ConfigSync.mapSpaces(
            in: .init(bindings: bindings, settings: settings),
            sourceOrdinals: source,
            localDesktops: local,
            mainDisplayUUID: "LOCAL-MAIN"
        )

        XCTAssertEqual(mapped.settings.dockBars[0].spaceID, "LOCAL-MAIN#m2", "主屏第 2 个桌面 → 本机主屏第 2 个")
        XCTAssertEqual(mapped.settings.dockBars[1].spaceID, "LOCAL-EXT#y1", "第 2 块屏第 1 个 → 本机第 2 块屏第 1 个")
        XCTAssertEqual(mapped.settings.dockBars[2].spaceID, "SRC-MAIN#c", "本机没有第 4 个桌面：保留原 ID 成孤儿")
        XCTAssertNil(mapped.settings.dockBars[3].spaceID, "未绑定的栏不动")
        XCTAssertEqual(report, ConfigSync.MappingReport(kept: 0, mapped: 2, orphaned: 1))
        XCTAssertEqual(mapped.bindings.first(where: { $0.customName == "写作" })?.id, "LOCAL-MAIN#m2", "桌面命名同一规则")
    }

    func testMapSpacesKeepsIDsThatExistLocally() {
        var settings = AppSettings()
        settings.dockBars = [DockBar(name: "本机", spaceID: "D#S2")]
        let local = [space("D", "S1", ordinal: 1, id64: 1), space("D", "S2", ordinal: 2, id64: 2)]
        // 序号故意写错：本机已有这个桌面 ID 时以 ID 为准。
        let (mapped, report) = ConfigSync.mapSpaces(
            in: .init(bindings: [], settings: settings),
            sourceOrdinals: ["D#S2": SpaceOrdinal(display: 1, desktop: 1)],
            localDesktops: local,
            mainDisplayUUID: "D"
        )
        XCTAssertEqual(mapped.settings.dockBars[0].spaceID, "D#S2")
        XCTAssertEqual(report.kept, 1)
    }

    func testMapSpacesDedupesNamesOnTheSameDesktop() {
        let bindings = [
            DesktopBinding(displayUUID: "L", spaceUUID: "s1", customName: "本机名", override: nil),
            DesktopBinding(displayUUID: "R", spaceUUID: "r1", customName: "远端名", override: nil),
        ]
        let (mapped, _) = ConfigSync.mapSpaces(
            in: .init(bindings: bindings, settings: AppSettings()),
            sourceOrdinals: ["R#r1": SpaceOrdinal(display: 1, desktop: 1)],
            localDesktops: [space("L", "s1", ordinal: 1, id64: 1)],
            mainDisplayUUID: "L"
        )
        XCTAssertEqual(mapped.bindings.count, 1, "一个桌面只留一条名字")
        XCTAssertEqual(mapped.bindings.first?.customName, "本机名")
    }

    // MARK: - 写文件：只写自己那份、内容没变不重写

    func testWriteCreatesOwnFileUnderSideDock() throws {
        let root = tempDirectory("write")
        let folder = ConfigSyncFolder(root: root)

        XCTAssertEqual(try folder.write(snapshot(deviceID: "DEVICE-A")), .written)

        let file = root.appendingPathComponent("SideDock/DEVICE-A.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("SideDock").path)
        XCTAssertEqual(leftovers, ["DEVICE-A.json"], "临时文件不留下")
    }

    func testUnchangedContentIsNotRewritten() throws {
        let root = tempDirectory("unchanged")
        let folder = ConfigSyncFolder(root: root)
        let first = snapshot(writtenAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(try folder.write(first), .written)
        let file = root.appendingPathComponent("SideDock/DEVICE-A.json")
        let before = try Data(contentsOf: file)

        var later = first
        later.writtenAt = Date(timeIntervalSince1970: 1_800_000_600)
        XCTAssertEqual(try folder.write(later), .unchanged, "只有写入时间不同 = 内容没变")
        XCTAssertEqual(try Data(contentsOf: file), before, "文件一个字节都没动（写入时间还是旧的）")

        var changed = later
        changed.config.settings.restoreOnQuit = false
        XCTAssertEqual(try folder.write(changed), .written, "内容变了才写")
        XCTAssertNotEqual(try Data(contentsOf: file), before)
    }

    func testWriteNeverTouchesOtherDevicesFiles() throws {
        let root = tempDirectory("others")
        let folder = ConfigSyncFolder(root: root)
        XCTAssertEqual(try folder.write(snapshot(deviceID: "DEVICE-B")), .written)
        let otherFile = root.appendingPathComponent("SideDock/DEVICE-B.json")
        let otherBefore = try Data(contentsOf: otherFile)

        var mine = snapshot(deviceID: "DEVICE-A")
        mine.config.settings.restoreOnQuit = false
        XCTAssertEqual(try folder.write(mine), .written)

        XCTAssertEqual(try Data(contentsOf: otherFile), otherBefore, "别的设备那份原样不动")
        let listed = try folder.list()
        XCTAssertEqual(Set(listed.entries.map(\.snapshot.deviceID)), ["DEVICE-A", "DEVICE-B"])
    }

    func testWriteFailsWhenFolderIsMissing() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-sync-not-mounted-\(UUID().uuidString)", isDirectory: true)
        let folder = ConfigSyncFolder(root: root)
        XCTAssertThrowsError(try folder.write(snapshot())) { error in
            XCTAssertEqual(error as? ConfigSyncFolder.SyncError, .folderMissing(root.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "云盘没挂载时不能自己造出这个文件夹")
    }

    func testListSkipsHiddenAndCountsUnreadableFiles() throws {
        let root = tempDirectory("list")
        let folder = ConfigSyncFolder(root: root)
        XCTAssertEqual(try folder.write(snapshot(deviceID: "DEVICE-A")), .written)
        let directory = root.appendingPathComponent("SideDock")
        try Data("{}".utf8).write(to: directory.appendingPathComponent(".DEVICE-A.json.tmp"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        try Data("x".utf8).write(to: directory.appendingPathComponent("notes.txt"))

        let listed = try folder.list()
        XCTAssertEqual(listed.entries.map(\.snapshot.deviceID), ["DEVICE-A"])
        XCTAssertEqual(listed.unreadable, 1)
    }

    func testSnapshotRoundTripsWithConfigPayload() throws {
        let bar = DockBar(name: "工作", spaceID: "D#S1", apps: [tile("/Applications/A.app", label: "A")])
        let original = snapshot(bars: [bar], ordinals: ["D#S1": SpaceOrdinal(display: 1, desktop: 1)])
        let data = try ConfigSync.makeEncoder().encode(original)
        let decoded = try ConfigSync.makeDecoder().decode(SyncSnapshot.self, from: data)
        XCTAssertEqual(decoded.config.settings.dockBars, [bar])
        XCTAssertEqual(decoded.spaceOrdinals["D#S1"], SpaceOrdinal(display: 1, desktop: 1))
        XCTAssertEqual(decoded.writtenAt, original.writtenAt)
    }

    // MARK: - 缺 App

    private func locator(existing: Set<String>, bundles: [String: String] = [:]) -> AppLocator {
        AppLocator(fileExists: { existing.contains($0) }, applicationPath: { bundles[$0] })
    }

    func testPresenceFindsOriginalRelocatedAndMissing() {
        let finder = locator(existing: ["/Applications/Here.app", "/Apps/Moved.app"], bundles: ["com.moved": "/Apps/Moved.app"])
        XCTAssertEqual(finder.presence(of: tile("/Applications/Here.app", label: "Here")), .atOriginalPath("/Applications/Here.app"))
        XCTAssertEqual(finder.presence(of: tile("/Applications/Moved.app", label: "Moved", bundle: "com.moved")), .relocated("/Apps/Moved.app"))
        XCTAssertEqual(finder.presence(of: tile("/Applications/Gone.app", label: "Gone")), .missing)
        XCTAssertEqual(finder.presence(of: DockTile(raw: ["tile-type": .string("spacer-tile")])), .notAFile)
    }

    func testWritableAppsSkipsMissingAndRelocatesByBundleID() {
        let finder = locator(existing: ["/Applications/Here.app", "/Apps/Moved.app"], bundles: ["com.moved": "/Apps/Moved.app"])
        let here = tile("/Applications/Here.app", label: "Here")
        let moved = tile("/Applications/Moved.app", label: "Moved", bundle: "com.moved")
        let gone = tile("/Applications/Gone.app", label: "Gone")

        let result = finder.writableApps([here, moved, gone])

        XCTAssertEqual(result.apps.count, 2)
        XCTAssertEqual(result.apps[0], here, "原路径还在的条目原样写")
        XCTAssertEqual(DockStripRules.filePath(of: result.apps[1]), "/Apps/Moved.app")
        XCTAssertEqual(result.apps[1].bundleIdentifier, "com.moved")
        XCTAssertEqual(result.apps[1].label, "Moved")
        XCTAssertEqual(result.skipped.map(\.label), ["Gone"])
        XCTAssertEqual(result.relocated, 1)
    }

    func testSecondaryStripSkipsMissingAppsWhenLocatorIsGiven() {
        let finder = locator(existing: ["/Applications/Here.app", "/Apps/Moved.app"], bundles: ["com.moved": "/Apps/Moved.app"])
        let config = DockConfig(pinnedApps: [
            tile("/Applications/Here.app", label: "Here"),
            tile("/Applications/Moved.app", label: "Moved", bundle: "com.moved"),
            tile("/Applications/Gone.app", label: "Gone"),
        ])

        let snapshot = SecondaryDockContentBuilder.snapshot(from: config, runningBundleIDs: [], iconSize: 36, locator: finder)

        XCTAssertEqual(snapshot?.items.map(\.label), ["Here", "Moved"], "找不到的不画")
        XCTAssertEqual(snapshot?.items.last?.launchPath, "/Apps/Moved.app", "按 bundle ID 找到的新位置启动")
        XCTAssertEqual(config.pinnedApps.count, 3, "配置本身不删")
    }

    func testSecondaryStripHidesWhenEveryAppIsMissing() {
        let config = DockConfig(pinnedApps: [tile("/Applications/Gone.app", label: "Gone")])
        XCTAssertNil(SecondaryDockContentBuilder.snapshot(
            from: config, runningBundleIDs: [], iconSize: 36, locator: locator(existing: [])
        ))
    }
}

// MARK: - AppState 接线

@MainActor
final class ConfigSyncStateTests: XCTestCase {

    private func baseDomain() -> [String: PlistValue] {
        [
            "orientation": .string("bottom"),
            "tilesize": .double(36),
            "persistent-apps": .array([]),
            "persistent-others": .array([]),
            "mru-spaces": .bool(true),
            "mod-count": .int(1),
        ]
    }

    private func tempDirectory(_ name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-syncstate-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeState(
        _ name: String,
        spaces: [DesktopSpace],
        appLocator: AppLocator? = nil,
        preferences: FakePreferences? = nil
    ) -> AppState {
        let directory = tempDirectory(name)
        let environment = SyncEnvironment(
            settingsStore: .inMemory,
            identity: { DeviceIdentity(id: "THIS-MAC", name: "这台 Mac") },
            appVersion: "test",
            debounce: .milliseconds(10)
        )
        return AppState(
            dockController: DockController(
                preferences: preferences ?? FakePreferences(domain: baseDomain()),
                reloader: DockReloader(
                    process: FakeDockProcess(),
                    timeout: .milliseconds(200),
                    pollInterval: .milliseconds(2),
                    fallbackGrace: .milliseconds(20),
                    minimumSpacing: .zero
                ),
                backup: {}
            ),
            configStore: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            baselineStore: BaselineStore(
                baselineURL: directory.appendingPathComponent("baseline.plist"),
                markerURL: directory.appendingPathComponent("session.state"),
                backupsURL: directory.appendingPathComponent("backups", isDirectory: true)
            ),
            provider: FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64),
            fileLog: makeTestFileLog(),
            appLocator: appLocator,
            syncEnvironment: environment,
            environmentReader: { EnvironmentReading(stageManagerActive: false, dockSide: .bottom) }
        )
    }

    func testDefaultEnvironmentNeverSyncs() {
        let directory = tempDirectory("default")
        let state = AppState(
            dockController: DockController(
                preferences: FakePreferences(domain: baseDomain()),
                reloader: DockReloader(process: FakeDockProcess(), minimumSpacing: .zero),
                backup: {}
            ),
            configStore: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            baselineStore: BaselineStore(
                baselineURL: directory.appendingPathComponent("baseline.plist"),
                markerURL: directory.appendingPathComponent("session.state"),
                backupsURL: directory.appendingPathComponent("backups", isDirectory: true)
            ),
            provider: FakeSpaceProvider(isAvailable: false, reason: "test"),
            fileLog: makeTestFileLog()
        )
        XCTAssertNil(state.syncSettings.folderPath, "测试默认没有同步文件夹，绝不往真实云盘写")
        XCTAssertNil(state.syncNow(manual: false))
    }

    func testSyncNowWritesThisMacsFileWithoutLocalOnlyFields() async throws {
        let spaces = FakeSpaceProvider.desktops(count: 2)
        let state = makeState("write", spaces: spaces)
        state.start()
        defer { state.stop() }
        state.updateSettings {
            $0.secondaryDockRowPrefs = ["\(spaces[0].id)|bottom": SecondaryDockRowPref(anchorBarID: UUID())]
        }
        let root = tempDirectory("cloud")
        state.setAutoSync(false)
        state.chooseSyncFolder(root)

        await state.syncNow()?.value

        let file = root.appendingPathComponent("SideDock/THIS-MAC.json")
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("folderPath"), "同步设置本身不进同步文件")
        XCTAssertFalse(text.contains("autoSync"))
        let decoded = try ConfigSync.makeDecoder().decode(SyncSnapshot.self, from: data)
        XCTAssertEqual(decoded.deviceName, "这台 Mac")
        XCTAssertTrue(decoded.config.settings.secondaryDockRowPrefs.isEmpty, "本机专属字段已剔除")
        XCTAssertEqual(decoded.spaceOrdinals[spaces[1].id], SpaceOrdinal(display: 1, desktop: 2), "附上桌面序号")
        XCTAssertFalse(state.syncStatusFailed)
    }

    func testAutoSyncWritesAfterConfigChange() async throws {
        let spaces = FakeSpaceProvider.desktops(count: 1)
        let state = makeState("auto", spaces: spaces)
        state.start()
        defer { state.stop() }
        let root = tempDirectory("cloud-auto")
        state.setAutoSync(false)
        state.chooseSyncFolder(root)
        state.setAutoSync(true)
        await state.syncWriteTask?.value

        state.updateSettings { $0.restoreOnQuit = false }
        let file = root.appendingPathComponent("SideDock/THIS-MAC.json")
        var synced = false
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(10))
            await state.syncWriteTask?.value
            if let data = try? Data(contentsOf: file),
               let decoded = try? ConfigSync.makeDecoder().decode(SyncSnapshot.self, from: data),
               decoded.config.settings.restoreOnQuit == false {
                synced = true
                break
            }
        }
        XCTAssertTrue(synced, "落盘后防抖写一次自己那份")
    }

    func testImportFromOtherMacMapsBindingsAndKeepsLocalRowPrefs() async {
        let spaces = FakeSpaceProvider.desktops(count: 3)
        let state = makeState("import", spaces: spaces)
        state.start()
        defer { state.stop() }
        let anchor = UUID()
        let prefKey = "\(spaces[0].id)|bottom"
        state.updateSettings { $0.secondaryDockRowPrefs = [prefKey: SecondaryDockRowPref(anchorBarID: anchor)] }

        var settings = AppSettings()
        settings.dockBars = [
            DockBar(name: "远端", spaceID: "OTHER-DISP#r2"),
            DockBar(name: "孤儿", spaceID: "OTHER-DISP#r9"),
        ]
        let remote = SyncSnapshot(
            deviceID: "OTHER-MAC",
            deviceName: "另一台 Mac",
            appVersion: "0.2.1 (9)",
            writtenAt: Date(),
            spaceOrdinals: ["OTHER-DISP#r2": SpaceOrdinal(display: 1, desktop: 2)],
            config: .init(
                bindings: [DesktopBinding(displayUUID: "OTHER-DISP", spaceUUID: "r2", customName: "远端名", override: nil)],
                settings: settings
            )
        )
        let entry = ConfigSyncFolder.Entry(
            fileName: "OTHER-MAC.json",
            fileURL: URL(fileURLWithPath: "/tmp/OTHER-MAC.json"),
            snapshot: remote
        )

        XCTAssertFalse(state.isThisDevice(entry))
        let report = state.importSyncSnapshot(entry)

        XCTAssertEqual(report.mapped, 1)
        XCTAssertEqual(report.orphaned, 1)
        XCTAssertEqual(state.dockBars.first(where: { $0.name == "远端" })?.spaceID, spaces[1].id, "按序号落到本机桌面 2")
        XCTAssertEqual(state.dockBars.first(where: { $0.name == "孤儿" })?.spaceID, "OTHER-DISP#r9", "对不上的留成孤儿")
        XCTAssertEqual(state.bindings.first?.id, spaces[1].id)
        XCTAssertEqual(state.settings.secondaryDockRowPrefs[prefKey]?.anchorBarID, anchor, "本机专属字段保留本机的值")
    }

    func testNativeDockWriteSkipsAppsMissingOnThisMac() async {
        let spaces = FakeSpaceProvider.desktops(count: 1)
        let preferences = FakePreferences(domain: baseDomain())
        let finder = AppLocator(
            fileExists: { $0 == "/Applications/Here.app" },
            applicationPath: { _ in nil }
        )
        let state = makeState("native", spaces: spaces, appLocator: finder, preferences: preferences)
        state.start()
        defer { state.stop() }
        state.updateSettings {
            $0.freezeNativeDockSwitching = false
            $0.autoApplyOnEdit = false
        }
        let here = DockTile.makeFileTile(
            url: URL(fileURLWithPath: "/Applications/Here.app", isDirectory: true),
            label: "Here", bundleIdentifier: "com.example.here"
        )
        let gone = DockTile.makeFileTile(
            url: URL(fileURLWithPath: "/Applications/Gone.app", isDirectory: true),
            label: "Gone", bundleIdentifier: "com.example.gone"
        )
        let id = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: id, name: "栏", apps: [here, gone]))
        state.bindDockBar(id, to: spaces[0].id)
        await state.dockController.waitForIdle()

        state.applyActiveDesktopDock()
        await state.dockController.waitForIdle()

        let written = preferences.lastEntries?["persistent-apps"]?.arrayValue ?? []
        XCTAssertEqual(written.count, 1, "这台 Mac 上找不到的 App 不写进原生 Dock")
        XCTAssertEqual(state.dockBars.first(where: { $0.id == id })?.apps.count, 2, "配置里不删")
    }
}

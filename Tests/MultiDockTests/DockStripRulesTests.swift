import XCTest
@testable import MultiDock

/// 图标条的固定规则（启动台必须在首位、Finder 只是幻影）。
/// 对应 `docs/PLAN.md` §3.6 / §3.7。
final class DockStripRulesTests: XCTestCase {

    private func appTile(_ path: String, label: String) -> DockTile {
        DockTile.makeFileTile(
            url: URL(fileURLWithPath: path, isDirectory: true),
            label: label,
            bundleIdentifier: "com.example.\(label)"
        )
    }

    // MARK: - 启动台

    func testLaunchpadTileShapeMatchesTheRealDomain() {
        // 本机实测：file-type 169、dock-extra false、bundle com.apple.launchpad.launcher
        let tile = DockStripRules.makeLaunchpadTile()

        XCTAssertEqual(tile.tileType, "file-tile")
        XCTAssertEqual(tile.bundleIdentifier, "com.apple.launchpad.launcher")
        XCTAssertEqual(tile.label, "启动台")
        XCTAssertEqual(tile.tileData?["file-type"], .int(169))
        XCTAssertEqual(tile.tileData?["dock-extra"], .bool(false))
        XCTAssertEqual(tile.fileURLString, "file:///System/Applications/Launchpad.app/")
    }

    func testIsLaunchpadRecognisesBundleIdentifier() {
        XCTAssertTrue(DockStripRules.isLaunchpad(DockStripRules.makeLaunchpadTile()))
    }

    func testIsLaunchpadRecognisesURLWhenBundleIdentifierIsMissing() {
        var raw = DockStripRules.makeLaunchpadTile().raw
        var data = raw["tile-data"]!.dictionaryValue!
        data.removeValue(forKey: "bundle-identifier")
        raw["tile-data"] = .dictionary(data)

        XCTAssertTrue(DockStripRules.isLaunchpad(DockTile(raw: raw)),
                      "没写 bundle-identifier 也要能认出来，否则会插进第二个启动台")
    }

    func testIsLaunchpadRejectsOrdinaryApps() {
        XCTAssertFalse(DockStripRules.isLaunchpad(appTile("/Applications/Safari.app", label: "Safari")))
    }

    func testNormalizationMovesLaunchpadToFront() {
        let apps = [
            appTile("/Applications/Safari.app", label: "Safari"),
            DockStripRules.makeLaunchpadTile(),
            appTile("/Applications/Xcode.app", label: "Xcode"),
        ]

        let normalized = DockStripRules.normalizedApps(apps)

        XCTAssertEqual(normalized.count, 3)
        XCTAssertTrue(DockStripRules.isLaunchpad(normalized[0]))
        XCTAssertEqual(normalized[1].label, "Safari")
        XCTAssertEqual(normalized[2].label, "Xcode")
    }

    func testNormalizationCollapsesDuplicateLaunchpads() {
        let apps = [
            DockStripRules.makeLaunchpadTile(),
            appTile("/Applications/Safari.app", label: "Safari"),
            DockStripRules.makeLaunchpadTile(),
        ]

        let normalized = DockStripRules.normalizedApps(apps)

        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized.filter(DockStripRules.isLaunchpad).count, 1)
    }

    func testNormalizationKeepsTheExistingLaunchpadTileVerbatim() {
        // 回归：早先版本无条件用合成条目覆盖启动台，会把真实域里的 GUID / book /
        // file-mod-date 抹掉，逼 Dock 重新推导一遍。功能上能跑，但没必要动人家的数据。
        var real = DockStripRules.makeLaunchpadTile().raw
        real["GUID"] = .int(2477364010)
        var data = real["tile-data"]!.dictionaryValue!
        data["book"] = .data(Data("bookX".utf8))
        data["file-mod-date"] = .int(3816403915)
        real["tile-data"] = .dictionary(data)
        let existing = DockTile(raw: real)

        let normalized = DockStripRules.normalizedApps([existing, appTile("/Applications/Safari.app", label: "Safari")])

        XCTAssertEqual(normalized[0].raw, real, "已有的启动台条目必须原样保留")
        XCTAssertEqual(normalized[0].raw["GUID"], .int(2477364010))
    }

    func testNormalizationSynthesisesLaunchpadOnlyWhenAbsent() {
        let normalized = DockStripRules.normalizedApps([appTile("/Applications/Safari.app", label: "Safari")])

        XCTAssertEqual(normalized[0].raw, DockStripRules.makeLaunchpadTile().raw)
    }

    func testNormalizationInjectsLaunchpadWhenMissing() {
        let normalized = DockStripRules.normalizedApps([appTile("/Applications/Safari.app", label: "Safari")])

        XCTAssertEqual(normalized.count, 2)
        XCTAssertTrue(DockStripRules.isLaunchpad(normalized[0]))
    }

    func testNormalizationCollapsesDuplicateApps() {
        let safari = appTile("/Applications/Safari.app", label: "Safari")
        let normalized = DockStripRules.normalizedApps([safari, safari, safari])

        XCTAssertEqual(normalized.count, 2, "同一个 App 被拖进来三次也只留一个")
    }

    func testNormalizationIsIdempotent() {
        let once = DockStripRules.normalizedApps([
            appTile("/Applications/Xcode.app", label: "Xcode"),
            DockStripRules.makeLaunchpadTile(),
        ])
        XCTAssertEqual(DockStripRules.normalizedApps(once), once)
    }

    // MARK: - Dock 栏内容（barApps：不插启动台、不固定任何 App）

    func testBarAppsKeepsLaunchpadWhereTheUserPutIt() {
        // 2026-10-06 用户规格：栏不固定任何 App —— 启动台只是普通条目，可删可排。
        let apps = [
            appTile("/Applications/Safari.app", label: "Safari"),
            DockStripRules.makeLaunchpadTile(),
        ]

        let normalized = DockStripRules.barApps(apps)

        XCTAssertEqual(normalized.map(\.label), ["Safari", "启动台"], "顺序原样保留，不把启动台挪到首位")
    }

    func testBarAppsDoesNotSynthesiseLaunchpadForOrdinaryApps() {
        let normalized = DockStripRules.barApps([appTile("/Applications/Safari.app", label: "Safari")])

        XCTAssertEqual(normalized.map(\.label), ["Safari"], "没有启动台也不补一个")
    }

    func testBarAppsAllowsEmpty() {
        // 用户可以清空栏（与默认 Dock 不同：那里启动台必须保留）。
        XCTAssertTrue(DockStripRules.barApps([]).isEmpty)
    }

    func testBarAppsCollapsesDuplicates() {
        let safari = appTile("/Applications/Safari.app", label: "Safari")
        XCTAssertEqual(DockStripRules.barApps([safari, safari]).count, 1)
    }

    // MARK: - URL 形式

    func testDirectoryURLStringAddsTrailingSlash() {
        let url = URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)

        XCTAssertEqual(DockTile.directoryURLString(for: url), "file:///Applications/Safari.app/")
    }

    func testDirectoryURLStringIsIdempotent() {
        let url = URL(string: "file:///Applications/Safari.app/")!

        XCTAssertEqual(DockTile.directoryURLString(for: url), "file:///Applications/Safari.app/")
    }

    func testMakeFileTileWritesDirectoryStyleURL() {
        // 回归：早先版本用 `url.absoluteString`，得到不带尾斜杠的 URL，
        // 与真实域（P0 写入实验用的形式）不一致。
        let tile = appTile("/Applications/Safari.app", label: "Safari")

        XCTAssertEqual(tile.fileURLString, "file:///Applications/Safari.app/")
        XCTAssertEqual(tile.tileData?["file-data"]?.dictionaryValue?["_CFURLStringType"], .int(15))
    }

    func testFilePathRoundTrip() {
        let tile = appTile("/Applications/Safari.app", label: "Safari")

        XCTAssertEqual(DockStripRules.filePath(of: tile), "/Applications/Safari.app")
    }

    func testFilePathRejectsNonFileURLs() {
        var raw = appTile("/Applications/Safari.app", label: "Safari").raw
        var data = raw["tile-data"]!.dictionaryValue!
        var fileData = data["file-data"]!.dictionaryValue!
        fileData["_CFURLString"] = .string("https://example.com/x")
        data["file-data"] = .dictionary(fileData)
        raw["tile-data"] = .dictionary(data)

        XCTAssertNil(DockStripRules.filePath(of: DockTile(raw: raw)))
    }

    func testIsInstalledDetectsMissingApps() {
        XCTAssertTrue(DockStripRules.isInstalled(appTile(DockStripRules.launchpadPath, label: "启动台")))
        XCTAssertFalse(DockStripRules.isInstalled(appTile("/Applications/NoSuchApp-xyz.app", label: "不存在")))
    }

    // MARK: - 从磁盘造条目

    func testTileForAppReadsBundleIdentifierFromDisk() throws {
        let tile = try XCTUnwrap(DockStripRules.tile(forAppAt: DockStripRules.launchpadPath))

        XCTAssertEqual(tile.bundleIdentifier, "com.apple.launchpad.launcher")
        XCTAssertEqual(tile.fileURLString, "file:///System/Applications/Launchpad.app/")
    }

    func testTileForAppRejectsNonApplicationPaths() {
        XCTAssertNil(DockStripRules.tile(forAppAt: "/Applications"))
        XCTAssertNil(DockStripRules.tile(forAppAt: "/etc/hosts"))
        XCTAssertNil(DockStripRules.tile(forAppAt: "/Applications/NoSuchApp-xyz.app"))
    }

    // MARK: - 其他项（persistent-others）

    private func otherTile(_ path: String, label: String) -> DockTile {
        DockTile(raw: [
            "tile-type": .string("directory-tile"),
            "tile-data": .dictionary([
                "file-data": .dictionary([
                    "_CFURLString": .string("file://\(path)/"),
                    "_CFURLStringType": .int(15),
                ]),
                "file-label": .string(label),
                "file-type": .int(2),
            ]),
        ])
    }

    func testNormalizedOthersDeduplicatesAndKeepsOrder() {
        let downloads = otherTile("/Users/apple/Downloads", label: "下载")
        let documents = otherTile("/Users/apple/Documents", label: "文稿")

        let normalized = DockStripRules.normalizedOthers([downloads, downloads, documents])

        XCTAssertEqual(normalized.map(\.label), ["下载", "文稿"])
    }

    func testNormalizedOthersInventsNothing() {
        // 与 apps 不同：其他项里没有「必须存在」的条目
        //（Finder 是系统隐式渲染的，启动台在 persistent-apps 里）。
        XCTAssertTrue(DockStripRules.normalizedOthers([]).isEmpty)
    }

    func testOtherTileIsRecognisedAsFolder() {
        XCTAssertTrue(otherTile("/Users/apple/Downloads", label: "下载").isFolder)
        XCTAssertFalse(appTile("/Applications/Safari.app", label: "Safari").isFolder)
    }

    /// 回归守卫：**不要**给文件夹/普通文件开"合成新条目"的口子。
    ///
    /// `docs/spikes.md` 实验 8 实测：自拼的 `directory-tile` 不会被 Dock 认领
    /// （Dock 不补 `GUID` / `book`），而字段不全的形状会让 Dock 直接 SIGABRT。
    /// 所以这条路必须是关着的；要加文件夹只能由用户在访达里自己拖进 Dock。
    func testDockItemRejectionClosesTheFolderAndFilePaths() {
        XCTAssertEqual(DockStripRules.rejectionReason(for: "/Applications"), .folder)
        XCTAssertEqual(DockStripRules.rejectionReason(for: "/etc/hosts"), .file)
        XCTAssertEqual(DockStripRules.rejectionReason(for: "/Users/apple/NoSuch-xyz"), .notAnApp)
    }

    func testDockItemRejectionAcceptsRealAppBundles() {
        XCTAssertNil(DockStripRules.rejectionReason(for: DockStripRules.launchpadPath))
    }
}

/// `AppSettings` 的解码必须向前兼容：老配置文件里没有新字段时，
/// 不能整份回落到默认值 —— 那会把用户已有的设置静默清空。
final class AppSettingsCodingTests: XCTestCase {

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    func testDecodingConfigWrittenBeforeDockBarsExistedKeepsOtherSettings() throws {
        let settings = try decode(#"{"restoreOnQuit":false,"autoApplyOnEdit":false,"reloadStrategy":"sigterm"}"#)

        XCTAssertFalse(settings.restoreOnQuit)
        XCTAssertFalse(settings.autoApplyOnEdit)
        XCTAssertEqual(settings.reloadStrategy, .sigterm)
        XCTAssertTrue(settings.dockBars.isEmpty, "老配置里没有 Dock 栏，就是空的")
        XCTAssertEqual(settings.defaultDockAppCount, 10, "老配置里没有显示数量，用默认 10")
    }

    func testDecodingEmptyObjectYieldsDefaults() throws {
        let settings = try decode("{}")

        XCTAssertTrue(settings.restoreOnQuit)
        XCTAssertEqual(settings.clickAction, .nextDesktop)
        XCTAssertEqual(settings.reloadStrategy, .auto)
        XCTAssertTrue(settings.showToastOnDesktopSwitch)
    }

    func testRoundTripPreservesDockBars() throws {
        var settings = AppSettings()
        settings.defaultDockAppCount = 7
        settings.dockBars = [
            DockBar(
                name: "工作",
                position: .right,
                spaceID: "DISP#SPACE",
                apps: DockStripRules.normalizedApps([
                    DockStripRules.makeLaunchpadTile(),
                    DockTile.makeFileTile(
                        url: URL(fileURLWithPath: "/Applications/Xcode.app", isDirectory: true),
                        label: "Xcode",
                        bundleIdentifier: "com.apple.dt.Xcode"
                    ),
                ])
            ),
            DockBar(name: "摸鱼"),
        ]

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.dockBars.count, 2)
        XCTAssertEqual(restored.dockBars[0].position, .right)
        XCTAssertEqual(restored.dockBars[0].apps.map(\.label), ["启动台", "Xcode"])
        XCTAssertEqual(restored.dockBars[0].spaceID, "DISP#SPACE")
        XCTAssertEqual(restored.dockBars[1].position, .bottom)
    }
}

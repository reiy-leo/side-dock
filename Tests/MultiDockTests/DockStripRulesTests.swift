import XCTest
@testable import MultiDock

/// 图标条规则（2026-10-06 起：本 App 不生成任何 Dock 内容，只剩栏内容去重 / 其他项 / 造条目）。
/// 对应 `docs/PLAN.md` §3.6 / §3.7。
///
/// **启动台与 Finder 的专项用例已随功能删除**：本 App 不再合成启动台、也不画 Finder 幻影
/// （用户指令：去掉「最近添加的应用」整块逻辑）。保留它们的形状知识没必要 ——
/// 那两条 P0 结论写在 `DockStripRules` 头部注释与 `docs/facts.md` 里。
final class DockStripRulesTests: XCTestCase {

    private func appTile(_ path: String, label: String) -> DockTile {
        DockTile.makeFileTile(
            url: URL(fileURLWithPath: path, isDirectory: true),
            label: label,
            bundleIdentifier: "com.example.\(label)"
        )
    }

    // MARK: - Dock 栏内容（barApps：不插固定项、不固定任何 App）

    func testBarAppsKeepsOrderVerbatim() {
        // 栏内容 = 用户放什么就是什么：顺序原样保留。
        let apps = [
            appTile("/Applications/Safari.app", label: "Safari"),
            appTile("/System/Applications/Launchpad.app", label: "启动台"),
            appTile("/Applications/Xcode.app", label: "Xcode"),
        ]

        let normalized = DockStripRules.barApps(apps)

        XCTAssertEqual(normalized.map(\.label), ["Safari", "启动台", "Xcode"])
    }

    func testBarAppsDoesNotSynthesiseAnything() {
        let normalized = DockStripRules.barApps([appTile("/Applications/Safari.app", label: "Safari")])

        XCTAssertEqual(normalized.map(\.label), ["Safari"], "只去重，不补启动台、不插任何固定项")
    }

    func testBarAppsAllowsEmpty() {
        // 用户可以清空栏（空栏在界面上就是"没有图标"，次级条随之隐藏）。
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
        XCTAssertTrue(DockStripRules.isInstalled(appTile("/System/Applications/Launchpad.app", label: "启动台")))
        XCTAssertFalse(DockStripRules.isInstalled(appTile("/Applications/NoSuchApp-xyz.app", label: "不存在")))
    }

    // MARK: - 从磁盘造条目

    func testTileForAppReadsBundleIdentifierFromDisk() throws {
        let tile = try XCTUnwrap(DockStripRules.tile(forAppAt: "/System/Applications/Launchpad.app"))

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
        XCTAssertNil(DockStripRules.rejectionReason(for: "/System/Applications/Launchpad.app"))
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
        settings.menuBarIcon = .parasol
        settings.dockBars = [
            DockBar(
                name: "工作",
                position: .right,
                spaceID: "DISP#SPACE",
                apps: DockStripRules.barApps([
                    DockTile.makeFileTile(
                        url: URL(fileURLWithPath: "/Applications/Xcode.app", isDirectory: true),
                        label: "Xcode",
                        bundleIdentifier: "com.apple.dt.Xcode"
                    ),
                    DockTile.makeFileTile(
                        url: URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true),
                        label: "Safari",
                        bundleIdentifier: "com.apple.Safari"
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
        XCTAssertEqual(restored.dockBars[0].apps.map(\.label), ["Xcode", "Safari"])
        XCTAssertEqual(restored.dockBars[0].spaceID, "DISP#SPACE")
        XCTAssertEqual(restored.dockBars[1].position, .bottom)
    }
}

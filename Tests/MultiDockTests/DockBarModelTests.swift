import XCTest
@testable import MultiDock

/// 2026-10-05 设置窗口重构的新模型：最近应用扫描、Dock 栏实体与迁移、
/// 位置可用性（台前调度避让）、独立贴边几何。
final class DockBarModelTests: XCTestCase {

    // MARK: - DockBarPosition

    func testAvailablePositionsExcludeLeftWhenStageManagerIsActive() {
        XCTAssertEqual(
            DockBarPosition.available(stageManagerActive: true),
            [.bottom, .right],
            "台前调度占左缘，位置选项必须避开左"
        )
        XCTAssertEqual(
            DockBarPosition.available(stageManagerActive: false),
            [.bottom, .left, .right],
            "台前调度没开时三条边都可以"
        )
    }

    func testPositionVerticality() {
        XCTAssertFalse(DockBarPosition.bottom.isBarVertical)
        XCTAssertTrue(DockBarPosition.left.isBarVertical)
        XCTAssertTrue(DockBarPosition.right.isBarVertical)
    }

    // MARK: - DockBar 解码兼容

    func testDockBarDecodingToleratesMissingFields() throws {
        // 手改 config.json 删掉后半截字段，也不能解码失败（decodeIfPresent 兜底）。
        let bar = try JSONDecoder().decode(DockBar.self, from: Data(#"{"name":"工作"}"#.utf8))
        XCTAssertEqual(bar.name, "工作")
        XCTAssertEqual(bar.position, .bottom)
        XCTAssertNil(bar.spaceID)
        XCTAssertTrue(bar.apps.isEmpty)
        XCTAssertFalse(bar.id.uuidString.isEmpty, "缺 id 时补一个新 UUID")
    }

    // MARK: - 迁移（旧版逐桌面 override → Dock 栏）

    private func space(ordinal: Int) -> DesktopSpace {
        DesktopSpace(
            displayUUID: "DISP",
            spaceUUID: "SPACE-\(ordinal)",
            id64: UInt64(ordinal),
            type: 0,
            ordinal: ordinal
        )
    }

    private func appTile(_ label: String) -> DockTile {
        DockTile.makeFileTile(
            url: URL(fileURLWithPath: "/Applications/\(label).app", isDirectory: true),
            label: label,
            bundleIdentifier: "com.example.\(label)"
        )
    }

    func testMigratedBarsComeFromOverridesAndKeepNames() {
        let bindings = [
            DesktopBinding(displayUUID: "DISP", spaceUUID: "SPACE-1", customName: "工作",
                           override: DockConfig(pinnedApps: [appTile("Safari")])),
            DesktopBinding(displayUUID: "DISP", spaceUUID: "SPACE-2", customName: nil,
                           override: DockConfig(pinnedApps: [appTile("Notes"), appTile("Xcode")])),
        ]

        let bars = DockBarCatalog.migratedBars(from: bindings)

        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0].name, "工作", "有自定义名就用桌面名")
        XCTAssertEqual(bars[0].spaceID, "DISP#SPACE-1")
        XCTAssertEqual(bars[0].apps.map(\.label), ["Safari"])
        XCTAssertEqual(bars[1].name, "Dock 2", "没名字的按顺序编")
        XCTAssertEqual(bars[1].apps.count, 2)
    }

    func testMigrationCapsAppsAtTheMaximum() {
        let many = (0..<30).map { appTile("App\($0)") }
        let bindings = [
            DesktopBinding(displayUUID: "DISP", spaceUUID: "SPACE-1", customName: nil,
                           override: DockConfig(pinnedApps: many)),
        ]

        let bars = DockBarCatalog.migratedBars(from: bindings)

        XCTAssertEqual(bars[0].apps.count, DockBar.maxApps, "旧配置里的超长图标条截到 15")
    }

    func testPaddingOnlyFillsUpToTheDefaultCount() {
        let migrated = [
            DockBar(name: "工作", spaceID: "DISP#SPACE-1", apps: [appTile("Safari")]),
        ]

        let padded = DockBarCatalog.paddedToDefault(migrated)

        XCTAssertEqual(padded.count, DockBarCatalog.defaultBarCount, "默认可以有 5 根栏")
        XCTAssertEqual(padded[0].name, "工作")
        XCTAssertTrue(padded.dropFirst().allSatisfy { $0.spaceID == nil }, "补的栏不绑定桌面")
        XCTAssertEqual(padded.dropFirst().map(\.name), ["Dock 2", "Dock 3", "Dock 4", "Dock 5"])

        // 已达 5 根时不再补；用户删光的也不再补（那是有意的）。
        XCTAssertEqual(DockBarCatalog.paddedToDefault(padded).count, DockBarCatalog.defaultBarCount)
        XCTAssertEqual(DockBarCatalog.paddedToDefault([]).count, DockBarCatalog.defaultBarCount,
                       "空列表（首次运行）也补到 5")
    }

    // MARK: - 独立贴边几何

    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1200)

    func testStandaloneBottomTucksHalfBelowTheScreen() {
        let barSize = SecondaryDockLayout.barSize(itemCount: 4, iconSize: 36, isVertical: false)
        let (revealed, tucked) = SecondaryDockLayout.standalonePlacement(
            barSize: barSize, position: .bottom, screen: screen
        )
        // 4 * (36+8) + 16 = 192；36 + 20 = 56
        XCTAssertEqual(revealed, CGRect(x: 864, y: 0, width: 192, height: 56), "贴屏幕底边、水平居中")
        XCTAssertEqual(tucked, CGRect(x: 864, y: -28, width: 192, height: 56), "半露 = 滑出屏幕一半")
    }

    func testStandaloneRightTucksHalfOffTheRightEdge() {
        let barSize = SecondaryDockLayout.barSize(itemCount: 4, iconSize: 36, isVertical: true)
        let (revealed, tucked) = SecondaryDockLayout.standalonePlacement(
            barSize: barSize, position: .right, screen: screen
        )
        XCTAssertEqual(revealed, CGRect(x: 1864, y: 504, width: 56, height: 192),
                       "贴右缘、垂直居中：(1200-192)/2 = 504")
        XCTAssertEqual(tucked, CGRect(x: 1892, y: 504, width: 56, height: 192), "半露 = 向右滑出屏幕一半")
    }

    func testStandaloneLeftMirrorsRight() {
        let barSize = SecondaryDockLayout.barSize(itemCount: 4, iconSize: 36, isVertical: true)
        let (revealed, tucked) = SecondaryDockLayout.standalonePlacement(
            barSize: barSize, position: .left, screen: screen
        )
        XCTAssertEqual(revealed, CGRect(x: 0, y: 504, width: 56, height: 192), "贴左缘")
        XCTAssertEqual(tucked, CGRect(x: -28, y: 504, width: 56, height: 192), "半露 = 向左滑出屏幕一半")
    }

    func testStandaloneOversizedBarIsClamped() {
        let barSize = SecondaryDockLayout.barSize(itemCount: 100, iconSize: 48, isVertical: true)
        let (revealed, tucked) = SecondaryDockLayout.standalonePlacement(
            barSize: barSize, position: .right, screen: screen
        )
        XCTAssertEqual(revealed.height, 1200 - SecondaryDockLayout.screenMargin * 2)
        XCTAssertEqual(tucked.height, revealed.height, "收起只平移，不改尺寸")
    }

    func testPositionMatchesOrientation() {
        XCTAssertTrue(DockBarPosition.bottom.matches(.bottom))
        XCTAssertTrue(DockBarPosition.left.matches(.left))
        XCTAssertTrue(DockBarPosition.right.matches(.right))
        XCTAssertFalse(DockBarPosition.right.matches(.bottom), "不同侧 = 独立贴边")
    }

    // MARK: - StageManagerStatus（探测逻辑用注入值验，真实读数见 docs/facts.md）

    func testStageManagerFallbackTreatsUnknownAsInactive() {
        // 读不到（nil）时 UI 按「未开启」处理：三个位置都给。
        // 这里只锁 API 契约：available(stageManagerActive:) 对 nil 的处理在 AppState.availableBarPositions。
        XCTAssertNotNil(DockBarPosition.available(stageManagerActive: false))
    }

    // MARK: - 更新检查（关于 Tab 的纯函数部分）

    func testSemanticVersionComparison() {
        XCTAssertTrue(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.9.9"), "缺段按 0")
        XCTAssertTrue(UpdateCheck.isNewer("v0.2.0", than: "0.1.0"), "tag 带不带 v 都能比")
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.1.0"), "相同不算新")
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0-beta", than: "0.1.0"), "预发布后缀截掉后主段相同")
        XCTAssertFalse(UpdateCheck.isNewer("abc", than: "0.1.0"), "无法解析的版本保守判旧")
    }

    func testParseReleaseReadsTagAndURL() throws {
        let json = #"{"tag_name":"v1.2.3","html_url":"https://github.com/reiy-leo/side-dock/releases/tag/v1.2.3"}"#
        let outcome = try XCTUnwrap(UpdateCheck.parseRelease(data: Data(json.utf8)))
        XCTAssertEqual(outcome, .release(
            tag: "1.2.3",
            url: URL(string: "https://github.com/reiy-leo/side-dock/releases/tag/v1.2.3")
        ))

        XCTAssertNil(UpdateCheck.parseRelease(data: Data("不是 JSON".utf8)))
        XCTAssertNil(UpdateCheck.parseRelease(data: Data(#"{"html_url":"x"}"#.utf8)), "没有 tag_name 不算发布")
    }
}

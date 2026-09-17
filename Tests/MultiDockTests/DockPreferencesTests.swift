import XCTest
@testable import MultiDock

/// 白名单合并：对应 `docs/PLAN.md` §4 里「除白名单键外无任何差异」的验收标准。
final class DockPreferencesTests: XCTestCase {

    private var realisticDomain: [String: PlistValue] {
        [
            // 白名单内的键
            "persistent-apps": .array([.dictionary(["tile-type": .string("file-tile")])]),
            "tilesize": .double(36),
            "orientation": .string("bottom"),
            // 必须原样保留的键
            "mru-spaces": .int(1),
            "wvous-br-corner": .int(4),
            "springboard-rows": .int(5),
            "recent-apps": .array([.string("com.example.app")]),
            "mod-count": .int(22_538),
            "trash-full": .bool(false),
        ]
    }

    func testOnlyWhitelistedKeysAreOverwritten() {
        let merged = DockPreferences.merged(
            domain: realisticDomain,
            entries: [
                "tilesize": .double(64),
                "orientation": .string("left"),
            ]
        )

        XCTAssertEqual(merged["tilesize"], .double(64))
        XCTAssertEqual(merged["orientation"], .string("left"))
    }

    func testNonWhitelistedKeysAreIgnoredNotWritten() {
        // 传入被排除的键时必须被忽略：否则会误伤热角、启动台网格等无关配置。
        let merged = DockPreferences.merged(
            domain: realisticDomain,
            entries: [
                "mru-spaces": .int(0),
                "wvous-br-corner": .int(0),
                "mod-count": .int(1),
                "totally-made-up-key": .string("x"),
            ]
        )

        XCTAssertEqual(merged["mru-spaces"], .int(1), "mru-spaces 必须原样保留")
        XCTAssertEqual(merged["wvous-br-corner"], .int(4), "屏幕角必须原样保留")
        XCTAssertEqual(merged["mod-count"], .int(22_538), "mod-count 必须原样保留")
        XCTAssertNil(merged["totally-made-up-key"], "白名单外的键不应被写入")
    }

    func testKeySetIsNeverChanged() {
        let merged = DockPreferences.merged(
            domain: realisticDomain,
            entries: ["tilesize": .double(128)]
        )
        XCTAssertEqual(Set(merged.keys), Set(realisticDomain.keys))
    }

    func testUnknownNonWhitelistedKeysSurvive() {
        // 未来 macOS 新增的、我们不认识的键也必须原样保留 —— 这是"整域替换"会踩的坑。
        var domain = realisticDomain
        domain["some-future-macos-key"] = .string("keep me")
        let merged = DockPreferences.merged(domain: domain, entries: ["tilesize": .double(48)])
        XCTAssertEqual(merged["some-future-macos-key"], .string("keep me"))
    }

    func testAppearanceEntriesStayInsideWhitelist() {
        // DockAppearance 产出的键必须全部在白名单里，否则写不进去还不报错。
        var appearance = DockAppearance()
        appearance.autohideDelay = 0.5
        appearance.autohideTimeModifier = 0.2
        for key in appearance.domainEntries.keys {
            XCTAssertTrue(
                DockPreferences.whitelistedKeys.contains(key),
                "\(key) 不在白名单里，配置会被静默丢弃"
            )
        }
    }

    func testWhitelistAndExclusionListDoNotOverlap() {
        let overlap = DockPreferences.whitelistedKeys
            .intersection(DockPreferences.excludedKeys)
        XCTAssertTrue(overlap.isEmpty, "白名单与排除清单冲突：\(overlap)")
    }

    func testExcludedKeysAreNeverInWhitelist() {
        // 逐个断言，比集合比较更能说明意图。
        for key in ["mru-spaces", "recent-apps", "mod-count", "version", "ResetLaunchPad"] {
            XCTAssertFalse(DockPreferences.whitelistedKeys.contains(key), "\(key) 不该出现在白名单")
        }
    }

    func testMRUSpacesIsNotReachableThroughTheWhitelistPath() {
        // `mru-spaces` 只能通过 `DockPreferences.writeMRUSpaces(_:)` 这一个窄口子写。
        // 一旦混进白名单，每次「立即应用」都会顺手改掉用户的桌面重排设置 —— 那是静默修改。
        let merged = DockPreferences.merged(
            domain: realisticDomain,
            entries: [DockPreferences.mruSpacesKey: .bool(false)]
        )
        XCTAssertEqual(merged["mru-spaces"], .int(1), "白名单路径绝不能碰 mru-spaces")
        XCTAssertTrue(DockPreferences.excludedKeys.contains(DockPreferences.mruSpacesKey))
    }
}

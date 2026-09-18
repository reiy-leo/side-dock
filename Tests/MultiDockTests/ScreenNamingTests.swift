import AppKit
import XCTest
@testable import MultiDock

/// 显示器名解析（计划 §3.7：桌面列表要带**显示器名**；`AGENTS.md` §4 的映射实测）。
///
/// 纯解析部分不碰真实屏幕，全部可单测；只有 `currentScreens()` 需要真机。
final class ScreenNamingTests: XCTestCase {

    private let builtIn = ScreenNaming.Screen(
        uuid: "AB24BB32-C5EC-D10A-6F9D-F01F35552F60",
        name: "内建视网膜显示器"
    )
    private let external = ScreenNaming.Screen(
        uuid: "CD34CC43-D6FD-E21B-7A0E-01246663A071",
        name: "DELL U2720Q"
    )

    func testResolvesNameByDisplayUUID() {
        let screens = [builtIn, external]

        XCTAssertEqual(ScreenNaming.name(for: builtIn.uuid, screens: screens), "内建视网膜显示器")
        XCTAssertEqual(ScreenNaming.name(for: external.uuid, screens: screens), "DELL U2720Q")
    }

    func testComparisonIsCaseInsensitive() {
        // 一个来自 SkyLight、一个来自 CoreGraphics；两边目前都是大写，但放宽一档更稳。
        XCTAssertEqual(ScreenNaming.name(for: builtIn.uuid.lowercased(), screens: [builtIn]),
                       "内建视网膜显示器")
    }

    func testUnknownDisplayUUIDResolvesToNil() {
        XCTAssertNil(ScreenNaming.name(for: "FFFFEEEE-DDDD-CCCC-BBBB-AAAAAAAAAAAA", screens: [builtIn]))
    }

    /// 关键：映射不到时**不能**回落成某台真实显示器的名字。
    /// 那会让用户以为桌面挂在这台屏上，比"未识别"更糟。
    func testUnmappedDisplayUUIDDoesNotLie() {
        let text = ScreenNaming.displayName(for: "FFFFEEEE-DDDD-CCCC-BBBB-AAAAAAAAAAAA",
                                            screens: [builtIn])

        XCTAssertTrue(text.hasPrefix("未识别显示器"))
        XCTAssertTrue(text.contains("FFFFEEEE"), "要给出 UUID 前 8 位，方便照调试面板核对")
        XCTAssertFalse(text.contains("内建"))
    }

    func testEmptyDisplayUUIDHasItsOwnText() {
        XCTAssertEqual(ScreenNaming.displayName(for: "", screens: []), "未知显示器")
        XCTAssertEqual(ScreenNaming.name(for: "", screens: []), nil)
    }

    /// 真机就绪性：本机每台屏都要能解析出非空的 `displayUUID` ——
    /// 否则多显示器时桌面列表会把几台屏的桌面挤成一组。
    @MainActor
    func testCurrentScreensMapsEveryAttachedDisplay() {
        let screens = ScreenNaming.currentScreens()

        XCTAssertEqual(screens.count, NSScreen.screens.count)
        XCTAssertFalse(screens.isEmpty)
        XCTAssertTrue(screens.allSatisfy { !$0.uuid.isEmpty && !$0.name.isEmpty })
    }
}
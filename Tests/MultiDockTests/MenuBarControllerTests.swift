import AppKit
import XCTest
@testable import MultiDock

/// 菜单栏「图标 + 数字」垂直对齐的守卫（2026-10-06 用户报告偏高）。
///
/// 症状与根因：数字没有下伸部，`NSStatusBarButton` 按整段行盒垂直居中 → 数字墨迹偏高
/// （实测 @2x：图标墨心 21.1px vs 数字 18.6px，偏 ~1.2pt）。
/// 修法：`attributedTitle` + `.baselineOffset` 下压（生产值 `titleBaselineOffset`）。
/// 测量方法：`swift scripts/measure-menubar-baseline.swift`（离屏，零权限）。
@MainActor
final class MenuBarControllerTests: XCTestCase {

    /// 标题必须带下压的 baselineOffset —— 退回 `button.title = " \(n)"` 就是回退这个修复。
    func testNumberTitleCarriesBaselineOffsetForOpticalCentering() {
        let title = MenuBarController.attributedTitle(
            ordinal: 3,
            font: NSFont.systemFont(ofSize: 13)
        )
        XCTAssertEqual(title.string, " 3", "序号前要留一个空格（与图标拉开间距）")

        let offset = (title.attribute(.baselineOffset, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue
        XCTAssertNotNil(offset, "标题必须带 baselineOffset（不加就偏高 ~1.2pt）")
        XCTAssertEqual(offset ?? 0, Double(MenuBarController.titleBaselineOffset), accuracy: 0.001)
        XCTAssertLessThan(offset ?? 0, 0, "必须是负值（下压）——数字无下伸部，不下压会偏高")
    }

    /// 不带显式颜色：让按钮按菜单栏亮/暗与高亮态自动着色（带颜色会把暗色菜单栏写成黑字）。
    func testNumberTitleLeavesColorUnsetSoMenuBarAppearanceCanTint() {
        let title = MenuBarController.attributedTitle(ordinal: 1, font: nil)
        XCTAssertNil(title.attribute(.foregroundColor, at: 0, effectiveRange: nil),
                     "不能写死颜色，否则菜单栏亮/暗切换时数字会看不清")
    }

    /// 按钮字体拿不到时回落系统字号（13pt），保证标题与菜单栏其余文字同号。
    func testNumberTitleFallsBackToSystemFontWhenButtonFontMissing() {
        let title = MenuBarController.attributedTitle(ordinal: 10, font: nil)
        XCTAssertEqual(title.string, " 10", "两位数序号同样要正确渲染")
        let font = title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, NSFont.systemFontSize)
    }
}

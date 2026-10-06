import AppKit
import XCTest
@testable import MultiDock

/// `DesktopNameOverlayWindow` 的纯布局：三档位置 + **宽度按内容量、不截字**。
/// 不碰真窗口 —— 窗口属性（跨空间、不抢焦点、不挡点击）只能真机验。
@MainActor
final class DesktopNameOverlayTests: XCTestCase {

    /// 假想的显示器可见区（AppKit 坐标，原点左下）。数值随手编，够验几何就行。
    private let visibleFrame = NSRect(x: 0, y: 25, width: 1440, height: 875)

    // MARK: - 三档位置

    func testTopSitsBelowVisibleTopAndCentered() {
        let layout = DesktopNameOverlayWindow.panelLayout(
            text: "工作",
            available: visibleFrame,
            placement: .top
        )
        XCTAssertEqual(layout.origin.x, (1440 - layout.panelSize.width) / 2, accuracy: 0.5, "水平恒居中")
        XCTAssertEqual(
            layout.origin.y,
            25 + 875 - 80 - layout.panelSize.height,
            accuracy: 0.5,
            "顶部档位：面板顶边距可见区顶 80pt（旧版 toast 同款，天然避开菜单栏）"
        )
    }

    func testMiddleCentersVertically() {
        let layout = DesktopNameOverlayWindow.panelLayout(
            text: "工作",
            available: visibleFrame,
            placement: .middle
        )
        XCTAssertEqual(layout.origin.y, 25 + (875 - layout.panelSize.height) / 2, accuracy: 0.5,
                       "中部档位：可见区垂直居中")
    }

    func testBottomClearsVisibleBottom() {
        let layout = DesktopNameOverlayWindow.panelLayout(
            text: "工作",
            available: visibleFrame,
            placement: .bottom
        )
        XCTAssertEqual(layout.origin.y, 25 + 64, accuracy: 0.5,
                       "底部档位：面板底边距可见区底 64pt（避开次级条薄边）")
    }

    // MARK: - 宽度按内容量（**省略号回归**）

    /// 这是用户报的 bug：名字被截成省略号。**实测阈值**：64 pt 下量宽 604 pt 的十个汉字，
    /// label 宽 608 仍被截、612 起完整 —— 所以余量必须 ≥ 8（`NSTextFieldCell` 每侧约 2 pt
    /// 内边距 + CJK 推进宽取整）。这里钉住余量下限，别被优化掉。
    func testLabelWidthHasEnoughSlackToAvoidTruncation() {
        for name in ["工作", "一二三四五六七八九十", "Desktop 10", "👍🏽开发环境"] {
            let layout = DesktopNameOverlayWindow.panelLayout(
                text: name,
                available: visibleFrame,
                placement: .top
            )
            let font = NSFont.systemFont(
                ofSize: DesktopNameOverlayWindow.fontSize,
                weight: DesktopNameOverlayWindow.fontWeight
            )
            let measured = (name as NSString).size(withAttributes: [.font: font]).width
            XCTAssertGreaterThanOrEqual(
                layout.labelFrame.width - measured,
                8,
                "「\(name)」的文字框余量不足 8 pt —— 会退化成省略号（实测 4 pt 余量就会截断）"
            )
        }
    }

    /// 十个字素簇（名字上限）在 1440 宽的屏上必须能完整放下、不触发截断兜底。
    func testTenGraphemeNameFitsWithoutTruncation() {
        let longest = "一二三四五六七八九十"
        let layout = DesktopNameOverlayWindow.panelLayout(
            text: longest,
            available: visibleFrame,
            placement: .top
        )
        let font = NSFont.systemFont(
            ofSize: DesktopNameOverlayWindow.fontSize,
            weight: DesktopNameOverlayWindow.fontWeight
        )
        let measured = ceil((longest as NSString).size(withAttributes: [.font: font]).width)
        XCTAssertGreaterThanOrEqual(layout.labelFrame.width, measured, "最长名字必须完整显示")
        XCTAssertLessThan(layout.panelSize.width, visibleFrame.width, "面板整体要放得进屏幕")
    }

    /// 面板宽度 = 文字宽 + 两侧内边距（内容撑开，不是固定槽位）。
    func testPanelWidthFollowsContent() {
        let short = DesktopNameOverlayWindow.panelLayout(text: "一", available: visibleFrame, placement: .top)
        let long = DesktopNameOverlayWindow.panelLayout(
            text: "一二三四五六七八九十",
            available: visibleFrame,
            placement: .top
        )
        XCTAssertLessThan(short.panelSize.width, long.panelSize.width, "短名面板应比长名窄")
        XCTAssertGreaterThanOrEqual(
            short.panelSize.width,
            DesktopNameOverlayWindow.minPanelWidth,
            "单字不缩成一颗圆"
        )
        XCTAssertGreaterThanOrEqual(
            long.panelSize.width,
            long.labelFrame.width + DesktopNameOverlayWindow.horizontalPadding * 2 - 0.5,
            "文字两侧要有内边距"
        )
    }

    /// 字号与字重是用户规格，别被无意改掉。
    func testFontMatchesSpec() {
        XCTAssertEqual(DesktopNameOverlayWindow.fontSize, 64)
        XCTAssertEqual(DesktopNameOverlayWindow.fontWeight, .heavy, "字重 800 = .heavy")
    }

    func testPlacementDecodesAllCasesAndRoundTrips() throws {
        for placement in DesktopNamePlacement.allCases {
            let data = try JSONEncoder().encode(placement)
            let restored = try JSONDecoder().decode(DesktopNamePlacement.self, from: data)
            XCTAssertEqual(restored, placement)
        }
    }
}

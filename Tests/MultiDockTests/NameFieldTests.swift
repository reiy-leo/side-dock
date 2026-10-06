import AppKit
import XCTest
@testable import MultiDock

/// `NameField` 宽度的守卫（2026-10-06 用户规格：应用栏里的 Dock 栏名输入框
/// 「要更宽一点，默认 10 个中文字符宽度」）。
///
/// 名字上限是 10 个字素簇（`DesktopNaming.maxLength`）—— 框必须容得下**最宽的 10 个字**
/// （全角中文），不能出现省略号。宽度不是手调的数字，而是「10 字实测 + 内边距 + 余量」
/// 的算式（`NameField.tenCharacterWidth`）；这里用**运行时字体测量**核对算式本体，
/// 系统字体度量变了会红在测试上，而不是悄悄把名字截出省略号。
@MainActor
final class NameFieldTests: XCTestCase {

    /// 10 个全角字素簇在输入框字号下的步进 × 10 + `NSTextFieldCell` 自带行内边距 + 容器内边距
    /// = 框宽的基准（`NameField.tenCharacterWidth` 的算式本体）。
    ///
    /// ⚠️ cell 的 4pt（左右各 2pt `lineFragmentPadding`）必须计入 —— 实测只按
    /// 「文本宽 + 容器内边距」给框会差 1pt 截成省略号（真踩过）。
    func testTenCharacterWidthFitsTenFullWidthGlyphs() {
        let font = NSFont.systemFont(ofSize: NameFieldContainer.fontSize)
        let text = String(repeating: "中", count: DesktopNaming.maxLength)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let cellOverhead = Self.cellWidthOverhead(for: font)
        let containerPadding = NameFieldContainer.horizontalPadding * 2

        XCTAssertGreaterThanOrEqual(
            NameField.tenCharacterWidth, textWidth + cellOverhead + containerPadding,
            "框宽必须 ≥ 10 个全角字实测宽 + cell 行内边距 + 容器内边距（否则第 10 个字被截成省略号）"
        )
    }

    /// 也不能宽得没边：余量（留给编辑态光标）不许超过一个字宽。
    func testWidthSlackStaysWithinOneGlyph() {
        let font = NSFont.systemFont(ofSize: NameFieldContainer.fontSize)
        let glyphWidth = ("中" as NSString).size(withAttributes: [.font: font]).width
        let textWidth = glyphWidth * CGFloat(DesktopNaming.maxLength)
        let slack = NameField.tenCharacterWidth
            - textWidth - Self.cellWidthOverhead(for: font) - NameFieldContainer.horizontalPadding * 2

        XCTAssertGreaterThan(slack, 0, "要留出编辑态光标余量（正好等于文本宽会吃掉最后一个字的收笔）")
        XCTAssertLessThanOrEqual(slack, glyphWidth, "余量超过一个字宽就不再是「10 个中文宽度」")
    }

    /// `NSTextFieldCell` 对给定文本要求的最小行宽 − 文本自身宽度（即左右行内边距）。
    /// 直接问 AppKit（`cellSize`），不硬编码 4pt —— 系统换了度量测试还能自查。
    private static func cellWidthOverhead(for font: NSFont) -> CGFloat {
        let cell = NSTextFieldCell()
        cell.font = font
        cell.stringValue = String(repeating: "中", count: DesktopNaming.maxLength)
        cell.wraps = false
        cell.isScrollable = true
        let textWidth = (cell.stringValue as NSString).size(withAttributes: [.font: font]).width
        return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10000, height: 100)).width - textWidth
    }

    /// 桌面名的输入框（`DesktopsTabView` 用 200pt）不受这里影响：两边上限同为 10 字素簇，
    /// 应用栏用的 `tenCharacterWidth` 也必须 ≥ 桌面页那个 200pt 的 0.6 倍这种明显过窄的值 ——
    /// 等价地：它必须容得下与桌面页同样长的名字，两处口径一致。
    func testWidthMatchesDesktopTabCapacity() {
        let font = NSFont.systemFont(ofSize: NameFieldContainer.fontSize)
        let ten = ("密" as NSString).size(withAttributes: [.font: font]).width * 10
        XCTAssertGreaterThan(NameField.tenCharacterWidth, ten,
                             "10 字素簇上限的名字在应用栏里也不该出省略号")
    }
}

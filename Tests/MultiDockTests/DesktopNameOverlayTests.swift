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

    // MARK: - 展示效果（2026-10-06 用户规格：默认 / 流动霓虹 / 赛博紫韵）

    func testEffectDecodesAllCasesAndRoundTrips() throws {
        for effect in DesktopNameEffect.allCases {
            let data = try JSONEncoder().encode(effect)
            let restored = try JSONDecoder().decode(DesktopNameEffect.self, from: data)
            XCTAssertEqual(restored, effect)
        }
    }

    /// 旧配置没有这个键 → 默认「默认」档，不能解码失败（与其它字段同一 decodeIfPresent 规矩）。
    func testSettingsDecodeDefaultsToStandardEffect() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{\"restoreOnQuit\": true}".utf8))
        XCTAssertEqual(legacy.desktopNameEffect, .standard, "旧配置回落默认效果")

        var settings = AppSettings()
        settings.desktopNameEffect = .cyberPurple
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.desktopNameEffect, .cyberPurple, "往返保持")
    }

    /// `.standard` 没有渲染配方（走原生 label），两个霓虹档必须有 —— 三档各自的语义不能混。
    func testOnlyEffectCasesHaveSpecs() {
        XCTAssertNil(DesktopNameEffect.standard.spec, "默认档不需要自绘配方")
        let neon = try? XCTUnwrap(DesktopNameEffect.neonFlow.spec)
        let cyber = try? XCTUnwrap(DesktopNameEffect.cyberPurple.spec)
        XCTAssertNotNil(neon, "流动霓虹必须有配方")
        XCTAssertNotNil(cyber, "赛博紫韵必须有配方")
        XCTAssertNotEqual(neon, cyber, "两档效果不能是同一份配方")
    }

    /// 配方的基本约束：渐变至少两色、速度为正、辉光不超出面板上下内边距（否则会被圆角剪切）。
    func testEffectSpecsAreWellFormed() throws {
        for effect in DesktopNameEffect.allCases {
            guard let spec = effect.spec else { continue }
            XCTAssertGreaterThanOrEqual(spec.gradientColors.count, 2, "\(effect) 渐变至少两色")
            XCTAssertGreaterThan(spec.flowPeriod, 0, "\(effect) 流动周期必须为正")
            XCTAssertGreaterThan(spec.glowRadius, 0, "\(effect) 辉光半径必须为正")
            XCTAssertLessThanOrEqual(
                spec.glowRadius,
                DesktopNameOverlayWindow.verticalPadding * 2,
                "\(effect) 辉光半径超出面板内边距会被圆角剪切"
            )
        }
    }

    /// **流动分段的覆盖性**（画布的核心几何）：任意相位下两段渐变相加都盖住整行文字。
    func testFlowSegmentsCoverTextAtEveryPhase() {
        for step in 0...20 {
            let phase = CGFloat(step) / 20
            let starts = DesktopNameEffectCanvas.flowSegmentStarts(phase: phase)
            XCTAssertEqual(starts.count, 2, "两段")
            // 每段覆盖 [start, start+1]；并集必须包含 [0,1]（文字所在区间）。
            let covered = starts.map { ($0, $0 + 1) }
            for point in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
                XCTAssertTrue(
                    covered.contains { $0.0 <= point && point <= $0.1 },
                    "相位 \(phase) 下点 \(point) 没被任何一段盖住"
                )
            }
            // 两段首尾相接（第二段起点 = 第一段终点），衔接颜色才连续。
            XCTAssertEqual(starts[1], starts[0] + 1, accuracy: 0.0001, "两段必须相接")
        }
    }

    /// 相位越界也要安全（负数/超 1 回绕后同样满足覆盖性）。
    func testFlowSegmentsWrapOutOfRangePhases() {
        for phase in [CGFloat(-0.3), -1.0, 1.0, 2.7] {
            let starts = DesktopNameEffectCanvas.flowSegmentStarts(phase: phase)
            XCTAssertEqual(starts.count, 2)
            let minStart = starts.min()!
            let maxEnd = starts.max()! + 1
            XCTAssertLessThanOrEqual(minStart, 0, "并集下界要 ≤ 0（相位 \(phase)）")
            XCTAssertGreaterThanOrEqual(maxEnd, 1, "并集上界要 ≥ 1（相位 \(phase)）")
        }
    }

    /// 字形路径：有文字 → 路径非空且宽度与实测文本宽同量级；空文字 → nil。
    func testGlyphPathIsBuiltForText() throws {
        let font = NSFont.systemFont(
            ofSize: DesktopNameOverlayWindow.fontSize,
            weight: DesktopNameOverlayWindow.fontWeight
        )
        let path = try XCTUnwrap(
            DesktopNameEffectCanvas.glyphPath(text: "工作", font: font, canvasSize: NSSize(width: 600, height: 120))
        )
        let measured = ("工作" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThan(path.boundingBoxOfPath.width, 0)
        // 路径量到的是**墨水范围**（不含 glyph 两侧的 side bearing），比推进宽窄 —— 实测
        // 「工作」在 64 pt heavy 下：推进 120.8、墨水 101.1。只钉量级区间：既不可能是空路径，
        // 也不该超过推进宽（超过了说明测的是别的字形）。
        XCTAssertGreaterThan(Double(path.boundingBoxOfPath.width), Double(measured) * 0.5)
        XCTAssertLessThanOrEqual(Double(path.boundingBoxOfPath.width), Double(measured))
        XCTAssertNil(DesktopNameEffectCanvas.glyphPath(text: "", font: font, canvasSize: NSSize(width: 600, height: 120)),
                     "空文字没有字形")
    }

    /// `presentation(...)` 把效果带进布局：几何仍按面板布局算，档位与效果互不干扰。
    func testPresentationCarriesEffectAndLayout() {
        let presentation = DesktopNameOverlayWindow.presentation(
            text: "工作",
            available: visibleFrame,
            placement: .middle,
            effect: .neonFlow
        )
        XCTAssertEqual(presentation.effect, .neonFlow)
        XCTAssertEqual(presentation.text, "工作")
        XCTAssertEqual(
            presentation.layout,
            DesktopNameOverlayWindow.panelLayout(text: "工作", available: visibleFrame, placement: .middle),
            "效果不应影响几何"
        )
    }

    // MARK: - 窗口接线（不弹窗：直接调 `apply`，与快照同一渲染路径）

    /// 默认档：label 可见、画布隐藏、无动画在跑。
    func testApplyingStandardShowsLabelOnly() {
        let window = DesktopNameOverlayWindow()
        window.apply(DesktopNameOverlayWindow.presentation(
            text: "工作", available: visibleFrame, placement: .top, effect: .standard
        ))
        XCTAssertEqual(window.activeEffect, .standard)
        XCTAssertTrue(window.labelIsVisibleForTesting)
        XCTAssertFalse(window.canvasIsVisibleForTesting)
        XCTAssertFalse(window.canvasIsAnimatingForTesting, "默认档不跑动画")
    }

    /// 效果档：画布顶掉 label 并开始播动画；切回默认档停表。
    func testApplyingEffectsDrivesCanvasLifecycle() {
        let window = DesktopNameOverlayWindow()
        for effect in [DesktopNameEffect.neonFlow, .cyberPurple] {
            window.apply(DesktopNameOverlayWindow.presentation(
                text: "一二三四五六七八九十", available: visibleFrame, placement: .top, effect: effect
            ))
            XCTAssertEqual(window.activeEffect, effect)
            XCTAssertFalse(window.labelIsVisibleForTesting, "\(effect) 档文字走画布")
            XCTAssertTrue(window.canvasIsVisibleForTesting)
            XCTAssertTrue(window.canvasIsAnimatingForTesting, "\(effect) 档展示期间应播动画")
        }
        window.apply(DesktopNameOverlayWindow.presentation(
            text: "工作", available: visibleFrame, placement: .top, effect: .standard
        ))
        XCTAssertFalse(window.canvasIsAnimatingForTesting, "切回默认档必须停表")
        XCTAssertTrue(window.labelIsVisibleForTesting)
    }

    /// **定时器真的在跑**：起表后跑 0.2 s RunLoop，相位必须往前推 ——
    /// rules.md 里有「DispatchSourceTimer 在本项目 RunLoop 场景一次都不 fire」的前科，
    /// 这条守卫证明 `Timer` + `.common` 模式这条路的动画真的会推进（不只是"isAnimating = true"）。
    func testAnimationActuallyAdvancesPhase() {
        let window = DesktopNameOverlayWindow()
        window.apply(DesktopNameOverlayWindow.presentation(
            text: "工作", available: visibleFrame, placement: .top, effect: .neonFlow
        ))
        XCTAssertEqual(window.snapshotCanvas.phase, 0, "起手相位归零")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertGreaterThan(window.snapshotCanvas.phase, 0, "0.2 秒后相位必须往前走（定时器真的在 fire）")
        window.hide()
        let frozen = window.snapshotCanvas.phase
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(window.snapshotCanvas.phase, frozen, accuracy: 0.0001, "停表后相位不该再动")
    }

    /// 展示→收起：动画停止（没停表就是隐藏后还在烧 CPU）。
    func testHideStopsAnimation() {
        let window = DesktopNameOverlayWindow()
        window.apply(DesktopNameOverlayWindow.presentation(
            text: "工作", available: visibleFrame, placement: .top, effect: .neonFlow
        ))
        XCTAssertTrue(window.canvasIsAnimatingForTesting)
        window.hide()
        XCTAssertFalse(window.canvasIsAnimatingForTesting, "收起后动画必须停")
    }

    /// 效果从 provider 实时读：同一窗口先默认档、再霓虹档，第二次展示就用新效果。
    func testEffectProviderIsReadPerPresentation() {
        var effect = DesktopNameEffect.standard
        let window = DesktopNameOverlayWindow(
            placementProvider: { .top },
            styleProvider: { effect }
        )
        let layout = DesktopNameOverlayWindow.panelLayout(text: "工作", available: visibleFrame, placement: .top)
        window.apply(DesktopNameOverlayWindow.presentation(
            text: "工作", available: visibleFrame, placement: .top, effect: effect
        ))
        XCTAssertEqual(window.activeEffect, .standard)
        effect = .neonFlow
        window.apply(DesktopNameOverlayWindow.presentation(
            text: "工作", available: visibleFrame, placement: .top, effect: effect
        ))
        XCTAssertEqual(window.activeEffect, .neonFlow, "每次展示都重新读效果")
        XCTAssertEqual(layout.panelSize, DesktopNameOverlayWindow.panelLayout(
            text: "工作", available: visibleFrame, placement: .top
        ).panelSize, "几何不受效果影响")
    }
}

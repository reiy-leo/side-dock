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

    // MARK: - 展示背景效果（2026-10-06 用户规格：默认 / 流动霓虹 / 赛博紫韵；
    //          同日用户澄清：效果修饰**背景**，不是字体）

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

    /// `.standard` 没有背景配方（走原生磨砂面板），两个霓虹档必须有 —— 三档语义不能混。
    func testOnlyEffectCasesHaveSpecs() {
        XCTAssertNil(DesktopNameEffect.standard.spec, "默认档不需要自绘背景")
        let neon = try? XCTUnwrap(DesktopNameEffect.neonFlow.spec)
        let cyber = try? XCTUnwrap(DesktopNameEffect.cyberPurple.spec)
        XCTAssertNotNil(neon, "流动霓虹必须有背景配方")
        XCTAssertNotNil(cyber, "赛博紫韵必须有背景配方")
        XCTAssertNotEqual(neon, cyber, "两档效果不能是同一份配方")
    }

    /// 背景配方的基本约束：底色/光带至少两色、速度为正在、光带半透明（不能冲淡白字）、
    /// 两档配色必须不同（用户要的是两种效果）。
    func testEffectSpecsAreWellFormed() throws {
        for effect in DesktopNameEffect.allCases {
            guard let spec = effect.spec else { continue }
            XCTAssertGreaterThanOrEqual(spec.baseColors.count, 2, "\(effect) 底色至少两色")
            XCTAssertGreaterThanOrEqual(spec.bandColors.count, 2, "\(effect) 光带至少两条")
            XCTAssertGreaterThan(spec.flowPeriod, 0, "\(effect) 流动周期必须为正")
            XCTAssertGreaterThan(spec.bandAlpha, 0, "\(effect) 光带要看得见")
            XCTAssertLessThanOrEqual(spec.bandAlpha, 0.65, "\(effect) 光带太亮会冲淡压在上面的白字")
        }
        let neon = try XCTUnwrap(DesktopNameEffect.neonFlow.spec)
        let cyber = try XCTUnwrap(DesktopNameEffect.cyberPurple.spec)
        XCTAssertNotEqual(neon.bandColors, cyber.bandColors, "两档光带配色要区分得开")
        XCTAssertNotEqual(neon.baseColors, cyber.baseColors, "两档底色要区分得开")
    }

    /// 底色必须够暗（白字可读性的前提）：两档底色在 sRGB 下的亮度都应低于 0.25。
    func testEffectBasesAreDarkEnoughForWhiteText() throws {
        for effect in DesktopNameEffect.allCases {
            guard let spec = effect.spec else { continue }
            for color in spec.baseColors {
                let rgb = color.usingColorSpace(.sRGB) ?? color
                let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
                XCTAssertLessThan(luminance, 0.25, "\(effect) 底色过亮（亮度 \(luminance)），白字会读不清")
            }
        }
    }

    /// **光带扫动的几何**（画布核心纯函数）：相位 0→1 时中心从面板左外侧扫到右外侧；
    /// 第二条反向（相向而行）；相位越界回绕安全。
    func testBandSweepGeometry() {
        let panel: CGFloat = 400
        let band: CGFloat = 248
        let outsideLeft = -band / 2
        let outsideRight = panel + band / 2
        for index in [0, 1] {
            // 端点：完整扫过面板。带 0 从左外侧 → 右外侧；带 1 反向（相向而行）。
            // ⚠️ 相位 1.0 回绕等于 0（`1 mod 1 = 0`）—— 用 0.99 逼近终点，别拿 1.0 当终点。
            let atStart = DesktopNameEffectCanvas.bandCenterX(
                phase: 0, bandIndex: index, panelWidth: panel, bandWidth: band
            )
            let nearEnd = DesktopNameEffectCanvas.bandCenterX(
                phase: 0.99, bandIndex: index, panelWidth: panel, bandWidth: band
            )
            if index % 2 == 0 {
                XCTAssertEqual(atStart, outsideLeft, accuracy: 0.5, "带 \(index) 起点应在左外侧")
                XCTAssertGreaterThan(nearEnd, panel, "带 \(index) 接近终点时应已扫出右缘")
            } else {
                XCTAssertEqual(atStart, outsideRight, accuracy: 0.5, "带 \(index) 起点应在右外侧（反向）")
                XCTAssertLessThan(nearEnd, 0, "带 \(index) 接近终点时应已扫出左缘")
            }
            let mid = DesktopNameEffectCanvas.bandCenterX(
                phase: 0.5, bandIndex: index, panelWidth: panel, bandWidth: band
            )
            XCTAssertEqual(mid, panel / 2, accuracy: 0.5, "带 \(index) 中点应扫过面板中心")
        }
        // 两条带方向相反：相位 p 时 index0 在 p、index1 在 1-p。
        let forward = DesktopNameEffectCanvas.bandCenterX(phase: 0.25, bandIndex: 0, panelWidth: panel, bandWidth: band)
        let backward = DesktopNameEffectCanvas.bandCenterX(phase: 0.25, bandIndex: 1, panelWidth: panel, bandWidth: band)
        let backwardAt75 = DesktopNameEffectCanvas.bandCenterX(phase: 0.75, bandIndex: 0, panelWidth: panel, bandWidth: band)
        XCTAssertEqual(backward, backwardAt75, accuracy: 0.5, "第二条带应与第一条相向而行")
        XCTAssertNotEqual(forward, backward, accuracy: 1, "两条带相位不同步")
        // 越界相位回绕后仍在扫动范围内。
        for phase in [CGFloat(-0.3), -1.0, 1.0, 2.7] {
            let center = DesktopNameEffectCanvas.bandCenterX(
                phase: phase, bandIndex: 0, panelWidth: panel, bandWidth: band
            )
            XCTAssertGreaterThanOrEqual(center, -band / 2 - 0.5, "相位 \(phase) 越界")
            XCTAssertLessThanOrEqual(center, panel + band / 2 + 0.5, "相位 \(phase) 越界")
        }
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

    /// 默认档：文字可见（labelColor，跟随磨砂材质）、背景画布隐藏、无动画在跑。
    func testApplyingStandardShowsLabelOnly() {
        let window = DesktopNameOverlayWindow()
        window.apply(DesktopNameOverlayWindow.presentation(
            text: "工作", available: visibleFrame, placement: .top, effect: .standard
        ))
        XCTAssertEqual(window.activeEffect, .standard)
        XCTAssertTrue(window.labelIsVisibleForTesting, "文字永远可见")
        XCTAssertEqual(window.labelColorForTesting, .labelColor, "默认档字色跟随外观")
        XCTAssertFalse(window.canvasIsVisibleForTesting)
        XCTAssertFalse(window.canvasIsAnimatingForTesting, "默认档不跑动画")
    }

    /// 效果档：**文字仍可见**（只换背景——用户澄清点），背景画布显示并开始播动画；
    /// 字色切成纯白（暗底上保证可读）；切回默认档停表、字色还原。
    func testApplyingEffectsKeepsTextAndDrivesBackgroundCanvas() {
        let window = DesktopNameOverlayWindow()
        for effect in [DesktopNameEffect.neonFlow, .cyberPurple] {
            window.apply(DesktopNameOverlayWindow.presentation(
                text: "一二三四五六七八九十", available: visibleFrame, placement: .top, effect: effect
            ))
            XCTAssertEqual(window.activeEffect, effect)
            XCTAssertTrue(window.labelIsVisibleForTesting, "\(effect) 档文字必须仍然显示（效果是背景，不是字体）")
            XCTAssertEqual(window.labelColorForTesting, .white, "\(effect) 档暗底上白字")
            XCTAssertTrue(window.canvasIsVisibleForTesting, "\(effect) 档背景画布接管")
            XCTAssertTrue(window.canvasIsAnimatingForTesting, "\(effect) 档展示期间应播动画")
        }
        window.apply(DesktopNameOverlayWindow.presentation(
            text: "工作", available: visibleFrame, placement: .top, effect: .standard
        ))
        XCTAssertFalse(window.canvasIsAnimatingForTesting, "切回默认档必须停表")
        XCTAssertFalse(window.canvasIsVisibleForTesting, "默认档背景画布隐藏")
        XCTAssertEqual(window.labelColorForTesting, .labelColor, "默认档字色还原")
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

import AppKit
import SwiftUI
import XCTest
@testable import MultiDock

/// 设置窗口红绿灯对齐的守卫（2026-10-06 用户规格：**红绿灯和下方侧边栏图标对齐、
/// 距离左边和上边的 margin 相等**）。
///
/// 背景：窗口无 titlebar（`fullSizeContentView`），红绿灯浮在侧边栏上。系统默认三个圆点
/// 中心 (14,14)/(34,14)/(54,14) 贴角，与侧边栏图标列（墨迹中心 x ≈ 26）不在一列。
/// 生产修法：`SettingsWindow`（`UI/SettingsWindow.swift`）在每次布局拍子里把三个按钮
/// 重贴到「图标列正上方」—— 首个圆点中心 (26,26)，左 = 上 = 20 pt，步距 20（系统默认）。
///
/// 分两层守卫：
/// - **纯几何**（默认跑）：钉住 26 / 20 / 步距 / 标题栏加长量覆盖圆点下缘；
/// - **真实窗口**（`MULTIDOCK_UI_SNAPSHOT=1`）：离屏渲染 + 墨迹扫描，验「真正画出来的
///   像素」在目标位（frame 对了但没画出来 / 画歪了都能抓到），外加整颗圆点命中与
///   缩放后保持 —— resize 会把按钮 frame 打回系统基准（实测），这是最容易回退的点。
@MainActor
final class SettingsChromeLayoutTests: XCTestCase {

    // MARK: - 纯几何（默认跑）

    /// 第一个圆点的中心必须落在侧边栏图标列中心线上 —— 这就是用户说的「和下方的图标对齐」。
    func testFirstDotCentersOnSidebarIconColumn() {
        let center = TrafficLightLayout.buttonCenter(index: 0, themeHeight: 588)
        XCTAssertEqual(center.x, TrafficLightLayout.iconColumnCenterX, accuracy: 0.001,
                       "首个圆点中心 x 必须等于图标列中心（对齐规格）")
    }

    /// 左、上边距相等且都等于 `edgeMargin`（用户规格「距离左边、上边margin一样」）。
    /// 注意两个约束是耦合的：对齐把左距钉死为 `iconColumnCenterX - dotRadius`，
    /// 上距只能取同一个值 —— 单独调任一个都会破坏另一个，所以这里钉死等式。
    func testLeftAndTopMarginsAreEqualAndCoupledToAlignment() {
        let themeHeight: CGFloat = 588
        let center = TrafficLightLayout.buttonCenter(index: 0, themeHeight: themeHeight)
        let leftMargin = center.x - TrafficLightLayout.dotRadius
        let topMargin = themeHeight - center.y - TrafficLightLayout.dotRadius
        XCTAssertEqual(leftMargin, topMargin, accuracy: 0.001, "左距 == 上距（用户规格）")
        XCTAssertEqual(leftMargin, TrafficLightLayout.edgeMargin, accuracy: 0.001)
        XCTAssertEqual(TrafficLightLayout.edgeMargin,
                       TrafficLightLayout.iconColumnCenterX - TrafficLightLayout.dotRadius,
                       accuracy: 0.001,
                       "edgeMargin 必须由图标列对齐推导 —— 这是「对齐且边距相等」的唯一解")
    }

    /// 三个圆点的步距保持系统默认 20 pt（不要另起一套间距）。
    func testDotSpacingStaysAtSystemDefault() {
        let centers = (0..<3).map { TrafficLightLayout.buttonCenter(index: $0, themeHeight: 588).x }
        XCTAssertEqual(centers[1] - centers[0], TrafficLightLayout.dotSpacing, accuracy: 0.001)
        XCTAssertEqual(centers[2] - centers[1], TrafficLightLayout.dotSpacing, accuracy: 0.001)
        XCTAssertEqual(TrafficLightLayout.dotSpacing, 20, accuracy: 0.001)
    }

    /// 标题栏加长量必须罩住圆点下缘（圆点底 = edgeMargin + 直径 32 pt > 系统标题栏 28 pt）——
    /// 不然圆点下半截的点击会穿透到侧边栏。
    func testTitlebarGrowthCoversDotBottom() {
        let dotBottom = TrafficLightLayout.edgeMargin + TrafficLightLayout.dotRadius * 2
        let systemTitlebarHeight: CGFloat = 28
        XCTAssertGreaterThan(dotBottom, systemTitlebarHeight,
                             "前置：圆点下缘低于系统标题栏时才有加长的必要")
        XCTAssertGreaterThanOrEqual(
            systemTitlebarHeight + TrafficLightLayout.titlebarGrowth, dotBottom,
            "系统标题栏高度 + 加长量必须 ≥ 圆点下缘（否则圆点下缘点不到）"
        )
    }

    // MARK: - 真实窗口（离屏，MULTIDOCK_UI_SNAPSHOT=1 才跑）

    func testTrafficLightsRenderAlignedAndStayPutAcrossResize() throws {
        guard ProcessInfo.processInfo.environment["MULTIDOCK_UI_SNAPSHOT"] == "1" else {
            throw XCTSkip("需要 MULTIDOCK_UI_SNAPSHOT=1（真实窗口的离屏墨迹扫描）")
        }

        let window = makeWindow()
        defer { window.close() }

        try verifyChrome(window, label: "初始")

        // resize 会把按钮 frame 打回系统基准 —— 布局拍子的重贴必须把位置拉回来。
        window.setFrame(NSRect(x: 100, y: 100, width: 1000, height: 700), display: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
        try verifyChrome(window, label: "放大后")

        window.setFrame(NSRect(x: 100, y: 100, width: 760, height: 520), display: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
        try verifyChrome(window, label: "缩小后")
    }

    /// 逐项核对：三个圆点的渲染墨迹在目标位、左/上边距相等、第一列与侧边栏图标居中对齐、
    /// 整颗圆点可点（中心 + 下半截）、按钮 frame 在缩放后仍是换算值。
    private func verifyChrome(_ window: NSWindow, label: String) throws {
        let theme = try XCTUnwrap(window.contentView?.superview, "\(label): 拿不到主题框视图")
        let themeHeight = theme.bounds.height

        let rep = try XCTUnwrap(theme.bitmapImageRepForCachingDisplay(in: theme.bounds),
                                "\(label): 建位图失败")
        theme.cacheDisplay(in: theme.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(theme.bounds.width, 1)

        // 1) 圆点渲染墨迹：中心与边距（像素真值，不只信 frame）
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            let button = try XCTUnwrap(window.standardWindowButton(type), "\(label): 缺按钮 \(index)")
            let inWindow = button.superview!.convert(button.frame, to: nil)
            let x0 = Int(inWindow.minX * scale) - 6, x1 = Int(inWindow.maxX * scale) + 6
            let y0 = Int((themeHeight - inWindow.maxY) * scale) - 6
            let y1 = Int((themeHeight - inWindow.minY) * scale) + 6
            let box = try XCTUnwrap(contrastBBox(rep, x: x0..<x1, y: y0..<y1),
                                    "\(label): 按钮 \(index) 区域没有可见墨迹")
            let centerX = (Double(box.minX) + Double(box.maxX + 1)) / 2 / Double(scale)
            let centerYFromTop = (Double(box.minY) + Double(box.maxY + 1)) / 2 / Double(scale)
            let expected = TrafficLightLayout.buttonCenter(index: index, themeHeight: themeHeight)
            XCTAssertEqual(centerX, expected.x, accuracy: 0.75,
                           "\(label): 第 \(index + 1) 个圆点中心 x 应贴图标列")
            XCTAssertEqual(centerYFromTop, themeHeight - expected.y, accuracy: 0.75,
                           "\(label): 第 \(index + 1) 个圆点中心 y 应在顶下 26 pt")

            if index == 0 {
                let leftMargin = Double(box.minX) / Double(scale)
                let topMargin = Double(box.minY) / Double(scale)
                XCTAssertEqual(leftMargin, TrafficLightLayout.edgeMargin, accuracy: 0.75,
                               "\(label): 左距应为 \(TrafficLightLayout.edgeMargin) pt（渲染真值）")
                XCTAssertEqual(topMargin, TrafficLightLayout.edgeMargin, accuracy: 0.75,
                               "\(label): 上距应为 \(TrafficLightLayout.edgeMargin) pt（渲染真值）")
            }
        }

        // 2) 整颗圆点可点：中心与下半截（顶下 20 / 26 / 31 / 33 都在按钮上）
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            let button = try XCTUnwrap(window.standardWindowButton(type), "\(label): 缺按钮")
            for pointFromTop in [20.0, 26.0, 31.0, 33.0] {
                let pt = NSPoint(x: TrafficLightLayout.buttonCenter(index: index, themeHeight: themeHeight).x,
                                 y: themeHeight - pointFromTop)
                let hit = theme.hitTest(pt)
                let onButton = hit === button || (hit?.isDescendant(of: button) ?? false)
                XCTAssertTrue(onButton,
                              "\(label): 顶下 \(pointFromTop) pt 处应命中第 \(index + 1) 个圆点，实际 \(hit.map(String.init(describing:)) ?? "nil")")
            }
        }

        // 3) 与侧边栏图标列对齐：找到第一行图标（列表在 spacer 下方，y ≥ 56），取墨迹中心。
        if let iconCenterX = firstSidebarIconCenterX(rep, scale: scale) {
            XCTAssertEqual(iconCenterX, TrafficLightLayout.iconColumnCenterX, accuracy: 2.0,
                           "\(label): 侧边栏图标列中心应 ≈ \(TrafficLightLayout.iconColumnCenterX)")
            XCTAssertEqual(TrafficLightLayout.buttonCenter(index: 0, themeHeight: themeHeight).x,
                           iconCenterX, accuracy: 2.0,
                           "\(label): 红绿灯必须和下方图标对齐")
        } else {
            XCTFail("\(label): 侧边栏图标列找不到（扫描区域或阈值问题）")
        }
    }

    // MARK: - 夹具与像素工具

    private func makeWindow() -> NSWindow {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-chrome-layout-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let displayUUID = "AB24BB32-C5EC-D10A-6F9D-F01F35552F60"
        let spaces = [
            DesktopSpace(displayUUID: displayUUID, spaceUUID: "1DAA5EC4-6F9D-4A24-BB32-CHROME00000001",
                         id64: 6, type: 0, ordinal: 1),
            DesktopSpace(displayUUID: displayUUID, spaceUUID: "1DAA5EC4-6F9D-4A24-BB32-CHROME00000002",
                         id64: 7, type: 0, ordinal: 2),
        ]
        let state = AppState(
            dockController: DockController(
                preferences: FakePreferences(domain: [
                    "orientation": .string("bottom"), "tilesize": .double(36),
                    "persistent-apps": .array([]), "persistent-others": .array([]),
                    "mru-spaces": .bool(true), "mod-count": .int(1),
                ]),
                reloader: DockReloader(
                    process: FakeDockProcess(),
                    timeout: .milliseconds(200),
                    pollInterval: .milliseconds(2),
                    fallbackGrace: .milliseconds(20),
                    minimumSpacing: .zero
                ),
                backup: {}
            ),
            configStore: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            baselineStore: BaselineStore(
                baselineURL: directory.appendingPathComponent("baseline.plist"),
                markerURL: directory.appendingPathComponent("session.state"),
                backupsURL: directory.appendingPathComponent("backups", isDirectory: true)
            ),
            provider: FakeSpaceProvider(desktops: spaces, activeSpaceID: 6),
            fileLog: makeTestFileLog(),
            environmentReader: { EnvironmentReading(stageManagerActive: false, dockSide: .bottom) }
        )
        state.refreshDesktops()
        state.refreshDockCapabilities()
        let window = SettingsWindowFactory.makeWindow(state: state, tabModel: SettingsTabModel())
        window.appearance = NSAppearance(named: .aqua)
        window.layoutIfNeeded()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return window
    }

    /// 与区域四角背景差异明显的像素 bbox（圆点用的对比扫描）。
    private func contrastBBox(_ rep: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var bg = 1.0
        for (sx, sy) in [(x.lowerBound, y.lowerBound), (x.upperBound - 1, y.lowerBound),
                         (x.lowerBound, y.upperBound - 1), (x.upperBound - 1, y.upperBound - 1)] {
            if let c = rep.colorAt(x: sx, y: sy)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 {
                bg = min(bg, luminance(c))
            }
        }
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for yy in y {
            for xx in x where xx >= 0 && xx < rep.pixelsWide && yy >= 0 && yy < rep.pixelsHigh {
                guard let c = rep.colorAt(x: xx, y: yy)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                if luminance(c) < bg - 0.03 {
                    minX = min(minX, xx); maxX = max(maxX, xx)
                    minY = min(minY, yy); maxY = max(maxY, yy)
                }
            }
        }
        guard minX <= maxX else { return nil }
        return (minX, maxX, minY, maxY)
    }

    /// 侧边栏第一行图标的墨迹中心 x（pt）。列表行图标是灰阶墨迹：与同列上方背景
    /// （40 px 采样）亮度差 > 0.12 视作墨迹；扫描 y ∈ [56, 240] pt，取最先出现的行。
    private func firstSidebarIconCenterX(_ rep: NSBitmapImageRep, scale: CGFloat) -> Double? {
        let xRange = Int(6 * scale)..<Int(40 * scale)
        let yRange = Int(56 * scale)..<min(Int(240 * scale), rep.pixelsHigh)
        for yy in yRange {
            var minX = Int.max, maxX = Int.min
            for xx in xRange where xx < rep.pixelsWide {
                guard let c = rep.colorAt(x: xx, y: yy)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                let refY = max(0, yy - Int(40 * scale))
                guard let ref = rep.colorAt(x: xx, y: refY)?.usingColorSpace(.sRGB), ref.alphaComponent > 0.5 else { continue }
                if abs(luminance(c) - luminance(ref)) > 0.12 {
                    minX = min(minX, xx); maxX = max(maxX, xx)
                }
            }
            // 图标墨迹宽度 10–30 pt（太窄是噪点、太宽是整行文字/边线，均跳过）
            if minX <= maxX {
                let widthPT = Double(maxX - minX + 1) / Double(scale)
                if widthPT >= 10, widthPT <= 30 {
                    return (Double(minX) + Double(maxX + 1)) / 2 / Double(scale)
                }
            }
        }
        return nil
    }

    private func luminance(_ c: NSColor) -> Double {
        0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
    }
}

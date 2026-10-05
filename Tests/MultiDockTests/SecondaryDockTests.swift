import AppKit
import XCTest
@testable import MultiDock

// MARK: - 几何纯函数

/// 次级 Dock 条的几何。所有数字都按 `SecondaryDockLayout` 的规则手算核对。
@MainActor
final class SecondaryDockLayoutTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1200)

    private func bottomFace(inset: CGFloat = 53) -> DockFaceGeometry {
        DockFaceGeometry(
            orientation: .bottom,
            screen: screen,
            visible: CGRect(x: 0, y: inset, width: 1920, height: 1200 - inset)
        )
    }

    func testDetectsBottomLeftRightFaces() {
        // bottom：只有底边内缩（本机实测 53）。
        XCTAssertEqual(
            SecondaryDockLayout.detectDockFace(
                screen: screen,
                visible: CGRect(x: 0, y: 53, width: 1920, height: 1147)
            )?.orientation,
            .bottom
        )
        // left：只有左边内缩。
        XCTAssertEqual(
            SecondaryDockLayout.detectDockFace(
                screen: screen,
                visible: CGRect(x: 76, y: 0, width: 1844, height: 1200)
            )?.orientation,
            .left
        )
        // right：只有右边内缩。
        XCTAssertEqual(
            SecondaryDockLayout.detectDockFace(
                screen: screen,
                visible: CGRect(x: 0, y: 0, width: 1844, height: 1200)
            )?.orientation,
            .right
        )
    }

    func testNoInsetMeansNoFace() {
        // Dock 隐藏（自动隐藏滑走）后内缩归零 —— 探测不到，调用方保持现状。
        XCTAssertNil(SecondaryDockLayout.detectDockFace(screen: screen, visible: screen))
        // 低于阈值的小内缩同样不算（噪声/边沿触发区）。
        XCTAssertNil(
            SecondaryDockLayout.detectDockFace(
                screen: screen,
                visible: CGRect(x: 0, y: 5, width: 1920, height: 1195)
            )
        )
    }

    func testBottomPlacementPeeksAboveDock() {
        let face = bottomFace()
        let barSize = SecondaryDockLayout.barSize(itemCount: 4, iconSize: 36, isVertical: false)
        // 4 * (36+8) + 16 = 192；36 + 20 = 56
        XCTAssertEqual(barSize, CGSize(width: 192, height: 56))

        let (revealed, tucked) = SecondaryDockLayout.placement(barSize: barSize, face: face)
        // 展开贴 Dock 顶边上方：y = 53 + 4；水平居中：(1920-192)/2 = 864。
        XCTAssertEqual(revealed, CGRect(x: 864, y: 57, width: 192, height: 56))
        // 半露 = 向下平移半个条厚（28），下半截被原生 Dock 挡住。
        XCTAssertEqual(tucked, CGRect(x: 864, y: 29, width: 192, height: 56))
    }

    func testRightPlacementPeeksTowardScreenInterior() {
        let face = DockFaceGeometry(
            orientation: .right,
            screen: screen,
            visible: CGRect(x: 0, y: 0, width: 1844, height: 1200)
        )
        let barSize = SecondaryDockLayout.barSize(itemCount: 4, iconSize: 36, isVertical: true)
        XCTAssertEqual(barSize, CGSize(width: 56, height: 192))

        let (revealed, tucked) = SecondaryDockLayout.placement(barSize: barSize, face: face)
        // 展开贴 Dock 内侧面左侧：x = 1844 - 4 - 56 = 1784；贴屏幕底角：y = 4。
        XCTAssertEqual(revealed, CGRect(x: 1784, y: 4, width: 56, height: 192))
        // 半露 = 向右平移半个条宽（28），右半截滑进 Dock 身后。
        XCTAssertEqual(tucked, CGRect(x: 1812, y: 4, width: 56, height: 192))
    }

    func testLeftPlacementMirrorsRight() {
        let face = DockFaceGeometry(
            orientation: .left,
            screen: screen,
            visible: CGRect(x: 76, y: 0, width: 1844, height: 1200)
        )
        let barSize = SecondaryDockLayout.barSize(itemCount: 4, iconSize: 36, isVertical: true)
        let (revealed, tucked) = SecondaryDockLayout.placement(barSize: barSize, face: face)
        XCTAssertEqual(revealed, CGRect(x: 80, y: 4, width: 56, height: 192))
        XCTAssertEqual(tucked, CGRect(x: 52, y: 4, width: 56, height: 192))
    }

    func testOversizedBarIsClampedIntoScreen() {
        let barSize = SecondaryDockLayout.barSize(itemCount: 100, iconSize: 48, isVertical: false)
        let (revealed, tucked) = SecondaryDockLayout.placement(barSize: barSize, face: bottomFace())
        XCTAssertEqual(revealed.width, 1920 - SecondaryDockLayout.screenMargin * 2)
        XCTAssertEqual(revealed.minX, SecondaryDockLayout.screenMargin)
        XCTAssertEqual(tucked.width, revealed.width, "收起只平移，不改尺寸")
    }

    func testDockAreaTracksOrientation() {
        // bottom：Dock 区 = 屏幕底部的内缩条带。
        XCTAssertEqual(
            SecondaryDockLayout.dockArea(of: bottomFace(inset: 53)),
            CGRect(x: 0, y: 0, width: 1920, height: 53)
        )
        // right：Dock 区 = 屏幕右侧的内缩条带。
        XCTAssertEqual(
            SecondaryDockLayout.dockArea(
                of: DockFaceGeometry(orientation: .right, screen: screen, visible: CGRect(x: 0, y: 0, width: 1844, height: 1200))
            ),
            CGRect(x: 1844, y: 0, width: 76, height: 1200)
        )
        // left：Dock 区 = 屏幕左侧的内缩条带。
        XCTAssertEqual(
            SecondaryDockLayout.dockArea(
                of: DockFaceGeometry(orientation: .left, screen: screen, visible: CGRect(x: 76, y: 0, width: 1844, height: 1200))
            ),
            CGRect(x: 0, y: 0, width: 76, height: 1200)
        )
    }
}

// MARK: - 内容构建

@MainActor
final class SecondaryDockContentBuilderTests: XCTestCase {

    private func tile(
        path: String,
        label: String,
        bundleID: String
    ) -> DockTile {
        DockTile.makeFileTile(
            url: URL(fileURLWithPath: path, isDirectory: true),
            label: label,
            bundleIdentifier: bundleID
        )
    }

    func testFinderFirstThenLaunchpadThenApps() {
        let safari = tile(path: "/Applications/Safari.app", label: "Safari", bundleID: "com.apple.Safari")
        var config = DockConfig()
        config.pinnedApps = DockStripRules.normalizedApps([safari, DockStripRules.makeLaunchpadTile()])

        let snapshot = SecondaryDockContentBuilder.snapshot(
            from: config,
            runningBundleIDs: ["com.apple.Safari"],
            iconSize: 36
        )
        let items = try? XCTUnwrap(snapshot?.items)

        XCTAssertEqual(items?.count, 3, "Finder 幻影 + 启动台 + 1 个 App")
        XCTAssertEqual(items?.first?.id, "finder")
        XCTAssertEqual(items?.first?.isRunning, true, "Finder 永远在运行")
        XCTAssertEqual(items?.dropFirst().first?.id, DockStripRules.makeLaunchpadTile().normalizedKey)
        XCTAssertEqual(items?.last?.label, "Safari")
        XCTAssertEqual(items?.last?.isRunning, true, "运行指示按 bundle id 匹配")
        XCTAssertEqual(items?.last?.launchPath, "/Applications/Safari.app")
    }

    func testUninstalledAppIsFlaggedNotRunning() {
        var config = DockConfig()
        config.pinnedApps = DockStripRules.normalizedApps([
            tile(path: "/Applications/DoesNotExist-XYZ.app", label: "Ghost", bundleID: "com.ghost"),
        ])
        let snapshot = SecondaryDockContentBuilder.snapshot(
            from: config,
            runningBundleIDs: [],
            iconSize: 36
        )
        XCTAssertEqual(snapshot?.items.last?.isInstalled, false)
        XCTAssertEqual(snapshot?.items.last?.isRunning, false)
    }

    func testEmptyConfigYieldsNilSnapshot() {
        XCTAssertNil(
            SecondaryDockContentBuilder.snapshot(from: DockConfig(), runningBundleIDs: [], iconSize: 36)
        )
    }
}

// MARK: - 调度状态机

@MainActor
private final class FakeSecondaryDockPresenter: SecondaryDockPresenting {
    private(set) var updateCount = 0
    private(set) var lastIsVertical = false
    private(set) var frames: [(frame: NSRect, animated: Bool)] = []
    private(set) var frontCount = 0
    private(set) var outCount = 0
    private(set) var pullCount = 0

    var lastFrame: NSRect? { frames.last?.frame }
    var lastAnimated: Bool? { frames.last?.animated }

    func updateContent(_ content: SecondaryDockContentSnapshot, isVertical: Bool) {
        updateCount += 1
        lastIsVertical = isVertical
    }

    func setFrame(_ frame: NSRect, animated: Bool) {
        frames.append((frame, animated))
    }

    func orderFront() { frontCount += 1 }
    func orderOut() { outCount += 1 }
    func pullToActiveSpace() { pullCount += 1 }
}

@MainActor
private final class FakeDockFaceProvider: DockFaceProviding {
    var face: DockFaceGeometry?
    func currentFace() -> DockFaceGeometry? { face }
}

@MainActor
private final class ContentBox {
    var snapshot: SecondaryDockContentSnapshot?
}

/// 可变光标替身：显出带判定的用例要在「带里 / 带外」之间切换光标位置。
@MainActor
private final class MouseBox {
    var point: CGPoint
    init(point: CGPoint) { self.point = point }
}

@MainActor
final class SecondaryDockControllerTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1200)

    private func bottomFace(inset: CGFloat = 53) -> DockFaceGeometry {
        DockFaceGeometry(
            orientation: .bottom,
            screen: screen,
            visible: CGRect(x: 0, y: inset, width: 1920, height: 1200 - inset)
        )
    }

    private func rightFace() -> DockFaceGeometry {
        DockFaceGeometry(
            orientation: .right,
            screen: screen,
            visible: CGRect(x: 0, y: 0, width: 1844, height: 1200)
        )
    }

    private func makeContent(items: Int = 3) -> SecondaryDockContentSnapshot {
        let entries = (0..<items).map { index in
            SecondaryDockItem(
                id: "app-\(index)",
                label: "App \(index)",
                icon: NSWorkspace.shared.icon(for: .applicationBundle),
                launchPath: nil,
                isInstalled: true,
                isRunning: false
            )
        }
        return SecondaryDockContentSnapshot(items: entries, iconSize: 36)
    }

    private func makeController(
        presenter: FakeSecondaryDockPresenter,
        provider: FakeDockFaceProvider,
        content: ContentBox,
        enabled: Bool = true
    ) -> SecondaryDockController {
        SecondaryDockController(deps: .init(
            presenter: presenter,
            faceProvider: provider,
            content: { [weak content] _ in content?.snapshot },
            isEnabled: { enabled },
            log: { _ in },
            tuckDebounce: .milliseconds(10),
            mouseLocation: { CGPoint(x: -9999, y: -9999) }
        ))
    }

    private func makeSpace() -> DesktopSpace {
        FakeSpaceProvider.desktops(count: 1)[0]
    }

    /// 显示流程的前置：几何探到 + 内容就位 + 桌面变化事件。
    private func showBar(
        _ controller: SecondaryDockController,
        presenter: FakeSecondaryDockPresenter,
        provider: FakeDockFaceProvider,
        content: ContentBox
    ) {
        provider.face = bottomFace()
        controller.geometryTick()
        content.snapshot = makeContent()
        controller.spaceDidChange(makeSpace())
        XCTAssertEqual(presenter.frontCount, 1, "前置：条已显示")
    }

    func testSpaceChangeShowsTuckedBar() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content)

        provider.face = bottomFace()
        controller.geometryTick()
        content.snapshot = makeContent()
        controller.spaceDidChange(makeSpace())

        XCTAssertEqual(presenter.frontCount, 1)
        let barSize = SecondaryDockLayout.barSize(itemCount: 3, iconSize: 36, isVertical: false)
        let expected = SecondaryDockLayout.placement(barSize: barSize, face: bottomFace())
        XCTAssertEqual(presenter.lastFrame, expected.tucked, "默认只露一半")
        XCTAssertEqual(presenter.lastAnimated, false, "几何定位不走动画")
    }

    func testHoverRevealsThenTucksAfterDebounce() async throws {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content)
        showBar(controller, presenter: presenter, provider: provider, content: content)

        controller.hoverChanged(true)
        let barSize = SecondaryDockLayout.barSize(itemCount: 3, iconSize: 36, isVertical: false)
        let expected = SecondaryDockLayout.placement(barSize: barSize, face: bottomFace())
        XCTAssertEqual(presenter.lastFrame, expected.revealed, "hover 滑出全条")
        XCTAssertEqual(presenter.lastAnimated, true, "hover 走动画")

        controller.hoverChanged(false)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(presenter.lastFrame, expected.tucked, "防抖过后收回半露")
    }

    func testHoverReenterDuringDebounceKeepsRevealed() async throws {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content)
        showBar(controller, presenter: presenter, provider: provider, content: content)

        controller.hoverChanged(true)
        controller.hoverChanged(false)
        controller.hoverChanged(true)
        try await Task.sleep(for: .milliseconds(120))
        let barSize = SecondaryDockLayout.barSize(itemCount: 3, iconSize: 36, isVertical: false)
        let expected = SecondaryDockLayout.placement(barSize: barSize, face: bottomFace())
        XCTAssertEqual(presenter.lastFrame, expected.revealed, "防抖期内回来就不收回")
    }

    func testTuckSafetyNetKeepsBarUnderMouse() async throws {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        // 鼠标就停在展开后的条上（exit 事件丢失的场景）：(900, 60) 落在展开区内。
        let controller = SecondaryDockController(deps: .init(
            presenter: presenter,
            faceProvider: provider,
            content: { [weak content] _ in content?.snapshot },
            isEnabled: { true },
            log: { _ in },
            tuckDebounce: .milliseconds(10),
            mouseLocation: { CGPoint(x: 900, y: 60) }
        ))
        showBar(controller, presenter: presenter, provider: provider, content: content)

        controller.hoverChanged(true)
        controller.hoverChanged(false)
        try await Task.sleep(for: .milliseconds(120))
        let barSize = SecondaryDockLayout.barSize(itemCount: 3, iconSize: 36, isVertical: false)
        let expected = SecondaryDockLayout.placement(barSize: barSize, face: bottomFace())
        XCTAssertEqual(presenter.lastFrame, expected.revealed, "鼠标还在条上就不收回")
    }

    func testFullscreenSpaceHides() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content)
        showBar(controller, presenter: presenter, provider: provider, content: content)

        controller.spaceDidChange(nil)
        XCTAssertEqual(presenter.outCount, 1, "全屏空间与原生 Dock 一样躲起来")
        XCTAssertEqual(presenter.frontCount, 1, "不再重复显示")
    }

    // MARK: - 切桌面的空间拉回（方案 ②，实验 24 / AGENTS.md §6.1 #4，2026-10-05 拍板）

    func testSpaceSwitchPullsShowingBarToNewSpace() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content)
        showBar(controller, presenter: presenter, provider: provider, content: content)

        // 切到另一个桌面：窗口单空间配方还挂在旧空间，必须拉回当前空间并淡入。
        controller.spaceDidChange(FakeSpaceProvider.desktops(count: 2)[1])
        XCTAssertEqual(presenter.pullCount, 1, "显示中的条换了空间要拉回")
        XCTAssertEqual(presenter.frontCount, 1, "拉回复用已显示的窗口，不重新 orderFront")
        XCTAssertEqual(presenter.outCount, 0, "拉回不该先收起")
    }

    func testRapidSpaceSwitchesPullEachTime() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content)
        showBar(controller, presenter: presenter, provider: provider, content: content)

        let spaces = FakeSpaceProvider.desktops(count: 2)
        controller.spaceDidChange(spaces[1])
        controller.spaceDidChange(spaces[0])
        XCTAssertEqual(presenter.pullCount, 2, "每次真实切换都拉一次（过期的复位由窗口侧取消，不归调度器管）")
    }

    func testSameSpaceEventDoesNotPull() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content)
        showBar(controller, presenter: presenter, provider: provider, content: content)

        // 同一桌面的重复事件（刷新路径）不拉——拉回自带淡入，重复触发会叠出闪烁。
        controller.spaceDidChange(makeSpace())
        XCTAssertEqual(presenter.pullCount, 0, "同一桌面的重复事件不拉回")
    }

    func testFullscreenSwitchHidesWithoutPull() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content)
        showBar(controller, presenter: presenter, provider: provider, content: content)

        controller.spaceDidChange(nil)
        XCTAssertEqual(presenter.outCount, 1)
        XCTAssertEqual(presenter.pullCount, 0, "切到全屏是隐藏路径，不是拉回")
    }

    func testReturnFromFullscreenShowsWithoutPull() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content)
        showBar(controller, presenter: presenter, provider: provider, content: content)

        controller.spaceDidChange(nil)
        XCTAssertEqual(presenter.outCount, 1, "前置：全屏时已隐藏")

        // 从全屏回到用户桌面：从隐藏到显示，orderFront 本身就落在当前空间，不用拉。
        controller.spaceDidChange(FakeSpaceProvider.desktops(count: 2)[1])
        XCTAssertEqual(presenter.frontCount, 2, "从隐藏恢复显示")
        XCTAssertEqual(presenter.pullCount, 0, "隐藏过的窗口 orderFront 落在当前空间，无需拉回")
    }

    func testDisabledKeepsHidden() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content, enabled: false)

        provider.face = bottomFace()
        controller.geometryTick()
        content.snapshot = makeContent()
        controller.spaceDidChange(makeSpace())

        XCTAssertEqual(presenter.frontCount, 0, "开关关闭就不显示")
    }

    func testEmptyContentHides() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content)

        provider.face = bottomFace()
        controller.geometryTick()
        content.snapshot = nil
        controller.spaceDidChange(makeSpace())
        XCTAssertEqual(presenter.frontCount, 0, "空配置的桌面不显示条")

        content.snapshot = makeContent()
        controller.refresh()
        XCTAssertEqual(presenter.frontCount, 1, "配置补上内容后立即出现")
    }

    func testGeometryTickRepositionsOnOrientationChange() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content)
        showBar(controller, presenter: presenter, provider: provider, content: content)

        provider.face = rightFace()
        controller.geometryTick()

        XCTAssertEqual(presenter.lastIsVertical, true, "侧边 Dock 配竖条")
        let barSize = SecondaryDockLayout.barSize(itemCount: 3, iconSize: 36, isVertical: true)
        let expected = SecondaryDockLayout.placement(barSize: barSize, face: rightFace())
        XCTAssertEqual(presenter.lastFrame, expected.tucked)
    }

    // MARK: - 与原生 Dock 的可见性同步（自动隐藏）

    private func makeSyncController(
        presenter: FakeSecondaryDockPresenter,
        provider: FakeDockFaceProvider,
        content: ContentBox,
        mouse: MouseBox,
        grace: Duration = .milliseconds(20)
    ) -> SecondaryDockController {
        SecondaryDockController(deps: .init(
            presenter: presenter,
            faceProvider: provider,
            content: { [weak content] _ in content?.snapshot },
            isEnabled: { true },
            log: { _ in },
            tuckDebounce: .milliseconds(5),
            geometryPollInterval: .milliseconds(5),
            revealGrace: grace,
            mouseLocation: { [weak mouse] in mouse?.point ?? .zero }
        ))
    }

    func testAutoHideHidesBarAfterGraceWhenCursorOutsideRevealZone() async {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        // 光标在屏幕中央，不在 Dock 区。
        let mouse = MouseBox(point: CGPoint(x: 960, y: 600))
        let controller = makeSyncController(presenter: presenter, provider: provider, content: content, mouse: mouse)

        provider.face = bottomFace()
        controller.geometryTick()
        content.snapshot = makeContent()
        controller.spaceDidChange(makeSpace())
        XCTAssertEqual(presenter.frontCount, 1, "前置：条已显示")

        // Dock 滑走（face == nil）：光标不在显出带 → 宽限后与 Dock 一起收起。
        provider.face = nil
        controller.geometryTick()
        XCTAssertEqual(presenter.outCount, 0, "宽限期内还没收")
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(presenter.outCount, 1, "原生 Dock 隐藏，次级条同步隐藏")
    }

    func testAutoHideKeepsBarWhileCursorInRevealZone() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        // 光标在 Dock 区里（bottom 内缩 53 → 区高 53）。
        let mouse = MouseBox(point: CGPoint(x: 960, y: 30))
        let controller = makeSyncController(presenter: presenter, provider: provider, content: content, mouse: mouse)

        provider.face = bottomFace()
        controller.geometryTick()
        content.snapshot = makeContent()
        controller.spaceDidChange(makeSpace())
        XCTAssertEqual(presenter.frontCount, 1)

        provider.face = nil
        controller.geometryTick()
        XCTAssertEqual(presenter.outCount, 0, "光标在显出带里：Dock 在屏或即将显出，条保持显示")
        XCTAssertEqual(presenter.frontCount, 1, "已显示就不重复 orderFront")
    }

    func testAutoHideShowsBarAgainWhenCursorReturnsToRevealZone() async {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let mouse = MouseBox(point: CGPoint(x: 960, y: 600))
        let controller = makeSyncController(presenter: presenter, provider: provider, content: content, mouse: mouse)

        provider.face = bottomFace()
        controller.geometryTick()
        content.snapshot = makeContent()
        controller.spaceDidChange(makeSpace())

        mouse.point = CGPoint(x: 960, y: 600)
        provider.face = nil
        controller.geometryTick()
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(presenter.outCount, 1, "前置：已随 Dock 隐藏")

        // 光标回到 Dock 区（鼠标碰边触发自动隐藏显出）→ 条同步重新出现。
        mouse.point = CGPoint(x: 960, y: 30)
        controller.geometryTick()
        XCTAssertEqual(presenter.frontCount, 2, "show 则同步 show")
        XCTAssertEqual(presenter.outCount, 1, "重新显示不该多一次收起")
    }

    func testBarWidthFollowsContentCount() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let mouse = MouseBox(point: CGPoint(x: -9999, y: -9999))
        let controller = makeSyncController(presenter: presenter, provider: provider, content: content, mouse: mouse)

        provider.face = bottomFace()
        controller.geometryTick()
        content.snapshot = makeContent(items: 3)
        controller.spaceDidChange(makeSpace())

        let wideSize = SecondaryDockLayout.barSize(itemCount: 3, iconSize: 36, isVertical: false)
        let widePlacement = SecondaryDockLayout.placement(barSize: wideSize, face: bottomFace())
        XCTAssertEqual(presenter.lastFrame, widePlacement.tucked, "窗口宽度按当前内容条目数撑开")

        // 换到只有 1 个条目的桌面：内容变，窗口宽度跟着变窄（2026-10-05 用户修订：
        // 废弃固定槽位——方案 ② 下宽度变化静默发生在沉没位，切桌面无可见跳变）。
        content.snapshot = makeContent(items: 1)
        controller.spaceDidChange(makeSpace())
        let narrowSize = SecondaryDockLayout.barSize(itemCount: 1, iconSize: 36, isVertical: false)
        let narrowPlacement = SecondaryDockLayout.placement(barSize: narrowSize, face: bottomFace())
        XCTAssertEqual(presenter.lastFrame, narrowPlacement.tucked, "切桌面后窗口宽度随新内容收缩")
    }
}

// MARK: - 冻结闸门（AppState 路径）

@MainActor
final class SecondaryDockFreezeTests: XCTestCase {

    private func baseDomain() -> [String: PlistValue] {
        [
            "orientation": .string("bottom"),
            "tilesize": .double(36),
            "magnification": .bool(true),
            "largesize": .double(98),
            "autohide": .bool(false),
            "mineffect": .string("scale"),
            "minimize-to-application": .bool(true),
            "persistent-apps": .array([]),
            "persistent-others": .array([]),
            "mru-spaces": .bool(true),
            "mod-count": .int(1),
        ]
    }

    private func makeStores(_ name: String) -> (ConfigStore, BaselineStore) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            BaselineStore(
                baselineURL: directory.appendingPathComponent("baseline.plist"),
                markerURL: directory.appendingPathComponent("session.state"),
                backupsURL: directory.appendingPathComponent("backups", isDirectory: true)
            )
        )
    }

    private func makeState(
        preferences: FakePreferences,
        stores: (ConfigStore, BaselineStore),
        provider: FakeSpaceProvider? = nil
    ) -> AppState {
        let state = AppState(
            dockController: DockController(
                preferences: preferences,
                reloader: DockReloader(
                    process: FakeDockProcess(),
                    timeout: .milliseconds(200),
                    pollInterval: .milliseconds(2),
                    fallbackGrace: .milliseconds(20),
                    minimumSpacing: .zero
                ),
                backup: {}
            ),
            configStore: stores.0,
            baselineStore: stores.1,
            provider: provider ?? FakeSpaceProvider(isAvailable: false, reason: "测试替身"),
            fileLog: makeTestFileLog()
        )
        // 冻结现在是产品默认值；这里的用例各自显式决定冻结状态，默认按「未冻结」测。
        state.updateSettings { $0.freezeNativeDockSwitching = false }
        return state
    }

    private func config(tilesize: Double = 52, apps: Int = 1) -> DockConfig {
        var config = DockConfig()
        config.appearance.tilesize = tilesize
        // 各不相同的条目（真实键名不同），避免归一化去重把条数压掉。
        config.pinnedApps = (0..<apps).map { index in
            DockTile.makeFileTile(
                url: URL(fileURLWithPath: "/Applications/App\(index).app", isDirectory: true),
                label: "App\(index)",
                bundleIdentifier: "com.example.app\(index)"
            )
        }
        return config
    }

    func testFrozenSwitchSkipsApplyButStillSwitches() async {
        let events = Box<[String]>([])
        let spaces = FakeSpaceProvider.desktops(count: 2)
        let provider = FakeSpaceProvider(
            desktops: spaces,
            activeSpaceID: spaces[0].id64,
            events: events
        )
        let preferences = FakePreferences(domain: baseDomain(), events: events)
        let state = makeState(preferences: preferences, stores: makeStores("freeze-switch"), provider: provider)
        state.start()
        defer { state.stop() }

        state.setDockConfigInMemory(config(), for: .defaultDock)
        state.dockEdited(.defaultDock, reason: "准备")
        await state.dockController.waitForIdle()
        state.updateSettings { $0.freezeNativeDockSwitching = true }
        await state.dockController.waitForIdle()

        let writesBefore = preferences.writeCount
        events.value.removeAll()
        state.switchToNextDesktop()
        await state.dockController.waitForIdle()

        XCTAssertEqual(provider.switchTargets, [spaces[1].id64], "冻结只停应用，不停切换")
        XCTAssertEqual(preferences.writeCount, writesBefore, "冻结期间切桌面不能写偏好")
        XCTAssertEqual(events.value.filter { $0 == "write" }.count, 0, "被动回调同样被冻结挡住")
    }

    func testUnfrozenSwitchStillApplies() async {
        let events = Box<[String]>([])
        let spaces = FakeSpaceProvider.desktops(count: 2)
        let provider = FakeSpaceProvider(
            desktops: spaces,
            activeSpaceID: spaces[0].id64,
            events: events
        )
        let preferences = FakePreferences(domain: baseDomain(), events: events)
        let state = makeState(preferences: preferences, stores: makeStores("unfrozen-switch"), provider: provider)
        state.start()
        defer { state.stop() }

        state.setDockConfigInMemory(config(), for: .defaultDock)
        state.dockEdited(.defaultDock, reason: "准备")
        await state.dockController.waitForIdle()
        // 桌面 2 配一份不同的 Dock 且暂不应用（关掉 autoApplyOnEdit），
        // 否则目标内容与已应用内容一致，指纹短路根本不会写，测不出"照常应用"。
        state.updateSettings { $0.autoApplyOnEdit = false }
        state.setOverride(config(tilesize: 88), for: spaces[1], reason: "桌面 2 独立")

        let writesBefore = preferences.writeCount
        state.switchToNextDesktop()
        await state.dockController.waitForIdle()

        XCTAssertGreaterThan(preferences.writeCount, writesBefore, "未冻结时预应用照常写偏好")
    }

    func testFrozenManualDockEditRoutesToDefaultDock() {
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("freeze-edit"))
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.freezeNativeDockSwitching = true }

        state.handleUserDockEdit(config(tilesize: 77))

        XCTAssertEqual(
            state.settings.defaultDock.appearance.tilesize, 77,
            "冻结模式下手动改动归入默认 Dock"
        )
        XCTAssertTrue(state.bindings.isEmpty, "不能回存到「当前桌面的绑定」——冻结后那个语义不成立")
    }

    func testAppSettingsDecodeDefaultsForSecondaryDockFields() throws {
        // 旧配置文件没有这两个键 → 走 decodeIfPresent 的默认值，不能解码失败。
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{\"restoreOnQuit\": true}".utf8))
        XCTAssertTrue(legacy.showSecondaryDock, "次级条默认开")
        XCTAssertTrue(legacy.freezeNativeDockSwitching, "冻结默认开（2026-10-04：原生 Dock 不逐桌面重启）")

        // 往返保持（冻结翻到 false 这一侧，与默认值相反的方向才算验过）。
        var settings = AppSettings()
        settings.showSecondaryDock = false
        settings.freezeNativeDockSwitching = false
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(restored, settings)
    }

    // MARK: - 冻结模式的「原生 Dock = 默认 Dock」语义

    func testEnablingFreezeAlignsNativeDockToDefaultDock() async {
        let spaces = FakeSpaceProvider.desktops(count: 2)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("freeze-enable"), provider: provider)
        state.start()
        defer { state.stop() }

        // 先制造「原生 Dock 停在某个桌面的 override 上」的局面：冻结开启后必须对齐回默认 Dock。
        state.updateSettings { $0.defaultDock = config(tilesize: 52) }
        state.setOverride(config(tilesize: 88), for: spaces[0], reason: "预置独立 Dock")
        await state.dockController.waitForIdle()
        XCTAssertEqual(preferences.readDomain()["tilesize"]?.doubleValue, 88, "预置条件：原生 Dock 已是 override")

        let writesBefore = preferences.writeCount
        state.setFreezeNativeDockSwitching(true)
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.readDomain()["tilesize"]?.doubleValue, 52,
                       "开启冻结后原生 Dock 立刻对齐默认 Dock，不等下一次切换")
        XCTAssertGreaterThan(preferences.writeCount, writesBefore, "对齐是一次真实写入（而不是只翻开关）")
    }

    func testDisablingFreezeAppliesActiveDesktopConfig() async {
        let spaces = FakeSpaceProvider.desktops(count: 2)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("freeze-disable"), provider: provider)
        state.start()
        defer { state.stop() }

        state.updateSettings { $0.defaultDock = config(tilesize: 52) }
        // 活动桌面的 override 先建好但不应用（关 autoApply），由「解冻」这一步来应用它。
        state.updateSettings { $0.autoApplyOnEdit = false }
        state.setOverride(config(tilesize: 88), for: spaces[0], reason: "活动桌面的独立 Dock")
        state.setFreezeNativeDockSwitching(true)
        await state.dockController.waitForIdle()
        XCTAssertEqual(preferences.readDomain()["tilesize"]?.doubleValue, 52, "预置条件：冻结在默认 Dock 上")

        let writesBefore = preferences.writeCount
        state.setFreezeNativeDockSwitching(false)
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.readDomain()["tilesize"]?.doubleValue, 88,
                       "解冻后当前桌面的生效配置立刻应用，别等下一次切换")
        XCTAssertGreaterThan(preferences.writeCount, writesBefore)
    }

    func testLaunchInFreezeModeAlignsDefaultDockAfterSelfHeal() async throws {
        let spaces = FakeSpaceProvider.desktops(count: 2)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let preferences = FakePreferences(domain: baseDomain())
        let stores = makeStores("freeze-launch")
        let state = makeState(preferences: preferences, stores: stores, provider: provider)

        // 造一笔「上次没还原完」的欠账：自愈先写回基准（tilesize 36），冻结对齐再覆盖成默认 Dock（52）。
        // 最终落在 52 就证明对齐排在自愈之后 —— 反了的话最终会是 36。
        try stores.1.writeSessionMarker(
            BaselineStore.SessionMarker(
                pid: 999_999,
                startedAt: Date(),
                appliedFingerprint: "dirty-launch",
                appliedAt: Date()
            )
        )
        state.updateSettings { $0.freezeNativeDockSwitching = true }
        state.updateSettings { $0.defaultDock = config(tilesize: 52) }
        state.start()
        defer { state.stop() }

        await state.waitForSelfHeal()
        await state.waitForFrozenDockAlignment()
        await state.dockController.waitForIdle()

        XCTAssertEqual(preferences.readDomain()["tilesize"]?.doubleValue, 52,
                       "启动对齐在自愈之后执行，最终停在冻结配置（默认 Dock）上")
    }

    // MARK: - 冻结模式的内容口径（条宽随内容，图标尺寸取默认 Dock）

    func testFreezeModeContentUsesDefaultDockIconSizeAndOwnItemCount() {
        let spaces = FakeSpaceProvider.desktops(count: 2)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("freeze-sizing"), provider: provider)
        state.start()
        defer { state.stop() }

        state.updateSettings { $0.freezeNativeDockSwitching = true }
        state.updateSettings { $0.defaultDock = config(tilesize: 36, apps: 1) }
        // 桌面 1：1 个 App；桌面 2：3 个 App（都没有启动台 → 内容构建各补一枚）。
        state.updateSettings { $0.autoApplyOnEdit = false }
        state.setOverride(config(tilesize: 44, apps: 1), for: spaces[0], reason: "桌面 1")
        state.setOverride(config(tilesize: 48, apps: 3), for: spaces[1], reason: "桌面 2")

        let desktop1 = state.secondaryDockContent(for: spaces[0])
        XCTAssertEqual(desktop1?.items.count, 3,
                       "桌面 1 内容口径：1 Finder + (1 App + 1 启动台) = 3；条宽按本桌面内容撑开（2026-10-05 修订，废弃固定槽位）")
        XCTAssertEqual(desktop1?.iconSize, 36, "冻结模式图标尺寸取默认 Dock，不跟桌面走")

        state.updateSettings { $0.freezeNativeDockSwitching = false }
        let unfrozen = state.secondaryDockContent(for: spaces[0])
        XCTAssertEqual(unfrozen?.iconSize, 44, "未冻结时图标尺寸跟随该桌面生效配置")
    }
}

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
    private(set) var hideCount = 0
    private(set) var fadeBackCount = 0
    /// 安全网判定信号的可注入替身（真实窗口 = `window.isOnActiveSpace` / `window.alphaValue`）。
    var stubIsOnActiveSpace = true
    var stubCurrentAlpha: CGFloat = 1

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
    func hideForSpaceTransition() { hideCount += 1 }
    func fadeBackFromSpaceTransition() { fadeBackCount += 1 }
    var isOnActiveSpace: Bool { stubIsOnActiveSpace }
    var currentAlpha: CGFloat { stubCurrentAlpha }
}

@MainActor
private final class FakeDockFaceProvider: DockFaceProviding {
    var face: DockFaceGeometry?
    /// 独立贴边摆放用的屏幕矩形。默认给一块 1920×1200，用例可覆盖。
    var screenFrame: CGRect? = CGRect(x: 0, y: 0, width: 1920, height: 1200)
    func currentFace() -> DockFaceGeometry? { face }
    func currentScreenFrame() -> CGRect? { screenFrame }
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

    private func makeContent(
        items: Int = 3,
        position: DockBarPosition = .bottom
    ) -> SecondaryDockContentSnapshot {
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
        return SecondaryDockContentSnapshot(items: entries, iconSize: 36, position: position)
    }

    private func makeController(
        presenter: FakeSecondaryDockPresenter,
        provider: FakeDockFaceProvider,
        content: ContentBox,
        enabled: Bool = true,
        gestureRevealTimeout: Duration = .milliseconds(600),
        safetyNetQuietWindow: Duration = .milliseconds(250)
    ) -> SecondaryDockController {
        SecondaryDockController(deps: .init(
            presenter: presenter,
            faceProvider: provider,
            content: { [weak content] _ in content?.snapshot },
            isEnabled: { enabled },
            log: { _ in },
            tuckDebounce: .milliseconds(10),
            gestureRevealTimeout: gestureRevealTimeout,
            safetyNetQuietWindow: safetyNetQuietWindow,
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

    // MARK: - 手势预隐藏（实验 26：type 30 前置手势 → 切桌面「不跟着滑」）

    func testGesturePrehidesShowingBarAndTucks() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(
            presenter: presenter, provider: provider, content: content,
            gestureRevealTimeout: .milliseconds(500)
        )
        showBar(controller, presenter: presenter, provider: provider, content: content)

        // 展开态下触手势：一拍即隐，且顺手收回展开（切完桌面浮出的是半露）。
        controller.hoverChanged(true)
        controller.spaceTransitionGestureDetected()
        XCTAssertEqual(presenter.hideCount, 1, "手势一拍即隐（alpha=0 直设）")
        let barSize = SecondaryDockLayout.barSize(itemCount: 3, iconSize: 36, isVertical: false)
        let expected = SecondaryDockLayout.placement(barSize: barSize, face: bottomFace())
        XCTAssertEqual(presenter.lastFrame, expected.tucked, "预隐藏同时收回复展态")
        XCTAssertEqual(presenter.lastAnimated, false)
    }

    func testGestureTimeoutFadesBackWhenSwitchInterrupted() async throws {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(
            presenter: presenter, provider: provider, content: content,
            gestureRevealTimeout: .milliseconds(20)
        )
        showBar(controller, presenter: presenter, provider: provider, content: content)

        controller.spaceTransitionGestureDetected()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(presenter.fadeBackCount, 1, "打断横扫：超时后分步渐回（不升沉没位）")
        XCTAssertEqual(presenter.pullCount, 0, "没有空间翻转就不做沉没位升起")

        // 渐回后状态机复位：新手势能再次预隐藏。
        controller.spaceTransitionGestureDetected()
        XCTAssertEqual(presenter.hideCount, 2, "超时渐回后可再次预隐藏")
    }

    func testRepeatedGesturesRenewTimeout() async throws {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(
            presenter: presenter, provider: provider, content: content,
            gestureRevealTimeout: .milliseconds(60)
        )
        showBar(controller, presenter: presenter, provider: provider, content: content)

        controller.spaceTransitionGestureDetected()
        try await Task.sleep(for: .milliseconds(30))
        controller.spaceTransitionGestureDetected() // 连击：续命
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(presenter.hideCount, 1, "连击只隐藏一次")
        XCTAssertEqual(presenter.fadeBackCount, 1, "超时从最后一个手势起算，只渐回一次")
    }

    func testSpaceChangeAfterGesturePullsWithoutTimeoutFade() async throws {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(
            presenter: presenter, provider: provider, content: content,
            gestureRevealTimeout: .milliseconds(20)
        )
        showBar(controller, presenter: presenter, provider: provider, content: content)

        controller.spaceTransitionGestureDetected()
        controller.spaceDidChange(FakeSpaceProvider.desktops(count: 2)[1])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(presenter.pullCount, 1, "切换确认走拉回 + 沉没位升起")
        XCTAssertEqual(presenter.fadeBackCount, 0, "拉回已接管显形，超时任务作废")
    }

    func testGestureIgnoredWhenBarNotShowing() async throws {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(
            presenter: presenter, provider: provider, content: content,
            gestureRevealTimeout: .milliseconds(20)
        )
        provider.face = bottomFace()
        controller.geometryTick()
        content.snapshot = nil // 空配置桌面：条不在
        controller.spaceDidChange(makeSpace())

        controller.spaceTransitionGestureDetected()
        XCTAssertEqual(presenter.hideCount, 0, "条不在就无预隐藏可言")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(presenter.fadeBackCount, 0)
    }

    func testHoverSuppressedWhilePreHidden() async throws {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(
            presenter: presenter, provider: provider, content: content,
            gestureRevealTimeout: .milliseconds(20)
        )
        showBar(controller, presenter: presenter, provider: provider, content: content)

        controller.spaceTransitionGestureDetected()
        let framesBefore = presenter.frames.count
        controller.hoverChanged(true)
        XCTAssertEqual(presenter.frames.count, framesBefore, "预隐藏期间 hover 不挪 frame")
        try await Task.sleep(for: .milliseconds(80))
    }

    // MARK: - 安全网（实验 26 26e/26f：卡死兜底，条件模式无关）

    func testSafetyNetHealsStuckDimmedBar() async throws {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(
            presenter: presenter, provider: provider, content: content,
            safetyNetQuietWindow: .milliseconds(20)
        )
        showBar(controller, presenter: presenter, provider: provider, content: content)

        // 模拟 animator 卡死：非预隐藏但 alpha 卡在 0.3（26e 实测故障形态）。
        presenter.stubCurrentAlpha = 0.3
        try await Task.sleep(for: .milliseconds(80))
        controller.geometryTick()
        XCTAssertEqual(presenter.pullCount, 1, "卡半透明 → 安全网重挂拉回")
    }

    func testSafetyNetHealsOrphanedBar() async throws {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(
            presenter: presenter, provider: provider, content: content,
            safetyNetQuietWindow: .milliseconds(20)
        )
        showBar(controller, presenter: presenter, provider: provider, content: content)

        // 模拟孤儿绑定：拉回的 +16ms 复位把窗口绑进了瞬态空间（26e 偶发形态）。
        presenter.stubIsOnActiveSpace = false
        try await Task.sleep(for: .milliseconds(80))
        controller.geometryTick()
        XCTAssertEqual(presenter.pullCount, 1, "不在当前空间 → 安全网重挂拉回")
    }

    func testSafetyNetSkipsHealthyBar() async throws {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(
            presenter: presenter, provider: provider, content: content,
            safetyNetQuietWindow: .milliseconds(20)
        )
        showBar(controller, presenter: presenter, provider: provider, content: content)

        try await Task.sleep(for: .milliseconds(80))
        controller.geometryTick()
        XCTAssertEqual(presenter.pullCount, 0, "健康状态（在当前空间、alpha=1）不触发安全网")
    }

    func testSafetyNetSkipsWhilePreHidden() async throws {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(
            presenter: presenter, provider: provider, content: content,
            gestureRevealTimeout: .milliseconds(500),
            safetyNetQuietWindow: .milliseconds(20)
        )
        showBar(controller, presenter: presenter, provider: provider, content: content)

        // 预隐藏期间两个信号都豁免：翻转前窗口还在当前空间、alpha=0 是预期态。
        controller.spaceTransitionGestureDetected()
        presenter.stubIsOnActiveSpace = false
        presenter.stubCurrentAlpha = 0
        try await Task.sleep(for: .milliseconds(80))
        controller.geometryTick()
        XCTAssertEqual(presenter.pullCount, 0, "预隐藏是预期态，安全网不掺和")
    }

    func testSafetyNetBacksOffAfterUnhealedStuck() async throws {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(
            presenter: presenter, provider: provider, content: content,
            safetyNetQuietWindow: .milliseconds(20)
        )
        showBar(controller, presenter: presenter, provider: provider, content: content)

        presenter.stubCurrentAlpha = 0.3
        try await Task.sleep(for: .milliseconds(80))
        controller.geometryTick()
        XCTAssertEqual(presenter.pullCount, 1, "第一次兜底")

        // 紧跟着的一拍在退避窗（2× 静默窗）内：不再反复闪动。
        controller.geometryTick()
        XCTAssertEqual(presenter.pullCount, 1, "退避期内不重复兜底")

        // 静默超过 2× 静默窗后仍卡死：再兜一次（替身不会真好，正好验连续未愈路径）。
        try await Task.sleep(for: .milliseconds(80))
        controller.geometryTick()
        XCTAssertEqual(presenter.pullCount, 2, "退避窗外仍未愈 → 再次兜底")
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
        // 栏绑在右缘（附着右侧面 Dock）：Dock 从底部换到右侧，条从独立贴边切到附着竖条。
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content)
        showBar(controller, presenter: presenter, provider: provider, content: content)

        content.snapshot = makeContent(items: 3, position: .right)
        controller.refresh()
        let standaloneSize = SecondaryDockLayout.barSize(itemCount: 3, iconSize: 36, isVertical: true)
        let standalone = SecondaryDockLayout.standalonePlacement(
            barSize: standaloneSize, position: .right, screen: provider.screenFrame!
        )
        XCTAssertEqual(presenter.lastFrame, standalone.tucked, "前置：Dock 在底部时右缘栏独立贴边")

        provider.face = rightFace()
        controller.geometryTick()

        XCTAssertEqual(presenter.lastIsVertical, true, "侧边栏配竖条")
        let barSize = SecondaryDockLayout.barSize(itemCount: 3, iconSize: 36, isVertical: true)
        let expected = SecondaryDockLayout.placement(barSize: barSize, face: rightFace())
        XCTAssertEqual(presenter.lastFrame, expected.tucked, "Dock 到了右缘，栏附着到 Dock 内侧")
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

    // MARK: - 独立贴边（2026-10-05：Dock 栏位置 ≠ 原生 Dock 方位）

    func testStandaloneRightPositionIgnoresBottomDockGeometry() async {
        // Dock 在底部、栏在右缘：独立贴边，与 Dock 几何无关；Dock 自动隐藏（face == nil）也不收。
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let mouse = MouseBox(point: CGPoint(x: -9999, y: -9999))
        let controller = makeSyncController(presenter: presenter, provider: provider, content: content, mouse: mouse)

        provider.face = bottomFace()
        controller.geometryTick()
        content.snapshot = makeContent(items: 3, position: .right)
        controller.spaceDidChange(makeSpace())

        let barSize = SecondaryDockLayout.barSize(itemCount: 3, iconSize: 36, isVertical: true)
        let expected = SecondaryDockLayout.standalonePlacement(
            barSize: barSize, position: .right, screen: provider.screenFrame!
        )
        XCTAssertEqual(presenter.lastFrame, expected.tucked, "独立贴边按自己的边摆（半露 = 滑出屏幕一半）")
        XCTAssertEqual(presenter.lastIsVertical, true, "侧边栏配竖条")

        // Dock 滑走：独立贴边的条不跟 Dock 的显隐走。
        provider.face = nil
        controller.geometryTick()
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(presenter.outCount, 0, "独立贴边的条不随原生 Dock 收起")
    }

    func testSwitchingPositionRepositionsImmediately() {
        let presenter = FakeSecondaryDockPresenter()
        let provider = FakeDockFaceProvider()
        let content = ContentBox()
        let controller = makeController(presenter: presenter, provider: provider, content: content)
        showBar(controller, presenter: presenter, provider: provider, content: content)

        // 同一根栏从底部改到右缘：下一次内容更新就要按新位置摆。
        content.snapshot = makeContent(items: 3, position: .right)
        controller.refresh()
        let barSize = SecondaryDockLayout.barSize(itemCount: 3, iconSize: 36, isVertical: true)
        let expected = SecondaryDockLayout.standalonePlacement(
            barSize: barSize, position: .right, screen: provider.screenFrame!
        )
        XCTAssertEqual(presenter.lastFrame, expected.tucked, "位置改动立即生效")
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

    /// 生成 N 个互不相同的可写入条目（真实键名不同，避免归一化去重把条数压掉）。
    private func apps(count: Int, prefix: String = "App") -> [DockTile] {
        (0..<count).map { index in
            DockTile.makeFileTile(
                url: URL(fileURLWithPath: "/Applications/\(prefix)\(index).app", isDirectory: true),
                label: "\(prefix)\(index)",
                bundleIdentifier: "com.example.\(prefix.lowercased())\(index)"
            )
        }
    }

    private func makeState(
        preferences: FakePreferences,
        stores: (ConfigStore, BaselineStore),
        provider: FakeSpaceProvider? = nil,
        recentApps: [DockTile]? = nil,
        environment: EnvironmentReading = EnvironmentReading(stageManagerActive: false, dockSide: .bottom)
    ) -> AppState {
        let injectedApps = recentApps ?? apps(count: 1, prefix: "Default")
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
            fileLog: makeTestFileLog(),
            recentAppsProvider: { limit in Array(injectedApps.prefix(limit)) },
            environmentReader: { environment }
        )
        // 冻结现在是产品默认值；这里的用例各自显式决定冻结状态，默认按「未冻结」测。
        state.updateSettings { $0.freezeNativeDockSwitching = false }
        return state
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

        // 默认 Dock（最近添加的应用）先应用一遍，让"已应用指纹"就位。
        state.applyDefaultDock()
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

        state.applyDefaultDock()
        await state.dockController.waitForIdle()
        // 桌面 2 绑一根内容不同的栏，且暂不应用（关掉 autoApplyOnEdit）——
        // 否则目标内容与已应用内容一致，指纹短路根本不会写，测不出"照常应用"。
        state.updateSettings { $0.autoApplyOnEdit = false }
        let barID = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: barID, name: "桌面 2", apps: DockStripRules.normalizedApps(apps(count: 2))))
        state.bindDockBar(barID, to: spaces[1].id)

        let writesBefore = preferences.writeCount
        state.switchToNextDesktop()
        await state.dockController.waitForIdle()

        XCTAssertGreaterThan(preferences.writeCount, writesBefore, "未冻结时预应用照常写偏好")
    }

    func testFrozenManualDockEditIsNotCapturedAnywhere() {
        // 2026-10-05 起默认 Dock 由「最近添加的应用」自动生成，冻结模式下
        // 原生 Dock 的手动改动无处可回 —— 只能如实记日志说明原因。
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("freeze-edit"))
        state.start()
        defer { state.stop() }
        state.updateSettings { $0.freezeNativeDockSwitching = true }

        let edited = DockConfig(pinnedApps: DockStripRules.normalizedApps(apps(count: 3, prefix: "Manual")))
        state.handleUserDockEdit(edited)

        XCTAssertTrue(state.dockBars.allSatisfy { $0.spaceID == nil }, "冻结后没有「当前桌面的绑定」可回存")
        XCTAssertTrue(state.log.contains { $0.message.contains("手动改动不回存") })
    }

    func testAppSettingsDecodeDefaultsForSecondaryDockFields() throws {
        // 旧配置文件没有这些键 → 走 decodeIfPresent 的默认值，不能解码失败。
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{\"restoreOnQuit\": true}".utf8))
        XCTAssertTrue(legacy.showSecondaryDock, "次级条默认开")
        XCTAssertTrue(legacy.freezeNativeDockSwitching, "冻结默认开（2026-10-04：原生 Dock 不逐桌面重启）")
        XCTAssertEqual(legacy.defaultDockAppCount, 10, "默认 Dock 显示 10 个最近添加的应用")
        XCTAssertTrue(legacy.dockBars.isEmpty, "栏列表为空 = 待迁移")

        // 往返保持（冻结翻到 false 这一侧，与默认值相反的方向才算验过）。
        var settings = AppSettings()
        settings.showSecondaryDock = false
        settings.freezeNativeDockSwitching = false
        settings.defaultDockAppCount = 7
        settings.dockBars = [DockBar(name: "工作", position: .right)]
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

        // 先制造「原生 Dock 停在某个桌面的绑定栏内容上」的局面：冻结开启后必须对齐回默认 Dock。
        state.updateSettings { $0.autoApplyOnEdit = false }
        let barID = state.addDockBar()
        state.updateDockBarInMemory(
            DockBar(id: barID, name: "独占", apps: DockStripRules.normalizedApps(apps(count: 1, prefix: "Bar")))
        )
        state.bindDockBar(barID, to: spaces[0].id)
        state.applyConfigForDesktop(spaces[0], reason: "预置")
        await state.dockController.waitForIdle()
        XCTAssertTrue(
            preferences.readDomain()["persistent-apps"]?.fingerprintToken.contains("Bar0") ?? false,
            "预置条件：原生 Dock 已是绑定栏的内容"
        )

        let writesBefore = preferences.writeCount
        state.setFreezeNativeDockSwitching(true)
        await state.dockController.waitForIdle()

        XCTAssertTrue(
            preferences.readDomain()["persistent-apps"]?.fingerprintToken.contains("Default0") ?? false,
            "开启冻结后原生 Dock 立刻对齐默认 Dock（最近添加的应用），不等下一次切换"
        )
        XCTAssertGreaterThan(preferences.writeCount, writesBefore, "对齐是一次真实写入（而不是只翻开关）")
    }

    func testDisablingFreezeAppliesActiveDesktopConfig() async {
        let spaces = FakeSpaceProvider.desktops(count: 2)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("freeze-disable"), provider: provider)
        state.start()
        defer { state.stop() }

        // 活动桌面的绑定栏先建好但不应用（关 autoApply），由「解冻」这一步来应用它。
        state.updateSettings { $0.autoApplyOnEdit = false }
        let barID = state.addDockBar()
        state.updateDockBarInMemory(
            DockBar(id: barID, name: "独占", apps: DockStripRules.normalizedApps(apps(count: 1, prefix: "Bar")))
        )
        state.bindDockBar(barID, to: spaces[0].id)
        state.setFreezeNativeDockSwitching(true)
        await state.dockController.waitForIdle()
        XCTAssertTrue(
            preferences.readDomain()["persistent-apps"]?.fingerprintToken.contains("Default0") ?? false,
            "预置条件：冻结在默认 Dock（启动台 + 最近应用）上"
        )

        let writesBefore = preferences.writeCount
        state.setFreezeNativeDockSwitching(false)
        await state.dockController.waitForIdle()

        XCTAssertGreaterThan(preferences.writeCount, writesBefore, "解冻后当前桌面的生效配置立刻应用，别等下一次切换")
        XCTAssertTrue(
            preferences.readDomain()["persistent-apps"]?.fingerprintToken.contains("Bar0") ?? false,
            "解冻后应用的是活动桌面绑定栏的内容"
        )
    }

    func testLaunchInFreezeModeAlignsDefaultDockAfterSelfHeal() async throws {
        let spaces = FakeSpaceProvider.desktops(count: 2)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let preferences = FakePreferences(domain: baseDomain())
        let stores = makeStores("freeze-launch")
        let state = makeState(preferences: preferences, stores: stores, provider: provider)

        // 造一笔「上次没还原完」的欠账：自愈先写回基准（空内容），冻结对齐再覆盖成默认 Dock。
        // 最终落在默认 Dock 的内容上就证明对齐排在自愈之后 —— 反了的话最终会是基准的空内容。
        try stores.1.writeSessionMarker(
            BaselineStore.SessionMarker(
                pid: 999_999,
                startedAt: Date(),
                appliedFingerprint: "dirty-launch",
                appliedAt: Date()
            )
        )
        state.updateSettings { $0.freezeNativeDockSwitching = true }
        state.start()
        defer { state.stop() }

        await state.waitForSelfHeal()
        await state.waitForFrozenDockAlignment()
        await state.dockController.waitForIdle()

        XCTAssertEqual(
            preferences.readDomain()["persistent-apps"]?.arrayValue?.count, 2,
            "启动对齐在自愈之后执行，最终停在冻结配置（默认 Dock = 启动台 + 最近应用）上"
        )
    }

    // MARK: - 冻结模式的内容口径（图标尺寸跟随系统；快照带栏位置）

    func testStripContentFollowsSystemTileSizeAndBarPosition() {
        let spaces = FakeSpaceProvider.desktops(count: 2)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let preferences = FakePreferences(domain: baseDomain())
        let state = makeState(preferences: preferences, stores: makeStores("freeze-sizing"), provider: provider)
        state.start()
        defer { state.stop() }

        // 桌面 1：1 个 App（底部）；桌面 2：3 个 App（右侧）。
        state.updateSettings { $0.autoApplyOnEdit = false }
        let bar1 = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: bar1, name: "桌面 1", apps: apps(count: 1, prefix: "B1")))
        state.bindDockBar(bar1, to: spaces[0].id)
        let bar2 = state.addDockBar()
        state.updateDockBarInMemory(DockBar(id: bar2, name: "桌面 2", position: .right, apps: apps(count: 3, prefix: "B2")))
        state.bindDockBar(bar2, to: spaces[1].id)

        let desktop1 = state.secondaryDockContent(for: spaces[0])
        XCTAssertEqual(desktop1?.items.count, 3,
                       "桌面 1 内容口径：1 Finder + (1 App + 1 启动台) = 3；条宽按本桌面内容撑开")
        XCTAssertEqual(desktop1?.iconSize, 36, "图标尺寸跟随系统（域里 tilesize = 36）")
        XCTAssertEqual(desktop1?.position, .bottom)

        let desktop2 = state.secondaryDockContent(for: spaces[1])
        XCTAssertEqual(desktop2?.items.count, 5, "桌面 2：1 Finder + (3 App + 1 启动台) = 5")
        XCTAssertEqual(desktop2?.position, .right, "快照要带上栏的位置，调度器据此选附着/独立贴边")

        // 未绑定栏的桌面没有条可显示。
        let orphan = FakeSpaceProvider.desktops(count: 1, displayUUID: "DISP-2", baseID: 900)[0]
        XCTAssertNil(state.secondaryDockContent(for: orphan), "没绑栏的桌面不显示条")
    }
}

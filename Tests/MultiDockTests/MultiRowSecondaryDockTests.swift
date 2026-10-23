import AppKit
import XCTest
@testable import MultiDock

// MARK: - 多行次级条（2026-10-23 用户规格，同日改版）
//
// 每条屏幕边一扇窗口，同桌面同边的栏各算一行（最多 3 行）。条**只显示一行**，滚动切换：
// 一次手势只翻一行、翻完有停顿；有多行时末端有指示点。去掉了抽屉（展开多行）与拖拽 handle。

@MainActor
final class MultiRowSecondaryDockLayoutTests: XCTestCase {

    func testSizeIsOneRowThickWithIndicatorRoomWhenMultiRow() {
        let single = SecondaryDockLayout.barSize(itemCount: 4, iconSize: 36, isVertical: false)
        XCTAssertEqual(
            SecondaryDockLayout.multiRowSize(maxItemCount: 4, rowCount: 1, iconSize: 36, isVertical: false),
            single,
            "1 行时与旧的单行尺寸完全一致"
        )
        let multi = SecondaryDockLayout.multiRowSize(maxItemCount: 4, rowCount: 3, iconSize: 36, isVertical: false)
        XCTAssertEqual(multi.height, single.height, "多行也只有 1 行厚")
        XCTAssertEqual(multi.width, single.width + SecondaryDockLayout.rowIndicatorLength, "末端留指示点")
        let side = SecondaryDockLayout.multiRowSize(maxItemCount: 4, rowCount: 2, iconSize: 36, isVertical: true)
        XCTAssertEqual(side.width, SecondaryDockLayout.barSize(itemCount: 4, iconSize: 36, isVertical: true).width)
        XCTAssertEqual(side.height,
                       SecondaryDockLayout.barSize(itemCount: 4, iconSize: 36, isVertical: true).height
                           + SecondaryDockLayout.rowIndicatorLength)
    }

    func testSnapshotClampsAnchor() {
        let ids = [UUID(), UUID()]
        var snapshot = SecondaryDockContentSnapshot(items: [], iconSize: 36)
        snapshot.rows = ids.map { SecondaryDockRow(barID: $0, name: "", items: []) }
        snapshot.anchorBarID = UUID()
        XCTAssertEqual(snapshot.effectiveAnchorBarID, ids[0], "锚定行不在：回到第一行")

        let single = SecondaryDockContentSnapshot(items: [], iconSize: 36)
        XCTAssertEqual(single.displayRows.count, 1, "旧口径：没有 rows 就把 items 当唯一一行")
    }
}

// MARK: - 滚动切行

final class SecondaryDockRowPagerTests: XCTestCase {
    private typealias Pager = SecondaryDockRowPager

    private func sample(_ delta: CGFloat, _ phase: Pager.Phase, momentum: Bool = false,
                        precise: Bool = true, at time: TimeInterval) -> Pager.Sample {
        Pager.Sample(delta: delta, phase: phase, isMomentum: momentum, isPrecise: precise, time: time)
    }

    func testOneTrackpadGestureFlipsOnlyOneRow() {
        var pager = Pager()
        XCTAssertEqual(pager.feed(sample(5, .began, at: 0)), 0)
        XCTAssertEqual(pager.feed(sample(10, .changed, at: 0.02)), 0, "没过阈值不翻")
        XCTAssertEqual(pager.feed(sample(15, .changed, at: 0.04)), 1, "过阈值翻一行")
        XCTAssertEqual(pager.feed(sample(80, .changed, at: 0.5)), 0, "同一次手势不再翻")
        XCTAssertEqual(pager.feed(sample(0, .ended, at: 0.6)), 0)
        XCTAssertEqual(pager.feed(sample(60, .none, momentum: true, at: 0.7)), 0, "惯性不翻")
        XCTAssertEqual(pager.feed(sample(-30, .began, at: 1.0)), -1, "新手势往回翻")
    }

    func testCooldownGivesAPause() {
        var pager = Pager()
        XCTAssertEqual(pager.feed(sample(30, .began, at: 0)), 1)
        XCTAssertEqual(pager.feed(sample(0, .ended, at: 0.05)), 0)
        XCTAssertEqual(pager.feed(sample(30, .began, at: 0.1)), 0, "冷却内的新手势不翻")
        XCTAssertEqual(pager.feed(sample(0, .ended, at: 0.15)), 0)
        XCTAssertEqual(pager.feed(sample(30, .began, at: 0.5)), 1, "冷却过了再翻")
    }

    func testMouseWheelNotchFlipsOneRowWithCooldown() {
        var pager = Pager()
        XCTAssertEqual(pager.feed(sample(1, .none, precise: false, at: 0)), 1)
        XCTAssertEqual(pager.feed(sample(1, .none, precise: false, at: 0.1)), 0, "快速连转不连跳")
        XCTAssertEqual(pager.feed(sample(-1, .none, precise: false, at: 0.5)), -1)
    }

    func testDirectionalDelta() {
        XCTAssertNil(Pager.directionalDelta(dx: 20, dy: 3, position: .bottom), "底部条：横向留给系统")
        XCTAssertEqual(Pager.directionalDelta(dx: 1, dy: 8, position: .bottom), 8)
        XCTAssertEqual(Pager.directionalDelta(dx: -9, dy: 1, position: .left), 9, "左条：往内侧（右）推 = 下一行")
        XCTAssertEqual(Pager.directionalDelta(dx: 9, dy: 1, position: .right), 9, "右条：往内侧（左）推 = 下一行")
        XCTAssertEqual(Pager.directionalDelta(dx: 0, dy: -2, position: .left), -2, "鼠标滚轮在侧边条也能用")
    }
}

@MainActor
final class SecondaryDockRowsModelTests: XCTestCase {

    func testStepMovesOneRowClampsAndReports() {
        let model = SecondaryDockRowsModel()
        let ids = [UUID(), UUID(), UUID()]
        var reported: [UUID?] = []
        model.onUserScrolled = { reported.append($0) }
        model.show(ids[0])
        XCTAssertFalse(model.step(-1, rowIDs: ids), "第一行再往回：不动")
        XCTAssertTrue(model.step(1, rowIDs: ids))
        XCTAssertEqual(model.currentRowID, ids[1])
        XCTAssertTrue(model.step(1, rowIDs: ids))
        XCTAssertFalse(model.step(1, rowIDs: ids), "最后一行不循环")
        XCTAssertEqual(model.currentRowID, ids[2])
        XCTAssertEqual(model.lastStepDirection, 1)
        XCTAssertTrue(model.step(-1, rowIDs: ids))
        XCTAssertEqual(model.lastStepDirection, -1)
        XCTAssertEqual(reported, [ids[1], ids[2], ids[1]])
        model.show(ids[0])
        XCTAssertEqual(reported.count, 3, "程序化定位不回报")
    }

    private func item(running: Bool, path: String?) -> SecondaryDockItem {
        SecondaryDockItem(id: "x", label: "X", icon: NSImage(size: NSSize(width: 8, height: 8)),
                          launchPath: path, isInstalled: true, isRunning: running)
    }

    func testBounceUntilLaunchedThenStops() async throws {
        let model = SecondaryDockRowsModel()
        model.bounceRise = .milliseconds(5)
        model.bounceFall = .milliseconds(5)
        var launched = false
        model.isLaunchFinished = { _ in launched }
        model.bounce(item(running: false, path: "/Applications/X.app"), height: 18)
        XCTAssertTrue(model.isBouncing("x"))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.isBouncing("x"), "还没起来：继续弹")
        launched = true
        for _ in 0..<100 where model.isBouncing("x") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isBouncing("x"))
        XCTAssertNil(model.bounceOffsets["x"])
    }

    func testRunningAppDoesNotBounce() {
        let model = SecondaryDockRowsModel()
        model.bounce(item(running: true, path: "/Applications/X.app"), height: 18)
        XCTAssertFalse(model.isBouncing("x"), "已在运行：点了只是切过去，不弹（同原生）")
        model.bounce(item(running: false, path: nil), height: 18)
        XCTAssertFalse(model.isBouncing("x"), "不可点的条目不弹")
    }
}

@MainActor
private final class RowsFakePresenter: SecondaryDockPresenting {
    private(set) var frames: [(frame: NSRect, animated: Bool)] = []
    private(set) var revealedStates: [Bool] = []
    var lastFrame: NSRect? { frames.last?.frame }
    var lastAnimated: Bool? { frames.last?.animated }

    func updateContent(_ content: SecondaryDockContentSnapshot, isVertical: Bool) {}
    func setFrame(_ frame: NSRect, animated: Bool) { frames.append((frame, animated)) }
    func orderFront() {}
    func orderOut() {}
    func pullToActiveSpace() {}
    func hideForSpaceTransition() {}
    func fadeBackFromSpaceTransition() {}
    var isOnActiveSpace: Bool { true }
    var currentAlpha: CGFloat { 1 }
    func setRevealed(_ revealed: Bool) { revealedStates.append(revealed) }
}

@MainActor
private final class RowsFaceProvider: DockFaceProviding {
    var face: DockFaceGeometry?
    func currentFace() -> DockFaceGeometry? { face }
    func currentScreenFrame() -> CGRect? { CGRect(x: 0, y: 0, width: 1920, height: 1200) }
}

@MainActor
private final class RowsBox {
    var snapshot: SecondaryDockContentSnapshot?
    var anchors: [UUID?] = []
    var mouse = CGPoint(x: -9999, y: -9999)
}

@MainActor
final class MultiRowSecondaryDockControllerTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1200)

    private var bottomFace: DockFaceGeometry {
        DockFaceGeometry(
            orientation: .bottom,
            screen: screen,
            visible: CGRect(x: 0, y: 53, width: 1920, height: 1147)
        )
    }

    private func item(_ index: Int) -> SecondaryDockItem {
        SecondaryDockItem(
            id: "app-\(index)",
            label: "App \(index)",
            icon: NSImage(size: NSSize(width: 16, height: 16)),
            launchPath: nil,
            isInstalled: true,
            isRunning: false
        )
    }

    /// 3 行（各 2 / 4 / 3 个图标）。
    private func threeRows() -> (SecondaryDockContentSnapshot, [UUID]) {
        let ids = [UUID(), UUID(), UUID()]
        let counts = [2, 4, 3]
        let rows = zip(ids, counts).map { id, count in
            SecondaryDockRow(barID: id, name: "", items: (0..<count).map(item))
        }
        var snapshot = SecondaryDockContentSnapshot(items: rows[0].items, iconSize: 36, position: .bottom)
        snapshot.barID = ids[0]
        snapshot.rows = rows
        return (snapshot, ids)
    }

    private func makeController(_ presenter: RowsFakePresenter, _ provider: RowsFaceProvider, _ box: RowsBox)
        -> SecondaryDockController
    {
        SecondaryDockController(deps: .init(
            presenter: presenter,
            faceProvider: provider,
            content: { [weak box] _ in box?.snapshot },
            isEnabled: { true },
            log: { _ in },
            tuckDebounce: .milliseconds(10),
            mouseLocation: { [weak box] in box?.mouse ?? .zero },
            onAnchorRowChanged: { [weak box] _, id in box?.anchors.append(id) }
        ))
    }

    private func show(_ controller: SecondaryDockController, _ provider: RowsFaceProvider) {
        provider.face = bottomFace
        controller.geometryTick()
        controller.spaceDidChange(FakeSpaceProvider.desktops(count: 1)[0])
    }

    private func expectedFrames() -> (revealed: CGRect, tucked: CGRect) {
        let size = SecondaryDockLayout.multiRowSize(maxItemCount: 4, rowCount: 3, iconSize: 36, isVertical: false)
        let placement = SecondaryDockLayout.placement(barSize: size, face: bottomFace)
        return (placement.revealed, placement.tucked)
    }

    func testRevealedAndTuckedAreBothOneRow() async throws {
        let presenter = RowsFakePresenter()
        let provider = RowsFaceProvider()
        let box = RowsBox()
        box.snapshot = threeRows().0
        let controller = makeController(presenter, provider, box)
        show(controller, provider)

        let expected = expectedFrames()
        XCTAssertEqual(presenter.lastFrame, expected.tucked, "收起：1 行厚、长度按最长那一行 + 指示点")

        controller.hoverChanged(true)
        XCTAssertEqual(presenter.lastFrame, expected.revealed, "显出也只有 1 行（没有抽屉）")
        XCTAssertEqual(presenter.lastFrame?.height, expected.tucked.height)
        XCTAssertEqual(presenter.revealedStates.last, true)

        controller.hoverChanged(false)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(presenter.lastFrame, expected.tucked)
        XCTAssertEqual(presenter.revealedStates.last, false)
    }

    func testRowScrollIsForwardedWithTheSpace() {
        let presenter = RowsFakePresenter()
        let provider = RowsFaceProvider()
        let box = RowsBox()
        let (snapshot, ids) = threeRows()
        box.snapshot = snapshot
        let controller = makeController(presenter, provider, box)
        show(controller, provider)

        controller.rowScrolled(ids[2])
        XCTAssertEqual(box.anchors, [ids[2]])
    }
}

import AppKit
import XCTest
@testable import MultiDock

// MARK: - 多行次级条（2026-10-23 用户规格）
//
// 每条屏幕边一扇窗口，同桌面同边的栏各占一行（最多 3 行）：
// 收起（半露在原生 Dock 后方）恒为 1 行；hover 显出 = 用户拖 handle 定的行数；
// 拖拽中厚度跟手、松手吸附到整行并回存；拖拽期间不收回。

@MainActor
final class MultiRowSecondaryDockLayoutTests: XCTestCase {

    func testThicknessGrowsByOneRowPitchPerRow() {
        XCTAssertEqual(SecondaryDockLayout.thickness(rows: 1, iconSize: 36), 56, "1 行 = 原来的条厚（icon + 20）")
        XCTAssertEqual(SecondaryDockLayout.thickness(rows: 2, iconSize: 36), 102)
        XCTAssertEqual(SecondaryDockLayout.thickness(rows: 3, iconSize: 36), 148)
        XCTAssertEqual(
            SecondaryDockLayout.multiRowSize(maxItemCount: 4, thickness: 56, iconSize: 36, isVertical: false),
            SecondaryDockLayout.barSize(itemCount: 4, iconSize: 36, isVertical: false),
            "1 行时与旧的单行尺寸完全一致"
        )
    }

    func testSnappedRowsRoundsToTheNearestRowAndClamps() {
        XCTAssertEqual(SecondaryDockLayout.snappedRows(thickness: 56, iconSize: 36, maxRows: 3), 1)
        XCTAssertEqual(SecondaryDockLayout.snappedRows(thickness: 80, iconSize: 36, maxRows: 3), 2, "过半行进位")
        XCTAssertEqual(SecondaryDockLayout.snappedRows(thickness: 78, iconSize: 36, maxRows: 3), 1, "不到半行回落")
        XCTAssertEqual(SecondaryDockLayout.snappedRows(thickness: 400, iconSize: 36, maxRows: 2), 2, "不超过可用行数")
        XCTAssertEqual(SecondaryDockLayout.snappedRows(thickness: 10, iconSize: 36, maxRows: 3), 1)
    }

    func testResizeKeepsTheDockSideAnchored() {
        let frame = CGRect(x: 100, y: 60, width: 300, height: 56)
        XCTAssertEqual(
            SecondaryDockLayout.resized(frame, toThickness: 102, position: .bottom),
            CGRect(x: 100, y: 60, width: 300, height: 102),
            "底部：下沿不动往上长"
        )
        let side = CGRect(x: 1800, y: 100, width: 56, height: 300)
        XCTAssertEqual(
            SecondaryDockLayout.resized(side, toThickness: 102, position: .right),
            CGRect(x: 1754, y: 100, width: 102, height: 300),
            "右侧：右沿不动往左长"
        )
        XCTAssertEqual(
            SecondaryDockLayout.resized(CGRect(x: 0, y: 100, width: 56, height: 300), toThickness: 102, position: .left),
            CGRect(x: 0, y: 100, width: 102, height: 300),
            "左侧：左沿不动往右长"
        )
        XCTAssertEqual(SecondaryDockLayout.thickness(dragging: CGPoint(x: 0, y: 160), anchoredFrame: frame, position: .bottom), 100)
        XCTAssertEqual(SecondaryDockLayout.thickness(dragging: CGPoint(x: 1700, y: 0), anchoredFrame: side, position: .right), 156)
    }

    func testSnapshotClampsRowsAndAnchor() {
        let ids = [UUID(), UUID()]
        var snapshot = SecondaryDockContentSnapshot(items: [], iconSize: 36)
        snapshot.rows = ids.map { SecondaryDockRow(barID: $0, name: "", items: []) }
        snapshot.visibleRows = 3
        snapshot.anchorBarID = UUID()
        XCTAssertEqual(snapshot.effectiveVisibleRows, 2, "行数不超过栏数")
        XCTAssertEqual(snapshot.effectiveAnchorBarID, ids[0], "锚定行不在：回到第一行")

        let single = SecondaryDockContentSnapshot(items: [], iconSize: 36)
        XCTAssertEqual(single.displayRows.count, 1, "旧口径：没有 rows 就把 items 当唯一一行")
        XCTAssertEqual(single.effectiveVisibleRows, 1)
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
    var committedRows: [Int] = []
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

    /// 3 行（各 2 / 4 / 3 个图标），展开 `visibleRows` 行。
    private func threeRows(visibleRows: Int) -> (SecondaryDockContentSnapshot, [UUID]) {
        let ids = [UUID(), UUID(), UUID()]
        let counts = [2, 4, 3]
        let rows = zip(ids, counts).map { id, count in
            SecondaryDockRow(barID: id, name: "", items: (0..<count).map(item))
        }
        var snapshot = SecondaryDockContentSnapshot(items: rows[0].items, iconSize: 36, position: .bottom)
        snapshot.barID = ids[0]
        snapshot.rows = rows
        snapshot.visibleRows = visibleRows
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
            onVisibleRowsCommitted: { [weak box] _, rows in box?.committedRows.append(rows) },
            onAnchorRowChanged: { [weak box] _, id in box?.anchors.append(id) }
        ))
    }

    private func show(_ controller: SecondaryDockController, _ provider: RowsFaceProvider) {
        provider.face = bottomFace
        controller.geometryTick()
        controller.spaceDidChange(FakeSpaceProvider.desktops(count: 1)[0])
    }

    private func expectedFrames(rows: Int) -> (revealed: CGRect, tucked: CGRect) {
        let revealed = SecondaryDockLayout.placement(
            barSize: SecondaryDockLayout.multiRowSize(
                maxItemCount: 4,
                thickness: SecondaryDockLayout.thickness(rows: rows, iconSize: 36),
                iconSize: 36,
                isVertical: false
            ),
            face: bottomFace
        ).revealed
        let tucked = SecondaryDockLayout.placement(
            barSize: SecondaryDockLayout.barSize(itemCount: 4, iconSize: 36, isVertical: false),
            face: bottomFace
        ).tucked
        return (revealed, tucked)
    }

    func testTuckedIsOneRowAndRevealedIsTheUsersRowCount() async throws {
        let presenter = RowsFakePresenter()
        let provider = RowsFaceProvider()
        let box = RowsBox()
        box.snapshot = threeRows(visibleRows: 2).0
        let controller = makeController(presenter, provider, box)
        show(controller, provider)

        let expected = expectedFrames(rows: 2)
        XCTAssertEqual(presenter.lastFrame, expected.tucked, "收起：1 行厚、长度按最长那一行")

        controller.hoverChanged(true)
        XCTAssertEqual(presenter.lastFrame, expected.revealed, "显出：展开到用户拖成的 2 行")
        XCTAssertEqual(presenter.lastFrame?.minY, bottomFace.visible.minY + SecondaryDockLayout.faceGap,
                       "显出锚定 Dock 内侧面，往屏幕内长")
        XCTAssertEqual(presenter.revealedStates.last, true)

        controller.hoverChanged(false)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(presenter.lastFrame, expected.tucked)
        XCTAssertEqual(presenter.revealedStates.last, false, "收起时告诉窗口（handle 隐藏、滚回锚定行）")
    }

    func testDragFollowsTheCursorThenSnapsAndCommits() {
        let presenter = RowsFakePresenter()
        let provider = RowsFaceProvider()
        let box = RowsBox()
        box.snapshot = threeRows(visibleRows: 1).0
        let controller = makeController(presenter, provider, box)
        show(controller, provider)
        controller.hoverChanged(true)
        let start = expectedFrames(rows: 1).revealed

        controller.resize(.began)
        XCTAssertTrue(controller.isResizing)
        controller.resize(.changed(CGPoint(x: start.midX, y: start.minY + 90)))
        XCTAssertEqual(presenter.lastFrame?.height, 90, "拖拽中厚度跟手")
        XCTAssertEqual(presenter.lastFrame?.minY, start.minY, "锚定侧不动")
        XCTAssertEqual(presenter.lastAnimated, false)

        controller.resize(.changed(CGPoint(x: start.midX, y: start.minY + 999)))
        XCTAssertEqual(presenter.lastFrame?.height, SecondaryDockLayout.thickness(rows: 3, iconSize: 36), "最多 3 行")

        controller.geometryTick()
        controller.refresh()
        XCTAssertEqual(presenter.lastFrame?.height, SecondaryDockLayout.thickness(rows: 3, iconSize: 36),
                       "拖拽中轮询重摆不把高度打回已存的行数")

        controller.resize(.changed(CGPoint(x: start.midX, y: start.minY + 110)))
        box.mouse = CGPoint(x: start.midX, y: start.minY + 20)
        controller.resize(.ended)
        XCTAssertFalse(controller.isResizing)
        XCTAssertEqual(box.committedRows, [2], "松手吸附到最近的整行（110 → 2 行）并回存")
        XCTAssertEqual(presenter.lastFrame?.height, SecondaryDockLayout.thickness(rows: 2, iconSize: 36))
        XCTAssertEqual(presenter.lastAnimated, true, "吸附走动画")
    }

    func testDraggingOutsideTheBarDoesNotTuck() async throws {
        let presenter = RowsFakePresenter()
        let provider = RowsFaceProvider()
        let box = RowsBox()
        box.snapshot = threeRows(visibleRows: 1).0
        let controller = makeController(presenter, provider, box)
        show(controller, provider)
        controller.hoverChanged(true)
        let revealed = expectedFrames(rows: 1).revealed

        controller.resize(.began)
        controller.resize(.changed(CGPoint(x: revealed.midX, y: revealed.minY + 130)))
        controller.hoverChanged(false)   // 光标拖出了窗口
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(presenter.lastFrame?.height, 130, "拖拽期间不收回")
        XCTAssertEqual(presenter.revealedStates.last, true)
    }

    func testSingleRowEdgeIgnoresResize() {
        let presenter = RowsFakePresenter()
        let provider = RowsFaceProvider()
        let box = RowsBox()
        box.snapshot = SecondaryDockContentSnapshot(items: (0..<3).map(item), iconSize: 36, position: .bottom)
        let controller = makeController(presenter, provider, box)
        show(controller, provider)
        controller.hoverChanged(true)
        let before = presenter.frames.count

        controller.resize(.began)
        controller.resize(.changed(CGPoint(x: 900, y: 400)))
        controller.resize(.ended)
        XCTAssertFalse(controller.isResizing)
        XCTAssertEqual(presenter.frames.count, before, "只有一行：没有 handle、拖拽无效")
        XCTAssertEqual(box.committedRows, [])
    }

    func testRowScrollIsForwardedWithTheSpace() {
        let presenter = RowsFakePresenter()
        let provider = RowsFaceProvider()
        let box = RowsBox()
        let (snapshot, ids) = threeRows(visibleRows: 1)
        box.snapshot = snapshot
        let controller = makeController(presenter, provider, box)
        show(controller, provider)

        controller.rowScrolled(ids[2])
        XCTAssertEqual(box.anchors, [ids[2]])
    }
}

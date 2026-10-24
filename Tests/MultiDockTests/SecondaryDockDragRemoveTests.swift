import AppKit
import XCTest
@testable import MultiDock

/// 拖出移除（2026-10-24 用户规格：把 App 拖出侧边坞一定距离松手 = 移除）。
@MainActor
final class SecondaryDockDragRemoveTests: XCTestCase {

    func testRemovalDistanceScalesWithIconButHasFloor() {
        XCTAssertEqual(SecondaryDockWindow.removalDistance(iconSize: 28), 48)
        XCTAssertEqual(SecondaryDockWindow.removalDistance(iconSize: 36), 54)
        XCTAssertEqual(SecondaryDockWindow.removalDistance(iconSize: 48), 72)
    }

    func testCursorInsideOrNearBarDoesNotRemove() {
        let bar = CGRect(x: 100, y: 0, width: 400, height: 50)
        XCTAssertFalse(SecondaryDockWindow.isOutForRemoval(cursor: CGPoint(x: 300, y: 25), barRect: bar, threshold: 54))
        XCTAssertFalse(SecondaryDockWindow.isOutForRemoval(cursor: CGPoint(x: 300, y: 100), barRect: bar, threshold: 54))
    }

    func testCursorFarEnoughInAnyDirectionRemoves() {
        let bar = CGRect(x: 100, y: 0, width: 400, height: 50)
        // 往屏幕内侧（上方）
        XCTAssertTrue(SecondaryDockWindow.isOutForRemoval(cursor: CGPoint(x: 300, y: 104), barRect: bar, threshold: 54))
        // 从条端横着拖出去
        XCTAssertTrue(SecondaryDockWindow.isOutForRemoval(cursor: CGPoint(x: 560, y: 25), barRect: bar, threshold: 54))
        // 斜角：按到底板角的直线距离算
        XCTAssertFalse(SecondaryDockWindow.isOutForRemoval(cursor: CGPoint(x: 530, y: 80), barRect: bar, threshold: 54))
        XCTAssertTrue(SecondaryDockWindow.isOutForRemoval(cursor: CGPoint(x: 545, y: 95), barRect: bar, threshold: 54))
    }

    func testPlaceholderRowFallsBackToContentBar() {
        let bar = UUID()
        XCTAssertEqual(
            SecondaryDockWindow.resolvedBarID(rowID: SecondaryDockContentSnapshot.placeholderRowID, fallback: bar), bar
        )
        XCTAssertEqual(SecondaryDockWindow.resolvedBarID(rowID: nil, fallback: bar), bar)
        let row = UUID()
        XCTAssertEqual(SecondaryDockWindow.resolvedBarID(rowID: row, fallback: bar), row)
    }

    func testDraggingStateTracksItem() {
        let model = SecondaryDockRowsModel()
        let item = SecondaryDockItem(
            id: "com.example.app", label: "Example", icon: NSImage(), launchPath: nil, isInstalled: true, isRunning: false
        )
        var ended: (String, UUID?)?
        let row = UUID()
        model.onItemDragEnded = { item, rowID in ended = (item.id, rowID) }
        model.itemDragChanged(item, rowID: row)
        XCTAssertEqual(model.draggingItemID, "com.example.app")
        model.itemDragEnded(item, rowID: row)
        XCTAssertNil(model.draggingItemID)
        XCTAssertEqual(ended?.0, "com.example.app")
        XCTAssertEqual(ended?.1, row)
    }
}

/// 2026-10-24 Bug：光标停在屏幕最底部，条显出后离开屏幕边 6 pt，光标落进缝里 → 收 → 显 → 收……来回弹。
@MainActor
final class SecondaryDockHoldZoneTests: XCTestCase {
    func testGapBetweenBarAndScreenEdgeKeepsBarRevealed() {
        let revealed = CGRect(x: 100, y: 6, width: 300, height: 56)
        let hold = SecondaryDockController.holdRect(revealed: revealed, position: .bottom)
        XCTAssertTrue(hold.contains(CGPoint(x: 200, y: 0)), "屏幕最底一行像素")
        XCTAssertTrue(hold.contains(CGPoint(x: 200, y: 3)))
        XCTAssertFalse(hold.contains(CGPoint(x: 50, y: 3)), "条两端以外不算")
        XCTAssertFalse(hold.contains(CGPoint(x: 200, y: 70)), "条上方不算")

        let left = SecondaryDockController.holdRect(revealed: CGRect(x: 6, y: 100, width: 56, height: 300), position: .left)
        XCTAssertTrue(left.contains(CGPoint(x: 0, y: 200)))
        let right = SecondaryDockController.holdRect(revealed: CGRect(x: 1858, y: 100, width: 56, height: 300), position: .right)
        XCTAssertTrue(right.contains(CGPoint(x: 1919, y: 200)))
    }
}

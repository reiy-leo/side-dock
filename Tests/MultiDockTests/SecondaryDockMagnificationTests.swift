import AppKit
import XCTest
@testable import MultiDock

/// 悬停放大（2026-10-23 用户规格：跟随系统放大开关与尺寸）的纯计算。
@MainActor
final class SecondaryDockMagnificationTests: XCTestCase {

    func testMagnifiedSizeFollowsSystemSwitch() {
        XCTAssertNil(SecondaryDockMagnification.magnifiedSize(enabled: false, largeSize: 96, iconSize: 36))
        XCTAssertEqual(SecondaryDockMagnification.magnifiedSize(enabled: true, largeSize: 96, iconSize: 36), 96)
        // 读不到 largesize → macOS 缺省 128。
        XCTAssertEqual(SecondaryDockMagnification.magnifiedSize(enabled: true, largeSize: nil, iconSize: 36), 128)
        // 放大尺寸不比图标大 → 等于不放大。
        XCTAssertNil(SecondaryDockMagnification.magnifiedSize(enabled: true, largeSize: 30, iconSize: 36))
        XCTAssertEqual(SecondaryDockMagnification.headroom(iconSize: 36, magnifiedSize: 96), 60)
        XCTAssertEqual(SecondaryDockMagnification.headroom(iconSize: 36, magnifiedSize: nil), 0)
    }

    func testNoCursorMeansIdentity() {
        let effects = SecondaryDockMagnification.effects(
            count: 5, slotLength: 40, spacing: 2, iconSize: 36, magnifiedSize: 96, cursor: nil
        )
        XCTAssertEqual(effects.map(\.scale), [1, 1, 1, 1, 1])
        XCTAssertEqual(effects.map(\.offset), [0, 0, 0, 0, 0])
    }

    func testIconUnderCursorIsLargestAndStaysPut() {
        // 第 3 个槽位（index 2）中心 = 2 × 42 + 20 = 104。
        let effects = SecondaryDockMagnification.effects(
            count: 7, slotLength: 40, spacing: 2, iconSize: 36, magnifiedSize: 96, cursor: 104
        )
        XCTAssertEqual(effects[2].scale, 96.0 / 36.0, accuracy: 0.0001)
        XCTAssertEqual(effects[2].offset, 0, accuracy: 0.0001, "光标下的图标不被推走")
        XCTAssertLessThan(effects[1].scale, effects[2].scale)
        XCTAssertEqual(effects[1].scale, effects[3].scale, accuracy: 0.0001, "两侧对称衰减")
        XCTAssertLessThan(effects[1].offset, 0, "左邻往左让")
        XCTAssertGreaterThan(effects[3].offset, 0, "右邻往右让")
        XCTAssertEqual(effects[1].offset, -effects[3].offset, accuracy: 0.0001)
    }

    func testFarIconsUnscaled() {
        let effects = SecondaryDockMagnification.effects(
            count: 12, slotLength: 40, spacing: 2, iconSize: 36, magnifiedSize: 72, cursor: 20
        )
        XCTAssertEqual(effects[11].scale, 1)
        XCTAssertEqual(effects[0].offset, 0, accuracy: 0.0001)
    }

    func testWindowFrameExtendsTowardScreenInterior() {
        let bar = NSRect(x: 100, y: 10, width: 200, height: 56)
        XCTAssertEqual(
            SecondaryDockWindow.windowFrame(forBar: bar, headroom: 60, position: .bottom),
            NSRect(x: 100, y: 10, width: 200, height: 116)
        )
        let side = NSRect(x: 1784, y: 504, width: 56, height: 192)
        XCTAssertEqual(
            SecondaryDockWindow.windowFrame(forBar: side, headroom: 60, position: .right),
            NSRect(x: 1724, y: 504, width: 116, height: 192)
        )
        XCTAssertEqual(
            SecondaryDockWindow.windowFrame(forBar: side, headroom: 60, position: .left),
            NSRect(x: 1784, y: 504, width: 116, height: 192)
        )
        XCTAssertEqual(SecondaryDockWindow.windowFrame(forBar: bar, headroom: 0, position: .bottom), bar)
        XCTAssertEqual(
            SecondaryDockWindow.barRectInWindow(barSize: side.size, headroom: 60, position: .right),
            NSRect(x: 60, y: 0, width: 56, height: 192)
        )
    }

    func testMultiRowDisablesMagnification() {
        var snapshot = SecondaryDockContentSnapshot(items: [], iconSize: 36)
        snapshot.magnifiedSize = 96
        XCTAssertEqual(snapshot.effectiveMagnifiedSize, 96)
        snapshot.rows = [
            SecondaryDockRow(barID: UUID(), name: "A", items: []),
            SecondaryDockRow(barID: UUID(), name: "B", items: []),
        ]
        XCTAssertNil(snapshot.effectiveMagnifiedSize)
    }
}

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
        XCTAssertEqual(SecondaryDockMagnification.headroom(iconSize: 36, magnifiedSize: nil), 18, "不放大也给弹跳留空间")
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

    func testEndRoomCoversDisplacementAtBarEnds() {
        // 真机（2026-10-23）：两端图标放大时被窗口边截断。光标停在第一个图标上时，
        // 末端那一侧的累计让位 + 图标半边溢出必须落在 endRoom 里。
        let icon: CGFloat = 36
        for magnified in [CGFloat(64), 96, 128] {
            for isVertical in [false, true] {
                let slot = SecondaryDockMagnification.slotLength(iconSize: icon, isVertical: isVertical)
                let pitch = slot + SecondaryDockMagnification.slotSpacing
                let room = SecondaryDockMagnification.endRoom(iconSize: icon, magnifiedSize: magnified, pitch: pitch)
                let count = 20
                let length = CGFloat(count) * pitch - SecondaryDockMagnification.slotSpacing
                for cursor in stride(from: CGFloat(0), through: length, by: 3) {
                    let effects = SecondaryDockMagnification.effects(
                        count: count, slotLength: slot, spacing: SecondaryDockMagnification.slotSpacing,
                        iconSize: icon, magnifiedSize: magnified, cursor: cursor
                    )
                    for (index, effect) in effects.enumerated() {
                        let center = CGFloat(index) * pitch + slot / 2 + effect.offset
                        let half = icon * effect.scale / 2
                        XCTAssertGreaterThanOrEqual(center - half, -room, "左/上端越界 m=\(magnified)")
                        XCTAssertLessThanOrEqual(center + half, length + room, "右/下端越界 m=\(magnified)")
                    }
                }
            }
        }
    }

    func testWindowFrameAddsEndRoomAlongBar() {
        let bar = NSRect(x: 100, y: 10, width: 200, height: 56)
        XCTAssertEqual(
            SecondaryDockWindow.windowFrame(forBar: bar, headroom: 60, endRoom: 30, position: .bottom),
            NSRect(x: 70, y: 10, width: 260, height: 116)
        )
        let side = NSRect(x: 1784, y: 504, width: 56, height: 192)
        XCTAssertEqual(
            SecondaryDockWindow.windowFrame(forBar: side, headroom: 60, endRoom: 30, position: .right),
            NSRect(x: 1724, y: 474, width: 116, height: 252)
        )
        XCTAssertEqual(
            SecondaryDockWindow.barRectInWindow(barSize: side.size, headroom: 60, endRoom: 30, position: .right),
            NSRect(x: 60, y: 30, width: 56, height: 192)
        )
    }

    func testMultiRowKeepsMagnification() {
        // 2026-10-23 用户规格：多行条也放大（同日改为只显示一行，放大的就是这一行）。
        var snapshot = SecondaryDockContentSnapshot(items: [], iconSize: 36)
        snapshot.magnifiedSize = 96
        snapshot.rows = [
            SecondaryDockRow(barID: UUID(), name: "A", items: []),
            SecondaryDockRow(barID: UUID(), name: "B", items: []),
        ]
        XCTAssertEqual(snapshot.effectiveMagnifiedSize, 96)
    }


    func testExtentsAndBarOverflowGrowWithMagnification() {
        let slot = SecondaryDockMagnification.slotLength(iconSize: 36, isVertical: false)
        let spacing = SecondaryDockMagnification.slotSpacing
        let flat = SecondaryDockMagnification.effects(
            count: 5, slotLength: slot, spacing: spacing, iconSize: 36, magnifiedSize: 96, cursor: nil
        )
        let flatRange = SecondaryDockMagnification.extents(effects: flat, slotLength: slot, spacing: spacing, iconSize: 36)
        XCTAssertEqual(flatRange.start, (slot - 36) / 2, accuracy: 0.01)
        // 光标停在第一个图标上：左端图标放大后越过槽位起点，右侧整体让位往后推。
        let hot = SecondaryDockMagnification.effects(
            count: 5, slotLength: slot, spacing: spacing, iconSize: 36, magnifiedSize: 96, cursor: slot / 2
        )
        let hotRange = SecondaryDockMagnification.extents(effects: hot, slotLength: slot, spacing: spacing, iconSize: 36)
        XCTAssertLessThan(hotRange.start, flatRange.start)
        XCTAssertGreaterThan(hotRange.end, flatRange.end)

        let barLength: CGFloat = 220
        XCTAssertEqual(SecondaryDockMagnification.barOverflow(start: 20, end: 200, barLength: barLength), .zero,
                       "图标都在条里：不伸")
        let overflow = SecondaryDockMagnification.barOverflow(start: -10, end: 230, barLength: barLength)
        XCTAssertEqual(overflow.leading, 16, "超出左端 10 + 留边 6")
        XCTAssertEqual(overflow.trailing, 16)
    }

    func testContainerRectGrowsAlongTheBarWithinEndRoom() {
        let size = NSSize(width: 200, height: 56)
        let rect = SecondaryDockWindow.containerRect(
            barSize: size, headroom: 60, endRoom: 30,
            overflow: SecondaryDockBarOverflow(leading: 10, trailing: 50), position: .bottom
        )
        XCTAssertEqual(rect, NSRect(x: 20, y: 0, width: 240, height: 56), "左伸 10，右伸钳到 endRoom 30")
        let side = SecondaryDockWindow.containerRect(
            barSize: NSSize(width: 56, height: 200), headroom: 60, endRoom: 30,
            overflow: SecondaryDockBarOverflow(leading: 10, trailing: 5), position: .left
        )
        XCTAssertEqual(side, NSRect(x: 0, y: 25, width: 56, height: 215), "竖条：上端往 maxY、下端往 minY")
    }
}


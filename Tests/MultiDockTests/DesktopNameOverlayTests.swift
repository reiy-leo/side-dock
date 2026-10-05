import XCTest
@testable import MultiDock

/// `DesktopNameOverlayWindow.frameOrigin` 的纯几何：三档位置在可见区里的落点。
/// 不碰真窗口 —— 窗口属性（跨空间、不抢焦点、不挡点击）只能真机验，
/// 见 `scripts/check-toast-window.sh` 与 A11 手测项。
@MainActor
final class DesktopNameOverlayTests: XCTestCase {

    /// 假想的显示器可见区（AppKit 坐标，原点左下）。数值随手编，够验几何就行。
    private let visibleFrame = NSRect(x: 0, y: 25, width: 1440, height: 875)

    private let size = NSSize(width: 400, height: 120)

    func testTopSitsBelowVisibleTopAndCentered() {
        let origin = DesktopNameOverlayWindow.frameOrigin(for: .top, visibleFrame: visibleFrame, size: size)
        XCTAssertEqual(origin.x, (1440 - 400) / 2, accuracy: 0.5, "水平恒居中")
        XCTAssertEqual(origin.y, 25 + 875 - 80 - 120, accuracy: 0.5, "顶部档位：窗口顶边距可见区顶 80pt（旧版 toast 同款，天然避开菜单栏）")
    }

    func testMiddleCentersVertically() {
        let origin = DesktopNameOverlayWindow.frameOrigin(for: .middle, visibleFrame: visibleFrame, size: size)
        XCTAssertEqual(origin.y, 25 + (875 - 120) / 2, accuracy: 0.5, "中部档位：可见区垂直居中")
        XCTAssertEqual(origin.x, (1440 - 400) / 2, accuracy: 0.5)
    }

    func testBottomClearsVisibleBottom() {
        let origin = DesktopNameOverlayWindow.frameOrigin(for: .bottom, visibleFrame: visibleFrame, size: size)
        XCTAssertEqual(origin.y, 25 + 64, accuracy: 0.5, "底部档位：窗口底边距可见区底 64pt（避开次级条薄边）")
    }

    func testPlacementDecodesAllCasesAndRoundTrips() throws {
        // 三个档位都要能从 JSON 原样回来（rawValue 稳定 = config.json 兼容）。
        for placement in DesktopNamePlacement.allCases {
            let data = try JSONEncoder().encode(placement)
            let restored = try JSONDecoder().decode(DesktopNamePlacement.self, from: data)
            XCTAssertEqual(restored, placement)
        }
    }
}

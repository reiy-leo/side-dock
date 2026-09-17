import XCTest
@testable import MultiDock

/// SkyLight 空间字典的解析规则。
///
/// **为什么单独测这个**：`type != 0`（全屏 App 空间、系统空间）必须被过滤掉，否则每次进全屏
/// 都会被当成"切了桌面"、白重启一次 Dock。但全屏空间不是随时都有 —— 本机就没有，
/// 等真机出现再回归不可靠，所以把解析抽成纯函数在这里用合成数据钉死。
final class SpaceParsingTests: XCTestCase {

    private func space(
        uuid: String = UUID().uuidString,
        id64: UInt64,
        type: Int = 0
    ) -> [String: Any] {
        ["uuid": uuid, "id64": NSNumber(value: id64), "type": NSNumber(value: type)]
    }

    private func display(_ uuid: String, spaces: [[String: Any]]) -> [String: Any] {
        ["Display Identifier": uuid, "Spaces": spaces]
    }

    // MARK: - 全屏过滤

    func testFullScreenSpacesAreFilteredOut() {
        let spaces = SkyLightSpaceProvider.userDesktops(fromDisplays: [
            display("D1", spaces: [
                space(uuid: "u1", id64: 1, type: 0),
                space(uuid: "u2", id64: 2, type: 4),   // 全屏 App
                space(uuid: "u3", id64: 3, type: 0),
            ])
        ])

        XCTAssertEqual(spaces.map(\.spaceUUID), ["u1", "u3"])
        XCTAssertTrue(spaces.allSatisfy { $0.type == 0 })
    }

    /// 全屏空间不能占号：它夹在两个用户桌面中间时，第三个桌面的序号必须是 2 而不是 3。
    func testFullScreenSpaceDoesNotConsumeAnOrdinal() {
        let spaces = SkyLightSpaceProvider.userDesktops(fromDisplays: [
            display("D1", spaces: [
                space(uuid: "u1", id64: 1, type: 0),
                space(uuid: "u2", id64: 2, type: 4),
                space(uuid: "u3", id64: 3, type: 0),
            ])
        ])

        XCTAssertEqual(spaces.map(\.ordinal), [1, 2])
        XCTAssertEqual(spaces.last?.displayName, "桌面 2")
    }

    /// 只有全屏空间时，一个用户桌面都该没有 —— 而不是回退成"当成桌面"。
    func testOnlyFullScreenSpacesYieldsNoDesktops() {
        let spaces = SkyLightSpaceProvider.userDesktops(fromDisplays: [
            display("D1", spaces: [
                space(uuid: "u1", id64: 1, type: 4),
                space(uuid: "u2", id64: 2, type: 4),
            ])
        ])

        XCTAssertTrue(spaces.isEmpty)
    }

    // MARK: - 多显示器

    /// 多显示器下每个显示器各自从 1 开始编号，且 `id` 必须带上 displayUUID，
    /// 否则两台显示器上同序号的桌面会互相覆盖。
    func testEachDisplayNumbersItsOwnDesktopsFromOne() {
        let spaces = SkyLightSpaceProvider.userDesktops(fromDisplays: [
            display("D1", spaces: [space(uuid: "a1", id64: 11), space(uuid: "a2", id64: 12)]),
            display("D2", spaces: [space(uuid: "b1", id64: 21), space(uuid: "b2", id64: 22)]),
        ])

        XCTAssertEqual(spaces.map(\.ordinal), [1, 2, 1, 2])
        XCTAssertEqual(Set(spaces.map(\.id)).count, 4, "id 必须唯一，否则跨显示器会串")
        XCTAssertTrue(spaces.allSatisfy { $0.id.hasPrefix($0.displayUUID) })
    }

    /// 插拔外接屏后同一个 spaceUUID 可能出现在别的显示器上 —— 映射键变了，不能当成同一个桌面。
    func testSameSpaceUUIDOnAnotherDisplayIsADifferentDesktop() {
        let same = [
            display("D1", spaces: [space(uuid: "same", id64: 7)]),
            display("D2", spaces: [space(uuid: "same", id64: 7)]),
        ]

        let spaces = SkyLightSpaceProvider.userDesktops(fromDisplays: same)
        XCTAssertEqual(spaces.count, 2)
        XCTAssertNotEqual(spaces[0].id, spaces[1].id)
    }

    // MARK: - 坏数据

    func testDisplayWithoutIdentifierIsSkipped() {
        let spaces = SkyLightSpaceProvider.userDesktops(fromDisplays: [
            ["Spaces": [space(uuid: "u1", id64: 1)]],
            display("D2", spaces: [space(uuid: "u2", id64: 2)]),
        ])

        XCTAssertEqual(spaces.map(\.spaceUUID), ["u2"])
    }

    func testSpacesWithMissingFieldsAreSkipped() {
        let spaces = SkyLightSpaceProvider.userDesktops(fromDisplays: [
            display("D1", spaces: [
                ["type": NSNumber(value: 0)],                                  // 缺 uuid / id64
                ["uuid": "u2", "type": NSNumber(value: 0)],                     // 缺 id64
                ["uuid": "u3", "id64": NSNumber(value: 3)],                     // 缺 type
                ["uuid": "u4", "id64": NSNumber(value: 4), "type": NSNumber(value: 0)],
            ])
        ])

        XCTAssertEqual(spaces.map(\.spaceUUID), ["u4"])
    }

    /// 空输入（私有 API 返回 nil 的等价情形）不能崩。
    func testEmptyInputYieldsNoDesktops() {
        XCTAssertTrue(SkyLightSpaceProvider.userDesktops(fromDisplays: []).isEmpty)
    }
}

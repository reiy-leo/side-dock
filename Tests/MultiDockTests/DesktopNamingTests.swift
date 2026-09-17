import XCTest
@testable import MultiDock

/// 桌面命名的归一化与解析。对应 `docs/PLAN.md` §3.10 的命名规格。
final class DesktopNamingTests: XCTestCase {

    private func space(ordinal: Int = 1, display: String = "DISPLAY-A") -> DesktopSpace {
        DesktopSpace(
            displayUUID: display,
            spaceUUID: String(format: "UUID-%02d", ordinal),
            id64: UInt64(ordinal),
            type: 0,
            ordinal: ordinal
        )
    }

    private func binding(
        for space: DesktopSpace,
        name: String? = nil,
        override: DockConfig? = nil
    ) -> DesktopBinding {
        DesktopBinding(
            displayUUID: space.displayUUID,
            spaceUUID: space.spaceUUID,
            customName: name,
            override: override
        )
    }

    // MARK: - 归一化

    func testEmptyAndBlankBecomeNoName() {
        XCTAssertEqual(DesktopNaming.normalize(""), "")
        XCTAssertEqual(DesktopNaming.normalize("   "), "")
        XCTAssertEqual(DesktopNaming.normalize("\n\t "), "")
        XCTAssertNil(DesktopNaming.normalizedOrNil(nil))
        XCTAssertNil(DesktopNaming.normalizedOrNil("   "), "纯空白等于没起名")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(DesktopNaming.normalize("  工作  "), "工作")
    }

    func testNewlinesAreFlattenedInsteadOfKept() {
        XCTAssertEqual(DesktopNaming.normalize("工作\n桌面"), "工作 桌面")
        XCTAssertEqual(DesktopNaming.normalize("工作\r\n桌面"), "工作 桌面", "CRLF 不该折成两个空格")
        XCTAssertEqual(DesktopNaming.normalize("工作\r桌面"), "工作 桌面")
    }

    func testExactlyMaxLengthIsUntouched() {
        let ten = "一二三四五六七八九十"
        XCTAssertEqual(ten.count, DesktopNaming.maxLength)
        XCTAssertEqual(DesktopNaming.normalize(ten), ten)
    }

    func testTruncatesByGraphemeClusterNotBytes() {
        // 11 个中文：按字节或 UTF-16 码元都会算错，按字素簇正好截到 10。
        let eleven = "一二三四五六七八九十甲"
        XCTAssertEqual(eleven.count, 11)
        XCTAssertEqual(DesktopNaming.normalize(eleven), "一二三四五六七八九十")
        // 混合内容同样按字素簇算：空格也是 1 个字符。
        // "桌面 A1B2C3D4E5F6" 共 15 个字符（桌 面 空格 A 1 B 2 C 3 D 4 E 5 F 6）→ 截到 "桌面 A1B2C3D"。
        XCTAssertEqual(DesktopNaming.normalize("桌面 A1B2C3D4E5F6"), "桌面 A1B2C3D")
    }

    func testEmojiCountsAsOneCharacter() {
        // 家庭 emoji 由多个码点 + ZWJ 组成，但只是 1 个字素簇。
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(DesktopNaming.normalize(String(repeating: family, count: 12)),
                       String(repeating: family, count: DesktopNaming.maxLength))

        // 带肤色修饰符的 emoji 同理。
        let thumbs = "👍🏽"
        XCTAssertEqual(thumbs.count, 1)
        XCTAssertEqual(DesktopNaming.normalize(String(repeating: thumbs, count: 11)),
                       String(repeating: thumbs, count: DesktopNaming.maxLength))
    }

    func testTruncationHappensAfterTrimming() {
        // 先 trim 再截断：首尾空白不该占掉字符配额。
        XCTAssertEqual(DesktopNaming.normalize("  一二三四五六七八九十甲乙  "), "一二三四五六七八九十")
    }

    // MARK: - 显示名解析

    func testDisplayNameFallsBackToOrdinal() {
        XCTAssertEqual(DesktopNaming.displayName(for: space(ordinal: 2), bindings: []), "桌面 2")
    }

    func testDisplayNamePrefersCustomName() {
        let s = space(ordinal: 2)
        XCTAssertEqual(DesktopNaming.displayName(for: s, bindings: [binding(for: s, name: "工作")]), "工作")
    }

    func testDisplayNameIgnoresBlankCustomName() {
        let s = space(ordinal: 2)
        XCTAssertEqual(DesktopNaming.displayName(for: s, bindings: [binding(for: s, name: "   ")]), "桌面 2")
    }

    func testDisplayNameIsScopedByDisplayAndSpaceUUID() {
        // 多显示器时映射键是 (displayUUID, spaceUUID)：另一台显示器上的同序号桌面不能串名。
        let mine = space(ordinal: 1, display: "DISPLAY-A")
        let other = space(ordinal: 1, display: "DISPLAY-B")
        let bindings = [binding(for: mine, name: "工作")]
        XCTAssertEqual(DesktopNaming.displayName(for: mine, bindings: bindings), "工作")
        XCTAssertEqual(DesktopNaming.displayName(for: other, bindings: bindings), "桌面 1")
    }

    // MARK: - 改名规则

    func testRenameCreatesBindingWithoutOverride() {
        let s = space()
        let updated = DesktopNaming.updatingBindings([], name: "工作", for: s)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.customName, "工作")
        XCTAssertNil(updated.first?.override, "改名不该顺手创建 Dock override")
        XCTAssertEqual(updated.first?.id, s.id)
    }

    func testRenameDoesNotTouchExistingOverride() {
        let s = space()
        let config = DockConfig(pinnedApps: [], otherItems: [], appearance: DockAppearance())
        let existing = binding(for: s, name: "旧名", override: config)

        let updated = DesktopNaming.updatingBindings([existing], name: "新名", for: s)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.customName, "新名")
        XCTAssertEqual(updated.first?.override, config, "命名与 Dock 绑定解耦，改名不能动 override")
    }

    func testClearingNameRemovesBindingWithNoOverride() {
        let s = space()
        let updated = DesktopNaming.updatingBindings([binding(for: s, name: "工作")], name: "", for: s)
        XCTAssertTrue(updated.isEmpty, "既没名字也没 Dock 设置的绑定该被删掉，不留空行")
    }

    func testClearingNameKeepsBindingWithOverride() {
        let s = space()
        let config = DockConfig()
        let updated = DesktopNaming.updatingBindings(
            [binding(for: s, name: "工作", override: config)],
            name: "  ",
            for: s
        )
        XCTAssertEqual(updated.count, 1)
        XCTAssertNil(updated.first?.customName)
        XCTAssertEqual(updated.first?.override, config)
    }

    func testClearingWithoutExistingBindingIsNoop() {
        XCTAssertTrue(DesktopNaming.updatingBindings([], name: "   ", for: space()).isEmpty)
    }

    func testRenameStoresTruncatedName() {
        let s = space()
        let updated = DesktopNaming.updatingBindings([], name: "一二三四五六七八九十甲乙", for: s)
        XCTAssertEqual(updated.first?.customName, "一二三四五六七八九十")
    }

    func testRenameOnOtherDesktopLeavesTheRestAlone() {
        let a = space(ordinal: 1, display: "DISPLAY-A")
        let b = space(ordinal: 2, display: "DISPLAY-A")
        let updated = DesktopNaming.updatingBindings([binding(for: a, name: "A")], name: "B", for: b)
        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(DesktopNaming.displayName(for: a, bindings: updated), "A")
        XCTAssertEqual(DesktopNaming.displayName(for: b, bindings: updated), "B")
    }

    // MARK: - 加载时归一化

    func testNormalizedBindingsTruncatesAndDropsEmptyRows() {
        let s = space()
        let messy = [
            binding(for: s, name: "一二三四五六七八九十甲乙"),   // 超长 → 截断
            binding(for: s, name: "   "),                       // 空 → 整条丢弃
            binding(for: s, name: nil, override: DockConfig()), // 无名字但有 override → 保留
        ]
        let normalized = DesktopNaming.normalizedBindings(messy)
        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized[0].customName, "一二三四五六七八九十")
        XCTAssertNil(normalized[1].customName)
        XCTAssertNotNil(normalized[1].override)
    }
}

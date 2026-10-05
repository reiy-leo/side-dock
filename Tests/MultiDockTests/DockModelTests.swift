import XCTest
@testable import MultiDock

/// 数据模型与指纹归一化。对应 `docs/PLAN.md` §4 里「指纹归一化、白名单写入」的验收点。
final class DockModelTests: XCTestCase {

    // MARK: - PlistValue

    func testBooleanIsNotConfusedWithNumber() {
        // NSNumber 会把布尔桥接成数字。用错判断方式时 true 会变成 1，
        // 导致「magnification = true」被写成整数、Dock 不认。
        XCTAssertEqual(PlistValue(any: true), .bool(true))
        XCTAssertEqual(PlistValue(any: false), .bool(false))
        XCTAssertEqual(PlistValue(any: NSNumber(value: 1)), .int(1))
        XCTAssertEqual(PlistValue(any: NSNumber(value: 0)), .int(0))
    }

    func testNumberKindsAreDistinguished() {
        XCTAssertEqual(PlistValue(any: NSNumber(value: 36)), .int(36))
        XCTAssertEqual(PlistValue(any: NSNumber(value: 36.5)), .double(36.5))
    }

    func testRoundTripThroughAny() {
        let original: [String: Any] = [
            "string": "hello",
            "int": 42,
            "bool": true,
            "double": 1.5,
            "array": [1, 2, 3],
            "nested": ["key": "value"],
        ]
        var converted: [String: PlistValue] = [:]
        for (key, value) in original {
            converted[key] = PlistValue(any: value)
        }
        let back = converted.mapValues(\.anyValue)

        XCTAssertEqual(back["string"] as? String, "hello")
        XCTAssertEqual(back["int"] as? Int, 42)
        XCTAssertEqual(back["bool"] as? Bool, true)
        XCTAssertEqual(back["double"] as? Double, 1.5)
        XCTAssertEqual(back["array"] as? [Int], [1, 2, 3])
        XCTAssertEqual((back["nested"] as? [String: Any])?["key"] as? String, "value")
    }

    // MARK: - tile 归一化

    private func makeTile(
        label: String,
        url: String,
        guid: Int? = nil,
        fileModDate: Int? = nil,
        book: Data? = nil
    ) -> DockTile {
        var tileData: [String: PlistValue] = [
            "file-data": .dictionary([
                "_CFURLString": .string(url),
                "_CFURLStringType": .int(15),
            ]),
            "file-label": .string(label),
            "dock-extra": .bool(false),
            "file-type": .int(41),
        ]
        if let fileModDate { tileData["file-mod-date"] = .int(fileModDate) }
        if let book { tileData["book"] = .data(book) }
        var raw: [String: PlistValue] = [
            "tile-type": .string("file-tile"),
            "tile-data": .dictionary(tileData),
        ]
        if let guid { raw["GUID"] = .int(guid) }
        return DockTile(raw: raw)
    }

    func testNormalizedKeyIgnoresDockRegeneratedFields() {
        // 计划 §3.8 要求：归一化必须剔除 GUID / file-mod-date / book，
        // 否则 Dock 每次重载都会重算这些字段，指纹永远对不上，会误判成"用户改了 Dock"。
        let plain = makeTile(label: "Chrome", url: "file:///Applications/Google%20Chrome.app/")
        let noisy = makeTile(
            label: "Chrome",
            url: "file:///Applications/Google%20Chrome.app/",
            guid: 12345,
            fileModDate: 999_999,
            book: Data([0x01, 0x02, 0x03])
        )
        XCTAssertEqual(plain.normalizedKey, noisy.normalizedKey)
    }

    func testNormalizedKeyDistinguishesDifferentApps() {
        let a = makeTile(label: "Chrome", url: "file:///Applications/Google%20Chrome.app/")
        let b = makeTile(label: "Safari", url: "file:///Applications/Safari.app/")
        XCTAssertNotEqual(a.normalizedKey, b.normalizedKey)
    }

    func testNormalizedKeyIsOrderSensitiveInConfigFingerprint() {
        let a = makeTile(label: "A", url: "file:///Applications/A.app/")
        let b = makeTile(label: "B", url: "file:///Applications/B.app/")

        let first = DockConfig(pinnedApps: [a, b])
        let second = DockConfig(pinnedApps: [b, a])

        // 顺序不同就是不同配置 —— 否则"拖拽排序"会被指纹短路掉。
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    func testFingerprintIsStableForIdenticalContent() {
        let tiles = [makeTile(label: "A", url: "file:///Applications/A.app/")]
        let one = DockConfig(pinnedApps: tiles)
        let two = DockConfig(pinnedApps: tiles)
        XCTAssertEqual(one.fingerprint, two.fingerprint)
    }

    func testFingerprintCoversOtherItemsToo() {
        // 其他项（文件夹/堆栈）同样参与指纹：内容变了必须重新应用。
        let folder = DockTile(raw: [
            "tile-type": .string("directory-tile"),
            "tile-data": .dictionary([
                "file-data": .dictionary([
                    "_CFURLString": .string("file:///Users/x/Downloads/"),
                    "_CFURLStringType": .int(15),
                ]),
                "file-label": .string("下载"),
            ]),
        ])
        let without = DockConfig(pinnedApps: [])
        let with = DockConfig(pinnedApps: [], otherItems: [folder])
        XCTAssertNotEqual(without.fingerprint, with.fingerprint)
    }

    // MARK: - tile 合成

    func testMakeFileTileDoesNotAssignGUID() {
        // 计划 §3.6：新建 tile 时不给 GUID，让 Dock 自己分配。
        let tile = DockTile.makeFileTile(
            url: URL(fileURLWithPath: "/Applications/Example.app"),
            label: "Example",
            bundleIdentifier: "com.example.app"
        )
        XCTAssertNil(tile.raw["GUID"])
        XCTAssertEqual(tile.tileType, "file-tile")
        XCTAssertEqual(tile.label, "Example")
        XCTAssertEqual(tile.bundleIdentifier, "com.example.app")
    }
}

import XCTest
@testable import MultiDock

/// **真机验收：读这台 Mac 上真实的启动台数据库**（只读，不改一个字节）。
///
/// 默认跳过 —— 与 `DockAcceptanceTests` 同一约定，需要显式开启：
/// `MULTIDOCK_LAUNCHPAD_ACCEPTANCE=1 swift test --disable-sandbox --filter LaunchpadAcceptanceTests`
///
/// 验四件事：
/// 1. 数据库位置按 Darwin 用户目录算得对（能打开）；
/// 2. 文件夹与 App 读得出来，且每个文件夹的 App 数 > 0；
/// 3. bookmark 解析率（这台机器上真机实测 160/160；这里只要**绝大多数**能解析，
///    因为删掉的 App 本来就该解析不到 —— 那种情况回落 bundle id 索引也算成功）；
/// 4. 读完之后数据库文件的字节不变（只读承诺）。
final class LaunchpadAcceptanceTests: XCTestCase {

    private func requireEnabled() throws {
        guard ProcessInfo.processInfo.environment["MULTIDOCK_LAUNCHPAD_ACCEPTANCE"] == "1" else {
            throw XCTSkip("需要 MULTIDOCK_LAUNCHPAD_ACCEPTANCE=1（只读真机启动台数据库）")
        }
    }

    func testRealLaunchpadDatabaseReadsAndResolves() throws {
        try requireEnabled()
        guard LaunchpadSupport.isSystemSupported else {
            throw XCTSkip("本机 macOS \(LaunchpadSupport.currentMajorVersion) 没有启动台，跳过")
        }

        let url = LaunchpadDatabase.defaultURL()
        print("启动台数据库：\(url.path)")
        let before = try Data(contentsOf: url)

        let records = try LaunchpadDatabase.loadFolders(at: url)
        XCTAssertFalse(records.isEmpty, "真机上应当至少有一个启动台文件夹")
        for record in records {
            XCTAssertFalse(record.apps.isEmpty, "文件夹「\(record.name)」读出来是空的 —— 层级查询可能错了")
        }

        let folders = LaunchpadResolver().resolve(records)
        let total = folders.reduce(0) { $0 + $1.apps.count }
        let resolved = folders.reduce(0) { $0 + $1.resolvedApps.count }
        let unresolvedTitles = folders.flatMap { $0.apps.filter { !$0.isResolved }.map(\.title) }
        print("真机启动台：\(folders.count) 个文件夹、\(total) 个 App，定位成功 \(resolved) 个")
        print("文件夹：\(folders.map { "\($0.displayName)(\($0.apps.count))" }.joined(separator: "、"))")
        if !unresolvedTitles.isEmpty {
            print("定位不到（\(unresolvedTitles.count)）：\(unresolvedTitles.joined(separator: "、"))")
        }
        XCTAssertGreaterThan(resolved, 0, "一个都定位不到说明解析链路断了")
        // 真机绝大多数应当能定位（实测 160/160）；留一点余量给"刚删掉的 App"。
        XCTAssertGreaterThan(
            Double(resolved) / Double(max(total, 1)), 0.8,
            "定位率低于 80%，bookmark 解析或兜底索引可能有问题"
        )

        let after = try Data(contentsOf: url)
        XCTAssertEqual(before, after, "只读承诺：读启动台数据库不得修改它")
    }
}

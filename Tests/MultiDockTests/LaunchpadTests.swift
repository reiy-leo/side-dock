import Foundation
import SQLite3
import XCTest
@testable import MultiDock

// MARK: - 夹具：造一个与真机同形的启动台数据库

/// 造测试用的启动台库（只建读取要用的三张表：`items` / `apps` / `groups`）。
///
/// 刻意支持**乱序插入 + 显式 ordering**：真机库里 rowid 与屏幕顺序无关，
/// 读取器必须靠 `parent_id + ordering` 排序 —— 按插入顺序排的夹具会让这一条失去意义。
final class LaunchpadFixtureDatabase {
    struct App {
        var title: String
        var bundleID: String
        var bookmark: Data?
    }

    struct Folder {
        var name: String
        /// 文件夹内的分页（真机：一个文件夹=一个或多个 type 3 的页，App 挂在页下面）。
        var pages: [[App]]
    }

    var folders: [Folder] = []
    /// 直接挂在启动台根页上的 App（不进任何文件夹）——读取器应当忽略它们。
    var rootApps: [App] = []

    private var handle: OpaquePointer?
    private var nextRowID: Int64 = 1

    /// 写库。返回写出的文件 URL。
    @discardableResult
    static func write(_ configure: (inout LaunchpadFixtureDatabase) -> Void, to url: URL) throws -> URL {
        var fixture = LaunchpadFixtureDatabase()
        configure(&fixture)
        try fixture.build(at: url)
        return url
    }

    private func build(at url: URL) throws {
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK, "建库失败")
        defer { sqlite3_close(handle) }
        try exec("""
        CREATE TABLE items (rowid INTEGER PRIMARY KEY ASC, uuid VARCHAR, flags INTEGER, type INTEGER,
                            parent_id INTEGER NOT NULL, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR,
                           category_id INTEGER, moddate REAL, bookmark BLOB);
        CREATE TABLE groups (item_id INTEGER PRIMARY KEY, category_id INTEGER, title VARCHAR);
        """)

        // 根（真机：`parent_id = 0` 的 type 1 条目）。
        let root = insertItem(type: 1, parent: 0, ordering: 0)
        // 根页（type 3）—— 文件夹和"根页上的 App"都挂在它下面。
        let rootPage = insertItem(type: 3, parent: root, ordering: 0)

        // 乱序插入文件夹：屏幕顺序由 ordering 决定，不由插入顺序。
        var folderOrder: [Int] = Array(folders.indices)
        folderOrder.reverse()
        for index in folderOrder {
            let folder = folders[index]
            let folderID = insertItem(type: 2, parent: rootPage, ordering: Int64(index))
            insertGroup(itemID: folderID, title: folder.name)
            for (pageIndex, pageApps) in folder.pages.enumerated() {
                let pageID = insertItem(type: 3, parent: folderID, ordering: Int64(pageIndex))
                for (appIndex, app) in pageApps.enumerated() {
                    let appID = insertItem(type: 4, parent: pageID, ordering: Int64(appIndex))
                    insertApp(itemID: appID, app: app)
                }
            }
        }
        for (index, app) in rootApps.enumerated() {
            let appID = insertItem(type: 4, parent: rootPage, ordering: Int64(index + 100))
            insertApp(itemID: appID, app: app)
        }
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            XCTFail("夹具 SQL 失败：\(message)")
            throw LaunchpadDatabaseError.queryFailed(message)
        }
    }

    private func insertItem(type: Int, parent: Int64, ordering: Int64) -> Int64 {
        let id = nextRowID
        nextRowID += 1
        try? exec("INSERT INTO items (rowid, uuid, flags, type, parent_id, ordering) "
            + "VALUES (\(id), '\(UUID().uuidString)', 0, \(type), \(parent), \(ordering));")
        return id
    }

    private func insertApp(itemID: Int64, app: App) {
        let binder = AppBinder(handle: handle)
        binder.insert(itemID: itemID, app: app)
    }

    private func insertGroup(itemID: Int64, title: String) {
        let binder = AppBinder(handle: handle)
        binder.insertGroup(itemID: itemID, title: title)
    }
}

/// 绑参数的插入（文本里有引号会打断拼 SQL，必须走 prepare/bind）。
///
/// ⚠️ 析构符必须用 `SQLITE_TRANSIENT`（`-1` 的位转换）：Swift 的 `String` 传给
/// `sqlite3_bind_text` 时是临时 C 串，`SQLITE_STATIC`（`nil`）会在 `step` 前就失效 ——
/// 实测表现是**所有文本都变成空串**（夹具静默坏掉，排查成本很高）。
private struct AppBinder {
    let handle: OpaquePointer?

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func insert(itemID: Int64, app: LaunchpadFixtureDatabase.App) {
        var statement: OpaquePointer?
        let sql = "INSERT INTO apps (item_id, title, bundleid, storeid, category_id, moddate, bookmark) "
            + "VALUES (?, ?, ?, NULL, NULL, NULL, ?);"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, itemID)
        sqlite3_bind_text(statement, 2, app.title, -1, Self.transient)
        sqlite3_bind_text(statement, 3, app.bundleID, -1, Self.transient)
        if let bookmark = app.bookmark {
            sqlite3_bind_blob(statement, 4, [UInt8](bookmark), Int32(bookmark.count), Self.transient)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_step(statement)
    }

    func insertGroup(itemID: Int64, title: String) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO groups (item_id, title) VALUES (?, ?);",
                                 -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, itemID)
        sqlite3_bind_text(statement, 2, title, -1, Self.transient)
        sqlite3_step(statement)
    }
}

// MARK: - 只读数据库

/// 启动台数据库读取器：顺序、层级、错误分类。
final class LaunchpadDatabaseTests: XCTestCase {

    private func tempURL(_ name: String) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-lp-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("db")
    }

    /// 文件夹按屏幕顺序返回（夹具是倒序插入的，只有 ordering 排对了才会通过）；
    /// 多页文件夹里的 App 按「页序 → 页内序」串成一条。
    func testReadsFoldersAndAppsInLaunchpadOrder() throws {
        let url = try LaunchpadFixtureDatabase.write({ fixture in
            fixture.folders = [
                LaunchpadFixtureDatabase.Folder(name: "第一个", pages: [[
                    .init(title: "A1", bundleID: "com.example.a1", bookmark: nil),
                    .init(title: "A2", bundleID: "com.example.a2", bookmark: nil),
                ]]),
                LaunchpadFixtureDatabase.Folder(name: "第二个", pages: [
                    [.init(title: "B1", bundleID: "com.example.b1", bookmark: nil)],
                    [
                        .init(title: "B2", bundleID: "com.example.b2", bookmark: nil),
                        .init(title: "B3", bundleID: "com.example.b3", bookmark: nil),
                    ],
                ]),
            ]
            fixture.rootApps = [.init(title: "根页 App", bundleID: "com.example.root", bookmark: nil)]
        }, to: tempURL("order"))

        let folders = try LaunchpadDatabase.loadFolders(at: url)
        XCTAssertEqual(folders.map(\.name), ["第一个", "第二个"], "文件夹顺序必须按 ordering")
        XCTAssertEqual(folders[0].apps.map(\.title), ["A1", "A2"])
        XCTAssertEqual(folders[1].apps.map(\.title), ["B1", "B2", "B3"], "多页文件夹要按页序串起来")
        XCTAssertEqual(folders.map { $0.apps.count }, [2, 3], "根页上的散 App 不该混进任何文件夹")
    }

    func testMissingFileThrowsMissing() {
        let url = tempURL("missing")
        XCTAssertThrowsError(try LaunchpadDatabase.loadFolders(at: url)) { error in
            guard case LaunchpadDatabaseError.missing = error else {
                return XCTFail("应是 missing，实际 \(error)")
            }
        }
    }

    func testGarbageFileThrowsQueryFailed() throws {
        let url = tempURL("garbage")
        try Data("not a database".utf8).write(to: url)
        XCTAssertThrowsError(try LaunchpadDatabase.loadFolders(at: url)) { error in
            // 打不开（不是 SQLite 文件）或读不出表都可以，但必须是"读取失败"而不是"文件不存在"。
            switch error {
            case LaunchpadDatabaseError.openFailed, LaunchpadDatabaseError.queryFailed:
                break
            default:
                XCTFail("应是 openFailed/queryFailed，实际 \(error)")
            }
        }
    }

    /// 空标题、空 bundle id 照原样读出（显示层再回落「未命名」）。
    func testEmptyFieldsSurvive() throws {
        let url = try LaunchpadFixtureDatabase.write({ fixture in
            fixture.folders = [
                LaunchpadFixtureDatabase.Folder(name: "", pages: [[
                    .init(title: "", bundleID: "", bookmark: nil),
                ]]),
            ]
        }, to: tempURL("empty"))
        let folders = try LaunchpadDatabase.loadFolders(at: url)
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders[0].name, "")
        XCTAssertEqual(folders[0].apps.first?.title, "")
        XCTAssertEqual(folders[0].apps.first?.bundleIdentifier, "")
        XCTAssertNil(folders[0].apps.first?.bookmark)
    }

    /// **只读保证**：读一遍之后文件的字节不该变（启动台的数据我们绝不碰）。
    func testReadingDoesNotModifyTheDatabase() throws {
        let url = try LaunchpadFixtureDatabase.write({ fixture in
            fixture.folders = [LaunchpadFixtureDatabase.Folder(name: "只读", pages: [[
                .init(title: "A", bundleID: "com.example.a", bookmark: nil),
            ]])]
        }, to: tempURL("readonly"))
        let before = try Data(contentsOf: url)
        _ = try LaunchpadDatabase.loadFolders(at: url)
        let after = try Data(contentsOf: url)
        XCTAssertEqual(before, after, "读启动台数据库不得写入任何字节")
    }
}

// MARK: - 解析（bookmark → 路径 → 条目）

final class LaunchpadResolverTests: XCTestCase {
    private let calculatorPath = "/System/Applications/Calculator.app"

    private func tempDirectory() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-lp-resolve-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 造一个最小可用的 `.app`（`Bundle` 能读出 bundle id 和名字即可）。
    @discardableResult
    private func makeApp(at directory: URL, name: String, bundleID: String) throws -> URL {
        let appURL = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return appURL
    }

    private func bookmark(for path: String) throws -> Data {
        try URL(fileURLWithPath: path).bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
    }

    /// bookmark 是首选路径：解出真实路径 + 文件名，标成「已定位」。
    func testBookmarkResolvesToRealPath() throws {
        let record = LaunchpadFolderRecord(itemID: 1, name: "工具", apps: [
            LaunchpadAppRecord(title: "计算器", bundleIdentifier: "com.apple.Calculator",
                               bookmark: try bookmark(for: calculatorPath)),
        ])
        let folder = try XCTUnwrap(LaunchpadResolver(searchRoots: []).resolve([record]).first)
        XCTAssertEqual(folder.apps.count, 1)
        XCTAssertEqual(folder.apps[0].path, calculatorPath)
        XCTAssertNotNil(folder.apps[0].tile, "解析出的路径必须能造出条目")
        XCTAssertTrue(folder.resolvedApps.count == 1 && folder.unresolvedCount == 0)
    }

    /// bookmark 解不出（文件已删）→ 回落 bundle id 索引。
    func testFallsBackToBundleIndexWhenBookmarkIsStale() throws {
        let directory = tempDirectory()
        try makeApp(at: directory, name: "FakeTool", bundleID: "com.example.faketool")
        // bookmark 指向一个不存在的路径，索引里有真身。
        let record = LaunchpadFolderRecord(itemID: 1, name: "工具", apps: [
            LaunchpadAppRecord(title: "FakeTool", bundleIdentifier: "com.example.faketool",
                               bookmark: try bookmark(for: "/System/Applications/Calculator.app")),
            LaunchpadAppRecord(title: "没了", bundleIdentifier: "com.example.gone",
                               bookmark: nil),
        ])
        let folder = try XCTUnwrap(
            LaunchpadResolver(searchRoots: [directory.path]).resolve([record]).first
        )
        // 第一条的 bookmark 指向计算器（存在的），所以它仍解析成计算器 —— 这是设计：
        // bookmark 优先。第二条没有 bookmark、索引里也没有 → 定位不到。
        XCTAssertEqual(folder.apps[1].path, nil)
        XCTAssertEqual(folder.unresolvedCount, 1)

        // 纯索引路径：没有 bookmark、bundle id 在索引里 → 命中。
        let indexed = LaunchpadFolderRecord(itemID: 2, name: "工具", apps: [
            LaunchpadAppRecord(title: "FakeTool", bundleIdentifier: "com.example.faketool", bookmark: nil),
        ])
        let resolved = try XCTUnwrap(
            LaunchpadResolver(searchRoots: [directory.path]).resolve([indexed]).first
        )
        // 临时目录走 `/var`，而枚举拿到的 URL 是解析过符号链接的 `/private/var` —— 两边都归一后再比。
        let resolvedPath = try XCTUnwrap(resolved.apps[0].path)
        let expected = directory.appendingPathComponent("FakeTool.app").path
        XCTAssertEqual(
            URL(fileURLWithPath: resolvedPath).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
        )
        XCTAssertNotNil(resolved.apps[0].tile)
    }

    /// 同一个 App 在文件夹里出现两行（真机数据库的历史残留：iWork 双版本同名不同 bundle id）
    /// → 按解析出的路径去重，只保留先出现的。
    func testDuplicatePathsAreDeduped() throws {
        let shared = try bookmark(for: calculatorPath)
        let record = LaunchpadFolderRecord(itemID: 1, name: "效率", apps: [
            LaunchpadAppRecord(title: "计算器", bundleIdentifier: "com.apple.Calculator", bookmark: shared),
            LaunchpadAppRecord(title: "计算器", bundleIdentifier: "com.apple.Calculator.alt", bookmark: shared),
        ])
        let folder = try XCTUnwrap(LaunchpadResolver(searchRoots: []).resolve([record]).first)
        XCTAssertEqual(folder.apps.count, 1)
        XCTAssertEqual(folder.apps[0].bundleIdentifier, "com.apple.Calculator")
    }

    /// 定位不到的条目**照数保留**（要如实告知"几个搬不了"），不去重也不丢。
    func testUnresolvedEntriesAreKeptAndCounted() throws {
        let record = LaunchpadFolderRecord(itemID: 1, name: "空", apps: [
            LaunchpadAppRecord(title: "甲", bundleIdentifier: "", bookmark: nil),
            LaunchpadAppRecord(title: "乙", bundleIdentifier: "", bookmark: nil),
        ])
        let folder = try XCTUnwrap(LaunchpadResolver(searchRoots: []).resolve([record]).first)
        XCTAssertEqual(folder.apps.count, 2)
        XCTAssertEqual(folder.unresolvedCount, 2)
        XCTAssertTrue(folder.resolvedApps.isEmpty)
    }

    /// 显示名回落：标题为空时用「未命名」。
    func testEmptyNameFallsBackToUntitled() {
        let folder = LaunchpadFolder(itemID: 1, name: "", apps: [])
        XCTAssertEqual(folder.displayName, L("未命名", "Untitled"))
    }
}

// MARK: - 搬运规则

/// `LaunchpadImport` 的纯规则：并集 / 替换 / 上限 / 跳过项的账。
final class LaunchpadImportTests: XCTestCase {

    private func tile(_ name: String, bundle: String? = nil) -> DockTile {
        DockTile.makeFileTile(
            url: URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true),
            label: name,
            bundleIdentifier: bundle ?? "com.example.\(name.lowercased())"
        )
    }

    private func folder(_ names: [String], name: String = "文件夹") -> LaunchpadFolder {
        makeLaunchpadFolder(itemID: 1, name: name, apps: names.map { ($0, tile($0)) })
    }

    func testAppendedKeepsExistingOrderAndAppendsFolderApps() {
        let existing = [tile("A"), tile("B")]
        let (apps, report) = LaunchpadImport.appended(existing: existing, folder: folder(["C", "D"]))
        XCTAssertEqual(apps.map(\.label), ["A", "B", "C", "D"])
        XCTAssertEqual(report.addedCount, 2)
        XCTAssertEqual(report.keptCount, 4)
        XCTAssertFalse(report.hasSkips)
    }

    func testAppendedSkipsDuplicatesAlreadyInBar() {
        let existing = [tile("A"), tile("C")]
        let (apps, report) = LaunchpadImport.appended(existing: existing, folder: folder(["C", "D"]))
        XCTAssertEqual(apps.map(\.label), ["A", "C", "D"])
        XCTAssertEqual(report.addedCount, 1)
        XCTAssertEqual(report.duplicateCount, 1)
    }

    func testAppendedRespectsLimit() {
        let (apps, report) = LaunchpadImport.appended(
            existing: [tile("A")], folder: folder(["B", "C", "D"]), limit: 3
        )
        XCTAssertEqual(apps.map(\.label), ["A", "B", "C"])
        XCTAssertEqual(report.addedCount, 2)
        XCTAssertEqual(report.overLimitCount, 1)
    }

    func testAppendedSkipsAppsPinnedInNativeDock() {
        let pinned = tile("Safari", bundle: "com.apple.Safari")
        let (apps, report) = LaunchpadImport.appended(
            existing: [], folder: folder(["Xcode", "Safari"]), pinnedIn: DockStripRules.identityKeys(of: [pinned])
        )
        XCTAssertEqual(apps.map(\.label), ["Xcode"])
        XCTAssertEqual(report.pinnedSkipped, ["Safari"])
    }

    func testAppendedReportsUnresolvedApps() {
        let folder = makeLaunchpadFolder(itemID: 1, name: "混合", apps: [
            ("有", tile("Has")),
            ("无", nil),
        ])
        let (apps, report) = LaunchpadImport.appended(existing: [], folder: folder)
        XCTAssertEqual(apps.map(\.label), ["Has"])
        XCTAssertEqual(report.unresolvedTitles, ["无"])
    }

    func testReplacedReturnsFolderContentsOnly() {
        let existing = [tile("Old1"), tile("Old2")]
        let (apps, report) = LaunchpadImport.replaced(folder: folder(["New1", "New2"]))
        XCTAssertEqual(apps.map(\.label), ["New1", "New2"])
        XCTAssertEqual(report.keptCount, 2)
        XCTAssertNotEqual(apps.map(\.label), existing.map(\.label))
    }

    func testReplacedDedupesWithinFolder() {
        let duplicate = tile("Same")
        let folder = makeLaunchpadFolder(itemID: 1, name: "重复", apps: [
            ("Same", duplicate),
            ("Same", duplicate),
        ])
        let (apps, report) = LaunchpadImport.replaced(folder: folder)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(report.duplicateCount, 1)
    }

    func testReplacedRespectsPinnedExclusionAndLimit() {
        let safari = tile("Safari", bundle: "com.apple.Safari")
        let (apps, report) = LaunchpadImport.replaced(
            folder: folder(["A", "Safari", "B", "C"]),
            limit: 2,
            pinnedIn: DockStripRules.identityKeys(of: [safari])
        )
        XCTAssertEqual(apps.map(\.label), ["A", "B"])
        XCTAssertEqual(report.pinnedSkipped, ["Safari"])
        XCTAssertEqual(report.overLimitCount, 1)
    }

    func testEmptyFolderYieldsEmptyResult() {
        let (apps, report) = LaunchpadImport.replaced(folder: folder([]))
        XCTAssertTrue(apps.isEmpty)
        XCTAssertEqual(report.keptCount, 0)
    }
}

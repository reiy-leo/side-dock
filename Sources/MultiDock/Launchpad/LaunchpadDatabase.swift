import Foundation
import SQLite3

/// 启动台数据库的读取失败。每种都把**能说清的原因**带给用户 ——
/// 静默空列表会让人以为"启动台里没有文件夹"。
enum LaunchpadDatabaseError: Error, Equatable, Sendable {
    /// 数据库文件不存在：从没用过启动台，或系统没有启动台（macOS 26+）。
    case missing(String)
    case openFailed(String)
    case queryFailed(String)

    /// 给用户看的一句话（含下一步怎么办）。
    var userMessage: String {
        switch self {
        case .missing(let path):
            return L("读不到启动台数据库（\(path)）—— 打开一次启动台再回来点「刷新」。",
                     "Can't read the Launchpad database (\(path)) — open Launchpad once, then hit Refresh.")
        case .openFailed(let reason), .queryFailed(let reason):
            return L("读取启动台数据库失败：\(reason)", "Failed to read the Launchpad database: \(reason)")
        }
    }
}

/// 启动台数据库（SQLite）的**只读**读取。
///
/// 位置是每用户 Darwin 目录：`$DARWIN_USER_DIR/com.apple.dock.launchpad/db/db`。
/// 系统没有公开接口，但这份库是用户可读的普通文件（rw-r--r--），只读打开**零权限**；
/// 启动台自己用 WAL 写它，只读连接照常能读到最新内容（实测 160/160 个 App 全部可读）。
///
/// 表结构（macOS 15.8.1 实测）：
/// - `items(rowid, type, parent_id, ordering)` —— `type 1` 根 / `2` 文件夹 / `3` 页 / `4` App；
/// - `apps(item_id, title, bundleid, storeid, bookmark)` —— App 的名称、bundle id、定位 bookmark；
/// - `groups(item_id, title)` —— 文件夹（和文件夹内页）的名字。
///
/// 顺序：目录树里每一层都有自己的 `ordering`，所以用**递归 CTE 物化路径**串起来，
/// 拿到「与启动台屏幕上一致」的文件夹顺序与文件夹内 App 顺序（含多页文件夹）。
enum LaunchpadDatabase {

    /// 默认数据库位置。`confstr(_CS_DARWIN_USER_DIR)` 失败时按已知布局兜底（`…/0/`）。
    static func defaultURL() -> URL {
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count)
        let base: URL
        if length > 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            base = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
        } else {
            // 兜底：Darwin 用户目录 = 临时目录的上一级 + "0"（macOS 的固定布局）。
            base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .deletingLastPathComponent()
                .appendingPathComponent("0", isDirectory: true)
        }
        return base
            .appendingPathComponent("com.apple.dock.launchpad", isDirectory: true)
            .appendingPathComponent("db", isDirectory: true)
            .appendingPathComponent("db", isDirectory: false)
    }

    /// 读出全部文件夹（屏幕顺序），每个文件夹带屏幕顺序的 App 列表。
    static func loadFolders(at url: URL = defaultURL()) throws -> [LaunchpadFolderRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LaunchpadDatabaseError.missing(url.path)
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? ""
            if let handle { sqlite3_close(handle) }
            throw LaunchpadDatabaseError.openFailed(reason.isEmpty ? L("无法打开数据库", "can't open the database") : reason)
        }
        defer { sqlite3_close(handle) }
        // 启动台可能正在写（WAL）。读前等的上限给 1 秒，避免偶发 SQLITE_BUSY 直接把页面打成错误。
        sqlite3_busy_timeout(handle, 1_000)

        let folders = try readFolders(handle)
        let appsByFolder = try readApps(handle)
        return folders.map { folder in
            LaunchpadFolderRecord(
                itemID: folder.id,
                name: folder.name,
                apps: appsByFolder[folder.id] ?? []
            )
        }
    }

    // MARK: - 查询

    /// 文件夹列表（屏幕顺序）。
    ///
    /// 从根（`parent_id = 0`）递归物化路径；`walk.node` 就是条目 rowid。
    private static func readFolders(_ handle: OpaquePointer) throws -> [(id: Int, name: String)] {
        let sql = """
        WITH RECURSIVE walk(node, path) AS (
            SELECT rowid, printf('%09d.', ifnull(ordering, 0)) FROM items WHERE parent_id = 0
            UNION ALL
            SELECT c.rowid, walk.path || printf('%09d.', ifnull(c.ordering, 0))
            FROM items c JOIN walk ON c.parent_id = walk.node
        )
        SELECT walk.node, ifnull(groups.title, ''), walk.path
        FROM walk
        JOIN items ON items.rowid = walk.node
        LEFT JOIN groups ON groups.item_id = walk.node
        WHERE items.type = 2
        ORDER BY walk.path, walk.node;
        """
        return try withStatement(handle, sql: sql) { statement in
            var result: [(id: Int, name: String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append((Int(sqlite3_column_int64(statement, 0)), text(statement, 1)))
            }
            return result
        }
    }

    /// 每个文件夹下的 App（屏幕顺序）。
    ///
    /// 递归时把「最近一个 type = 2 的祖先」记进 `folder` 列 —— App 归到它所属的文件夹下；
    /// 文件夹自己的行也带上自己的 id（`CASE` 匹配 `c.type = 2`），所以子节点顺着继承。
    private static func readApps(_ handle: OpaquePointer) throws -> [Int: [LaunchpadAppRecord]] {
        let sql = """
        WITH RECURSIVE walk(node, path, folder) AS (
            SELECT rowid, printf('%09d.', ifnull(ordering, 0)), NULL FROM items WHERE parent_id = 0
            UNION ALL
            SELECT c.rowid, walk.path || printf('%09d.', ifnull(c.ordering, 0)),
                   CASE WHEN c.type = 2 THEN c.rowid ELSE walk.folder END
            FROM items c JOIN walk ON c.parent_id = walk.node
        )
        SELECT walk.folder, apps.title, ifnull(apps.bundleid, ''), apps.bookmark
        FROM walk
        JOIN apps ON apps.item_id = walk.node
        WHERE walk.folder IS NOT NULL
        ORDER BY walk.folder, walk.path;
        """
        return try withStatement(handle, sql: sql) { statement in
            var result: [Int: [LaunchpadAppRecord]] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let folder = Int(sqlite3_column_int64(statement, 0))
                let record = LaunchpadAppRecord(
                    title: text(statement, 1),
                    bundleIdentifier: text(statement, 2),
                    bookmark: blob(statement, 3)
                )
                result[folder, default: []].append(record)
            }
            return result
        }
    }

    // MARK: - SQLite 帮助

    private static func withStatement<T>(
        _ handle: OpaquePointer,
        sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LaunchpadDatabaseError.queryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private static func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, index)
        else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}

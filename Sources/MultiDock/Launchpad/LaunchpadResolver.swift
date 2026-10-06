import Foundation

/// 启动台记录 → 可写进 Dock 栏的条目（`DockTile`）。
///
/// 定位 App 有两条路：
/// 1. **bookmark**（首选）：启动台数据库里存的是 CFURL bookmark，`URL(resolvingBookmarkData:)`
///    直接解出真实路径 —— 真机实测 160/160 全中（含 `/System/Volumes/Preboot/…` 这类
///    cryptex 路径，文件都在）；
/// 2. **bundle id 索引**（兜底）：bookmark 解不出或文件已被删时，扫一遍常见安装目录
///    建 `bundleID → 路径` 索引再查。
///
/// 索引是**懒建**的：只有存在落到兜底的记录才会扫盘，全走 bookmark 时不扫。
struct LaunchpadResolver: Sendable {
    /// bundle id 兜底索引的搜索根（测试注入临时目录，不扫真实安装目录）。
    var searchRoots: [String] = LaunchpadResolver.defaultSearchRoots

    static var defaultSearchRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(home)/Applications",
        ]
    }

    func resolve(_ records: [LaunchpadFolderRecord]) -> [LaunchpadFolder] {
        var bundleIndex: [String: String]?
        return records.map { record in
            var seenPaths = Set<String>()
            var apps: [LaunchpadApp] = []
            for entry in record.apps {
                let path = resolvePath(entry, bundleIndex: &bundleIndex)
                let tile = path.flatMap { DockStripRules.tile(forAppAt: $0) }
                let app = LaunchpadApp(
                    title: entry.title,
                    bundleIdentifier: entry.bundleIdentifier,
                    path: path,
                    tile: tile
                )
                // 文件夹里可能有两行指向同一个 App（启动台数据库的历史残留，真机实测存在：
                // `com.apple.iWork.Pages` 与 `com.apple.Pages` 都叫「Pages文稿」）——
                // 按解析出的路径去重，保留先出现的；定位不到的条目不去重（要如实报数）。
                if let path {
                    guard seenPaths.insert(path.lowercased()).inserted else { continue }
                }
                apps.append(app)
            }
            return LaunchpadFolder(itemID: record.itemID, name: record.name, apps: apps)
        }
    }

    private func resolvePath(_ record: LaunchpadAppRecord, bundleIndex: inout [String: String]?) -> String? {
        if let bookmark = record.bookmark, let url = Self.resolveBookmark(bookmark),
           FileManager.default.fileExists(atPath: url.path) {
            return url.path
        }
        guard !record.bundleIdentifier.isEmpty else { return nil }
        if bundleIndex == nil {
            bundleIndex = Self.buildInstalledAppIndex(roots: searchRoots)
        }
        return bundleIndex?[record.bundleIdentifier]
    }

    /// 解 bookmark。`stale` 只是提示（路径仍有效），不影响使用。
    static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    /// 扫常见安装目录建 `bundleID → .app 路径` 索引。
    /// `.skipsPackageDescendants` 保证不钻进 App 包内部（否则 Xcode 里那堆内嵌 App 会污染索引）。
    static func buildInstalledAppIndex(roots: [String]) -> [String: String] {
        var index: [String: String] = [:]
        let fileManager = FileManager.default
        for root in roots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { continue }
                // 同名 bundle id 出现在多个位置时取先扫到的（搜索根按 /Applications 优先）。
                if index[identifier] == nil {
                    index[identifier] = url.path
                }
            }
        }
        return index
    }
}

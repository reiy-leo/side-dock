import Foundation

/// 「启动台文件夹 → Dock 栏」的搬运用规则（纯函数，好测）。
///
/// 用户规格（2026-10-06）的两个动作：
/// - **添加**：把文件夹里的 App **并入**目标栏末尾（栏里已有的不重复加、已有顺序不动）；
/// - **替换**：清空目标栏，换成文件夹的内容。
///
/// 两个动作共用三道闸，全部**如实报数**（不静默丢东西）：
/// 1. 定位不到的 App（磁盘上找不到 / 不是 .app 包）跳过；
/// 2. **已固定在原生 Dock 的 App 跳过** —— 2026-10-06 既有规则：那份每个桌面都能看到，
///    自定义栏只放"额外多出来的"（排除集由调用方按冻结模式给出）；
/// 3. 每栏上限 `DockBar.maxApps`，超出截断。
enum LaunchpadImport {

    /// 一次搬运的账。`duplicateCount` 在两个动作里含义不同：
    /// 添加 = 栏里已有（或文件夹内重复）没再加的；替换 = 文件夹内重复去重的。
    struct Report: Equatable, Sendable {
        var addedCount = 0
        var keptCount = 0
        var duplicateCount = 0
        var pinnedSkipped: [String] = []
        var unresolvedTitles: [String] = []
        var overLimitCount = 0

        /// 有没有"没进去"的东西 —— 有就把原因写进结果里。
        var hasSkips: Bool {
            duplicateCount > 0 || !pinnedSkipped.isEmpty || !unresolvedTitles.isEmpty || overLimitCount > 0
        }
    }

    /// 添加：`existing` 保持原顺序，文件夹里的新 App 依次接到末尾。
    static func appended(
        existing: [DockTile],
        folder: LaunchpadFolder,
        limit: Int = DockBar.maxApps,
        pinnedIn nativePinnedKeys: Set<String> = []
    ) -> (apps: [DockTile], report: Report) {
        var apps = DockStripRules.barApps(existing)
        var seen = Set(apps.map(\.normalizedKey))
        let (tiles, base) = eligibleTiles(folder: folder, limit: limit, pinnedIn: nativePinnedKeys)
        var report = base
        report.addedCount = 0
        for tile in tiles {
            guard !seen.contains(tile.normalizedKey) else {
                report.duplicateCount += 1
                continue
            }
            guard apps.count < limit else {
                report.overLimitCount += 1
                continue
            }
            seen.insert(tile.normalizedKey)
            apps.append(tile)
            report.addedCount += 1
        }
        report.keptCount = apps.count
        return (apps, report)
    }

    /// 替换：结果就是文件夹里可搬的那份（与旧内容"变了多少"由调用方对比）。
    static func replaced(
        folder: LaunchpadFolder,
        limit: Int = DockBar.maxApps,
        pinnedIn nativePinnedKeys: Set<String> = []
    ) -> (apps: [DockTile], report: Report) {
        let (tiles, report) = eligibleTiles(folder: folder, limit: limit, pinnedIn: nativePinnedKeys)
        var result = report
        result.keptCount = tiles.count
        return (DockStripRules.barApps(tiles), result)
    }

    /// 文件夹里可搬的条目：定位成功、未固定在原生 Dock、去重、截到上限。
    private static func eligibleTiles(
        folder: LaunchpadFolder,
        limit: Int,
        pinnedIn nativePinnedKeys: Set<String>
    ) -> (tiles: [DockTile], report: Report) {
        var tiles: [DockTile] = []
        var seen = Set<String>()
        var report = Report()
        for app in folder.apps {
            guard let tile = app.tile else {
                report.unresolvedTitles.append(app.title)
                continue
            }
            guard tile.appIdentityKeys.isDisjoint(with: nativePinnedKeys) else {
                report.pinnedSkipped.append(app.title)
                continue
            }
            guard !seen.contains(tile.normalizedKey) else {
                report.duplicateCount += 1
                continue
            }
            guard tiles.count < limit else {
                report.overLimitCount += 1
                continue
            }
            seen.insert(tile.normalizedKey)
            tiles.append(tile)
        }
        return (tiles, report)
    }
}

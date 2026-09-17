import AppKit
import Foundation

/// 图标条的固定规则（`docs/PLAN.md` §3.6 / §3.7）。
///
/// 两条 P0 实测结论决定了这里的形状：
/// 1. **Finder 在 `com.apple.dock` 里没有任何表示** —— 全量域 34 个键里找不到它。
///    所以"钉住 Finder"这件事**天然成立、无需代码**；UI 里把它画出来只是为了符合用户预期，
///    它绝不参与写入，也不该有拖拽手柄。
/// 2. **启动台是普通条目**（`persistent-apps[0]`，`bundle-identifier = com.apple.launchpad.launcher`，
///    `file-type = 169`，`dock-extra = false`）。它必须存在，所以由本类型负责"保证它在首位"。
enum DockStripRules {

    /// 启动台的真实路径与标识（本机实测值）。
    static let launchpadPath = "/System/Applications/Launchpad.app"
    static let launchpadBundleIdentifier = "com.apple.launchpad.launcher"
    /// 真实域里启动台的 `file-type` 是 169，普通 App 是 41。
    static let launchpadFileType = 169

    static let finderPath = "/System/Library/CoreServices/Finder.app"

    /// 该条目是不是启动台。
    static func isLaunchpad(_ tile: DockTile) -> Bool {
        if tile.bundleIdentifier == launchpadBundleIdentifier { return true }
        guard let url = tile.fileURLString else { return false }
        return url.hasPrefix("file://" + launchpadPath)
    }

    /// 合成启动台条目。
    static func makeLaunchpadTile() -> DockTile {
        DockTile.makeFileTile(
            url: URL(fileURLWithPath: launchpadPath, isDirectory: true),
            label: "启动台",
            bundleIdentifier: launchpadBundleIdentifier,
            fileType: launchpadFileType,
            dockExtra: false
        )
    }

    /// 把用户给的条目整理成"可写入"的顺序：
    /// 去掉重复的启动台，然后**把启动台放到首位**。
    ///
    /// 幂等：已经是这个形状时返回等值数组。
    ///
    /// **已存在的启动台条目原样保留**（连 `GUID` / `book` / `file-mod-date` 一起）。
    /// 早先版本无条件用 `makeLaunchpadTile()` 覆盖它，结果每次编辑图标条都会把真实域里
    /// 启动台的那几个字段抹掉、逼 Dock 重新推导一遍 —— 功能上能跑，但没必要。
    /// 只有"域里压根没有启动台"时才现造一个。
    static func normalizedApps(_ apps: [DockTile]) -> [DockTile] {
        var rest = apps.filter { !isLaunchpad($0) }
        // 顺手去掉完全重复的条目（同一个 App 被拖进来两次）。按归一化键判重。
        var seen = Set<String>()
        rest = rest.filter { seen.insert($0.normalizedKey).inserted }
        return [apps.first(where: isLaunchpad) ?? makeLaunchpadTile()] + rest
    }

    /// 用户可编辑的部分（去掉启动台）。
    static func editableApps(_ apps: [DockTile]) -> [DockTile] {
        apps.filter { !isLaunchpad($0) }
    }

    /// 把可编辑部分写回完整数组（启动台自动补回首位）。
    ///
    /// - Parameter existing: 当前完整数组。用于把**已有的启动台条目原样搬回来**，
    ///   而不是现造一个新的（会丢掉 `GUID` / `book`）。
    static func apps(fromEditable editable: [DockTile], preserving existing: [DockTile] = []) -> [DockTile] {
        normalizedApps(existing.filter(isLaunchpad) + editable)
    }

    // MARK: - 图标

    /// 取文件图标。**不需要任何权限** —— `NSWorkspace.icon(forFile:)` 是公开 API。
    /// 取不到时退回一个通用图标，不让 UI 出现空洞。
    static func icon(forPath path: String, size: CGFloat = 48) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: size, height: size)
        return image
    }

    /// 条目的显示图标。找不到路径时用通用 App 图标。
    static func icon(for tile: DockTile, size: CGFloat = 48) -> NSImage {
        guard let path = filePath(of: tile) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return icon(forPath: path, size: size)
    }

    /// 把 `file:///Applications/X.app/` 还原成文件系统路径。
    static func filePath(of tile: DockTile) -> String? {
        guard let string = tile.fileURLString, let url = URL(string: string) else { return nil }
        guard url.isFileURL else { return nil }
        return url.path
    }

    /// 该条目对应的磁盘路径**现在是否还存在**。用来把"已删除的 App"标灰。
    static func isInstalled(_ tile: DockTile) -> Bool {
        guard let path = filePath(of: tile) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - 从磁盘上的 .app 造条目

    /// 从 `.app` 包路径造一个可写入的条目。读 `Info.plist` 拿显示名与 bundle id。
    static func tile(forAppAt path: String) -> DockTile? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard url.pathExtension == "app" else { return nil }
        guard let bundle = Bundle(url: url) else { return nil }
        let label = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return DockTile.makeFileTile(
            url: url,
            label: label,
            bundleIdentifier: bundle.bundleIdentifier
        )
    }
}

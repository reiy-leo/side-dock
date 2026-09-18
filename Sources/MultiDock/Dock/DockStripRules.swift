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

    // MARK: - 其他项（persistent-others：文件夹 / 堆栈，计划 §3.2）

    /// 其他项的归一化：按归一化键去重，保留顺序与原始字段。
    ///
    /// 与 `normalizedApps` 的区别是**不插入任何固定项** —— `persistent-others` 里没有
    /// 「必须存在」的条目（Finder 是系统隐式渲染的，启动台在 `persistent-apps` 里）。
    ///
    /// ⚠️ 这里刻意**没有**合成新文件夹 tile 的能力。`docs/spikes.md` 实验 8 实测：
    /// 自己拼的 `directory-tile` **不会被 Dock 认领**（Dock 不补 `GUID` / `book`，8 秒后仍没有），
    /// 而字段不全的形状会让 Dock 直接 **SIGABRT**（launchd 也不会自动把它拉回来）。
    /// 所以其他项在本 App 里只能「读进来 / 排序 / 移除」，不能新建 —— 详见 `docs/PLAN.md` §3.6。
    static func normalizedOthers(_ others: [DockTile]) -> [DockTile] {
        var seen = Set<String>()
        return others.filter { seen.insert($0.normalizedKey).inserted }
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

    /// 拖进来的路径**为什么不能**变成条目（`nil` = 可以）。
    ///
    /// 存在的意义是**不留静默失败**：早先版本把文件夹拖进编辑条会命中
    /// `tile(forAppAt:)` 的 `pathExtension == "app"` 判断，然后悄悄返回 nil ——
    /// 用户只看到"什么都没发生"，会以为程序坏了。
    ///
    /// ⚠️ 文件夹与普通文件**刻意返回原因、而不是尝试合成条目**：`docs/spikes.md` 实验 8 实测，
    /// 自拼的 `directory-tile` 不会被 Dock 认领，字段不全的形状还会让 Dock 直接 **SIGABRT**。
    /// 要加文件夹，正确做法是让用户在访达里自己拖到 Dock 上 —— Dock 会写完整条目
    /// （含 `book`），随后 `DockWatcher` 会把它回存进配置，之后就能在编辑器里排序/移除。
    static func rejectionReason(for path: String) -> DockItemRejection? {
        if path.hasSuffix(".app") { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .notAnApp
        }
        return isDirectory.boolValue ? .folder : .file
    }
}

/// 拖进来的路径不能被接受的原因（`DockStripRules.rejectionReason(for:)`）。
///
/// 每条都带**替代做法**，因为这不是"功能没做"，而是"这条路会破坏用户的 Dock"。
enum DockItemRejection: String, Sendable {
    case folder
    case file
    case notAnApp

    /// 给用户看的一句话。
    var message: String {
        switch self {
        case .folder:
            return "不在这里新建文件夹条目：实测 Dock 不会认领 App 自己拼的目录条目"
                + "（不补 GUID/book，字段不全时还会直接崩）。要加文件夹，"
                + "请直接在访达里把文件夹拖到 Dock 上 —— App 会自动把它记进当前桌面的配置，"
                + "之后就能在这里排序或移除。"
        case .file:
            return "不在这里新建普通文件条目，原因同上（实测 Dock 不认领）。请在访达里自己拖到 Dock 上。"
        case .notAnApp:
            return "只支持 .app 应用包。"
        }
    }
}

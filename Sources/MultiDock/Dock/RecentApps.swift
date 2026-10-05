import CoreFoundation
import Foundation

/// 「最近添加的应用」扫描器（2026-10-05 用户规格）。
///
/// 默认 Dock 的内容不再手工维护：显示 `/Applications` 与 `~/Applications`
/// 里**最新添加**（按修改时间排序）的前 N 个应用，N 可调（1...15，默认 10）。
///
/// 修改时间是用户点名的判据（"最新添加的应用（修改时间）"）；系统更新顺带刷新的
/// 系统 App 也会参与排序 —— 这是字面规格，是否排除系统 App 留给用户反馈。
enum RecentAppsScanner {

    /// 一条扫描结果（磁盘枚举与「整理成条目」解耦，后者可脱离文件系统单测）。
    struct AppEntry: Hashable, Sendable {
        let path: String
        let modificationDate: Date
        let label: String
        let bundleIdentifier: String?
    }

    /// 参与扫描的目录。用户家目录的 `~/Applications` 不存在时静默跳过。
    static var defaultDirectories: [URL] {
        var urls = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        if !NSHomeDirectory().isEmpty {
            urls.append(URL(fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true))
        }
        return urls
    }

    /// 扫描磁盘，返回最新的 `limit` 个应用条目。
    /// 应用包内部的子目录不递归；符号链接按其自身属性参与排序。
    static func scan(directories: [URL] = RecentAppsScanner.defaultDirectories, limit: Int) -> [DockTile] {
        topApps(from: enumerate(directories: directories), limit: limit)
    }

    /// 枚举目录下的 `.app` 包。
    static func enumerate(directories: [URL]) -> [AppEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        var entries: [AppEntry] = []
        for directory in directories {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: []
            )) ?? []
            for url in contents {
                guard url.pathExtension.lowercased() == "app" else { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let modified = values?.contentModificationDate ?? .distantPast
                guard let tile = DockStripRules.tile(forAppAt: url.path) else { continue }
                entries.append(AppEntry(
                    path: url.path,
                    modificationDate: modified,
                    label: tile.label,
                    bundleIdentifier: tile.bundleIdentifier
                ))
            }
        }
        return entries
    }

    /// 纯函数：按修改时间取最新的 `limit` 个并转成可写入条目。
    /// 同一时刻并列时按名字排，保证两次扫描结果稳定（指纹短路依赖稳定性）。
    static func topApps(from entries: [AppEntry], limit: Int) -> [DockTile] {
        let clamped = min(max(limit, 1), DockBar.maxApps)
        let sorted = entries.sorted { lhs, rhs in
            if lhs.modificationDate != rhs.modificationDate {
                return lhs.modificationDate > rhs.modificationDate
            }
            return lhs.label < rhs.label
        }
        return sorted.prefix(clamped).map { entry in
            DockTile.makeFileTile(
                url: URL(fileURLWithPath: entry.path, isDirectory: true),
                label: entry.label,
                bundleIdentifier: entry.bundleIdentifier
            )
        }
    }
}

/// 台前调度开关探测（零权限）。
///
/// macOS 14/15 上 Stage Manager 的开关存在 `com.apple.WindowManager` 的
/// `GloballyEnabled`（本机实测为 1）。它的最近使用窗口条固定在屏幕**左缘**，
/// Dock 栏的位置选项要据此排除左。
enum StageManagerStatus {
    static let domainName = "com.apple.WindowManager"
    static let enabledKey = "GloballyEnabled"

    /// `true` = 开启（避开左）；`false` = 关闭；`nil` = 读不到（视为未开启，三个位置都给）。
    static func isActive() -> Bool? {
        guard let raw = CFPreferencesCopyAppValue(
            enabledKey as CFString,
            domainName as CFString
        ) else { return nil }
        if let number = raw as? NSNumber { return number.boolValue }
        if let bool = raw as? Bool { return bool }
        return nil
    }
}

/// 一次环境读取（`AppState` 的 2 s 轮询快照）：台前调度开关 + 原生 Dock 方位。
/// 两者任一变化都要反映到设置页（位置选项避开左 / 附着-独立提示）。
struct EnvironmentReading: Equatable, Sendable {
    var stageManagerActive: Bool?
    var dockSide: SecondaryDockOrientation?
}

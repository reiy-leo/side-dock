import AppKit
import Foundation

/// 栏里的 App 在这台 Mac 上还找不找得到（2026-10-26，配置同步配套）。
///
/// 配置会从别的 Mac 同步过来，栏里难免有这台没装的 App。规则：
/// 1. 存的路径还在 → 照用；
/// 2. 路径没了 → 按 bundle ID 让 `NSWorkspace` 再找一次（App 换了位置、改了名）；
/// 3. 还找不到 → 次级条不画它、写原生 Dock 时跳过它（免得出问号图标），
///    **但配置里不删**——装回来就又出现了。编辑器照旧标灰。
///
/// 两个闭包都可注入：测试不碰真实磁盘与 Launch Services。
/// `AppState` 默认不带它（nil = 旧行为，不过滤）；真机由 `AppDelegate` 传 `.live`。
struct AppLocator {
    /// 路径是否存在。
    var fileExists: (String) -> Bool
    /// bundle ID → 这台 Mac 上该 App 的路径（找不到 = nil）。
    var applicationPath: (String) -> String?

    static var live: AppLocator {
        AppLocator(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            applicationPath: { bundleID in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
            }
        )
    }

    enum Presence: Equatable {
        /// 条目不指向本地文件（没有 `file://` URL），不归这里管，原样保留。
        case notAFile
        /// 存的路径还在。
        case atOriginalPath(String)
        /// 存的路径没了，按 bundle ID 找到了新位置。
        case relocated(String)
        /// 这台 Mac 上找不到。
        case missing
    }

    func presence(of tile: DockTile) -> Presence {
        guard let path = DockStripRules.filePath(of: tile) else { return .notAFile }
        if fileExists(path) { return .atOriginalPath(path) }
        if let bundleID = tile.bundleIdentifier, !bundleID.isEmpty,
           let found = applicationPath(bundleID), !found.isEmpty, fileExists(found) {
            return .relocated(found)
        }
        return .missing
    }

    /// 能打开的路径（原路径或按 bundle ID 找到的新路径）；找不到或不是文件条目 = nil。
    func resolvedPath(of tile: DockTile) -> String? {
        switch presence(of: tile) {
        case .atOriginalPath(let path), .relocated(let path): return path
        case .notAFile, .missing: return nil
        }
    }

    /// 写原生 Dock 前的过滤：找不到的跳过；换了位置的换成新路径的条目。
    ///
    /// ⚠️ 只做过滤，不造新形状（`docs/rules.md` 实验 8：自拼条目坏形状会让 Dock SIGABRT）。
    /// 换位置的条目用 `DockTile.makeFileTile` 重建——这正是编辑器每次「添加」写进 Dock 的同一形状，
    /// 沿用原条目的名字与 bundle ID。
    func writableApps(_ tiles: [DockTile]) -> (apps: [DockTile], skipped: [DockTile], relocated: Int) {
        var apps: [DockTile] = []
        var skipped: [DockTile] = []
        var relocated = 0
        for tile in tiles {
            switch presence(of: tile) {
            case .notAFile, .atOriginalPath:
                apps.append(tile)
            case .relocated(let path):
                relocated += 1
                apps.append(DockTile.makeFileTile(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    label: tile.label,
                    bundleIdentifier: tile.bundleIdentifier
                ))
            case .missing:
                skipped.append(tile)
            }
        }
        return (apps, skipped, relocated)
    }
}

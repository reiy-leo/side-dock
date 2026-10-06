import Foundation

/// 启动台（Launchpad）模块的公共模型与系统闸门。
///
/// **只在 macOS 26 以下有意义**（2026-10-06 用户规格）：26 起系统用「应用程序」取代了
/// 启动台，那份按文件夹编排的数据不复存在。启动台自己的数据库（SQLite）是唯一数据源，
/// 本 App **只读**它（零权限、零网络），不修改一个字节。
enum LaunchpadSupport {
    /// 有启动台的系统上界：26 起没有。
    static func hasLaunchpad(majorVersion: Int) -> Bool { majorVersion < 26 }

    static var currentMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    static var isSystemSupported: Bool { hasLaunchpad(majorVersion: currentMajorVersion) }
}

// MARK: - 数据库记录（`LaunchpadDatabase` 的产物）

/// `apps` 表里的一行：一个 App 的名称、bundle id 与定位用的 bookmark。
struct LaunchpadAppRecord: Hashable, Sendable {
    var title: String
    var bundleIdentifier: String
    /// CFURL bookmark（启动台自己存的定位数据，`book` 魔数开头）。解析见 `LaunchpadResolver`。
    var bookmark: Data?
}

/// 一个启动台文件夹：名称 + 按启动台屏幕顺序排列的 App。
///
/// 文件夹在数据库里是 `type = 2` 的条目；里面的 App 分页存放（`type = 3` 是页），
/// 读取时按「页序 → 页内序」串成一条列表 —— 与启动台里看到的顺序一致。
struct LaunchpadFolderRecord: Hashable, Sendable, Identifiable {
    var itemID: Int
    var name: String
    var apps: [LaunchpadAppRecord]

    var id: Int { itemID }
}

// MARK: - 展示 / 搬运模型（`LaunchpadResolver` 的产物）

/// 一个已尽量定位的启动台 App：拿到 `tile` 才能写进 Dock 栏。
struct LaunchpadApp: Hashable, Sendable {
    var title: String
    var bundleIdentifier: String
    /// 解析出的 `.app` 路径（bookmark 优先，bundle id 索引兜底）。nil = 定位不到。
    var path: String?
    /// 可写进 Dock 栏的条目（`DockStripRules.tile(forAppAt:)` 造的，与访达拖入同口径）。
    var tile: DockTile?

    var isResolved: Bool { tile != nil }
}

/// 一个可搬运的启动台文件夹。
struct LaunchpadFolder: Hashable, Sendable, Identifiable {
    var itemID: Int
    var name: String
    var apps: [LaunchpadApp]

    var id: Int { itemID }

    /// 能搬的（已定位）与搬不了的（磁盘上找不到 / 不是 .app 包）分开数 —— 操作前如实告知。
    var resolvedApps: [LaunchpadApp] { apps.filter(\.isResolved) }
    var unresolvedCount: Int { apps.count - resolvedApps.count }

    /// 显示名：标题为空时回落「未命名」（与启动台自己的显示口径一致）。
    var displayName: String { name.isEmpty ? L("未命名", "Untitled") : name }
}

/// 「启动台」页的数据状态。
enum LaunchpadStatus: Equatable, Sendable {
    case notLoaded
    /// 本机系统没有启动台（macOS 26+）。
    case unsupportedSystem
    /// 有启动台但读不到它的数据库（文件不存在 / 打不开 / 结构不认识）。值是给用户看的原因。
    case unavailable(String)
    case loaded
}

/// 启动台数据入口。**全部可注入**：测试不碰真实数据库、也不扫真实安装目录。
struct LaunchpadLoader: Sendable {
    var isSystemSupported: @Sendable () -> Bool
    var loadRecords: @Sendable () throws -> [LaunchpadFolderRecord]
    var resolve: @Sendable ([LaunchpadFolderRecord]) -> [LaunchpadFolder]

    static let live = LaunchpadLoader(
        isSystemSupported: { LaunchpadSupport.isSystemSupported },
        loadRecords: { try LaunchpadDatabase.loadFolders() },
        resolve: { LaunchpadResolver().resolve($0) }
    )
}

/// 「添加到 / 替换」这类操作的返回：一句话结果（直接显示在行下方）+ 是否算失败。
struct LaunchpadOperationOutcome: Equatable, Sendable {
    var message: String
    var failed: Bool
}

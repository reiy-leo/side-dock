import Foundation

/// 次级 Dock 条（Dock 栏）在屏幕上的位置（2026-10-05 用户规格）。
///
/// 台前调度开启时占掉屏幕**左缘**（最近使用窗口条固定在左侧，系统不提供换侧设置），
/// 所以可选位置要避开左 —— 「避开台前调度占用的那边，其他两边都可以用」。
enum DockBarPosition: String, Codable, Sendable, CaseIterable {
    case bottom
    case left
    case right

    var displayName: String {
        switch self {
        case .bottom: return "底部"
        case .left: return "左侧"
        case .right: return "右侧"
        }
    }

    /// 条自身的走向：底部配横条，侧边配竖条。
    var isBarVertical: Bool { self != .bottom }

    /// 可选位置（UI 呈现顺序）。台前调度开启时排除左。
    /// 只约束**设置入口**：已经存在、存着 `.left` 的栏不做运行时改写 ——
    /// 用户把台前调度关掉后这根栏应当原样可用。
    static func available(stageManagerActive: Bool) -> [DockBarPosition] {
        allCases.filter { !(stageManagerActive && $0 == .left) }
    }
}

/// 一根 Dock 栏（桌面 Tab 编辑的实体）：名字 + 屏幕位置 + 绑定的桌面 + 图标。
///
/// 与旧版「逐桌面 override」的关系：栏是**主实体**，通过 `spaceID` 指向一个桌面；
/// 没绑栏的桌面在冻结模式下只有原生 Dock（默认 Dock = 最近添加的应用）可看。
struct DockBar: Codable, Hashable, Sendable, Identifiable {
    /// 每栏最多图标数（用户规格：最多 15）。**2026-10-06 起没有下限**——栏不固定任何 App，
    /// 允许清空（空栏的次级条隐藏）。
    static let maxApps = 15
    /// 设置页编辑器默认露出的槽位数，超出走滚动。
    static let visibleSlots = 8

    var id = UUID()
    /// 栏名。与桌面命名同一口径（≤10 字素簇，`DesktopNaming.normalize`）。
    var name: String
    var position: DockBarPosition = .bottom
    /// 绑定的桌面（`"\(displayUUID)#\(spaceUUID)"`，与 `DesktopSpace.id` 同口径）。
    /// nil = 未绑定（条隐藏，运行时不占任何空间）。
    var spaceID: String?
    /// 图标内容（写入时由 `DockStripRules` 保证启动台在首；编辑器只编辑其余部分）。
    var apps: [DockTile] = []
    /// 迁移保留：旧版逐桌面 override 里的其他项（文件夹/堆栈）。
    /// 新 UI 不提供创建（实验 8：自拼目录条目 Dock 不认领、坏形状会崩）。
    var otherItems: [DockTile] = []

    init(
        id: UUID = UUID(),
        name: String,
        position: DockBarPosition = .bottom,
        spaceID: String? = nil,
        apps: [DockTile] = [],
        otherItems: [DockTile] = []
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.spaceID = spaceID
        self.apps = apps
        self.otherItems = otherItems
    }

    enum CodingKeys: String, CodingKey {
        case id, name, position, spaceID, apps, otherItems
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        position = try container.decodeIfPresent(DockBarPosition.self, forKey: .position) ?? .bottom
        spaceID = try container.decodeIfPresent(String.self, forKey: .spaceID) ?? nil
        apps = try container.decodeIfPresent([DockTile].self, forKey: .apps) ?? []
        otherItems = try container.decodeIfPresent([DockTile].self, forKey: .otherItems) ?? []
    }
}

/// Dock 栏的默认值与旧配置迁移。
enum DockBarCatalog {
    /// 首次载入新版配置时的默认栏数（用户规格：默认可以有 5 个）。
    static let defaultBarCount = 5

    /// 从旧版逐桌面 override 迁移出 Dock 栏：每条带 override 的绑定变一根栏，
    /// 名字沿用桌面的自定义名（没有就按顺序编「Dock N」），位置先落 `.bottom`。
    ///
    /// 图标数超过 `DockBar.maxApps` 时截断（旧配置理论上可塞任意多个）。
    static func migratedBars(from bindings: [DesktopBinding]) -> [DockBar] {
        var bars: [DockBar] = []
        for binding in bindings {
            guard let override = binding.override else { continue }
            let name = DesktopNaming.normalizedOrNil(binding.customName)
                ?? "Dock \(bars.count + 1)"
            bars.append(DockBar(
                name: name,
                position: .bottom,
                spaceID: binding.id,
                apps: Array(override.pinnedApps.prefix(DockBar.maxApps)),
                otherItems: override.otherItems
            ))
        }
        return bars
    }

    /// 补足到默认栏数（只在迁移时调用：键不存在的配置补齐；用户显式删光的不再补）。
    /// 新栏不绑定桌面、位置底部、名字避开已有名字。
    static func paddedToDefault(_ bars: [DockBar]) -> [DockBar] {
        guard bars.count < defaultBarCount else { return bars }
        var result = bars
        while result.count < defaultBarCount {
            let index = result.count + 1
            let name = uniqueName(base: "Dock \(index)", existing: result)
            result.append(DockBar(name: name))
        }
        return result
    }

    private static func uniqueName(base: String, existing: [DockBar]) -> String {
        let used = Set(existing.map(\.name))
        if !used.contains(base) { return base }
        var counter = 2
        while used.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }
}

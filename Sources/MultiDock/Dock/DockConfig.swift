import CoreFoundation
import Foundation

/// plist 值的可编码表示。
///
/// 计划原文写的是 `struct DockTile { var raw: [String: Any] }`，但 `[String: Any]` 不满足
/// `Codable`，无法落盘到 `config.json`。这里用一个受限的枚举把 plist 的合法类型全表示出来，
/// 同时提供与 `Any`（CFPreferences 的返回类型）的双向转换。
enum PlistValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case data(Data)
    case date(Date)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    init?(any: Any) {
        switch any {
        case let value as String:
            self = .string(value)
        case let value as Data:
            self = .data(value)
        case let value as Date:
            self = .date(value)
        case let value as NSNumber:
            // NSNumber 会把布尔也桥接成数字，必须用 CFTypeID 区分，否则 true 会变成 1。
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if CFNumberIsFloatType(value) {
                self = .double(value.doubleValue)
            } else {
                self = .int(value.intValue)
            }
        case let value as [Any]:
            self = .array(value.compactMap { PlistValue(any: $0) })
        case let value as [String: Any]:
            var dict: [String: PlistValue] = [:]
            for (key, raw) in value {
                guard let converted = PlistValue(any: raw) else { return nil }
                dict[key] = converted
            }
            self = .dictionary(dict)
        default:
            return nil
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .data(let v): return v
        case .date(let v): return v
        case .array(let v): return v.map(\.anyValue)
        case .dictionary(let v): return v.mapValues(\.anyValue)
        }
    }

    var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }
    var intValue: Int? { if case .int(let v) = self { return v } else { return nil } }
    var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    var boolValue: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    var dictionaryValue: [String: PlistValue]? { if case .dictionary(let v) = self { return v } else { return nil } }
    var arrayValue: [PlistValue]? { if case .array(let v) = self { return v } else { return nil } }

    /// 供归一化指纹使用的稳定字符串。
    var fingerprintToken: String {
        switch self {
        case .string(let v): return "s:\(v)"
        case .int(let v): return "i:\(v)"
        case .double(let v): return "d:\(v)"
        case .bool(let v): return "b:\(v)"
        case .data(let v): return "x:\(v.count)"
        case .date(let v): return "t:\(v.timeIntervalSince1970)"
        case .array(let v): return "[" + v.map(\.fingerprintToken).joined(separator: ",") + "]"
        case .dictionary(let v):
            return "{" + v.keys.sorted().map { "\($0)=\(v[$0]!.fingerprintToken)" }.joined(separator: ",") + "}"
        }
    }
}

/// Dock 上的一个图标/条目。字典原样保留，便于回写时不丢失 Dock 自己的字段。
struct DockTile: Codable, Hashable, Sendable {
    var raw: [String: PlistValue]

    init(raw: [String: PlistValue]) { self.raw = raw }

    init?(any: Any) {
        guard let value = PlistValue(any: any), let dict = value.dictionaryValue else { return nil }
        self.raw = dict
    }

    var anyValue: [String: Any] { raw.mapValues(\.anyValue) }

    var tileType: String { raw["tile-type"]?.stringValue ?? "" }
    var tileData: [String: PlistValue]? { raw["tile-data"]?.dictionaryValue }
    var label: String { tileData?["file-label"]?.stringValue ?? "" }
    var bundleIdentifier: String? { tileData?["bundle-identifier"]?.stringValue }

    var fileURLString: String? {
        tileData?["file-data"]?.dictionaryValue?["_CFURLString"]?.stringValue
    }

    var fileURL: URL? {
        guard let string = fileURLString else { return nil }
        return URL(string: string)
    }

    var isFolder: Bool { tileType == "directory-tile" }

    /// 归一化指纹用的稳定键。
    ///
    /// **只取这几个字段**，因此天然剔除了 Dock 每次重载都会重算的
    /// `GUID` / `file-mod-date` / `parent-mod-date` / `book`（计划 §3.8 要求）。
    var normalizedKey: String {
        let fileData = tileData?["file-data"]?.dictionaryValue
        let url = fileData?["_CFURLString"]?.stringValue ?? ""
        let urlType = fileData?["_CFURLStringType"]?.fingerprintToken ?? ""
        let label = tileData?["file-label"]?.stringValue ?? ""
        let bundle = tileData?["bundle-identifier"]?.stringValue ?? ""
        return "\(tileType)|\(url)|\(urlType)|\(label)|\(bundle)"
    }

    /// 按 Dock 的格式合成新条目。**不给 `GUID`**，让 Dock 自己分配（计划 §3.6）。
    ///
    /// - Parameter dockExtra: 真实域里**用户自己拖进来的** App 是 `true`，
    ///   系统自带项（启动台）是 `false`。默认按用户条目处理。
    static func makeFileTile(
        url: URL,
        label: String,
        bundleIdentifier: String?,
        fileType: Int = 41,
        dockExtra: Bool = true
    ) -> DockTile {
        let fileData: [String: PlistValue] = [
            "_CFURLString": .string(directoryURLString(for: url)),
            "_CFURLStringType": .int(15),
        ]
        var tileData: [String: PlistValue] = [
            "file-data": .dictionary(fileData),
            "file-label": .string(label),
            "dock-extra": .bool(dockExtra),
            "file-type": .int(fileType),
        ]
        if let bundleIdentifier {
            tileData["bundle-identifier"] = .string(bundleIdentifier)
        }
        return DockTile(raw: ["tile-type": .string("file-tile"), "tile-data": .dictionary(tileData)])
    }

    /// Dock 对 `.app` 包写的是**带尾斜杠**的目录 URL（`file:///Applications/X.app/`）。
    ///
    /// `URL(fileURLWithPath:).absoluteString` 不带尾斜杠，与真实域不一致；
    /// P0 的写入实验用的也是带尾斜杠的形式（`scripts/spike-reload.sh`）。
    static func directoryURLString(for url: URL) -> String {
        let absolute = url.absoluteString
        guard !absolute.hasSuffix("/") else { return absolute }
        return absolute + "/"
    }
}

/// 一套 Dock 配置：**只有内容**（图标 + 其他项）。
///
/// 2026-10-05 用户修订：大小 / 放大 / 自动隐藏 / 特效 / 最小化到应用等外观项**全部跟随系统**，
/// App 不再提供设置、也不再写入任何外观键（原 `DockAppearance` 已删除）。
/// 外观键只保留在**还原路径**上：退出还原 / 自愈仍会把基准快照里的外观键原样写回，
/// 兼容旧版本可能留下的改动（无痕原则的收尾）。
struct DockConfig: Codable, Hashable, Sendable {
    var pinnedApps: [DockTile] = []
    var otherItems: [DockTile] = []

    /// 归一化指纹（内容口径）。内容相同则整条应用流水线短路，**完全不重启 Dock**（计划 §3.4 第 2 条）。
    var fingerprint: String { fingerprint(restrictedTo: nil) }

    /// 只比较 `keys` 里的键（nil = 全部）。
    ///
    /// 写入后校验要用它：只比对实际写进去的键，避免"明明写成功了却判定失败"的假阴性。
    func fingerprint(restrictedTo keys: Set<String>?) -> String {
        var parts: [String] = ["apps:" + pinnedApps.map(\.normalizedKey).joined(separator: ">")]
        parts.append("others:" + otherItems.map(\.normalizedKey).joined(separator: ">"))
        if keys != nil {
            // 外观键已不再写入；`restrictedTo` 只会传入内容键，这里无需再过滤。
            // 保留参数形态是为了与 `DockController` 的校验口径共用一套签名。
        }
        return parts.joined(separator: "\n")
    }

    /// 从真实 Dock 域读取一套配置（「从当前 Dock 抓取」用）。只取内容键。
    static func read(from domain: [String: PlistValue]) -> DockConfig {
        var config = DockConfig()
        if let apps = domain["persistent-apps"]?.arrayValue {
            config.pinnedApps = apps.compactMap { $0.dictionaryValue.map(DockTile.init(raw:)) }
        }
        if let others = domain["persistent-others"]?.arrayValue {
            config.otherItems = others.compactMap { $0.dictionaryValue.map(DockTile.init(raw:)) }
        }
        return config
    }
}

/// 一个桌面与一套 Dock 配置的绑定关系（现在只承载**桌面命名**；Dock 内容由 `DockBar` 承载）。
struct DesktopBinding: Codable, Hashable, Sendable {
    var displayUUID: String
    var spaceUUID: String
    /// 仅存本地：macOS 15 没有桌面命名接口（计划 §1）。
    var customName: String?
    /// ⚠️ **已废弃（2026-10-05）**：逐桌面 Dock 由 `DockBar` 承载。这个字段只在
    /// 读取旧版 `config.json` 时用于迁移（迁进 `DockBar` 后立刻清空，不再写回）。
    var override: DockConfig?

    var id: String { "\(displayUUID)#\(spaceUUID)" }

    /// 绑定列表的**唯一**改法：改一条（不存在就插入），改完若没有名字了就删掉，不留空行。
    static func updating(
        _ bindings: [DesktopBinding],
        for space: DesktopSpace,
        _ mutate: (inout DesktopBinding) -> Void
    ) -> [DesktopBinding] {
        var result = bindings
        if let index = result.firstIndex(where: { $0.id == space.id }) {
            mutate(&result[index])
            if result[index].customName == nil {
                result.remove(at: index)
            }
            return result
        }
        var fresh = DesktopBinding(
            displayUUID: space.displayUUID,
            spaceUUID: space.spaceUUID,
            customName: nil,
            override: nil
        )
        mutate(&fresh)
        guard fresh.customName != nil else { return result }
        result.append(fresh)
        return result
    }
}

/// 菜单栏**左键**单击的行为。`⇧`+左键 = 切到上一个桌面是固定行为，不受这个设置影响
/// （但选了 `.openMenu` 时 `⇧`+左键也一并打开菜单，见 `MenuBarController`）。
enum ClickAction: String, Codable, Sendable, CaseIterable {
    /// 左键单击 = 切到下一个桌面（默认）。
    case nextDesktop
    /// 左键单击 = 打开菜单。
    case openMenu

    var displayName: String {
        switch self {
        case .nextDesktop: return "切换到下一个桌面"
        case .openMenu: return "打开菜单"
        }
    }
}

/// 桌面名称（切换提示）在屏幕上的摆放位置。水平恒居中，只选纵向档位（2026-10-06 用户规格）。
/// 默认 `.top` —— 与旧版「中上部」一致，也是 iPhone 锁屏时钟的位置。
enum DesktopNamePlacement: String, Codable, Sendable, CaseIterable {
    /// 可见区顶部往下一段距离（类 iPhone 锁屏）。
    case top
    /// 可见区正中。
    case middle
    /// 可见区底部往上一段距离。
    case bottom

    var displayName: String {
        switch self {
        case .top: return "顶部"
        case .middle: return "中部"
        case .bottom: return "底部"
        }
    }
}

/// Dock 重载方式。P0 结论：不存在热重载，主路径为 SIGHUP（约 101 ms 不可用）。
enum ReloadStrategy: String, Codable, Sendable, CaseIterable {
    /// 自动：SIGHUP 为主，SIGTERM + kickstart 兜底。
    case auto
    /// 强制走 SIGTERM + kickstart（约 395 ms）。
    case sigterm

    var displayName: String {
        switch self {
        case .auto: return "自动（SIGHUP，约 0.1 秒）"
        case .sigterm: return "SIGTERM 重启（约 0.4 秒）"
        }
    }
}

struct AppSettings: Codable, Hashable, Sendable {
    /// 退出时还原为基准 Dock。默认开（无痕原则）。
    var restoreOnQuit = true
    /// 左键单击行为。
    var clickAction: ClickAction = .nextDesktop
    /// 编辑后立即应用到真实 Dock。
    var autoApplyOnEdit = true
    /// 识别用户在真实 Dock 上的手动改动并回存。
    var autoCaptureUserEdits = true
    /// 重载方式。
    var reloadStrategy: ReloadStrategy = .auto
    /// 切换桌面时展示桌面名（2026-10-06 起为 iPhone 锁屏式大字，见 `DesktopNameOverlayWindow`）。
    var showToastOnDesktopSwitch = true
    /// 桌面名称的展示位置（顶部/中部/底部，水平恒居中）。默认顶部（类 iPhone 锁屏，同旧版「中上部」）。
    var desktopNamePlacement: DesktopNamePlacement = .top
    /// 次级 Dock 条：贴着原生 Dock 内侧半露、hover 滑出、随桌面秒换内容的自绘图标条。
    var showSecondaryDock = true
    /// 冻结原生 Dock 的逐桌面切换：开启后切桌面不再写偏好/重启 Dock，
    /// 逐桌面的差异全部由次级 Dock 条呈现（原生 Dock 保持一套固定配置 = 默认 Dock）。
    /// 手动路径（「立即应用」「编辑后立即应用」）不受影响。
    /// 默认开（2026-10-04 用户决定：原生 Dock 全桌面一致，不逐桌面重启）。
    var freezeNativeDockSwitching = true
    /// Dock 栏列表（桌面 Tab 编辑）。每栏可绑定一个桌面；没绑定栏的桌面在冻结模式下
    /// 只有原生 Dock（默认 Dock）可看。默认 5 栏由加载时的迁移/补齐逻辑保证。
    var dockBars: [DockBar] = []
    /// 菜单栏图标（Lucide 五选一，2026-10-06 用户规格）。换图标立即生效，不重启 Dock。
    var menuBarIcon: MenuBarIcon = .default
    /// 切相邻桌面时合成 ⌃←/⌃→ 以借系统过渡动画（2026-10-06 实验 28）。
    /// **默认关**：本机实测事件投递被系统拦下（阳性对照 Cmd+Tab 也不生效），开了也没动画，
    /// 只会让每次切换多等一次超时。留在 config 里是因为**换机器/系统放开后不用改代码**。
    /// ⚠️ 刻意**不做设置 UI**：能开也无效的开关就是假开关（项目规矩，见 D1/C7）。
    var animatedDesktopSwitch = false

    enum CodingKeys: String, CodingKey {
        case restoreOnQuit, clickAction, autoApplyOnEdit, autoCaptureUserEdits, reloadStrategy
        case showToastOnDesktopSwitch, desktopNamePlacement
        case showSecondaryDock, freezeNativeDockSwitching
        case dockBars, menuBarIcon, animatedDesktopSwitch
    }

    init() {}

    /// 手写解码，**每个字段都用 `decodeIfPresent` 兜默认值**。
    ///
    /// 必须这么做：合成的 `init(from:)` 遇到旧配置文件里缺的新键会直接抛错，
    /// 而 `ConfigStore.load()` 失败时返回的是**整份默认配置** —— 用户已有的设置会被静默清空。
    /// 以后每加一个字段，都在这里补一行。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        restoreOnQuit = try container.decodeIfPresent(Bool.self, forKey: .restoreOnQuit) ?? true
        clickAction = try container.decodeIfPresent(ClickAction.self, forKey: .clickAction) ?? .nextDesktop
        autoApplyOnEdit = try container.decodeIfPresent(Bool.self, forKey: .autoApplyOnEdit) ?? true
        autoCaptureUserEdits = try container.decodeIfPresent(Bool.self, forKey: .autoCaptureUserEdits) ?? true
        reloadStrategy = try container.decodeIfPresent(ReloadStrategy.self, forKey: .reloadStrategy) ?? .auto
        showToastOnDesktopSwitch =
            try container.decodeIfPresent(Bool.self, forKey: .showToastOnDesktopSwitch) ?? true
        desktopNamePlacement =
            try container.decodeIfPresent(DesktopNamePlacement.self, forKey: .desktopNamePlacement) ?? .top
        showSecondaryDock = try container.decodeIfPresent(Bool.self, forKey: .showSecondaryDock) ?? true
        freezeNativeDockSwitching =
            try container.decodeIfPresent(Bool.self, forKey: .freezeNativeDockSwitching) ?? true
        dockBars = try container.decodeIfPresent([DockBar].self, forKey: .dockBars) ?? []
        menuBarIcon = try container.decodeIfPresent(MenuBarIcon.self, forKey: .menuBarIcon) ?? .default
        animatedDesktopSwitch =
            try container.decodeIfPresent(Bool.self, forKey: .animatedDesktopSwitch) ?? false
    }
}

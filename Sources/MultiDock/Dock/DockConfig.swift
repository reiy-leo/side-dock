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
    static func makeFileTile(url: URL, label: String, bundleIdentifier: String?, fileType: Int = 41) -> DockTile {
        let fileData: [String: PlistValue] = [
            "_CFURLString": .string(url.absoluteString),
            "_CFURLStringType": .int(15),
        ]
        var tileData: [String: PlistValue] = [
            "file-data": .dictionary(fileData),
            "file-label": .string(label),
            "dock-extra": .bool(false),
            "file-type": .int(fileType),
        ]
        if let bundleIdentifier {
            tileData["bundle-identifier"] = .string(bundleIdentifier)
        }
        return DockTile(raw: ["tile-type": .string("file-tile"), "tile-data": .dictionary(tileData)])
    }
}

/// Dock 外观。只覆盖白名单里的键（计划 §3.2）。
struct DockAppearance: Codable, Hashable, Sendable {
    var orientation: String = "bottom"
    var tilesize: Double = 36
    var magnification: Bool = false
    var largesize: Double = 128
    var autohide: Bool = false
    var autohideDelay: Double?
    var autohideTimeModifier: Double?
    var mineffect: String = "genie"
    var minimizeToApplication: Bool = false
    var showProcessIndicators: Bool = false

    /// 与 `com.apple.dock` 的键名映射。**未设置的键（nil）不参与写入**，
    /// 避免把用户没配过的键强行写成默认值。
    var domainEntries: [String: PlistValue] {
        var entries: [String: PlistValue] = [
            "orientation": .string(orientation),
            "tilesize": .double(tilesize),
            "magnification": .bool(magnification),
            "largesize": .double(largesize),
            "autohide": .bool(autohide),
            "mineffect": .string(mineffect),
            "minimize-to-application": .bool(minimizeToApplication),
            "show-process-indicators": .bool(showProcessIndicators),
        ]
        if let autohideDelay { entries["autohide-delay"] = .double(autohideDelay) }
        if let autohideTimeModifier { entries["autohide-time-modifier"] = .double(autohideTimeModifier) }
        return entries
    }

    /// 从真实域读取，缺键则用默认值兜底。
    static func read(from domain: [String: PlistValue]) -> DockAppearance {
        var appearance = DockAppearance()
        if let v = domain["orientation"]?.stringValue { appearance.orientation = v }
        if let v = domain["tilesize"]?.doubleValue { appearance.tilesize = v }
        if let v = domain["magnification"]?.boolValue { appearance.magnification = v }
        if let v = domain["largesize"]?.doubleValue { appearance.largesize = v }
        if let v = domain["autohide"]?.boolValue { appearance.autohide = v }
        appearance.autohideDelay = domain["autohide-delay"]?.doubleValue
        appearance.autohideTimeModifier = domain["autohide-time-modifier"]?.doubleValue
        if let v = domain["mineffect"]?.stringValue { appearance.mineffect = v }
        if let v = domain["minimize-to-application"]?.boolValue { appearance.minimizeToApplication = v }
        if let v = domain["show-process-indicators"]?.boolValue { appearance.showProcessIndicators = v }
        return appearance
    }
}

/// 一套 Dock 配置：图标 + 外观。
struct DockConfig: Codable, Hashable, Sendable {
    var pinnedApps: [DockTile] = []
    var otherItems: [DockTile] = []
    var appearance = DockAppearance()

    /// 归一化指纹。内容相同则整条应用流水线短路，**完全不重启 Dock**（计划 §3.4 第 2 条）。
    var fingerprint: String {
        var parts: [String] = ["apps:" + pinnedApps.map(\.normalizedKey).joined(separator: ">")]
        parts.append("others:" + otherItems.map(\.normalizedKey).joined(separator: ">"))
        parts.append("appearance:" + appearance.domainEntries.keys.sorted()
            .map { "\($0)=\(appearance.domainEntries[$0]!.fingerprintToken)" }
            .joined(separator: ","))
        return parts.joined(separator: "\n")
    }

    /// 从真实 Dock 域读取一套配置（「从当前真实 Dock 抓取」用）。
    static func read(from domain: [String: PlistValue]) -> DockConfig {
        var config = DockConfig()
        if let apps = domain["persistent-apps"]?.arrayValue {
            config.pinnedApps = apps.compactMap { $0.dictionaryValue.map(DockTile.init(raw:)) }
        }
        if let others = domain["persistent-others"]?.arrayValue {
            config.otherItems = others.compactMap { $0.dictionaryValue.map(DockTile.init(raw:)) }
        }
        config.appearance = DockAppearance.read(from: domain)
        return config
    }
}

/// 一个桌面与一套 Dock 配置的绑定关系。
struct DesktopBinding: Codable, Hashable, Sendable {
    var displayUUID: String
    var spaceUUID: String
    /// 仅存本地：macOS 15 没有桌面命名接口（计划 §1）。
    var customName: String?
    /// nil = 沿用默认 Dock。
    var override: DockConfig?

    var id: String { "\(displayUUID)#\(spaceUUID)" }
}

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
}

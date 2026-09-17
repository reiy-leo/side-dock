import CoreFoundation
import Foundation

/// `com.apple.dock` 偏好域的读写。
///
/// 两条铁律（计划 §3.2 / §3.4）：
/// 1. **只覆盖白名单键**，其余键（热角、启动台网格、`recent-apps` 等）原样保留。
/// 2. **单次原子写**：读全量域 → 覆盖白名单键 → 一次性写回。绝不整域替换，
///    也不用 `defaults` 命令行逐条拼。
enum DockPreferences {

    /// 域名的字符串形式。`CFString` 不是 `Sendable`，所以这里只存 String，
    /// 用到时再转（转换很便宜，且避免静态可变全局量）。
    static let domainName = "com.apple.dock"

    static var domain: CFString { domainName as CFString }

    /// 参与读写比对的白名单键。
    ///
    /// 实测提醒：本机 `com.apple.dock` 的 34 个键里**没有** `show-process-indicators`、
    /// `autohide-delay`、`autohide-time-modifier`。这些键仍留在白名单里（用户一旦配置就要写），
    /// 但 P2 首次写入外观键时必须逐个实测确认键名在当前系统上有效。
    static let whitelistedKeys: Set<String> = [
        "persistent-apps",
        "persistent-others",
        "orientation",
        "tilesize",
        "magnification",
        "largesize",
        "autohide",
        "autohide-delay",
        "autohide-time-modifier",
        "mineffect",
        "minimize-to-application",
        "show-process-indicators",
    ]

    /// 明确排除、**永不写入**的键。
    static let excludedKeys: Set<String> = [
        "mru-spaces",            // 另有显式开关，且只在用户主动点击时才改
        "wvous-bl-corner", "wvous-bl-modifier",
        "wvous-br-corner", "wvous-br-modifier",
        "wvous-tl-corner", "wvous-tl-modifier",
        "wvous-tr-corner", "wvous-tr-modifier",
        "springboard-rows", "springboard-columns",
        "recent-apps",
        "mod-count",
        "version",
        "loc", "region",
        "trash-full",
        "ResetLaunchPad",
    ]

    /// 读全量域。Dock 不在白名单里的键也一并带回来，写回时原样保留。
    static func readDomain() -> [String: PlistValue] {
        guard let raw = CFPreferencesCopyMultiple(
            nil,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any] else { return [:] }

        var result: [String: PlistValue] = [:]
        for (key, value) in raw {
            if let converted = PlistValue(any: value) { result[key] = converted }
        }
        return result
    }

    /// 只读白名单键。
    static func readWhitelisted() -> [String: PlistValue] {
        readDomain().filter { whitelistedKeys.contains($0.key) }
    }

    /// 把 entries 覆盖到 domain 上，**只作用于白名单键**，其余键原样保留。
    ///
    /// 抽成纯函数是为了能脱离真实系统测试 —— 这是「除白名单键外无任何差异」这条验收标准的核心逻辑。
    static func merged(domain: [String: PlistValue], entries: [String: PlistValue]) -> [String: PlistValue] {
        var result = domain
        for (key, value) in entries where whitelistedKeys.contains(key) {
            result[key] = value
        }
        return result
    }

    /// 把配置覆盖到白名单键上并单次原子写回。
    ///
    /// - Parameter entries: 要覆盖的键值对。**只会作用于白名单内的键**，
    ///   传进来的非白名单键会被忽略（防止误伤）。
    /// - Returns: 实际写入的键数量。
    @discardableResult
    static func writeWhitelisted(_ entries: [String: PlistValue]) -> Int {
        let safeEntries = entries.filter { whitelistedKeys.contains($0.key) }
        guard !safeEntries.isEmpty else { return 0 }

        let mergedDomain = merged(domain: readDomain(), entries: safeEntries)
        let payload = mergedDomain.mapValues(\.anyValue) as CFDictionary
        CFPreferencesSetMultiple(
            payload,
            nil,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesAppSynchronize(domain)
        return safeEntries.count
    }

    /// 导出全量域为 plist 数据（基准快照 / 备份用）。
    static func exportDomainData() -> Data? {
        var payload: [String: Any] = [:]
        for (key, value) in readDomain() { payload[key] = value.anyValue }
        return try? PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    }

    // MARK: - 白名单之外：唯一的两个例外

    /// 「根据最近使用自动重新排列空间」。本机默认 `1`（开），会打乱桌面顺序、
    /// 破坏「切到下一个桌面」的直觉（`docs/PLAN.md` §1 的当前风险项）。
    static let mruSpacesKey = "mru-spaces"

    /// 读 `mru-spaces`。域里没有这个键时返回 nil —— UI 据此显示"本机不支持"，而不是做一个没反应的开关。
    static func readMRUSpaces() -> Bool? {
        readDomain()[mruSpacesKey]?.boolValue
    }

    /// 写 `mru-spaces`。
    ///
    /// ⚠️ **这是白名单之外唯一的写入路径**，刻意只认这一个键，而不是开放一个
    /// `writeExplicit(key:value:)` 通用口子 —— 通用口子迟早会被误用到热角、启动台网格、
    /// `recent-apps` 上，那些键改坏了用户是能感觉到的。要再加键，请再加一个同样窄的方法。
    ///
    /// 只在设置页的显式开关里调用（用户主动点击才改）。调用方负责重启 Dock 让改动生效。
    @discardableResult
    static func writeMRUSpaces(_ enabled: Bool) -> Bool {
        let payload: CFDictionary = [mruSpacesKey: PlistValue.bool(enabled).anyValue] as CFDictionary
        CFPreferencesSetMultiple(payload, nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesAppSynchronize(domain)
        // 读回确认。写不进去（例如被 MDM 管住）时返回 false，UI 才能如实报错而不是假装成功。
        return readMRUSpaces() == enabled
    }
}

import AppKit
import CoreGraphics

/// 显示器名解析：把 SkyLight 的 `displayUUID` 映射成用户看得懂的显示器名。
///
/// 为什么需要它：多显示器时 `DesktopSpace.id` 是 `(displayUUID, spaceUUID)`（`docs/PLAN.md` §1），
/// 桌面页若只按顺序列出桌面，用户看不出哪个桌面在哪台屏上 —— 计划 §3.7 要求列表里带**显示器名**。
///
/// 映射关系本身是实测成立的（`AGENTS.md` §4）：`CGDisplayCreateUUIDFromDisplayID` 的结果与
/// SkyLight 的 `Display Identifier` **逐字符相同**。这里沿用 toast 定位的同一套换算。
///
/// 结构上刻意拆两半：**纯解析**（`name(for:screens:)` / `displayName(for:screens:)`）不碰 AppKit，
/// 可以脱离真实显示器单测；取屏幕列表（`currentScreens()`）才碰 `NSScreen`。
enum ScreenNaming {

    /// 一台显示器的最小描述。抽出来是为了让解析逻辑能单测。
    struct Screen: Equatable, Sendable, Identifiable {
        /// SkyLight 的 `Display Identifier`，与 `CGDisplayCreateUUIDFromDisplayID` 一致。
        let uuid: String
        /// `NSScreen.localizedName`，例如「内建视网膜显示器」。
        let name: String

        var id: String { uuid }
    }

    /// 按 `displayUUID` 找显示器名；映射不到返回 nil。
    ///
    /// 大小写不敏感比较：两边目前都是大写，但一个来自 SkyLight、一个来自 CoreGraphics，
    /// 比较时放宽一档更稳。
    static func name(for displayUUID: String, screens: [Screen]) -> String? {
        screens.first { $0.uuid.caseInsensitiveCompare(displayUUID) == .orderedSame }?.name
    }

    /// 显示文案：映射不到时**不撒谎** —— 直接说明未识别并给出 UUID 前 8 位，
    /// 方便用户照调试面板核对，而不是显示一个错的显示器名。
    static func displayName(for displayUUID: String, screens: [Screen]) -> String {
        if let name = name(for: displayUUID, screens: screens) { return name }
        if displayUUID.isEmpty { return "未知显示器" }
        return "未识别显示器（\(displayUUID.prefix(8))…）"
    }

    /// 当前接的所有显示器，与 `NSScreen.screens` 同序（主屏在最前）。
    @MainActor
    static func currentScreens() -> [Screen] {
        NSScreen.screens.compactMap { screen in
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
            else { return nil }
            return Screen(uuid: CFUUIDCreateString(nil, uuid) as String, name: screen.localizedName)
        }
    }
}
import Foundation

/// 桌面命名规则（`docs/PLAN.md` §3.10）。
///
/// 名字**只存在本地** `config.json`：macOS 15 的空间字典里没有名称字段（P0 实测），写不回系统。
/// 改名与 Dock 绑定解耦 —— `customName` 与 `override` 互不影响。
enum DesktopNaming {

    /// 长度上限，**按字素簇计**：中文算 1 个，`👍🏽` 也算 1 个。
    /// 用户说的「字符」是眼里看到的字，不是 UTF-8 字节也不是 UTF-16 码元。
    static let maxLength = 10

    /// 归一化：换行折成空格 → 去掉首尾空白 → 按字素簇截断。
    ///
    /// 输入框提交时与加载配置时都要过这一道，手改 `config.json` 塞进超长名也撑不破布局。
    static func normalize(_ raw: String) -> String {
        // CRLF 先处理，否则会被折成两个空格。
        let flattened = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let trimmed = flattened.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(maxLength))
    }

    /// 归一化后为空 = 没有自定义名 → 回落「桌面 N」。
    static func normalizedOrNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = normalize(raw)
        return name.isEmpty ? nil : name
    }

    /// 桌面显示名：有自定义名用自定义名，否则回落 `DesktopSpace.displayName`（「桌面 N」）。
    ///
    /// 这是**唯一的解析入口** —— 菜单栏、下拉菜单、设置页、调试面板、toast 全都走它，
    /// 否则会出现「菜单栏和设置页名字不一样」。
    static func displayName(for space: DesktopSpace, bindings: [DesktopBinding]) -> String {
        customName(for: space, bindings: bindings) ?? space.displayName
    }

    static func customName(for space: DesktopSpace, bindings: [DesktopBinding]) -> String? {
        bindings.first { $0.id == space.id }.flatMap { normalizedOrNil($0.customName) }
    }

    /// 改名。**只动 `customName`，绝不碰 `override`**。
    /// 名字清空且该桌面没有 Dock override 时删掉整条绑定，不留空行。
    ///
    /// 插入/清理规则统一由 `DesktopBinding.updating` 负责（与改 Dock 共用一套）。
    static func updatingBindings(
        _ bindings: [DesktopBinding],
        name raw: String,
        for space: DesktopSpace
    ) -> [DesktopBinding] {
        let name = normalizedOrNil(raw)
        return DesktopBinding.updating(bindings, for: space) { $0.customName = name }
    }

    /// 改 Dock override。**只动 `override`，绝不碰 `customName`**。
    ///
    /// - Parameter config: nil = 该桌面「沿用默认 Dock」。
    static func updatingBindings(
        _ bindings: [DesktopBinding],
        override config: DockConfig?,
        for space: DesktopSpace
    ) -> [DesktopBinding] {
        DesktopBinding.updating(bindings, for: space) { $0.override = config }
    }

    /// 加载配置后统一归一化一遍：截断超长名，并清掉「既无名字又无 override」的空绑定。
    static func normalizedBindings(_ bindings: [DesktopBinding]) -> [DesktopBinding] {
        var result: [DesktopBinding] = []
        for var binding in bindings {
            binding.customName = normalizedOrNil(binding.customName)
            if binding.customName == nil, binding.override == nil { continue }
            result.append(binding)
        }
        return result
    }
}

import Foundation

/// 界面语言（2026-10-06 用户规格：支持中文、英文）。
enum AppLanguage: String, Sendable {
    case zh
    case en
}

/// 双语文字取一 + 语言解析。
///
/// **用法**：`L("中文原文", "English text")` —— 两种语言都写在调用点上，不建 key 表：
/// 编译器保证两边都写了，永远不会出现「查表落空、英文界面里冒出中文」的半吊子状态。
/// 带插值也照写（两侧各自插值，取其一）：
/// `L("已添加「\(name)」", "Added “\(name)”")` —— 插值表达式要**无副作用**，因为它会被求值两次。
///
/// **语言怎么定**：跟随系统（macOS 13+ 的「系统设置 → 通用 → 语言与地区 → 应用程序」
/// 里也能给本 App 单独指定，系统会改 `AppleLanguages`）。打包后的 App 读
/// `Bundle.main.preferredLocalizations` —— `Support/Info.plist` 声明了
/// `CFBundleLocalizations = [en, zh-Hans]`，实测能正确反映系统语言与 per-app 设置
/// （`scripts/lang-probe` 式探针验证过：中文系统 → `zh-Hans`、英文/其它语言 → `en`）。
///
/// **默认中文**：没有本地化元数据的场景（`swift test`、直接跑二进制）一律中文 ——
/// 测试断言与 `docs/` 里的 grep 判据全部基于中文，不能被运行环境偷改。
/// 改语言后需要重启 App 生效（系统对 per-app 语言也是这个要求）。
enum L10n {
    private static let lock = NSLock()
    /// 当前界面语言。App 启动时经 `applySystemLanguage()` 写入；测试默认不碰它（= 中文）。
    nonisolated(unsafe) private static var current: AppLanguage = .zh

    static var language: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            current = newValue
        }
    }

    /// 由本地化偏好解析语言（纯函数，可单测）。
    ///
    /// 规则：**不声明中英文的包（测试、裸二进制）恒中文**；声明了的包只看第一偏好 ——
    /// 以 `zh` 开头取中文，其余一律英文（`Info.plist` 的开发区域是 en，
    /// 非中英文系统拿到的第一偏好就是 `en`，见 `docs/rules.md`「双语支持的新坑」）。
    static func resolvedLanguage(
        declaredLocalizations: [String],
        preferredLocalizations: [String]
    ) -> AppLanguage {
        let declaresChineseOrEnglish = declaredLocalizations.contains {
            $0.hasPrefix("en") || $0.hasPrefix("zh")
        }
        guard declaresChineseOrEnglish else { return .zh }
        guard let first = preferredLocalizations.first?.lowercased() else { return .zh }
        return first.hasPrefix("zh") ? .zh : .en
    }

    /// 启动时调用一次。返回解析结果（方便日志与排查「语言怎么没切」）。
    @discardableResult
    static func applySystemLanguage(bundle: Bundle = .main) -> AppLanguage {
        let resolved = resolvedLanguage(
            declaredLocalizations: bundle.localizations,
            preferredLocalizations: bundle.preferredLocalizations
        )
        language = resolved
        return resolved
    }

    /// 双语取一。`language` 默认取当前语言；显式传入便于单测。
    static func text(_ zh: String, _ en: String, language: AppLanguage? = nil) -> String {
        (language ?? self.language) == .en ? en : zh
    }
}

/// 界面文案的短名：`L("中文", "English")`。完整规则见 `L10n`。
@inline(__always)
func L(_ zh: String, _ en: String) -> String {
    L10n.text(zh, en)
}

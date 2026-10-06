import ApplicationServices
import CoreGraphics
import Foundation

/// 相邻桌面的「带动画切换」：借系统快捷键（⌃← / ⌃→）的过渡动画。
///
/// ## ⚠️ 2026-10-06 实测结论：**本机这条通道是关着的**（实验 28）
///
/// 完整探针（`scripts/spike-animated-switch.swift`）测出的事实，比实验 7.6 更精确：
///
/// | 观测 | 结果 |
/// | --- | --- |
/// | `AXIsProcessTrusted()` | **true**（辅助功能已授权） |
/// | `CGPreflightPostEventAccess()` | **true** |
/// | `CGEventSource(stateID: .hidSystemState)` | 创建成功 |
/// | 合成 ⌃→ | **空间不切**（1.5 s 无变化） |
/// | **阳性对照**：合成 Cmd+Tab | **前台 App 不变** |
/// | 替代路：AppleScript `key code 124 using control down` | `-1743` 未授权 Apple Events |
///
/// → **不是权限、不是 tap、不是参数**：事件在**投递层**被系统拦下（与实验 7.6 同源），
/// 且这条闸门在 macOS 15.8.1 上依旧存在。实验 7.6 把它归因于"权限"是**不准确的** ——
/// 授权后仍然不通。**加动画的需求在可预见的路径上无解**，除非走 `SLSWillSwitchSpaces`
/// 那类内部通道（实验 7 已判定：段错误风险，不做）。
///
/// ## 那这份实现为什么还在
///
/// 因为它是**唯一正确的那条路**（如果哪天系统的投递闸门放开，合成 ⌃←/⌃→ 就是与用户按键盘
/// 完全等价的入口，过渡动画由 WindowServer 给）。所以：
/// - **默认关闭**（`SpaceStepSynthesisSettings.isEnabled`，config 里的用户开关）；
/// - 打开后仍然**带超时兜底**：合成没生效就回硬切，**绝不会卡住不切**（`SpaceSwitcher`）；
/// - 用户开关的价值是"等我换台机器/等系统放开之后不用改代码"。
///
/// **语义边界**：合成只能表达「系统顺序上的相邻一步」。跨桌面点选（菜单里直接选某个桌面）
/// 与两端循环（系统键盘在首/尾不循环）仍走硬切 —— 见 `SpaceSwitcher`。
@MainActor
protocol SpaceStepSynthesizing: AnyObject {
    /// 辅助功能权限是否已授予（未授予时合成不会有任何效果）。
    var isPermitted: Bool { get }
    /// 合成一次相邻切换。返回「事件已投递」，**不代表**系统真的切了（由调用方确认）。
    @discardableResult
    func synthesizeStep(previous: Bool) -> Bool
}

/// 真实实现：`CGEventPost` 合成 ⌃← / ⌃→。
@MainActor
final class HotKeySpaceStepSynthesizer: SpaceStepSynthesizing {

    var isPermitted: Bool { AccessibilityPermission.isGranted }

    @discardableResult
    func synthesizeStep(previous: Bool) -> Bool {
        guard isPermitted else { return false }
        // 与系统热键表对齐：79 = ⌃←（keycode 123），81 = ⌃→（keycode 124）。
        let key: CGKeyCode = previous ? 123 : 124
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

/// 辅助功能权限（合成键盘事件所需）。
enum AccessibilityPermission {
    /// 是否已授权。**只读检查，不弹窗** —— 适合在每次切换前调用。
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// 弹系统引导（首次调用会让「系统设置 → 隐私与安全性 → 辅助功能」把本 App 列进去）。
    /// 用户点过之后系统不再重复弹；状态变化需要用户去系统设置里勾选。
    ///
    /// 键名写字面量：`kAXTrustedCheckOptionPrompt` 是 C 可变全局，Swift 6 严格并发下
    /// 直接引用报错（"not concurrency-safe"）。实测量出的键就是 `AXTrustedCheckOptionPrompt`。
    static func requestPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

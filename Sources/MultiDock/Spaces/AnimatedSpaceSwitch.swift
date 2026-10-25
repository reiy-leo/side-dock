import ApplicationServices
import CoreGraphics
import Foundation

/// 「带动画切换桌面」：借系统 Mission Control 快捷键的过渡动画（2026-10-25 用户规格，设置里可选开启）。
///
/// ## 两种快捷键
///
/// | 情形 | 快捷键（`com.apple.symbolichotkeys` id） | 说明 |
/// | --- | --- | --- |
/// | 相邻一步（左/右一个桌面） | 79 = 向左一个空间（⌃←）、81 = 向右（⌃→） | 系统默认开启 |
/// | 跨桌面 / 首尾循环 | 118…133 = 切换到桌面 1…16 | 1–9 默认 ⌃1–⌃9 但**默认关**；10–16 需用户自己设键 |
///
/// 「切换到桌面 N」**一次直接滑过去**、只播一段动画 —— 所以从桌面 10 回桌面 1 不用连按 9 次。
/// 对应的快捷键没开 → 不合成，直接回硬切。**只读** `com.apple.symbolichotkeys`，从不写（无痕）。
///
/// ## ⚠️ 实验 28 失败的真正原因（2026-10-25 复盘，待真机确认）
///
/// 实验 28 读到 79/81 的参数是 `[65535, 123/124, 8650752]`：`8650752 = 0x840000`
/// = **Control（0x40000）+ SecondaryFn（0x800000）**。方向键在实体键盘上天生带 fn 标志，
/// 系统热键表也按这个组合登记；而当时合成的事件**只带了 `.maskControl`** → 热键匹配不上 →
/// 「事件投递了但空间不动」。阳性对照 Cmd+Tab 本身就不响应合成事件，不能当对照。
/// 现在按热键表登记的**原样修饰键**合成（并先后补发修饰键按下/抬起），不再自己拼。
///
/// 任何一步没生效都有**超时兜底硬切**（`SpaceSwitcher`），绝不会卡住不切。
@MainActor
protocol SpaceStepSynthesizing: AnyObject {
    /// 辅助功能权限是否已授予（未授予时合成不会有任何效果）。
    var isPermitted: Bool { get }
    /// 合成一次相邻切换（⌃← / ⌃→）。返回「事件已投递」，**不代表**系统真的切了（由调用方确认）；
    /// 对应快捷键在系统里关着时返回 false（调用方直接硬切，不白等超时）。
    @discardableResult
    func synthesizeStep(previous: Bool) -> Bool
    /// 「切换到桌面 N」快捷键是否可用（N 从 1 起，≤16）。
    func canJump(toDesktop number: Int) -> Bool
    /// 合成「切换到桌面 N」。语义同 `synthesizeStep`。
    @discardableResult
    func synthesizeJump(toDesktop number: Int) -> Bool
}

extension SpaceStepSynthesizing {
    func canJump(toDesktop number: Int) -> Bool { false }
    @discardableResult
    func synthesizeJump(toDesktop number: Int) -> Bool { false }
}

// MARK: - 系统快捷键表（只读）

/// 系统热键表里的一条快捷键。
struct SymbolicHotKey: Equatable, Sendable {
    let keyCode: CGKeyCode
    /// 热键表登记的修饰键位（与 `CGEventFlags.rawValue` 同位布局）。
    let modifiers: UInt64

    var eventFlags: CGEventFlags {
        // 只保留设备无关的修饰位（高 16 位）。
        CGEventFlags(rawValue: modifiers & 0xFFFF_0000)
    }
}

/// 桌面切换相关的系统快捷键。
enum SpaceShortcut: Equatable, Sendable {
    case step(previous: Bool)
    case desktop(Int)

    /// 「切换到桌面 N」的上限（Mission Control 每块屏最多 16 个桌面）。
    static let maxDesktopNumber = 16

    /// `com.apple.symbolichotkeys` 里的 id。
    var hotKeyID: Int? {
        switch self {
        case .step(let previous):
            return previous ? 79 : 81
        case .desktop(let number):
            guard (1...Self.maxDesktopNumber).contains(number) else { return nil }
            return 117 + number
        }
    }
}

enum SymbolicHotKeys {
    static let domain = "com.apple.symbolichotkeys"
    static let tableKey = "AppleSymbolicHotKeys"

    /// 从热键表里解析一条：**必须 enabled、且有真实键码**（65535 = 没设键）。纯函数，便于测试。
    static func parse(_ table: [String: Any], id: Int) -> SymbolicHotKey? {
        guard let entry = table[String(id)] as? [String: Any] else { return nil }
        guard boolValue(entry["enabled"]) == true else { return nil }
        guard
            let value = entry["value"] as? [String: Any],
            let parameters = value["parameters"] as? [Any],
            parameters.count >= 3,
            let keyCode = intValue(parameters[1]),
            let modifiers = intValue(parameters[2]),
            keyCode >= 0, keyCode != 65535, modifiers >= 0
        else { return nil }
        return SymbolicHotKey(keyCode: CGKeyCode(keyCode), modifiers: UInt64(modifiers))
    }

    /// 读当前系统热键表（每次现读：用户可能刚在系统设置里改过）。
    static func currentTable() -> [String: Any] {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(tableKey as CFString, domain as CFString) as? [String: Any] ?? [:]
    }

    static func hotKey(for shortcut: SpaceShortcut, table: [String: Any]? = nil) -> SymbolicHotKey? {
        guard let id = shortcut.hotKeyID else { return nil }
        return parse(table ?? currentTable(), id: id)
    }

    private static func boolValue(_ any: Any?) -> Bool? {
        if let bool = any as? Bool { return bool }
        if let number = any as? NSNumber { return number.boolValue }
        return nil
    }

    private static func intValue(_ any: Any) -> Int? {
        if let int = any as? Int { return int }
        if let number = any as? NSNumber { return number.intValue }
        return nil
    }
}

/// 设置页用的就绪状态：权限 + 快捷键开没开。
struct AnimatedSwitchReadiness: Equatable {
    var accessibilityGranted: Bool
    /// ⌃← 与 ⌃→ 都开着。
    var stepKeysEnabled: Bool
    /// 现有桌面里（最多 16 个）已开「切换到桌面 N」的个数。
    var jumpKeysEnabled: Int
    /// 参与统计的桌面数（`min(桌面数, 16)`）。
    var jumpKeysNeeded: Int

    static func current(desktopCount: Int) -> AnimatedSwitchReadiness {
        let table = SymbolicHotKeys.currentTable()
        let needed = min(desktopCount, SpaceShortcut.maxDesktopNumber)
        let enabled = needed > 0
            ? (1...needed).filter { SymbolicHotKeys.hotKey(for: .desktop($0), table: table) != nil }.count
            : 0
        return AnimatedSwitchReadiness(
            accessibilityGranted: AccessibilityPermission.isGranted,
            stepKeysEnabled: SymbolicHotKeys.hotKey(for: .step(previous: true), table: table) != nil
                && SymbolicHotKeys.hotKey(for: .step(previous: false), table: table) != nil,
            jumpKeysEnabled: enabled,
            jumpKeysNeeded: needed
        )
    }
}

// MARK: - 真实合成器

/// 真实实现：按系统热键表登记的键与修饰键 `CGEventPost` 合成。
@MainActor
final class HotKeySpaceStepSynthesizer: SpaceStepSynthesizing {

    var isPermitted: Bool { AccessibilityPermission.isGranted }

    @discardableResult
    func synthesizeStep(previous: Bool) -> Bool {
        post(.step(previous: previous))
    }

    func canJump(toDesktop number: Int) -> Bool {
        SymbolicHotKeys.hotKey(for: .desktop(number)) != nil
    }

    @discardableResult
    func synthesizeJump(toDesktop number: Int) -> Bool {
        post(.desktop(number))
    }

    /// 修饰键 → 左侧实体键的键码（补发按下/抬起，让热键匹配与真按一致）。
    private static let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
        (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55),
    ]

    private func post(_ shortcut: SpaceShortcut) -> Bool {
        guard isPermitted, let hotKey = SymbolicHotKeys.hotKey(for: shortcut) else { return false }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let flags = hotKey.eventFlags
        let modifiers = Self.modifierKeys.filter { flags.contains($0.0) }

        var events: [CGEvent] = []
        var held: CGEventFlags = []
        for (flag, code) in modifiers {
            held.insert(flag)
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { return false }
            event.flags = held
            events.append(event)
        }
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: hotKey.keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: hotKey.keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        events.append(down)
        events.append(up)
        for (flag, code) in modifiers.reversed() {
            held.remove(flag)
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
            event.flags = held
            events.append(event)
        }
        events.forEach { $0.post(tap: .cghidEventTap) }
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

    /// 系统设置 → 隐私与安全性 → 辅助功能。
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    /// 系统设置 → 键盘（快捷键 → 调度中心在里面）。
    static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}

import CoreFoundation
import Foundation

/// 台前调度开关探测（零权限）。
///
/// macOS 14/15 上 Stage Manager 的开关存在 `com.apple.WindowManager` 的
/// `GloballyEnabled`（本机实测为 1）。它的最近使用窗口条固定在屏幕**左缘**，
/// Dock 栏的位置选项要据此排除左。
///
/// （2026-10-06 自 `RecentApps.swift` 迁来 —— 那份文件随「最近添加的应用」扫描器一起删除。）
enum StageManagerStatus {
    static let domainName = "com.apple.WindowManager"
    static let enabledKey = "GloballyEnabled"

    /// `true` = 开启（避开左）；`false` = 关闭；`nil` = 读不到（视为未开启，三个位置都给）。
    static func isActive() -> Bool? {
        // 先同步：长驻进程里 CFPreferences 会缓存别的域，用户在控制中心开关台前调度后
        // 不同步就一直读到旧值（2026-10-24「台前调度那边没灰」排查）。
        CFPreferencesAppSynchronize(domainName as CFString)
        guard let raw = CFPreferencesCopyAppValue(
            enabledKey as CFString,
            domainName as CFString
        ) else { return nil }
        if let number = raw as? NSNumber { return number.boolValue }
        if let bool = raw as? Bool { return bool }
        return nil
    }
}

/// 一次环境读取（`AppState` 的 2 s 轮询快照）：台前调度开关 + 原生 Dock 方位。
/// 两者任一变化都要反映到设置页（位置选项避开左 / 附着-独立提示）。
struct EnvironmentReading: Equatable, Sendable {
    var stageManagerActive: Bool?
    var dockSide: SecondaryDockOrientation?
}

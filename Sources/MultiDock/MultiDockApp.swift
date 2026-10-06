import AppKit

/// 程序入口。
///
/// 直接用 `NSApplication` 而不是 SwiftUI 的 `App` + `MenuBarExtra`：
/// 硬约束要求「左键单击 = 切下一个桌面，⇧+左键 = 切上一个桌面，右键 / ⌥+左键 = 下拉菜单」，
/// 而 `MenuBarExtra` 无法区分左右键。详见 `UI/MenuBarController.swift`。
///
/// 设置窗口与调试面板仍然是 SwiftUI，通过 `NSHostingController` 承载。
@main
@MainActor
enum MultiDockMain {

    /// `NSApplication.delegate` 是 **weak** 引用，必须由我们持有强引用，
    /// 否则 delegate 会在 `app.run()` 之前就被释放，App 起来后什么都不响应。
    private static let delegate = AppDelegate()

    static func main() {
        // 界面语言（2026-10-06）：跟随系统解析一次，之后所有 `L("中文", "English")`
        // 都按它取。必须在任何 UI 构造之前——`AppState` 的默认文案在实例化时就求值了。
        L10n.applySystemLanguage()
        let app = NSApplication.shared
        app.delegate = delegate
        // 菜单栏 App：不在 Dock 里显示图标、没有主窗口。
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

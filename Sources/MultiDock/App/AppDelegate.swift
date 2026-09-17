import AppKit
import SwiftUI

/// AppKit 委托：组装状态、菜单栏、窗口，并把退出流程交给 `LifecycleController`。
///
/// 这里用 AppKit 而不是纯 SwiftUI 场景，原因见 `MenuBarController` 的注释：
/// 硬约束要求区分左右键点击，`MenuBarExtra` 做不到。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var state: AppState!
    private var lifecycle: LifecycleController!
    private var menuBar: MenuBarController!

    private var debugWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var powerOffObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        self.state = state

        lifecycle = LifecycleController(state: state)
        menuBar = MenuBarController(state: state)
        menuBar.onOpenDebugPanel = { [weak self] in self?.showDebugPanel() }
        menuBar.onOpenSettings = { [weak self] in self?.showSettings() }
        menuBar.onQuit = { NSApp.terminate(nil) }

        lifecycle.applicationDidFinishLaunching()
        observePowerOff()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycle.applicationWillTerminate()
        if let token = powerOffObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    /// 退出流程：还原未完成前不放行（计划 §3.3）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecycle.shouldTerminate() ? .terminateNow : .terminateLater
    }

    /// 注销/关机同样要走还原路径。
    private func observePowerOff() {
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lifecycle.systemWillPowerOff()
            }
        }
    }

    // MARK: - 窗口

    private func showDebugPanel() {
        if let window = debugWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = makeWindow(
            title: "MultiDock 调试面板",
            size: NSSize(width: 760, height: 620),
            content: DebugPanelView(state: state)
        )
        debugWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = makeWindow(
            title: "MultiDock 设置",
            size: NSSize(width: 560, height: 480),
            content: SettingsView(state: state)
        )
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.setContentSize(size)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // 关掉后仍保留实例，再次打开时复用，避免状态丢失。
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

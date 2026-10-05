import AppKit
import Observation
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
    private var toastWindow: DesktopNameToastWindow!
    private var secondaryDockWindow: SecondaryDockWindow!
    private var secondaryDockController: SecondaryDockController?

    private var debugWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsTabModel: SettingsTabModel?
    private var powerOffObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        self.state = state
        attachToast(to: state)
        attachSecondaryDock(to: state)

        lifecycle = LifecycleController(state: state)
        // 无痕原则的两条接线：把「改过 Dock」记进会话标记；退出时把基准写回真实 Dock。
        state.onDockApplied = { [weak lifecycle] fingerprint in
            lifecycle?.noteDockApplied(fingerprint: fingerprint)
        }
        lifecycle.restoreHandler = { [weak state] in
            // 只有退出/关机这两条路走这里 —— 所以一律 `forQuit`：写完偏好、发一发 SIGHUP 就走，
            // 不等 Dock 归位。等满降级链在 launchd 退避期间是几十秒（真机 2026-09-19）。
            await state?.restoreToBaseline(forQuit: true)
        }
        menuBar = MenuBarController(state: state)
        menuBar.onOpenDebugPanel = { [weak self] in self?.showDebugPanel() }
        menuBar.onOpenSettings = { [weak self] in self?.showSettings() }
        menuBar.onQuit = { NSApp.terminate(nil) }

        lifecycle.applicationDidFinishLaunching()
        observePowerOff()
        observeScreenChanges()
    }

    /// toast 的接线：窗口在这里建，调度逻辑在 `ToastPresenter`，状态与命名解析仍归 `AppState`。
    /// 必须在 `state.start()`（观察器启动）之前接上，否则首次桌面变化会漏掉。
    private func attachToast(to state: AppState) {
        let window = DesktopNameToastWindow()
        toastWindow = window
        state.attachToastPresenter(
            ToastPresenter(
                presenter: window,
                displayName: { [weak state] space in
                    state?.displayName(for: space) ?? space.displayName
                },
                isEnabled: { [weak state] in
                    state?.settings.showToastOnDesktopSwitch ?? true
                },
                log: { [weak state] message in
                    state?.append(.info, message)
                }
            )
        )
    }

    /// 次级 Dock 条的接线：窗口在这里建，调度逻辑在 `SecondaryDockController`，
    /// 内容快照与开关仍归 `AppState`。同样必须在 `state.start()` 之前接上。
    private func attachSecondaryDock(to state: AppState) {
        let window = SecondaryDockWindow()
        secondaryDockWindow = window
        let controller = SecondaryDockController(
            deps: .init(
                presenter: window,
                faceProvider: ScreenInsetDockFaceProvider(),
                content: { [weak state] space in state?.secondaryDockContent(for: space) },
                isEnabled: { [weak state] in state?.settings.showSecondaryDock ?? true },
                log: { [weak state] message in
                    state?.append(.info, message)
                }
            )
        )
        secondaryDockController = controller
        window.onActivate = { item in
            guard let path = item.launchPath else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        window.onHoverChange = { [weak controller] inside in
            controller?.hoverChanged(inside)
        }
        state.attachSecondaryDock(controller)
        controller.start()
        observeSecondaryDockConfiguration(state, controller: controller)
    }

    /// 次级 Dock 条的内容随配置变化（改图标、改绑定、开关切换）即时刷新。
    /// 与 `MenuBarController` 同一手法：`withObservationTracking` 观察一轮、变更时重注册。
    private func observeSecondaryDockConfiguration(
        _ state: AppState,
        controller: SecondaryDockController
    ) {
        withObservationTracking {
            _ = state.settings
            _ = state.bindings
            // 桌面列表也进依赖：条的内容与位置随桌面绑定栏走（2026-10-05 起每栏可设位置），
            // 桌面增删（插拔外接屏、全屏进出）后要重算。
            _ = state.desktops
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                controller.refresh()
                self.observeSecondaryDockConfiguration(state, controller: controller)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycle.applicationWillTerminate()
        if let token = powerOffObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        if let token = screenParametersObserver {
            NotificationCenter.default.removeObserver(token)
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

    /// 插拔外接显示器后桌面列表必须重读，否则新显示器上的桌面不会进菜单。
    /// 只做刷新，不主动应用 Dock —— 屏幕变化瞬间活动空间还没定，交给轮询收敛。
    private func observeScreenChanges() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.state.handleScreenParametersChanged()
                // 插拔/改分辨率会改变 Dock 的排他内缩，次级条立刻重摆（1s 轮询兜底）。
                self?.secondaryDockController?.geometryTick()
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
        let tabModel = settingsTabModel ?? SettingsTabModel()
        settingsTabModel = tabModel
        let window = SettingsWindowFactory.makeWindow(state: state, tabModel: tabModel)
        settingsWindow = window
        window.center()
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

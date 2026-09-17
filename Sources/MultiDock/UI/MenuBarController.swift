import AppKit

/// 菜单栏图标与下拉菜单。
///
/// **为什么不用 `MenuBarExtra`**：硬约束要求「左键单击 = 切到下一个桌面，右键 / ⌥+左键 = 下拉菜单」，
/// 而 `MenuBarExtra` 的点击一律被它自己吃掉、无法区分左右键。所以这里用 `NSStatusItem`
/// 直接控制 `sendAction(on:)`，菜单内容仍是纯 AppKit（无需 SwiftUI 的场景系统）。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let state: AppState
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    /// 菜单项回调（由 AppDelegate 注入，避免这里直接持有窗口逻辑）。
    var onOpenDebugPanel: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "MultiDock")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // 关键：同时接收左右键，否则拿不到右键事件。
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "MultiDock — 左键切下一个桌面，右键打开菜单"
        }

        menu.delegate = self
        refreshTitle()
        observeActiveSpace()
    }

    // MARK: - 图标标题

    private func refreshTitle() {
        let ordinal = state.activeSpace?.ordinal
        statusItem.button?.title = ordinal.map { " \($0)" } ?? ""
    }

    /// `withObservationTracking` 只回调一次，所以要重新注册自己。
    private func observeActiveSpace() {
        withObservationTracking {
            _ = state.activeSpace
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshTitle()
                self?.observeActiveSpace()
            }
        }
    }

    // MARK: - 点击

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
        let isOptionClick = event?.modifierFlags.contains(.option) ?? false
        let forceMenu = state.settings.clickAction == .openMenu

        if isRightClick || isOptionClick || forceMenu {
            showMenu()
        } else {
            state.switchToNextDesktop()
        }
    }

    private func showMenu() {
        rebuildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    /// 菜单关闭后必须解绑，否则左键点击会被菜单继续吃掉。
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    // MARK: - 菜单内容

    private func rebuildMenu() {
        menu.removeAllItems()

        if !state.spaceProviderAvailable {
            let warning = NSMenuItem(
                title: "⚠︎ 桌面功能不可用（见调试面板）",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        // 桌面列表：当前项打勾，点选即切换
        if state.desktops.isEmpty {
            let empty = NSMenuItem(title: "未识别到桌面", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for space in state.desktops {
                // 走 AppState 的解析入口：有自定义名用自定义名，否则「桌面 N」。
                let item = NSMenuItem(
                    title: state.displayName(for: space),
                    action: #selector(selectDesktop(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = space
                item.state = (space.id == state.activeSpace?.id) ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let next = NSMenuItem(title: "下一个桌面", action: #selector(goNextDesktop), keyEquivalent: "")
        next.target = self
        next.isEnabled = state.spaceProviderAvailable && state.desktops.count > 1
        menu.addItem(next)

        // 计划 §3.7 菜单栏下拉：把此刻真实 Dock 抓下来覆盖当前桌面的配置。
        let resetFromLive = NSMenuItem(
            title: "用当前 Dock 重置本桌面配置",
            action: #selector(resetFromLiveDock),
            keyEquivalent: ""
        )
        resetFromLive.target = self
        menu.addItem(resetFromLive)

        let refresh = NSMenuItem(title: "刷新桌面列表", action: #selector(refreshDesktops), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let debug = NSMenuItem(title: "调试面板…", action: #selector(openDebugPanel), keyEquivalent: "d")
        debug.target = self
        menu.addItem(debug)

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        // 标题写清"退出会还原"：无痕原则是硬约束，别让用户以为退出后 Dock 会留在改动后的状态。
        let quit = NSMenuItem(title: "退出并还原 Dock", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - 动作

    @objc private func selectDesktop(_ sender: NSMenuItem) {
        guard let space = sender.representedObject as? DesktopSpace else { return }
        state.switchTo(space)
    }

    @objc private func goNextDesktop() { state.switchToNextDesktop() }
    @objc private func resetFromLiveDock() { state.resetActiveDesktopConfigFromLiveDock() }
    @objc private func refreshDesktops() { state.refreshDesktops() }
    @objc private func openDebugPanel() { onOpenDebugPanel?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func quit() { onQuit?() }
}

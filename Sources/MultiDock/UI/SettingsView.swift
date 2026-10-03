import AppKit
import SwiftUI

/// 设置窗口当前显示的页。由窗口工具栏（NSToolbar 可选项）写入，SwiftUI 侧只读。
/// 放成可注入的类而不是 `@State`：NSToolbar 的 item action 在 AppKit 侧，写不进视图状态。
@MainActor
@Observable
final class SettingsTabModel {
    var tab: SettingsTab = .general
}

/// 设置窗口的两页。
enum SettingsTab {
    case general
    case desktop
}

/// 设置窗口。两个页：通用（默认 Dock）/ 桌面（逐桌面独立 Dock）。
///
/// 顶部有一条**报警横幅**：`docs/PLAN.md` §3.1 末段要求"降级时在 UI 明确报警，而不是静默失效"，
/// §3.9 第 3 条要求"Dock 拉不回来时提示从备份恢复"。这两件事都只进日志和调试面板是不合格的 ——
/// 用户不看日志。
struct SettingsView: View {
    @Bindable var state: AppState
    var tabModel: SettingsTabModel

    var body: some View {
        VStack(spacing: 0) {
            WarningBanner(state: state)
            switch tabModel.tab {
            case .general: GeneralTab(state: state)
            case .desktop: DesktopListView(state: state)
            }
        }
        .frame(width: 780, height: 560)
    }
}

// MARK: - 窗口工具栏（System Preferences 式标签页）

/// macOS 设置窗口的原生形态：工具栏上「图标 + 文字」的标签页，选中项高亮
/// （窗口 `toolbarStyle = .preference`）。SwiftUI 的 `TabView` 在 macOS 上渲染成
/// 浏览器式的窗口标签——没有任何一个 Apple 设置窗口长那样。
@MainActor
final class SettingsToolbarController: NSObject, NSToolbarDelegate {
    static let generalItem = NSToolbarItem.Identifier("MultiDock.Settings.General")
    static let desktopItem = NSToolbarItem.Identifier("MultiDock.Settings.Desktop")

    private let tabModel: SettingsTabModel

    init(tabModel: SettingsTabModel) {
        self.tabModel = tabModel
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.items
    }

    /// 把两页做成「可选中」的标签：AppKit 负责选中高亮，页切换仍走 item action。
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.generalItem, Self.desktopItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.items
    }

    private static var items: [NSToolbarItem.Identifier] {
        [.flexibleSpace, generalItem, desktopItem, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.generalItem:
            item.label = "通用"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "通用")
            item.target = self
            item.action = #selector(showGeneral)
        case Self.desktopItem:
            item.label = "桌面"
            item.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "桌面")
            item.target = self
            item.action = #selector(showDesktop)
        default:
            return nil
        }
        return item
    }

    @objc private func showGeneral() { tabModel.tab = .general }
    @objc private func showDesktop() { tabModel.tab = .desktop }
}

// MARK: - 窗口装配

/// 设置窗口的完整装配（SwiftUI 内容 + 可选中工具栏标签）。
/// AppDelegate 与 UI 快照测试**共用** —— 快照要复制一份装配逻辑，验出来的就不是真窗口。
@MainActor
enum SettingsWindowFactory {
    private static var keepAliveKey: UInt8 = 0

    static func makeWindow(state: AppState, tabModel: SettingsTabModel) -> NSWindow {
        let toolbarController = SettingsToolbarController(tabModel: tabModel)
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: SettingsView(state: state, tabModel: tabModel)
        ))
        window.title = "MultiDock 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // 关掉后仍保留实例，再次打开时复用，避免状态丢失。
        window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "MultiDock.Settings.Tabs")
        toolbar.delegate = toolbarController
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        toolbar.selectedItemIdentifier = SettingsToolbarController.generalItem
        // 与 `SettingsView` 根视图的 `.frame(width:height:)` 保持一致，
        // 否则窗口先按这个尺寸画一帧再被 SwiftUI 撑开，会看到一次跳动。
        window.setContentSize(NSSize(width: 780, height: 560))
        // NSToolbar.delegate 是弱引用：把 controller 挂在窗口上保活。
        objc_setAssociatedObject(window, &keepAliveKey, toolbarController, .OBJC_ASSOCIATION_RETAIN)
        return window
    }
}

// MARK: - 报警横幅

/// 设置窗口顶部的报警区。两条都为空时**整个视图不占空间**。
private struct WarningBanner: View {
    var state: AppState

    var body: some View {
        if state.dockFailureWarning != nil || state.spaceProviderWarning != nil {
            VStack(alignment: .leading, spacing: 12) {
                if let reason = state.dockFailureWarning {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Dock 拉不回来")
                                .font(.headline)
                            Text("\(reason)。可以点右边重试，或到「通用 → 备份与还原」恢复一份历史备份。")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 4) {
                            Button("再试一次拉回") { state.retryDockRevival() }
                            Button("立即还原到原始 Dock") { state.restoreToBaselineNow() }
                        }
                    }
                }

                if let reason = state.spaceProviderWarning {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("桌面切换不可用")
                                .font(.headline)
                            Text("\(reason)。Dock 配置仍能手动应用，但不会随桌面自动切换，菜单栏的切换按钮也不起作用。")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
        }
    }
}

// MARK: - 通用

private struct GeneralTab: View {
    @Bindable var state: AppState
    /// 待确认的备份恢复。恢复备份会真的重启 Dock，必须二次确认。
    @State private var pendingBackup: BaselineStore.BackupEntry?

    var body: some View {
        Form {
            Section("默认 Dock") {
                DockStripEditor(
                    config: defaultDockBinding,
                    availableKeys: state.availableWhitelistedKeys,
                    captureLive: { state.captureLiveDockConfig() }
                ) { reason in
                    state.dockEdited(.defaultDock, reason: reason)
                }
                Text("访达与启动台固定在图标条最前面。访达在系统偏好里根本没有对应条目（P0 实测），所以不需要也不能改；启动台由程序保证存在。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("默认 Dock 的外观") {
                DockAppearanceEditor(
                    appearance: defaultAppearanceBinding,
                    unavailableKeys: state.unavailableAppearanceKeys
                ) { reason in
                    state.dockEdited(.defaultDock, reason: reason)
                }
            }

            Section("应用") {
                HStack(spacing: 8) {
                    Button("立即应用") { state.applyDefaultDock() }
                        .disabled(state.settings.defaultDock.pinnedApps.isEmpty)
                    Button("立即还原到原始 Dock") { state.restoreToBaselineNow() }
                    Button("把当前 Dock 设为新基准") { state.resetBaselineToCurrent() }
                    Button("撤销自动回存") { state.undoLastAutoCapture() }
                        .disabled(!state.canUndoAutoCapture())
                        .help("撤销上一次「识别到你在真实 Dock 上的改动并回存」的覆盖（回存只落在当前活动桌面上）。")
                    Spacer()
                }
                Text(state.lastApplySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.settings.defaultDock.pinnedApps.isEmpty {
                    Label("默认 Dock 还是空的。点图标条上的「从当前 Dock 抓取」把它读进来，否则「立即应用」会把 Dock 清空（已禁用）。",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("菜单栏") {
                Picker("左键单击", selection: clickActionBinding) {
                    ForEach(ClickAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("右键或 ⌥+左键始终打开菜单。⇧+左键切上一个桌面；左键若设为「打开菜单」，⇧+左键也一并打开菜单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("桌面切换") {
                Toggle("切换桌面时显示桌面名称", isOn: toastBinding)
                Text("在桌面所在显示器的中上部显示该桌面的名字，1 秒后自动消失。不抢焦点、不挡点击。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("次级 Dock 条") {
                Toggle("显示次级 Dock 条", isOn: secondaryDockBinding)
                Text("贴在原生 Dock 内侧的自绘图标条：默认只露一半（藏在原生 Dock 身后），鼠标移上去滑出全条。内容跟随当前桌面的图标配置，切换桌面瞬间换内容、不重启 Dock。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("冻结原生 Dock 的逐桌面切换", isOn: freezeNativeDockBinding)
                    .disabled(!state.settings.showSecondaryDock)
                if state.settings.freezeNativeDockSwitching {
                    Text("已冻结：原生 Dock 保持一套固定配置，切桌面不再重启；每个桌面的差异由次级条呈现。手动改动真实 Dock 会记入默认 Dock。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !state.settings.showSecondaryDock {
                    Text("需要先开启「显示次级 Dock 条」——冻结后桌面的差异只能靠次级条看到。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("退出行为") {
                Toggle("退出 App 时还原为原始 Dock", isOn: restoreOnQuitBinding)
                Text("无痕原则：首次运行会把当时的 Dock 完整存为基准快照，退出时自动还原；即使被强杀或崩溃，下次启动也会检测并还原。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("启动与自愈") {
                Toggle("登录时自动启动", isOn: loginItemBinding)
                    .disabled(!LoginItem.isAvailable)
                Text(state.loginItemStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !LoginItem.isAvailable {
                    Text("当前不在 .app 包里运行，登录启动不可用。用 ./scripts/build-app.sh 打包后再开。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("强杀自愈：被强杀或崩溃时，下次启动会自动把 Dock 还原为原始状态，并在屏幕上给出提示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let summary = state.selfHealSummary {
                    Label(summary, systemImage: "arrow.uturn.backward")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let stale = state.interruptedSession {
                    Text("上次未正常退出：PID \(String(stale.pid))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section("桌面行为") {
                Toggle("根据最近使用自动重排空间（mru-spaces）", isOn: mruSpacesBinding)
                    .disabled(state.mruSpaces == nil)
                Text("本机默认是开的。开着时系统会按最近使用重排桌面顺序，菜单栏的「切到下一个桌面」会变得不符合直觉，建议关掉。这个键不在常规写入范围内 —— 只有你在这里点开关才会改，改完会自动重启一次 Dock 生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.mruSpaces == nil {
                    Text("当前 macOS 的 com.apple.dock 里没有这个键，因此不提供开关。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("备份与还原") {
                if state.backups.isEmpty {
                    Text("还没有历史备份。每次真正写 Dock 之前都会自动留一份，最多保留 20 份。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(state.backups.prefix(5)) { entry in
                        HStack(spacing: 8) {
                            Text(entry.fileName)
                                .font(.caption.monospaced())
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("恢复") { pendingBackup = entry }
                        }
                    }
                    if state.backups.count > 5 {
                        Text("只列出最近 5 份，共 \(state.backups.count) 份。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("刷新列表") { state.refreshBackups() }
                Text("恢复备份只覆盖 Dock 的图标与外观，不动热角、启动台网格等设置 —— 因为我们从来只写那几项。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Dock 应用") {
                Toggle("编辑后立即应用", isOn: autoApplyBinding)
                Toggle("识别真实 Dock 上的手动改动并回存", isOn: autoCaptureBinding)
                Picker("重载方式", selection: reloadStrategyBinding) {
                    ForEach(ReloadStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                Text("实测：写偏好后 Dock 不会自己重读，改配置要重启 Dock 进程 —— SIGHUP 约 0.1 秒不可用，SIGTERM 约 0.4 秒。（macOS 存在私有的实时生效通道，外观键已验证可行；条目路径打通前不启用。）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !state.unavailableAppearanceKeys.isEmpty {
                Section("本机不支持") {
                    Text(state.unavailableAppearanceKeys.sorted().joined(separator: "、"))
                        .font(.caption.monospaced())
                    Text("这些键在当前 macOS 的 com.apple.dock 里不存在，写进去不会生效，因此不做成开关。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refreshBackups() }
        .alert(
            "恢复这份备份？",
            isPresented: Binding(
                get: { pendingBackup != nil },
                set: { if !$0 { pendingBackup = nil } }
            ),
            presenting: pendingBackup
        ) { entry in
            Button("恢复", role: .destructive) {
                state.restoreBackup(entry)
                pendingBackup = nil
            }
            Button("取消", role: .cancel) { pendingBackup = nil }
        } message: { entry in
            Text("会用 \(entry.fileName) 里的图标与外观覆盖当前 Dock，并重启一次 Dock（约 0.1 秒不可用）。")
        }
    }

    private var defaultDockBinding: Binding<DockConfig> {
        Binding(
            get: { state.dockConfig(for: .defaultDock) },
            // 只改内存：拖拽排序过程中会连续触发，落盘统一由 `dockEdited` 做一次。
            set: { state.setDockConfigInMemory($0, for: .defaultDock) }
        )
    }

    private var defaultAppearanceBinding: Binding<DockAppearance> {
        Binding(
            get: { state.dockAppearance(for: .defaultDock) },
            // 同上：滑杆拖动过程中会连续触发，提交在 `DockAppearanceEditor` 的 onCommit 里。
            set: { state.setDockAppearanceInMemory($0, for: .defaultDock) }
        )
    }

    private var clickActionBinding: Binding<ClickAction> {
        Binding(
            get: { state.settings.clickAction },
            set: { value in state.updateSettings { $0.clickAction = value } }
        )
    }

    private var restoreOnQuitBinding: Binding<Bool> {
        Binding(
            get: { state.settings.restoreOnQuit },
            set: { value in state.updateSettings { $0.restoreOnQuit = value } }
        )
    }

    /// 登录项状态属于系统（`SMAppService`），**不存进 config.json**，所以直接读系统。
    /// 改完之后 `setLoginItemEnabled` 会刷新 `loginItemStatus`，视图因此重新求值。
    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { LoginItem.isEnabled },
            set: { state.setLoginItemEnabled($0) }
        )
    }

    private var mruSpacesBinding: Binding<Bool> {
        Binding(
            get: { state.mruSpaces ?? false },
            set: { state.setMRUSpaces($0) }
        )
    }

    private var autoApplyBinding: Binding<Bool> {
        Binding(
            get: { state.settings.autoApplyOnEdit },
            set: { value in state.updateSettings { $0.autoApplyOnEdit = value } }
        )
    }

    private var autoCaptureBinding: Binding<Bool> {
        Binding(
            get: { state.settings.autoCaptureUserEdits },
            set: { value in state.updateSettings { $0.autoCaptureUserEdits = value } }
        )
    }

    private var reloadStrategyBinding: Binding<ReloadStrategy> {
        Binding(
            get: { state.settings.reloadStrategy },
            set: { value in state.updateSettings { $0.reloadStrategy = value } }
        )
    }

    private var toastBinding: Binding<Bool> {
        Binding(
            get: { state.settings.showToastOnDesktopSwitch },
            set: { value in
                state.updateSettings { $0.showToastOnDesktopSwitch = value }
                if !value { state.toastPresenter?.dismissNow() }
            }
        )
    }

    private var secondaryDockBinding: Binding<Bool> {
        Binding(
            get: { state.settings.showSecondaryDock },
            set: { value in
                state.updateSettings { $0.showSecondaryDock = value }
                // 关掉时立即收窗口；打开时由观察回调刷新。冻结开关跟着失能/恢复。
                if !value {
                    state.updateSettings { $0.freezeNativeDockSwitching = false }
                }
                state.secondaryDock?.refresh()
            }
        )
    }

    private var freezeNativeDockBinding: Binding<Bool> {
        Binding(
            get: { state.settings.freezeNativeDockSwitching },
            set: { value in
                state.updateSettings { $0.freezeNativeDockSwitching = value }
                state.secondaryDock?.refresh()
            }
        )
    }
}

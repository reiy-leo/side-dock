import SwiftUI

/// 设置窗口。两个 Tab：通用（默认 Dock）/ 桌面（逐桌面独立 Dock）。
struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView {
            GeneralTab(state: state)
                .tabItem { Label("通用", systemImage: "gearshape") }
            DesktopListView(state: state)
                .tabItem { Label("桌面", systemImage: "rectangle.3.group") }
        }
        .frame(width: 780, height: 560)
    }
}

// MARK: - 通用

private struct GeneralTab: View {
    @Bindable var state: AppState

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
                Text("右键或 ⌥+左键始终打开菜单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("桌面切换") {
                Toggle("切换桌面时显示桌面名称", isOn: toastBinding)
                Text("在桌面所在显示器的中上部显示该桌面的名字，1 秒后自动消失。不抢焦点、不挡点击。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("退出行为") {
                Toggle("退出 App 时还原为原始 Dock", isOn: restoreOnQuitBinding)
                Text("无痕原则：首次运行会把当时的 Dock 完整存为基准快照，退出时自动还原；即使被强杀或崩溃，下次启动也会检测并还原。")
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
                Text("P0 实测结论：Dock 没有热重载，改配置必须重启 Dock 进程。SIGHUP 约 0.1 秒不可用，SIGTERM 约 0.4 秒。")
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
}

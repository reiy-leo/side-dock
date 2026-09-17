import SwiftUI

/// 设置窗口。计划要求两个 Tab：通用 / 桌面。
///
/// **P1 只实现「不需要写 Dock」的部分**：交互与行为开关。
/// Dock 编辑条（`DockStripEditor`）与逐桌面绑定属于 P2/P3，这里明确标注为待实现，
/// 不做假 UI —— 免得看起来能用、点了没反应。
struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView {
            GeneralTab(state: state)
                .tabItem { Label("通用", systemImage: "gearshape") }
            DesktopsTab(state: state)
                .tabItem { Label("桌面", systemImage: "rectangle.3.group") }
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - 通用

private struct GeneralTab: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
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

            Section("待实现") {
                LabeledContent("默认 Dock 编辑条", value: "P2")
                LabeledContent("立即还原到原始 Dock", value: "P2")
                LabeledContent("mru-spaces 开关", value: "P4")
                Text("P1 阶段不会写入任何 Dock 设置，所以这些按钮还不存在。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
}

// MARK: - 桌面

private struct DesktopsTab: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("显示器上的用户桌面") {
                    if state.desktops.isEmpty {
                        Text(state.spaceProviderAvailable ? "未识别到桌面" : "桌面功能不可用")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(state.desktops) { space in
                            HStack {
                                Image(systemName: space.id == state.activeSpace?.id
                                      ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(space.id == state.activeSpace?.id
                                                     ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(space.displayName)
                                    Text(space.spaceUUID)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("id64=\(space.id64)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section {
                    LabeledContent("逐桌面 Dock 绑定", value: "P3")
                    LabeledContent("自定义桌面名", value: "P3")
                    Text("桌面命名在 macOS 15 没有系统接口，只能存在本地（P0 已确认空间字典里没有名称字段）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("待实现")
                }
            }

            Divider()

            HStack {
                Button("刷新桌面列表") { state.refreshDesktops() }
                Spacer()
                Text("自动每 300 ms 刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }
}

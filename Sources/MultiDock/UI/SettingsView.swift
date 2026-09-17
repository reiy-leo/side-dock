import SwiftUI

/// 设置窗口。计划要求两个 Tab：通用 / 桌面。
///
/// **P2.5 只实现「不需要写 Dock」的部分**：交互与行为开关，以及逐桌面的命名。
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

// MARK: - 桌面

private struct DesktopsTab: View {
    @Bindable var state: AppState

    /// 编辑中的草稿，**不直接绑到模型**。两个原因：
    /// 1. 每次击键都写模型 = 每个字符写一次 `config.json`；
    /// 2. 中文输入法组字（marked text）期间对值做截断会打断候选词。
    /// 所以草稿留在本地，回车或失焦时再归一化提交（超长此时被截到 10）。
    @State private var drafts: [String: String] = [:]
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("显示器上的用户桌面") {
                    if state.desktops.isEmpty {
                        Text(state.spaceProviderAvailable ? "未识别到桌面" : "桌面功能不可用")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(state.desktops) { space in
                            desktopRow(space)
                        }
                    }
                }

                Section {
                    LabeledContent("逐桌面 Dock 绑定", value: "P3")
                    Text("桌面名只存在本地（macOS 15 没有桌面命名接口，P0 已确认空间字典里没有名称字段），不会写回系统。")
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
        .onAppear { syncDrafts() }
        .onChange(of: state.desktopListGeneration) { syncDrafts() }
        .onChange(of: focused) { previous, _ in
            // 失焦即提交，避免用户改完直接切走导致改动丢失。
            guard let previous, let space = state.desktops.first(where: { $0.id == previous }) else { return }
            commit(space)
        }
    }

    private func desktopRow(_ space: DesktopSpace) -> some View {
        let draft = drafts[space.id] ?? ""
        let isActive = space.id == state.activeSpace?.id
        return HStack(spacing: 8) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                TextField("桌面 \(space.ordinal)", text: draftBinding(for: space))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .focused($focused, equals: space.id)
                    .onSubmit { commit(space) }
                Text(space.spaceUUID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text("\(draft.count)/\(DesktopNaming.maxLength)")
                .font(.caption.monospaced())
                .foregroundStyle(draft.count > DesktopNaming.maxLength ? Color.orange : Color.secondary)
                .help("回车或点到别处时按 \(DesktopNaming.maxLength) 个字符截断")

            Spacer()

            if isActive {
                Text("当前")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func draftBinding(for space: DesktopSpace) -> Binding<String> {
        Binding(
            get: { drafts[space.id] ?? state.customName(for: space) ?? "" },
            set: { drafts[space.id] = $0 }
        )
    }

    /// 提交：归一化（去空白、截断到 10）并落盘，然后把草稿对齐成归一化后的结果。
    private func commit(_ space: DesktopSpace) {
        let raw = drafts[space.id] ?? state.customName(for: space) ?? ""
        state.setCustomName(raw, for: space)
        drafts[space.id] = state.customName(for: space) ?? ""
    }

    private func syncDrafts() {
        var next: [String: String] = [:]
        for space in state.desktops {
            next[space.id] = state.customName(for: space) ?? ""
        }
        drafts = next
    }
}

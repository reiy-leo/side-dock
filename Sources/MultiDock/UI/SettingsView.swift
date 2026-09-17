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
}

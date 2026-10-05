import AppKit
import SwiftUI

/// 设置窗口当前显示的页。由侧边栏（SwiftUI List 选中项）写入，窗口装配侧也持有
/// —— 菜单/测试要指定页时走它。
@MainActor
@Observable
final class SettingsTabModel {
    var tab: SettingsTab = .general
}

/// 设置窗口的五个页（2026-10-06 起侧边栏呈现，系统设置风格；同日「桌面」拆出「应用栏」）。
enum SettingsTab: Hashable {
    case general
    case appBars
    case desktop
    case data
    case about
}

/// 设置窗口：左侧边栏选项卡 + 右侧内容，顶部保留报警横幅。
///
/// **为什么是 `NavigationSplitView` 而不是 `TabView`**：SwiftUI 的 `TabView` 在 macOS 上
/// 渲染成浏览器式窗口标签；系统的 macOS 设置（Ventura+）是侧边栏形态。侧边栏用
/// SwiftUI List 的选中项驱动（`SettingsTabModel` 桥接，菜单/测试可指定页）。
///
/// 报警横幅放在**内容列**顶部：`docs/PLAN.md` §3.1 末段要求"降级时在 UI 明确报警"，
/// §3.9 第 3 条要求"Dock 拉不回来时提示从备份恢复"——用户不看日志。
struct SettingsView: View {
    @Bindable var state: AppState
    var tabModel: SettingsTabModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 200)
        } detail: {
            VStack(spacing: 0) {
                WarningBanner(state: state)
                switch tabModel.tab {
                case .general: GeneralTab(state: state)
                case .appBars: DockBarsTab(state: state)
                case .desktop: DesktopsTab(state: state)
                case .data: DataView(state: state)
                case .about: AboutTab(state: state)
                }
            }
            .frame(minWidth: 600, minHeight: 500)
        }
        .frame(width: 880, height: 560)
    }

    // MARK: 侧边栏

    /// 侧边栏布局（2026-10-06 用户要求）：主 tabs（通用/桌面/数据）在顶部、
    /// 与窗口顶再让出一截；「关于」钉在列底。
    ///
    /// **为什么「关于」不走 List 行**：`List` 没有"行钉底"机制——中间塞 spacer 行
    /// 不会撑开（行高取内容理想值）。用 `safeAreaInset(edge: .bottom)` 承载一根
    /// 单行的原生 sidebar 小 `List`（与上方同一份 selection 绑定）：行样式、hover、
    /// 选中胶囊、窗口非激活变灰全走系统实现，不手绘。
    private var sidebar: some View {
        List(selection: tabSelection) {
            Section {
                Label("通用", systemImage: "gearshape").tag(SettingsTab.general)
                Label("应用栏", systemImage: "dock.rectangle").tag(SettingsTab.appBars)
                Label("桌面", systemImage: "rectangle.3.group").tag(SettingsTab.desktop)
                Label("数据", systemImage: "externaldrive").tag(SettingsTab.data)
            }
        }
        // 无 titlebar 的窗口里红绿灯浮在侧边栏上，默认行距顶太近 —— 顶部再让出一截
        // （safeAreaInset 不产生可点击视图，不挡窗口顶部拖拽区）。
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 26)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            List(selection: tabSelection) {
                Label("关于", systemImage: "info.circle").tag(SettingsTab.about)
            }
            // 高度 = 单行 sidebar List 的自然高度（上下 contentInset ~10 + 行 ~28）。
            // 行高是系统固定值，窗口缩放不影响。
            .frame(height: 48)
        }
    }

    /// 上、下两个 List 共用同一份选中绑定：点「关于」时上方三行自动全不选，
    /// 点主 tabs 时底部「关于」自动取消高亮。
    private var tabSelection: Binding<SettingsTab> {
        Binding(
            get: { tabModel.tab },
            set: { tabModel.tab = $0 }
        )
    }
}

// MARK: - 窗口装配

/// 设置窗口的完整装配（SwiftUI 内容）。AppDelegate 与 UI 快照测试**共用** ——
/// 快照要复制一份装配逻辑，验出来的就不是真窗口。
@MainActor
enum SettingsWindowFactory {
    static func makeWindow(state: AppState, tabModel: SettingsTabModel) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: SettingsView(state: state, tabModel: tabModel)
        ))
        // 系统设置风格（2026-10-06 用户要求）：去掉 titlebar，侧边栏贯通到窗口顶。
        // 仍保留 .titled —— 红绿灯与顶部隐藏拖拽区靠它；fullSizeContentView 让内容
        // 占满全高，侧边栏材质（NavigationSplitView 左列）因此延伸进原 titlebar 区。
        // title 只给「窗口」菜单与辅助功能用，界面上不再显示。
        window.title = "MultiDock 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // 关掉后仍保留实例，再次打开时复用，避免状态丢失。
        window.isReleasedWhenClosed = false
        // 与 `SettingsView` 根视图的 `.frame(width:height:)` 保持一致，
        // 否则窗口先按这个尺寸画一帧再被 SwiftUI 撑开，会看到一次跳动。
        window.setContentSize(NSSize(width: 880, height: 560))
        window.center()
        return window
    }
}

// MARK: - 菜单栏图标选择

/// 五选一的图标格子：图标 + 名称，选中描强调色（apple-design：选项并列、状态一眼可见）。
private struct MenuBarIconChoice: View {
    let icon: MenuBarIcon
    @Binding var selection: MenuBarIcon

    private var isSelected: Bool { selection == icon }

    var body: some View {
        Button {
            selection = icon
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let image = icon.image(size: 20) {
                        Image(nsImage: image)
                            .resizable()
                            .renderingMode(.template)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "questionmark")
                            .frame(width: 20, height: 20)
                    }
                }
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Text(icon.displayName)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .frame(width: 56, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(icon.displayName)（Lucide \(icon.lucideName)）")
    }
}

// MARK: - 报警横幅

/// 设置窗口内容列顶部的报警区。两条都为空时**整个视图不占空间**。
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
                            Text("\(reason)。可以点右边重试，或到「数据 → 备份与还原」恢复一份历史备份。")
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

    var body: some View {
        Form {
            Section("应用") {
                HStack(spacing: 8) {
                    Button("立即应用") { state.applyDefaultDock() }
                        .disabled(state.defaultDock.pinnedApps.isEmpty)
                    Button("立即还原到原始 Dock") { state.restoreToBaselineNow() }
                    Button("把当前 Dock 设为新基准") { state.resetBaselineToCurrent() }
                    Button("撤销自动回存") { state.undoLastAutoCapture() }
                        .disabled(!state.canUndoAutoCapture())
                        .help("撤销上一次「识别到你在真实 Dock 上的改动并回存」的覆盖（回存只落在活动桌面绑定的栏上）。")
                    Spacer()
                }
                Text(state.lastApplySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.defaultDock.pinnedApps.isEmpty {
                    Label("没有扫描到任何应用，默认 Dock 是空的，「立即应用」已禁用。", systemImage: "exclamationmark.triangle")
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("图标")
                    HStack(spacing: 8) {
                        ForEach(MenuBarIcon.allCases, id: \.self) { icon in
                            MenuBarIconChoice(icon: icon, selection: menuBarIconBinding)
                        }
                    }
                }
                Text("右键或 ⌥+左键始终打开菜单。⇧+左键切上一个桌面；左键若设为「打开菜单」，⇧+左键也一并打开菜单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("次级 Dock 条") {
                Toggle("显示次级 Dock 条", isOn: secondaryDockBinding)
                Text("每个桌面可以绑定一根 Dock 栏（在「应用栏」页配置）：默认只露一半，鼠标移上去滑出全条，点击图标启动。位置可以贴屏幕底边或侧边（台前调度占用的一侧会自动避开）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("冻结原生 Dock 的逐桌面切换", isOn: freezeNativeDockBinding)
                    .disabled(!state.settings.showSecondaryDock)
                if state.settings.freezeNativeDockSwitching {
                    Text("已冻结：原生 Dock 固定为「默认 Dock」（最近添加的应用），切桌面不再重启；每个桌面的差异由绑定到该桌面的 Dock 栏呈现。")
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

            Section("Dock 应用") {
                Toggle("编辑后立即应用", isOn: autoApplyBinding)
                Toggle("识别真实 Dock 上的手动改动并回存", isOn: autoCaptureBinding)
                Picker("重载方式", selection: reloadStrategyBinding) {
                    ForEach(ReloadStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                Text("实测：写偏好后 Dock 不会自己重读，改配置要重启 Dock 进程 —— SIGHUP 约 0.1 秒不可用，SIGTERM 约 0.4 秒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var menuBarIconBinding: Binding<MenuBarIcon> {
        Binding(
            get: { state.settings.menuBarIcon },
            set: { value in state.updateSettings { $0.menuBarIcon = value } }
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

    private var secondaryDockBinding: Binding<Bool> {
        Binding(
            get: { state.settings.showSecondaryDock },
            set: { value in
                state.updateSettings { $0.showSecondaryDock = value }
                // 关掉时立即收窗口；打开时由观察回调刷新。冻结开关跟着失能/恢复
                // （走同一个入口，解冻的「恢复逐桌面应用」也一并发生）。
                if !value {
                    state.setFreezeNativeDockSwitching(false)
                }
                state.secondaryDock?.refresh()
            }
        )
    }

    private var freezeNativeDockBinding: Binding<Bool> {
        Binding(
            get: { state.settings.freezeNativeDockSwitching },
            set: { value in
                // 开/关都要让原生 Dock 立刻与新模式一致（重扫默认 Dock 并对齐 / 恢复逐桌面），
                // 语义在 `AppState.setFreezeNativeDockSwitching` 里，别在这里另写一份。
                state.setFreezeNativeDockSwitching(value)
            }
        )
    }
}

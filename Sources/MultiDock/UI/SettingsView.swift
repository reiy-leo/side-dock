import AppKit
import SwiftUI

/// 设置窗口当前显示的页。由侧边栏（SwiftUI List 选中项）写入，窗口装配侧也持有
/// —— 菜单/测试要指定页时走它。
@MainActor
@Observable
final class SettingsTabModel {
    var tab: SettingsTab = .general
}

/// 设置窗口的六个页（2026-10-06 起侧边栏呈现，系统设置风格；同日「桌面」拆出「应用栏」，
/// 2026-10-06 第 9 轮「菜单栏」从通用页拆出独立成页）。
enum SettingsTab: Hashable {
    case general
    case menuBar
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
                case .menuBar: MenuBarTab(state: state)
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

    /// 侧边栏布局（2026-10-06 用户要求）：主 tabs（通用/菜单栏/应用栏/桌面/数据）在顶部、
    /// 与窗口顶再让出一截；「关于」钉在列底。
    ///
    /// **为什么「关于」不走 List 行**：`List` 没有"行钉底"机制——中间塞 spacer 行
    /// 不会撑开（行高取内容理想值）。用 `safeAreaInset(edge: .bottom)` 承载一根
    /// 单行的原生 sidebar 小 `List`（与上方同一份 selection 绑定）：行样式、hover、
    /// 选中胶囊、窗口非激活变灰全走系统实现，不手绘。
    private var sidebar: some View {
        List(selection: tabSelection) {
            Section {
                Label(L("通用", "General"), systemImage: "gearshape").tag(SettingsTab.general)
                Label(L("菜单栏", "Menu Bar"), systemImage: "menubar.rectangle").tag(SettingsTab.menuBar)
                Label(L("应用栏", "Dock Bars"), systemImage: "dock.rectangle").tag(SettingsTab.appBars)
                Label(L("桌面", "Desktops"), systemImage: "rectangle.3.group").tag(SettingsTab.desktop)
                Label(L("数据", "Data"), systemImage: "externaldrive").tag(SettingsTab.data)
            }
        }
        // 无 titlebar 的窗口里红绿灯浮在侧边栏上，默认行距顶太近 —— 顶部再让出一截
        // （safeAreaInset 不产生可点击视图，不挡窗口顶部拖拽区）。
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 26)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            List(selection: tabSelection) {
                Label(L("关于", "About"), systemImage: "info.circle").tag(SettingsTab.about)
            }
            // 高度 = 单行 sidebar List 的自然高度（上下 contentInset ~10 + 行 ~28）。
            // 行高是系统固定值，窗口缩放不影响。
            .frame(height: 48)
        }
    }

    /// 上、下两个 List 共用同一份选中绑定：点「关于」时上方五行自动全不选，
    /// 点主 tabs 时底部「关于」自动取消高亮。
    private var tabSelection: Binding<SettingsTab> {
        Binding(
            get: { tabModel.tab },
            set: { tabModel.tab = $0 }
        )
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
        .help(L("\(icon.displayName)（Lucide \(icon.lucideName)）", "\(icon.displayName) (Lucide \(icon.lucideName))"))
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
                            Text(L("Dock 拉不回来", "Can't Bring the Dock Back"))
                                .font(.headline)
                            Text(L("\(reason)。可以点右边重试，或到「数据 → 备份与还原」恢复一份历史备份。",
                                   "\(reason). Retry on the right, or restore a backup from Data → Backups & Restore."))
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 4) {
                            Button(L("再试一次拉回", "Try Again")) { state.retryDockRevival() }
                            Button(L("立即还原到原始 Dock", "Restore Original Dock")) { state.restoreToBaselineNow() }
                        }
                    }
                }

                if let reason = state.spaceProviderWarning {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("桌面切换不可用", "Desktop Switching Unavailable"))
                                .font(.headline)
                            Text(L("\(reason)。Dock 配置仍能手动应用，但不会随桌面自动切换，菜单栏的切换按钮也不起作用。",
                                   "\(reason). Dock configuration can still be applied manually, but it won't follow desktops automatically, and the menu bar switcher won't work."))
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

// MARK: - 菜单栏

/// 「菜单栏」选项卡（2026-10-06 第 9 轮用户指令：从通用页拆出独立成页）。
///
/// 内容为原通用页「菜单栏」节整块迁入，按话题分成两组：**点击行为**
/// （左键动作 + 右键/⌥/⇧ 说明）与**图标**（Lucide 五选一）。
/// 行为、文案、绑定全部原样——只是换了承载页面。
private struct MenuBarTab: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section(L("点击行为", "Click Behavior")) {
                Picker(L("左键单击", "Left Click"), selection: clickActionBinding) {
                    ForEach(ClickAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .pickerStyle(.radioGroup)
                // 切桌面的系统滑动过渡**不做开关**（2026-10-06 实验 28：合成事件在本机被
                // 系统拦在投递层，阳性对照 Cmd+Tab 也不生效——开关能开也无效就是假开关）。
                // 研究留档：docs/spikes.md 实验 28；config 里有 `animatedDesktopSwitch` 供
                // 换机器/系统放开后手工开启。
                Text(L("右键或 ⌥+左键始终打开菜单。⇧+左键切上一个桌面；左键若设为「打开菜单」，⇧+左键也一并打开菜单。",
                       "Right-click or ⌥-click always opens the menu. ⇧-click switches to the previous desktop; if Left Click is set to “Open Menu”, ⇧-click opens the menu too."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L("图标", "Icon")) {
                HStack(spacing: 8) {
                    ForEach(MenuBarIcon.allCases, id: \.self) { icon in
                        MenuBarIconChoice(icon: icon, selection: menuBarIconBinding)
                    }
                }
                Text(L("换图标立即生效；图标旁的数字是当前桌面序号。",
                       "Icon changes apply immediately; the number next to the icon is the current desktop index."))
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
}

// MARK: - 通用

private struct GeneralTab: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            // 「应用」+「Dock 应用」+「桌面行为」合并为一节（2026-10-06 用户指令）：
            // 三块都是「本 App 如何写/管理原生 Dock」的话题（mru-spaces 也是 Dock 域键）。
            Section("Dock") {
                // 按钮多、文案长：用自适应换行布局，避免窄窗口下被截断（craft：不许出现省略号）。
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { applyButtons }
                    VStack(alignment: .leading, spacing: 6) { applyButtons }
                }
                if let reason = state.activeDesktopApplyBlockedReason {
                    Text(L("不能应用：\(reason)。", "Can't apply: \(reason)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(state.lastApplySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("编辑后立即应用", "Apply Immediately After Edits"), isOn: autoApplyBinding)
                Toggle(L("识别真实 Dock 上的手动改动并回存", "Detect Manual Edits in the Real Dock and Save Back"), isOn: autoCaptureBinding)
                Picker(L("重载方式", "Reload Method"), selection: reloadStrategyBinding) {
                    ForEach(ReloadStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                Text(L("实测：写偏好后 Dock 不会自己重读，改配置要重启 Dock 进程 —— SIGHUP 约 0.1 秒不可用，SIGTERM 约 0.4 秒。",
                       "Measured: the Dock doesn't re-read preferences on its own, so applying a config restarts the Dock process — SIGHUP costs ~0.1 s of downtime, SIGTERM ~0.4 s."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("根据最近使用自动重排空间（mru-spaces）", "Reorder Spaces by Recent Use (mru-spaces)"), isOn: mruSpacesBinding)
                    .disabled(state.mruSpaces == nil)
                Text(L("本机默认是开的。开着时系统会按最近使用重排桌面顺序，菜单栏的「切到下一个桌面」会变得不符合直觉，建议关掉。这个键不在常规写入范围内 —— 只有你在这里点开关才会改，改完会自动重启一次 Dock 生效。",
                       "On by default on this Mac. When on, macOS reorders desktops by recent use and “Switch to Next Desktop” becomes unintuitive, so turning it off is recommended. This key is outside the normal write set — only this switch changes it, and it takes effect after one Dock restart."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.mruSpaces == nil {
                    Text(L("当前 macOS 的 com.apple.dock 里没有这个键，因此不提供开关。",
                           "This macOS build has no such key in com.apple.dock, so no switch is offered."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L("启动、退出与自愈", "Launch, Quit & Self-Healing")) {
                Toggle(L("退出 App 时还原为原始 Dock", "Restore the Original Dock When Quitting"), isOn: restoreOnQuitBinding)
                Text(L("无痕原则：首次运行会把当时的 Dock 完整存为基准快照，退出时自动还原；被强杀或崩溃时，下次启动也会自动还原，并在屏幕上给出提示。",
                       "Trace-free principle: on first launch the Dock is saved in full as a baseline snapshot and restored on quit; after a force-quit or crash, the next launch restores it too and shows an on-screen notice."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("登录时自动启动", "Launch at Login"), isOn: loginItemBinding)
                    .disabled(!LoginItem.isAvailable)
                Text(state.loginItemStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !LoginItem.isAvailable {
                    Text(L("当前不在 .app 包里运行，登录启动不可用。用 ./scripts/build-app.sh 打包后再开。",
                           "Not running from an .app bundle, so Launch at Login is unavailable. Build with ./scripts/build-app.sh first."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary = state.selfHealSummary {
                    Label(summary, systemImage: "arrow.uturn.backward")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let stale = state.interruptedSession {
                    Text(L("上次未正常退出：PID \(String(stale.pid))", "Last quit was abnormal: PID \(String(stale.pid))"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 「应用」节的四个按钮（HStack / VStack 两种排布共用同一份）。
    @ViewBuilder
    private var applyButtons: some View {
        // 应用的是**当前桌面绑定的 Dock 栏**（2026-10-06 起没有自动内容源）。
        Button(L("应用当前桌面的 Dock 栏", "Apply This Desktop's Dock Bar")) { state.applyActiveDesktopDock() }
            .disabled(state.activeDesktopApplyBlockedReason != nil)
        Button(L("立即还原到原始 Dock", "Restore Original Dock")) { state.restoreToBaselineNow() }
        Button(L("把当前 Dock 设为新基准", "Use Current Dock as New Baseline")) { state.resetBaselineToCurrent() }
        Button(L("撤销自动回存", "Undo Auto Save-Back")) { state.undoLastAutoCapture() }
            .disabled(!state.canUndoAutoCapture())
            .help(L("撤销上一次「识别到你在真实 Dock 上的改动并回存」的覆盖（回存只落在活动桌面绑定的栏上）。",
                    "Undo the last automatic save-back from the real Dock (save-backs only target the active desktop's bound bar)."))
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
}

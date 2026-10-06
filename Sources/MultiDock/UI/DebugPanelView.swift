import SwiftUI
import AppKit

/// 调试面板：当前 spaceUUID / id64 / type、桌面列表、应用日志。
///
/// P1 的验收要靠它：切桌面 10 次，日志里 spaceUUID 必须全对、无漏报；
/// 进出全屏 App 不能触发切换、不能污染列表。
struct DebugPanelView: View {
    @Bindable var state: AppState
    @State private var autoScroll = true

    var body: some View {
        VSplitView {
            upper
                .frame(minHeight: 200)
            logSection
                .frame(minHeight: 200)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var upper: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusSection
                applicationSection
                desktopSection
                pathSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusSection: some View {
        GroupBox(L("当前状态", "Current Status")) {
            VStack(alignment: .leading, spacing: 6) {
                row(L("私有 API", "Private API"), state.spaceProviderAvailable ? L("可用", "available") : L("不可用", "unavailable"),
                    tint: state.spaceProviderAvailable ? .green : .red)
                if let warning = state.spaceProviderWarning {
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                row(L("显示器数量", "Displays"), "\(NSScreen.screens.count)")
                row(L("桌面数量", "Desktops"), "\(state.desktops.count)")
                if let active = state.activeSpace {
                    row(L("活动桌面", "Active desktop"),
                        L("\(state.displayName(for: active))（序号 \(active.ordinal)）",
                          "\(state.displayName(for: active)) (index \(active.ordinal))"))
                    row("spaceUUID", active.spaceUUID, mono: true)
                    row("id64", "\(active.id64)", mono: true)
                    row(L("type", "type"), L("\(active.type)（0 = 用户桌面）", "\(active.type) (0 = user desktop)"), mono: true)
                    row("displayUUID", active.displayUUID, mono: true)
                } else {
                    row(L("活动桌面", "Active desktop"), L("不属于任何用户桌面（可能在全屏 App 空间）", "not a user desktop (possibly a full-screen app space)"), tint: .orange)
                }
                HStack(spacing: 8) {
                    Button(L("测试 toast", "Test Toast")) { state.showTestToast() }
                    Text(L("在桌面所在显示器的中上部显示当前桌面名，1 秒后自动消失（不受「上一个桌面」条件限制）。", "Shows the current desktop name on that desktop's display; disappears after one second (not limited by the “previous desktop” condition)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let stale = state.interruptedSession {
                    row(L("残留会话标记", "Stale session marker"),
                        L("PID \(stale.pid)，开始于 \(stale.startedAt.formatted())",
                          "PID \(stale.pid), started \(stale.startedAt.formatted())"),
                        tint: stale.impliesDirtyDock ? .orange : .secondary)
                }
                if let monitor = state.dockPresenceMonitor {
                    row(L("Dock 存活监视", "Dock presence monitor"),
                        L("\(monitor.isRunning ? "运行中" : "已停止")　连续缺失 \(monitor.consecutiveMisses) 次　"
                            + "恢复 \(monitor.recoveryCount) 次　拉回尝试 \(monitor.kickstartCount) 次",
                          "\(monitor.isRunning ? "running" : "stopped")　misses \(monitor.consecutiveMisses)　"
                            + "recoveries \(monitor.recoveryCount)　pull-back attempts \(monitor.kickstartCount)"),
                        tint: monitor.isPersistentlyDown ? .red : .secondary)
                    if let reason = state.dockFailureWarning {
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    row(L("Dock 存活监视", "Dock presence monitor"), L("未启动", "not started"), tint: .orange)
                }
                row(L("基准快照", "Baseline snapshot"), state.baselineCapturedThisLaunch ? L("本次启动新建", "created this launch") : L("沿用已有", "reused"))
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var desktopSection: some View {
        GroupBox(L("识别到的用户桌面（按 Spaces 数组顺序，即左右顺序）", "Detected user desktops (in Spaces array order, i.e. left-to-right)")) {
            VStack(alignment: .leading, spacing: 4) {
                if state.desktops.isEmpty {
                    Text(L("（无）", "(none)"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.desktops) { space in
                        HStack(spacing: 8) {
                            Text(space.id == state.activeSpace?.id ? "▶" : " ")
                                .font(.body.monospaced())
                                .foregroundStyle(.tint)
                            Text(state.displayName(for: space))
                                .frame(width: 60, alignment: .leading)
                            // 多显示器时 displayUUID 是映射键的一部分，插拔外接屏后靠它核对有没有串。
                            Text(space.displayUUID.isEmpty ? "—" : String(space.displayUUID.prefix(8)))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .help(space.displayUUID)
                            Text(space.spaceUUID)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Text("id64=\(space.id64)  type=\(space.type)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 「最近一次应用」：计划 §3.4 第 6 条要求把 `appliedFingerprint` / `appliedAt` /
    /// 重载方式 / 耗时记到**调试面板可见**的地方。
    ///
    /// 应用摘要（含重载方式与耗时）平时在设置页也有一份；这里补的是**调试口径**：
    /// 内容指纹、写入时刻、以及两个"我们凭什么判断状态"的闸门（本次运行是否改过 Dock、
    /// 回存闸门是否打开）。排查"回存没生效 / 白重启一次"这类问题时看的就是这几行。
    private var applicationSection: some View {
        GroupBox(L("最近一次应用", "Last Apply")) {
            VStack(alignment: .leading, spacing: 6) {
                row(L("结果摘要", "Result summary"), state.lastApplySummary)
                row(L("内容指纹", "Content fingerprint"), fingerprintText, mono: true)
                row(L("写入时刻", "Applied at"), appliedAtText)
                row(L("本次运行改过 Dock", "Dock changed this run"), state.hasAppliedDockConfig ? L("是", "yes") : L("否", "no"))
                row(L("回存闸门", "Save-back gate"), state.dockController.appliedComparableFingerprint == nil ? L("关闭（还没写过）", "closed (nothing written yet)") : L("打开", "open"))
                Text(L("回存闸门打开后，`DockWatcher` 才会把真实 Dock 上的手动改动回存到当前桌面；"
                        + "内容指纹用来短路\"这份配置已经生效\"，避免白写一遍 + 白重启一次 Dock。",
                      "Only once the save-back gate is open will `DockWatcher` save manual Dock edits back to the current desktop; "
                        + "the content fingerprint short-circuits \"this config is already applied\", avoiding a wasted write and Dock restart."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 指纹是多行文本（apps / others / appearance 三段），只展示前两行 + 长度，便于对照日志。
    private var fingerprintText: String {
        guard let fingerprint = state.dockController.appliedFingerprint else { return L("（还没写过）", "(nothing written yet)") }
        let lines = fingerprint.split(separator: "\n")
        let head = lines.prefix(2).joined(separator: " / ")
        let trimmed = head.count > 72 ? String(head.prefix(72)) + "…" : head
        return L("\(trimmed)（共 \(fingerprint.count) 字符）", "\(trimmed) (\(fingerprint.count) chars total)")
    }

    private var appliedAtText: String {
        guard let at = state.dockController.appliedAt else { return L("（还没写过）", "(nothing written yet)") }
        let seconds = Date().timeIntervalSince(at)
        return L("\(at.formatted(.dateTime.hour().minute().second()))（\(String(format: "%.0f", seconds)) 秒前）",
                 "\(at.formatted(.dateTime.hour().minute().second())) (\(String(format: "%.0f", seconds)) s ago)")
    }

    private var pathSection: some View {
        GroupBox(L("文件位置", "File Locations")) {
            VStack(alignment: .leading, spacing: 4) {
                row(L("基准快照", "Baseline snapshot"), state.baselinePath, mono: true)
                row(L("配置文件", "Config file"), state.configPath, mono: true)
                row(L("日志文件", "Log file"), state.logPath, mono: true)
                Text(L("基准快照是首次运行时对 com.apple.dock 全量域的只读备份，此后不覆盖；每次真正写 Dock 之前另存一份到 backups/。", "The baseline snapshot is a read-only copy of the whole com.apple.dock domain from first launch; it's never overwritten. Another copy is saved to backups/ before every real Dock write."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("应用日志（\(state.log.count)）", "App Log (\(state.log.count))"))
                    .font(.headline)
                Spacer()
                Toggle(L("自动滚到底部", "Auto-scroll to bottom"), isOn: $autoScroll)
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(state.log) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(entry.timestamp.formatted(.dateTime.hour().minute().second()))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(entry.level.symbol)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(color(for: entry.level))
                                Text(entry.message)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.log.count) {
                    guard autoScroll, let last = state.log.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false, tint: Color = .primary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .frame(width: 96, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .caption.monospaced() : .body)
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

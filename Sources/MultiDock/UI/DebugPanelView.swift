import SwiftUI

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
                desktopSection
                pathSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusSection: some View {
        GroupBox("当前状态") {
            VStack(alignment: .leading, spacing: 6) {
                row("私有 API", state.spaceProviderAvailable ? "可用" : "不可用",
                    tint: state.spaceProviderAvailable ? .green : .red)
                if let warning = state.spaceProviderWarning {
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                row("桌面数量", "\(state.desktops.count)")
                if let active = state.activeSpace {
                    row("活动桌面", "\(active.displayName)（序号 \(active.ordinal)）")
                    row("spaceUUID", active.spaceUUID, mono: true)
                    row("id64", "\(active.id64)", mono: true)
                    row("type", "\(active.type)（0 = 用户桌面）", mono: true)
                    row("displayUUID", active.displayUUID, mono: true)
                } else {
                    row("活动桌面", "不属于任何用户桌面（可能在全屏 App 空间）", tint: .orange)
                }
                if let stale = state.interruptedSession {
                    row("残留会话标记", "PID \(stale.pid)，开始于 \(stale.startedAt.formatted())",
                        tint: stale.impliesDirtyDock ? .orange : .secondary)
                }
                row("基准快照", state.baselineCapturedThisLaunch ? "本次启动新建" : "沿用已有")
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var desktopSection: some View {
        GroupBox("识别到的用户桌面（按 Spaces 数组顺序，即左右顺序）") {
            VStack(alignment: .leading, spacing: 4) {
                if state.desktops.isEmpty {
                    Text("（无）")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.desktops) { space in
                        HStack(spacing: 8) {
                            Text(space.id == state.activeSpace?.id ? "▶" : " ")
                                .font(.body.monospaced())
                                .foregroundStyle(.tint)
                            Text(space.displayName)
                                .frame(width: 60, alignment: .leading)
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

    private var pathSection: some View {
        GroupBox("文件位置") {
            VStack(alignment: .leading, spacing: 4) {
                row("基准快照", state.baselinePath, mono: true)
                row("配置文件", state.configPath, mono: true)
                row("日志文件", state.logPath, mono: true)
                Text("P1 阶段不会写入任何 Dock 设置；基准快照是首次运行时对 com.apple.dock 全量域的只读备份。")
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
                Text("应用日志（\(state.log.count)）")
                    .font(.headline)
                Spacer()
                Toggle("自动滚到底部", isOn: $autoScroll)
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

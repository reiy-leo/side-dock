import AppKit
import SwiftUI

/// 「启动台」Tab（2026-10-06 用户规格）：
/// **从启动台读出所有文件夹（名称 + 包含的 App），每个文件夹可以「添加到某个 Dock」或「替换某个 Dock」。**
///
/// 只在**macOS 26 以下**有意义 —— 26 起系统用「应用程序」取代了启动台，
/// 那份按文件夹编排的数据不复存在，本页显示说明并禁用全部操作。
///
/// 数据只读（启动台自己的 SQLite 库），零权限、零网络、不修改启动台一个字节；
/// 写出去的方向只有「目标 Dock 栏」，仍走 `dockBarEdited` 那条既定通路
/// （落盘 + 冻结模式语义 + 次级条刷新都在里面）。
struct LaunchpadTab: View {
    @Bindable var state: AppState

    /// 每个文件夹行下方的操作结果（itemID → 一句话），失败与成功同栏呈现。
    @State private var outcomes: [Int: LaunchpadOperationOutcome] = [:]
    @State private var hoveredRow: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch state.launchpadStatus {
                case .unsupportedSystem:
                    unsupportedNotice
                case .unavailable(let reason):
                    unavailableNotice(reason)
                case .notLoaded:
                    loadingNotice
                case .loaded:
                    folderList
                }
            }
            // 与其它页的 Form 分组保持同一版心（两侧各让 60 pt）。
            .padding(.horizontal, 60)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { state.refreshLaunchpadFolders() }
    }

    // MARK: - 状态分支

    private var unsupportedNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("这台 Mac 没有启动台", "This Mac Has No Launchpad"), systemImage: "square.grid.2x2")
                .font(.headline)
            Text(L("macOS 26 起系统用「应用程序」取代了启动台，按文件夹编排的那份数据也不复存在，所以这个页面无从读取。此页在 macOS 26 以下可用。",
                   "macOS 26 replaced Launchpad with Applications, so the folder-based data this tab reads no longer exists. This tab is available on macOS 26 and earlier."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func unavailableNotice(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("读不到启动台", "Can't Read Launchpad"), systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("刷新", "Refresh")) { state.refreshLaunchpadFolders() }
        }
    }

    private var loadingNotice: some View {
        Text(L("正在读取启动台…", "Reading Launchpad…"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - 文件夹列表

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L("启动台文件夹（\(state.launchpadFolders.count)）",
                       "Launchpad Folders (\(state.launchpadFolders.count))"))
                    .font(.headline)
                Spacer(minLength: 8)
                Button(L("刷新", "Refresh")) { state.refreshLaunchpadFolders() }
                    .controlSize(.small)
                    .help(L("重新读取启动台数据库（在启动台里改过文件夹后点它）",
                            "Re-read the Launchpad database (use this after changing folders in Launchpad)"))
            }
            .padding(.bottom, 6)

            if state.launchpadFolders.isEmpty {
                Text(L("启动台里还没有文件夹。在启动台里把 App 拖到一起成组，再回这里刷新。",
                       "No folders in Launchpad yet. Group apps together in Launchpad, then refresh here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(state.launchpadFolders) { folder in
                        folderRow(folder)
                    }
                }
            }

            Text(L("只读启动台数据库，不改动它；操作只写目标 Dock 栏。已固定在原生 Dock 的 App 不会重复加入（2026-10-06 既有规则）。",
                   "The Launchpad database is read-only; actions only write to the target Dock bar. Apps already pinned in the native Dock are never duplicated (existing rule)."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    /// 一行文件夹：名称 + 计数 + App 图标预览；右侧两个操作：
    /// 「添加到 Dock 栏 ▾」把本文件夹的 App 并入某根栏，**不清空它**；
    /// 「替换 Dock 栏 ▾」清空某根栏，换成这个文件夹的内容。
    private func folderRow(_ folder: LaunchpadFolder) -> some View {
        let isHovered = hoveredRow == folder.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(folderCountText(folder))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 150, alignment: .leading)

                iconPreview(folder)

                Spacer(minLength: 8)

                addMenu(folder)
                replaceMenu(folder)
            }

            if let outcome = outcomes[folder.id] {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: outcome.failed ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(outcome.failed ? Color.orange : Color.secondary)
                    Text(outcome.message)
                        .font(.caption)
                        .foregroundStyle(outcome.failed ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L("知道了", "OK")) { outcomes[folder.id] = nil }
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .onHover { inside in
            if inside { hoveredRow = folder.id }
            else if hoveredRow == folder.id { hoveredRow = nil }
        }
    }

    private func folderCountText(_ folder: LaunchpadFolder) -> String {
        var text = L("\(folder.apps.count) 个 App", "\(folder.apps.count) app(s)")
        if folder.unresolvedCount > 0 {
            text += L("（\(folder.unresolvedCount) 个定位不到）", " (\(folder.unresolvedCount) not found)")
        }
        return text
    }

    /// App 图标预览：只显示图标、不显示名字（与应用栏编辑器同口径），名字靠悬停 tooltip。
    private func iconPreview(_ folder: LaunchpadFolder) -> some View {
        let shown = folder.apps.prefix(10)
        return HStack(spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, app in
                if let tile = app.tile {
                    Image(nsImage: DockStripRules.icon(for: tile, size: 22))
                        .resizable()
                        .frame(width: 22, height: 22)
                        .help(app.title)
                } else {
                    // 定位不到的条目占位（虚线框），一眼能看出这个文件夹有搬不了的成员。
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
                        .foregroundStyle(Color(nsColor: .separatorColor))
                        .frame(width: 22, height: 22)
                        .help(L("\(app.title)（定位不到）", "\(app.title) (not found)"))
                }
            }
            if folder.apps.count > shown.count {
                Text("+\(folder.apps.count - shown.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 操作菜单

    /// 目标栏列表的菜单项。用 `Menu` + `Button`（不是 `Picker`）：
    /// 每个文件夹行都要独立弹一份，且行标签要带图标数说明。
    private func addMenu(_ folder: LaunchpadFolder) -> some View {
        Menu {
            barActions(for: folder) { bar in
                state.addLaunchpadFolder(folder, to: bar.id)
            }
        } label: {
            Text(L("添加到…", "Add to…"))
        }
        .frame(width: 110)
        .fixedSize()
        .disabled(state.dockBars.isEmpty)
        .help(L("把这个文件夹的 App 并入所选 Dock 栏（栏里已有的不重复加）",
                "Append this folder's apps to the chosen Dock bar (existing icons are kept)"))
    }

    private func replaceMenu(_ folder: LaunchpadFolder) -> some View {
        Menu {
            barActions(for: folder) { bar in
                state.replaceDockBar(bar.id, withLaunchpadFolder: folder)
            }
        } label: {
            Text(L("替换…", "Replace…"))
        }
        .frame(width: 110)
        .fixedSize()
        .disabled(state.dockBars.isEmpty)
        .help(L("清空所选 Dock 栏，换成这个文件夹的内容",
                "Clear the chosen Dock bar and fill it with this folder's contents"))
    }

    private func barActions(
        for folder: LaunchpadFolder,
        perform: @escaping (DockBar) -> LaunchpadOperationOutcome
    ) -> some View {
        Group {
            if state.dockBars.isEmpty {
                Text(L("还没有 Dock 栏", "No Dock bars yet"))
            } else {
                ForEach(state.dockBars) { bar in
                    Button {
                        outcomes[folder.id] = perform(bar)
                    } label: {
                        Text(barMenuTitle(bar))
                    }
                }
            }
        }
    }

    /// 菜单项标题：「栏名（N 个图标 · 桌面名 / 未绑定）」——搬之前就能看清目标是谁。
    private func barMenuTitle(_ bar: DockBar) -> String {
        let target: String
        if let spaceID = bar.spaceID,
           let space = state.desktops.first(where: { $0.id == spaceID }) {
            target = state.displayName(for: space)
        } else {
            target = L("未绑定", "Unbound")
        }
        return L("\(bar.name)（\(bar.apps.count) 个图标 · \(target)）",
                 "\(bar.name) (\(bar.apps.count) icons · \(target))")
    }
}

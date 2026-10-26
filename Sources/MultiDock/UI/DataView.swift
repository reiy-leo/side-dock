import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 「数据」选项卡：配置的导出 / 导入 + 备份与还原（2026-10-06 自通用页迁入）。
///
/// 导出 = 把当前 `config.json` 的同构 Payload（设置 + Dock 栏 + 桌面命名）写成用户选择的文件；
/// 导入 = 反向：解码 → 走与启动加载**同一套**归一化/迁移 → 落盘。导入会换掉整套设置
/// （含冻结开关等），但**不自动应用 Dock** —— 原生 Dock 由「立即应用」/ 切桌面 / 下次启动跟上，
/// 次级条与绑定即时生效。
struct DataView: View {
    @Bindable var state: AppState
    /// 待确认的备份恢复。恢复备份会真的重启 Dock，必须二次确认。
    @State private var pendingBackup: BaselineStore.BackupEntry?
    /// 待确认的同步导入（从云端恢复本机那份 / 导入别的设备那份）。都会整份替换本机设置。
    @State private var pendingSyncImport: ConfigSyncFolder.Entry?

    var body: some View {
        Form {
            Section(L("配置文件", "Configuration File")) {
                HStack(spacing: 8) {
                    Button(L("导出配置…", "Export Config…")) { exportConfiguration() }
                    Button(L("导入配置…", "Import Config…")) { importConfiguration() }
                    Spacer()
                }
                Text(L("导出 = 把当前全部设置（Dock 栏、绑定、命名、各开关）存成一个 JSON 文件；导入会用文件里的内容整份替换当前设置并落盘（与启动加载同一套归一化/迁移）。次级条与绑定导入即生效；原生 Dock 由「立即应用」（通用页）/ 切桌面 / 下次启动跟上。", "Export saves all current settings (Dock bars, bindings, names, switches) as one JSON file; import replaces the whole configuration with the file's content and writes it to disk (same normalization/migration as launch). Secondary bars and bindings take effect immediately; the native Dock follows via “Apply” (General tab) / desktop switching / next launch."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = state.lastDataOperationMessage {
                    Label(
                        message,
                        systemImage: state.lastDataOperationFailed
                            ? "exclamationmark.triangle"
                            : "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(state.lastDataOperationFailed ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                // 路径是"查证用"的次级信息，收进脚注行、弱化呈现（craft：主次分明）。
                HStack(spacing: 6) {
                    Text(L("文件", "File"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(state.configPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            syncSection

            Section(L("备份与还原", "Backups & Restore")) {
                if state.backups.isEmpty {
                    Text(L("还没有历史备份。每次真正写 Dock 之前都会自动留一份，最多保留 20 份。", "No backups yet. One is kept automatically before every real Dock write, up to 20."))
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
                            Button(L("恢复", "Restore")) { pendingBackup = entry }
                        }
                    }
                    if state.backups.count > 5 {
                        Text(L("只列出最近 5 份，共 \(state.backups.count) 份。", "Showing the latest 5 of \(state.backups.count)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button(L("刷新列表", "Refresh List")) { state.refreshBackups() }
                Text(L("恢复备份只覆盖 Dock 的图标等内容，不动热角、启动台网格等设置 —— 因为我们从来只写那几项。", "Restoring a backup only overwrites Dock contents (icons etc.), not hot corners or Launchpad layout — we only ever write those few keys."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            state.refreshBackups()
            state.refreshSyncSnapshots()
        }
        .alert(
            L("恢复这份备份？", "Restore This Backup?"),
            isPresented: Binding(
                get: { pendingBackup != nil },
                set: { if !$0 { pendingBackup = nil } }
            ),
            presenting: pendingBackup
        ) { entry in
            Button(L("恢复", "Restore"), role: .destructive) {
                state.restoreBackup(entry)
                pendingBackup = nil
            }
            Button(L("取消", "Cancel"), role: .cancel) { pendingBackup = nil }
        } message: { entry in
            Text(L("会用 \(entry.fileName) 里的内容覆盖当前 Dock，并重启一次 Dock（约 0.1 秒不可用）。", "The contents of \(entry.fileName) will overwrite the current Dock, restarting it once (~0.1 s unavailable)."))
        }
    }

    // MARK: - 同步（2026-10-26）

    private var hasSyncFolder: Bool { state.syncSettings.folderPath != nil }

    @ViewBuilder
    private var syncSection: some View {
        Section(L("同步", "Sync")) {
            HStack(spacing: 8) {
                Text(L("同步文件夹", "Sync Folder"))
                Spacer(minLength: 12)
                if let path = state.syncSettings.folderPath {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(path)
                } else {
                    Text(L("还没选", "Not set"))
                        .foregroundStyle(.secondary)
                }
                Button(hasSyncFolder ? L("更换…", "Change…") : L("选择…", "Choose…")) { chooseSyncFolder() }
            }
            if hasSyncFolder, !state.syncFolderAvailable {
                Label(
                    L("现在找不到这个文件夹。云盘没开，或者没挂载？", "This folder can't be found right now. Is the cloud drive running or mounted?"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(
                L("自动同步", "Sync Automatically"),
                isOn: Binding(
                    get: { state.syncSettings.autoSync },
                    set: { state.setAutoSync($0) }
                )
            )
            .disabled(!hasSyncFolder)
            HStack(spacing: 8) {
                Button(L("立即同步", "Sync Now")) { _ = state.syncNow() }
                    .disabled(!hasSyncFolder)
                Button(L("刷新列表", "Refresh List")) { _ = state.refreshSyncSnapshots() }
                    .disabled(!hasSyncFolder)
                Spacer()
                if hasSyncFolder {
                    Button(L("停止同步", "Stop Syncing")) { state.clearSyncFolder() }
                }
            }
            .alert(
                pendingSyncImport.map { state.isThisDevice($0) } == true
                    ? L("从云端恢复本机设置？", "Restore This Mac's Settings?")
                    : L("导入这台 Mac 的设置？", "Import Settings from This Mac?"),
                isPresented: Binding(
                    get: { pendingSyncImport != nil },
                    set: { if !$0 { pendingSyncImport = nil } }
                ),
                presenting: pendingSyncImport
            ) { entry in
                Button(state.isThisDevice(entry) ? L("恢复", "Restore") : L("导入", "Import"), role: .destructive) {
                    state.importSyncSnapshot(entry)
                    pendingSyncImport = nil
                }
                Button(L("取消", "Cancel"), role: .cancel) { pendingSyncImport = nil }
            } message: { entry in
                if state.isThisDevice(entry) {
                    Text(L("会用云端这份换掉本机现在的全部设置。原生 Dock 不会马上变。",
                           "The cloud copy replaces all current settings on this Mac. The native Dock doesn't change right away."))
                } else {
                    Text(L("会用「\(entry.snapshot.deviceName)」的设置换掉本机全部设置。桌面按序号对应：第几块屏的第几个桌面。对不上的栏会变成孤儿栏，在「应用栏」页解绑。",
                           "Settings from “\(entry.snapshot.deviceName)” replace all settings on this Mac. Desktops are matched by order: the Nth desktop on the Nth display. Bars that don't match become orphans; unbind them in the Dock Bars tab."))
                }
            }
            if let message = syncStatusLine {
                Label(message, systemImage: state.syncStatusFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(state.syncStatusFailed ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(state.syncSnapshots) { entry in
                syncSnapshotRow(entry)
            }
            if state.syncUnreadableCount > 0 {
                Text(L("还有 \(state.syncUnreadableCount) 个文件读不懂，已跳过。", "\(state.syncUnreadableCount) file(s) couldn't be read and were skipped."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L("每台 Mac 只写自己那份，放在文件夹里的 SideDock 下，不碰别的设备。上传下载交给云盘客户端，比如 Google Drive 桌面版、iCloud Drive。备份、基准快照和同步设置只留在本机。",
                   "Each Mac writes only its own file, under SideDock in this folder, and never touches other devices' files. Your cloud client (Google Drive for desktop, iCloud Drive…) does the uploading. Backups, the baseline snapshot and sync settings stay on this Mac."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 结果一句话：有新结果显示结果，否则显示上次同步时间。
    private var syncStatusLine: String? {
        if let message = state.syncStatusMessage { return message }
        guard hasSyncFolder, let last = state.syncSettings.lastSyncAt else { return nil }
        return L("上次同步：\(last.formatted(date: .abbreviated, time: .shortened))",
                 "Last synced: \(last.formatted(date: .abbreviated, time: .shortened))")
    }

    private func syncSnapshotRow(_ entry: ConfigSyncFolder.Entry) -> some View {
        let mine = state.isThisDevice(entry)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.snapshot.deviceName)
                    if mine {
                        Text(L("本机", "This Mac"))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    }
                }
                Text(entry.snapshot.writtenAt.formatted(date: .abbreviated, time: .shortened)
                    + (entry.snapshot.appVersion.isEmpty ? "" : " · \(entry.snapshot.appVersion)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(mine ? L("从云端恢复", "Restore from Cloud") : L("导入到本机", "Import to This Mac")) {
                pendingSyncImport = entry
            }
        }
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("选这个文件夹", "Choose Folder")
        panel.message = L("选一个云盘里的文件夹，比如 Google Drive 的「我的云端硬盘」。", "Pick a folder in your cloud drive, such as “My Drive” in Google Drive.")
        if let current = state.syncFolderURL { panel.directoryURL = current }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.chooseSyncFolder(url)
    }

    // MARK: - 导出 / 导入

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = L("SideDock-配置-\(dateStamp).json", "SideDock-config-\(dateStamp).json")
        panel.prompt = L("导出", "Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.exportConfiguration(to: url)
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("导入", "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.importConfiguration(from: url)
    }

    private var dateStamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}

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
        .onAppear { state.refreshBackups() }
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

    // MARK: - 导出 / 导入

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = L("MultiDock-配置-\(dateStamp).json", "MultiDock-config-\(dateStamp).json")
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

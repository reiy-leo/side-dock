import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 一根 Dock 栏的图标编辑器（2026-10-05 用户规格）：
/// **横向**一条（不管栏在屏幕上是横是竖，设置页里永远横排），
/// 默认露出 **8 个槽位**，超过走滚动；图标数 **1...15**（下限由「最后一个图标不可删」保证，
/// 上限由「添加」禁用 + 拒绝超量拖入保证）。
///
/// 结构固定为：**[访达] [启动台] [可编辑的 App…] [＋]** —— 与原生 Dock 的口径一致：
/// 访达是幻影（偏好域里没有表示），启动台由 `DockStripRules` 保证在首位。
///
/// 编辑只改内存（`bar` 绑定）；落盘/应用由 `onCommit` 一次性交给 `AppState`。
/// ⚠️ 其他项（文件夹/堆栈）不能在这里新建（实验 8：自拼目录条目 Dock 不认领、坏形状崩 Dock）；
/// 迁移带进来的其他项不在本编辑器显示（原生 Dock 写入时随栏一并写回）。
struct DockBarEditor: View {
    @Binding var bar: DockBar
    /// 一次编辑完成（排序落定 / 移除 / 添加）后回调，参数是给日志看的中文说明。
    var onCommit: (DockBar, String) -> Void

    @State private var dragging: String?
    @State private var isFileTargeted = false
    /// 拖入被拒（文件夹 / 普通文件 / 超出上限）时的说明。**不留静默失败**。
    @State private var rejectionMessage: String?

    private let iconSize: CGFloat = 44
    private let slotSize: CGFloat = 60

    /// 默认露出 8 个槽位：固定编辑条宽度，内容多了走滚动。
    private var stripWidth: CGFloat { CGFloat(DockBar.visibleSlots) * slotSize + 24 }

    private var editable: [DockTile] {
        var seen = Set<String>()
        return DockStripRules.editableApps(bar.apps)
            .filter { seen.insert($0.normalizedKey).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            strip
            controls
        }
    }

    // MARK: - 图标条

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { slots }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(width: stripWidth, height: slotSize + 12, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isFileTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: isFileTargeted ? 2 : 1)
        )
        // 从访达拖 .app 进来。只认文件 URL，不会和内部的排序拖拽打架。
        .dropDestination(for: URL.self) { urls, _ in
            addDropped(urls)
        } isTargeted: { targeted in
            isFileTargeted = targeted
        }
    }

    @ViewBuilder
    private var slots: some View {
        finderSlot
        launchpadSlot
        ForEach(editable, id: \.normalizedKey) { tile in
            editableSlot(tile)
        }
        appendSlot
    }

    private var finderSlot: some View {
        VStack(spacing: 2) {
            Image(nsImage: DockStripRules.icon(forPath: DockStripRules.finderPath, size: iconSize))
                .resizable()
                .frame(width: iconSize, height: iconSize)
            Text("访达")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: slotSize)
        .help("访达永远在 Dock 最左侧。系统不把它存在偏好里，所以既不需要也不能修改。")
    }

    private var launchpadSlot: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: DockStripRules.icon(forPath: DockStripRules.launchpadPath, size: iconSize))
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            Text("启动台")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: slotSize)
        .help("启动台固定在图标条最前面，不能移除或移动。")
    }

    private func editableSlot(_ tile: DockTile) -> some View {
        let installed = DockStripRules.isInstalled(tile)
        let canRemove = editable.count > 1
        return VStack(spacing: 2) {
            Image(nsImage: DockStripRules.icon(for: tile, size: iconSize))
                .resizable()
                .frame(width: iconSize, height: iconSize)
                .opacity(installed ? 1 : 0.35)
            Text(tile.label)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(installed ? Color.primary : Color.secondary)
        }
        .frame(width: slotSize)
        .opacity(dragging == tile.normalizedKey ? 0.4 : 1)
        .contentShape(Rectangle())
        .help(installed ? tile.label : "\(tile.label)（磁盘上找不到这个 App）")
        .onDrag {
            dragging = tile.normalizedKey
            return NSItemProvider(object: tile.normalizedKey as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: BarReorderDropDelegate(
                target: tile,
                currentDragging: { dragging },
                apps: $bar.apps,
                onFinish: { onCommit(bar, "调整「\(bar.name)」的图标顺序") }
            )
        )
        .contextMenu {
            Button("从 Dock 栏移除") { remove(tile) }
                .disabled(!canRemove)
            if !canRemove {
                Text("每根栏至少要留 1 个图标")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appendSlot: some View {
        Button {
            presentAppPicker()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: editable.count >= DockBar.maxApps ? "checkmark" : "plus")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: iconSize, height: iconSize)
                Text(editable.count >= DockBar.maxApps ? "已满" : "添加")
                    .font(.caption2)
            }
            .frame(width: slotSize)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(editable.count >= DockBar.maxApps)
        .help(editable.count >= DockBar.maxApps
              ? "每根栏最多 \(DockBar.maxApps) 个图标"
              : "从访达拖 .app 到图标条上，或点这里选择。")
        .onDrop(
            of: [.text],
            delegate: BarAppendDropDelegate(
                currentDragging: { dragging },
                apps: $bar.apps,
                onFinish: { onCommit(bar, "把 App 移到「\(bar.name)」末尾") }
            )
        )
    }

    // MARK: - 底部控件

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(editable.count)/\(DockBar.maxApps) 个图标")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                removeZone
                Text("拖到这里移除")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 拖入被拒时说清原因 —— 静默失败会让人以为程序坏了。
            if let rejectionMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(rejectionMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("知道了") { self.rejectionMessage = nil }
                        .font(.caption)
                }
            }
        }
    }

    private var removeZone: some View {
        Image(systemName: "trash")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color(nsColor: .separatorColor))
            )
            .onDrop(of: [.text], delegate: BarRemoveDropDelegate(
                currentDragging: { dragging },
                apps: $bar.apps,
                onRemove: { note in onCommit(bar, note) },
                onReject: { rejectionMessage = "每根栏至少要留 1 个图标" }
            ))
    }

    // MARK: - 编辑动作

    private func commitApps(_ apps: [DockTile], note: String) {
        let normalized = DockStripRules.apps(fromEditable: apps, preserving: bar.apps)
        guard normalized != bar.apps else { return }
        bar.apps = normalized
        onCommit(bar, note)
    }

    private func remove(_ tile: DockTile) {
        guard editable.count > 1 else {
            rejectionMessage = "每根栏至少要留 1 个图标"
            return
        }
        var apps = editable
        apps.removeAll { $0.normalizedKey == tile.normalizedKey }
        commitApps(apps, note: "从「\(bar.name)」移除「\(tile.label)」")
    }

    /// 从访达拖进来的 URL：只接受 `.app`；文件夹 / 普通文件 / 超出上限**明确拒绝并说明原因**。
    private func addDropped(_ urls: [URL]) -> Bool {
        var apps = editable
        var added = 0
        var rejection: String?
        for url in urls {
            if apps.count >= DockBar.maxApps {
                rejection = "每根栏最多 \(DockBar.maxApps) 个图标，「\(url.deletingPathExtension().lastPathComponent)」没有加进来"
                continue
            }
            if let reason = DockStripRules.rejectionReason(for: url.path) {
                rejection = rejection ?? reason.message
                continue
            }
            guard let tile = DockStripRules.tile(forAppAt: url.path) else {
                rejection = rejection ?? DockItemRejection.notAnApp.message
                continue
            }
            guard !apps.contains(where: { $0.normalizedKey == tile.normalizedKey }) else { continue }
            apps.append(tile)
            added += 1
        }
        rejectionMessage = rejection
        guard added > 0 else { return false }
        commitApps(apps, note: "拖入 \(added) 个 App 到「\(bar.name)」")
        return true
    }

    /// 选择器只让选 `.app`：文件夹 / 文件这条路是**故意关掉**的（见 `DockItemRejection`）。
    private func presentAppPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "添加到 Dock 栏"
        guard panel.runModal() == .OK else { return }
        _ = addDropped(panel.urls)
    }
}

// MARK: - 拖拽排序

/// 把被拖条目移动到目标位置。
///
/// 拖拽过程中**只改内存模型**（`bar.apps`），真正的「落盘 + 应用」由 `onFinish` 一次性触发 ——
/// 否则拖过 10 个位置就会落 10 次盘。
private struct BarReorderDropDelegate: DropDelegate {
    let target: DockTile
    let currentDragging: () -> String?
    @Binding var apps: [DockTile]
    let onFinish: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = currentDragging(), dragged != target.normalizedKey else { return }
        let editable = DockStripRules.editableApps(apps)
        guard
            let from = editable.firstIndex(where: { $0.normalizedKey == dragged }),
            let to = editable.firstIndex(where: { $0.normalizedKey == target.normalizedKey }),
            from != to
        else { return }

        var reordered = editable
        let item = reordered.remove(at: from)
        reordered.insert(item, at: to)
        apps = DockStripRules.apps(fromEditable: reordered, preserving: apps)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        onFinish()
        return true
    }
}

/// 拖到「添加」格子上 = 移到末尾。
private struct BarAppendDropDelegate: DropDelegate {
    let currentDragging: () -> String?
    @Binding var apps: [DockTile]
    let onFinish: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = currentDragging() else { return }
        var editable = DockStripRules.editableApps(apps)
        guard let from = editable.firstIndex(where: { $0.normalizedKey == dragged }),
              from != editable.count - 1 else { return }
        let item = editable.remove(at: from)
        editable.append(item)
        apps = DockStripRules.apps(fromEditable: editable, preserving: apps)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        onFinish()
        return true
    }
}

/// 拖到垃圾桶 = 移除。少于 1 个图标时通过 `onReject` 说明原因，不静默失败。
private struct BarRemoveDropDelegate: DropDelegate {
    let currentDragging: () -> String?
    @Binding var apps: [DockTile]
    let onRemove: (String) -> Void
    let onReject: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = currentDragging() else { return false }
        var editable = DockStripRules.editableApps(apps)
        guard editable.contains(where: { $0.normalizedKey == dragged }) else { return false }
        guard editable.count > 1 else {
            onReject()
            return false
        }
        editable.removeAll { $0.normalizedKey == dragged }
        apps = DockStripRules.apps(fromEditable: editable, preserving: apps)
        onRemove("从 Dock 栏移除一个 App")
        return true
    }
}

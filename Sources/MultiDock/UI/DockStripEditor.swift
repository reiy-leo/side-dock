import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 默认 Dock 的图标条编辑器（计划 §3.7 通用 Tab）。
///
/// 结构固定为：**[Finder] [启动台] [可编辑的 App…] [＋]**。
/// - Finder 是**幻影**：P0 已确认 `com.apple.dock` 里没有任何 Finder 表示，
///   所以它只是画出来给用户看的，不参与写入，也没有拖拽手柄。
/// - 启动台由 `DockStripRules` 保证永远在首位，拖不动、删不掉。
///
/// 编辑只改 `config.pinnedApps`；真正的写入/重启 Dock 由 `AppState` 决定
/// （受「编辑后立即应用」开关控制），这里通过 `onCommit` 上报一次改动。
struct DockStripEditor: View {

    @Binding var config: DockConfig
    /// 当前 Dock 域里存在、因而可安全写入的键。用于把"本机没有的键"对应的控件禁用掉。
    var availableKeys: Set<String>
    /// 读当前真实 Dock。由 `AppState` 提供 —— 编辑器不直接碰偏好域，
    /// 否则会绕过注入点（测试里就会读到真实系统）。
    var captureLive: () -> DockConfig?
    /// 一次编辑完成（排序落定 / 移除 / 添加）后回调，参数是给日志看的中文说明。
    var onCommit: (String) -> Void

    @State private var dragging: String?
    @State private var isFileTargeted = false

    private let iconSize: CGFloat = 44
    private let slotSize: CGFloat = 60

    private var editable: [DockTile] {
        var seen = Set<String>()
        return DockStripRules.editableApps(config.pinnedApps)
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
            HStack(spacing: 6) {
                finderSlot
                launchpadSlot
                ForEach(editable, id: \.normalizedKey) { tile in
                    editableSlot(tile)
                }
                appendSlot
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(height: slotSize + 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isFileTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: isFileTargeted ? 2 : 1)
        )
        // 从访达拖 .app 进来。只认文件 URL，所以不会和内部的排序拖拽打架。
        .dropDestination(for: URL.self) { urls, _ in
            addApps(at: urls)
        } isTargeted: { targeted in
            isFileTargeted = targeted
        }
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
            delegate: ReorderDropDelegate(
                target: tile,
                currentDragging: { dragging },
                apps: $config.pinnedApps,
                onFinish: { onCommit("调整 Dock 图标顺序") }
            )
        )
        .contextMenu {
            Button("从 Dock 移除") { remove(tile) }
        }
    }

    private var appendSlot: some View {
        Button {
            presentAppPicker()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: iconSize, height: iconSize)
                Text("添加")
                    .font(.caption2)
            }
            .frame(width: slotSize)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("从访达拖 .app 到图标条上，或点这里选择。")
        .onDrop(
            of: [.text],
            delegate: AppendDropDelegate(
                currentDragging: { dragging },
                apps: $config.pinnedApps,
                onFinish: { onCommit("把 App 移到 Dock 末尾") }
            )
        )
    }

    // MARK: - 底部控件

    private var controls: some View {
        HStack(spacing: 8) {
            Button("从当前 Dock 抓取") { capture() }
                .help("把此刻真实的 Dock 图标条读进编辑器，作为默认 Dock。")

            Spacer()

            removeZone

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var removeZone: some View {
        HStack(spacing: 4) {
            Image(systemName: "trash")
            Text("拖到这里移除")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color(nsColor: .separatorColor))
        )
        .onDrop(of: [.text], delegate: RemoveDropDelegate(
            currentDragging: { dragging },
            apps: $config.pinnedApps,
            onFinish: { onCommit("从 Dock 移除一个 App") }
        ))
    }

    private var hint: String {
        if !availableKeys.contains("tilesize") {
            return "本机 Dock 域里没有 tilesize，大小设置将不可用"
        }
        return "\(editable.count) 个图标"
    }

    // MARK: - 编辑动作

    private func commitApps(_ apps: [DockTile], note: String) {
        let normalized = DockStripRules.apps(fromEditable: apps, preserving: config.pinnedApps)
        guard normalized != config.pinnedApps else { return }
        config.pinnedApps = normalized
        onCommit(note)
    }

    private func remove(_ tile: DockTile) {
        var apps = editable
        apps.removeAll { $0.normalizedKey == tile.normalizedKey }
        commitApps(apps, note: "从 Dock 移除「\(tile.label)」")
    }

    private func append(_ tile: DockTile) {
        var apps = editable
        guard !apps.contains(where: { $0.normalizedKey == tile.normalizedKey }) else { return }
        apps.append(tile)
        commitApps(apps, note: "把「\(tile.label)」加入 Dock")
    }

    /// 从访达拖进来的 URL：只接受 `.app`。
    private func addApps(at urls: [URL]) -> Bool {
        var apps = editable
        var added = 0
        for url in urls {
            guard let tile = DockStripRules.tile(forAppAt: url.path) else { continue }
            guard !apps.contains(where: { $0.normalizedKey == tile.normalizedKey }) else { continue }
            apps.append(tile)
            added += 1
        }
        guard added > 0 else { return false }
        commitApps(apps, note: "拖入 \(added) 个 App 到 Dock")
        return true
    }

    private func presentAppPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "添加到 Dock"
        guard panel.runModal() == .OK else { return }
        _ = addApps(at: panel.urls)
    }

    /// 「从当前 Dock 抓取」：把真实域读回来覆盖编辑器内容（含外观）。
    private func capture() {
        guard let live = captureLive() else { return }
        config = live
        onCommit("从当前 Dock 抓取：\(live.pinnedApps.count) 个图标")
    }
}

// MARK: - 拖拽排序

/// 把被拖条目移动到目标位置。
///
/// 拖拽过程中**只改内存模型**（`config.pinnedApps`），真正的「写入 + 重启 Dock」
/// 由 `onFinish` 一次性触发 —— 否则拖过 10 个位置就会重启 10 次 Dock。
private struct ReorderDropDelegate: DropDelegate {
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
private struct AppendDropDelegate: DropDelegate {
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

/// 拖到垃圾桶 = 移除。
private struct RemoveDropDelegate: DropDelegate {
    let currentDragging: () -> String?
    @Binding var apps: [DockTile]
    let onFinish: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = currentDragging() else { return false }
        var editable = DockStripRules.editableApps(apps)
        editable.removeAll { $0.normalizedKey == dragged }
        apps = DockStripRules.apps(fromEditable: editable, preserving: apps)
        onFinish()
        return true
    }
}

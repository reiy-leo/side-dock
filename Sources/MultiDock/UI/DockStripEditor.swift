import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 默认 Dock 的图标条编辑器（计划 §3.7 通用 Tab）。
///
/// 结构固定为：**[Finder] [启动台] [可编辑的 App…] [＋]**，下方另有**其他项**一条
/// （`persistent-others`：文件夹 / 堆栈，计划 §3.2）。
/// - Finder 是**幻影**：P0 已确认 `com.apple.dock` 里没有任何 Finder 表示，
///   所以它只是画出来给用户看的，不参与写入，也没有拖拽手柄。
/// - 启动台由 `DockStripRules` 保证永远在首位，拖不动、删不掉。
///
/// 编辑只改内存里的 `config`；真正的写入/重启 Dock 由 `AppState` 决定
/// （受「编辑后立即应用」开关控制），这里通过 `onCommit` 上报一次改动。
///
/// ⚠️ **其他项只能「读进来 / 排序 / 移除」，不能新建**。`docs/spikes.md` 实验 8 实测：
/// 自己拼的 `directory-tile` 不会被 Dock 认领（Dock 不补 `GUID` / `book`），
/// 而字段不全的形状会让 Dock 直接 **SIGABRT**。所以拖文件夹进来时**把原因和替代做法**
/// 说清楚（在访达里自己拖到 Dock 上，App 会自动回存），不做静默失败、也不做假开关。
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
    /// 拖入被拒（文件夹 / 普通文件）时的说明。**不留静默失败** —— 早先版本拖文件夹进来
    /// 是"什么都没发生"，用户只会以为程序坏了。
    @State private var rejectionMessage: String?

    private let iconSize: CGFloat = 44
    private let slotSize: CGFloat = 60

    /// Dock 放在左右两侧时，编辑条也竖过来 —— 否则和实际 Dock 长得不一样，排序会看反。
    private var isVertical: Bool { config.appearance.orientation != "bottom" }

    private var editable: [DockTile] {
        var seen = Set<String>()
        return DockStripRules.editableApps(config.pinnedApps)
            .filter { seen.insert($0.normalizedKey).inserted }
    }

    /// 其他项是否可写：域里没有 `persistent-others` 就写不进去，控件直接禁用（不做假开关）。
    private var othersWritable: Bool { availableKeys.contains("persistent-others") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            strip
            othersStrip
            controls
        }
    }

    // MARK: - 图标条

    private var strip: some View {
        ScrollView(isVertical ? .vertical : .horizontal, showsIndicators: false) {
            Group {
                if isVertical {
                    VStack(spacing: 6) { slots }
                } else {
                    HStack(spacing: 6) { slots }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(
            width: isVertical ? slotSize + 24 : nil,
            height: isVertical ? nil : slotSize + 12
        )
        .frame(minHeight: isVertical ? 160 : nil, maxHeight: isVertical ? 260 : nil)
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
        // 文件夹 / 普通文件会被**明确拒绝并说明原因**（见 `DockStripRules.rejectionReason`），
        // 不留"拖了没反应"的静默失败。
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
        .modifier(SlotSizing(vertical: isVertical, size: slotSize))
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
        .modifier(SlotSizing(vertical: isVertical, size: slotSize))
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
        .modifier(SlotSizing(vertical: isVertical, size: slotSize))
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
            .modifier(SlotSizing(vertical: isVertical, size: slotSize))
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

    // MARK: - 其他项（persistent-others：文件夹 / 堆栈）

    /// 其他项一条。**只显示 / 排序 / 移除，不新建** —— 理由见类型文档与
    /// `DockStripRules.normalizedOthers`（实验 8：Dock 不认领自拼的目录条目，坏形状还会崩）。
    @ViewBuilder
    private var othersStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("其他项（文件夹 / 堆栈）")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !othersWritable {
                    Text("本机 Dock 域里没有 persistent-others，写不进去")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            ScrollView(isVertical ? .vertical : .horizontal, showsIndicators: false) {
                Group {
                    if isVertical {
                        VStack(spacing: 6) { otherSlots }
                    } else {
                        HStack(spacing: 6) { otherSlots }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(
                width: isVertical ? slotSize + 24 : nil,
                height: isVertical ? 120 : slotSize + 12
            )
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .opacity(othersWritable ? 1 : 0.5)
        }
    }

    @ViewBuilder
    private var otherSlots: some View {
        if config.otherItems.isEmpty {
            Text(othersWritable ? "真实 Dock 里还没有文件夹或堆栈" : "不可用")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(height: slotSize, alignment: .center)
                .padding(.horizontal, 6)
        } else {
            ForEach(config.otherItems, id: \.normalizedKey) { tile in
                otherSlot(tile)
            }
        }
    }

    private func otherSlot(_ tile: DockTile) -> some View {
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
        .modifier(SlotSizing(vertical: isVertical, size: slotSize))
        .opacity(dragging == tile.normalizedKey ? 0.4 : 1)
        .contentShape(Rectangle())
        .help(installed
              ? "\(tile.label)：真实 Dock 里的其他项，可以排序或移除（不能在这里新建同类的项）"
              : "\(tile.label)（磁盘上找不到这个文件夹）")
        .onDrag {
            dragging = tile.normalizedKey
            return NSItemProvider(object: tile.normalizedKey as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: OthersReorderDropDelegate(
                target: tile,
                currentDragging: { dragging },
                items: $config.otherItems,
                onFinish: { onCommit("调整 Dock 其他项顺序") }
            )
        )
        .contextMenu {
            Button("从 Dock 移除") { removeOther(tile) }
        }
    }

    // MARK: - 底部控件

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("从当前 Dock 抓取") { capture() }
                    .help("把此刻真实的 Dock（图标条 + 其他项 + 外观）读进编辑器。")

                Spacer()

                removeZone

                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 拖入被拒时说清原因与替代做法 —— 静默失败会让人以为程序坏了。
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
        // 图标条与其他项共用同一个垃圾桶：拖进来的键属于哪个数组就删哪个。
        .onDrop(of: [.text], delegate: RemoveDropDelegate(
            currentDragging: { dragging },
            apps: $config.pinnedApps,
            others: $config.otherItems,
            onFinish: { onCommit($0) }
        ))
    }

    private var hint: String {
        var parts = ["\(editable.count) 个图标"]
        if !config.otherItems.isEmpty { parts.append("\(config.otherItems.count) 个其他项") }
        if !availableKeys.contains("tilesize") {
            parts.append("本机 Dock 域里没有 tilesize，大小设置将不可用")
        }
        return parts.joined(separator: " · ")
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

    /// 从访达拖进来的 URL：只接受 `.app`；文件夹 / 普通文件**明确拒绝并说明原因**。
    ///
    /// 早先版本对拒绝是静默的（拖进去"什么都没发生"）。现在把原因摆在编辑条下方，
    /// 并给出**替代做法**：在访达里自己拖到 Dock 上，App 会自动把那条完整条目回存进配置。
    private func addDropped(_ urls: [URL]) -> Bool {
        var apps = editable
        var added = 0
        var rejection: DockItemRejection?
        for url in urls {
            if let reason = DockStripRules.rejectionReason(for: url.path) {
                rejection = rejection ?? reason
                continue
            }
            guard let tile = DockStripRules.tile(forAppAt: url.path) else {
                rejection = rejection ?? .notAnApp
                continue
            }
            guard !apps.contains(where: { $0.normalizedKey == tile.normalizedKey }) else { continue }
            apps.append(tile)
            added += 1
        }
        rejectionMessage = rejection?.message
        guard added > 0 else { return false }
        commitApps(apps, note: "拖入 \(added) 个 App 到 Dock")
        return true
    }

    /// 其他项：只排序 / 移除，**不新建**（`docs/spikes.md` 实验 8 的结论）。
    private func commitOthers(_ others: [DockTile], note: String) {
        let normalized = DockStripRules.normalizedOthers(others)
        guard normalized != config.otherItems else { return }
        config.otherItems = normalized
        onCommit(note)
    }

    private func removeOther(_ tile: DockTile) {
        var items = config.otherItems
        items.removeAll { $0.normalizedKey == tile.normalizedKey }
        commitOthers(items, note: "从 Dock 移除其他项「\(tile.label)」")
    }

    /// 选择器只让选 `.app`：文件夹 / 文件这条路是**故意关掉**的（见 `DockItemRejection`）。
    /// 与其让用户选完再报错，不如一开始就选不了。
    private func presentAppPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "添加到 Dock"
        guard panel.runModal() == .OK else { return }
        _ = addDropped(panel.urls)
    }

    /// 「从当前 Dock 抓取」：把真实域读回来覆盖编辑器内容（含**其他项**与外观）。
    private func capture() {
        guard let live = captureLive() else { return }
        config = live
        onCommit("从当前 Dock 抓取：\(live.pinnedApps.count) 个图标、\(live.otherItems.count) 个其他项")
    }
}

// MARK: - 格子尺寸

/// 横排时格子定宽、高度自适应；竖排时格子定高、宽度自适应（图标条整体才收得成一条）。
private struct SlotSizing: ViewModifier {
    let vertical: Bool
    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(width: size)
            .frame(height: vertical ? size : nil)
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

/// 拖到垃圾桶 = 移除。**图标条与其他项共用它**：被拖的键在哪个数组里就删哪个。
///
/// 两个数组的说明不同，所以 `onFinish` 带一个字符串参数，而不是让调用方猜。
private struct RemoveDropDelegate: DropDelegate {
    let currentDragging: () -> String?
    @Binding var apps: [DockTile]
    @Binding var others: [DockTile]
    let onFinish: (String) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = currentDragging() else { return false }

        var editable = DockStripRules.editableApps(apps)
        if editable.contains(where: { $0.normalizedKey == dragged }) {
            editable.removeAll { $0.normalizedKey == dragged }
            apps = DockStripRules.apps(fromEditable: editable, preserving: apps)
            onFinish("从 Dock 移除一个 App")
            return true
        }

        guard others.contains(where: { $0.normalizedKey == dragged }) else { return false }
        others.removeAll { $0.normalizedKey == dragged }
        onFinish("从 Dock 移除一个其他项")
        return true
    }
}

/// 其他项内部排序。
///
/// 与 `ReorderDropDelegate` 分开写：后者走的是 `DockStripRules.editableApps` 那一套
/// （必须保住启动台、收尾要 `apps(fromEditable:preserving:)`），而其他项没有固定项、
/// 也不该被 apps 的规则碰。硬合成一个 delegate 只会让两边的边界条件互相干扰。
private struct OthersReorderDropDelegate: DropDelegate {
    let target: DockTile
    let currentDragging: () -> String?
    @Binding var items: [DockTile]
    let onFinish: () -> Void

    func dropEntered(info: DropInfo) {
        guard
            let dragged = currentDragging(),
            dragged != target.normalizedKey,
            let from = items.firstIndex(where: { $0.normalizedKey == dragged }),
            let to = items.firstIndex(where: { $0.normalizedKey == target.normalizedKey }),
            from != to
        else { return }

        var reordered = items
        let item = reordered.remove(at: from)
        reordered.insert(item, at: to)
        items = reordered
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        onFinish()
        return true
    }
}

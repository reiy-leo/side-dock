import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 一根 Dock 栏的图标编辑器（2026-10-05 用户规格；2026-10-06 修订）。
/// **横向**一条（不管栏在屏幕上是横是竖，设置页里永远横排），
/// 默认露出 **8 个槽位**，超过走滚动；图标数 **0...15** —— 栏不固定任何 App
/// （不画访达 / 启动台幻影；启动台只是普通条目，可删可排），允许清空。
///
/// **预览只显示图标、不显示应用名**（2026-10-06 用户规格）：名字靠悬停 tooltip。
///
/// 编辑只改内存（`bar` 绑定）；落盘/应用由 `onCommit` 一次性交给 `AppState`。
/// ⚠️ 其他项（文件夹/堆栈）不能在这里新建（实验 8：自拼目录条目 Dock 不认领、坏形状崩 Dock）；
/// 迁移带进来的其他项不在本编辑器显示（原生 Dock 写入时随栏一并写回）。
///
/// **原生 Dock 已固定的 App 不进本栏**（2026-10-06 用户规格）：添加时拦下并给警告；
/// 判断走注入的 `isPinnedInNativeDock`（`AppState` 提供，冻结模式才有排除集）。
struct DockBarEditor: View {
    @Binding var bar: DockBar
    /// 一次编辑完成（排序落定 / 移除 / 添加）后回调，参数是给日志看的说明。
    var onCommit: (DockBar, String) -> Void
    /// 该条目是否已固定在原生 Dock 中（true = 不许加进来）。默认 false —— 未冻结/测试构造时无排除集。
    var isPinnedInNativeDock: (DockTile) -> Bool = { _ in false }

    @State private var dragging: String?
    @State private var hovered: String?
    @State private var isFileTargeted = false
    /// 图标正被拖到垃圾桶上方（驱动它的红色背景）。
    @State private var isRemoveTargeted = false
    /// 拖入被拒（文件夹 / 普通文件 / 超出上限）时的说明。**不留静默失败**。
    @State private var rejectionMessage: String?

    private let iconSize: CGFloat = 44
    private let slotSize: CGFloat = 60

    /// 默认露出 8 个槽位：固定编辑条宽度，内容多了走滚动。
    private var stripWidth: CGFloat { CGFloat(DockBar.visibleSlots) * slotSize + 24 }

    private var editable: [DockTile] {
        DockStripRules.barApps(bar.apps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 图标条 + 垃圾桶**同行**（2026-10-06 用户规格 ④：垃圾桶在预览右边）。
            HStack(alignment: .center, spacing: 10) {
                strip
                removeZone
                Spacer(minLength: 0)
            }
            // 下面的说明只在出错时出现（计数与「拖到这里移除」已按用户规格 ③⑤ 去掉）。
            if let rejectionMessage {
                rejectionRow(rejectionMessage)
            }
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
        ForEach(editable, id: \.normalizedKey) { tile in
            editableSlot(tile)
        }
        appendSlot
    }

    /// 图标槽：**只有图标、不显示名字**（2026-10-06 用户规格）；名字与安装状态看 tooltip。
    /// 悬停给一层极淡的圆角底（craft：可点/可拖的东西在指针下要有回应）。
    private func editableSlot(_ tile: DockTile) -> some View {
        let installed = DockStripRules.isInstalled(tile)
        let isHot = hovered == tile.normalizedKey || dragging == tile.normalizedKey
        return Image(nsImage: DockStripRules.icon(for: tile, size: iconSize))
            .resizable()
            .frame(width: iconSize, height: iconSize)
            .frame(width: slotSize, height: slotSize)
            .opacity(installed ? 1 : 0.35)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHot ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = tile.normalizedKey }
                else if hovered == tile.normalizedKey { hovered = nil }
            }
            .help(installed ? tile.label : L("\(tile.label)（磁盘上找不到这个 App）", "\(tile.label) (app not found on disk)"))
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
                    // 落下即清 `dragging`：它同时驱动悬停高亮，留着会让被拖的图标一直淡着色。
                    onFinish: {
                        dragging = nil
                        onCommit(bar, L("调整「\(bar.name)」的图标顺序", "Reordered icons in “\(bar.name)”"))
                    }
                )
            )
            .contextMenu {
                Button(L("从 Dock 栏移除", "Remove from Dock Bar")) { remove(tile) }
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
                Text(editable.count >= DockBar.maxApps ? L("已满", "Full") : L("添加", "Add"))
                    .font(.caption2)
            }
            .frame(width: slotSize, height: slotSize)
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovered == appendKey ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = appendKey }
            else if hovered == appendKey { hovered = nil }
        }
        .disabled(editable.count >= DockBar.maxApps)
        .help(editable.count >= DockBar.maxApps
              ? L("每根栏最多 \(DockBar.maxApps) 个图标", "Up to \(DockBar.maxApps) icons per bar")
              : L("从访达拖 .app 到图标条上，或点这里选择。", "Drag an .app from Finder onto the strip, or click to choose."))
        .onDrop(
            of: [.text],
            delegate: BarAppendDropDelegate(
                currentDragging: { dragging },
                apps: $bar.apps,
                onFinish: {
                    dragging = nil
                    onCommit(bar, L("把 App 移到「\(bar.name)」末尾", "Moved an app to the end of “\(bar.name)”"))
                }
            )
        )
    }

    /// 「添加」槽的悬停键（与图标的 `normalizedKey` 不会撞——那是路径）。
    private var appendKey: String { "+" }

    // MARK: - 拖入被拒的说明

    /// 拖入被拒时说清原因 —— 静默失败会让人以为程序坏了。
    private func rejectionRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L("知道了", "OK")) { rejectionMessage = nil }
                .font(.caption)
        }
    }

    /// 垃圾桶：**在图标条右边、正方形**（2026-10-06 用户规格 ④），
    /// 拖拽经过/悬停时**红色背景**（危险动作的标准配色，拖拽中才有颜色）。
    ///
    /// 尺寸跟图标槽一致（`slotSize`）——比图标高一点点，视觉上是个"目的地"而不是小图标。
    private var removeZone: some View {
        let isActive = isRemoveTargeted
        return Image(systemName: "trash")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(isActive ? Color.white : Color.secondary)
            .frame(width: slotSize, height: slotSize)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? Color.red : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1, dash: isActive ? [] : [4, 3])
                    )
                    .foregroundStyle(isActive ? Color.red : Color(nsColor: .separatorColor))
            )
            .contentShape(Rectangle())
            .help(L("拖动图标到这里移除", "Drag an icon here to remove it"))
            // 用带 `isTargeted` 的形态（而不是 DropDelegate）：红色背景要靠它驱动。
            .onDrop(of: [.text], isTargeted: $isRemoveTargeted) { _ in
                guard let dragged = dragging else { return false }
                var edited = DockStripRules.barApps(bar.apps)
                guard edited.contains(where: { $0.normalizedKey == dragged }) else { return false }
                edited.removeAll { $0.normalizedKey == dragged }
                bar.apps = DockStripRules.barApps(edited)
                onCommit(bar, L("从 Dock 栏移除一个 App", "Removed an app from the Dock bar"))
                return true
            }
    }

    // MARK: - 编辑动作

    private func commitApps(_ apps: [DockTile], note: String) {
        let normalized = DockStripRules.barApps(apps)
        guard normalized != bar.apps else { return }
        bar.apps = normalized
        onCommit(bar, note)
    }

    private func remove(_ tile: DockTile) {
        var apps = editable
        apps.removeAll { $0.normalizedKey == tile.normalizedKey }
        commitApps(apps, note: L("从「\(bar.name)」移除「\(tile.label)」", "Removed “\(tile.label)” from “\(bar.name)”"))
    }

    /// 从访达拖进来的 URL：只接受 `.app`；文件夹 / 普通文件 / 超出上限**明确拒绝并说明原因**。
    private func addDropped(_ urls: [URL]) -> Bool {
        var apps = editable
        var added = 0
        var rejection: String?
        for url in urls {
            if apps.count >= DockBar.maxApps {
                rejection = L("每根栏最多 \(DockBar.maxApps) 个图标，「\(url.deletingPathExtension().lastPathComponent)」没有加进来",
                              "Up to \(DockBar.maxApps) icons per bar — “\(url.deletingPathExtension().lastPathComponent)” was not added")
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
            // 原生 Dock 里已固定的 App：拦下 + 说清为什么（用户规格 2026-10-06）。
            // 检查放在去重之前 —— 重复项本来就静默跳过，但"原生也有"必须让用户看见。
            if isPinnedInNativeDock(tile) {
                let name = tile.label.isEmpty ? (tile.bundleIdentifier ?? L("这个 App", "this app")) : tile.label
                rejection = rejection ?? L("「\(name)」已固定在原生 Dock 中，不在这里重复显示 —— 先把它从原生 Dock 移除，再加进来。",
                                           "“\(name)” is already pinned in the native Dock and won't be duplicated here — remove it from the native Dock first.")
                continue
            }
            guard !apps.contains(where: { $0.normalizedKey == tile.normalizedKey }) else { continue }
            apps.append(tile)
            added += 1
        }
        rejectionMessage = rejection
        guard added > 0 else { return false }
        commitApps(apps, note: L("拖入 \(added) 个 App 到「\(bar.name)」", "Added \(added) app(s) to “\(bar.name)”"))
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
        panel.prompt = L("添加到 Dock 栏", "Add to Dock Bar")
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
        let editable = DockStripRules.barApps(apps)
        guard
            let from = editable.firstIndex(where: { $0.normalizedKey == dragged }),
            let to = editable.firstIndex(where: { $0.normalizedKey == target.normalizedKey }),
            from != to
        else { return }

        var reordered = editable
        let item = reordered.remove(at: from)
        reordered.insert(item, at: to)
        apps = DockStripRules.barApps(reordered)
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
        var editable = DockStripRules.barApps(apps)
        guard let from = editable.firstIndex(where: { $0.normalizedKey == dragged }),
              from != editable.count - 1 else { return }
        let item = editable.remove(at: from)
        editable.append(item)
        apps = DockStripRules.barApps(editable)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        onFinish()
        return true
    }
}

// 「拖到垃圾桶移除」改为 `removeZone` 里的闭包式 `onDrop(isTargeted:)`（2026-10-06）——
// 那个形态能看到"正在拖到它上方"，红色背景靠它驱动；DropDelegate 形态没有这个信号。

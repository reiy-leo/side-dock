import AppKit
import Observation
import SwiftUI

/// 次级 Dock 条的一个条目。窗口层只认它，不碰 `DockConfig`。
struct SecondaryDockItem: Identifiable {
    let id: String
    /// tooltip 文案。
    let label: String
    let icon: NSImage
    /// 点击时用 `NSWorkspace` 打开的路径；nil = 只展示、不可点。
    let launchPath: String?
    let isInstalled: Bool
    let isRunning: Bool
}

/// 一次内容更新需要的全部数据（调度器 → 窗口）。
struct SecondaryDockContentSnapshot {
    var items: [SecondaryDockItem]
    var iconSize: CGFloat
    /// 这份内容对应的 Dock 栏位置（2026-10-05：每栏可设位置）。
    /// 附着原生 Dock（与 Dock 方位同侧）走贴 Dock 几何；否则独立贴边。
    var position: DockBarPosition = .bottom
    /// 这份内容来自哪根栏（2026-10-06：右键菜单改位置要知道改谁）。
    /// 多行条（2026-10-23）里是**第一行**那根栏。
    var barID: UUID? = nil
    /// 多行条（2026-10-23 用户规格）：同一桌面同一条边上的栏，每根一行，最多 3 行，
    /// 按 `dockBars` 顺序。空 = 只有 `items` 这一行（旧调用点与测试的单行口径）。
    var rows: [SecondaryDockRow] = []
    /// 条显示的那一行（上次切到的行；不在了就是第一行）。
    var anchorBarID: UUID? = nil
    /// 悬停放大后的图标尺寸（跟随系统「放大」；nil = 系统没开放大，2026-10-23）。
    var magnifiedSize: CGFloat? = nil

    /// 这一份内容实际生效的放大尺寸。多行条也放大，但只放大光标所在的那一行（2026-10-23 用户规格）。
    var effectiveMagnifiedSize: CGFloat? { magnifiedSize }

    /// 单行口径的占位 ID（`rows` 为空、也没有 `barID` 时用）。
    static let placeholderRowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// 实际要画的行：`rows` 为空时把 `items` 当成唯一一行。
    var displayRows: [SecondaryDockRow] {
        guard rows.isEmpty else { return Array(rows.prefix(DockBar.maxRowsPerEdge)) }
        return [SecondaryDockRow(barID: barID ?? Self.placeholderRowID, name: "", items: items)]
    }

    /// 最长那一行的条目数（窗口长度按它定，滚动时窗口不忽宽忽窄）。
    var maxRowItemCount: Int {
        displayRows.map(\.items.count).max() ?? items.count
    }

    /// 钳制后的锚定行：`anchorBarID` 不在行里就回到第一行。
    var effectiveAnchorBarID: UUID? {
        let rows = displayRows
        if let anchorBarID, rows.contains(where: { $0.barID == anchorBarID }) { return anchorBarID }
        return rows.first?.barID
    }
}

/// 多行条里的一行 = 一根 Dock 栏的内容。
struct SecondaryDockRow: Identifiable {
    let barID: UUID
    var name: String
    var items: [SecondaryDockItem]
    var id: UUID { barID }
}

/// 多行条的当前行、切行与弹跳状态（窗口持有，视图读它）。
///
/// 2026-10-23 用户规格：去掉抽屉（展开多行）与拖拽 handle，条**只显示一行**，滚动切换；
/// 一次手势只翻一行，翻完有停顿（`SecondaryDockRowPager`）。
@MainActor
@Observable
final class SecondaryDockRowsModel {
    /// 正在显示的行。
    var currentRowID: UUID?
    /// 最近一次切行方向：+1 = 往屏幕内侧的下一行，-1 = 回上一行（决定切入动画从哪边来）。
    var lastStepDirection: Int = 1
    /// 显出态（悬停放大只在显出时生效：收起时条大半在原生 Dock 身后，放大会从 Dock 上方冒出来）。
    var isRevealed = false
    /// 点击启动后正在弹跳的图标（条目 ID → 当前朝屏幕内侧的位移）。
    var bounceOffsets: [String: CGFloat] = [:]
    /// 放大时条底板两端伸出的长度（图标超出条端就跟着变长，同原生 Dock）。
    private(set) var barOverflow: SecondaryDockBarOverflow = .zero
    /// 条本体沿条方向的长度（视图量出来写进来，算伸出量用）。
    @ObservationIgnored var barLength: CGFloat = 0
    /// 伸出量变了（窗口据此改底板的 frame）。
    @ObservationIgnored var onBarOverflowChange: (SecondaryDockBarOverflow) -> Void = { _ in }

    /// 某一行的图标范围（条坐标）。只认当前行（切行动画里淡出的旧行不算）。
    func reportIconExtents(rowID: UUID?, start: CGFloat, end: CGFloat) {
        if let rowID, let currentRowID, rowID != currentRowID { return }
        setBarOverflow(SecondaryDockMagnification.barOverflow(start: start, end: end, barLength: barLength))
    }

    func setBarOverflow(_ overflow: SecondaryDockBarOverflow) {
        guard overflow != barOverflow else { return }
        barOverflow = overflow
        onBarOverflowChange(overflow)
    }

    @ObservationIgnored var onUserScrolled: (UUID?) -> Void = { _ in }
    @ObservationIgnored var pager = SecondaryDockRowPager()
    @ObservationIgnored private var bouncingIDs: Set<String> = []
    /// App 是否已启动完成（弹跳的停止条件；测试可替换）。
    @ObservationIgnored var isLaunchFinished: @MainActor (String) -> Bool = { SecondaryDockRowsModel.appFinishedLaunching($0) }
    /// 弹跳节拍（测试可缩短）。
    @ObservationIgnored var bounceRise: Duration = .milliseconds(190)
    @ObservationIgnored var bounceFall: Duration = .milliseconds(230)

    /// 程序化定位到某行（切桌面 / 内容换了），不回报、不动画。
    func show(_ rowID: UUID?) {
        if currentRowID != rowID { currentRowID = rowID }
    }

    /// 按方向切一行（钳在首尾，不循环）。切成了就回报并返回 true。
    @discardableResult
    func step(_ direction: Int, rowIDs: [UUID]) -> Bool {
        guard direction != 0, rowIDs.count > 1 else { return false }
        let index = currentRowID.flatMap { rowIDs.firstIndex(of: $0) } ?? 0
        let target = index + (direction > 0 ? 1 : -1)
        guard rowIDs.indices.contains(target) else { return false }
        lastStepDirection = direction > 0 ? 1 : -1
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
            currentRowID = rowIDs[target]
        }
        onUserScrolled(rowIDs[target])
        return true
    }

    // MARK: 点击启动弹跳（2026-10-23 用户规格：和原生一样弹几下，不然以为点了没反应）

    /// 最多弹几下（App 迟迟没起来也会停）。
    static let maxBounces = 12
    /// 至少弹几下（App 起得再快也弹满，看得见）。
    static let minAppBounces = 2

    /// 开始弹跳：已在运行的 App（点了只是切过去）不弹；非 App（文件 / 文件夹）弹一下；
    /// App 弹到启动完成为止（至少 `minAppBounces` 下，最多 `maxBounces` 下）。
    func bounce(_ item: SecondaryDockItem, height: CGFloat) {
        guard !item.isRunning, let path = item.launchPath, !bouncingIDs.contains(item.id) else { return }
        bouncingIDs.insert(item.id)
        let isApp = path.hasSuffix(".app") || path.hasSuffix(".app/")
        let id = item.id
        Task { @MainActor [weak self] in
            for count in 1...Self.maxBounces {
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.19)) { self.bounceOffsets[id] = height }
                try? await Task.sleep(for: self.bounceRise)
                withAnimation(.easeIn(duration: 0.23)) { self.bounceOffsets[id] = 0 }
                try? await Task.sleep(for: self.bounceFall)
                if !isApp { break }
                if count >= Self.minAppBounces, self.isLaunchFinished(path) { break }
            }
            self?.bounceOffsets[id] = nil
            self?.bouncingIDs.remove(id)
        }
    }

    func isBouncing(_ id: String) -> Bool { bouncingIDs.contains(id) }

    static func appFinishedLaunching(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL == url && $0.isFinishedLaunching
        }
    }
}

/// 从一套 `DockConfig` 构建条目。**纯函数**（`runningBundleIDs` 由调用方注入），
/// 方便脱离 `NSWorkspace` 单测。
///
/// 2026-10-06 起（用户规格：栏不固定任何 App）：**不插 Finder 幻影、不补启动台**——
/// 栏里有什么就显示什么，顺序原样；空栏没有可显示条目。
/// 只取 `pinnedApps`——`otherItems`（文件夹/堆栈）的展开视图是另一套交互，v1 不做。
enum SecondaryDockContentBuilder {
    /// 没有可显示的条目时返回 nil（调用方应把条隐藏）。空判看 `pinnedApps` 本身。
    static func snapshot(
        from config: DockConfig,
        runningBundleIDs: Set<String>,
        iconSize: CGFloat
    ) -> SecondaryDockContentSnapshot? {
        let apps = DockStripRules.barApps(config.pinnedApps)
        guard !apps.isEmpty else { return nil }

        var items: [SecondaryDockItem] = []
        for tile in apps {
            items.append(SecondaryDockItem(
                id: tile.normalizedKey,
                label: tile.label.isEmpty ? (tile.bundleIdentifier ?? L("应用", "App")) : tile.label,
                icon: DockStripRules.icon(for: tile, size: iconSize),
                launchPath: DockStripRules.filePath(of: tile),
                isInstalled: DockStripRules.isInstalled(tile),
                isRunning: runningBundleIDs.contains(tile.bundleIdentifier ?? "")
            ))
        }
        return SecondaryDockContentSnapshot(items: items, iconSize: iconSize)
    }
}

/// 图标条本体。运行指示点占一个固定高度的槽位，避免它出现/消失时条目跳动。
///
/// **多行（2026-10-23 用户规格，同日改版）**：同一桌面同一条边的栏各算一行，但条**只显示一行**，
/// 滚动切换（一次手势一行，见 `SecondaryDockRowPager`）。有多行时条的末端（横条 = 右端，
/// 竖条 = 下端）有一列小圆点：几行几个点，当前行高亮——一眼看出这条边不止一根栏。
/// 去掉了抽屉（展开多行）与拖拽 handle。
struct SecondaryDockStripView: View {
    let rows: [SecondaryDockRow]
    let position: DockBarPosition
    let isVertical: Bool
    let iconSize: CGFloat
    /// 悬停放大尺寸（nil = 不放大）。
    var magnifiedSize: CGFloat? = nil
    var model: SecondaryDockRowsModel
    let onActivate: (SecondaryDockItem) -> Void
    let onHoverChange: (Bool) -> Void
    var onRowHover: (UUID) -> Void = { _ in }

    var body: some View {
        content
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                GeometryReader { proxy in
                    let length = isVertical ? proxy.size.height : proxy.size.width
                    Color.clear.onChange(of: length, initial: true) { _, value in model.barLength = value }
                }
            }
            .coordinateSpace(.named(Self.barSpace))
            // hover 区域随底板伸出（光标停在伸出去的那段上不算离开）。
            .contentShape(SecondaryDockOverflowShape(overflow: model.barOverflow, isVertical: isVertical))
            .onHover { inside in
                onHoverChange(inside)
                if inside, let id = currentRow?.barID { onRowHover(id) }
            }
            // 窗口朝屏幕内侧多出的透明空间（放大 / 弹跳的图标长进去），以及沿条方向两端给让位图标的余量；
            // 条本体只占其余部分（与 `SecondaryDockWindow.barRectInWindow` 一致）。
            .padding(innerEdge, headroom)
            .padding(isVertical ? .vertical : .horizontal, endRoom)
    }

    /// 条本体的坐标空间（图标范围按它量）。
    static let barSpace = "secondaryDockBar"

    private var endRoom: CGFloat {
        SecondaryDockMagnification.endRoom(
            iconSize: iconSize,
            magnifiedSize: magnifiedSize,
            pitch: SecondaryDockMagnification.slotLength(iconSize: iconSize, isVertical: isVertical)
                + SecondaryDockMagnification.slotSpacing
        )
    }

    private var headroom: CGFloat {
        SecondaryDockMagnification.headroom(iconSize: iconSize, magnifiedSize: magnifiedSize)
    }

    /// 屏幕内侧那条边（底部条 = 上；左侧条 = 右；右侧条 = 左）。
    private var innerEdge: Edge.Set {
        isVertical ? (position == .right ? .leading : .trailing) : .top
    }

    private var currentRow: SecondaryDockRow? {
        if let id = model.currentRowID, let row = rows.first(where: { $0.barID == id }) { return row }
        return rows.first
    }

    @ViewBuilder
    private var content: some View {
        if rows.count > 1 {
            if isVertical {
                VStack(spacing: 2) {
                    rowArea.frame(maxHeight: .infinity)
                    indicator
                }
            } else {
                HStack(spacing: 2) {
                    rowArea.frame(maxWidth: .infinity)
                    indicator
                }
            }
        } else {
            rowArea
        }
    }

    /// 当前行。切行时新行从「它所在的那一侧」滑入（往内侧的下一行从内侧来）并淡入，旧行淡出。
    private var rowArea: some View {
        ZStack {
            if let row = currentRow {
                rowView(row)
                    .id(row.barID)
                    .transition(rowTransition)
            }
        }
    }

    private var rowTransition: AnyTransition {
        let distance = (iconSize * 0.6).rounded()
        // 内侧方向的位移：底部条往上（-y），左侧条往右（+x），右侧条往左（-x）。
        let inward: CGSize = isVertical
            ? CGSize(width: position == .right ? -distance : distance, height: 0)
            : CGSize(width: 0, height: -distance)
        let sign: CGFloat = model.lastStepDirection > 0 ? 1 : -1
        let from = CGSize(width: inward.width * sign, height: inward.height * sign)
        let to = CGSize(width: -from.width, height: -from.height)
        return .asymmetric(
            insertion: .offset(from).combined(with: .opacity),
            removal: .offset(to).combined(with: .opacity)
        )
    }

    private func rowView(_ row: SecondaryDockRow) -> some View {
        let slots = SecondaryDockSlotsView(
            items: row.items,
            position: position,
            isVertical: isVertical,
            iconSize: iconSize,
            magnifiedSize: model.isRevealed ? magnifiedSize : nil,
            model: model,
            rowID: row.barID,
            onActivate: onActivate
        )
        return Group {
            if isVertical {
                slots
                    .frame(width: iconSize + 6)
                    .frame(maxHeight: .infinity)
            } else {
                slots
                    .frame(height: iconSize + 6)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 多行提示：几行几个点，当前行高亮。点的排列与行的空间顺序一致
    /// （横条：第一行在最下；左侧条：第一行在最左；右侧条：第一行在最右）。
    private var indicator: some View {
        let ids = rows.map(\.barID)
        let ordered = (isVertical ? position == .right : true) ? Array(ids.reversed()) : ids
        let current = currentRow?.barID
        let layout = isVertical
            ? AnyLayout(HStackLayout(spacing: 3))
            : AnyLayout(VStackLayout(spacing: 3))
        return layout {
            ForEach(ordered, id: \.self) { id in
                Circle()
                    .fill(Color.primary.opacity(id == current ? 0.8 : 0.25))
                    .frame(width: 5, height: 5)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .help(L("这条边有 \(rows.count) 行，滚动切换", "\(rows.count) rows on this edge — scroll to switch"))
    }
}

/// 一行里的图标槽位 + 悬停放大（2026-10-23）+ 点击启动弹跳。
///
/// 光标位置用 `onContinuousHover` 在这一排槽位自己的坐标里取（起点 = 第一个槽位），
/// 放大倍数与让位由 `SecondaryDockMagnification.effects` 算。放大不用 `scaleEffect`
/// （那是把已栅格化的小图拉大，会糊），而是直接把图片框放大、对齐到靠 Dock 的那一侧溢出。
struct SecondaryDockSlotsView: View {
    let items: [SecondaryDockItem]
    let position: DockBarPosition
    let isVertical: Bool
    let iconSize: CGFloat
    let magnifiedSize: CGFloat?
    var model: SecondaryDockRowsModel? = nil
    /// 这排图标属于哪一行（报图标范围用）。
    var rowID: UUID? = nil
    let onActivate: (SecondaryDockItem) -> Void

    @State private var cursor: CGFloat?

    private static let spacing: CGFloat = SecondaryDockMagnification.slotSpacing

    /// 槽位沿条方向的长度：横条 = 宽（minWidth iconSize + 4）；竖条 = 高（图标 + 2 + 圆点 4）。
    private var slotLength: CGFloat { SecondaryDockMagnification.slotLength(iconSize: iconSize, isVertical: isVertical) }

    /// 放大朝屏幕内侧长：对齐到靠 Dock / 屏幕边的那一侧。
    private var growAlignment: Alignment {
        isVertical ? (position == .right ? .trailing : .leading) : .bottom
    }

    var body: some View {
        let effects = SecondaryDockMagnification.effects(
            count: items.count,
            slotLength: slotLength,
            spacing: Self.spacing,
            iconSize: iconSize,
            magnifiedSize: magnifiedSize,
            cursor: magnifiedSize == nil ? nil : cursor
        )
        let layout = isVertical
            ? AnyLayout(VStackLayout(spacing: Self.spacing))
            : AnyLayout(HStackLayout(spacing: Self.spacing))
        layout {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let effect = index < effects.count ? effects[index] : (scale: 1, offset: 0)
                slot(item, scale: effect.scale)
                    .offset(x: isVertical ? 0 : effect.offset, y: isVertical ? effect.offset : 0)
                    .zIndex(Double(effect.scale))
            }
        }
        .background {
            if let model {
                let range = SecondaryDockMagnification.extents(
                    effects: effects, slotLength: slotLength, spacing: Self.spacing, iconSize: iconSize
                )
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(SecondaryDockStripView.barSpace))
                    let origin = isVertical ? frame.minY : frame.minX
                    let probe = SecondaryDockExtentProbe(start: origin + range.start, end: origin + range.end)
                    Color.clear.onChange(of: probe, initial: true) { _, value in
                        model.reportIconExtents(rowID: rowID, start: value.start, end: value.end)
                    }
                }
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard magnifiedSize != nil else {
                if cursor != nil { cursor = nil }
                return
            }
            switch phase {
            case .active(let point):
                let value = isVertical ? point.y : point.x
                if cursor == nil {
                    withAnimation(.easeOut(duration: 0.12)) { cursor = value }
                } else {
                    cursor = value
                }
            case .ended:
                withAnimation(.easeOut(duration: 0.15)) { cursor = nil }
            }
        }
    }

    /// 弹跳位移（朝屏幕内侧：底部条往上，左侧条往右，右侧条往左）。
    private func bounceOffset(_ item: SecondaryDockItem) -> CGSize {
        let amount = model?.bounceOffsets[item.id] ?? 0
        guard amount != 0 else { return .zero }
        if isVertical { return CGSize(width: position == .right ? -amount : amount, height: 0) }
        return CGSize(width: 0, height: -amount)
    }

    private func slot(_ item: SecondaryDockItem, scale: CGFloat) -> some View {
        let size = (iconSize * scale).rounded()
        return VStack(spacing: 2) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .offset(bounceOffset(item))
                .frame(width: iconSize, height: iconSize, alignment: growAlignment)
                .opacity(item.isInstalled ? 1 : 0.35)
            Circle()
                .fill(item.isRunning ? Color.primary.opacity(0.75) : Color.clear)
                .frame(width: 4, height: 4)
        }
        .frame(minWidth: iconSize + 4)
        .contentShape(Rectangle())
        .onTapGesture {
            model?.bounce(item, height: SecondaryDockMagnification.bounceHeight(iconSize: iconSize))
            onActivate(item)
        }
        .help(item.label)
    }
}

/// 图标范围在条坐标里的位置（`onChange` 要 Equatable）。
struct SecondaryDockExtentProbe: Equatable {
    var start: CGFloat
    var end: CGFloat
}

/// 条的 hover 形状：本体沿条方向两端各伸出 `overflow`。
struct SecondaryDockOverflowShape: Shape {
    var overflow: SecondaryDockBarOverflow
    var isVertical: Bool

    func path(in rect: CGRect) -> Path {
        if isVertical {
            return Path(CGRect(x: rect.minX, y: rect.minY - overflow.leading,
                               width: rect.width, height: rect.height + overflow.leading + overflow.trailing))
        }
        return Path(CGRect(x: rect.minX - overflow.leading, y: rect.minY,
                           width: rect.width + overflow.leading + overflow.trailing, height: rect.height))
    }
}

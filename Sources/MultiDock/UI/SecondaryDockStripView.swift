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
    /// hover 显出时展开几行（用户拖成的高度，按桌面各存各的）。收起恒为 1 行。
    var visibleRows: Int = 1
    /// 收起时显示的那一行（上次滚到的行；不在了就是第一行）。
    var anchorBarID: UUID? = nil
    /// 悬停放大后的图标尺寸（跟随系统「放大」；nil = 系统没开放大，2026-10-23）。
    var magnifiedSize: CGFloat? = nil

    /// 这一份内容实际生效的放大尺寸：v1 只有单行条放大（多行条的滚动视口会裁掉长出去的图标）。
    var effectiveMagnifiedSize: CGFloat? {
        displayRows.count <= 1 ? magnifiedSize : nil
    }

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

    /// 钳制后的展开行数：1...min(行数, 3)。
    var effectiveVisibleRows: Int {
        min(max(visibleRows, 1), max(displayRows.count, 1))
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

/// 拖拽 handle 的阶段（光标位置用屏幕坐标 `NSEvent.mouseLocation`——拖拽中窗口自己在变形，
/// 视图/窗口坐标系都靠不住）。
enum SecondaryDockResizePhase: Equatable {
    case began
    case changed(CGPoint)
    case ended
}

/// 多行条的滚动与 handle 状态（窗口持有，视图经 `@Bindable` 读写）。
///
/// 滚动位置的「用户滚动」回报有静默窗：窗口变形（显出/收起/拖高）时 ScrollView 会因为视口
/// 变化自己夹紧滚动位置，那不是用户滚的，不能写进「上次滚到的行」。
@MainActor
@Observable
final class SecondaryDockRowsModel {
    var scrolledRowID: UUID?
    var showsHandle = false
    var isResizing = false
    /// 显出态（悬停放大只在显出时生效：收起时条大半在原生 Dock 身后，放大会从 Dock 上方冒出来）。
    var isRevealed = false
    @ObservationIgnored var suppressScrollReportsUntil: Date = .distantPast
    @ObservationIgnored var onUserScrolled: (UUID?) -> Void = { _ in }

    /// 程序化滚到某行，并在 `quiet` 秒内不回报滚动变化。
    func scroll(to rowID: UUID?, quiet: TimeInterval = 0.4) {
        suppressScrollReportsUntil = Date().addingTimeInterval(quiet)
        if scrolledRowID != rowID { scrolledRowID = rowID }
    }

    func suppressReports(for quiet: TimeInterval = 0.4) {
        suppressScrollReportsUntil = max(suppressScrollReportsUntil, Date().addingTimeInterval(quiet))
    }

    func report(_ rowID: UUID?) {
        guard Date() >= suppressScrollReportsUntil else { return }
        onUserScrolled(rowID)
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

/// 图标条本体。**不做放大效果**（用户规格），图标定尺寸；
/// 运行指示点占一个固定高度的槽位，避免它出现/消失时条目跳动。
///
/// **多行（2026-10-23 用户规格）**：同一桌面同一条边的栏各占一行（竖条为一列），
/// 靠原生 Dock / 屏幕边的那一行是第一行（底部 = 最下面一行；左 = 最左一列；右 = 最右一列），
/// 往屏幕内侧依次是第 2、3 行。视口放不下全部行时可滚动（按行吸附），
/// 只接与行排列同向的滚动分量——横条只吃竖向滚动，横向留给系统切桌面手势。
/// 外沿（底部 = 上沿，左 = 右沿，右 = 左沿）有拖拽 handle，只在显出态出现。
struct SecondaryDockStripView: View {
    let rows: [SecondaryDockRow]
    let position: DockBarPosition
    let isVertical: Bool
    let iconSize: CGFloat
    /// 悬停放大尺寸（nil = 不放大）。
    var magnifiedSize: CGFloat? = nil
    @Bindable var model: SecondaryDockRowsModel
    let onActivate: (SecondaryDockItem) -> Void
    let onHoverChange: (Bool) -> Void
    var onRowHover: (UUID) -> Void = { _ in }
    var onResize: (SecondaryDockResizePhase) -> Void = { _ in }

    var body: some View {
        rowsContent
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: handleAlignment) {
                if model.showsHandle, rows.count > 1 {
                    handle
                }
            }
            .onHover(perform: onHoverChange)
            // 窗口朝屏幕内侧多出的透明空间（放大的图标长进去），以及沿条方向两端给让位图标的余量；
            // 条本体只占其余部分（与 `SecondaryDockWindow.barRectInWindow` 一致）。
            .padding(innerEdge, headroom)
            .padding(isVertical ? .vertical : .horizontal, endRoom)
    }

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

    /// 靠 Dock / 屏幕边的第一行要画在哪一端：横条在最下（倒序），右侧竖条在最右（倒序）。
    private var isReversed: Bool { isVertical ? position == .right : true }

    private var orderedRows: [SecondaryDockRow] { isReversed ? rows.reversed() : rows }

    /// 滚动位置的锚点 = 第一行所在的那一端（记住的「上次滚到的行」就是贴着这一端的行）。
    private var scrollAnchor: UnitPoint {
        isVertical ? (position == .right ? .trailing : .leading) : .bottom
    }

    private var handleAlignment: Alignment {
        isVertical ? (position == .right ? .leading : .trailing) : .top
    }

    @ViewBuilder
    private var rowsContent: some View {
        if rows.count <= 1 {
            rowView(rows.first)
        } else if isVertical {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(orderedRows) { row in scrollableRow(row) }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $model.scrolledRowID, anchor: scrollAnchor)
            .defaultScrollAnchor(scrollAnchor)
            .onChange(of: model.scrolledRowID) { _, newValue in model.report(newValue) }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(orderedRows) { row in scrollableRow(row) }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $model.scrolledRowID, anchor: scrollAnchor)
            .defaultScrollAnchor(scrollAnchor)
            .onChange(of: model.scrolledRowID) { _, newValue in model.report(newValue) }
        }
    }

    private func scrollableRow(_ row: SecondaryDockRow) -> some View {
        rowView(row)
            .id(row.barID)
            .onHover { inside in
                if inside { onRowHover(row.barID) }
            }
    }

    /// 一行（竖条为一列）。厚度固定 = 图标 + 指示点槽位，长度撑满、内容居中。
    @ViewBuilder
    private func rowView(_ row: SecondaryDockRow?) -> some View {
        let slots = SecondaryDockSlotsView(
            items: row?.items ?? [],
            position: position,
            isVertical: isVertical,
            iconSize: iconSize,
            magnifiedSize: rows.count <= 1 && model.isRevealed ? magnifiedSize : nil,
            onActivate: onActivate
        )
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

    /// 拖拽 handle：外沿居中的一根短胶囊，热区比胶囊大一圈。
    private var handle: some View {
        Capsule()
            .fill(Color.primary.opacity(0.35))
            .frame(width: isVertical ? 4 : 36, height: isVertical ? 36 : 4)
            .frame(width: isVertical ? 10 : 64, height: isVertical ? 64 : 10)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else if !model.isResizing {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in
                        if !model.isResizing {
                            model.isResizing = true
                            onResize(.began)
                        }
                        onResize(.changed(NSEvent.mouseLocation))
                    }
                    .onEnded { _ in
                        model.isResizing = false
                        onResize(.ended)
                        NSCursor.arrow.set()
                    }
            )
            .help(L("拖动调整行数（最多 3 行）", "Drag to change the number of rows (up to 3)"))
    }
}

/// 一行里的图标槽位 + 悬停放大（2026-10-23）。
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

    private func slot(_ item: SecondaryDockItem, scale: CGFloat) -> some View {
        let size = (iconSize * scale).rounded()
        return VStack(spacing: 2) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .frame(width: iconSize, height: iconSize, alignment: growAlignment)
                .opacity(item.isInstalled ? 1 : 0.35)
            Circle()
                .fill(item.isRunning ? Color.primary.opacity(0.75) : Color.clear)
                .frame(width: 4, height: 4)
        }
        .frame(minWidth: iconSize + 4)
        .contentShape(Rectangle())
        .onTapGesture { onActivate(item) }
        .help(item.label)
    }
}

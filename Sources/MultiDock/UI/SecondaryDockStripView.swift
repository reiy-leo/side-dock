import AppKit
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
    /// 固定几何模式的槽位数（nil = 按 `items.count` 撑开窗口）。
    ///
    /// 冻结模式下原生 Dock 全桌面一致，条也固定尺寸：槽位取所有桌面生效配置的最大值，
    /// 切桌面只换图标、窗口一毫米不挪（用户规格：sticky 在原生 Dock 的固定位置上）。
    var sizingSlots: Int?
}

/// 从一套 `DockConfig` 构建条目。**纯函数**（`runningBundleIDs` 由调用方注入），
/// 方便脱离 `NSWorkspace` 单测。
///
/// 规则沿用 `DockStripRules`：
/// - Finder 幻影置首（原生 Dock 里 Finder 永远存在，但它在偏好域里没有表示）；
/// - 启动台首位（`normalizedApps`）；
/// - 只取 `pinnedApps`——`otherItems`（文件夹/堆栈）的展开视图是另一套交互，v1 不做。
enum SecondaryDockContentBuilder {
    /// 没有可显示的条目时返回 nil（调用方应把条隐藏）。
    ///
    /// 空判口径与 `applyConfigForDesktop` 一致：看**原始** `pinnedApps` 是否为空 ——
    /// `normalizedApps` 会给空数组补一枚启动台，不能拿它当判据。
    static func snapshot(
        from config: DockConfig,
        runningBundleIDs: Set<String>,
        iconSize: CGFloat
    ) -> SecondaryDockContentSnapshot? {
        guard !config.pinnedApps.isEmpty else { return nil }
        let apps = DockStripRules.normalizedApps(config.pinnedApps)

        var items: [SecondaryDockItem] = [SecondaryDockItem(
            id: "finder",
            label: "访达",
            icon: DockStripRules.icon(forPath: DockStripRules.finderPath, size: iconSize),
            launchPath: DockStripRules.finderPath,
            isInstalled: true,
            isRunning: true
        )]
        for tile in apps {
            items.append(SecondaryDockItem(
                id: tile.normalizedKey,
                label: tile.label.isEmpty ? (tile.bundleIdentifier ?? "应用") : tile.label,
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
struct SecondaryDockStripView: View {
    let items: [SecondaryDockItem]
    let isVertical: Bool
    let iconSize: CGFloat
    let onActivate: (SecondaryDockItem) -> Void
    let onHoverChange: (Bool) -> Void

    var body: some View {
        Group {
            if isVertical {
                VStack(spacing: 2) { slots }
            } else {
                HStack(spacing: 2) { slots }
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover(perform: onHoverChange)
    }

    @ViewBuilder
    private var slots: some View {
        ForEach(items) { item in
            VStack(spacing: 2) {
                Image(nsImage: item.icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
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
}

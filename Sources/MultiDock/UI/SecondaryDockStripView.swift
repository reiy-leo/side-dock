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
    /// 这份内容对应的 Dock 栏位置（2026-10-05：每栏可设位置）。
    /// 附着原生 Dock（与 Dock 方位同侧）走贴 Dock 几何；否则独立贴边。
    var position: DockBarPosition = .bottom
    /// 这份内容来自哪根栏（2026-10-06：右键菜单改位置要知道改谁）。
    var barID: UUID? = nil
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

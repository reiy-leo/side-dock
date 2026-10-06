import AppKit

/// 桌面名称的展示窗口（2026-10-06 用户规格；同日第 2 版修订）。
///
/// **第 2 版（用户反馈）**：
/// - **磨砂玻璃面板**（原来是无底无框白字压壁纸）：`NSVisualEffectView`，材质与胶囊 HUD
///   同一套配方（`.popover` + `.behindWindow` + 1 px 内描边 + `state = .active`），
///   文字因此改用 `labelColor` 跟随面板材质（不再需要投影）。
/// - **字重 800**（`.heavy`，用户指定）。
/// - **宽度按内容量**：不再依赖 `NSTextField.intrinsicContentSize`，改用
///   `NSString.size(withAttributes:)` + 几 pt 余量（`widthSlack`）——真机反馈过
///   "文字框与量宽完全相等时，末端字被光栅化取整挤出、变成省略号"。
///
/// 位置三档不变（顶部/中部/底部，`desktopNamePlacement`）；窗口层配方与胶囊逐条相同
/// （跨空间、不抢焦点、不挡点击、statusBar 层）。
@MainActor
final class DesktopNameOverlayWindow: ToastPresenting {

    // MARK: - 尺寸常量（单测与快照都引用它们，别内联数字）

    /// 主字号。固定值：名字最长 10 个字素簇。
    static let fontSize: CGFloat = 64
    /// 字重 800 = `.heavy`（2026-10-06 用户规格）。
    static let fontWeight: NSFont.Weight = .heavy
    /// 面板左右内边距。
    static let horizontalPadding: CGFloat = 36
    /// 面板上下内边距。
    static let verticalPadding: CGFloat = 20
    /// 面板圆角。
    static let cornerRadius: CGFloat = 22
    /// 单字名字不要缩成一颗圆。
    static let minPanelWidth: CGFloat = 180
    /// 量宽余量（pt）。**实测必需**：`NSTextField` 的 cell 每侧有约 2 pt 内边距，且 CJK
    /// 字形的实际推进宽比 `NSString.size` 有取整损耗 —— 64 pt 下量宽 604 pt 的十个字，
    /// label 宽 608 仍被截成省略号、612 起完整显示（探针脚本实测）→ 留 12 稳妥。
    static let widthSlack: CGFloat = 12

    /// 顶部档位距可见区顶边的距离（沿用旧版 toast 的实测值，`visibleFrame` 天然避开菜单栏）。
    private static let topInset: CGFloat = 80
    /// 底部档位距可见区底边的距离：避开次级条半露的薄边与原生 Dock 边缘。
    private static let bottomInset: CGFloat = 64

    private let window: ToastWindow
    private let panel: NSVisualEffectView
    private let edge: GlassEdgeView
    private let label: NSTextField
    private let placementProvider: () -> DesktopNamePlacement

    /// UI 快照测试用（验的是真窗口，与 `SecondaryDockWindowFactory` 同一口径）。
    var snapshotWindow: NSWindow { window }

    /// 位置实时读取：切到哪个档位，下一次展示就按哪个档位摆（不必重建窗口）。
    init(placementProvider: @escaping () -> DesktopNamePlacement = { .top }) {
        self.placementProvider = placementProvider
        window = ToastWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        // 面板是磨砂玻璃，交给系统画窗口投影（边缘靠 1 px 内描边 + 投影共同撑出层次）。
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.isMovable = false
        // 关掉出场/退场动画：提示只活 1 秒，淡入淡出会吃掉可感知的停留时间（与胶囊窗口同理）。
        window.animationBehavior = .none

        panel = NSVisualEffectView()
        panel.material = .popover
        panel.blendingMode = .behindWindow
        panel.state = .active
        // 遮罩按当前尺寸现画（不做拉伸），尺寸在 show() 里随内容更新。
        panel.maskImage = Self.panelMask(size: NSSize(width: Self.minPanelWidth, height: 120))

        edge = GlassEdgeView(cornerRadius: Self.cornerRadius)
        edge.autoresizingMask = [.width, .height]
        panel.addSubview(edge)

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: Self.fontSize, weight: Self.fontWeight)
        // 文字在磨砂面板上走 labelColor：亮色深字、深色浅字，随材质自适应。
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isSelectable = false
        panel.addSubview(label)

        window.contentView = panel
    }

    func show(text: String, displayUUID: String?) {
        guard let screen = ScreenMatching.resolve(displayUUID) else { return }
        let layout = Self.panelLayout(
            text: text,
            available: screen.visibleFrame,
            placement: placementProvider()
        )
        label.stringValue = text
        panel.frame = NSRect(origin: .zero, size: layout.panelSize)
        panel.maskImage = Self.panelMask(size: layout.panelSize)
        label.frame = layout.labelFrame
        edge.frame = panel.bounds
        window.setFrame(
            NSRect(origin: layout.origin, size: layout.panelSize),
            display: true
        )
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    // MARK: - 布局（纯函数，单测直接打这里，不碰 NSScreen）

    /// 按内容量宽 + 算窗口位置。**宽度不截字**：10 个字素簇在 64 pt 下约 604 pt，
    /// 任何屏幕都放得下；只有理论上超宽（手改配置塞超长名）才启用截断兜底。
    static func panelLayout(
        text: String,
        available: NSRect,
        placement: DesktopNamePlacement
    ) -> DesktopNamePanelLayout {
        let font = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let maxTextWidth = max(minPanelWidth, available.width - 32)
        let textWidth = min(ceil(measured.width) + widthSlack, maxTextWidth)
        let textHeight = ceil(measured.height)
        let panelSize = NSSize(
            width: max(minPanelWidth, textWidth + horizontalPadding * 2),
            height: textHeight + verticalPadding * 2
        )
        let labelFrame = NSRect(
            x: (panelSize.width - textWidth) / 2,
            y: (panelSize.height - textHeight) / 2,
            width: textWidth,
            height: textHeight
        )
        return DesktopNamePanelLayout(
            panelSize: panelSize,
            labelFrame: labelFrame,
            origin: frameOrigin(for: placement, visibleFrame: available, size: panelSize)
        )
    }

    /// 纯几何：按档位算窗口原点（AppKit 坐标原点在左下）。
    static func frameOrigin(
        for placement: DesktopNamePlacement,
        visibleFrame: NSRect,
        size: NSSize
    ) -> NSPoint {
        let x = visibleFrame.midX - size.width / 2
        let y: CGFloat
        switch placement {
        case .top:
            y = visibleFrame.maxY - topInset - size.height
        case .middle:
            y = visibleFrame.midY - size.height / 2
        case .bottom:
            y = visibleFrame.minY + bottomInset
        }
        return NSPoint(x: x, y: y)
    }

    /// 圆角遮罩：按尺寸现画一张 1:1 的 alpha 图（`NSVisualEffectView` 没有 cornerRadius）。
    private static func panelMask(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            ).fill()
            return true
        }
    }
}

/// 一次名称面板布局的完整结果（纯值）。
struct DesktopNamePanelLayout: Equatable {
    var panelSize: NSSize
    var labelFrame: NSRect
    var origin: NSPoint
}

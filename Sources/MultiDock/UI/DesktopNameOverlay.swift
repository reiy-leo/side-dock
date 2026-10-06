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
///
/// **第 3 版（2026-10-06 用户规格「默认、流动霓虹、赛博紫韵」）**：
/// 新增 `desktopNameEffect` 三档**背景**效果（同日用户澄清：效果修饰的是展示背景，
/// **不是字体**）—— 默认档仍是磨砂面板 + `labelColor` 大字；两个霓虹档把
/// **面板背景**交给 `DesktopNameEffectCanvas` 自绘（暗底 + 流动光带 + 霓虹描边），
/// **文字始终是同一个 label**，只是效果档把字色切成白色（暗底上保证可读）。
/// 动画只在展示的那 1 秒里跑（`show()` 启动、`hide()` 停止）。效果是**实时读取**的
/// （同位置的 provider 模式），改设置下一次展示就生效，不必重建窗口。
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
    /// 霓虹档的**背景**画布（默认档隐藏；位于 label 之下，文字不受它影响）。
    private let canvas: DesktopNameEffectCanvas
    private let placementProvider: () -> DesktopNamePlacement
    private let styleProvider: () -> DesktopNameEffect

    /// 最近一次展示用的效果（单测断言「效果从 provider 流到了窗口」用）。
    private(set) var activeEffect: DesktopNameEffect = .standard
    /// 单测读视图状态用：文字恒可见（效果只换背景，不碰字体），画布仅效果档可见。
    var labelIsVisibleForTesting: Bool { !label.isHidden }
    var labelColorForTesting: NSColor { label.textColor ?? .clear }
    var canvasIsVisibleForTesting: Bool { !canvas.isHidden }
    /// 画布是否正在播动画（展示期间应为 true，收起后 false）。
    var canvasIsAnimatingForTesting: Bool { canvas.isAnimating }

    /// UI 快照测试用（验的是真窗口，与 `SecondaryDockWindowFactory` 同一口径）。
    var snapshotWindow: NSWindow { window }
    /// UI 快照测试用：固定相位抓「确定的一帧」（动画在跑时相位每帧都不同，快照会不确定）。
    var snapshotCanvas: DesktopNameEffectCanvas { canvas }

    /// 位置/效果都**实时读取**：切到哪个档位，下一次展示就按哪个档位摆（不必重建窗口）。
    init(
        placementProvider: @escaping () -> DesktopNamePlacement = { .top },
        styleProvider: @escaping () -> DesktopNameEffect = { .standard }
    ) {
        self.placementProvider = placementProvider
        self.styleProvider = styleProvider
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

        // 画布是**背景层**：插在 label 之下（效果修饰背景，文字永远在最上层）。
        canvas = DesktopNameEffectCanvas(frame: .zero)
        canvas.autoresizingMask = [.width, .height]
        canvas.isHidden = true
        panel.addSubview(canvas, positioned: .below, relativeTo: label)

        window.contentView = panel
    }

    func show(text: String, displayUUID: String?) {
        guard let screen = ScreenMatching.resolve(displayUUID) else { return }
        let presentation = Self.presentation(
            text: text,
            available: screen.visibleFrame,
            placement: placementProvider(),
            effect: styleProvider()
        )
        apply(presentation)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
        // 收起即停：动画只在展示的那 1 秒里跑，隐藏后不烧 CPU。
        canvas.stopAnimating()
    }

    // MARK: - 展示模型（纯函数 + 应用，单测不弹窗也能验接线）

    /// 一次展示的完整描述（文本 + 效果 + 几何）。纯值，好断言。
    static func presentation(
        text: String,
        available: NSRect,
        placement: DesktopNamePlacement,
        effect: DesktopNameEffect
    ) -> DesktopNamePresentation {
        DesktopNamePresentation(
            text: text,
            effect: effect,
            layout: panelLayout(text: text, available: available, placement: placement)
        )
    }

    /// 把一次展示应用到窗口与子视图上（**不 order front** —— 单测调它验接线，不会弹窗）。
    ///
    /// 文字**永远**交给同一个 label（效果只换背景，不碰字体——2026-10-06 用户澄清）。
    /// 效果档：画布显示、字色切纯白（压在暗底上，与壁纸无关地可读）；
    /// 默认档：画布隐藏、字色回 `labelColor`（跟随磨砂材质与亮/暗外观）。
    func apply(_ presentation: DesktopNamePresentation) {
        activeEffect = presentation.effect
        let isEffect = presentation.effect.spec != nil

        label.stringValue = presentation.text
        label.textColor = isEffect ? .white : .labelColor
        canvas.isHidden = !isEffect

        panel.frame = NSRect(origin: .zero, size: presentation.layout.panelSize)
        panel.maskImage = Self.panelMask(size: presentation.layout.panelSize)
        label.frame = presentation.layout.labelFrame
        // 画布先立好尺寸与圆角，再喂效果（尺寸/效果变化都会按当前 bounds 重绘）。
        canvas.frame = panel.bounds
        canvas.cornerRadius = Self.cornerRadius
        canvas.effect = presentation.effect
        edge.frame = panel.bounds

        window.setFrame(
            NSRect(origin: presentation.layout.origin, size: presentation.layout.panelSize),
            display: true
        )

        if isEffect {
            canvas.resetPhase()
            canvas.startAnimating()
        } else {
            canvas.stopAnimating()
        }
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

/// 一次名称展示的完整描述（文本 + 效果 + 布局）。`presentation(...)` 产出、`apply(_:)` 消费。
struct DesktopNamePresentation: Equatable {
    var text: String
    var effect: DesktopNameEffect
    var layout: DesktopNamePanelLayout
}

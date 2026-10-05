import AppKit

/// 桌面名称的「iPhone 锁屏式」展示窗口（2026-10-06 用户规格，`docs/PLAN.md` §3.10）。
///
/// 与胶囊 HUD（`HudToastWindow`，系统级告知用）分工：桌面名走这里——
/// **无底、无描边**，一行大号极细白字直接压在壁纸上，带柔和投影，观感对标 iPhone 锁屏时钟。
/// 窗口层配方与胶囊窗口逐条相同（跨空间、不抢焦点、不挡点击、statusBar 层），
/// 每一条都是踩过坑的，见 `HudToastWindow` 文件头的清单。
@MainActor
final class DesktopNameOverlayWindow: ToastPresenting {

    /// 锁屏体感的主字号。固定值：名字最长 10 个字素簇，常见显示器宽度都放得下（超出截尾）。
    private static let fontSize: CGFloat = 64
    /// 文本四周留白，给图层投影留渲染空间（窗口透明，投影画在窗口内）。
    private static let shadowPad: CGFloat = 28
    /// 顶部档位距可见区顶边的距离（沿用旧版 toast 的实测值，`visibleFrame` 天然避开菜单栏）。
    private static let topInset: CGFloat = 80
    /// 底部档位距可见区底边的距离：避开次级条半露的薄边与原生 Dock 边缘。
    private static let bottomInset: CGFloat = 64

    private let window: ToastWindow
    private let container: NSView
    private let label: NSTextField
    private let placementProvider: () -> DesktopNamePlacement

    /// 位置实时读取：切到哪个档位，下一次切换就按哪个档位摆（不必重建窗口）。
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
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.isMovable = false
        // 关掉出场/退场动画：提示只活 1 秒，淡入淡出会吃掉可感知的停留时间（与胶囊窗口同理）。
        window.animationBehavior = .none

        container = NSView(frame: .zero)

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: Self.fontSize, weight: .thin)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isSelectable = false
        // 锁屏观感的关键：细白字压在任意壁纸上都要立得住。图层投影从文字位图的 alpha
        // 生成，随字形走，比 NSShadow（画进 cell，方向语义反直觉）更稳。
        label.wantsLayer = true
        label.layer?.shadowColor = NSColor.black.cgColor
        label.layer?.shadowOpacity = 0.55
        label.layer?.shadowRadius = 12
        label.layer?.shadowOffset = NSSize(width: 0, height: -4)

        container.addSubview(label)
        window.contentView = container
    }

    func show(text: String, displayUUID: String?) {
        guard let screen = ScreenMatching.resolve(displayUUID) else { return }
        label.stringValue = text

        let available = screen.visibleFrame
        let maxTextWidth = available.width - 80
        let textSize = label.intrinsicContentSize
        let textWidth = min(ceil(textSize.width), maxTextWidth)
        let textHeight = ceil(textSize.height)
        let width = textWidth + Self.shadowPad * 2
        let height = textHeight + Self.shadowPad * 2

        let origin = Self.frameOrigin(
            for: placementProvider(),
            visibleFrame: available,
            size: NSSize(width: width, height: height)
        )
        container.frame = NSRect(x: 0, y: 0, width: width, height: height)
        label.frame = NSRect(
            x: Self.shadowPad,
            y: Self.shadowPad,
            width: textWidth,
            height: textHeight
        )
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    /// 纯几何：按档位算窗口原点（AppKit 坐标原点在左下）。单测直接打这里，不碰真窗口。
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
}

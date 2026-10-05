import AppKit
import CoreGraphics

/// 胶囊 HUD 提示窗口（`docs/PLAN.md` §3.10）。
///
/// **2026-10-06 起职责收缩**：桌面名称改走 `DesktopNameOverlayWindow`（iPhone 锁屏式大字），
/// 本窗口只服务**系统级告知**（自愈还原「已自动还原上次未还原的 Dock」、「Dock 已恢复」）——
/// 这类消息必须压在任何壁纸上都可读，胶囊底 + HUD 材质正合适。
///
/// **下面每一条属性错了都会出问题**，不是可选的润色：
/// - `collectionBehavior` 少了 `.canJoinAllSpaces` → 窗口只在自己所在的空间显示，切过去反而看不见，功能等于失效
/// - `canBecomeKey` / `canBecomeMain` = false → 否则用户切过去正要打字，字会打进 toast
/// - `ignoresMouseEvents` = true → 绝不挡住点击
/// - `level = .statusBar`（25）→ 高于 Dock 的窗口层（20）与普通 App 窗口
/// - 用 `orderFrontRegardless()` 而不是 `makeKeyAndOrderFront` → 后者会抢焦点
///
/// 不需要任何系统权限：这就是本 App 自己的一个窗口。
@MainActor
final class HudToastWindow: ToastPresenting {

    private let window: ToastWindow
    private let label: NSTextField
    private let container: NSVisualEffectView
    private let edge: ToastEdgeView

    /// 距显示器**可见区**顶部的距离。用 `visibleFrame` 而非 `frame`，天然避开菜单栏。
    private static let topInset: CGFloat = 80
    private static let horizontalPadding: CGFloat = 14
    /// 定高：名字长短只影响宽度，胶囊的高度必须恒定，否则每次切桌面都能看到一次跳动。
    private static let pillHeight: CGFloat = 32
    private static let cornerRadius: CGFloat = 16
    /// 单字名字不要长成一颗圆：短到某个下限就保持"胶囊"的比例。
    private static let minPillWidth: CGFloat = 76

    init() {
        window = ToastWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.isMovable = false
        // 关掉出场/退场动画：提示只活 1 秒，淡入淡出会吃掉可感知的停留时间，也让计时核对变糊。
        window.animationBehavior = .none

        // 系统 HUD 材质：`.popover` 会跟随亮/深色外观，`blendingMode = .behindWindow` 让它
        // 模糊身后**真实的内容**——这正是它能压在任意壁纸和别人家全屏 App 上的原因。
        // 早先版本用固定黑底 0.78 逃避这个问题，代价是亮色下糊成一坨、深色下又比背景更闷。
        container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        // NSVisualEffectView 没有 cornerRadius（那是 UIKit 的），圆角只能靠 maskImage 裁。
        // 遮罩按当前尺寸现画，不做拉伸——拉伸会把两端的小圆角扯成椭圆。
        container.maskImage = Self.pillMask(width: Self.minPillWidth)

        edge = ToastEdgeView(cornerRadius: Self.cornerRadius)
        edge.autoresizingMask = [.width, .height]
        container.addSubview(edge)

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isSelectable = false
        container.addSubview(label)

        window.contentView = container
    }

    func show(text: String, displayUUID: String?) {
        guard let screen = ScreenMatching.resolve(displayUUID) else { return }
        label.stringValue = text

        let available = screen.visibleFrame
        let textSize = label.intrinsicContentSize
        let textWidth = ceil(textSize.width)
        let textHeight = ceil(textSize.height)
        let maxWidth = available.width - 80
        let width = min(
            max(textWidth + Self.horizontalPadding * 2, Self.minPillWidth),
            maxWidth
        )
        let height = Self.pillHeight

        // 水平居中；顶边距可见区顶部 topInset（AppKit 坐标原点在左下角，所以 y 要减）。
        let origin = NSPoint(
            x: available.midX - width / 2,
            y: available.maxY - Self.topInset - height
        )
        container.frame = NSRect(x: 0, y: 0, width: width, height: height)
        container.maskImage = Self.pillMask(width: width)
        label.frame = NSRect(
            x: (width - textWidth) / 2,
            y: (height - textHeight) / 2,
            width: textWidth,
            height: textHeight
        )
        edge.frame = container.bounds
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    /// 胶囊遮罩：按宽度现画一张 1:1 的 alpha 图（高度固定）。
    private static func pillMask(width: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: width, height: pillHeight), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            ).fill()
            return true
        }
    }

    /// 由 `displayUUID` 找到对应的 `NSScreen`；找不到就回落主屏。
    ///
    /// SkyLight 的 `Display Identifier` 与 `CGDisplayCreateUUIDFromDisplayID` 实测逐字符相同
    /// （见 `AGENTS.md` §4），所以这条映射是可靠的。
    private static func screen(for displayUUID: String?) -> NSScreen? {
        ScreenMatching.resolve(displayUUID)
    }
}

/// `displayUUID` → `NSScreen` 的共享映射（胶囊 HUD 与锁屏式名称窗口都要按目标显示器落位）。
///
/// SkyLight 的 `Display Identifier` 与 `CGDisplayCreateUUIDFromDisplayID` 实测逐字符相同
/// （见 `AGENTS.md` §4），所以这条映射是可靠的。
@MainActor
enum ScreenMatching {
    static func resolve(_ displayUUID: String?) -> NSScreen? {
        let screens = NSScreen.screens
        guard let first = screens.first else { return nil }
        let fallback = NSScreen.main ?? first
        guard let displayUUID else { return fallback }

        for screen in screens {
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value ?? 0
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { continue }
            if (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(displayUUID) == .orderedSame {
                return screen
            }
        }
        return fallback
    }
}

/// 胶囊的 1 px 内描边。
///
/// 亮色下 `.popover` 材质接近纯白，压在浅色壁纸上会和背景糊在一起；这条边是唯一把它撑出来的
/// 东西。深色下反过来需要一条更淡的高光边。两种外观分别给值，见 `edgeColor`。
@MainActor
private final class ToastEdgeView: NSView {
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    /// 动态色：在 `draw(_:)` 里解析时，`NSAppearance.current` 就是本视图的 `effectiveAppearance`，
    /// 所以换外观之后不需要手动重算颜色，只需要重绘。
    private static let edgeColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.12)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        path.lineWidth = 1
        Self.edgeColor.setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 显式禁掉「能成为 key / main」——无边框窗口默认就不行，写出来是为了让人一眼看到这条硬约束。
/// 胶囊 HUD 与锁屏式名称窗口（`DesktopNameOverlayWindow`）共用这一个子类。
final class ToastWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

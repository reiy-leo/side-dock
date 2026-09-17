import AppKit
import CoreGraphics

/// 切换桌面时的中上部提示窗口（`docs/PLAN.md` §3.10）。
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
final class DesktopNameToastWindow: ToastPresenting {

    private let window: ToastWindow
    private let label: NSTextField
    private let container: NSView

    /// 距显示器**可见区**顶部的距离。用 `visibleFrame` 而非 `frame`，天然避开菜单栏。
    private static let topInset: CGFloat = 80
    private static let horizontalPadding: CGFloat = 20
    private static let verticalPadding: CGFloat = 10
    private static let cornerRadius: CGFloat = 12

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

        // 深色胶囊 + 白字。不用 vibrancy：这玩意儿要浮在任意背景（含别人的全屏 App）之上，
        // 固定的深色底比跟随外观更可控。
        container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.masksToBounds = true

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        container.addSubview(label)
        window.contentView = container
    }

    func show(text: String, displayUUID: String?) {
        guard let screen = Self.screen(for: displayUUID) else { return }
        label.stringValue = text

        let available = screen.visibleFrame
        let textSize = label.intrinsicContentSize
        let maxWidth = available.width - 80
        let size = NSSize(
            width: min(textSize.width + Self.horizontalPadding * 2, maxWidth),
            height: textSize.height + Self.verticalPadding * 2
        )

        // 水平居中；顶边距可见区顶部 topInset（AppKit 坐标原点在左下角，所以 y 要减）。
        let origin = NSPoint(
            x: available.midX - size.width / 2,
            y: available.maxY - Self.topInset - size.height
        )
        container.frame = NSRect(origin: .zero, size: size)
        label.frame = container.bounds
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    /// 由 `displayUUID` 找到对应的 `NSScreen`；找不到就回落主屏。
    ///
    /// SkyLight 的 `Display Identifier` 与 `CGDisplayCreateUUIDFromDisplayID` 实测逐字符相同
    /// （见 `AGENTS.md` §4），所以这条映射是可靠的。
    private static func screen(for displayUUID: String?) -> NSScreen? {
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

/// 显式禁掉「能成为 key / main」——无边框窗口默认就不行，写出来是为了让人一眼看到这条硬约束。
private final class ToastWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

import AppKit
import SwiftUI

/// 次级 Dock 条的呈现协议。调度逻辑（`SecondaryDockController`）只认它，
/// 测试里用假实现替换 —— 与 `ToastPresenting` 同一拆分。
@MainActor
protocol SecondaryDockPresenting: AnyObject {
    func updateContent(_ content: SecondaryDockContentSnapshot, isVertical: Bool)
    func setFrame(_ frame: NSRect, animated: Bool)
    func orderFront()
    func orderOut()
    /// 把窗口拉回当前活动空间（`.moveToActiveSpace` 折中方案的配套，实验 24 / AGENTS.md §6.1 #4）。
    /// 真实窗口 = 「临时跨空间可见 → orderFront → 设回单空间」+ 淡入；替身记录调用次数即可。
    func pullToActiveSpace()
}

/// 贴在原生 Dock 内侧的次级条窗口。
///
/// 窗口层配方沿用 `DesktopNameToastWindow`（那条配方每一条都是踩过坑的）：
/// borderless、`canBecomeKey` / `canBecomeMain` = false（绝不抢焦点）、用 `orderFrontRegardless()` 显示。
/// 与 toast 的三点不同：
/// - **空间归属用 `.moveToActiveSpace`（实验 24 折中方案，2026-10-05 用户拍板）**：
///   「跨空间可见且过渡不滑动」零权限下无解（窗口层级 / Dock tags / `CGSSetWindowWorkspace`
///   全证伪，特权来自进程身份）——只有系统窗口（原生 Dock、菜单栏）能钉住。本条改为
///   `.moveToActiveSpace`：**切换桌面瞬间条留在旧空间（对新空间不可见，不滑动）**，切换完成
///   后由 `SecondaryDockController.spaceDidChange` 调 `pullToActiveSpace()` 把它拉回当前空间
///   并淡入。`NSWorkspace.activeSpaceDidChangeNotification` 只在真人手势时触发，但程序化
///   切换（菜单栏点击）也有 `SpaceSwitcher.switchTo → observer.refreshNow()` 立即回调，
///   两条路都在切换当拍拉回，没有 300 ms 空窗。
/// - `ignoresMouseEvents = false` —— 条要接收点击与 hover；
/// - `level = 19` —— **低于** Dock 的 20：半露时滑进 Dock 身后的部分被 Dock 像素挡住，
///   视觉上就是「从原生 Dock 底下探出来」；
/// - 内容是可交互的 SwiftUI 图标条（点击启动，hover 滑出）。
@MainActor
final class SecondaryDockWindow: SecondaryDockPresenting {

    /// 低于 Dock（20）、高于一切普通窗口。toast 用 25（高于 Dock），本条必须**低于** Dock。
    private static let windowLevel = NSWindow.Level(rawValue: 19)
    private static let cornerRadius: CGFloat = 14
    /// 常态配方：窗口只属一个空间——切换瞬间留在旧空间（对新空间不可见，**不滑动**，实验 24）。
    private static let singleSpaceBehavior: NSWindow.CollectionBehavior =
        [.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    /// 拉回瞬间的临时配方：跨空间可见，`orderFrontRegardless` 借它在当前空间重新注册。
    private static let crossSpaceBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    /// 拉回后的淡入时长——与 hover 滑动（`setFrame` 动画 0.18 s）同款节奏。
    private static let pullFadeDuration = 0.18

    private let window: SecondaryDockPanelWindow
    private let container: NSVisualEffectView
    private var hosting: NSHostingView<SecondaryDockStripView>!
    /// 「设回单空间配方」的延迟任务；连切时取消上一拍未生效的，防止堆积。
    private var pullResetTask: Task<Void, Never>?

    /// 点击条目。由 `AppDelegate` 注入（`NSWorkspace.open`）。
    var onActivate: (SecondaryDockItem) -> Void = { _ in }
    /// hover 进/出。由 `AppDelegate` 接到 `SecondaryDockController.hoverChanged(_:)`。
    var onHoverChange: (Bool) -> Void = { _ in }

    /// 工厂与测试共用：`SecondaryDockWindowFactory` 直接走这条装配路径，
    /// 快照验出来的才是真窗口。
    init() {
        window = SecondaryDockPanelWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = Self.windowLevel
        window.collectionBehavior = Self.singleSpaceBehavior
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.animationBehavior = .none
        window.ignoresMouseEvents = false

        // 材质与 toast 同款：`.popover` 跟随亮/深色外观，`behindWindow` 能压在任意内容上。
        container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active

        hosting = NSHostingView(rootView: makeStrip(items: [], isVertical: false, iconSize: 36))
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
    }

    func updateContent(_ content: SecondaryDockContentSnapshot, isVertical: Bool) {
        hosting.rootView = makeStrip(
            items: content.items,
            isVertical: isVertical,
            iconSize: content.iconSize
        )
    }

    func setFrame(_ frame: NSRect, animated: Bool) {
        container.frame = NSRect(origin: .zero, size: frame.size)
        // NSVisualEffectView 没有 cornerRadius（那是 UIKit 的），圆角靠 maskImage 现画。
        container.maskImage = Self.maskImage(size: frame.size)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    func orderFront() {
        // 不用 makeKeyAndOrderFront：那会抢焦点（toast 的既有教训）。
        window.orderFrontRegardless()
    }

    func orderOut() {
        window.orderOut(nil)
    }

    /// 拉回当前活动空间并淡入（`spike-pull-nsworkspace` 实证配方）：
    /// 1. 置透明 → 切到临时跨空间配方 → `orderFrontRegardless` 在当前空间重新注册；
    /// 2. 下一拍（16 ms，spike 实证 10 ms 即够，留一帧余量）设回单空间配方；
    /// 3. 0.18 s easeInEaseOut 淡入（与 hover 滑动同款节奏）。
    /// 连击时 `pullResetTask` 先取消上一拍未生效的复位，防止旧任务把新空间的配方改回去。
    func pullToActiveSpace() {
        pullResetTask?.cancel()
        window.alphaValue = 0
        window.collectionBehavior = Self.crossSpaceBehavior
        orderFront()
        pullResetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            self.window.collectionBehavior = Self.singleSpaceBehavior
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.pullFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 1
        }
    }

    private func makeStrip(items: [SecondaryDockItem], isVertical: Bool, iconSize: CGFloat) -> SecondaryDockStripView {
        SecondaryDockStripView(
            items: items,
            isVertical: isVertical,
            iconSize: iconSize,
            onActivate: { [weak self] item in self?.onActivate(item) },
            onHoverChange: { [weak self] inside in self?.onHoverChange(inside) }
        )
    }

    /// 圆角遮罩：按当前尺寸现画一张 alpha 图（不做拉伸——拉伸会把圆角扯成椭圆）。
    private static func maskImage(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
    }
}

/// 显式禁掉「能成为 key / main」——无边框窗口默认就不行，写出来是为了让人一眼看到这条硬约束。
private final class SecondaryDockPanelWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 供 `UISnapshotTests` 离屏渲染用的装配入口。**必须**与真实窗口同一条路径，
/// 快照里另拼视图验出来的不算（与 `SettingsWindowFactory` 同一约定）。
@MainActor
enum SecondaryDockWindowFactory {
    static func makeWindow(
        items: [SecondaryDockItem],
        isVertical: Bool,
        iconSize: CGFloat,
        frame: NSRect
    ) -> NSWindow {
        let dockWindow = SecondaryDockWindow()
        dockWindow.updateContent(
            SecondaryDockContentSnapshot(items: items, iconSize: iconSize),
            isVertical: isVertical
        )
        dockWindow.setFrame(frame, animated: false)
        return dockWindow.panelWindow
    }
}

extension SecondaryDockWindow {
    /// 工厂读取底层 `NSWindow`（同文件内可访问 private 存储属性）。
    fileprivate var panelWindow: NSWindow { window }
}

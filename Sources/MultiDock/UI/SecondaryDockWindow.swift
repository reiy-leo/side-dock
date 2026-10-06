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
    /// 手势预隐藏（实验 26）：type 30 前置手势一触发就直设 α=0 —— 切桌面前把条藏掉，
    /// 翻转过渡就「不跟着滑」。不走 animator（在本窗口实测随机静默失效，实验 26 26e/26f）。
    func hideForSpaceTransition()
    /// 预隐藏超时的分步渐回（打断横扫/误扫）：α 分 6 步 × 20 ms 直设回 1。
    func fadeBackFromSpaceTransition()
    /// 安全网信号：窗口是否挂在当前活动空间（孤儿空间绑定检测，实验 26 26e）。
    var isOnActiveSpace: Bool { get }
    /// 安全网信号：当前透明度（animator 卡死 / 渐回中断检测，实验 26 26f）。
    var currentAlpha: CGFloat { get }
}

/// 右键菜单的条目集合（2026-10-06）：屏幕位置快捷切换。**纯函数**。
///
/// 与设置页 `DockBarsTab.positionOptions(for:)` 同一口径：可选位置
/// （台前调度开着避开左）之外，栏当前存着的位置即使不在可选清单里也要插回去 ——
/// 勾标如实展示现状，用户至少能从「左侧（台前调度占用的那边）」改走。
enum SecondaryDockContextMenuBuilder {
    struct Item: Equatable {
        let position: DockBarPosition
        let isCurrent: Bool
    }

    static func items(current: DockBarPosition, available: [DockBarPosition]) -> [Item] {
        var options = available
        if !options.contains(current) {
            options.insert(current, at: 0)
        }
        return options.map { Item(position: $0, isCurrent: $0 == current) }
    }
}

/// 贴在原生 Dock 内侧的次级条窗口。
///
/// 窗口层配方沿用 `HudToastWindow`（那条配方每一条都是踩过坑的）：
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
/// - 内容是可交互的 SwiftUI 图标条（点击启动，hover 滑出；**右键弹屏幕位置菜单**，2026-10-06）。
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
    /// 拉回后的升起时长（实验 25：从原生 Dock 底部探回 + 同步淡显，替代原地 alpha 淡入；
    /// 加上检测/拉回开销，切换结束后总感知 ≈ 0.14 s，压进用户规格的 0.15 s 内）。
    private static let pullRiseDuration = 0.12
    /// 沉没位余量：整条沉到原生 Dock 上缘（`visibleFrame` 底边）以下再多留的距离。
    private static let sinkMargin: CGFloat = 6

    private let window: SecondaryDockPanelWindow
    private let container: NSVisualEffectView
    private var hosting: SecondaryDockHostingView!
    /// 「设回单空间配方」的延迟任务；连切时取消上一拍未生效的，防止堆积。
    private var pullResetTask: Task<Void, Never>?
    /// 分步 alpha 渐变任务（实验 26 26f）。`window.animator().alphaValue` 在本窗口实测
    /// 随机静默失效（26e 九次超时渐回七次卡死 alpha=0.0），渐回全部换手动分步直设。
    private var fadeTask: Task<Void, Never>?
    /// 最近一次 `setFrame` 的目标位（动画进行中也记录终点）。拉回的升起目标用它：
    /// 安全网兜底时窗口 frame 可能停在沉没位等废值，当前 frame 不能当目标（实验 26 26f）。
    private var intendedFrame: NSRect?

    /// 点击条目。由 `AppDelegate` 注入（`NSWorkspace.open`）。
    var onActivate: (SecondaryDockItem) -> Void = { _ in }
    /// hover 进/出。由 `AppDelegate` 接到 `SecondaryDockController.hoverChanged(_:)`。
    var onHoverChange: (Bool) -> Void = { _ in }
    /// 右键菜单选中了新位置（栏 ID, 目标位置）。由 `AppDelegate` 接到
    /// `AppState.setDockBarPosition`（2026-10-06）。
    var onPositionSelected: (UUID?, DockBarPosition) -> Void = { _, _ in }
    /// 可选位置清单（台前调度开着避开左）。由 `AppDelegate` 接到 `AppState.availableBarPositions`
    /// （环境缓存，2 s 轮询保鲜；菜单每次右键现建，最多滞后一拍）。
    var availablePositionsProvider: () -> [DockBarPosition] = { DockBarPosition.allCases }

    /// 右键菜单的 target。NSMenuItem 对 target 是 assign（不保活），必须由窗口存储属性常驻持有。
    private let menuTarget = SecondaryDockMenuTarget()
    /// 最近一次内容的位置与所属栏（右键菜单的勾标与落点）。
    private var currentPosition: DockBarPosition = .bottom
    private var currentBarID: UUID?

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

        hosting = SecondaryDockHostingView(rootView: makeStrip(items: [], isVertical: false, iconSize: 36))
        hosting.autoresizingMask = [.width, .height]
        hosting.menuProvider = { [weak self] in self?.makeContextMenu() }
        container.addSubview(hosting)
        window.contentView = container

        menuTarget.onSelect = { [weak self] position in
            guard let self else { return }
            self.onPositionSelected(self.currentBarID, position)
        }
    }

    func updateContent(_ content: SecondaryDockContentSnapshot, isVertical: Bool) {
        currentPosition = content.position
        currentBarID = content.barID
        hosting.rootView = makeStrip(
            items: content.items,
            isVertical: isVertical,
            iconSize: content.iconSize
        )
    }

    func setFrame(_ frame: NSRect, animated: Bool) {
        intendedFrame = frame
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

    /// 拉回当前活动空间并从原生 Dock 底部升起（实验 25 实证编排）：
    /// 1. 记录原位 → 置透明、frame 一次跳到沉没位（整条在 `visibleFrame` 底边以下，
    ///    此刻窗口还属旧空间，跳变无视觉）；
    /// 2. 切到临时跨空间配方 → `orderFrontRegardless` 在当前空间重新注册；
    /// 3. 下一拍（16 ms，spike 实证 10 ms 即够，留一帧余量）设回单空间配方；
    /// 4. 0.12 s easeInEaseOut 升回原位，alpha 分步直设同步淡显（各 6 步 × 20 ms ——
    ///    即便 Dock 在左/右侧、沉没位不被遮挡，也只是无方向感的淡入，不会破相）。
    /// 连击时 `pullResetTask` 先取消上一拍未生效的复位，防止旧任务把新空间的配方改回去。
    func pullToActiveSpace() {
        pullResetTask?.cancel()
        fadeTask?.cancel()
        let targetFrame = intendedFrame ?? window.frame
        let visibleBottom = (window.screen ?? NSScreen.main)?.visibleFrame.minY ?? 0
        window.alphaValue = 0
        window.setFrame(
            NSRect(
                x: targetFrame.minX,
                y: visibleBottom - targetFrame.height - Self.sinkMargin,
                width: targetFrame.width,
                height: targetFrame.height
            ),
            display: false
        )
        window.collectionBehavior = Self.crossSpaceBehavior
        orderFront()
        pullResetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            self.window.collectionBehavior = Self.singleSpaceBehavior
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.pullRiseDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
        }
        // alpha 不进动画组：animator 渐回在本窗口实测随机静默失效（实验 26 26e/26f），
        // 换分步直设（6 步 × 20 ms ≈ 120 ms，与 0.12 s 升起同步收尾）。
        fadeAlpha(to: 1)
    }

    /// 手势预隐藏（实验 26）：type 30 一到就直设 α=0。
    func hideForSpaceTransition() {
        fadeTask?.cancel()
        window.alphaValue = 0
    }

    /// 打断横扫（600 ms 无切换）的分步渐回。
    func fadeBackFromSpaceTransition() {
        fadeAlpha(to: 1)
    }

    var isOnActiveSpace: Bool { window.isOnActiveSpace }
    var currentAlpha: CGFloat { window.alphaValue }

    /// 右键菜单：屏幕位置快捷切换（2026-10-06）。**每次右键现建**（`SecondaryDockHostingView`
    /// 的 `rightMouseDown` 调进来），当前位置勾标与台前调度避左都按当下状态。internal =
    /// 测试见证位：装配与 target 分发必须可断言（rules.md「见证位」教训）。
    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.title = L("屏幕位置", "Screen Position")
        for item in SecondaryDockContextMenuBuilder.items(
            current: currentPosition,
            available: availablePositionsProvider()
        ) {
            let menuItem = NSMenuItem(
                title: item.position.displayName,
                action: #selector(SecondaryDockMenuTarget.positionChosen(_:)),
                keyEquivalent: ""
            )
            menuItem.target = menuTarget
            menuItem.representedObject = item.position.rawValue
            menuItem.state = item.isCurrent ? .on : .off
            menu.addItem(menuItem)
        }
        return menu
    }

    /// 分步直设 alpha（实验 26 26f）。被取消时停在中间值 —— 调用方
    ///（hideForSpaceTransition / pullToActiveSpace 开头）随即直设 0，无残留。
    private func fadeAlpha(to target: CGFloat, steps: Int = 6, intervalMs: Int = 20) {
        fadeTask?.cancel()
        let from = window.alphaValue
        let delta = target - from
        guard abs(delta) > 0.005 else { return }
        fadeTask = Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(intervalMs))
                guard !Task.isCancelled, let self else { return }
                self.window.alphaValue = from + delta * CGFloat(step) / CGFloat(steps)
            }
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

/// 承载 SwiftUI 内容并接管右键。条上的 SwiftUI 手势只管左键（`onTapGesture`），
/// 右键走 AppKit 原路 —— 在这里显式 popUp 位置菜单，不依赖内容层、不怕 SwiftUI 手势抢事件。
@MainActor
private final class SecondaryDockHostingView: NSHostingView<SecondaryDockStripView> {
    /// 每次右键现建菜单（当前位置勾标、台前调度避左都按当下状态）。
    /// 返回值用 `NSMenu?`：窗口层拿不到菜单（理论不可达）时回落 AppKit 默认行为。
    var menuProvider: (() -> NSMenu?)?

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuForRightClick() else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// 单独展平一层：`menuProvider?()` 对可选返回值会产生双可选。
    private func menuForRightClick() -> NSMenu? {
        guard let provider = menuProvider else { return nil }
        return provider()
    }
}

/// 右键菜单的 target。**NSMenuItem 对 target 是 assign（不保活）**——临时对象会在
/// 菜单弹出前析构、动作静默失联，所以由窗口的存储属性常驻持有（见 `SecondaryDockWindow.menuTarget`）。
@MainActor
private final class SecondaryDockMenuTarget: NSObject {
    var onSelect: ((DockBarPosition) -> Void)?

    @objc func positionChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let position = DockBarPosition(rawValue: raw) else { return }
        onSelect?(position)
    }
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

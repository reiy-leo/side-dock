import AppKit

/// 次级 Dock 条的调度逻辑。**不碰 AppKit 窗口**（呈现走 `SecondaryDockPresenting`，
/// 几何走 `DockFaceProviding`），状态机可以脱离真实窗口单测 —— 与 `ToastPresenter` 同一拆分。
///
/// 状态只有两个：半露（默认）与展开（hover）。窗口在「启用 + 在用户桌面 + 有内容」时显示，
/// 全屏空间（`space == nil`）与关闭开关时隐藏 —— 与原生 Dock 的可见性行为对齐。
@MainActor
final class SecondaryDockController {

    struct Dependencies {
        var presenter: any SecondaryDockPresenting
        var faceProvider: any DockFaceProviding
        /// 当前桌面 → 内容快照；nil = 没有可显示的内容。由 `AppState` 提供。
        var content: (DesktopSpace?) -> SecondaryDockContentSnapshot?
        var isEnabled: () -> Bool
        var log: (String) -> Void
        /// hover 离开后收回去的防抖时长（防止掠过时闪烁）。
        var tuckDebounce: Duration = .milliseconds(150)
        /// 几何轮询周期（Dock 方位/大小/自动隐藏变化只靠轮询发现）。
        /// 200 ms：自动隐藏的显出/收回同步也靠这个节拍，太慢跟不上 Dock 的滑入滑出。
        var geometryPollInterval: Duration = .milliseconds(200)
        /// 光标离开显出带后收回的宽限时长（Dock 自己收回也有迟滞，防止掠过边缘闪烁）。
        var revealGrace: Duration = .milliseconds(400)
        /// 鼠标位置。收回去之前核对一遍 —— 窗口自己动过时 `onHover(false)` 可能丢事件；
        /// 显出带判定也用它。
        var mouseLocation: () -> CGPoint = { NSEvent.mouseLocation }
    }

    private let deps: Dependencies
    private var geometryTask: Task<Void, Never>?
    private var tuckTask: Task<Void, Never>?

    private var face: DockFaceGeometry?
    private var revealedFrame: NSRect?
    private var tuckedFrame: NSRect?
    private var currentIsVertical = false
    private var isRevealed = false
    private var isShowing = false
    private var lastSpace: DesktopSpace?
    /// 最近一次见到的 Dock 占用条带。face == nil（自动隐藏生效中）时用它判定
    /// 光标是否在「显出带」里 ——Dock 的实际显隐没有零权限的直读信号（实验 22）。
    private var lastDockArea: CGRect?
    /// 光标离开显出带后的宽限收起任务。
    private var hideGraceTask: Task<Void, Never>?

    init(deps: Dependencies) {
        self.deps = deps
    }

    /// 启动几何轮询。**先立即探一次再进入周期**，否则条要等一个周期才出现。
    func start() {
        geometryTask?.cancel()
        geometryTask = Task { [interval = deps.geometryPollInterval] in
            while !Task.isCancelled {
                self.geometryTick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        geometryTask?.cancel()
        geometryTask = nil
        tuckTask?.cancel()
        tuckTask = nil
        hide()
    }

    /// 桌面变化（`SpaceObserver.onActiveSpaceChanged` 的第三个消费者）。
    /// `nil` = 全屏空间，与原生 Dock 一样躲起来。
    func spaceDidChange(_ space: DesktopSpace?) {
        lastSpace = space
        applyCurrentState()
    }

    /// 开关或配置（settings / bindings）变化后的统一入口。
    func refresh() {
        applyCurrentState()
    }

    /// 屏幕变化 / 周期轮询共用：Dock 的排他几何变了就重新摆放。
    func geometryTick() {
        guard deps.isEnabled() else {
            hide()
            return
        }
        let fresh = deps.faceProvider.currentFace()
        guard fresh != face else {
            // 几何没变也要跟光标：自动隐藏生效中（face == nil），显出/收回完全由光标位置驱动。
            if face == nil {
                evaluateHiddenStateVisibility(with: deps.content(lastSpace))
            }
            return
        }
        face = fresh
        if let fresh {
            lastDockArea = SecondaryDockLayout.dockArea(of: fresh)
        }
        deps.log("次级 Dock 条：Dock 几何变化 → \(fresh.map { "\($0.orientation) 内缩 \($0.visible)" } ?? "探测不到")")
        applyCurrentState()
    }

    // MARK: - hover

    func hoverChanged(_ inside: Bool) {
        if inside {
            tuckTask?.cancel()
            tuckTask = nil
            guard !isRevealed, let revealed = revealedFrame else { return }
            isRevealed = true
            deps.presenter.setFrame(revealed, animated: true)
            return
        }
        guard isRevealed, tuckTask == nil else { return }
        tuckTask = Task { [debounce = deps.tuckDebounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.tuckIfMouseOutside()
        }
    }

    /// 收回去。鼠标可能其实还停在条上（窗口自己动过、exit 事件丢了），先核对一遍位置。
    private func tuckIfMouseOutside() {
        tuckTask = nil
        guard isRevealed, let tucked = tuckedFrame, let revealed = revealedFrame else { return }
        guard !revealed.contains(deps.mouseLocation()) else { return }
        isRevealed = false
        deps.presenter.setFrame(tucked, animated: true)
    }

    // MARK: - 内部

    private func applyCurrentState() {
        guard deps.isEnabled(), let space = lastSpace, let content = deps.content(space) else {
            hide()
            return
        }
        guard let face else {
            // Dock 没占屏幕（自动隐藏生效中 / 重启瞬态）：可见性与原生 Dock 同步——
            // 光标在显出带里 = Dock 在屏（正在显出）→ 显示并照常换内容；不在 → 宽限后收起。
            // 换内容不挪窗：frame 沿用最近一次 face 的摆放（tucked/revealed 一直保留着）。
            evaluateHiddenStateVisibility(with: content)
            return
        }
        let barSize = SecondaryDockLayout.barSize(
            itemCount: content.sizingSlots ?? content.items.count,
            iconSize: content.iconSize,
            isVertical: face.orientation.isBarVertical
        )
        let placement = SecondaryDockLayout.placement(barSize: barSize, face: face)
        revealedFrame = placement.revealed
        tuckedFrame = placement.tucked
        currentIsVertical = face.orientation.isBarVertical
        deps.presenter.updateContent(content, isVertical: currentIsVertical)
        applyCurrentFrame(animated: false)
        if !isShowing {
            isShowing = true
            deps.presenter.orderFront()
        }
    }

    private func applyCurrentFrame(animated: Bool) {
        let frame = isRevealed ? revealedFrame : tuckedFrame
        if let frame {
            deps.presenter.setFrame(frame, animated: animated)
        }
    }

    private func hide() {
        tuckTask?.cancel()
        tuckTask = nil
        hideGraceTask?.cancel()
        hideGraceTask = nil
        isRevealed = false
        guard isShowing else { return }
        isShowing = false
        deps.presenter.orderOut()
    }

    // MARK: - 与原生 Dock 的可见性同步（自动隐藏）

    /// Dock 的实际显隐没有零权限的直读信号（实验 22：typed setter 只翻旗标不改 work area，
    /// 探针窗口 occlusionState 不可靠，CGWindowList 在 15.8.1 看不到 Dock）。
    /// 用「光标是否在最近一次 Dock 占用条带（略外扩）里」近似：光标碰边 = Dock 显出，条跟着出来；
    /// 离开 = Dock 收回，条宽限后收回。
    private func evaluateHiddenStateVisibility(with content: SecondaryDockContentSnapshot?) {
        // 从没见过 Dock 几何就没有可用的 frame（零尺寸窗口），宁可继续藏着。
        guard tuckedFrame != nil else { return }
        if let content, cursorInRevealZone() {
            hideGraceTask?.cancel()
            hideGraceTask = nil
            deps.presenter.updateContent(content, isVertical: currentIsVertical)
            if !isShowing {
                isShowing = true
                deps.presenter.orderFront()
            }
        } else {
            scheduleGraceHide()
        }
    }

    private func cursorInRevealZone() -> Bool {
        guard let area = lastDockArea else { return false }
        return area.insetBy(dx: -8, dy: -8).contains(deps.mouseLocation())
    }

    /// 光标离开显出带后宽限收回 —— 与 Dock 自己收回的迟滞对齐，防止掠过屏幕边缘时闪烁。
    private func scheduleGraceHide() {
        guard isShowing, hideGraceTask == nil else { return }
        hideGraceTask = Task { [grace = deps.revealGrace] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            self.hideIfCursorStillOutside()
        }
    }

    private func hideIfCursorStillOutside() {
        hideGraceTask = nil
        guard isShowing, !cursorInRevealZone() else { return }
        hide()
    }
}

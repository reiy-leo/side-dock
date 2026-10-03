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
        var geometryPollInterval: Duration = .seconds(1)
        /// 鼠标位置。收回去之前核对一遍 —— 窗口自己动过时 `onHover(false)` 可能丢事件。
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
        guard fresh != face else { return }
        face = fresh
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
            // 探测不到 Dock（如自动隐藏滑走中）：保持现有位置，只换内容。
            if isShowing {
                deps.presenter.updateContent(content, isVertical: currentIsVertical)
            }
            return
        }
        let barSize = SecondaryDockLayout.barSize(
            itemCount: content.items.count,
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
        isRevealed = false
        guard isShowing else { return }
        isShowing = false
        deps.presenter.orderOut()
    }
}

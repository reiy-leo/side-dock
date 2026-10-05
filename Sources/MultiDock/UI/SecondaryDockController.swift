import AppKit

/// 次级 Dock 条的调度逻辑。**不碰 AppKit 窗口**（呈现走 `SecondaryDockPresenting`，
/// 几何走 `DockFaceProviding`），状态机可以脱离真实窗口单测 —— 与 `ToastPresenter` 同一拆分。
///
/// 状态只有两个：半露（默认）与展开（hover）。窗口在「启用 + 在用户桌面 + 有内容」时显示，
/// 全屏空间（`space == nil`）与关闭开关时隐藏 —— 与原生 Dock 的可见性行为对齐。
/// 另有一个瞬态：**手势预隐藏**（实验 26）——type 30 前置手势一拍即隐，翻转确认后由
/// 拉回编排接管，600 ms 无切换（打断横扫）则分步渐回。
///
/// **摆放模式（2026-10-05：每根 Dock 栏可设位置）**：
/// - **附着**（栏位置 == 原生 Dock 方位）：贴原生 Dock 内侧，半露被 Dock 挡住；
///   显隐与原生 Dock 同步（自动隐藏时跟光标显出带，实验 22 启发式）。
/// - **独立贴边**（栏位置 ≠ Dock 方位）：贴自己那一边的屏幕边缘，半露 = 滑出屏幕一半；
///   与原生 Dock 的显隐**无关**（它本来就不在那条边上），常驻半露。
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
        /// 手势预隐藏的超时渐回（实验 26 26f）。真切换发生在最后一个 type 30 之后
        /// 550–650 ms —— 压短会提前显形反闪，别调。
        var gestureRevealTimeout: Duration = .milliseconds(600)
        /// 安全网静默窗（实验 26 26f）：状态机动作后静默超过这个时长才检查；
        /// 连续未愈翻倍退避（防 Mission Control 打开期间反复闪动）。
        var safetyNetQuietWindow: Duration = .milliseconds(250)
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
    /// 最近一次内容的位置。附着/独立的判定基准。
    private var currentPosition: DockBarPosition = .bottom
    /// 最近一次见到的 Dock 方位。face == nil（自动隐藏生效中）时用它判定附着/独立。
    private var lastFaceOrientation: SecondaryDockOrientation?
    /// 最近一次见到的 Dock 占用条带。face == nil（自动隐藏生效中）时用它判定
    /// 光标是否在「显出带」里 ——Dock 的实际显隐没有零权限的直读信号（实验 22）。
    private var lastDockArea: CGRect?
    /// 光标离开显出带后的宽限收起任务。
    private var hideGraceTask: Task<Void, Never>?
    /// 手势预隐藏态（实验 26）：type 30 已触发，等翻转确认或超时渐回。
    private var isPreHidden = false
    /// 预隐藏的超时任务（连击续命 = 每个 30 重挂）。
    private var gestureRevealTask: Task<Void, Never>?
    /// 最近一次状态机动作（手势/翻转确认/超时/安全网兜底）时刻；安全网静默窗基准。
    private var lastStateMachineEventAt: ContinuousClock.Instant?
    /// 安全网连续未愈次数（退避：250 → 500 ms）。
    private var netBackoff = 0
    private let clock = ContinuousClock()

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
    ///
    /// 方案 ② 的拉回时机就在这里（实验 24 / AGENTS.md §6.1 #4，2026-10-05 拍板）：
    /// 窗口单空间配方（`.moveToActiveSpace`）在切换瞬间留在旧空间——新空间看不见它，**不滑动**；
    /// 切换完成回调到达时把它拉回当前空间并淡入。手势与程序化切换（`SpaceSwitcher.switchTo →
    /// observer.refreshNow()`）都会当拍走到这里，没有 300 ms 空窗。
    func spaceDidChange(_ space: DesktopSpace?) {
        let spaceChanged = space != lastSpace
        let wasShowing = isShowing
        lastSpace = space
        applyCurrentState()
        guard spaceChanged else { return }
        // 翻转已确认（手势/键盘/MC 出入都走这里）：预隐藏使命结束，超时任务作废，
        // 由拉回编排接管显形（实验 26 26f）。
        isPreHidden = false
        gestureRevealTask?.cancel()
        gestureRevealTask = nil
        netBackoff = 0
        lastStateMachineEventAt = clock.now
        // 只在「换了空间」且「条在旧空间还挂着、新空间仍要显示」时拉回：
        // - 从隐藏到显示（全屏回来 / 刚开启）不用拉——`orderFront` 本身就落在当前空间；
        // - 切到全屏（nil）`applyCurrentState` 已把条藏起来，`isShowing` 变 false，不拉；
        // - 同一空间的重复事件不拉，防止淡入叠淡入的闪烁。
        if wasShowing, isShowing {
            deps.presenter.pullToActiveSpace()
        }
    }

    // MARK: - 手势预隐藏（实验 26：type 30 前置手势 → 切桌面「不跟着滑」）

    /// 三/四指切桌面的前置手势（`SpaceTransitionGestureMonitor` 的 type 30 回调）。
    /// 翻转前 ~620 ms 内必现：第一时间把条藏掉，翻转过渡就看不见条在滑。
    /// 打断横扫与 ⌃→ 键盘切换（零 30）不进这里 —— 前者超时渐回，后者照旧拉回。
    func spaceTransitionGestureDetected() {
        guard deps.isEnabled(), isShowing else { return }
        lastStateMachineEventAt = clock.now
        if isPreHidden {
            // 连击续命：最后一个 30 后 550–650 ms 才翻转，每个新 30 重挂超时。
        } else {
            isPreHidden = true
            // 顺手收回复展态：预隐藏期间收不到 hover 反馈，收回去切完桌面浮出的就是干净的半露。
            isRevealed = false
            applyCurrentFrame(animated: false)
            deps.presenter.hideForSpaceTransition()
            deps.log("次级 Dock 条：切桌面前置手势 → 预隐藏")
        }
        gestureRevealTask?.cancel()
        gestureRevealTask = Task { [timeout = deps.gestureRevealTimeout, weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.revealOnGestureTimeout()
        }
    }

    /// 超时无空间切换 = 打断的横扫（没切过去）：分步渐回。
    /// 不做沉没位升起 —— 空间没翻，窗口还在原地（spike 26f 行为）。
    private func revealOnGestureTimeout() {
        gestureRevealTask = nil
        guard isPreHidden else { return }
        isPreHidden = false
        lastStateMachineEventAt = clock.now
        deps.presenter.fadeBackFromSpaceTransition()
        deps.log("次级 Dock 条：超时无切换 → 分步渐回（误扫）")
    }

    /// 安全网（实验 26 26e/26f）：animator 卡死 / 孤儿空间绑定 / 渐回中断的兜底。
    /// 条件刻意**模式无关**（独立贴边的半露 frame 本来就滑出屏幕一半，不能用「frame 出屏」
    /// 判定）：只看「不在当前空间」与「非预隐藏却 alpha<1」两个信号。预隐藏期间两者都豁免
    /// —— 翻转前窗口还挂在当前空间、alpha=0 是预期态，且每个 30 都在续命。
    /// 挂在 `geometryTick`（200 ms 节拍）里：恢复延迟以节拍为上界。
    private func runSpaceTransitionSafetyNet() {
        guard isShowing, let lastEventAt = lastStateMachineEventAt else { return }
        // 静默窗退避（spike 26f：250 → 500 ms，防 MC 打开期间反复闪动）。
        let quietWindow = netBackoff >= 1
            ? deps.safetyNetQuietWindow + deps.safetyNetQuietWindow
            : deps.safetyNetQuietWindow
        guard clock.now - lastEventAt > quietWindow else { return }
        let stuckOffSpace = !isPreHidden && !deps.presenter.isOnActiveSpace
        let stuckDimmed = !isPreHidden && deps.presenter.currentAlpha < 0.99
        guard stuckOffSpace || stuckDimmed else { return }
        netBackoff += 1
        lastStateMachineEventAt = clock.now
        deps.presenter.pullToActiveSpace()
        deps.log(
            "次级 Dock 条：安全网 #\(netBackoff) 兜底重挂"
                + "（不在当前空间=\(stuckOffSpace) 卡半透明=\(stuckDimmed)）"
        )
    }

    /// 开关或配置（settings / bars）变化后的统一入口。
    func refresh() {
        applyCurrentState()
    }

    /// 屏幕变化 / 周期轮询共用：Dock 的排他几何变了就重新摆放。
    func geometryTick() {
        guard deps.isEnabled() else {
            hide()
            return
        }
        runSpaceTransitionSafetyNet()
        let fresh = deps.faceProvider.currentFace()
        guard fresh != face else {
            // 几何没变也要跟光标：自动隐藏生效中（face == nil）且条附着在 Dock 那条边上时，
            // 显出/收回完全由光标位置驱动；独立贴边的条不参与这套同步。
            if face == nil, isAttachedToDock {
                evaluateHiddenStateVisibility(with: deps.content(lastSpace))
            }
            return
        }
        face = fresh
        if let fresh {
            lastDockArea = SecondaryDockLayout.dockArea(of: fresh)
            lastFaceOrientation = fresh.orientation
        }
        deps.log("次级 Dock 条：Dock 几何变化 → \(fresh.map { "\($0.orientation) 内缩 \($0.visible)" } ?? "探测不到")")
        applyCurrentState()
    }

    // MARK: - hover

    func hoverChanged(_ inside: Bool) {
        // 预隐藏期间不响应 hover：窗口正透明，显形/收回都无视觉意义，
        // 还会把 frame 留在展开位（切完桌面浮出全条；实验 26）。
        guard !isPreHidden else { return }
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

    /// 当前条是否「附着」在原生 Dock 那条边上（位置 == Dock 方位）。
    /// face 探测不到时（自动隐藏生效中）用最近一次见到的方位兜底。
    private var isAttachedToDock: Bool {
        guard let orientation = face?.orientation ?? lastFaceOrientation else {
            // 从没见过 Dock：默认 bottom 口径（原生 Dock 最常见的位置）。
            return currentPosition == .bottom
        }
        return currentPosition.matches(orientation)
    }

    private func applyCurrentState() {
        guard deps.isEnabled(), let space = lastSpace, let content = deps.content(space) else {
            hide()
            return
        }
        currentPosition = content.position
        let barSize = SecondaryDockLayout.barSize(
            itemCount: content.items.count,
            iconSize: content.iconSize,
            isVertical: content.position.isBarVertical
        )
        // 附着模式（face 在场且方位一致）：贴原生 Dock 内侧。
        if let face, currentPosition.matches(face.orientation) {
            let placement = SecondaryDockLayout.placement(barSize: barSize, face: face)
            revealedFrame = placement.revealed
            tuckedFrame = placement.tucked
            currentIsVertical = currentPosition.isBarVertical
            deps.presenter.updateContent(content, isVertical: currentIsVertical)
            applyCurrentFrame(animated: false)
            if !isShowing {
                isShowing = true
                deps.presenter.orderFront()
            }
            return
        }
        // face == nil（Dock 自动隐藏生效中 / 重启瞬态）且这根栏本来就附着在 Dock 那条边上：
        // 沿用最近一次的附着摆放，可见性交给显出带判定（实验 22 启发式）。
        // ⚠️ 不能在这里落到独立贴边 —— 那会让跟随 Dock 隐藏的条在 Dock 滑走瞬间"常驻"。
        let rememberedAttached = face == nil
            && (lastFaceOrientation.map { currentPosition.matches($0) } ?? (currentPosition == .bottom))
        if rememberedAttached {
            currentIsVertical = currentPosition.isBarVertical
            deps.presenter.updateContent(content, isVertical: currentIsVertical)
            evaluateHiddenStateVisibility(with: content)
            return
        }
        // 独立贴边：与原生 Dock 的几何无关（即便 face == nil 也照摆）。
        if let screen = deps.faceProvider.currentScreenFrame() {
            let placement = SecondaryDockLayout.standalonePlacement(
                barSize: barSize,
                position: currentPosition,
                screen: screen
            )
            revealedFrame = placement.revealed
            tuckedFrame = placement.tucked
            currentIsVertical = currentPosition.isBarVertical
            deps.presenter.updateContent(content, isVertical: currentIsVertical)
            applyCurrentFrame(animated: false)
            if !isShowing {
                isShowing = true
                deps.presenter.orderFront()
            }
        }
        // 连屏幕都拿不到：沿用旧 frame，等下一个轮询拍。
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
        if isPreHidden {
            isPreHidden = false
            gestureRevealTask?.cancel()
            gestureRevealTask = nil
            // 把 alpha 分步复位：否则下次 orderFront 摊上一个隐形窗口。
            deps.presenter.fadeBackFromSpaceTransition()
        }
        guard isShowing else { return }
        isShowing = false
        deps.presenter.orderOut()
    }

    // MARK: - 与原生 Dock 的可见性同步（自动隐藏；只对附着模式的条生效）

    /// Dock 的实际显隐没有零权限的直读信号（实验 22：typed setter 只翻旗标不改 work area，
    /// 探针窗口 occlusionState 不可靠，CGWindowList 在 15.8.1 看不到 Dock）。
    /// 用「光标是否在最近一次 Dock 占用条带（略外扩）里」近似：光标碰边 = Dock 显出，条跟着出来；
    /// 离开 = Dock 收回，条宽限后收回。
    ///
    /// **独立贴边的条不走这里**：它不在 Dock 那条边上，Dock 藏不藏与它无关（常驻半露）。
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

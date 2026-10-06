import Foundation

/// 主动切换桌面。
///
/// 目标 = **当前活动显示器上**、按 `Spaces` 数组顺序（即左右顺序）取的下一个/上一个
/// 用户桌面，两端循环。见 `docs/PLAN.md` §3.1。
///
/// **过渡动画（2026-10-06）**：系统快捷键（⌃← / ⌃→）那条路能借到 WindowServer 的滑动过渡，
/// 所以「相邻一步」优先**合成按键**（需要辅助功能权限，见 `AnimatedSpaceSwitch`）。
/// 合成只保证"事件已投递"，所以**异步确认**：`synthesisTimeout` 内空间没翻转 → 硬切兜底。
/// **绝不会卡住不切**；主线程也不被阻塞（确认在后台 Task 里等）。
///
/// 边界（有意为之）：菜单里**跨桌面点选**与**两端循环**仍走硬切 —— 合成按键只能表达
/// "系统顺序上的相邻一步"，跨选要连打好几拍、动画叠在一起，体验更差。
@MainActor
final class SpaceSwitcher {

    private let observer: SpaceObserver
    private let synthesizer: (any SpaceStepSynthesizing)?
    /// 合成后等空间翻转的上限。**空间 ID 在过渡动画结束后才翻**（实验 25 实测），
    /// 键盘触发的过渡约 300–450 ms，故取 800 ms 留足余量。超时只影响"合成被吞"这一
    /// 罕见情形的兜底延迟；正常路径一翻到就返回，与这个值无关。
    private let synthesisTimeout: Duration
    private let pollInterval: Duration
    /// 日志出口。`AppState` 在 init 完成后回接（init 阶段还不能引用 self）。
    private var log: @MainActor (String) -> Void

    init(
        observer: SpaceObserver,
        synthesizer: (any SpaceStepSynthesizing)? = nil,
        synthesisTimeout: Duration = .milliseconds(800),
        pollInterval: Duration = .milliseconds(20),
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.observer = observer
        self.synthesizer = synthesizer
        self.synthesisTimeout = synthesisTimeout
        self.pollInterval = pollInterval
        self.log = log
    }

    /// 回接日志出口（`AppState` 用：init 里拿不到 self）。
    func setLogger(_ logger: @escaping @MainActor (String) -> Void) {
        log = logger
    }

    /// 合成通路的可用性（设置页提示用）：装没装合成器 + 权限是否已授予。
    var animatedSwitchPermitted: Bool {
        synthesizer?.isPermitted ?? false
    }

    enum Direction { case next, previous }

    /// 切换风格：相邻一步可走合成（带动画），其余走硬切。
    enum SwitchStyle: Equatable {
        case hard
        case animatedStep(Direction)

        var direction: Direction? {
            if case .animatedStep(let direction) = self { return direction }
            return nil
        }
    }

    /// 当前桌面所属显示器上的用户桌面列表（保持左右顺序）。
    private func peers(of space: DesktopSpace) -> [DesktopSpace] {
        observer.desktops.filter { $0.displayUUID == space.displayUUID }
    }

    /// 切到下一个/上一个桌面。返回被切到的桌面，无可切时返回 nil。
    @discardableResult
    func step(_ direction: Direction) -> DesktopSpace? {
        guard let target = target(direction) else { return nil }
        return switchTo(target, style: .animatedStep(direction))
    }

    /// **只算出**下一个/上一个桌面，不真的切。
    ///
    /// 预应用要用它：先知道目标是谁，把它的 Dock 配置推下去，再切空间 ——
    /// 这样切换动画结束时 Dock 已经是正确状态（`docs/PLAN.md` §3.4 第 8 条）。
    func target(_ direction: Direction) -> DesktopSpace? {
        guard let current = observer.activeSpace else { return nil }
        let list = peers(of: current)
        guard list.count > 1 else { return nil }
        guard let index = list.firstIndex(where: { $0.spaceUUID == current.spaceUUID }) else { return nil }

        let offset = direction == .next ? 1 : -1
        return list[(index + offset + list.count) % list.count]
    }

    /// 目标是否与当前桌面在**系统顺序**上相邻（相邻才谈得上"合成一步"）。
    ///
    /// 判据是前后索引差恰好 ±1。**两端循环跳不算** —— 系统键盘切换在首/尾不循环，
    /// 合成表达不了（会静默没反应）。两个桌面时 0→1 是正常一步（可合成），1→0 才是循环跳。
    func isAdjacentStep(to target: DesktopSpace, direction: Direction) -> Bool {
        guard let current = observer.activeSpace else { return false }
        let list = peers(of: current)
        guard
            let currentIndex = list.firstIndex(where: { $0.spaceUUID == current.spaceUUID }),
            let targetIndex = list.firstIndex(where: { $0.spaceUUID == target.spaceUUID })
        else { return false }
        let offset = direction == .next ? 1 : -1
        return targetIndex == currentIndex + offset
    }

    /// 切到指定桌面。切换后立刻刷新观察器，不等下一个轮询周期。
    ///
    /// - Parameter style: `.hard` 直接硬切；`.animatedStep` 先试合成（异步确认 + 超时兜底）。
    @discardableResult
    func switchTo(_ space: DesktopSpace, style: SwitchStyle = .hard) -> DesktopSpace? {
        guard observer.provider.isAvailable else { return nil }

        if let direction = style.direction,
           let synthesizer,
           isAdjacentStep(to: space, direction: direction) {
            if synthesizer.isPermitted {
                let posted = synthesizer.synthesizeStep(previous: direction == .previous)
                if posted {
                    log("合成 \(direction == .previous ? "⌃←" : "⌃→")：走系统过渡动画切到相邻桌面")
                    confirmAnimatedStep(to: space, from: observer.activeSpace)
                    return space
                }
                log("合成键盘事件失败（会话不可用），回落到硬切")
            } else {
                log("没有辅助功能权限，无法借系统过渡动画（退化为硬切）")
            }
        }

        guard observer.provider.setCurrentSpace(space) else { return nil }
        observer.refreshNow()
        return space
    }

    /// 合成后的异步确认：空间在 `synthesisTimeout` 内翻到目标 → 收工；
    /// 否则说明系统吞了合成（热键被用户改过、被安全策略拦下等）→ **硬切兜底**。
    ///
    /// ⚠️ 每次循环都 `refreshNow()` 读**实时**状态：`observer.activeSpace` 是缓存，
    /// 不刷新的话即使系统真的切过去了也读不到 → 会误判超时、再硬切一次（多跳一拍）。
    ///
    /// ⚠️ 兜底前还要**防抢跑**：若超时时空间已经不在起点了（系统过渡迟到、正在途中），
    /// 就不要再硬切 —— 那会和系统自己的过渡打架（多跳一拍/闪回）。
    private func confirmAnimatedStep(to target: DesktopSpace, from origin: DesktopSpace?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + self.synthesisTimeout
            while ContinuousClock.now < deadline {
                self.observer.refreshNow()
                if self.observer.activeSpace?.id == target.id {
                    return
                }
                try? await Task.sleep(for: self.pollInterval)
                if Task.isCancelled { return }
            }
            self.observer.refreshNow()
            let current = self.observer.activeSpace
            guard current?.id == origin?.id else {
                self.log("合成切换超时，但空间已不在起点（系统过渡迟到），不再兜底硬切")
                return
            }
            self.log("合成切换未在 \(self.synthesisTimeout) 内生效，改用硬切")
            if self.observer.provider.setCurrentSpace(target) {
                self.observer.refreshNow()
            }
        }
    }
}

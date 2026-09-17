import Foundation

/// 主动切换桌面。
///
/// 目标 = **当前活动显示器上**、按 `Spaces` 数组顺序（即左右顺序）取的下一个/上一个
/// 用户桌面，两端循环。见 `docs/PLAN.md` §3.1。
@MainActor
final class SpaceSwitcher {

    private let observer: SpaceObserver

    init(observer: SpaceObserver) {
        self.observer = observer
    }

    enum Direction { case next, previous }

    /// 当前桌面所属显示器上的用户桌面列表（保持左右顺序）。
    private func peers(of space: DesktopSpace) -> [DesktopSpace] {
        observer.desktops.filter { $0.displayUUID == space.displayUUID }
    }

    /// 切到下一个/上一个桌面。返回被切到的桌面，无可切时返回 nil。
    @discardableResult
    func step(_ direction: Direction) -> DesktopSpace? {
        guard let target = target(direction) else { return nil }
        return switchTo(target)
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

    /// 切到指定桌面。切换后立刻刷新观察器，不等下一个轮询周期。
    @discardableResult
    func switchTo(_ space: DesktopSpace) -> DesktopSpace? {
        guard observer.provider.isAvailable else { return nil }
        guard observer.provider.setCurrentSpace(space) else { return nil }
        observer.refreshNow()
        return space
    }
}

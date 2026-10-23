import AppKit

/// 多行条的滚动切行（2026-10-23 用户规格：去掉抽屉，只显示一行，滚动切换，
/// 「滚动要有停顿感，而不是直接跳过其中某一条」）。**纯逻辑**，事件由窗口喂进来，方便单测。
///
/// 规则：
/// - 触控板（有 phase）：一次手势（began → ended）最多翻一行；累计位移过阈值才翻；
///   惯性（momentum）事件一概不翻——不然一甩就连跳两三行。
/// - 鼠标滚轮（无 phase、非精确）：一格翻一行。
/// - 翻完有冷却：冷却内的新手势 / 新一格都不翻，给出「停一下」的节奏。
struct SecondaryDockRowPager {
    enum Phase: Equatable {
        case none, began, changed, ended

        init(_ phase: NSEvent.Phase) {
            if phase.contains(.began) || phase.contains(.mayBegin) {
                self = .began
            } else if phase.contains(.ended) || phase.contains(.cancelled) {
                self = .ended
            } else if phase.contains(.changed) || phase.contains(.stationary) {
                self = .changed
            } else {
                self = .none
            }
        }
    }

    struct Sample: Equatable {
        /// 已换算成「正 = 往屏幕内侧的下一行」的位移（见 `directionalDelta`）。
        var delta: CGFloat
        var phase: Phase
        var isMomentum: Bool
        var isPrecise: Bool
        /// 事件时间（秒，单调）。
        var time: TimeInterval
    }

    /// 触控板累计多少点翻一行。
    static let preciseThreshold: CGFloat = 24
    /// 翻一行后的冷却（秒）。
    static let cooldown: TimeInterval = 0.35

    private var accumulated: CGFloat = 0
    private var lockedForGesture = false
    private var cooldownUntil: TimeInterval = -.infinity

    /// 喂一个滚动事件，返回 +1（下一行）/ -1（上一行）/ 0（不翻）。
    mutating func feed(_ sample: Sample) -> Int {
        if sample.isMomentum { return 0 }
        switch sample.phase {
        case .began:
            accumulated = 0
            lockedForGesture = false
        case .ended:
            accumulated = 0
            lockedForGesture = false
            return 0
        case .none, .changed:
            break
        }
        guard !lockedForGesture else { return 0 }
        guard sample.time >= cooldownUntil else {
            accumulated = 0
            return 0
        }
        guard sample.delta != 0 else { return 0 }
        let step: Int
        if sample.isPrecise || sample.phase != .none {
            accumulated += sample.delta
            guard abs(accumulated) >= Self.preciseThreshold else { return 0 }
            step = accumulated > 0 ? 1 : -1
        } else {
            step = sample.delta > 0 ? 1 : -1
        }
        accumulated = 0
        lockedForGesture = sample.phase != .none
        cooldownUntil = sample.time + Self.cooldown
        return step
    }

    /// 把滚动位移换算成「正 = 往屏幕内侧的下一行」。返回 nil = 这个方向不归条管。
    ///
    /// - 底部条：行往上叠，只吃竖向分量（`dy > 0` = 下一行）；横向为主的滚动留给系统（切桌面等）。
    /// - 左 / 右侧条：行往屏幕内侧排。横向为主时，往内侧推内容（左条 `dx < 0`、右条 `dx > 0`）= 下一行；
    ///   竖向为主（鼠标滚轮只有竖向）时同底部条，`dy > 0` = 下一行。
    static func directionalDelta(dx: CGFloat, dy: CGFloat, position: DockBarPosition) -> CGFloat? {
        let horizontal = abs(dx) > abs(dy)
        switch position {
        case .bottom:
            return horizontal ? nil : dy
        case .left:
            return horizontal ? -dx : dy
        case .right:
            return horizontal ? dx : dy
        }
    }
}

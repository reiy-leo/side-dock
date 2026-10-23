import CoreGraphics
import Foundation

/// 次级 Dock 条的方位（随原生 Dock 的位置）。
enum SecondaryDockOrientation: Equatable, Sendable {
    case bottom
    case left
    case right

    /// 条自身的走向：底部 Dock 配横条，侧边 Dock 配竖条。
    var isBarVertical: Bool { self != .bottom }
}

/// 原生 Dock 的排他几何（AppKit 坐标，y 向上）。
///
/// 由 `NSScreen.visibleFrame` 的内缩推出（`SecondaryDockLayout.detectDockFace`），
/// `visible` 就是系统为原生 Dock **预留过**的区域边界。
struct DockFaceGeometry: Equatable, Sendable {
    let orientation: SecondaryDockOrientation
    let screen: CGRect
    let visible: CGRect
}

/// 次级 Dock 条的几何。
///
/// **实测依据（2026-10-04，macOS 15.8.1，`docs/spikes.md` 实验 21）**：
/// Dock 条**不是**独立的 CG 窗口 —— Dock 进程在列表里只有一个全屏 layer-20 窗口，
/// 条画在它里面。所以几何源不用 CGWindowList，用 `visibleFrame` 的排他内缩
/// （本机 bottom 方位、tilesize 36 时 `minY = 53`）。
///
/// 摆放力学（用户规格：条在原生 Dock「下方」，默认半露、hover 全出）：
/// - 条贴在 Dock 的**内侧面**（bottom → 上方；right → 左侧；left → 右侧）；
/// - **半露** = 整条向 Dock 方向滑进去条厚的 `tuckRatio`（2026-10-06 用户调整：0.5 → 0.8，
///   与原生 Dock 重叠更多、只露一条薄边）—— 本条窗口层级低于 Dock（19 < 20），
///   滑进去的部分被原生 Dock 的像素自然挡住，看起来就是「从原生 Dock 底下探出一条边」；
/// - **hover 全出** = 向屏幕内侧滑出整条（内侧是普通窗口地盘，永远有空间）。
enum SecondaryDockLayout {

    /// 条与 Dock 内侧面之间的间隙。
    static let faceGap: CGFloat = 4
    /// 条到屏幕边缘的最小边距。
    static let screenMargin: CGFloat = 4
    /// 内缩小于这个值视为「探测不到 Dock」（自动隐藏滑走后内缩 ≈ 0）。
    static let hiddenInsetThreshold: CGFloat = 8
    /// 半露滑入占比：`tucked` 相对 `revealed` 向 Dock 方向滑入多少个条厚。
    /// 2026-10-06 用户调整：0.5（滑入一半）→ 0.8（与原生 Dock 重叠更多，约只露 20% 条厚）。
    /// **独立贴边不用它**：那边的半露按用户规格固定为「滑出屏幕一半」（`standalonePlacement`）。
    static let tuckRatio: CGFloat = 0.8

    /// 从屏幕与可见区内缩推断原生 Dock 的方位。探测不到返回 nil。
    static func detectDockFace(screen: CGRect, visible: CGRect) -> DockFaceGeometry? {
        let bottomInset = visible.minY - screen.minY
        let leftInset = visible.minX - screen.minX
        let rightInset = screen.maxX - visible.maxX
        let candidates: [(SecondaryDockOrientation, CGFloat)] = [
            (.bottom, bottomInset), (.left, leftInset), (.right, rightInset),
        ]
        // 并列时 max(by:) 取先出现的 bottom —— 菜单栏的内缩在顶部，不参与。
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 > hiddenInsetThreshold else {
            return nil
        }
        return DockFaceGeometry(orientation: best.0, screen: screen, visible: visible)
    }

    /// 按条目数与图标尺寸算条的尺寸（供给 `placement`）。
    /// 刻意比 SwiftUI 内容**略宽**：窗口是权威尺寸，内容居中放着，宁可有留白也不裁切。
    static func barSize(itemCount: Int, iconSize: CGFloat, isVertical: Bool) -> CGSize {
        let slotLength = CGFloat(max(itemCount, 1)) * (iconSize + 8) + 16
        let thickness = iconSize + 20
        return isVertical ? CGSize(width: thickness, height: slotLength)
            : CGSize(width: slotLength, height: thickness)
    }

    /// 多行指示点（2026-10-23 用户规格：去掉抽屉，只显示一行、滚动切换）沿条方向占的长度。
    static let rowIndicatorLength: CGFloat = 10

    /// 条的尺寸：长度按最长那一行（切行时窗口不忽宽忽窄），厚度恒为 1 行；
    /// 有多行时末端多留 `rowIndicatorLength` 放指示点。
    static func multiRowSize(maxItemCount: Int, rowCount: Int, iconSize: CGFloat, isVertical: Bool) -> CGSize {
        let base = barSize(itemCount: maxItemCount, iconSize: iconSize, isVertical: isVertical)
        let extra = rowCount > 1 ? rowIndicatorLength : 0
        return isVertical ? CGSize(width: base.width, height: base.height + extra)
            : CGSize(width: base.width + extra, height: base.height)
    }

    /// 计算条的展开（hover）与半露（默认）两个 frame。
    ///
    /// 半露的定义：`tucked` 相对 `revealed` 向 Dock 方向平移 `tuckRatio` 个条厚
    /// （滑入量取整到整点，半露边不落在半像素上）。
    static func placement(barSize: CGSize, face: DockFaceGeometry) -> (revealed: CGRect, tucked: CGRect) {
        let screen = face.screen
        let size = CGSize(
            width: min(barSize.width, screen.width - screenMargin * 2),
            height: min(barSize.height, screen.height - screenMargin * 2)
        )
        switch face.orientation {
        case .bottom:
            // 横条，水平居中（原生 Dock 的面板也是水平居中的），贴 Dock 顶边上方；
            // 半露 = 向下平移 0.8 个条高，只在 Dock 上缘外露出薄薄一条。
            let x = clamp(
                (screen.midX - size.width / 2).rounded(),
                low: screen.minX + screenMargin,
                high: screen.maxX - size.width - screenMargin
            )
            let revealed = CGRect(
                origin: CGPoint(x: x, y: face.visible.minY + faceGap),
                size: size
            )
            let tucked = revealed.offsetBy(dx: 0, dy: -tuckOffset(size.height))
            return (revealed, tucked)
        case .right:
            // 竖条，右缘贴 Dock 内侧面、**竖直居中**（2026-10-23 用户反馈「没有居中」：原生侧边 Dock
            // 本身竖直居中，以前贴屏幕底角看着歪）；半露 = 向右滑进 Dock 身后。
            let revealed = CGRect(
                origin: CGPoint(x: face.visible.maxX - faceGap - size.width, y: verticallyCenteredY(size, in: screen)),
                size: size
            )
            let tucked = revealed.offsetBy(dx: tuckOffset(size.width), dy: 0)
            return (revealed, tucked)
        case .left:
            // 竖条，左缘贴 Dock 内侧面、竖直居中（同右侧）；半露 = 向左滑进 Dock 身后。
            let revealed = CGRect(
                origin: CGPoint(x: face.visible.minX + faceGap, y: verticallyCenteredY(size, in: screen)),
                size: size
            )
            let tucked = revealed.offsetBy(dx: -tuckOffset(size.width), dy: 0)
            return (revealed, tucked)
        }
    }

    /// 半露的滑入量：条厚 × `tuckRatio`，取整到整点（0.8 × 56 = 44.8 这类浮点值
    /// 会把半露边摆在半像素上，整条边发虚）。
    private static func tuckOffset(_ thickness: CGFloat) -> CGFloat {
        (thickness * tuckRatio).rounded()
    }

    /// Dock 在屏上实际占用的条带（screen 与 visible 的差集）。
    ///
    /// 给次级条做「与原生 Dock 同步显隐」的显出带判定：自动隐藏生效中（face == nil）时，
    /// 光标落在这个条带（略外扩）里 = Dock 在屏或即将显出，条跟着显示。
    static func dockArea(of face: DockFaceGeometry) -> CGRect {
        let screen = face.screen
        let visible = face.visible
        switch face.orientation {
        case .bottom:
            return CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: visible.minY - screen.minY)
        case .left:
            return CGRect(x: screen.minX, y: screen.minY, width: visible.minX - screen.minX, height: screen.height)
        case .right:
            return CGRect(x: visible.maxX, y: screen.minY, width: screen.maxX - visible.maxX, height: screen.height)
        }
    }

    // MARK: - 独立贴边（2026-10-05：Dock 栏位置可设，≠ 原生 Dock 方位时走这里）

    /// 独立贴边摆放：栏不贴原生 Dock（`position` ≠ Dock 方位），改贴**自己那一边**的屏幕边缘。
    ///
    /// 半露的机制不同：贴 Dock 时靠层级 19 被 Dock（层级 20）挡住一半；
    /// 独立贴边没有可借用的遮挡者，改为**整条滑出屏幕一半** —— 出屏即「藏」，hover 滑回贴齐边缘。
    static func standalonePlacement(
        barSize: CGSize,
        position: DockBarPosition,
        screen: CGRect
    ) -> (revealed: CGRect, tucked: CGRect) {
        let size = CGSize(
            width: min(barSize.width, screen.width - screenMargin * 2),
            height: min(barSize.height, screen.height - screenMargin * 2)
        )
        switch position {
        case .bottom:
            let x = clamp(
                (screen.midX - size.width / 2).rounded(),
                low: screen.minX + screenMargin,
                high: screen.maxX - size.width - screenMargin
            )
            let revealed = CGRect(origin: CGPoint(x: x, y: screen.minY), size: size)
            return (revealed, revealed.offsetBy(dx: 0, dy: -size.height / 2))
        case .left:
            let y = clamp(
                (screen.midY - size.height / 2).rounded(),
                low: screen.minY + screenMargin,
                high: screen.maxY - size.height - screenMargin
            )
            let revealed = CGRect(origin: CGPoint(x: screen.minX, y: y), size: size)
            return (revealed, revealed.offsetBy(dx: -size.width / 2, dy: 0))
        case .right:
            let y = clamp(
                (screen.midY - size.height / 2).rounded(),
                low: screen.minY + screenMargin,
                high: screen.maxY - size.height - screenMargin
            )
            let revealed = CGRect(origin: CGPoint(x: screen.maxX - size.width, y: y), size: size)
            return (revealed, revealed.offsetBy(dx: size.width / 2, dy: 0))
        }
    }

    /// 竖条在屏幕上竖直居中的 y（取整、夹在边距内）。
    private static func verticallyCenteredY(_ size: CGSize, in screen: CGRect) -> CGFloat {
        clamp(
            (screen.midY - size.height / 2).rounded(),
            low: screen.minY + screenMargin,
            high: screen.maxY - size.height - screenMargin
        )
    }

    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
}

extension DockBarPosition {
    /// 与原生 Dock 方位是否同侧（同侧 = 附着模式，贴原生 Dock 内侧）。
    func matches(_ orientation: SecondaryDockOrientation) -> Bool {
        switch (self, orientation) {
        case (.bottom, .bottom), (.left, .left), (.right, .right): return true
        default: return false
        }
    }
}

/// 悬停放大（2026-10-23 用户规格：跟随系统「放大」开关与尺寸）。纯函数，方便单测。
///
/// 原生 Dock 的放大借不过来，这里自己算：光标附近的图标按距离做余弦衰减放大，
/// 邻居沿条方向让位，并保证**光标所在那一点不动**（放大不会把光标下的图标推走）。
/// 放大的图标朝屏幕内侧长出条外，窗口在内侧预留 `headroom` 的透明空间给它。
enum SecondaryDockMagnification {
    /// 系统 `largesize` 缺省值（macOS 默认放大尺寸）。
    static let defaultLargeSize: CGFloat = 128

    /// 放大后的图标尺寸：系统关了放大 → nil；开了 → `largesize`（缺省 128），钳在
    /// `iconSize...128`，比图标还小就等于不放大（nil）。
    static func magnifiedSize(enabled: Bool, largeSize: Double?, iconSize: CGFloat) -> CGFloat? {
        guard enabled else { return nil }
        let size = min(CGFloat(largeSize ?? Double(defaultLargeSize)), 128)
        return size > iconSize + 0.5 ? size : nil
    }

    /// 窗口朝屏幕内侧要多留的透明厚度（整点）。
    static func headroom(iconSize: CGFloat, magnifiedSize: CGFloat?) -> CGFloat {
        let bounce = bounceHeight(iconSize: iconSize)
        guard let magnifiedSize else { return bounce }
        return max(bounce, (magnifiedSize - iconSize).rounded(.up))
    }

    /// 点击启动时图标的弹跳高度（2026-10-23 用户规格：和原生一样弹几下）。
    /// 朝屏幕内侧弹，所以 `headroom` 至少要留这么多。
    static func bounceHeight(iconSize: CGFloat) -> CGFloat {
        (iconSize * 0.5).rounded(.up)
    }

    /// 窗口沿条方向**两端**各要多留的透明长度（整点，2026-10-23 真机：两端图标放大时被截断/看不见）。
    /// 光标停在一端时，另一侧让位的累计位移最多约「半个放大鼓包」的总增量，
    /// 再加末端图标自己放大后的半边溢出。按长条（足够多图标）估上界，保守取整。
    static func endRoom(iconSize: CGFloat, magnifiedSize: CGFloat?, pitch: CGFloat) -> CGFloat {
        guard let magnifiedSize, iconSize > 0, pitch > 0 else { return 0 }
        let extraMax = max(0, magnifiedSize - iconSize)
        guard extraMax > 0 else { return 0 }
        let reach = radius(pitch: pitch, magnifiedSize: magnifiedSize)
        // 余弦鼓包在 [-reach, reach] 上的积分 = reach，按槽位离散 ≈ reach / pitch 个满幅增量。
        let bumpTotal = extraMax * reach / pitch
        return (bumpTotal / 2 + extraMax / 2 + pitch).rounded(.up)
    }

    /// 槽位沿条方向的长度（与 `SecondaryDockSlotsView` 一致）：横条 = iconSize + 4；竖条 = iconSize + 6。
    static func slotLength(iconSize: CGFloat, isVertical: Bool) -> CGFloat {
        isVertical ? iconSize + 6 : iconSize + 4
    }

    /// 槽位间距（与 `SecondaryDockSlotsView` 一致）。
    static let slotSpacing: CGFloat = 2

    /// 影响半径：光标两侧这么远之内的图标会放大（约 2.5 个槽位，放大越大范围越宽）。
    static func radius(pitch: CGFloat, magnifiedSize: CGFloat) -> CGFloat {
        max(pitch * 2.5, magnifiedSize * 1.2)
    }

    /// 每个槽位的（放大倍数, 沿条方向的位移）。`cursor` 是光标在这一行内容坐标里沿条方向的位置
    /// （第一个槽位起点 = 0）；nil = 不在行上，全部 (1, 0)。
    static func effects(
        count: Int,
        slotLength: CGFloat,
        spacing: CGFloat,
        iconSize: CGFloat,
        magnifiedSize: CGFloat?,
        cursor: CGFloat?
    ) -> [(scale: CGFloat, offset: CGFloat)] {
        guard count > 0 else { return [] }
        guard let magnifiedSize, let cursor, iconSize > 0 else {
            return Array(repeating: (1, 0), count: count)
        }
        let pitch = slotLength + spacing
        let maxScale = magnifiedSize / iconSize
        let reach = radius(pitch: pitch, magnifiedSize: magnifiedSize)
        var scales: [CGFloat] = []
        var extras: [CGFloat] = []
        var cursorShift: CGFloat = 0
        for index in 0..<count {
            let center = CGFloat(index) * pitch + slotLength / 2
            let t = abs(center - cursor) / reach
            let bump = t < 1 ? (1 + cos(.pi * t)) / 2 : 0
            let scale = 1 + (maxScale - 1) * bump
            let extra = (scale - 1) * iconSize
            scales.append(scale)
            extras.append(extra)
            // 光标点在放大后布局里的位移 = 它之前（按比例）所有槽位多出来的长度。
            let fraction = min(max((cursor - (center - pitch / 2)) / pitch, 0), 1)
            cursorShift += extra * fraction
        }
        var result: [(scale: CGFloat, offset: CGFloat)] = []
        var before: CGFloat = 0
        for index in 0..<count {
            let shift = before + extras[index] / 2
            result.append((scales[index], shift - cursorShift))
            before += extras[index]
        }
        return result
    }

    /// 一排图标（放大 / 让位后）沿条方向实际占的范围，坐标原点 = 第一个槽位的起点。
    /// 图标在槽位里居中，放大后的边 = 槽位中心 + 位移 ± 放大尺寸 / 2。
    /// 用于让条的底板随内容变长（2026-10-23 用户反馈：hover 时两边的 App 超出条的范围）。
    static func extents(
        effects: [(scale: CGFloat, offset: CGFloat)],
        slotLength: CGFloat,
        spacing: CGFloat,
        iconSize: CGFloat
    ) -> (start: CGFloat, end: CGFloat) {
        guard !effects.isEmpty else { return (0, 0) }
        let pitch = slotLength + spacing
        var start = CGFloat.infinity
        var end = -CGFloat.infinity
        for (index, effect) in effects.enumerated() {
            let center = CGFloat(index) * pitch + slotLength / 2 + effect.offset
            let half = iconSize * effect.scale / 2
            start = min(start, center - half)
            end = max(end, center + half)
        }
        return (start, end)
    }

    /// 条底板两端要多伸出去的长度：图标边离条端不足 `margin` 的部分。
    /// `start` / `end` 是图标范围在条坐标里的位置，`barLength` 是条本体长度。
    static func barOverflow(start: CGFloat, end: CGFloat, barLength: CGFloat, margin: CGFloat = 6)
        -> SecondaryDockBarOverflow
    {
        guard barLength > 0 else { return .zero }
        return SecondaryDockBarOverflow(
            leading: max(0, (margin - start).rounded(.up)),
            trailing: max(0, (end - (barLength - margin)).rounded(.up))
        )
    }
}

/// 条底板沿条方向两端伸出的长度（leading = 横条左端 / 竖条上端）。
struct SecondaryDockBarOverflow: Equatable, Sendable {
    var leading: CGFloat
    var trailing: CGFloat
    static let zero = SecondaryDockBarOverflow(leading: 0, trailing: 0)
}

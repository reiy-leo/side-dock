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

    /// 多行条（2026-10-23）：相邻两行的行距（单行内容厚 `iconSize + 6` + 行间距 4）。
    static func rowPitch(iconSize: CGFloat) -> CGFloat { iconSize + 10 }

    /// `rows` 行时条的厚度（横条=高、竖条=宽）。1 行与 `barSize` 的厚度一致（`iconSize + 20`）。
    static func thickness(rows: Int, iconSize: CGFloat) -> CGFloat {
        iconSize + 20 + CGFloat(max(rows, 1) - 1) * rowPitch(iconSize: iconSize)
    }

    /// 多行条的尺寸：长度按最长那一行，厚度按行数（可传非整数行厚给拖拽中的实时尺寸）。
    static func multiRowSize(maxItemCount: Int, thickness: CGFloat, iconSize: CGFloat, isVertical: Bool) -> CGSize {
        let base = barSize(itemCount: maxItemCount, iconSize: iconSize, isVertical: isVertical)
        return isVertical ? CGSize(width: thickness, height: base.height)
            : CGSize(width: base.width, height: thickness)
    }

    /// 拖拽松手：把实时厚度吸附到最近的整行数（1...maxRows）。
    static func snappedRows(thickness: CGFloat, iconSize: CGFloat, maxRows: Int) -> Int {
        let raw = (thickness - self.thickness(rows: 1, iconSize: iconSize)) / rowPitch(iconSize: iconSize)
        let rows = Int(raw.rounded()) + 1
        return min(max(rows, 1), max(maxRows, 1))
    }

    /// 把条的厚度改成 `thickness`，**锚定靠原生 Dock / 屏幕边的那一侧**
    /// （底部 = 下沿不动往上长；左 = 左沿不动往右长；右 = 右沿不动往左长）。
    static func resized(_ frame: CGRect, toThickness thickness: CGFloat, position: DockBarPosition) -> CGRect {
        switch position {
        case .bottom:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: thickness)
        case .left:
            return CGRect(x: frame.minX, y: frame.minY, width: thickness, height: frame.height)
        case .right:
            return CGRect(x: frame.maxX - thickness, y: frame.minY, width: thickness, height: frame.height)
        }
    }

    /// 拖拽中按光标位置算条的厚度（锚定侧到光标的距离）。
    static func thickness(dragging point: CGPoint, anchoredFrame frame: CGRect, position: DockBarPosition) -> CGFloat {
        switch position {
        case .bottom: return point.y - frame.minY
        case .left: return point.x - frame.minX
        case .right: return frame.maxX - point.x
        }
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
        guard let magnifiedSize else { return 0 }
        return max(0, (magnifiedSize - iconSize).rounded(.up))
    }

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
}

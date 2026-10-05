import CoreGraphics

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
/// - **半露** = 整条向 Dock 方向滑进去一半 —— 本条窗口层级低于 Dock（19 < 20），
///   滑进去的那一半被原生 Dock 的像素自然挡住，看起来就是「从原生 Dock 底下探出一半」；
/// - **hover 全出** = 向屏幕内侧滑出整条（内侧是普通窗口地盘，永远有空间）。
enum SecondaryDockLayout {

    /// 条与 Dock 内侧面之间的间隙。
    static let faceGap: CGFloat = 4
    /// 条到屏幕边缘的最小边距。
    static let screenMargin: CGFloat = 4
    /// 内缩小于这个值视为「探测不到 Dock」（自动隐藏滑走后内缩 ≈ 0）。
    static let hiddenInsetThreshold: CGFloat = 8

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

    /// 计算条的展开（hover）与半露（默认）两个 frame。
    ///
    /// 半露的定义：`tucked` 相对 `revealed` 向 Dock 方向平移**半个条厚**。
    static func placement(barSize: CGSize, face: DockFaceGeometry) -> (revealed: CGRect, tucked: CGRect) {
        let screen = face.screen
        let size = CGSize(
            width: min(barSize.width, screen.width - screenMargin * 2),
            height: min(barSize.height, screen.height - screenMargin * 2)
        )
        switch face.orientation {
        case .bottom:
            // 横条，水平居中（原生 Dock 的面板也是水平居中的），贴 Dock 顶边上方；
            // 半露 = 向下平移半个条高，下半截被 Dock 挡住。
            let x = clamp(
                (screen.midX - size.width / 2).rounded(),
                low: screen.minX + screenMargin,
                high: screen.maxX - size.width - screenMargin
            )
            let revealed = CGRect(
                origin: CGPoint(x: x, y: face.visible.minY + faceGap),
                size: size
            )
            let tucked = revealed.offsetBy(dx: 0, dy: -size.height / 2)
            return (revealed, tucked)
        case .right:
            // 竖条，贴屏幕底角、右缘贴 Dock 内侧面；半露 = 向右滑进 Dock 身后。
            let revealed = CGRect(
                origin: CGPoint(x: face.visible.maxX - faceGap - size.width, y: screen.minY + screenMargin),
                size: size
            )
            let tucked = revealed.offsetBy(dx: size.width / 2, dy: 0)
            return (revealed, tucked)
        case .left:
            // 竖条，贴屏幕底角、左缘贴 Dock 内侧面；半露 = 向左滑进 Dock 身后。
            let revealed = CGRect(
                origin: CGPoint(x: face.visible.minX + faceGap, y: screen.minY + screenMargin),
                size: size
            )
            let tucked = revealed.offsetBy(dx: -size.width / 2, dy: 0)
            return (revealed, tucked)
        }
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

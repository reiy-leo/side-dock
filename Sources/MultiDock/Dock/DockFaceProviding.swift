import AppKit

/// 原生 Dock 排他几何的来源。协议化是为了测试里可以喂固定值。
@MainActor
protocol DockFaceProviding: AnyObject {
    /// 当前原生 Dock 的排他几何；nil = 探测不到（Dock 隐藏/无内缩），调用方应保持现状。
    func currentFace() -> DockFaceGeometry?
}

/// 真实实现：扫描所有 `NSScreen` 的 `visibleFrame` 内缩，取内缩最大的那块屏
/// （多显示器下原生 Dock 只出现在其中一块上）。
///
/// 依据 `SecondaryDockLayout` 头注释的实测结论：Dock 条不是独立 CG 窗口，
/// `visibleFrame` 的内缩才是系统为它预留位置的权威表达。
@MainActor
final class ScreenInsetDockFaceProvider: DockFaceProviding {
    func currentFace() -> DockFaceGeometry? {
        var best: DockFaceGeometry?
        var bestInset: CGFloat = 0
        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            let visible = screen.visibleFrame
            let inset = max(
                visible.minY - screenFrame.minY,
                visible.minX - screenFrame.minX,
                screenFrame.maxX - visible.maxX
            )
            guard inset > bestInset,
                let face = SecondaryDockLayout.detectDockFace(screen: screenFrame, visible: visible)
            else { continue }
            bestInset = inset
            best = face
        }
        return best
    }
}

import AppKit

/// 原生 Dock 排他几何的来源。协议化是为了测试里可以喂固定值。
@MainActor
protocol DockFaceProviding: AnyObject {
    /// 当前原生 Dock 的排他几何；nil = 探测不到（Dock 隐藏/无内缩），调用方应保持现状。
    func currentFace() -> DockFaceGeometry?
    /// Dock 所在显示器的屏幕矩形。
    ///
    /// 「独立贴边」的 Dock 栏（位置 ≠ 原生 Dock 方位）即使探测不到 face
    /// （自动隐藏生效中）也要能摆 —— 那种情况下以这张屏为准。
    /// nil = 连屏幕都拿不到（理论外），调用方保持现状。
    func currentScreenFrame() -> CGRect?
}

/// 真实实现：扫描所有 `NSScreen` 的 `visibleFrame` 内缩，取内缩最大的那块屏
/// （多显示器下原生 Dock 只出现在其中一块上）。
///
/// 依据 `SecondaryDockLayout` 头注释的实测结论：Dock 条不是独立 CG 窗口，
/// `visibleFrame` 的内缩才是系统为它预留位置的权威表达。
@MainActor
final class ScreenInsetDockFaceProvider: DockFaceProviding {
    private var lastKnownScreenFrame: CGRect?

    func currentFace() -> DockFaceGeometry? {
        var best: DockFaceGeometry?
        var bestInset: CGFloat = 0
        var bestScreen: CGRect?
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
            bestScreen = screenFrame
        }
        if let bestScreen {
            lastKnownScreenFrame = bestScreen
        }
        return best
    }

    func currentScreenFrame() -> CGRect? {
        if let face = currentFace() {
            lastKnownScreenFrame = face.screen
            return face.screen
        }
        // 探测不到 Dock（自动隐藏生效中）：用上次见过的 Dock 屏；从没见过就退主屏。
        if lastKnownScreenFrame != nil {
            return lastKnownScreenFrame
        }
        return NSScreen.screens.first(where: { $0 == NSScreen.main })?.frame
            ?? NSScreen.screens.first?.frame
    }
}

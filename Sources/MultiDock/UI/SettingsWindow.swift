import AppKit
import SwiftUI

/// 设置窗口的完整装配（SwiftUI 内容）+ 红绿灯重定位。AppDelegate 与 UI 快照测试**共用** ——
/// 快照要复制一份装配逻辑，验出来的就不是真窗口。
@MainActor
enum SettingsWindowFactory {
    static func makeWindow(state: AppState, tabModel: SettingsTabModel) -> NSWindow {
        let window = SettingsWindow(contentViewController: NSHostingController(
            rootView: SettingsView(state: state, tabModel: tabModel)
        ))
        // 系统设置风格（2026-10-06 用户要求）：去掉 titlebar，侧边栏贯通到窗口顶。
        // 仍保留 .titled —— 红绿灯与顶部隐藏拖拽区靠它；fullSizeContentView 让内容
        // 占满全高，侧边栏材质（NavigationSplitView 左列）因此延伸进原 titlebar 区。
        // title 只给「窗口」菜单与辅助功能用，界面上不再显示。
        window.title = L("MultiDock 设置", "MultiDock Settings")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // 关掉后仍保留实例，再次打开时复用，避免状态丢失。
        window.isReleasedWhenClosed = false
        // 与 `SettingsView` 根视图的 `.frame(width:height:)` 保持一致，
        // 否则窗口先按这个尺寸画一帧再被 SwiftUI 撑开，会看到一次跳动。
        window.setContentSize(NSSize(width: 880, height: 560))
        // 首帧就摆好红绿灯（不给系统默认位置任何露脸机会），之后由窗口的布局拍子维持。
        window.repositionTrafficLights()
        window.center()
        return window
    }
}

/// 红绿灯重定位的几何（2026-10-06 用户规格：**红绿灯和下方侧边栏图标对齐、左/上边距相等**）。
///
/// 实测（`SettingsChromeLayoutTests` 离屏墨迹扫描）：
/// 系统默认三个圆点中心 (14,14)/(34,14)/(54,14)，左/上边距各 8 pt；侧边栏图标列中心 x = 26
/// （五个行图标的墨迹中心 25.75–26.0；系统 List 的行内边距是固定值，窗口缩放不变）。
/// 目标：第一个圆点中心 (26, 26) —— 图标列正上方，左 = 上 = 边距 20 pt；步距保持系统默认 20。
enum TrafficLightLayout {
    /// 侧边栏图标列中心 x（pt，自窗口左边）。
    static let iconColumnCenterX: CGFloat = 26
    /// 圆点可见墨迹半径（直径 12 pt）。
    static let dotRadius: CGFloat = 6
    /// 左 / 上边距 —— 用户规格要求两者相等，取 20 = 图标列中心 26 − 半径 6
    /// （这个等式是"对齐且边距相等"的唯一解，别的值二选一必破；守卫测试钉住它）。
    static let edgeMargin: CGFloat = 20
    /// 圆点按钮中心步距（与系统默认一致，不另起一套）。
    static let dotSpacing: CGFloat = 20
    /// 标题栏视图与其容器向下的加长量：圆点下缘在顶下 32 pt，而系统标题栏（28 pt）的
    /// hit-test 区罩不住 —— 不补这一段，圆点下缘的点击会穿透到侧边栏。
    static let titlebarGrowth: CGFloat = 12

    /// 第 index 个圆点按钮的目标中心（窗口坐标，原点左下）。
    static func buttonCenter(index: Int, themeHeight: CGFloat) -> CGPoint {
        CGPoint(
            x: iconColumnCenterX + CGFloat(index) * dotSpacing,
            y: themeHeight - edgeMargin - dotRadius
        )
    }
}

/// 设置窗口：把红绿灯重定位到侧边栏图标列正上方（2026-10-06 用户规格）。
///
/// **为什么要在布局拍子里重贴**：`standardWindowButton` 的位置由 AppKit 管，没有公开 API
/// 可设；直接改 frame 有效（渲染、命中、hover 全跟按钮走），但**窗口缩放会把 frame 打回
/// 系统基准**（实测）——所以 override `layoutIfNeeded()` 在每次布局后重贴。重贴按窗口坐标
/// 换算、幂等（同一输入算出同一 frame，绝不来回抖动），缩放 / 换屏后仍落同一视觉位置。
///
/// 同时把标题栏视图与其容器向下加长（见 `TrafficLightLayout.titlebarGrowth`）：圆点下半截
/// 因此落在标题栏的 hit-test 区里，整颗圆点可点。这段加长是透明的（titlebarAppearsTransparent），
/// SwiftUI 内容的安全区不变（实测 `contentLayoutRect` / `safeAreaInsets` 都不动），
/// 唯一可见副作用是窗口顶部 40 pt 都能拖窗。
final class SettingsWindow: NSWindow {

    /// 标题栏视图 / 容器的基准 frame —— 以窗口顶为参照存（缩放后不失效），每个视图只记一次。
    private struct BaseFrame {
        var topInset: CGFloat
        var height: CGFloat
    }

    private var baseFrames: [ObjectIdentifier: BaseFrame] = [:]
    private var isRepositioning = false

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        repositionTrafficLights()
    }

    /// 把三个红绿灯圆点重贴到「侧边栏图标列正上方」。幂等，可在任意布局拍子后重复调用。
    func repositionTrafficLights() {
        // 全屏时空窗改造毫无意义（标题栏藏了），退出全屏后的布局拍子会补回来。
        guard !isRepositioning, !styleMask.contains(.fullScreen) else { return }
        guard let theme = contentView?.superview else { return }
        isRepositioning = true
        defer { isRepositioning = false }

        let themeHeight = theme.bounds.height

        // 先加长标题栏（其后所有子视图的窗口位置随之下移），再摆按钮 ——
        // 这样单次调用就收敛到目标位，不给中间帧任何机会。
        if let close = standardWindowButton(.closeButton),
           let titlebar = close.superview,
           let container = titlebar.superview {
            extendDownward(titlebar, by: TrafficLightLayout.titlebarGrowth, themeHeight: themeHeight)
            extendDownward(container, by: TrafficLightLayout.titlebarGrowth, themeHeight: themeHeight)
        }

        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in types.enumerated() {
            guard let button = standardWindowButton(type), let superview = button.superview else { continue }
            let center = TrafficLightLayout.buttonCenter(index: index, themeHeight: themeHeight)
            let centerInSuper = superview.convert(center, from: nil)
            let size = button.frame.size
            let target = NSRect(
                x: centerInSuper.x - size.width / 2,
                y: centerInSuper.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            if button.frame != target {
                button.frame = target
            }
        }
    }

    /// 把视图顶边钉住、下边向下加长 `growth`（绝对量；重复调用是幂等的，缩放打回后能再补）。
    private func extendDownward(_ view: NSView, by growth: CGFloat, themeHeight: CGFloat) {
        guard let superview = view.superview else { return }
        let current = superview.convert(view.frame, to: nil)
        // 退化帧（还没排过版）不记基准，等下一拍。
        guard current.height >= 20 else { return }
        let base: BaseFrame
        if let recorded = baseFrames[ObjectIdentifier(view)] {
            base = recorded
        } else {
            base = BaseFrame(topInset: themeHeight - current.maxY, height: current.height)
            baseFrames[ObjectIdentifier(view)] = base
        }
        let target = NSRect(
            x: current.minX,
            y: themeHeight - base.topInset - (base.height + growth),
            width: current.width,
            height: base.height + growth
        )
        let inSuper = superview.convert(target, from: nil)
        if view.frame != inSuper {
            view.frame = inSuper
        }
    }
}

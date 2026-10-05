import AppKit

/// 菜单栏图标：从 Lucide 图标库（ISC 许可，https://lucide.dev）选的五个之一。
///
/// **为什么内嵌 SVG 而不是系统符号**：用户指定了 Lucide 的具体图标
/// （tree-deciduous / parasol / sparkles / app-window-mac / shell），
/// SF Symbols 里没有对应的形状。SVG 源码逐字取自 lucide-static v1.52.0，
/// 只把 `stroke="currentColor"` 保持为墨色描边 —— 渲染后交给 `isTemplate`，
/// 由系统按菜单栏亮/暗与高亮态自动着色（模板图 = 只用 alpha，不用颜色）。
///
/// **渲染路径**：macOS 原生 `NSImage(data:)` 直接解码 SVG（实测返回 `_NSSVGImageRep`，
/// 本机 macOS 15.8.1 可用，无需任何第三方库、无网络请求）。
enum MenuBarIcon: String, Codable, Sendable, CaseIterable {
    case treeDeciduous
    case parasol
    case sparkles
    case appWindowMac
    case shell

    /// 默认值：落叶树 —— 与「多桌面」最贴的一个意象。
    static let `default`: MenuBarIcon = .treeDeciduous

    var displayName: String {
        switch self {
        case .treeDeciduous: return "落叶树"
        case .parasol: return "遮阳伞"
        case .sparkles: return "闪光"
        case .appWindowMac: return "窗口"
        case .shell: return "贝壳"
        }
    }

    /// Lucide 的图标名（查源、换图标时对得上）。
    var lucideName: String {
        switch self {
        case .treeDeciduous: return "tree-deciduous"
        case .parasol: return "parasol"
        case .sparkles: return "sparkles"
        case .appWindowMac: return "app-window-mac"
        case .shell: return "shell"
        }
    }

    /// 菜单栏用的模板图（18 pt）。取不到时返回 nil，调用方回落到系统符号。
    @MainActor
    var image: NSImage? {
        MenuBarIconRenderer.image(for: self, size: 18)
    }

    /// 设置页预览用图（指定尺寸，同样模板化 —— SwiftUI 里用 `foregroundStyle` 上色）。
    @MainActor
    func image(size: CGFloat) -> NSImage? {
        MenuBarIconRenderer.image(for: self, size: size)
    }
}

/// SVG 渲染与缓存。**`@MainActor`**：`NSImage` 按需光栅化、缓存是可变静态状态——
/// 两个使用点（菜单栏按钮、设置页预览）本来都跑在主线程，收敛到主 actor 最省事也最诚实。
@MainActor
enum MenuBarIconRenderer {
    private static var cache: [String: NSImage] = [:]

    static func image(for icon: MenuBarIcon, size: CGFloat) -> NSImage? {
        let key = "\(icon.rawValue)@\(size)"
        if let cached = cache[key] { return cached }
        guard let image = render(icon, size: size) else { return nil }
        cache[key] = image
        return image
    }

    private static func render(_ icon: MenuBarIcon, size: CGFloat) -> NSImage? {
        guard let data = icon.svgDocument.data(using: .utf8) else { return nil }
        guard let image = NSImage(data: data) else { return nil }
        // SVG 声明 24×24；菜单栏图标按点尺寸显式设小（模板图由系统着色）。
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}

extension MenuBarIcon {
    /// 完整 SVG 文档：Lucide 的默认线宽 2 / 圆头圆角连接，只把颜色固定为墨色
    /// （模板图只用 alpha，颜色本身不参与最终呈现）。
    fileprivate var svgDocument: String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" \
        fill="none" stroke="#000000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        \(pathBody)
        </svg>
        """
    }

    /// 路径数据逐字取自 Lucide（lucide-static v1.52.0，ISC 许可）。
    fileprivate var pathBody: String {
        switch self {
        case .treeDeciduous:
            return #"<path d="M8 19a4 4 0 0 1-2.24-7.32A3.5 3.5 0 0 1 9 6.03V6a3 3 0 1 1 6 0v.04a3.5 3.5 0 0 1 3.24 5.65A4 4 0 0 1 16 19Z"/><path d="M12 19v3"/>"#
        case .parasol:
            return #"<path d="M12.5 11.134 18.196 21"/><path d="M20.425 5.299a10 10 0 0 0-16.941 9.78c.183.563.843.774 1.355.478L20.16 6.711c.512-.296.66-.973.264-1.413"/><path d="M21 21H3"/>"#
        case .sparkles:
            return #"<path d="M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z"/><path d="M20 2v4"/><path d="M22 4h-4"/><circle cx="4" cy="20" r="2"/>"#
        case .appWindowMac:
            return #"<rect width="20" height="16" x="2" y="4" rx="2"/><path d="M6 8h.01"/><path d="M10 8h.01"/><path d="M14 8h.01"/>"#
        case .shell:
            return #"<path d="M14 11a2 2 0 1 1-4 0 4 4 0 0 1 8 0 6 6 0 0 1-12 0 8 8 0 0 1 16 0 10 10 0 1 1-20 0 11.93 11.93 0 0 1 2.42-7.22 2 2 0 1 1 3.16 2.44"/>"#
        }
    }
}

import AppKit
import QuartzCore

/// 名称面板**背景效果**的外观配方（纯值，可单测）。
///
/// ⚠️ 效果修饰的是**面板背景**，不是字体（2026-10-06 用户澄清）—— 文字始终是同一个
/// `NSTextField`，只是颜色随背景切换（暗底上用白字保证可读）。
struct DesktopNameEffectSpec: Equatable {
    /// 底色渐变（两色，从上到下）—— 暗底保证白字在任何壁纸上都读得清。
    var baseColors: [NSColor]
    /// 流动光带的颜色（每条一带）。
    var bandColors: [NSColor]
    /// 光带峰值不透明度。**刻意压低**：光带扫过文字下方时也不能把白字冲淡。
    var bandAlpha: CGFloat
    /// 一条光带扫过一整程的时长（秒）。
    var flowPeriod: TimeInterval
    /// 光带是否呼吸（赛博紫韵的「韵」；流动霓虹保持常亮）。
    var pulses: Bool
    /// 圆角描边色（霓虹灯管的边缘）。
    var borderColor: NSColor
}

extension DesktopNameEffect {
    /// 背景渲染配方。`.standard` 走原生磨砂面板（无配方）。
    var spec: DesktopNameEffectSpec? {
        switch self {
        case .standard:
            return nil
        case .neonFlow:
            // 深蓝黑底 + 青 / 品红两条光带相向扫过（霓虹招牌的经典双色），2.2 s 一程。
            return DesktopNameEffectSpec(
                baseColors: [
                    NSColor(srgbRed: 0.043, green: 0.063, blue: 0.129, alpha: 1),
                    NSColor(srgbRed: 0.094, green: 0.055, blue: 0.176, alpha: 1),
                ],
                bandColors: [
                    NSColor(srgbRed: 0.13, green: 0.90, blue: 1.00, alpha: 1),
                    NSColor(srgbRed: 1.00, green: 0.31, blue: 0.85, alpha: 1),
                ],
                bandAlpha: 0.50,
                flowPeriod: 2.2,
                pulses: false,
                borderColor: NSColor(srgbRed: 0.25, green: 0.72, blue: 1.00, alpha: 1)
            )
        case .cyberPurple:
            // 深紫底 + 亮紫 / 薰衣草紫两条光带同向慢扫（2.8 s），带呼吸 + 描边脉动。
            return DesktopNameEffectSpec(
                baseColors: [
                    NSColor(srgbRed: 0.086, green: 0.043, blue: 0.157, alpha: 1),
                    NSColor(srgbRed: 0.129, green: 0.055, blue: 0.216, alpha: 1),
                ],
                bandColors: [
                    NSColor(srgbRed: 0.69, green: 0.42, blue: 1.00, alpha: 1),
                    NSColor(srgbRed: 0.88, green: 0.60, blue: 1.00, alpha: 1),
                ],
                bandAlpha: 0.46,
                flowPeriod: 2.8,
                pulses: true,
                borderColor: NSColor(srgbRed: 0.61, green: 0.36, blue: 1.00, alpha: 1)
            )
        }
    }
}

/// 名称面板的**背景**效果画布：暗底渐变 + 流动光带 + 发光描边，圆角裁剪。
///
/// **为什么是 CoreGraphics 自绘 + 定时器**：① 项目的 `cacheDisplay` 离屏快照只走视图
/// 绘制路径，CoreAnimation 图层内容（尤其带 mask 的）抓不全 —— 自绘让快照与真机同一份
/// 渲染代码；② 项目既有教训是「别依赖隐式动画通道」（animator alpha 随机静默失效）——
/// 这里每帧显式 `needsDisplay`，相位是普通状态，可测可查。
///
/// 动画只在**展示的那 1 秒**里跑：`startAnimating()` / `stopAnimating()` 由窗口的
/// show/hide 调用；隐藏后定时器立即失效，不烧 CPU。
///
/// ⚠️ 本视图是**背景层**（窗口里位于文字 label 之下）——效果修饰背景，不碰字体
/// （2026-10-06 用户澄清）。
@MainActor
final class DesktopNameEffectCanvas: NSView {

    /// 当前效果（`.standard` 时本视图由窗口整体隐藏，不会走到绘制）。
    var effect: DesktopNameEffect = .standard {
        didSet {
            guard effect != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 面板圆角（与窗口同一常量）——底色/光带/描边都按这个圆角裁剪。
    var cornerRadius: CGFloat = DesktopNameOverlayWindow.cornerRadius {
        didSet { needsDisplay = true }
    }

    /// 流光相位（0..<1）。正常由计时器推进；测试/快照可显式设一个确定值。
    var phase: CGFloat = 0

    /// 是否正在播动画（展示期间 true，收起/默认档 false）。单测断言生命周期用。
    var isAnimating: Bool { timer != nil }

    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    /// 每帧间隔（30 fps）。展示只活 1 秒，30 帧足够顺滑，又便宜。
    static let frameInterval: TimeInterval = 1.0 / 30.0

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // 刻意**不写 deinit 停表**：`deinit` 是 nonisolated 的，碰不到主线程的 `timer`
    // （Swift 6 严格并发下直接编译失败）。生命周期由窗口负责 —— `hide()` 停表、
    // 窗口析构即释放；展示窗口与 App 同生命周期，不存在"视图没了定时器还在"的场景。

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: - 动画生命周期（只在窗口可见期间跑）

    func startAnimating() {
        guard effect.spec != nil, timer == nil, bounds.width > 1 else { return }
        lastTick = CACurrentMediaTime()
        // ⚠️ 用 `Timer.scheduledTimer` 而不是 `DispatchSourceTimer(queue: .main)` ——
        // 后者在本项目的长驻 RunLoop 场景里有「一次都不 fire」的实测前科（rules.md）。
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` 模式：菜单/滚动等追踪期间也照常推进。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let spec = effect.spec else { return }
        let now = CACurrentMediaTime()
        let elapsed = max(0, now - lastTick)
        lastTick = now
        phase = (phase + CGFloat(elapsed / spec.flowPeriod)).truncatingRemainder(dividingBy: 1)
        needsDisplay = true
    }

    /// 从 `show()` 每次重新开始：相位归零，动画重头播。
    func resetPhase() {
        phase = 0
        lastTick = CACurrentMediaTime()
        needsDisplay = true
    }

    // MARK: - 绘制（背景：暗底 → 光带 → 描边）

    override func draw(_ dirtyRect: NSRect) {
        guard let spec = effect.spec,
              let context = NSGraphicsContext.current?.cgContext
        else { return }

        let shape = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.saveGState()
        context.addPath(shape)
        context.clip()

        drawBase(spec: spec, in: context)
        drawBands(spec: spec, in: context)
        drawBorder(spec: spec, in: context)

        context.restoreGState()
    }

    /// 底色：两色竖向渐变（不透明）—— 白字可读性与壁纸无关，这是效果档的确定性来源。
    private func drawBase(spec: DesktopNameEffectSpec, in context: CGContext) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: spec.baseColors.map(\.cgColor) as CFArray,
            locations: [0, 1]
        ) else { return }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bounds.midX, y: bounds.maxY),
            end: CGPoint(x: bounds.midX, y: bounds.minY),
            options: []
        )
    }

    /// 流动光带：每条是"透明 → 彩色 → 透明"的横向渐变柱，用 `.plusLighter` 叠加
    /// （两带交叉处自然提亮）。竖向铺满、边缘柔和。
    private func drawBands(spec: DesktopNameEffectSpec, in context: CGContext) {
        let pulse: CGFloat = spec.pulses
            ? 0.78 + 0.22 * (0.5 + 0.5 * sin(phase * 2 * .pi))   // 0.78 … 1.00
            : 1
        let bandWidth = bounds.width * 0.62
        context.saveGState()
        context.setBlendMode(.plusLighter)
        for (index, color) in spec.bandColors.enumerated() {
            let center = Self.bandCenterX(
                phase: phase,
                bandIndex: index,
                panelWidth: bounds.width,
                bandWidth: bandWidth
            )
            let peak = spec.bandAlpha * pulse
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    color.withAlphaComponent(0).cgColor,
                    color.withAlphaComponent(peak).cgColor,
                    color.withAlphaComponent(peak * 0.75).cgColor,
                    color.withAlphaComponent(0).cgColor,
                ] as CFArray,
                locations: [0, 0.35, 0.6, 1]
            ) else { continue }
            // 轻微斜切（底部比顶部往前一点）——像光斜着扫过，不是呆板的竖条。
            let lean = bounds.height * 0.18 * (index == 0 ? 1 : -1)
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: center - bandWidth / 2 - lean, y: bounds.minY),
                end: CGPoint(x: center + bandWidth / 2 + lean, y: bounds.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()
    }

    /// 霓虹描边：圆角内描 1.5 pt + 同色小半径阴影（灯管边缘的发光）。
    private func drawBorder(spec: DesktopNameEffectSpec, in context: CGContext) {
        let pulse: CGFloat = spec.pulses
            ? 0.6 + 0.4 * (0.5 + 0.5 * sin(phase * 2 * .pi))
            : 1
        context.saveGState()
        context.setShadow(
            offset: .zero,
            blur: 6,
            color: spec.borderColor.withAlphaComponent(0.8 * pulse).cgColor
        )
        context.setStrokeColor(spec.borderColor.withAlphaComponent(0.75 * pulse).cgColor)
        context.setLineWidth(1.5)
        context.addPath(CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerWidth: cornerRadius - 1,
            cornerHeight: cornerRadius - 1,
            transform: nil
        ))
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - 纯几何（单测打这里）

    /// 某条光带中心的 x（**纯函数**）。相位 0..<1 推进时，中心从面板左外侧扫到右外侧；
    /// 第二条反向（相向而行的双带）。
    static func bandCenterX(
        phase: CGFloat,
        bandIndex: Int,
        panelWidth: CGFloat,
        bandWidth: CGFloat
    ) -> CGFloat {
        var wrapped = phase.truncatingRemainder(dividingBy: 1)
        if wrapped < 0 { wrapped += 1 }
        let progress = bandIndex % 2 == 0 ? wrapped : 1 - wrapped
        let travel = panelWidth + bandWidth
        return -bandWidth / 2 + progress * travel
    }
}

import AppKit
import CoreText
import QuartzCore

/// 霓虹效果的外观配方（纯值，可单测）。每个效果一族渐变颜色 + 辉光 + 流动速度。
struct DesktopNameEffectSpec: Equatable {
    /// 渐变颜色环：**首尾相接**用（渲染时自动在末尾补回第一色，因此循环无缝）。
    var gradientColors: [NSColor]
    /// 辉光颜色（在多层模糊里出现的那层光晕）。
    var glowColor: NSColor
    /// 辉光半径（pt）。面板上下内边距 20 pt，辉光别超出它 —— 否则会被圆角裁剪切掉。
    var glowRadius: CGFloat
    /// 流光循环一圈的时长（秒）。
    var flowPeriod: TimeInterval
    /// 辉光是否呼吸（赛博紫韵的「韵」：光晕缓慢脉动；流动霓虹保持常亮）。
    var glowPulses: Bool
}

extension DesktopNameEffect {
    /// 渲染配方。`.standard` 走原生 label（跟随外观的 `labelColor`），没有配方。
    var spec: DesktopNameEffectSpec? {
        switch self {
        case .standard:
            return nil
        case .neonFlow:
            // 青 → 紫 → 品红（霓虹招牌的经典三色），1.4 s 流一圈。
            return DesktopNameEffectSpec(
                gradientColors: [
                    NSColor(srgbRed: 0.13, green: 0.90, blue: 1.00, alpha: 1),
                    NSColor(srgbRed: 0.64, green: 0.36, blue: 1.00, alpha: 1),
                    NSColor(srgbRed: 1.00, green: 0.31, blue: 0.85, alpha: 1),
                ],
                glowColor: NSColor(srgbRed: 0.25, green: 0.72, blue: 1.00, alpha: 1),
                glowRadius: 16,
                flowPeriod: 1.4,
                glowPulses: false
            )
        case .cyberPurple:
            // 紫 → 深紫 → 亮紫（同色系深浅），2.6 s 慢流 + 光晕呼吸。
            return DesktopNameEffectSpec(
                gradientColors: [
                    NSColor(srgbRed: 0.69, green: 0.42, blue: 1.00, alpha: 1),
                    NSColor(srgbRed: 0.48, green: 0.30, blue: 1.00, alpha: 1),
                    NSColor(srgbRed: 0.88, green: 0.36, blue: 1.00, alpha: 1),
                ],
                glowColor: NSColor(srgbRed: 0.61, green: 0.36, blue: 1.00, alpha: 1),
                glowRadius: 18,
                flowPeriod: 2.6,
                glowPulses: true
            )
        }
    }
}

/// 霓虹效果的绘制画布：CoreText 取字形路径 → 辉光（带模糊的填充两遍）→ 渐变裁剪填充。
///
/// **为什么是 CoreGraphics 自绘 + 定时器，而不是 CoreAnimation 图层动画**：
/// 1. 项目的 `cacheDisplay` 离屏快照只走视图绘制路径，CA 图层内容（尤其带 mask 的）
///    抓不全 —— 自绘则快照与真机同一份代码，UI 验收真实；
/// 2. 展示窗口（`DesktopNameOverlayWindow`）本来就这么画（磨砂面板 + AppKit 子视图）；
/// 3. 项目既有教训是「别依赖隐式动画通道」（animator alpha 随机静默失效）——
///    这里每帧显式 `needsDisplay`，相位是普通状态，可测可查。
///
/// 动画只在**展示的那 1 秒**里跑：`startAnimating()` / `stopAnimating()` 由窗口的
/// show/hide 调用；隐藏后定时器立即失效，不烧 CPU。
@MainActor
final class DesktopNameEffectCanvas: NSView {

    /// 当前效果（`.standard` 时本视图由窗口整体隐藏，不会走到绘制）。
    var effect: DesktopNameEffect = .standard {
        didSet {
            guard effect != oldValue else { return }
            rebuildGlyphPath()
            needsDisplay = true
        }
    }

    /// 要画的文字。字号/字重与默认样式共用（`DesktopNameOverlayWindow` 的常量）。
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            rebuildGlyphPath()
            needsDisplay = true
        }
    }

    /// 面板圆角（与窗口同一常量）——辉光不许漫出面板的圆角形状。
    var cornerRadius: CGFloat = DesktopNameOverlayWindow.cornerRadius

    /// 流光相位（0..<1）。正常由计时器推进；测试/快照可显式设一个确定值。
    var phase: CGFloat = 0

    /// 是否正在播动画（展示期间 true，收起/默认档 false）。单测断言生命周期用。
    var isAnimating: Bool { timer != nil }

    private var glyphPath: CGPath?
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
        rebuildGlyphPath()
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
        // `.common` 模式：菜单/滚动等追踪期间也照常推进（展示窗口本来就不吃事件，但保持一致）。
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

    /// 从 `show()` 每次重新开始：相位归零，动画重头播（1 秒的展示看得到完整两个循环）。
    func resetPhase() {
        phase = 0
        lastTick = CACurrentMediaTime()
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard effect.spec != nil, let glyphPath,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        guard let spec = effect.spec else { return }

        // 辉光叠在磨砂面板上；圆角裁剪保证光晕不越出面板形状。
        context.saveGState()
        context.addPath(CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        ))
        context.clip()

        drawGlow(glyphPath, spec: spec, in: context)
        drawFlowingGradient(glyphPath, spec: spec, phase: phase, in: context)

        context.restoreGState()
    }

    /// 辉光：同一路径先大半径后小半径各填一遍（叠出"灯管芯 + 光晕"的层次）。
    private func drawGlow(_ path: CGPath, spec: DesktopNameEffectSpec, in context: CGContext) {
        let pulse: CGFloat = spec.glowPulses
            ? 0.80 + 0.20 * (0.5 + 0.5 * sin(phase * 2 * .pi))   // 0.80 … 1.00
            : 1
        context.saveGState()
        context.setShadow(offset: .zero, blur: spec.glowRadius, color: spec.glowColor.withAlphaComponent(0.85 * pulse).cgColor)
        context.setFillColor(spec.glowColor.withAlphaComponent(0.55 * pulse).cgColor)
        context.addPath(path)
        context.fillPath()

        context.setShadow(offset: .zero, blur: spec.glowRadius * 0.42, color: spec.glowColor.withAlphaComponent(0.95).cgColor)
        context.setFillColor(spec.glowColor.withAlphaComponent(0.9).cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    /// 流光：把渐变裁进字形，周期 = 文字墨宽；相位推进时画两段（当前周期 + 下一周期），
    /// 两段合起来永远覆盖住文字，衔接处颜色相等（首尾同色），循环无缝。
    private func drawFlowingGradient(
        _ path: CGPath,
        spec: DesktopNameEffectSpec,
        phase: CGFloat,
        in context: CGContext
    ) {
        let ink = path.boundingBoxOfPath
        guard ink.width > 0.5 else { return }
        let colors = spec.gradientColors + [spec.gradientColors[0]]
        let locations = (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) }
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors.map(\.cgColor) as CFArray,
            locations: locations
        ) else { return }

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setShadow(offset: .zero, blur: spec.glowRadius * 0.3,
                          color: spec.glowColor.withAlphaComponent(0.5).cgColor)
        for start in Self.flowSegmentStarts(phase: phase) {
            let from = CGPoint(x: ink.minX + start * ink.width, y: ink.midY)
            let to = CGPoint(x: ink.minX + (start + 1) * ink.width, y: ink.midY)
            context.drawLinearGradient(
                gradient,
                start: from,
                end: to,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()
    }

    /// 流动分段（**纯函数，单测打这里**）：返回两段渐变相对文字墨宽的起点倍数。
    ///
    /// 相位 `p ∈ [0,1)` 时返回 `[-p, 1-p]`：第一段覆盖 `[0, 1-p]`，第二段覆盖 `[1-p, 2-p]`，
    /// 并集 ⊇ `[0,1]` —— 无论相位多少，文字都被渐变完整盖住（不出现"空一段"）。
    static func flowSegmentStarts(phase: CGFloat) -> [CGFloat] {
        let wrapped = phase.truncatingRemainder(dividingBy: 1)
        let normalized = wrapped < 0 ? wrapped + 1 : wrapped
        return [-normalized, 1 - normalized]
    }

    // MARK: - 字形路径

    private func rebuildGlyphPath() {
        glyphPath = Self.glyphPath(
            text: text,
            font: .systemFont(ofSize: DesktopNameOverlayWindow.fontSize, weight: DesktopNameOverlayWindow.fontWeight),
            canvasSize: bounds.size
        )
    }

    /// 把一行文字转成 CoreText 字形路径（居中绘制在 `canvasSize` 里）。
    ///
    /// 字形路径而不是"画文字上色"：渐变需要**裁剪形状**，辉光需要**填充形状带阴影**，
    /// 两者共用同一条路径。字体度量走 `CTLineGetTypographicBounds`，与默认样式的
    /// label 居中口径一致（都用系统字体同一字号字重，视觉基线一致）。
    static func glyphPath(text: String, font: NSFont, canvasSize: NSSize) -> CGPath? {
        guard !text.isEmpty else { return nil }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let baselineY = (canvasSize.height - (ascent + descent)) / 2 + descent
        let startX = (canvasSize.width - width) / 2

        let path = CGMutablePath()
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, 0), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, 0), &positions)
            // ⚠️ 必须用 **run 自己的字体**取字形路径：中文走 CoreText 的回退字体
            // （PingFang 等），字形 ID 只在那个字体里有意义 —— 拿系统字体去查会画出
            // 完全不相干的拉丁字形（快照实测：中文被画成 "i ∇ Y ("）。踩过。
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = (attributes[kCTFontAttributeName as String] as! CTFont)
            for index in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                let transform = CGAffineTransform(
                    translationX: startX + positions[index].x,
                    y: baselineY + positions[index].y
                )
                path.addPath(glyph, transform: transform)
            }
        }
        return path.isEmpty ? nil : path
    }
}

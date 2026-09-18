// toast 外观的离线预览器：把 `UI/DesktopNameToast.swift` 里那颗胶囊在**假壁纸**上画出来，
// 输出亮色 / 深色两张 PNG，用来自检材质、圆角、描边、字号和内边距。
//
// 本机没有屏幕录制权限，`screencapture` 只能拍到壁纸（见 AGENTS.md §4），所以真机渲染
// 没法直接看图。这里改用 `cacheDisplay(in:to:)` 抓**我们自己窗口**的内容——零权限。
//
// 代价：预览用的是 `blendingMode = .withinWindow`（模糊身后同窗口里的内容），
// 真实 toast 用的是 `.behindWindow`（模糊身后屏幕上的内容）。**色调、圆角、描边、字体
// 这四件事在两种模式下一致**，模糊的具体画面不一致。所以这个工具用来定"形状和颜色"，
// 最终观感仍要在真机上切一次桌面确认。
//
// 用法： swift scripts/preview-toast.swift /tmp/toast-preview
//
// ⚠️ 这里的绘制是 DesktopNameToast.swift 的**副本**，改了那边记得同步改这里，
//    否则预览会骗人。
import AppKit

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/toast-preview"
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

// 与 DesktopNameToast.swift 保持一致的一组常量
let pillHeight: CGFloat = 32
let cornerRadius: CGFloat = 16
let horizontalPadding: CGFloat = 14
let minPillWidth: CGFloat = 76

func pillMask(width: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: width, height: pillHeight), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        return true
    }
}

final class EdgeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.12)
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }
}

/// 假壁纸：明暗、冷暖都来一块，好判断材质在难背景上够不够"站得住"。
final class CanvasView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.36, green: 0.47, blue: 0.31, alpha: 1).setFill()
        bounds.fill()
        let blocks: [(NSRect, NSColor)] = [
            (NSRect(x: 0, y: 0, width: bounds.width * 0.38, height: bounds.height * 0.55),
             NSColor(calibratedWhite: 0.92, alpha: 1)),
            (NSRect(x: bounds.width * 0.34, y: bounds.height * 0.42, width: bounds.width * 0.30, height: bounds.height * 0.58),
             NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.22, alpha: 1)),
            (NSRect(x: bounds.width * 0.62, y: 0, width: bounds.width * 0.38, height: bounds.height * 0.46),
             NSColor(calibratedRed: 0.78, green: 0.62, blue: 0.36, alpha: 1)),
        ]
        for (block, color) in blocks {
            color.setFill()
            block.fill()
        }
    }
}

func render(appearingAs name: NSAppearance.Name, fileSuffix: String) {
    let canvasSize = NSSize(width: 620, height: 260)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: canvasSize),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.appearance = NSAppearance(named: name)
    window.isOpaque = true
    window.backgroundColor = .black

    let canvas = CanvasView(frame: NSRect(origin: .zero, size: canvasSize))
    window.contentView = canvas

    let samples = ["计划 任务", "桌面 2", "一二三四五六七八九十"]
    for (index, text) in samples.enumerated() {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.backgroundColor = .clear

        let textWidth = ceil(label.intrinsicContentSize.width)
        let textHeight = ceil(label.intrinsicContentSize.height)
        let width = max(textWidth + horizontalPadding * 2, minPillWidth)

        let pill = NSVisualEffectView()
        pill.material = .popover
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.maskImage = pillMask(width: width)
        // 从顶部往下排，和真机上"贴着屏幕上沿"的位置感一致
        let y = canvasSize.height - 80 - pillHeight - CGFloat(index) * 46
        pill.frame = NSRect(x: (canvasSize.width - width) / 2, y: y, width: width, height: pillHeight)
        canvas.addSubview(pill)

        let edge = EdgeView(frame: pill.bounds)
        edge.autoresizingMask = [.width, .height]
        pill.addSubview(edge)

        label.frame = NSRect(
            x: (width - textWidth) / 2,
            y: (pillHeight - textHeight) / 2,
            width: textWidth,
            height: textHeight
        )
        pill.addSubview(label)
    }

    guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
        fputs("无法创建位图\n", stderr)
        return
    }
    canvas.cacheDisplay(in: canvas.bounds, to: rep)
    let url = URL(fileURLWithPath: "\(outputDirectory)/toast-\(fileSuffix).png")
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("无法编码 PNG\n", stderr)
        return
    }
    try? data.write(to: url)
    print(url.path)
}

render(appearingAs: .aqua, fileSuffix: "light")
render(appearingAs: .darkAqua, fileSuffix: "dark")

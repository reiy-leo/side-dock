// 菜单栏「图标 + 数字」垂直对齐的测量脚本（`MenuBarController.titleBaselineOffset` 调参/复验用）。
//
// 背景（2026-10-06 用户报告「图标和数字没有居中对齐」）：
// 数字（当前桌面序号）没有下伸部，`NSStatusBarButton` 按整段行盒（ascent+descent）垂直居中，
// 数字墨迹会整体偏高 —— 实测图标墨心 21.1px、数字 18.6px（@2x），偏 ~1.2pt。
// 修法：标题改 `attributedTitle` 加 `.baselineOffset` 下压。排版按像素量化（步进 ~0.5pt），
// 所以要扫出一整个「最优桶」而不是理论零点；当前生产值 -0.75（残余 -0.24pt < 半个像素）。
//
// 用法：
//   swift scripts/measure-menubar-baseline.swift                 # 默认扫一组候选
//   swift scripts/measure-menubar-baseline.swift -0.5 -0.75 -1.0 # 指定候选
//
// 输出：每个候选下图标/数字的 alpha 加权墨迹中心（px@2x）与差值；差值 ≈ 0 即对齐（|差| ≤ 0.5px）。
// 做法：真实 `NSStatusItem` 按钮 + `cacheDisplay` 离屏渲染 —— 零权限、不打扰真实菜单栏。
// SVG 与 `MenuBarIcon.appWindowMac`（生产默认同款）逐字相同；换测量用图标时改下面的 svg 常量。

import AppKit

let app = NSApplication.shared

let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" \
fill="none" stroke="#000000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\
<rect width="20" height="16" x="2" y="4" rx="2"/><path d="M6 8h.01"/><path d="M10 8h.01"/><path d="M14 8h.01"/></svg>
"""

func makeIcon(size: CGFloat) -> NSImage {
    let img = NSImage(data: svg.data(using: .utf8)!)!
    img.size = NSSize(width: size, height: size)
    img.isTemplate = true
    return img
}

func weightedCenter(_ rep: NSBitmapImageRep, cols: Range<Int>) -> Double {
    let h = rep.pixelsHigh, w = rep.pixelsWide
    var num = 0.0, den = 0.0
    for y in 0..<h {
        for x in cols.clamped(to: 0..<w) {
            let a = Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            num += a * Double(y)
            den += a
        }
    }
    return den > 0 ? num / den : .nan
}

/// 渲染一个候选（offset 为 nil = 现状的 `button.title`），返回（图标墨心, 数字墨心, 数字墨色）。
func measure(offset: CGFloat?, appearance: NSAppearance.Name = .darkAqua) -> (Double, Double, NSColor?)? {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer {
        item.isVisible = false
        NSStatusBar.system.removeStatusItem(item)
    }
    guard let button = item.button else { return nil }
    button.appearance = NSAppearance(named: appearance)
    button.imagePosition = .imageLeading
    button.image = makeIcon(size: 18)
    let font = button.font ?? NSFont.systemFont(ofSize: 13)
    if let off = offset {
        button.attributedTitle = NSAttributedString(string: " 1", attributes: [
            .font: font, .baselineOffset: off,
        ])
    } else {
        button.title = " 1"
    }
    button.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))

    guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return nil }
    button.cacheDisplay(in: button.bounds, to: rep)
    let w = rep.pixelsWide, h = rep.pixelsHigh

    // 内容列分组：图标、数字各成一组
    var colInk = [Bool](repeating: false, count: w)
    for x in 0..<w {
        for y in 0..<h where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
            colInk[x] = true
            break
        }
    }
    var groups: [Range<Int>] = []
    var start: Int? = nil
    for x in 0..<w {
        if colInk[x], start == nil { start = x }
        if !colInk[x], let s = start { groups.append(s..<x); start = nil }
    }
    if let s = start { groups.append(s..<w) }
    var merged: [Range<Int>] = []
    for g in groups {
        if let last = merged.last, g.lowerBound - last.upperBound < 6 {
            merged[merged.count - 1] = last.lowerBound..<g.upperBound
        } else {
            merged.append(g)
        }
    }
    guard merged.count >= 2 else { return nil }
    let iconCenter = weightedCenter(rep, cols: merged[0])
    let digitCenter = weightedCenter(rep, cols: merged[merged.count - 1])

    // 数字墨色（采样最右组里的不透明像素）——顺带验证亮/暗配色适配
    var color: NSColor?
    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
    for y in 0..<h {
        for x in merged[merged.count - 1] {
            if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 {
                r += Double(c.redComponent)
                g += Double(c.greenComponent)
                b += Double(c.blueComponent)
                n += 1
            }
        }
    }
    if n > 0 { color = NSColor(red: r/n, green: g/n, blue: b/n, alpha: 1) }
    return (iconCenter, digitCenter, color)
}

let args = CommandLine.arguments.dropFirst().compactMap { Double($0) }
let candidates: [Double?] = args.isEmpty ? [nil, -0.4, -0.5, -0.55, -0.75, -0.9, -1.0, -1.1] : [nil] + args.map { $0 }

print("菜单栏「图标 + 数字」对齐测量（@2x；差 = 数字墨心 - 图标墨心，越接近 0 越对齐）")
var best: (Double?, Double)? = nil
for candidate in candidates {
    guard let (iconC, digitC, color) = measure(offset: candidate.map { CGFloat($0) }) else {
        print("  \(candidate.map { String(format: "%+.2f", $0) } ?? "nil(现状)"): 测量失败")
        continue
    }
    let diff = digitC - iconC
    let label = candidate.map { String(format: "%+.2f", $0) } ?? "nil(现状)"
    let colorDesc = color.map { String(format: "数字色(%.2f,%.2f,%.2f)", $0.redComponent, $0.greenComponent, $0.blueComponent) } ?? ""
    let flag = abs(diff) <= 0.5 ? " ←最优桶" : ""
    print(String(format: "  offset %@: 图标墨心 %.2f  数字墨心 %.2f  差 %+.2fpx@2x = %+.2fpt  %@%@",
                 label, iconC, digitC, diff, diff / 2, colorDesc, flag))
    if best == nil || abs(diff) < abs(best!.1) { best = (candidate, diff) }
}
if let best {
    print(String(format: "最佳候选：offset %@（残余 %+.2fpx@2x）；生产值见 MenuBarController.titleBaselineOffset",
                 best.0.map { String(format: "%+.2f", $0) } ?? "nil", best.1))
}

// 从一张方形 PNG 生成 macOS 应用图标（.icns），按苹果图标网格对齐。
//
// 用法：
//   swift scripts/make-app-icon.swift Support/AppIcon-source.png Support/MultiDock.icns [导出 master.png]
//
// 对齐基准（2026-10-06 实测系统图标 Notes/Music/Weather 的 1024 渲染）：
//   - 画布 1024×1024，美术体（alpha>127）824×824 居中，四周留 100；
//   - 系统投影：剪影高斯模糊 σ≈10px、透明度 ≈0.29、向下偏移 ≈10px（黑）；
//     侧缘外 alpha≈37、底缘正下方 ≈64，向外约 12px 降到 alpha<8 —— 逐点吻合。
// 源图要求：透明背景、单一方形美术体（alpha 通道定义轮廓）。
// 本脚本清掉 alpha<8 的噪声、按「最大边 = 824」等比缩放置中、烘焙同款投影，
// 再批量降采样出 .iconset 并调 iconutil 打 icns。

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    fatalError("用法：swift scripts/make-app-icon.swift <source.png> <out.icns> [debug-master.png]")
}
let srcURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let debugURL: URL? = args.count >= 4 ? URL(fileURLWithPath: args[3]) : nil

// MARK: 常量（与系统图标对齐的网格）

let canvas = 1024
let bodySize = 824            // 美术体目标边长（长边）
let shadowBlur: Double = 10   // σ
let shadowAlpha: Double = 0.29
let shadowDrop: Double = 10   // 向下偏移
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: 读源图到 RGBA8（premultipliedLast）

guard let cgSrc = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let srcImage = CGImageSourceCreateImageAtIndex(cgSrc, 0, nil) else {
    fatalError("读不了源图：\(srcURL.path)")
}
let sw = srcImage.width, sh = srcImage.height
guard let srcCtx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8,
                             bytesPerRow: sw * 4, space: sRGB,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("建不了位图上下文")
}
// 全幅绘制时缓冲区首行 = 图像顶行；下面的 bbox 均按「行号自顶向下」计算。
srcCtx.draw(srcImage, in: CGRect(x: 0, y: 0, width: sw, height: sh))
let buf = srcCtx.data!.bindMemory(to: UInt8.self, capacity: sw * sh * 4)

// 清噪声：alpha<8 整像素归零（实测源图边外散布 1–3/255 的噪声；保留 137+ 的真 AA 边）
var cleaned = 0
for i in 0..<(sw * sh) {
    if buf[i * 4 + 3] < 8 {
        buf[i * 4] = 0; buf[i * 4 + 1] = 0; buf[i * 4 + 2] = 0; buf[i * 4 + 3] = 0
        cleaned += 1
    }
}
guard let cleanedImage = srcCtx.makeImage() else { fatalError("生成清理后的位图失败") }

// 美术体 bbox（alpha>127）：行号自顶向下
var minX = sw, maxX = -1, minY = sh, maxY = -1
for y in 0..<sh {
    for x in 0..<sw where buf[(y * sw + x) * 4 + 3] > 127 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
let bodyW = maxX - minX + 1, bodyH = maxY - minY + 1
guard bodyW > 0, bodyH > 0 else { fatalError("源图里找不到美术体（alpha 全透明？）") }

// 裁到美术体（外扩 2px 保住 alpha 126 以下的 AA 外沿，裁切矩形是左上原点坐标系）
let pad = 2
let cropX = max(0, minX - pad), cropY = max(0, minY - pad)
let cropW = min(sw, maxX + pad + 1) - cropX, cropH = min(sh, maxY + pad + 1) - cropY
guard let bodyImage = cleanedImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) else {
    fatalError("裁切美术体失败")
}

// MARK: 摆放（美术体长边缩到 824，居中；宽高比保留）

let scale = Double(bodySize) / Double(cropW > cropH ? cropW : cropH)
let drawW = Double(cropW) * scale, drawH = Double(cropH) * scale
// CG 坐标（原点左下，y 向上）：居中摆放
let drawRect = CGRect(x: (Double(canvas) - drawW) / 2, y: (Double(canvas) - drawH) / 2,
                      width: drawW, height: drawH)

print("源图 \(sw)×\(sh)，美术体 \(bodyW)×\(bodyH) @ (\(minX),\(minY))px（自顶向下）")
print("清理噪声像素 \(cleaned) 个；裁切 \(cropW)×\(cropH)；缩放比 \(String(format: "%.4f", scale))，落位 \(String(format: "%.1f", drawW))×\(String(format: "%.1f", drawH))")

// MARK: 投影（黑剪影 → 高斯模糊 → 透明度 → 下移）

guard let shadowCtx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                                bytesPerRow: canvas * 4, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("建不了投影上下文")
}
// 剪影（黑版美术体，用作投影源）。
// ⚠️ 混合模式只在源绘制覆盖的区域内生效：先前写法「整幅填黑 → destinationIn 叠身体」
// 在 drawRect 之外根本没参与混合，留在画布上仍是黑底（整幅变不透明，踩过）。
// 正确顺序：先画身体（其余透明），再用全幅黑填充以 .sourceIn 收敛（填充覆盖全画布）。
shadowCtx.draw(bodyImage, in: drawRect)
shadowCtx.setBlendMode(.sourceIn)
shadowCtx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
shadowCtx.fill(CGRect(x: 0, y: 0, width: Double(canvas), height: Double(canvas)))
guard let silhouette = shadowCtx.makeImage() else { fatalError("生成剪影失败") }

let ciCtx = CIContext(options: [.workingColorSpace: sRGB])
let blur = CIFilter.gaussianBlur()
blur.inputImage = CIImage(cgImage: silhouette).clampedToExtent()
blur.radius = Float(shadowBlur)
guard let shadowCI = blur.outputImage,
      let shadowImage = ciCtx.createCGImage(shadowCI, from: CGRect(x: 0, y: 0, width: canvas, height: canvas),
                                            format: .RGBA8, colorSpace: sRGB) else {
    fatalError("渲染投影失败")
}

// MARK: 合成 master 1024

guard let outCtx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                             bytesPerRow: canvas * 4, space: sRGB,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("建不了输出上下文")
}
// 投影的透明度靠 CGContext 全局 alpha 收敛（draw 时按 0.29 合成）
outCtx.setAlpha(CGFloat(shadowAlpha))
outCtx.draw(shadowImage, in: CGRect(x: 0, y: -shadowDrop, width: Double(canvas), height: Double(canvas)))
outCtx.setAlpha(1)
outCtx.draw(bodyImage, in: drawRect)
guard let master = outCtx.makeImage() else { fatalError("合成 master 失败") }

if let debugURL = debugURL {
    try! writePNG(master, to: debugURL)
    print("debug master -> \(debugURL.path)")
}

// MARK: 导出 .iconset 并打 icns

let iconsetURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("multidock-appicon-\(ProcessInfo.processInfo.processIdentifier).iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in variants {
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: px * 4, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("建不了 \(name) 上下文")
    }
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
    guard let img = ctx.makeImage() else { fatalError("渲染 \(name) 失败") }
    try! writePNG(img, to: iconsetURL.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
try! FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outURL.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil 失败（退出码 \(iconutil.terminationStatus)）") }
try? FileManager.default.removeItem(at: iconsetURL)
print("已生成 \(outURL.path)")

// MARK: 工具

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-app-icon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-app-icon", code: 2)
    }
}

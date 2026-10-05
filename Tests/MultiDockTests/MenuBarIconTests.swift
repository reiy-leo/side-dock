import AppKit
import XCTest
@testable import MultiDock

/// 菜单栏图标的渲染保障（2026-10-06 用户规格：Lucide 五选一）。
///
/// 这组测试防的是**静默失败**：SVG 路径写错一个字符、或系统某天不再原生解码 SVG 时，
/// `NSImage(data:)` 会返回 nil 或空图——菜单栏图标变空白，而没有测试就会一路静默。
@MainActor
final class MenuBarIconTests: XCTestCase {

    func testAllIconsRenderToNonEmptyTemplateImages() throws {
        for icon in MenuBarIcon.allCases {
            let image = try XCTUnwrap(icon.image(size: 18), "\(icon.lucideName) 应能解码成图")
            XCTAssertTrue(image.isTemplate, "\(icon.lucideName) 必须是模板图（系统按菜单栏亮暗着色）")
            XCTAssertEqual(image.size.width, 18, accuracy: 0.5)
            XCTAssertGreaterThan(try inkedPixelCount(of: image, size: 18), 8,
                                 "\(icon.lucideName) 渲染后应有实际笔画（不是空图）")
        }
    }

    func testEachIconLooksDifferentFromTheOthers() throws {
        // 五个图标必须真的不同：渲染成同尺寸位图后两两比对，任何两张都不该逐像素等同。
        var bitmaps: [MenuBarIcon: Data] = [:]
        for icon in MenuBarIcon.allCases {
            let image = try XCTUnwrap(icon.image(size: 24))
            bitmaps[icon] = try XCTUnwrap(alphaData(of: image, size: 24))
        }
        for (first, data) in bitmaps {
            for (second, other) in bitmaps where first != second {
                XCTAssertNotEqual(data, other, "\(first.lucideName) 与 \(second.lucideName) 渲染结果不应相同")
            }
        }
    }

    func testImagesAreCachedPerSize() throws {
        let a = try XCTUnwrap(MenuBarIcon.sparkles.image(size: 18))
        let b = try XCTUnwrap(MenuBarIcon.sparkles.image(size: 18))
        XCTAssertTrue(a === b, "同尺寸重复取图应命中缓存（避免每次重绘都重新解码 SVG）")

        let large = try XCTUnwrap(MenuBarIcon.sparkles.image(size: 40))
        XCTAssertFalse(a === large, "不同尺寸是不同缓存项")
    }

    func testDecodesFromRawValueAndFallsBackToDefault() throws {
        // config.json 里存的是 rawValue（kebab 语义名），加字段不许改已存值的含义。
        XCTAssertEqual(MenuBarIcon(rawValue: "treeDeciduous"), .treeDeciduous)
        XCTAssertEqual(MenuBarIcon(rawValue: "shell"), .shell)
        XCTAssertNil(MenuBarIcon(rawValue: "circle"))
    }

    // MARK: - 工具

    /// 把模板图画进白底，统计有笔画的像素数。
    private func inkedPixelCount(of image: NSImage, size: CGFloat) throws -> Int {
        let rep = try XCTUnwrap(pixels(of: image, size: size))
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.2 { count += 1 }
            }
        }
        return count
    }

    /// 把模板图渲染成 alpha 位图（模板图只用 alpha，通道值即形状）。
    private func alphaData(of image: NSImage, size: CGFloat) throws -> Data? {
        try XCTUnwrap(pixels(of: image, size: size)).representation(using: .png, properties: [:])
    }

    private func pixels(of image: NSImage, size: CGFloat) throws -> NSBitmapImageRep? {
        let scale: CGFloat = 2
        let pixelSize = Int(size * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

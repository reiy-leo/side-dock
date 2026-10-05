import AppKit
import SwiftUI

/// 桌面缩略图：桌面下拉列表里每行左侧的小图。
///
/// **能拿到什么就 honestly 用什么**（零权限）：
/// 1. `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` 里
///    `Spaces → <spaceUUID> → Desktop → Content → Choices[].Files[].relative` 指向的壁纸文件；
/// 2. 该空间没设独立壁纸时回落 `SystemDefault` / `AllSpacesAndDisplays` 的壁纸
///    （本机各空间共用系统壁纸时，所有空间都显示同一张 —— 这是事实，不是缺陷）；
/// 3. 连壁纸文件都读不到时退化为按 UUID 派生的稳定渐变色块（同空间永远同色，用于区分）。
///
/// 真·Mission Control 式窗口缩略图做不到：其他空间的窗口内容系统根本不渲染
/// （屏幕录制权限也换不来），见 `docs/spikes.md` 实验 24 的同类结论。
enum SpaceThumbnailProvider {
    private static let storeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    /// 只在主线程访问（SwiftUI 视图渲染路径）；`cacheLock` 兜底满足严格并发检查。
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: NSImage] = [:]

    /// `"\(displayUUID)#\(spaceUUID)"` 里的空间段（缩略图按空间取壁纸，与显示器无关）。
    static func spaceUUID(from spaceID: String) -> String {
        guard let hashIndex = spaceID.firstIndex(of: "#") else { return spaceID }
        return String(spaceID[spaceID.index(after: hashIndex)...])
    }

    /// 该空间的壁纸图（带缓存）。拿不到返回 nil，调用方画色块。
    static func wallpaper(for spaceID: String) -> NSImage? {
        let key = spaceUUID(from: spaceID)
        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard let image = loadWallpaper(spaceUUID: key) else { return nil }
        cacheLock.lock()
        cache[key] = image
        cacheLock.unlock()
        return image
    }

    private static func loadWallpaper(spaceUUID: String) -> NSImage? {
        guard let data = try? Data(contentsOf: storeURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let root = plist as? [String: Any]
        else { return nil }

        for candidate in wallpaperFileURLs(root: root, spaceUUID: spaceUUID) {
            if let image = NSImage(contentsOf: candidate) {
                return image
            }
        }
        return nil
    }

    /// 壁纸文件的候选顺序：本空间 → 本显示器 → 系统默认。
    private static func wallpaperFileURLs(root: [String: Any], spaceUUID: String) -> [URL] {
        var candidates: [URL] = []
        func collect(from section: Any?) {
            guard let section else { return }
            // Desktop / Idle / ScreenSaver 等键里只有 Desktop 是壁纸上桌面的那份。
            if let desktop = (section as? [String: Any])?["Desktop"] as? [String: Any],
                let content = desktop["Content"] as? [String: Any],
                let choices = content["Choices"] as? [[String: Any]]
            {
                for choice in choices {
                    guard let files = choice["Files"] as? [[String: Any]] else { continue }
                    for file in files {
                        guard let relative = file["relative"] as? String,
                            let url = URL(string: relative),
                            url.isFileURL,
                            FileManager.default.fileExists(atPath: url.path)
                        else { continue }
                        candidates.append(url)
                    }
                }
            }
        }
        if let spaces = root["Spaces"] as? [String: Any] {
            collect(from: spaces[spaceUUID])
        }
        if let displays = root["Displays"] as? [String: Any] {
            for (_, value) in displays { collect(from: value) }
        }
        collect(from: root["SystemDefault"])
        collect(from: root["AllSpacesAndDisplays"])
        return candidates
    }

    /// 色块回落用的稳定色相（同一空间永远同色）。
    static func hue(for spaceID: String) -> Double {
        let key = spaceUUID(from: spaceID)
        var hash: UInt64 = 1_469_598_103_934_665_6037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Double(hash % 360) / 360.0
    }
}

/// 下拉列表与列表行里用的缩略图：壁纸 + 圆角，拿不到壁纸画渐变色块。
struct SpaceThumbnailView: View {
    let spaceID: String
    var width: CGFloat = 30
    var height: CGFloat = 19

    var body: some View {
        if let image = SpaceThumbnailProvider.wallpaper(for: spaceID) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        } else {
            LinearGradient(
                colors: [
                    Color(hue: SpaceThumbnailProvider.hue(for: spaceID), saturation: 0.45, brightness: 0.75),
                    Color(hue: SpaceThumbnailProvider.hue(for: spaceID).truncatingRemainder(dividingBy: 1)
                        + 0.08, saturation: 0.55, brightness: 0.55),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }
}

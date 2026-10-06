import XCTest
@testable import MultiDock

/// 双语（中 / 英）支持的守卫。2026-10-06 用户规格：「支持中文、英文」。
///
/// 这里钉三件事：
/// 1. **语言解析**——哪些环境取中文、哪些取英文（含未声明本地化的回落）；
/// 2. **取词**——`L()` 两语言各取各的，且默认（测试环境）是中文；
/// 3. **真实 bundle 的接线**——打包后的 Info.plist 必须声明 `CFBundleLocalizations`，
///    否则 `preferredLocalizations` 永远是 en，中文系统也会显示英文。
///    这一条用**真的读 Support/Info.plist** 来守（离开发的机器最近的事实）。
final class L10nTests: XCTestCase {

    // MARK: - 解析

    func testDeclaredBundleFollowsPreferredLocalization() {
        let declared = ["en", "zh-Hans"]
        XCTAssertEqual(
            L10n.resolvedLanguage(declaredLocalizations: declared, preferredLocalizations: ["zh-Hans"]),
            .zh
        )
        XCTAssertEqual(
            L10n.resolvedLanguage(declaredLocalizations: declared, preferredLocalizations: ["en"]),
            .en
        )
    }

    /// 系统语言是第三语言（日语/法语）时：`Info.plist` 的开发区域是 en，
    /// 系统给的第一偏好就是 en —— 应当落到英文，而不是保留中文。
    func testThirdLanguageFallsBackToEnglish() {
        XCTAssertEqual(
            L10n.resolvedLanguage(declaredLocalizations: ["en", "zh-Hans"], preferredLocalizations: ["en"]),
            .en
        )
        XCTAssertEqual(
            L10n.resolvedLanguage(declaredLocalizations: ["en", "zh-Hans"], preferredLocalizations: ["ja"]),
            .en,
            "非 zh 的第一偏好 = 英文（枚举里没有 ja，系统把 en 排在最前）"
        )
    }

    /// **没有本地化元数据的环境（`swift test`、直接跑二进制）必须回中文** ——
    /// 全部既有测试断言与文档 grep 判据都基于中文，不能被运行环境偷改。
    func testUndeclaredBundleStaysChinese() {
        XCTAssertEqual(
            L10n.resolvedLanguage(declaredLocalizations: [], preferredLocalizations: ["en"]),
            .zh,
            "没声明本地化的包（测试 bundle）仍走中文"
        )
        XCTAssertEqual(
            L10n.resolvedLanguage(declaredLocalizations: [], preferredLocalizations: []),
            .zh
        )
    }

    func testChineseRegionVariantsAllResolveToChinese() {
        for preferred in [["zh-Hans-CN"], ["zh-Hans"], ["zh-Hant-TW"], ["zh"]] {
            XCTAssertEqual(
                L10n.resolvedLanguage(declaredLocalizations: ["en", "zh-Hans"], preferredLocalizations: preferred),
                .zh,
                "\(preferred) 应判为中文"
            )
        }
    }

    // MARK: - 取词

    func testTextPicksByLanguage() {
        XCTAssertEqual(L10n.text("中文", "English", language: .zh), "中文")
        XCTAssertEqual(L10n.text("中文", "English", language: .en), "English")
    }

    /// 当前语言默认是中文（测试进程不调 `applySystemLanguage`）。
    func testDefaultLanguageIsChineseInTests() {
        XCTAssertEqual(L10n.language, .zh)
        XCTAssertEqual(L("通用", "General"), "通用")
    }

    func testSwitchingLanguageChangesText() {
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en
        XCTAssertEqual(L("通用", "General"), "General")
        XCTAssertEqual(DesktopSpace(displayUUID: "d", spaceUUID: "s", id64: 1, type: 0, ordinal: 2).displayName,
                       "Desktop 2")
    }

    // MARK: - 源码守卫：不许出现「只有中文」的用户可见串

    /// 扫 `Sources/MultiDock/**`：每个含中文字符的字符串字面量都必须落在某个 `L(…)` 调用
    /// 的参数区间里 —— 否则它在英文界面上会原样冒出中文（用户明确要「支持中文、英文」）。
    ///
    /// 为什么是**区间**而不是行：`L()` 允许跨行、允许把插值里的三元表达式写成
    /// `\(active ? "开启" : "关闭")` 这种嵌套字面量（外层的 `L` 负责选语言，内层只是素材）。
    /// 注释里的中文（占证大多数）不算 —— 扫描器先把注释整段跳过。
    func testEveryChineseStringLiteralSitsInsideL() throws {
        let sourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MultiDockTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Sources/MultiDock")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: sourcesURL.path))
        var violations: [String] = []
        var scannedFiles = 0

        for case let relative as String in enumerator {
            guard relative.hasSuffix(".swift") else { continue }
            scannedFiles += 1
            let url = sourcesURL.appendingPathComponent(relative)
            let text = try String(contentsOf: url, encoding: .utf8)
            for violation in Self.chineseLiteralsOutsideL(in: text) {
                violations.append("\(relative):\(violation.line) “\(violation.snippet)”")
            }
        }

        XCTAssertGreaterThan(scannedFiles, 20, "扫描面太小，可能是路径算错")
        XCTAssertTrue(violations.isEmpty, """
            这些中文字符串没有包在 L("中文", "English") 里，英文界面下会漏出中文：
            \(violations.joined(separator: "\n"))
            """)
    }

    /// 扫描结果里的一条违规：行号 + 片段（供失败信息用）。
    private struct Violation {
        var line: Int
        var snippet: String
    }

    /// 极简 Swift 词法扫描：标注注释 / 字符串区间，找出 `L(` 的括号跨度，
    /// 再检查每个含中文的字符串字面量是否落在某个跨度内。
    private static func chineseLiteralsOutsideL(in text: String) -> [Violation] {
        let chars = Array(text)
        let count = chars.count
        var inComment = [Bool](repeating: false, count: count)
        var inString = [Bool](repeating: false, count: count)
        var stringSpans: [(start: Int, end: Int)] = []

        var i = 0
        while i < count {
            let c = chars[i]
            // 行注释
            if c == "/", i + 1 < count, chars[i + 1] == "/" {
                var j = i
                while j < count, chars[j] != "\n" { j += 1 }
                for k in i..<j { inComment[k] = true }
                i = j
                continue
            }
            // 块注释
            if c == "/", i + 1 < count, chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                let end = min(count, j + 2)
                for k in i..<end { inComment[k] = true }
                i = end
                continue
            }
            // 原始字符串 #"…"# / ##"…"##
            if c == "#" {
                var hashes = 0
                var k = i
                while k < count, chars[k] == "#" { hashes += 1; k += 1 }
                if k < count, chars[k] == "\"" {
                    var j = k + 1
                    while j < count {
                        if chars[j] == "\\" { j += 2; continue }
                        if chars[j] == "\"" {
                            var m = j + 1
                            var h = 0
                            while m < count, h < hashes, chars[m] == "#" { h += 1; m += 1 }
                            if h == hashes { j = m; break }
                        }
                        j += 1
                    }
                    let end = min(count, j)
                    for k2 in i..<end { inString[k2] = true }
                    stringSpans.append((i, end))
                    i = end
                    continue
                }
            }
            // 普通字符串（含三引号多行）
            if c == "\"" {
                var j = i + 1
                if i + 2 < count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                    j = i + 3
                    while j + 2 < count, !(chars[j] == "\"" && chars[j + 1] == "\"" && chars[j + 2] == "\"") { j += 1 }
                    j = min(count, j + 3)
                } else {
                    while j < count {
                        if chars[j] == "\\" { j += 2; continue }
                        if chars[j] == "\"" { j += 1; break }
                        j += 1
                    }
                }
                let end = min(count, j)
                for k in i..<end { inString[k] = true }
                stringSpans.append((i, end))
                i = end
                continue
            }
            i += 1
        }

        // `L(` 的括号跨度（跳过字符串与注释里的括号）。
        func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var lSpans: [(start: Int, end: Int)] = []
        var index = 0
        while index + 1 < count {
            if !inComment[index], !inString[index], chars[index] == "L", chars[index + 1] == "(",
               index == 0 || !isIdentifier(chars[index - 1]) {
                var depth = 0
                var j = index + 1
                while j < count {
                    if inComment[j] || inString[j] { j += 1; continue }
                    if chars[j] == "(" { depth += 1 }
                    else if chars[j] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    j += 1
                }
                lSpans.append((index, min(count, j + 1)))
                index = j + 1
                continue
            }
            index += 1
        }

        let cjk: (Character) -> Bool = { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
        var violations: [Violation] = []
        for span in stringSpans {
            let content = String(chars[span.start..<span.end])
            guard content.contains(where: cjk) else { continue }
            let insideL = lSpans.contains { span.start >= $0.start && span.start < $0.end }
            guard !insideL else { continue }
            let line = chars[0..<span.start].filter { $0 == "\n" }.count + 1
            let snippet = content.count > 60 ? String(content.prefix(60)) + "…" : content
            violations.append(Violation(line: line, snippet: snippet))
        }
        return violations
    }

    // MARK: - 打包接线（真读 Support/Info.plist）

    /// `CFBundleLocalizations` 必须同时声明 en 与 zh-Hans —— 没有它，
    /// `Bundle.main.preferredLocalizations` 会恒为 en（实验：探针 App 实测），
    /// 中文系统下界面会整片变英文。这条守卫防止有人「顺手清理」掉它。
    func testInfoPlistDeclaresBothLocalizations() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MultiDockTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Support/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let localizations = try XCTUnwrap(plist["CFBundleLocalizations"] as? [String])
        XCTAssertTrue(localizations.contains("en"), "缺 en：\(localizations)")
        XCTAssertTrue(localizations.contains("zh-Hans"), "缺 zh-Hans：\(localizations)")
        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "en",
                       "开发区域必须是 en —— 非中英文系统才落到英文（第三语言回落靠它）")
    }
}

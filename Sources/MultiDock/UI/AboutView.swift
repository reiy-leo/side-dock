import AppKit
import SwiftUI

/// 「关于」页的静态信息（名称 / 版本 / 仓库）。
///
/// 仓库地址取 git remote（`reiy-leo/side-dock`）；更新检查走 GitHub Releases API
/// （零权限，普通网络请求）。版本号来自 `Support/Info.plist` 的
/// `CFBundleShortVersionString`（打包脚本原样拷贝）——发版时记得改它。
enum AppAbout {
    static let appName = "MultiDock"
    static let repoURL = URL(string: "https://github.com/reiy-leo/side-dock")!
    static let releasesAPIURL = URL(string: "https://api.github.com/repos/reiy-leo/side-dock/releases/latest")!

    /// 展示用版本：「0.1.0 (1)」；读不到（未打包直接跑二进制）时如实说「开发版」。
    static var displayVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return L("开发版（未打包）", "Dev build (unpackaged)")
        }
    }

    /// 参与比较的版本号（语义化版本口径；读不到按 "0.0.0"——永远不比仓库里的发布新）。
    static var comparableVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 真实的发布读取器（注入给 `AppState.configureUpdateChecking`）。
    /// 测试不配置它 —— 关于页就停在「未检查」，不会碰到网络。
    static func standardReleaseFetcher() -> @Sendable () async -> UpdateCheckOutcome {
        { await Self.fetchLatestRelease() }
    }

    private static func fetchLatestRelease() async -> UpdateCheckOutcome {
        var request = URLRequest(url: releasesAPIURL)
        request.timeoutInterval = 8
        // GitHub API 要求带 UA，否则 403。
        request.setValue("MultiDock-UpdateCheck", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(L("响应不是 HTTP", "Response is not HTTP"))
            }
            switch http.statusCode {
            case 200:
                guard let parsed = UpdateCheck.parseRelease(data: data) else {
                    return .failure(L("发布数据格式不对", "Malformed release data"))
                }
                return parsed
            case 404:
                return .noRelease
            case 403:
                return .failure(L("GitHub 限流（403），稍后再试", "GitHub rate limit (403); try again later"))
            default:
                return .failure("HTTP \(http.statusCode)")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

/// 更新检查的单次结果（`releases/latest` 的解析 + 失败原因）。
enum UpdateCheckOutcome: Equatable, Sendable {
    /// 仓库存在但还没有任何发布。
    case noRelease
    case release(tag: String, url: URL?)
    case failure(String)
}

/// 版本比较与发布 JSON 解析（纯函数，可脱离网络单测）。
enum UpdateCheck {

    /// 解析 `releases/latest` 的响应体：取 `tag_name`（去掉开头的 v）与 `html_url`。
    static func parseRelease(data: Data) -> UpdateCheckOutcome? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any],
            let tag = json["tag_name"] as? String
        else { return nil }
        let trimmed = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let url = (json["html_url"] as? String).flatMap(URL.init(string:))
        return .release(tag: trimmed, url: url)
    }

    /// `latest` 是否比 `current` 新。按点分数字逐段比较；缺段按 0；
    /// 非数字段（预发布后缀如 `-beta.1`）截掉主段参与比较，无法比较时保守返回 false。
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let latestParts = numericParts(of: latest)
        let currentParts = numericParts(of: current)
        let width = max(latestParts.count, currentParts.count)
        for index in 0..<width {
            let lhs = index < latestParts.count ? latestParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func numericParts(of version: String) -> [Int] {
        // "1.2.3-beta.1" → 主段 "1.2.3"；"v1.2" → "1.2"
        let main = version
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? version
        let cleaned = main.hasPrefix("v") ? String(main.dropFirst()) : main
        return cleaned.split(separator: ".").map { Int($0) ?? 0 }
    }
}

/// 「关于」选项卡：图标、名称、版本、GitHub 仓库、更新检查。
struct AboutTab: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppAbout.appName).font(.title2.weight(.semibold))
                        Text(L("版本 \(AppAbout.displayVersion)", "Version \(AppAbout.displayVersion)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(L("macOS 多桌面（Space）Dock 管理工具。原生 Dock 全桌面一致，每个桌面的差异由 Dock 栏呈现。", "A macOS multi-desktop (Space) Dock manager. The native Dock is the same on every desktop; per-desktop differences come from Dock bars."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }

            Section(L("更新", "Updates")) {
                HStack(spacing: 8) {
                    Button(L("检查更新", "Check for Updates")) { state.checkForUpdates() }
                        .disabled(state.updateCheckStatus == .checking)
                    Spacer()
                    updateStatusView
                }
                Text(L("检查走 GitHub Releases（api.github.com，零权限）；本机没有发布版时会如实说明。", "Checks go through GitHub Releases (api.github.com, zero permissions); if there's no release yet it says so."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L("源代码", "Source Code")) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    Link(AppAbout.repoURL.absoluteString, destination: AppAbout.repoURL)
                    Spacer()
                    Button(L("打开仓库", "Open Repository")) { NSWorkspace.shared.open(AppAbout.repoURL) }
                }
                Text(L("本地运行、个人自用：不签名、不上架。问题与想法请到仓库提 issue。", "Run locally, for personal use: unsigned, not on the App Store. File issues and ideas on the repo."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { state.checkForUpdatesOncePerLaunch() }
    }

    private var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch state.updateCheckStatus {
        case .idle:
            Text(L("未检查", "Not checked")).font(.caption).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("正在检查…", "Checking…")).font(.caption).foregroundStyle(.secondary)
            }
        case .upToDate(let latest):
            Label(L("已是最新（仓库最新 \(latest)）", "Up to date (latest \(latest))"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .available(let latest, let url):
            HStack(spacing: 8) {
                Label(L("发现新版本 \(latest)", "New version \(latest) available"), systemImage: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if let url {
                    Button(L("打开发布页", "Open Release Page")) { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                }
            }
        case .failed(let reason):
            Label(L("检查失败：\(reason)", "Check failed: \(reason)"), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

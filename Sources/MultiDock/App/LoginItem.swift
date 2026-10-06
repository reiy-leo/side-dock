import Foundation
import ServiceManagement

/// 「登录时自动启动」。
///
/// 主路径是 `SMAppService.mainApp`（macOS 13+ 的公开接口，用户级，**不需要任何系统权限**）。
/// 本项目的 App 是 ad-hoc 签名、不上架的，`register()` 在某些位置/环境下会失败 ——
/// 那种情况退回写一个用户级 LaunchAgent（`~/Library/LaunchAgents/local.multidock.plist`）。
/// 这条对策写在 `docs/PLAN.md` §5（"未签名登录项注册失败 → SMAppService 失败即退回 LaunchAgent"）。
///
/// ⚠️ **`swift test` 里没有 `.app` 包**，`SMAppService.mainApp` 拿不到有效的 bundle。
/// 所以 `isAvailable` 先看有没有 bundle：不可用时 UI 直接显示原因，不做一个按了没反应的开关。
enum LoginItem {

    static let agentLabel = "local.multidock.loginitem"

    static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(agentLabel).plist")
    }

    /// 当前是否在真正的 `.app` 包里跑。`swift test` / `swift run` 都不是。
    static var isRunningFromBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isAvailable: Bool { isRunningFromBundle }

    /// 是否已开启。**以系统状态为准，不存进 `config.json`** ——
    /// 登录项是系统拥有的状态，本地再存一份迟早会和系统不一致。
    static var isEnabled: Bool {
        guard isAvailable else { return false }
        if SMAppService.mainApp.status == .enabled { return true }
        // SMAppService 没成，但我们写过 LaunchAgent，那也算开着。
        return FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    static func statusDescription() -> String {
        guard isAvailable else {
            return L("不可用（当前不在 .app 包里运行）", "Unavailable (not running from an .app bundle)")
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            return L("已开启（SMAppService）", "On (SMAppService)")
        case .notRegistered:
            return FileManager.default.fileExists(atPath: agentPlistURL.path)
                ? L("已开启（LaunchAgent 退回方案）", "On (LaunchAgent fallback)")
                : L("未开启", "Off")
        case .requiresApproval:
            return L("已注册，等你在「系统设置 → 通用 → 登录项」里批准",
                     "Registered — waiting for approval in System Settings → General → Login Items")
        case .notFound:
            return L("系统找不到该登录项（App 可能被移动过，先关再开一次）",
                     "Login item not found (the app may have moved — toggle it off and on again)")
        @unknown default:
            return L("未知状态", "Unknown state")
        }
    }

    /// 开启。返回实际用了哪条路（给日志，别让用户猜）。
    static func enable() throws -> String {
        guard isAvailable else { throw LoginItemError.notInAppBundle }
        do {
            try SMAppService.mainApp.register()
            return "SMAppService"
        } catch {
            // 退回 LaunchAgent。这里把 SMAppService 的报错也带上，便于排查。
            try writeAgentPlist()
            return L("LaunchAgent 退回方案（SMAppService 报错：\(error.localizedDescription)）",
                     "LaunchAgent fallback (SMAppService error: \(error.localizedDescription))")
        }
    }

    static func disable() throws -> String {
        var done: [String] = []
        if isAvailable, SMAppService.mainApp.status != .notRegistered {
            // 注销失败不算致命：可能只是本来就没注册上。继续清 LaunchAgent。
            try? SMAppService.mainApp.unregister()
            done.append(L("SMAppService 已注销", "SMAppService unregistered"))
        }
        if FileManager.default.fileExists(atPath: agentPlistURL.path) {
            try FileManager.default.removeItem(at: agentPlistURL)
            done.append(L("LaunchAgent plist 已删除", "LaunchAgent plist removed"))
        }
        return done.isEmpty ? L("本来就没开", "wasn't on") : done.joined(separator: L("；", "; "))
    }

    /// LaunchAgent plist 的内容。
    ///
    /// 抽成纯函数是为了能单测 —— 真去写用户的 `~/Library/LaunchAgents` 是测试不该干的事。
    ///
    /// 刻意**不设 `KeepAlive`**：这是登录启动项，不是守护进程。App 被用户退出后不该被反复拉起。
    static func agentPlist(executablePath: String) -> [String: PlistValue] {
        [
            "Label": .string(agentLabel),
            "ProgramArguments": .array([.string(executablePath)]),
            "RunAtLoad": .bool(true),
            "ProcessType": .string("Interactive"),
        ]
    }

    static func writeAgentPlist() throws {
        let directory = agentPlistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = agentPlist(executablePath: Bundle.main.bundlePath).mapValues(\.anyValue)
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        try data.write(to: agentPlistURL, options: .atomic)
    }
}

enum LoginItemError: LocalizedError, Equatable {
    case notInAppBundle

    var errorDescription: String? {
        switch self {
        case .notInAppBundle:
            return L("当前不在 .app 包里运行，无法注册登录项",
                     "Not running from an .app bundle; can't register a login item")
        }
    }
}

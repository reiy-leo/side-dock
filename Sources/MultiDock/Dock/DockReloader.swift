import AppKit
import Darwin
import Foundation

/// Dock 进程操作的能力抽象。
///
/// 抽出来是为了让「重启判定与兜底顺序」能脱离真实 Dock 单测 —— 与 `SpaceProviding` 隔离私有 API 同理。
protocol DockProcessControlling: Sendable {
    /// 当前 Dock 进程 PID；Dock 不在时返回 nil。
    func dockPID() -> pid_t?
    /// 给 Dock 发信号。返回是否投递成功（Dock 已死时返回 false，不算异常）。
    @discardableResult func signal(_ pid: pid_t, _ sig: Int32) -> Bool
    /// `launchctl kickstart -k` 兜底。返回是否执行成功。
    @discardableResult func kickstart() -> Bool
}

/// 真实实现。
struct RealDockProcessControl: DockProcessControlling {

    static let dockBundleIdentifier = "com.apple.dock"
    /// `launchctl` 的服务名。Dock 由这个 LaunchAgent 拉起。
    static let dockServiceName = "com.apple.Dock.agent"

    func dockPID() -> pid_t? {
        // 首选：LaunchServices 查询。在 .app 里最可靠。
        if let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.dockBundleIdentifier)
            .first?
            .processIdentifier {
            return pid
        }
        // 兜底：非 .app 进程（例如 `swift test` 的 xctest runner）里上一条可能查不到，
        // 但 Dock 一定在跑。用 pgrep 按进程名找，避免误判成"Dock 不在"。
        return Self.pgrepDockPID()
    }

    private static func pgrepDockPID() -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "Dock"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline).first
            return text.flatMap { pid_t($0) }
        } catch {
            return nil
        }
    }

    @discardableResult
    func signal(_ pid: pid_t, _ sig: Int32) -> Bool {
        Darwin.kill(pid, sig) == 0
    }

    @discardableResult
    func kickstart() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "kickstart", "-k",
            "gui/\(getuid())/\(Self.dockServiceName)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// 一次重载的结果。耗时与所用手段都要能被记录（计划 §3.4 第 6 条）。
struct ReloadOutcome: Sendable, Equatable {

    enum Method: String, Sendable {
        /// 主路径：约 101 ms 不可用。
        case sighup = "SIGHUP"
        /// 兜底：Dock 会先做约 255 ms 退出清理，总计约 367–395 ms。
        case sigterm = "SIGTERM"
        /// launchd 拉回。
        case kickstart = "kickstart"
        case failed = "失败"
    }

    var method: Method
    var oldPID: pid_t?
    var newPID: pid_t?
    var elapsed: TimeInterval

    var succeeded: Bool { newPID != nil }

    var description: String {
        guard succeeded else {
            return String(format: "%@ 失败（%.0f ms，旧 PID %@）", method.rawValue, elapsed * 1000,
                          oldPID.map(String.init) ?? "无")
        }
        return String(format: "%@ 成功：PID %@ → %@，用时 %.0f ms",
                      method.rawValue, oldPID.map(String.init) ?? "?", String(newPID!), elapsed * 1000)
    }
}

/// 让写入的 Dock 偏好生效。
///
/// **Dock 没有热重载**（P0 实测：post 任何通知都无效），只能让 Dock 进程重启。
/// 主路径 `SIGHUP`（约 101 ms 不可用），兜底 `SIGTERM` + `launchctl kickstart`。
///
/// ⚠️ **绝不用 AppleEvent 优雅退出**：`/System/Library/LaunchAgents/com.apple.Dock.plist` 是
/// `KeepAlive = {AfterInitialDemand:1, SuccessfulExit:0}`，退出码 0 时 launchd **不会**把 Dock 拉回来，
/// 用户会当场失去 Dock。只走信号路径。
@MainActor
final class DockReloader {

    private let process: any DockProcessControlling
    private let timeout: Duration
    private let pollInterval: Duration
    /// 发完 SIGTERM 后、动 `kickstart` 之前给的宽限。等的是「launchd 自己把 Dock 拉回来」，
    /// 免得正常机器上也白等一次 `kickstart`。
    private let fallbackGrace: Duration

    init(
        process: any DockProcessControlling = RealDockProcessControl(),
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(15),
        fallbackGrace: Duration = .milliseconds(500)
    ) {
        self.process = process
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.fallbackGrace = fallbackGrace
    }

    /// 重启 Dock。
    ///
    /// - Parameter strategy: `.auto` 先 SIGHUP；`.sigterm` 直接走 SIGTERM。
    ///   两条路失败都落到 `kickstart`。
    func reload(strategy: ReloadStrategy = .auto) async -> ReloadOutcome {
        let started = Date()
        guard let oldPID = process.dockPID() else {
            return ReloadOutcome(method: .failed, oldPID: nil, newPID: nil,
                                 elapsed: Date().timeIntervalSince(started))
        }

        if strategy == .auto {
            process.signal(oldPID, SIGHUP)
            if let newPID = await waitForRestart(after: oldPID) {
                return outcome(.sighup, oldPID: oldPID, newPID: newPID, started: started)
            }
        } else {
            process.signal(oldPID, SIGTERM)
            if let newPID = await waitForRestart(after: oldPID) {
                return outcome(.sigterm, oldPID: oldPID, newPID: newPID, started: started)
            }
        }

        // 兜底：确保 Dock 以信号致死，再用 launchd 拉回。
        let dyingPID = process.dockPID() ?? oldPID
        process.signal(dyingPID, SIGTERM)
        // 给它一点时间死透；这段时间内 launchd 可能自己就把它拉回来了。
        if let newPID = await waitForRestart(after: dyingPID, timeout: fallbackGrace) {
            return outcome(.sigterm, oldPID: oldPID, newPID: newPID, started: started)
        }
        process.kickstart()
        if let newPID = await waitForRestart(after: dyingPID) {
            return outcome(.kickstart, oldPID: oldPID, newPID: newPID, started: started)
        }

        return ReloadOutcome(method: .failed, oldPID: oldPID, newPID: nil,
                             elapsed: Date().timeIntervalSince(started))
    }

    /// 轮询等待一个**不同于** `oldPID` 的 Dock 进程出现。
    private func waitForRestart(after oldPID: pid_t, timeout: Duration? = nil) async -> pid_t? {
        let deadline = ContinuousClock.now + (timeout ?? self.timeout)
        while ContinuousClock.now < deadline {
            if let pid = process.dockPID(), pid != oldPID { return pid }
            try? await Task.sleep(for: pollInterval)
        }
        return nil
    }

    private func outcome(_ method: ReloadOutcome.Method, oldPID: pid_t, newPID: pid_t, started: Date) -> ReloadOutcome {
        ReloadOutcome(method: method, oldPID: oldPID, newPID: newPID, elapsed: Date().timeIntervalSince(started))
    }
}

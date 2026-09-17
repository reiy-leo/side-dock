import Foundation
import Observation
import os

/// 一条调试日志。调试面板可见（计划 §3.4 第 6 条要求记录耗时与重载方式）。
struct LogEntry: Identifiable, Sendable {
    enum Level: String, Sendable {
        case info, warning, error
        var symbol: String {
            switch self {
            case .info: return "•"
            case .warning: return "▲"
            case .error: return "■"
            }
        }
    }

    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String

    init(level: Level = .info, _ message: String) {
        self.timestamp = Date()
        self.level = level
        self.message = message
    }
}

/// 全局状态。UI 只读它，改状态都走这里的方法。
///
/// 空间相关的值**不复制**，直接转发给 `observer` —— 否则两份状态会不同步。
/// `observer` 本身是 `@Observable`，SwiftUI 读 `appState.desktops` 时会穿过转发拿到
/// `SpaceObserver.desktops` 的依赖，更新照常生效。
@MainActor
@Observable
final class AppState {

    // MARK: - 空间（转发给 observer）

    var desktops: [DesktopSpace] { observer.desktops }
    var activeSpace: DesktopSpace? { observer.activeSpace }
    var desktopListGeneration: Int { observer.desktopListGeneration }

    // MARK: - 配置

    private(set) var settings = AppSettings()
    private(set) var bindings: [DesktopBinding] = []

    // MARK: - 运行状况

    private(set) var spaceProviderAvailable = false
    private(set) var spaceProviderWarning: String?
    /// 启动时发现的残留会话标记（上次被强杀/崩溃）。
    private(set) var interruptedSession: BaselineStore.SessionMarker?
    private(set) var baselineCapturedThisLaunch = false
    private(set) var log: [LogEntry] = []

    let observer: SpaceObserver
    let switcher: SpaceSwitcher

    private let configStore = ConfigStore()
    private let baselineStore = BaselineStore()
    private let maxLogEntries = 400

    init() {
        let provider = SpaceProviderFactory.make()
        spaceProviderAvailable = provider.isAvailable
        spaceProviderWarning = provider.unavailableReason
        observer = SpaceObserver(provider: provider)
        switcher = SpaceSwitcher(observer: observer)
        observer.onActiveSpaceChanged = { [weak self] space in
            guard let self else { return }
            if let space {
                self.append(.info, "活动桌面 → \(space.displayName)（\(space.spaceUUID.prefix(8))…）")
            } else {
                self.append(.info, "活动空间不是用户桌面（可能是全屏 App），不触发切换")
            }
        }
    }

    // MARK: - 生命周期

    func start() {
        append(.info, "MultiDock 启动")
        append(.info, "系统 \(ProcessInfo.processInfo.operatingSystemVersionString)")

        if spaceProviderAvailable {
            append(.info, "SkyLight 私有 API 加载成功")
        } else {
            append(.error, spaceProviderWarning ?? "SkyLight 不可用")
        }

        runStartupSelfCheck()
        loadConfiguration()

        observer.start()
        append(.info, "桌面观察已启动（300 ms 轮询 + 通知）")
        append(.info, "识别到 \(observer.desktops.count) 个用户桌面")
        for space in observer.desktops {
            append(.info, "  · \(space.displayName) uuid=\(space.spaceUUID) id64=\(space.id64)")
        }
        if let active = observer.activeSpace {
            append(.info, "当前桌面：\(active.displayName) / id64=\(active.id64)")
        }
    }

    func stop() {
        observer.stop()
        append(.info, "桌面观察已停止")
    }

    /// 启动自检：残留会话标记 + 基准快照（计划 §3.9 的固定顺序）。
    private func runStartupSelfCheck() {
        if let stale = baselineStore.detectInterruptedSession() {
            interruptedSession = stale
            if stale.impliesDirtyDock {
                append(.warning, "上次未正常退出（PID \(stale.pid)），Dock 可能未还原 —— 自动还原将在 P4 提供")
            } else {
                append(.info, "发现上次未正常退出的残留标记，但上次未改动过 Dock，无需还原")
            }
            baselineStore.clearSessionMarker()
        }

        do {
            baselineCapturedThisLaunch = try baselineStore.captureBaselineIfNeeded()
            if baselineCapturedThisLaunch {
                append(.info, "已把当前 Dock 存为基准快照（首次运行，此后不再覆盖）")
            } else {
                append(.info, "基准快照已存在，沿用不改")
            }
        } catch {
            append(.error, "基准快照写入失败：\(error.localizedDescription)")
        }
    }

    private func loadConfiguration() {
        let payload = configStore.load()
        settings = payload.settings
        bindings = payload.bindings
        append(.info, "配置已载入：\(bindings.count) 条桌面绑定")
    }

    func persistConfiguration() {
        do {
            try configStore.save(.init(bindings: bindings, settings: settings))
        } catch {
            append(.error, "配置保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 动作

    func switchToNextDesktop() {
        guard spaceProviderAvailable else {
            append(.error, "桌面切换不可用：\(spaceProviderWarning ?? "未知原因")")
            return
        }
        guard let target = switcher.step(.next) else {
            append(.warning, "没有可切换的下一个桌面（当前显示器只有 1 个桌面，或尚未识别到活动桌面）")
            return
        }
        append(.info, "切换到 \(target.displayName)（id64=\(target.id64)）")
    }

    func switchTo(_ space: DesktopSpace) {
        guard spaceProviderAvailable else {
            append(.error, "桌面切换不可用：\(spaceProviderWarning ?? "未知原因")")
            return
        }
        guard switcher.switchTo(space) != nil else {
            append(.warning, "切换到 \(space.displayName) 失败")
            return
        }
        append(.info, "切换到 \(space.displayName)（id64=\(space.id64)）")
    }

    func refreshDesktops() {
        observer.refreshNow()
        append(.info, "手动刷新桌面列表：\(desktops.count) 个用户桌面")
    }

    func updateSettings(_ transform: (inout AppSettings) -> Void) {
        transform(&settings)
        persistConfiguration()
    }

    // MARK: - 日志

    /// 日志同时进内存（调试面板）、系统统一日志、以及落盘文件。
    /// 统一日志的意义：`log show --predicate 'subsystem == "local.multidock"' --info` 可事后核对行为。
    /// 落盘文件的意义：受限环境下读不到统一日志时，仍能核对（也是用户反馈问题时最方便的附件）。
    private let logger = Logger(subsystem: "local.multidock", category: "app")
    private let fileLog = FileLogSink()

    func append(_ level: LogEntry.Level, _ message: String) {
        let entry = LogEntry(level: level, message)
        log.append(entry)
        if log.count > maxLogEntries {
            log.removeFirst(log.count - maxLogEntries)
        }
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        fileLog.append(entry)
    }

    var baselinePath: String { baselineStore.baselineURL.path }
    var configPath: String { AppPaths.configFile.path }
    var logPath: String { fileLog.fileURL.path }
}

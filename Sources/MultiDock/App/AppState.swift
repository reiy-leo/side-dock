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
    /// 切换桌面的中上部提示。由 `AppDelegate` 注入 —— `AppState` 不碰 AppKit 窗口。
    private(set) var toastPresenter: ToastPresenter?

    /// Dock 应用流水线（读全量域 → 只覆盖白名单键 → 原子写 → 重启 Dock → 校验）。
    let dockController: DockController
    /// 最近一次应用结果的一句话摘要，设置页直接显示。
    private(set) var lastApplySummary = "尚未应用过任何 Dock 设置"
    /// 本次运行是否真的改过真实 Dock。无痕原则靠它判断退出时要不要还原。
    private(set) var hasAppliedDockConfig = false
    /// 当前 Dock 域里**不存在**、因而写不进去的外观键。UI 据此禁用对应控件，不做假开关。
    private(set) var unavailableAppearanceKeys: Set<String> = []
    /// 当前 Dock 域里存在、可安全写入的白名单键。**缓存**，避免每次渲染都读一遍偏好域。
    private(set) var availableWhitelistedKeys: Set<String> = []

    /// 由 `AppDelegate` 接到 `LifecycleController.noteDockApplied`，把"改过 Dock"记进会话标记。
    var onDockApplied: (@MainActor (String) -> Void)?

    private let configStore: ConfigStore
    private let baselineStore: BaselineStore
    private let maxLogEntries = 400

    /// 依赖全部可注入：`DockController` 与两个 Store 都能换成测试替身，
    /// 这样「立即应用 / 还原」这条路径不必真的动用户的 Dock 也能测。
    init(
        dockController: DockController = DockController(),
        configStore: ConfigStore = ConfigStore(),
        baselineStore: BaselineStore = BaselineStore()
    ) {
        let provider = SpaceProviderFactory.make()
        spaceProviderAvailable = provider.isAvailable
        spaceProviderWarning = provider.unavailableReason
        observer = SpaceObserver(provider: provider)
        switcher = SpaceSwitcher(observer: observer)
        self.dockController = dockController
        self.configStore = configStore
        self.baselineStore = baselineStore
        observer.onActiveSpaceChanged = { [weak self] space in
            guard let self else { return }
            if let space {
                self.append(.info, "活动桌面 → \(self.displayName(for: space))（\(space.spaceUUID.prefix(8))…）")
            } else {
                self.append(.info, "活动空间不是用户桌面（可能是全屏 App），不触发切换")
            }
            self.toastPresenter?.handleActiveSpaceChanged(space)
        }
        // 必须在最后：闭包要捕获 `self`，而所有存储属性得先初始化完。
        dockController.onOutcome = { [weak self] outcome in self?.handleDockOutcome(outcome) }
    }

    func attachToastPresenter(_ presenter: ToastPresenter) {
        toastPresenter = presenter
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
            append(.info, "  · \(displayName(for: space)) uuid=\(space.spaceUUID) id64=\(space.id64)")
        }
        if let active = observer.activeSpace {
            append(.info, "当前桌面：\(displayName(for: active)) / id64=\(active.id64)")
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
        // 归一化放在这里而不是 ConfigStore：手改 config.json 塞进超长名或空绑定，
        // 也要在进入内存模型前就被收拾干净（计划 §3.10 的「两层防线」）。
        let normalized = DesktopNaming.normalizedBindings(payload.bindings)
        if normalized.count != payload.bindings.count {
            append(.warning, "配置里有 \(payload.bindings.count - normalized.count) 条空绑定（既无名字也无 Dock 设置），已清理")
        }
        bindings = normalized
        append(.info, "配置已载入：\(bindings.count) 条桌面绑定")
        refreshDockCapabilities()
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
        append(.info, "切换到 \(displayName(for: target))（id64=\(target.id64)）")
    }

    func switchTo(_ space: DesktopSpace) {
        guard spaceProviderAvailable else {
            append(.error, "桌面切换不可用：\(spaceProviderWarning ?? "未知原因")")
            return
        }
        guard switcher.switchTo(space) != nil else {
            append(.warning, "切换到 \(displayName(for: space)) 失败")
            return
        }
        append(.info, "切换到 \(displayName(for: space))（id64=\(space.id64)）")
    }

    func refreshDesktops() {
        observer.refreshNow()
        append(.info, "手动刷新桌面列表：\(desktops.count) 个用户桌面")
    }

    func updateSettings(_ transform: (inout AppSettings) -> Void) {
        transform(&settings)
        persistConfiguration()
    }

    // MARK: - Dock 应用（计划 §3.4 / §3.5）

    /// 重新探测「当前 Dock 域里有哪些白名单键」。决定 UI 上哪些外观控件可用。
    func refreshDockCapabilities() {
        let present = dockController.presentWhitelistedKeys()
        availableWhitelistedKeys = present
        unavailableAppearanceKeys = settings.defaultDock.appearance.unavailableKeys(in: present)
        if !unavailableAppearanceKeys.isEmpty {
            append(.warning, "本机 Dock 域里没有这些键，对应设置将不可用："
                + unavailableAppearanceKeys.sorted().joined(separator: "、"))
        }
    }

    /// 编辑器专用：只改内存，不落盘。
    ///
    /// 拖拽排序的每一次 `dropEntered` 都会走到这里；如果顺手落盘，拖过一个图标就写一次
    /// `config.json`。落盘统一由 `dockConfigEdited` 在一次编辑结束时做一次。
    func setDefaultDock(_ config: DockConfig) {
        settings.defaultDock = config
    }

    /// 「立即应用」：把默认 Dock 推到真实 Dock。
    func applyDefaultDock() {
        applyDock(settings.defaultDock, reason: "手动应用默认 Dock")
    }

    /// 应用一套配置。连击会被合并，只对最终落点执行一次。
    func applyDock(_ config: DockConfig, reason: String) {
        guard !config.pinnedApps.isEmpty else {
            append(.warning, "默认 Dock 还是空的，先点「从当前 Dock 抓取」再应用 —— 否则会把 Dock 清空")
            return
        }
        append(.info, "准备应用 Dock（\(reason)）：\(config.pinnedApps.count) 个图标，重载方式 \(settings.reloadStrategy.displayName)")
        dockController.request(config, reason: reason, strategy: settings.reloadStrategy)
    }

    /// 把此刻真实的 Dock 读成配置（编辑器里的「从当前 Dock 抓取」）。
    ///
    /// 走 `dockController` 而不是直接读静态的 `DockPreferences`，否则会绕过注入点 ——
    /// 测试里就会读到真实系统的偏好域。
    func captureLiveDockConfig() -> DockConfig? {
        guard let live = dockController.captureLiveConfig() else {
            append(.error, "读不到 com.apple.dock，无法抓取")
            return nil
        }
        return live
    }

    func captureCurrentDockAsDefault() {
        guard let live = captureLiveDockConfig() else { return }
        updateSettings { $0.defaultDock = live }
        refreshDockCapabilities()
        append(.info, "已从当前 Dock 抓取：\(live.pinnedApps.count) 个图标、\(live.otherItems.count) 个其他项")
    }

    /// 编辑器每次改动后调用。受「编辑后立即应用」开关控制。
    func dockConfigEdited(reason: String) {
        persistConfiguration()
        append(.info, "默认 Dock 已修改：\(reason)")
        guard settings.autoApplyOnEdit else {
            append(.info, "「编辑后立即应用」已关闭，改动只存在本地配置里")
            return
        }
        applyDock(settings.defaultDock, reason: reason)
    }

    /// 「立即还原到原始 Dock」。退出还原（P4）也走同一条路径。
    func restoreToBaselineNow() {
        Task { await self.restoreToBaseline() }
    }

    @discardableResult
    func restoreToBaseline() async -> DockController.Outcome? {
        let baseline = baselineStore.readBaseline()
        guard !baseline.isEmpty else {
            append(.error, "找不到基准快照（\(baselineStore.baselineURL.path)），无法还原")
            return nil
        }
        let config = DockConfig.read(from: baseline)

        // 已经与基准一致就什么都不做 —— 省掉一次没必要的 Dock 重启（退出时会明显拖慢）。
        if liveMatchesBaseline(baseline) {
            append(.info, "当前 Dock 已与基准一致，跳过还原（不重启 Dock）")
            return DockController.Outcome(
                result: .skippedIdentical, reason: "还原到原始 Dock", reload: nil, writtenKeys: 0,
                verifyAttempts: 0, elapsed: 0, skippedKeys: [], fingerprint: config.fingerprint
            )
        }

        append(.info, "开始还原到原始 Dock：\(config.pinnedApps.count) 个图标")
        let outcome = await dockController.apply(
            config,
            reason: "还原到原始 Dock",
            strategy: settings.reloadStrategy,
            force: true
        )
        return outcome
    }

    /// 当前真实 Dock 的白名单键是否已经等于基准。
    ///
    /// 只比白名单键：`mod-count` / `recent-apps` 是 Dock 自己的计数器，
    /// 每次重启都会变，拿它们比会永远判定"不一致"。
    private func liveMatchesBaseline(_ baseline: [String: PlistValue]) -> Bool {
        let live = dockController.readDomain()
        guard !live.isEmpty else { return false }
        let keys = DockPreferences.whitelistedKeys
        return live.filter { keys.contains($0.key) } == baseline.filter { keys.contains($0.key) }
    }

    /// 「把当前 Dock 设为新基准」。
    func resetBaselineToCurrent() {
        do {
            try baselineStore.resetBaselineToCurrent()
            append(.info, "已把当前 Dock 设为新基准")
        } catch {
            append(.error, "更新基准失败：\(error.localizedDescription)")
        }
    }

    private func handleDockOutcome(_ outcome: DockController.Outcome) {
        lastApplySummary = outcome.summary
        switch outcome.result {
        case .applied:
            append(.info, "Dock 应用成功：\(outcome.summary)")
            if !outcome.skippedKeys.isEmpty {
                append(.warning, "这些键本机 Dock 域里没有，已跳过："
                    + outcome.skippedKeys.sorted().joined(separator: "、"))
            }
            hasAppliedDockConfig = true
            onDockApplied?(outcome.fingerprint)
            refreshDockCapabilities()
        case .skippedIdentical:
            append(.info, "Dock 内容与当前一致，未写入也未重启（\(outcome.reason)）")
        case .failed:
            append(.error, "Dock 应用失败：\(outcome.summary)")
        }
    }

    // MARK: - 桌面命名（计划 §3.10）

    /// 桌面的显示名：自定义名优先，否则「桌面 N」。**所有 UI 都走这里**，别再直接用 `space.displayName`。
    func displayName(for space: DesktopSpace) -> String {
        DesktopNaming.displayName(for: space, bindings: bindings)
    }

    func customName(for space: DesktopSpace) -> String? {
        DesktopNaming.customName(for: space, bindings: bindings)
    }

    /// 改名。归一化后与原值相同则完全不写盘（输入框每次提交都会调它）。
    func setCustomName(_ raw: String, for space: DesktopSpace) {
        let previous = displayName(for: space)
        let updated = DesktopNaming.updatingBindings(bindings, name: raw, for: space)
        guard updated != bindings else { return }
        bindings = updated
        persistConfiguration()
        append(.info, "桌面命名：\(previous) → 「\(displayName(for: space))」")
    }

    // MARK: - toast

    /// 调试面板的「测试 toast」：手动弹一次当前桌面名，用来在不开设置页的情况下核对窗口行为。
    func showTestToast() {
        guard settings.showToastOnDesktopSwitch else {
            append(.warning, "toast 已在设置里关闭，未显示")
            return
        }
        guard let toastPresenter else {
            append(.warning, "toast 未接入（AppDelegate 没注入 presenter）")
            return
        }
        let space = activeSpace
        let text = space.map { displayName(for: $0) } ?? "测试提示"
        toastPresenter.show(text: text, displayUUID: space?.displayUUID)
        append(.info, "手动触发 toast：\(text)")
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

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

/// Dock 编辑的目标：通用页的**默认 Dock**，或某个桌面的**独立 Dock**。
///
/// 抽出来是为了让编辑器只有一套读写口径 —— 图标条与外观控件都按 `(目标)` 取配置、
/// 写配置、提交改动。否则通用页与桌面页会各写一遍「只改内存 / 一次落盘」的逻辑，迟早不一致。
enum DockEditTarget: Hashable {
    case defaultDock
    case desktop(DesktopSpace)
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
    /// 已接显示器的 `displayUUID → 名字`。屏幕插拔时刷新（计划 §3.7：桌面列表要带**显示器名**）。
    ///
    /// 缓存而不是每次渲染现取：`NSScreen` + `CGDisplayCreateUUIDFromDisplayID` 是 AppKit 调用，
    /// 放在列表渲染路径上会每帧走一遍。刷新点是启动 + `didChangeScreenParametersNotification`。
    private(set) var displayScreens: [ScreenNaming.Screen] = []
    /// Dock 被外部弄死、且自动拉回一直失败时的警告文案（`nil` = 正常）。
    ///
    /// 计划 §3.9 第 3 条要求"仍异常则提示从备份恢复" —— 只记日志等于用户面对一个
    /// 没有 Dock 的桌面却不知道为什么。设置窗口顶部的横幅据此显示。
    private(set) var dockFailureWarning: String?
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

    /// 监视真实 Dock 上的人工改动（P3）。`autoCaptureUserEdits` 关闭时不创建。
    private(set) var dockWatcher: DockWatcher?
    /// 自动回存的旧配置暂存，供「撤销上一次自动回存」。只在内存里，见 `DockEditHistory`。
    private var editHistory = DockEditHistory()

    // MARK: - 无痕与自愈（P4）

    /// 启动自检发现「上次没走完还原」时置上，由 `scheduleSelfHealIfNeeded` 消费。
    private(set) var pendingSelfHeal: BaselineStore.SessionMarker?
    /// 本次运行是否真的自动还原过。设置页与调试面板显示这句话。
    private(set) var selfHealSummary: String?
    /// Dock 存活监视。Dock 被外部弄死（`kill -9`、崩溃）时拉回来。
    private(set) var dockPresenceMonitor: DockPresenceMonitor?
    /// `mru-spaces` 的真实值。nil = 本机没有这个键（UI 显示为不支持，不做假开关）。
    private(set) var mruSpaces: Bool?
    /// 历史备份列表，最新在前（设置页「备份与还原」）。
    private(set) var backups: [BaselineStore.BackupEntry] = []
    /// 登录启动的当前状态描述。
    private(set) var loginItemStatus = "未检查"

    /// 本次启动是否欠着一次自愈还原。`LifecycleController` 靠它把"还欠一次还原"写进新会话标记。
    var hasPendingSelfHeal: Bool { pendingSelfHeal?.impliesDirtyDock == true }

    /// 由 `AppDelegate` 接到 `LifecycleController.noteDockApplied`，把"改过 Dock"记进会话标记。
    var onDockApplied: (@MainActor (String) -> Void)?

    private let configStore: ConfigStore
    private let baselineStore: BaselineStore
    /// 测试注入的存活监视器。为 nil 时 `startDockPresenceMonitor` 自己造一个真的。
    private let injectedPresenceMonitor: DockPresenceMonitor?
    private let maxLogEntries = 400
    /// 自愈任务。留着句柄有两个用处：保证只发起一次；退出前可以等它跑完。
    private var selfHealTask: Task<Void, Never>?

    /// 依赖全部可注入：`DockController`、两个 Store、以及空间提供者都能换成测试替身，
    /// 这样「立即应用 / 还原 / 切桌面预应用」这几条路径不必真的动用户的 Dock 也能测。
    ///
    /// `provider` 也要可注入，否则「预应用先于切换」只能靠真实桌面来验，没法写成断言。
    init(
        dockController: DockController = DockController(),
        configStore: ConfigStore = ConfigStore(),
        baselineStore: BaselineStore = BaselineStore(),
        provider: (any SpaceProviding)? = nil,
        presenceMonitor: DockPresenceMonitor? = nil
    ) {
        let provider = provider ?? SpaceProviderFactory.make()
        spaceProviderAvailable = provider.isAvailable
        spaceProviderWarning = provider.unavailableReason
        observer = SpaceObserver(provider: provider)
        switcher = SpaceSwitcher(observer: observer)
        self.dockController = dockController
        self.configStore = configStore
        self.baselineStore = baselineStore
        self.injectedPresenceMonitor = presenceMonitor
        observer.onActiveSpaceChanged = { [weak self] space in
            guard let self else { return }
            if let space {
                self.append(.info, "活动桌面 → \(self.displayName(for: space))（\(space.spaceUUID.prefix(8))…）")
            } else {
                self.append(.info, "活动空间不是用户桌面（可能是全屏 App），不触发切换")
            }
            self.toastPresenter?.handleActiveSpaceChanged(space)
            // 桌面切换后把该桌面的 Dock 推下去（内容相同会被指纹短路，不会白重启 Dock）。
            if let space { self.applyConfigForDesktop(space, reason: "切到 \(self.displayName(for: space))") }
        }
        // 必须在最后：闭包要捕获 `self`，而所有存储属性得先初始化完。
        dockController.onOutcome = { [weak self] outcome in self?.handleDockOutcome(outcome) }
    }

    // MARK: - Dock 配置与桌面的绑定（计划 §3.2 / §3.7）

    /// 某个桌面的绑定（可能不存在）。
    func binding(for space: DesktopSpace) -> DesktopBinding? {
        bindings.first { $0.id == space.id }
    }

    /// 某个桌面实际生效的 Dock：有自己的 override 就用它，否则用默认 Dock。
    func effectiveConfig(for space: DesktopSpace) -> DockConfig {
        binding(for: space)?.override ?? settings.defaultDock
    }

    func hasOverride(for space: DesktopSpace) -> Bool {
        binding(for: space)?.override != nil
    }

    /// 设置/取消某个桌面的独立 Dock。`nil` = 沿用默认。
    func setOverride(_ config: DockConfig?, for space: DesktopSpace, reason: String) {
        let updated = DesktopNaming.updatingBindings(bindings, override: config, for: space)
        guard updated != bindings else { return }
        bindings = updated
        persistConfiguration()
        append(.info, "\(displayName(for: space))：\(reason)")
        if settings.autoApplyOnEdit { applyConfigForDesktop(space, reason: reason) }
    }

    /// 把默认 Dock 复制一份给某个桌面作为独立配置。
    func copyDefaultToOverride(for space: DesktopSpace) {
        setOverride(settings.defaultDock, for: space, reason: "复制默认 Dock 到本桌面")
    }

    // MARK: - 孤儿绑定（计划 §5「桌面被系统删除/重排后映射错位」）

    /// 绑定还在，但对应的桌面已经不在了（桌面被删、或被系统重排换了 UUID）。
    ///
    /// ⚠️ **绝不自动清理**：外接显示器被拔掉时，那台显示器上的桌面会整体消失，
    /// 它们的绑定看起来就是"孤儿"，但插回去还要用 —— 自动删会把用户的配置抹掉。
    /// 所以只在这里列出来，由用户显式点按钮清。
    var orphanedBindings: [DesktopBinding] {
        let live = Set(desktops.map(\.id))
        return bindings.filter { !live.contains($0.id) }
    }

    /// 清掉孤儿绑定，返回清掉的数量。
    @discardableResult
    func pruneOrphanedBindings() -> Int {
        let orphans = orphanedBindings
        guard !orphans.isEmpty else { return 0 }
        let dead = Set(orphans.map(\.id))
        bindings.removeAll { dead.contains($0.id) }
        persistConfiguration()
        append(.warning, "已清理 \(orphans.count) 条无效桌面绑定（对应桌面已不存在）")
        return orphans.count
    }

    /// 编辑器专用：只改内存，不落盘（理由同 `setDefaultDock`）。
    func setOverrideInMemory(_ config: DockConfig, for space: DesktopSpace) {
        bindings = DesktopNaming.updatingBindings(bindings, override: config, for: space)
    }

    /// 一次编辑结束：落盘一次，并按开关决定是否立即应用。
    func overrideEdited(for space: DesktopSpace, reason: String) {
        persistConfiguration()
        append(.info, "\(displayName(for: space)) 的 Dock 已修改：\(reason)")
        guard settings.autoApplyOnEdit else {
            append(.info, "「编辑后立即应用」已关闭，改动只存在本地配置里")
            return
        }
        applyConfigForDesktop(space, reason: reason)
    }

    /// 应用某个桌面实际生效的 Dock。
    func applyConfigForDesktop(_ space: DesktopSpace, reason: String) {
        let config = effectiveConfig(for: space)
        guard !config.pinnedApps.isEmpty else {
            append(.warning, "\(displayName(for: space)) 的 Dock 是空的，跳过应用 —— 先给它配一套图标")
            return
        }
        dockController.request(config, reason: reason, strategy: settings.reloadStrategy)
    }

    /// 用户手动改了真实 Dock → 回存到当前桌面的配置（计划 §3.8）。
    func handleUserDockEdit(_ config: DockConfig) {
        guard settings.autoCaptureUserEdits else {
            append(.info, "「识别手动改动并回存」已关闭，忽略这次改动")
            return
        }
        // 回存期间不能让 watcher 把这次写入又当成新的用户改动。
        dockWatcher?.stop()
        defer {
            dockWatcher?.acknowledge(dockController.appliedComparableFingerprint)
            dockWatcher?.start()
        }

        guard let space = activeSpace else {
            editHistory.push(settings.defaultDock, for: DockEditHistory.defaultDockKey)
            updateSettings { $0.defaultDock = config }
            append(.info, "手动改动已回存到默认 Dock（当前不在用户桌面上）")
            return
        }

        if hasOverride(for: space) {
            editHistory.push(effectiveConfig(for: space), for: space.id)
            setOverride(config, for: space, reason: "回存手动改动：\(config.pinnedApps.count) 个图标")
        } else {
            editHistory.push(settings.defaultDock, for: DockEditHistory.defaultDockKey)
            updateSettings { $0.defaultDock = config }
            append(.info, "手动改动已回存到默认 Dock：\(config.pinnedApps.count) 个图标")
        }
    }

    // MARK: - 撤销自动回存

    /// 回存落点与 `handleUserDockEdit` 同一口径：有独立 Dock 的桌面 → 该桌面；否则 → 默认 Dock。
    private func captureTargetKey(for space: DesktopSpace?) -> String {
        guard let space, hasOverride(for: space) else { return DockEditHistory.defaultDockKey }
        return space.id
    }

    /// 回存永远落在**活动桌面**上，所以撤销的落点也按活动桌面算，不能由 UI 传。
    func canUndoAutoCapture() -> Bool {
        editHistory.canUndo(for: captureTargetKey(for: activeSpace))
    }

    /// 撤销上一次自动回存。返回是否真的撤了。
    @discardableResult
    func undoLastAutoCapture() -> Bool {
        let space = activeSpace
        let key = captureTargetKey(for: space)
        guard let previous = editHistory.pop(for: key) else { return false }
        if key == DockEditHistory.defaultDockKey {
            updateSettings { $0.defaultDock = previous }
            append(.info, "已撤销上一次自动回存：默认 Dock 恢复为 \(previous.pinnedApps.count) 个图标")
        } else if let space {
            setOverride(previous, for: space, reason: "撤销上一次自动回存")
        }
        return true
    }

    // MARK: - 编辑器统一入口（默认 Dock 与逐桌面独立 Dock 共用）

    /// 目标当前生效的配置。
    func dockConfig(for target: DockEditTarget) -> DockConfig {
        switch target {
        case .defaultDock: return settings.defaultDock
        case .desktop(let space): return effectiveConfig(for: space)
        }
    }

    func dockAppearance(for target: DockEditTarget) -> DockAppearance {
        dockConfig(for: target).appearance
    }

    /// **只改内存**，不落盘、不应用。
    ///
    /// 编辑器必须走它：拖拽排序的每次 `dropEntered`、滑杆的每一步都会赋值，
    /// 若顺手落盘 + 重启 Dock，拖过一个图标就会写一次盘、闪一次 Dock。
    func setDockConfigInMemory(_ config: DockConfig, for target: DockEditTarget) {
        switch target {
        case .defaultDock:
            settings.defaultDock = config
        case .desktop(let space):
            setOverrideInMemory(config, for: space)
        }
    }

    func setDockAppearanceInMemory(_ appearance: DockAppearance, for target: DockEditTarget) {
        var config = dockConfig(for: target)
        config.appearance = appearance
        setDockConfigInMemory(config, for: target)
    }

    /// 一次编辑结束：**落盘一次**，并按「编辑后立即应用」开关决定要不要推给真实 Dock。
    func dockEdited(_ target: DockEditTarget, reason: String) {
        switch target {
        case .defaultDock:
            dockConfigEdited(reason: reason)
        case .desktop(let space):
            overrideEdited(for: space, reason: reason)
        }
    }

    /// 这个目标是否已经有独立于默认 Dock 的内容（决定 UI 显示"独立"还是"沿用默认"）。
    func isOverridden(_ target: DockEditTarget) -> Bool {
        switch target {
        case .defaultDock: return false
        case .desktop(let space): return hasOverride(for: space)
        }
    }

    private func startDockWatcher() {
        guard settings.autoCaptureUserEdits else {
            append(.info, "「识别真实 Dock 上的手动改动并回存」已关闭，不启动监视")
            return
        }
        let watcher = DockWatcher(
            currentFingerprint: { [weak self] in self?.dockController.currentComparableFingerprint() },
            appliedFingerprint: { [weak self] in self?.dockController.appliedComparableFingerprint },
            readLiveConfig: { [weak self] in self?.dockController.captureLiveConfig() },
            onUserEdit: { [weak self] config in self?.handleUserDockEdit(config) },
            log: { [weak self] message in self?.append(.info, message) }
        )
        watcher.start()
        dockWatcher = watcher
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
        refreshLoginItemStatus()
        refreshDisplayScreens()
        refreshBackups()
        refreshDockCapabilities()

        // 把"此刻真实 Dock 的内容"记成已应用状态：如果它已经等于要应用的那份配置，
        // 下面的自动应用就会被指纹短路，启动时不会白重启一次 Dock。
        dockController.adoptLiveDockAsApplied()

        observer.start()
        append(.info, "桌面观察已启动（300 ms 轮询 + 通知）")
        append(.info, "识别到 \(observer.desktops.count) 个用户桌面")
        for space in observer.desktops {
            append(.info, "  · \(displayName(for: space)) uuid=\(space.spaceUUID) id64=\(space.id64)"
                + (hasOverride(for: space) ? "（独立 Dock）" : "（沿用默认）"))
        }
        if let active = observer.activeSpace {
            append(.info, "当前桌面：\(displayName(for: active)) / id64=\(active.id64)")
        }

        startDockWatcher()
        startDockPresenceMonitor()
        // 自愈必须放在最后：它要走还原链路（写偏好 + 重启 Dock），
        // 得等观察器、watcher、监视器都就位，否则还原完它们才启动，状态会错。
        scheduleSelfHealIfNeeded()
    }

    func stop() {
        observer.stop()
        dockWatcher?.stop()
        dockPresenceMonitor?.stop()
        append(.info, "桌面观察已停止")
    }

    /// 退出前的准备工作：停掉会跟还原抢写入的监视器，并等所有排队的应用跑完。
    ///
    /// **这一步不能省**。`DockController.request` 是异步排队的：如果还原之前还有一笔待办
    /// 没落地，它会在还原**之后**才写进去 —— 用户看到的结果是"退出时还原了，Dock 却还是错的"。
    func prepareForTermination() async {
        dockWatcher?.stop()
        dockPresenceMonitor?.stop()
        // 自愈可能正在写偏好。先等它落地，否则两笔写入互相覆盖，
        // 结果取决于谁后写完 —— 那是不可复现的错乱。
        await waitForSelfHeal()
        await dockController.waitForIdle()
    }

    /// 启动自检：残留会话标记 + 基准快照（计划 §3.9 的固定顺序）。
    private func runStartupSelfCheck() {
        if let stale = baselineStore.detectInterruptedSession() {
            interruptedSession = stale
            if stale.impliesDirtyDock {
                // 不在这里还原：还原要写偏好 + 重启 Dock，得等观察器与监视器都就位。
                pendingSelfHeal = stale
                append(.warning, "上次未正常退出（PID \(stale.pid)），Dock 可能没还原 —— 启动后自动还原")
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
        // **预应用**（计划 §3.4 第 8 条）：先算出目标、把它的 Dock 推下去，再切空间 ——
        // 切换动画结束时 Dock 已经是正确状态，不用等轮询发现变化才动。
        guard let target = switcher.target(.next) else {
            append(.warning, "没有可切换的下一个桌面（当前显示器只有 1 个桌面，或尚未识别到活动桌面）")
            return
        }
        applyConfigForDesktop(target, reason: "预应用：切到 \(displayName(for: target))")
        guard switcher.switchTo(target) != nil else {
            append(.warning, "切换到 \(displayName(for: target)) 失败")
            return
        }
        append(.info, "切换到 \(displayName(for: target))（id64=\(target.id64)）")
    }

    /// ⇧ + 左键：切到上一个桌面。与 `switchToNextDesktop` 完全对称（同一条预应用链路）。
    func switchToPreviousDesktop() {
        guard spaceProviderAvailable else {
            append(.error, "桌面切换不可用：\(spaceProviderWarning ?? "未知原因")")
            return
        }
        guard let target = switcher.target(.previous) else {
            append(.warning, "没有可切换的上一个桌面（当前显示器只有 1 个桌面，或尚未识别到活动桌面）")
            return
        }
        applyConfigForDesktop(target, reason: "预应用：切到 \(displayName(for: target))")
        guard switcher.switchTo(target) != nil else {
            append(.warning, "切换到 \(displayName(for: target)) 失败")
            return
        }
        append(.info, "切到上一个桌面：\(displayName(for: target))（id64=\(target.id64)）")
    }

    func switchTo(_ space: DesktopSpace) {
        guard spaceProviderAvailable else {
            append(.error, "桌面切换不可用：\(spaceProviderWarning ?? "未知原因")")
            return
        }
        applyConfigForDesktop(space, reason: "预应用：切到 \(displayName(for: space))")
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

    /// 显示器配置变化（插拔外接屏 / 改分辨率）后重新识别桌面。
    ///
    /// 多显示器下 `displayUUID` 是映射键的一部分（`DesktopSpace.id`），插拔之后桌面列表
    /// 必须重读 —— 否则新显示器上的桌面要等下一次手动刷新才出现，期间切换会串行。
    /// 这里刻意**不**主动应用 Dock：屏幕变化的瞬间活动空间可能还没定，
    /// 交给 300 ms 轮询去收敛，避免瞎重启一次 Dock。
    func handleScreenParametersChanged() {
        let before = desktops.count
        refreshDisplayScreens()
        observer.refreshNow()
        append(.info, "显示器配置变化：桌面列表已刷新（\(before) → \(desktops.count) 个）")
    }

    /// 刷新 `displayUUID → 显示器名` 映射（计划 §3.7）。
    ///
    /// 插拔外接屏必然让这份映射变（`(displayUUID, spaceUUID)` 是桌面身份的一部分），
    /// 所以调用点就是启动 + `didChangeScreenParametersNotification`。
    func refreshDisplayScreens() {
        displayScreens = ScreenNaming.currentScreens()
    }

    /// 桌面列表与详情里显示的显示器名。映射不到时如实说明，不回落成一台错的显示器。
    func screenName(for displayUUID: String) -> String {
        ScreenNaming.displayName(for: displayUUID, screens: displayScreens)
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
        // mru-spaces 走同一个注入点，测试里不会读到真实系统的偏好域。
        mruSpaces = dockController.readMRUSpaces()
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

    /// 菜单栏的「用当前 Dock 重置本桌面配置」（计划 §3.7 菜单栏下拉）。
    ///
    /// 语义：**不新增绑定**。当前桌面有独立 Dock 就覆盖它；没有就覆盖默认 Dock ——
    /// 因为那个桌面本来就在用默认 Dock，凭空造一条 override 会让它悄悄脱离默认。
    func resetActiveDesktopConfigFromLiveDock() {
        guard let live = captureLiveDockConfig() else { return }
        guard let space = activeSpace else {
            updateSettings { $0.defaultDock = live }
            append(.info, "当前不在用户桌面上，已用当前 Dock 重置默认 Dock")
            return
        }
        if hasOverride(for: space) {
            setOverride(live, for: space, reason: "用当前 Dock 重置本桌面配置")
        } else {
            updateSettings { $0.defaultDock = live }
            append(.info, "\(displayName(for: space)) 沿用默认 Dock，已用当前 Dock 重置默认 Dock")
        }
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
            // 告诉 watcher「这次变化是我们自己造成的」，别当成用户手动改动。
            dockWatcher?.acknowledge(dockController.appliedComparableFingerprint)
            refreshDockCapabilities()
        case .skippedIdentical:
            append(.info, "Dock 内容与当前一致，未写入也未重启（\(outcome.reason)）")
        case .failed:
            append(.error, "Dock 应用失败：\(outcome.summary)")
        }
    }

    // MARK: - 无痕与自愈（P4）

    /// 启动自愈：上次被强杀/崩溃留下的残留标记，意味着真实 Dock 可能还停在我们写下的配置上。
    /// 启动后把它还原回基准，并给用户一个看得见的提示（toast + 日志）。
    private func scheduleSelfHealIfNeeded() {
        guard selfHealTask == nil, let stale = pendingSelfHeal, stale.impliesDirtyDock else { return }
        selfHealTask = Task { [weak self] in await self?.performSelfHeal(stale) }
    }

    /// 等自愈跑完。退出流程与测试都要用 —— 不等的话，自愈的写入会和退出还原的写入互相覆盖。
    func waitForSelfHeal() async {
        await selfHealTask?.value
    }

    /// 自愈还原。独立成方法而不是塞进 `Task` 闭包，是为了能单测。
    ///
    /// 失败**不清债务**：会话标记里的 `needsSelfHeal`（由 `LifecycleController.beginSession`
    /// 从 `hasPendingSelfHeal` 继承）会留到下次启动继续重试；退出时也会再走一遍还原链路。
    func performSelfHeal(_ stale: BaselineStore.SessionMarker) async {
        append(.warning, "开始自愈还原：上次（PID \(stale.pid)）没走完退出还原")
        let outcome = await restoreToBaseline()
        pendingSelfHeal = nil

        guard let outcome else {
            selfHealSummary = "自愈还原失败（读不到基准快照）"
            append(.error, "自愈还原失败：读不到基准快照 \(baselineStore.baselineURL.path)")
            return
        }
        switch outcome.result {
        case .applied:
            selfHealSummary = "已自动还原上次未还原的 Dock"
            append(.info, "自愈还原完成：\(outcome.summary)")
            toastPresenter?.announce("已自动还原上次未还原的 Dock")
        case .skippedIdentical:
            selfHealSummary = "Dock 已与原始状态一致，无需还原"
            append(.info, "自愈检查：真实 Dock 已经与基准一致，不用动它")
        case .failed:
            selfHealSummary = "自愈还原失败，请手动还原"
            append(.error, "自愈还原失败，请到设置页点「立即还原到原始 Dock」")
        }
    }

    /// Dock 存活监视（P4 验收第 4 条）。Dock 被外部弄死时拉回来。
    private func startDockPresenceMonitor() {
        // 注入的监视器带着自己的日志出口（测试用），不要在这里覆盖它。
        let monitor = injectedPresenceMonitor ?? DockPresenceMonitor { [weak self] message in
            self?.append(.warning, message)
        }
        // 这两个回调**无条件**挂上，包括注入的监视器 —— 它们写的是 AppState 自己的状态，
        // 而监视器可能是在测试里构造好再注入的（那时 init 参数没人填）。
        // 与上面的 log 出口不同：log 是监视器自己的出口，注入时就别覆盖。
        monitor.onPersistentlyDown = { [weak self] reason in
            guard let self else { return }
            self.dockFailureWarning = reason
            self.append(.error, "\(reason)。建议到「通用 → 备份与还原」恢复一份历史备份，或直接点「立即还原到原始 Dock」")
        }
        monitor.onRevived = { [weak self] count in
            guard let self else { return }
            self.dockFailureWarning = nil
            self.append(.info, "Dock 已恢复（第 \(count) 次），警告解除")
            self.toastPresenter?.announce("Dock 已恢复")
        }
        dockPresenceMonitor = monitor
        monitor.start()
    }

    /// 立刻再试一次把 Dock 拉回来（横幅上的按钮）。返回 `launchctl` 是否跑起来了。
    ///
    /// 注意返回值**不代表 Dock 回来了** —— 拉没拉回来由监视器的下一次轮询判定，
    /// 横幅也不会在这里就消失。
    @discardableResult
    func retryDockRevival() -> Bool {
        guard let monitor = dockPresenceMonitor else {
            append(.warning, "Dock 存活监视未启动，无法重试拉回")
            return false
        }
        let started = monitor.reviveNow()
        append(started ? .info : .warning,
               started ? "已手动重试拉回 Dock，等下一次轮询确认" : "手动重试拉回失败（launchctl 没跑起来）")
        return started
    }

    /// 「根据最近使用自动重排空间」。**只在用户主动点开关时调用**，不静默修改（计划 §1 风险项）。
    func setMRUSpaces(_ enabled: Bool) {
        let previous = mruSpaces
        guard dockController.writeMRUSpaces(enabled) else {
            mruSpaces = dockController.readMRUSpaces()
            append(.error, "写 mru-spaces 失败（可能被系统策略锁住），保持原值")
            return
        }
        mruSpaces = enabled
        append(.info, "mru-spaces：\(previous.map(String.init) ?? "未知") → \(enabled)")
        // 这个键不在白名单里，`apply` 管不到它 —— 只能单独重启一次 Dock 让它生效。
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.dockController.reloadOnly(strategy: self.settings.reloadStrategy)
            self.append(.info, "mru-spaces 生效重载：\(outcome.description)")
        }
    }

    /// 刷新历史备份列表（设置页打开时调）。
    func refreshBackups() {
        backups = baselineStore.listBackups()
    }

    /// 恢复某份历史备份。
    ///
    /// **只写白名单键**，不做整域替换。理由：我们自己从来只碰白名单键，备份里白名单之外的键
    /// （热角、启动台网格……）与我们无关；整域替换反而会把用户后来改过的那些设置一并冲回旧值，
    /// 那才是真的破坏。需要整域恢复的场景（Dock 被别的东西改坏了）在 README 里给了做法。
    func restoreBackup(_ entry: BaselineStore.BackupEntry) {
        let domain = baselineStore.readBackup(at: entry.url)
        guard !domain.isEmpty else {
            append(.error, "备份 \(entry.fileName) 读不出来或已损坏，未做任何改动")
            return
        }
        let config = DockConfig.read(from: domain)
        append(.info, "恢复备份 \(entry.fileName)：\(config.pinnedApps.count) 个图标")
        applyDock(config, reason: "恢复备份 \(entry.fileName)")
    }

    /// 登录启动状态（设置页显示）。真正的注册/注销在 `LoginItem`。
    func refreshLoginItemStatus() {
        loginItemStatus = LoginItem.statusDescription()
    }

    /// 开/关登录启动。用户主动点开关才会走到这里。
    func setLoginItemEnabled(_ enabled: Bool) {
        do {
            let how = enabled ? try LoginItem.enable() : try LoginItem.disable()
            append(.info, "登录启动：\(enabled ? "开启" : "关闭") —— \(how)")
        } catch {
            append(.error, "登录启动设置失败：\(error.localizedDescription)")
        }
        refreshLoginItemStatus()
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

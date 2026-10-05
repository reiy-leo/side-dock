import AppKit
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
///
/// **内容模型（2026-10-05 用户修订）**：
/// - 默认 Dock = 「最近添加的应用」自动生成（`RecentAppsScanner`），只存个数不存内容；
/// - 逐桌面差异由 **Dock 栏**（`DockBar`）承载：栏绑定桌面、可设屏幕位置，桌面上没绑栏
///   就只有原生 Dock（默认 Dock）可看；
/// - 大小 / 放大 / 自动隐藏 / 特效 / 最小化到应用**跟随系统**，App 不再读写外观键。
@MainActor
@Observable
final class AppState {

    // MARK: - 空间（转发给 observer）

    var desktops: [DesktopSpace] { observer.desktops }
    var activeSpace: DesktopSpace? { observer.activeSpace }
    var desktopListGeneration: Int { observer.desktopListGeneration }

    // MARK: - 配置

    private(set) var settings = AppSettings()
    /// 桌面命名（`customName`）。Dock 内容已改由 `settings.dockBars` 承载。
    private(set) var bindings: [DesktopBinding] = []
    /// 默认 Dock 的**运行时内容**：最近添加的应用（启动 / 改个数 / 手动应用前重建）。
    /// 不落 config.json —— 配置里只存 `defaultDockAppCount`，内容以扫描结果为准。
    private(set) var defaultDock = DockConfig()

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
    /// 次级 Dock 条的调度器。同样由 `AppDelegate` 注入；内容与开关从本状态读取。
    private(set) var secondaryDock: SecondaryDockController?

    /// Dock 应用流水线（读全量域 → 只覆盖内容键 → 原子写 → 重启 Dock → 校验）。
    let dockController: DockController
    /// 最近一次应用结果的一句话摘要，设置页直接显示。
    private(set) var lastApplySummary = "尚未应用过任何 Dock 设置"
    /// 本次运行是否真的改过真实 Dock。无痕原则靠它判断退出时要不要还原。
    private(set) var hasAppliedDockConfig = false

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
    /// 自愈任务是否已经跑完。**退出前的等待靠轮询这个标志**，
    /// 而不是 `await selfHealTask.value` —— 见 `settleSelfHeal(within:)`。
    private var selfHealFinished = false
    /// 冻结模式的启动对齐任务：自愈结束后把原生 Dock 对齐到默认 Dock。
    /// 留句柄是为了测试能等它跑完（`waitForFrozenDockAlignment`）。
    private var frozenDockAlignmentTask: Task<Void, Never>?

    /// 「最近添加的应用」的来源。默认扫 `/Applications` + `~/Applications`（按修改时间），
    /// 测试注入固定结果。
    private let recentAppsProvider: (_ limit: Int) -> [DockTile]
    /// 环境读取：台前调度开关 + 原生 Dock 方位（都零权限）。测试注入固定值。
    private let environmentReader: () -> EnvironmentReading

    /// 台前调度开关（缓存，2 s 轮询 + 打开设置窗口时即刷）。nil = 读不到，按未开启处理。
    /// 它决定 Dock 栏可选位置（开着避开左）；变更即更新设置页的位置选项。
    private(set) var stageManagerActive: Bool?
    /// 原生 Dock 方位（缓存，同一轮询）。nil = 探测不到（自动隐藏 / 重启瞬态）。
    /// 只喂设置页的实时提示；次级条自己的附着/独立判定走它 200 ms 的几何轮询，不经过这里。
    private(set) var dockSide: SecondaryDockOrientation?
    /// 环境轮询任务（2 s 一拍，便宜：一次 CFPreferences 读 + 一次 NSScreen 扫）。
    private var environmentTask: Task<Void, Never>?
    private var hasReadEnvironment = false

    /// 依赖全部可注入：`DockController`、两个 Store、以及空间提供者都能换成测试替身，
    /// 这样「立即应用 / 还原 / 切桌面预应用」这几条路径不必真的动用户的 Dock 也能测。
    ///
    /// `provider` 也要可注入，否则「预应用先于切换」只能靠真实桌面来验，没法写成断言。
    ///
    /// `fileLog` 也必须可注入：它默认写 `~/Library/Application Support/MultiDock/multidock.log`，
    /// 而那份日志是**用户核对真机行为的唯一凭据**（无屏幕录制、`log show` 沙箱里读不到）。
    /// 测试里不换掉它，一次 `swift test` 就会往那份日志灌进几千行假记录（假 PID 100 → 1001），
    /// 把"连切十次看 `Dock 不可用` 是不是回到 100 ms"这类核对整个污染掉。
    init(
        dockController: DockController = DockController(),
        configStore: ConfigStore = ConfigStore(),
        baselineStore: BaselineStore = BaselineStore(),
        provider: (any SpaceProviding)? = nil,
        presenceMonitor: DockPresenceMonitor? = nil,
        fileLog: FileLogSink = FileLogSink(),
        recentAppsProvider: @escaping (_ limit: Int) -> [DockTile] = { RecentAppsScanner.scan(limit: $0) },
        environmentReader: @escaping () -> EnvironmentReading = {
            EnvironmentReading(
                stageManagerActive: StageManagerStatus.isActive(),
                dockSide: ScreenInsetDockFaceProvider().currentFace()?.orientation
            )
        }
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
        self.fileLog = fileLog
        self.recentAppsProvider = recentAppsProvider
        self.environmentReader = environmentReader
        observer.onActiveSpaceChanged = { [weak self] space in
            guard let self else { return }
            if let space {
                self.append(.info, "活动桌面 → \(self.displayName(for: space))（\(space.spaceUUID.prefix(8))…）")
            } else {
                self.append(.info, "活动空间不是用户桌面（可能是全屏 App），不触发切换")
            }
            self.toastPresenter?.handleActiveSpaceChanged(space)
            self.secondaryDock?.spaceDidChange(space)
            // 桌面切换后把该桌面的 Dock 推下去（内容相同会被指纹短路，不会白重启 Dock）。
            if let space { self.applyForDesktopSwitch(space, reason: "切到 \(self.displayName(for: space))") }
        }
        // 必须在最后：闭包要捕获 `self`，而所有存储属性得先初始化完。
        dockController.onOutcome = { [weak self] outcome in self?.handleDockOutcome(outcome) }
    }

    // MARK: - Dock 栏（桌面 Tab 编辑的实体）

    var dockBars: [DockBar] { settings.dockBars }

    /// 绑定到某个桌面的栏（一个桌面同时只认第一根，`bindDockBar` 保证不重）。
    func dockBar(for space: DesktopSpace) -> DockBar? {
        settings.dockBars.first { $0.spaceID == space.id }
    }

    func dockBar(id: UUID) -> DockBar? {
        settings.dockBars.first { $0.id == id }
    }

    /// 绑定还挂在已消失桌面上（桌面被删 / 显示器被拔）的栏。**只提示不清**：
    /// 插回来还要用，清理只解绑（应用与位置保留）。
    var orphanedBars: [DockBar] {
        let live = Set(desktops.map(\.id))
        return settings.dockBars.filter { bar in
            guard let spaceID = bar.spaceID else { return false }
            return !live.contains(spaceID)
        }
    }

    /// 解绑所有孤儿栏（应用保留），返回解绑的数量。
    @discardableResult
    func unbindOrphanedBars() -> Int {
        let orphans = orphanedBars
        guard !orphans.isEmpty else { return 0 }
        let dead = Set(orphans.map(\.spaceID))
        updateSettings {
            for index in $0.dockBars.indices where $0.dockBars[index].spaceID.map(dead.contains) == true {
                $0.dockBars[index].spaceID = nil
            }
        }
        append(.warning, "已解绑 \(orphans.count) 根失效的 Dock 栏（对应桌面已不存在，应用保留）")
        secondaryDock?.refresh()
        return orphans.count
    }

    /// 新增一根空栏。名字自动避开已有名字。
    @discardableResult
    func addDockBar() -> UUID {
        let bar = DockBar(name: uniqueBarName(base: "Dock \(settings.dockBars.count + 1)"))
        updateSettings { $0.dockBars.append(bar) }
        append(.info, "已添加 Dock 栏「\(bar.name)」")
        return bar.id
    }

    func removeDockBar(id: UUID) {
        guard let bar = dockBar(id: id) else { return }
        updateSettings { $0.dockBars.removeAll { $0.id == id } }
        append(.info, "已删除 Dock 栏「\(bar.name)」")
        secondaryDock?.refresh()
    }

    /// 改栏名。归一化（≤10 字素簇）后与原值相同则不落盘。
    func renameDockBar(_ id: UUID, to raw: String) {
        guard var bar = dockBar(id: id) else { return }
        let name = DesktopNaming.normalize(raw)
        guard !name.isEmpty, name != bar.name else { return }
        bar.name = name
        updateDockBarInMemory(bar)
        persistConfiguration()
        append(.info, "Dock 栏改名 →「\(name)」")
    }

    /// 绑定栏到桌面。**一根桌面同时只挂一根栏**：绑到已有栏的桌面上，
    /// 会把另一根挤成未绑定（应用保留）。`nil` = 解绑。
    func bindDockBar(_ id: UUID, to spaceID: String?) {
        guard var bar = dockBar(id: id) else { return }
        guard bar.spaceID != spaceID else { return }
        var displacedName: String?
        var bars = settings.dockBars
        if let spaceID,
            let index = bars.firstIndex(where: { $0.spaceID == spaceID && $0.id != id })
        {
            bars[index].spaceID = nil
            displacedName = bars[index].name
        }
        guard let index = bars.firstIndex(where: { $0.id == id }) else { return }
        bars[index].spaceID = spaceID
        bar = bars[index]
        updateSettings { $0.dockBars = bars }
        if let displacedName {
            append(.info, "「\(displacedName)」让出桌面（一个桌面只挂一根栏）")
        }
        append(.info, "Dock 栏「\(bar.name)」：\(spaceID.map { "绑定桌面 \($0)" } ?? "已解绑")")
        refreshAfterBarChange(bar)
    }

    /// 编辑器专用：**只改内存**，不落盘（拖拽排序过程中会连发）。
    func updateDockBarInMemory(_ bar: DockBar) {
        guard let index = settings.dockBars.firstIndex(where: { $0.id == bar.id }) else { return }
        settings.dockBars[index] = bar
    }

    /// 一次编辑结束：落盘一次；绑定的桌面是活动桌面时按开关应用 + 刷新条。
    func dockBarEdited(_ bar: DockBar, reason: String) {
        updateDockBarInMemory(bar)
        persistConfiguration()
        append(.info, "Dock 栏「\(bar.name)」已修改：\(reason)")
        refreshAfterBarChange(bar)
    }

    private func refreshAfterBarChange(_ bar: DockBar) {
        secondaryDock?.refresh()
        guard let spaceID = bar.spaceID,
            !settings.freezeNativeDockSwitching,
            settings.autoApplyOnEdit,
            let space = desktops.first(where: { $0.id == spaceID })
        else { return }
        applyConfigForDesktop(space, reason: "Dock 栏「\(bar.name)」已修改")
    }

    private func uniqueBarName(base: String) -> String {
        let used = Set(settings.dockBars.map(\.name))
        guard used.contains(base) else { return base }
        var counter = 2
        while used.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    /// Dock 栏的可选位置（缓存值驱动，`refreshEnvironment` 更新后 SwiftUI 自动重渲染）。
    /// 台前调度开着时避开左（其窗口条固定占屏幕左缘）。
    var availableBarPositions: [DockBarPosition] {
        DockBarPosition.available(stageManagerActive: stageManagerActive ?? false)
    }

    /// 设置页实时提示：原生 Dock 的方位决定了「位置=同侧」的栏是附着模式（贴 Dock 内侧）。
    var dockSideDescription: String {
        switch dockSide {
        case .bottom: return "当前在底部（位置=底部的栏附着在 Dock 内侧）"
        case .left: return "当前在左侧（位置=左侧的栏附着在 Dock 内侧）"
        case .right: return "当前在右侧（位置=右侧的栏附着在 Dock 内侧）"
        case nil: return "位置未识别（各栏按自身位置独立贴边）"
        }
    }

    /// 读一次环境（台前调度 + 原生 Dock 方位），值变化时更新缓存并记日志。
    /// 首次读取静默（启动日志里没必要多两条）。
    func refreshEnvironment() {
        let reading = environmentReader()
        if reading.stageManagerActive != stageManagerActive {
            stageManagerActive = reading.stageManagerActive
            if hasReadEnvironment, let active = reading.stageManagerActive {
                append(.info, "台前调度：\(active ? "开启" : "关闭")——Dock 栏可选位置已更新")
            }
        }
        if reading.dockSide != dockSide {
            dockSide = reading.dockSide
            if hasReadEnvironment, let side = reading.dockSide {
                append(.info, "原生 Dock 位置变化 → \(side)")
            }
        }
        hasReadEnvironment = true
    }

    /// 打开设置窗口时的快照刷新（用户规格 2026-10-06：**只有打开设置窗口才重扫**最近应用），
    /// 顺带即刷环境（不等 2 s 轮询拍）。
    ///
    /// 重扫只更新内存里的默认 Dock（预览跟着变）；**不会自动应用**——
    /// 把新内容写进 Dock 仍由「立即应用」/ 数量改动 / 下次启动对齐触发，
    /// 否则每次开设置都可能白重启一次 Dock。
    func prepareSettingsPresentation() {
        rebuildDefaultDock(reason: "打开设置窗口重扫")
        refreshEnvironment()
    }

    private func startEnvironmentPoll() {
        environmentTask?.cancel()
        environmentTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshEnvironment()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - 默认 Dock（最近添加的应用）

    /// 重建默认 Dock 内容：扫 `/Applications` + `~/Applications`，取最新的 N 个。
    ///
    /// 重建时机：启动、改显示个数、「立即应用」与冻结对齐之前。**不做周期性重扫**：
    /// 装了新应用要等下一次重建（或手动点「立即应用」）才会进 Dock ——
    /// 自发改写 Dock 意味着不可预期的重启，宁少勿滥。
    func rebuildDefaultDock(reason: String) {
        let apps = recentAppsProvider(settings.defaultDockAppCount)
        // 启动台补首（与真实 Dock 的既有口径一致）：默认 Dock 是冻结模式下原生 Dock 的内容，
        // 历史配置里启动台永远在 persistent-apps[0]，自动内容不能把它弄丢。
        let normalized = DockStripRules.normalizedApps(apps)
        let changed = normalized != defaultDock.pinnedApps
        defaultDock = DockConfig(pinnedApps: normalized)
        if changed || reason.contains("重扫") {
            append(.info, "默认 Dock 重算（\(reason)）：\(apps.count) 个最近添加的应用")
        }
    }

    /// 改默认 Dock 显示的应用个数（1...15，默认 10）。
    func setDefaultDockAppCount(_ count: Int) {
        let clamped = min(max(count, 1), DockBar.maxApps)
        guard settings.defaultDockAppCount != clamped else { return }
        updateSettings { $0.defaultDockAppCount = clamped }
        rebuildDefaultDock(reason: "显示数量改为 \(clamped)")
        if settings.autoApplyOnEdit {
            applyDock(defaultDock, reason: "默认 Dock 数量改为 \(clamped)")
        }
    }

    // MARK: - 桌面生效配置

    /// 某个桌面实际生效的 Dock：绑定的栏优先，否则默认 Dock。
    func effectiveConfig(for space: DesktopSpace) -> DockConfig {
        guard let bar = dockBar(for: space) else { return defaultDock }
        return DockConfig(pinnedApps: bar.apps, otherItems: bar.otherItems)
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

    /// **桌面切换路径**的统一入口（被动回调 + 三条预应用都走它）。
    ///
    /// 「冻结原生 Dock 逐桌面切换」开启时整条跳过：原生 Dock 保持一套固定配置、
    /// 不再写偏好/重启，逐桌面的差异由次级 Dock 条呈现。
    /// 手动路径（「立即应用」、编辑器的「编辑后立即应用」）不走这里，不受冻结影响。
    func applyForDesktopSwitch(_ space: DesktopSpace, reason: String) {
        guard !settings.freezeNativeDockSwitching else {
            append(.info, "原生 Dock 已冻结：跳过「\(reason)」，由次级 Dock 条呈现")
            return
        }
        applyConfigForDesktop(space, reason: reason)
    }

    /// 「冻结原生 Dock 逐桌面切换」开关（设置页调用）。
    ///
    /// 除了翻转设置，两个方向都要让原生 Dock **立刻**与新模式一致，别等下一次切换：
    /// - 开：冻结的那套固定配置就是**默认 Dock**（最近添加的应用）—— 先重扫再对齐
    ///   （内容一致会被指纹短路，不写不重启）。不补这一下，原生 Dock 可能停在某个桌面的
    ///   旧内容上，而次级条显示的却是各自绑定栏的内容，两套内容并排各说各话。
    /// - 关：恢复逐桌面切换 —— 当前桌面的生效配置立即应用（有绑栏就上栏的内容）。
    func setFreezeNativeDockSwitching(_ enabled: Bool) {
        guard settings.freezeNativeDockSwitching != enabled else { return }
        updateSettings { $0.freezeNativeDockSwitching = enabled }
        secondaryDock?.refresh()
        if enabled {
            rebuildDefaultDock(reason: "冻结模式对齐前重扫")
            applyDock(defaultDock, reason: "冻结模式：原生 Dock 对齐默认 Dock")
        } else if let space = activeSpace {
            applyForDesktopSwitch(space, reason: "解冻：恢复逐桌面切换")
        }
    }

    /// 冻结模式：启动时把原生 Dock 对齐到「默认 Dock」。
    ///
    /// 为什么启动要补一次：退出时无痕还原把基准写回去，下次启动原生 Dock 就停在基准上；
    /// 不补这一下，原生 Dock 与次级条（默认 Dock / 桌面绑定栏）各显一套。
    /// 内容已经一致时 `apply` 指纹短路，不会重启 Dock。
    /// **必须排在自愈之后**：自愈先还原基准（清上次欠账），这里再冻结 ——
    /// 自愈的还原不走 `request` 队列，所以用 `await waitForSelfHeal()` 串行，不能只靠排队。
    func waitForFrozenDockAlignment() async {
        await frozenDockAlignmentTask?.value
    }

    private func reestablishFrozenDockIfNeeded() {
        guard settings.freezeNativeDockSwitching else { return }
        frozenDockAlignmentTask = Task { [weak self] in
            await self?.waitForSelfHeal()
            guard let self, !Task.isCancelled, self.settings.freezeNativeDockSwitching else { return }
            self.rebuildDefaultDock(reason: "冻结模式：启动对齐前重扫")
            self.applyDock(self.defaultDock, reason: "冻结模式：启动对齐默认 Dock")
        }
    }

    /// 用户手动改了真实 Dock → 回存（计划 §3.8）。
    ///
    /// 2026-10-05 起默认 Dock 的内容是**自动生成**的（最近添加的应用），
    /// 手动改动只可能回存到**活动桌面绑定的栏**里：
    /// - 冻结模式：原生 Dock 只有一套自动内容，手动改动无处可回 —— 只记日志说明原因；
    /// - 未冻结：有绑栏 → 回存进栏；没绑栏 → 当前桌面生效的是自动默认 Dock，同样无处可回。
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

        if settings.freezeNativeDockSwitching {
            append(.info, "冻结模式：默认 Dock 由「最近添加的应用」自动生成，手动改动不回存"
                + "（下次对齐会被覆盖）")
            return
        }

        guard let space = activeSpace else {
            append(.info, "当前不在用户桌面上（可能是全屏 App），手动改动不回存")
            return
        }
        guard var bar = dockBar(for: space) else {
            append(.info, "当前桌面未绑定 Dock 栏，手动改动不回存（切桌面会被默认内容覆盖）")
            return
        }

        editHistory.push(
            DockConfig(pinnedApps: bar.apps, otherItems: bar.otherItems),
            for: bar.id.uuidString
        )
        bar.apps = Array(config.pinnedApps.prefix(DockBar.maxApps))
        bar.otherItems = config.otherItems
        updateDockBarInMemory(bar)
        persistConfiguration()
        append(.info, "已回存到 Dock 栏「\(bar.name)」（\(bar.apps.count) 个图标）")
        if settings.autoApplyOnEdit {
            applyConfigForDesktop(space, reason: "回存手动改动")
        }
    }

    // MARK: - 撤销自动回存

    /// 回存落点与 `handleUserDockEdit` 同一口径：活动桌面绑定的栏；没有就落默认 Dock（历史遗留）。
    private func captureTargetKey(for space: DesktopSpace?) -> String {
        guard let space, let bar = dockBar(for: space) else { return DockEditHistory.defaultDockKey }
        return bar.id.uuidString
    }

    /// 回存永远落在**活动桌面**上，所以撤销的落点也按活动桌面算，不能由 UI 传。
    func canUndoAutoCapture() -> Bool {
        editHistory.canUndo(for: captureTargetKey(for: activeSpace))
    }

    /// 撤销上一次自动回存。返回是否真的撤了。
    @discardableResult
    func undoLastAutoCapture() -> Bool {
        let key = captureTargetKey(for: activeSpace)
        guard let previous = editHistory.pop(for: key) else { return false }
        if let barID = UUID(uuidString: key), var bar = dockBar(id: barID) {
            bar.apps = previous.pinnedApps
            bar.otherItems = previous.otherItems
            dockBarEdited(bar, reason: "撤销上一次自动回存")
            return true
        }
        defaultDock = previous
        append(.info, "已撤销上一次自动回存：默认 Dock 恢复为 \(previous.pinnedApps.count) 个图标")
        return true
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
        refreshEnvironment()

        // 把"此刻真实 Dock 的内容"记成已应用状态：如果它已经等于要应用的那份配置，
        // 下面的自动应用就会被指纹短路，启动时不会白重启一次 Dock。
        dockController.adoptLiveDockAsApplied()

        observer.start()
        append(.info, "桌面观察已启动（300 ms 轮询 + 通知）")
        append(.info, "识别到 \(observer.desktops.count) 个用户桌面")
        for space in observer.desktops {
            let bar = dockBar(for: space)
            append(.info, "  · \(displayName(for: space)) uuid=\(space.spaceUUID) id64=\(space.id64)"
                + (bar.map { "（Dock 栏「\($0.name)」）" } ?? "（未绑定栏）"))
        }
        if let active = observer.activeSpace {
            append(.info, "当前桌面：\(displayName(for: active)) / id64=\(active.id64)")
        }

        startDockWatcher()
        startDockPresenceMonitor()
        // 环境轮询（台前调度 / 原生 Dock 方位，2 s）：变化要反映到设置页的位置选项与提示。
        startEnvironmentPoll()
        // 次级 Dock 条按"此刻的活动桌面"初始化（之后由桌面变化回调驱动）。
        secondaryDock?.spaceDidChange(observer.activeSpace)
        // 自愈必须放在最后：它要走还原链路（写偏好 + 重启 Dock），
        // 得等观察器、watcher、监视器都就位，否则还原完它们才启动，状态会错。
        scheduleSelfHealIfNeeded()
        // 冻结模式的启动对齐排在自愈之后（它自己会等自愈跑完）。
        reestablishFrozenDockIfNeeded()
    }

    func stop() {
        observer.stop()
        dockWatcher?.stop()
        dockPresenceMonitor?.stop()
        secondaryDock?.stop()
        environmentTask?.cancel()
        environmentTask = nil
        frozenDockAlignmentTask?.cancel()
        append(.info, "桌面观察已停止")
    }

    /// 退出前的准备工作：停掉会跟还原抢写入的监视器，丢掉还没起跑的待办，
    /// 并**带上限地**等已经在跑的应用落地。返回 `true` = 真的干净了。
    ///
    /// **不能省，但也不能等满**：
    /// - 省掉 → 那笔待办会在还原**之后**才写进去，用户看到"退出时还原了，Dock 却还是错的"；
    /// - 等满 → 一次在飞的应用最坏走完整条降级链，launchd 退避期间实测几十秒，
    ///   那就是用户看到的"每次退出都卡住"。所以这里只等 `settleLimit`（默认 2 秒），
    ///   等不到就交给调用方留标记，下次启动自愈补上。
    /// - 自愈可能正在写偏好。先等它落地，否则两笔写入互相覆盖，
    ///   结果取决于谁后写完 —— 那是不可复现的错乱。
    func prepareForTermination(settleLimit: Duration = .seconds(2)) async -> Bool {
        dockWatcher?.stop()
        dockPresenceMonitor?.stop()
        // 还没起跑的待办：目标已经被"还原到基准"取代了，直接丢。
        dockController.dropPendingRequests()
        // 自愈可能正在写偏好。先等它落地，否则两笔写入互相覆盖，
        // 结果取决于谁后写完 —— 那是不可复现的错乱。同样带上限。
        guard await settleSelfHeal(within: settleLimit) else { return false }
        return await dockController.waitForIdle(upTo: settleLimit)
    }

    /// 等自愈在 `limit` 内跑完。没跑完返回 `false`。
    ///
    /// 只等不取消：**取消一次写了一半的还原比等久一点更危险**（与 `LifecycleController` 同理）。
    ///
    /// ⚠️ **刻意轮询标志，不用 `withTaskGroup` 赛跑**（与
    /// `DockController.waitForIdle(upTo:)` 同一个坑）：任务组闭包返回时会等**所有**子任务收尾，
    /// 而 `await task.value` 那种子任务对取消毫无反应 —— "上限"会**静默失效**：
    /// `group.next()` 照样在 20 ms 时报出 `false`（返回值看着是对的！），
    /// 可整个闭包要等那笔应用跑完才返回（实测 20 ms 上限 → 224 ms 墙钟）。
    private func settleSelfHeal(within limit: Duration) async -> Bool {
        guard selfHealTask != nil else { return true }
        let deadline = ContinuousClock.now + limit
        while !selfHealFinished, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return selfHealFinished
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
        var bindings = payload.bindings

        // 迁移（2026-10-05）：旧版逐桌面 override → Dock 栏。判据 = 配置里还没有任何栏
        // （`dockBars` 键不存在的旧文件解出来就是空数组）。迁移完补足到默认 5 栏；
        // 落盘放在下面 `self.bindings` 赋值**之后**（persistConfiguration 用的是实例属性）。
        let needsFormatUpgrade = settings.dockBars.isEmpty
        if needsFormatUpgrade {
            let migrated = DockBarCatalog.migratedBars(from: bindings)
            if !migrated.isEmpty {
                append(.info, "已把 \(migrated.count) 条逐桌面 Dock 配置迁移为 Dock 栏")
                for index in bindings.indices { bindings[index].override = nil }
            }
            settings.dockBars = DockBarCatalog.paddedToDefault(migrated)
        }

        // 归一化放在这里而不是 ConfigStore：手改 config.json 塞进超长名或空绑定，
        // 也要在进入内存模型前就被收拾干净（计划 §3.10 的「两层防线」）。
        let normalized = DesktopNaming.normalizedBindings(bindings)
        if normalized.count != bindings.count {
            append(.warning, "配置里有 \(bindings.count - normalized.count) 条空绑定（没有名字），已清理")
        }
        bindings = normalized
        self.bindings = normalized
        if needsFormatUpgrade {
            persistConfiguration()
        }
        append(.info, "配置已载入：\(settings.dockBars.count) 根 Dock 栏、\(normalized.count) 条桌面命名")
        rebuildDefaultDock(reason: "启动扫描")
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
        applyForDesktopSwitch(target, reason: "预应用：切到 \(displayName(for: target))")
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
        applyForDesktopSwitch(target, reason: "预应用：切到 \(displayName(for: target))")
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
        applyForDesktopSwitch(space, reason: "预应用：切到 \(displayName(for: space))")
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

    /// 重新探测 `mru-spaces` 的真实值。
    func refreshDockCapabilities() {
        // mru-spaces 走同一个注入点，测试里不会读到真实系统的偏好域。
        mruSpaces = dockController.readMRUSpaces()
    }

    /// 「立即应用」：重扫最近应用，把默认 Dock 推到真实 Dock。
    func applyDefaultDock() {
        rebuildDefaultDock(reason: "手动应用前重扫")
        applyDock(defaultDock, reason: "手动应用默认 Dock")
    }

    /// 应用一套配置。连击会被合并，只对最终落点执行一次。
    func applyDock(_ config: DockConfig, reason: String) {
        guard !config.pinnedApps.isEmpty else {
            append(.warning, "默认 Dock 是空的（没扫到任何应用），跳过「\(reason)」")
            return
        }
        append(.info, "准备应用 Dock（\(reason)）：\(config.pinnedApps.count) 个图标，重载方式 \(settings.reloadStrategy.displayName)")
        dockController.request(config, reason: reason, strategy: settings.reloadStrategy)
    }

    /// 把此刻真实的 Dock 读成一套配置（测试与回存用）。
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
    /// 2026-10-05 起默认 Dock 是自动生成的，这个动作**只对活动桌面绑定的栏**有意义：
    /// 把此刻真实 Dock 的内容抄进那根栏。冻结模式 / 未绑栏时如实说明，不做无效动作。
    func resetActiveDesktopConfigFromLiveDock() {
        guard let live = captureLiveDockConfig() else { return }
        guard !settings.freezeNativeDockSwitching else {
            append(.info, "冻结模式：原生 Dock 就是自动生成的默认内容，没有「本桌面配置」可重置")
            return
        }
        guard let space = activeSpace, var bar = dockBar(for: space) else {
            append(.info, "当前桌面未绑定 Dock 栏，没有可重置的配置")
            return
        }
        bar.apps = Array(live.pinnedApps.prefix(DockBar.maxApps))
        bar.otherItems = live.otherItems
        dockBarEdited(bar, reason: "用当前 Dock 重置（\(live.pinnedApps.count) 个图标）")
    }

    /// 编辑器每次改动后调用。受「编辑后立即应用」开关控制。
    func dockConfigEdited(reason: String) {
        persistConfiguration()
        append(.info, "默认 Dock 已修改：\(reason)")
        guard settings.autoApplyOnEdit else {
            append(.info, "「编辑后立即应用」已关闭，改动只存在本地配置里")
            return
        }
        applyDock(defaultDock, reason: reason)
    }

    /// 「立即还原到原始 Dock」。退出还原（P4）也走同一条路径。
    func restoreToBaselineNow() {
        Task { await self.restoreToBaseline() }
    }

    /// 「立即还原到原始 Dock」，以及退出还原（P4）与关机还原都走同一条路径。
    ///
    /// - Parameter forQuit: 我们**马上就不在了**（退出 / 关机）。那条路必须不等 Dock 归位 ——
    ///   等满一条降级链在 launchd 退避期间是几十秒（真机 2026-09-19 实测 53–54 秒），
    ///   而偏好写得出去、Dock 下次启动自然会读到，等它换不到任何东西。
    ///   菜单里那个手动按钮**不能**用这条：用户还看着屏幕，需要"确认真的还原了"。
    ///
    /// 还原写的是**基准域里的全部白名单键**（含外观键）：应用路径已不再写外观（跟随系统），
    /// 但旧版本写过 —— 还原是收尾，必须把那些键也带回去，无痕原则才闭环。
    @discardableResult
    func restoreToBaseline(forQuit: Bool = false) async -> DockController.Outcome? {
        let baseline = baselineStore.readBaseline()
        guard !baseline.isEmpty else {
            append(.error, "找不到基准快照（\(baselineStore.baselineURL.path)），无法还原")
            return nil
        }
        let config = DockConfig.read(from: baseline)
        let extraEntries = baseline.filter { DockPreferences.whitelistedKeys.contains($0.key) }

        // 已经与基准一致就什么都不做 —— 省掉一次没必要的 Dock 重启（退出时会明显拖慢）。
        if liveMatchesBaseline(baseline) {
            append(.info, "当前 Dock 已与基准一致，跳过还原（不重启 Dock）")
            return DockController.Outcome(
                result: .skippedIdentical, reason: "还原到原始 Dock", reload: nil, writtenKeys: 0,
                verifyAttempts: 0, elapsed: 0, note: nil, fingerprint: config.fingerprint
            )
        }

        append(.info, "开始还原到原始 Dock：\(config.pinnedApps.count) 个图标")
        let outcome = await dockController.apply(
            config,
            reason: "还原到原始 Dock",
            strategy: settings.reloadStrategy,
            force: true,
            forQuit: forQuit,
            extraEntries: extraEntries
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
        selfHealTask = Task { [weak self] in
            await self?.performSelfHeal(stale)
            self?.selfHealFinished = true
        }
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
    private func startDockWatcher() {
        guard settings.autoCaptureUserEdits else {
            append(.info, "「识别真实 Dock 上的手动改动并回存」已关闭，不启动监视")
            return
        }
        let watcher = DockWatcher(
            currentFingerprint: { [weak self] in self?.dockController.currentComparableFingerprint() },
            appliedFingerprint: { [weak self] in self?.dockController.appliedComparableFingerprint },
            readLiveConfig: { [weak self] in self?.dockController.captureLiveConfig() },
            isDockPresent: { [weak self] in self?.dockController.isDockAlive ?? false },
            onUserEdit: { [weak self] in self?.handleUserDockEdit($0) },
            log: { [weak self] message in self?.append(.info, message) }
        )
        watcher.start()
        dockWatcher = watcher
    }

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
        monitor.isReloading = { [weak self] in self?.dockController.isApplying ?? false }
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

    // MARK: - 次级 Dock 条

    /// 注入 toast 调度器（由 `AppDelegate` 组装）。
    func attachToastPresenter(_ presenter: ToastPresenter) {
        toastPresenter = presenter
    }

    /// 注入次级 Dock 条调度器（由 `AppDelegate` 组装，见 `attachToast` 的同一模式）。
    func attachSecondaryDock(_ controller: SecondaryDockController) {
        secondaryDock = controller
    }

    /// 次级 Dock 条的内容快照（调度器经注入闭包调用）。
    ///
    /// 返回 nil = 该桌面没有可显示的内容（条隐藏）。**内容只来自绑定栏**：
    /// 没绑栏的桌面在冻结模式下就是原生 Dock（默认 Dock = 最近添加的应用），条没有存在的必要。
    /// 正在运行的 App 集合现取 `NSWorkspace`（条目数少，开销可忽略）。
    ///
    /// 图标尺寸**跟随系统**（2026-10-05 用户规格）：读 `com.apple.dock` 的实时 `tilesize`
    /// （只读不写），钳制到 28–48 防止极端值把条撑破。
    func secondaryDockContent(for space: DesktopSpace?) -> SecondaryDockContentSnapshot? {
        guard let space, let bar = dockBar(for: space), !bar.apps.isEmpty else { return nil }
        let running = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.bundleIdentifier)
        )
        let systemTileSize = dockController.readSystemTileSize() ?? 36
        let iconSize = min(max(systemTileSize, 28), 48)
        guard var snapshot = SecondaryDockContentBuilder.snapshot(
            from: DockConfig(pinnedApps: bar.apps, otherItems: bar.otherItems),
            runningBundleIDs: running,
            iconSize: iconSize
        ) else { return nil }
        snapshot.position = bar.position
        return snapshot
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
    private let fileLog: FileLogSink

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

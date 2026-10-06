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
/// **内容模型（2026-10-06 用户修订：不再自动生成任何内容）**：
/// - **原生 Dock 归用户自己**：不再扫描 Applications、不存在「默认 Dock」；冻结模式下
///   本 App 从不改写原生 Dock（切桌面零写入），未冻结模式只写**绑定到该桌面的 Dock 栏**。
/// - 逐桌面差异由 **Dock 栏**（`DockBar`）承载：栏绑定桌面、可设屏幕位置；
///   没绑栏的桌面**什么都不写**（原生 Dock 保持原样）。
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
    private(set) var lastApplySummary = L("尚未应用过任何 Dock 设置", "No Dock settings applied yet")
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
    private(set) var loginItemStatus = L("未检查", "Not checked")

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

    // MARK: - 启动台（macOS 26 以下）

    /// 启动台数据入口（全部可注入：测试不碰真实数据库、也不扫真实安装目录）。
    private let launchpadLoader: LaunchpadLoader
    /// 最近一次读取到的启动台文件夹（屏幕顺序）。
    private(set) var launchpadFolders: [LaunchpadFolder] = []
    /// 「启动台」页的数据状态（驱动 UI：系统不支持 / 读不到 / 已加载）。
    private(set) var launchpadStatus: LaunchpadStatus = .notLoaded
    /// 上次记过的读取日志键：同一结果只记一次（每次切回本页都会重读，重复灌日志没有信息量）。
    private var lastLaunchpadLogKey: String?

    // MARK: - 数据（导出 / 导入）与更新检查

    /// 最近一次数据操作（导出 / 导入）的一句话结果，数据页直接显示。
    private(set) var lastDataOperationMessage: String?
    /// 最近一次数据操作是否失败（决定消息颜色）。
    private(set) var lastDataOperationFailed = false

    /// 更新检查状态（关于页显示）。
    enum UpdateCheckStatus: Equatable {
        case idle
        case checking
        case upToDate(latest: String)
        case available(latest: String, url: URL?)
        case failed(reason: String)
    }

    private(set) var updateCheckStatus: UpdateCheckStatus = .idle
    /// 每次启动只在关于页首次出现时自动检查一次；手动按钮随时可再查。
    private var hasAutoCheckedForUpdates = false
    /// 发布读取器。nil = 未配置（测试 / 快照环境）：按钮不会碰网络。
    private var releaseFetcher: (@Sendable () async -> UpdateCheckOutcome)?
    /// 在飞的检查任务句柄：连点「检查更新」时取消旧的，只保留最后一发。
    private var updateCheckTask: Task<Void, Never>?

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
        synthesizer: (any SpaceStepSynthesizing)? = nil,
        presenceMonitor: DockPresenceMonitor? = nil,
        fileLog: FileLogSink = FileLogSink(),
        launchpadLoader: LaunchpadLoader = .live,
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
        // 相邻一步优先合成系统快捷键（借 WindowServer 的滑动过渡，需辅助功能权限）；
        // 其余走硬切。超时兜底在 SpaceSwitcher 里，不会卡住不切。
        //
        // ⚠️ **默认不注入合成器**（nil = 旧版纯硬切行为）：真机由 AppDelegate 显式传入
        // `HotKeySpaceStepSynthesizer()`。这一条是硬要求 —— 测试进程里 `AXIsProcessTrusted()`
        // 可能为真，默认注入会让 `swift test` **真的合成按键去切用户的桌面**（实测踩到）。
        // 日志出口在 init 末尾回接（此处还不能引用 self）。
        switcher = SpaceSwitcher(
            observer: observer,
            synthesizer: synthesizer
        )
        self.dockController = dockController
        self.configStore = configStore
        self.baselineStore = baselineStore
        self.injectedPresenceMonitor = presenceMonitor
        self.fileLog = fileLog
        self.launchpadLoader = launchpadLoader
        self.environmentReader = environmentReader
        observer.onActiveSpaceChanged = { [weak self] space in
            guard let self else { return }
            if let space {
                self.append(.info, L("活动桌面 → \(self.displayName(for: space))（\(space.spaceUUID.prefix(8))…）", "Active desktop → \(self.displayName(for: space)) (\(space.spaceUUID.prefix(8))…)"))
            } else {
                self.append(.info, L("活动空间不是用户桌面（可能是全屏 App），不触发切换", "Active space is not a user desktop (possibly a full-screen app); not switching"))
            }
            self.toastPresenter?.handleActiveSpaceChanged(space)
            self.secondaryDock?.spaceDidChange(space)
            // 桌面切换后把该桌面的 Dock 推下去（内容相同会被指纹短路，不会白重启 Dock）。
            if let space { self.applyForDesktopSwitch(space, reason: L("切到 \(self.displayName(for: space))", "switch to \(self.displayName(for: space))")) }
        }
        // 必须在最后：闭包要捕获 `self`，而所有存储属性得先初始化完。
        dockController.onOutcome = { [weak self] outcome in self?.handleDockOutcome(outcome) }
        switcher.setLogger { [weak self] message in self?.append(.info, message) }
    }

    // MARK: - Dock 栏（桌面 Tab 编辑的实体）

    var dockBars: [DockBar] { settings.dockBars }

    /// 原生 Dock 里当前固定的 App 身份键（`DockTile.appIdentityKeys`）。
    ///
    /// 用户规格（2026-10-06）：**原生 Dock 里已固定的 App 不在自定义 Dock 栏里重复显示** ——
    /// 原生那份每个桌面都能看到，栏只该放"这个桌面额外多出来的"。
    /// 添加时拦下并给警告（`DockStripRules.addRejectionMessage`），已存在的**自动剔除**。
    ///
    /// **只在冻结模式有意义**：未冻结时原生 Dock 的内容就是我们写下去的栏内容，
    /// 拿它当排除集会把栏自己清空（自噬），所以那时这个集合恒空。
    private(set) var nativeDockPinnedKeys: Set<String> = []

    /// 这个条目是否已固定在原生 Dock 中（编辑器"添加"路径用它拦下并给警告）。
    func isPinnedInNativeDock(_ tile: DockTile) -> Bool {
        !tile.appIdentityKeys.isDisjoint(with: nativeDockPinnedKeys)
    }

    /// 重读原生 Dock 的固定内容，按新集合清洗所有栏（有变化才落盘）。
    /// 返回本次自动剔除的条目数。触发点：启动载入、打开设置窗口、原生 Dock 手动改动、冻结开关。
    @discardableResult
    func refreshNativeDockPinnedApps(reason: String) -> Int {
        guard settings.freezeNativeDockSwitching else {
            // 未冻结：排除集不适用（见属性注释）。清掉，免得解冻那一刻误剔。
            nativeDockPinnedKeys = []
            return 0
        }
        // 读不到偏好域就什么都不动 —— 拿不到事实时不做破坏性决定。
        guard let live = dockController.captureLiveConfig() else { return 0 }
        let keys = DockStripRules.identityKeys(of: live.pinnedApps)
        guard keys != nativeDockPinnedKeys else { return 0 }
        nativeDockPinnedKeys = keys
        return pruneAppsPinnedInNativeDock(reason: reason)
    }

    /// 清掉所有栏里「已固定在原生 Dock」的 App（落盘一次、逐栏记日志）。返回剔除条数。
    @discardableResult
    private func pruneAppsPinnedInNativeDock(reason: String) -> Int {
        guard !nativeDockPinnedKeys.isEmpty else { return 0 }
        var bars = settings.dockBars
        var pruned = 0
        for index in bars.indices {
            let (kept, removed) = DockStripRules.removingAppsPinnedInNativeDock(
                bars[index].apps,
                nativePinnedKeys: nativeDockPinnedKeys
            )
            guard !removed.isEmpty else { continue }
            bars[index].apps = kept
            pruned += removed.count
            append(.info, L("「\(bars[index].name)」里 \(removed.count) 个 App 已固定在原生 Dock 中，已自动剔除：\(removed.map(\.label).joined(separator: "、"))",
                            "\(removed.count) app(s) in “\(bars[index].name)” are already pinned in the native Dock and were removed: \(removed.map(\.label).joined(separator: ", "))"))
        }
        guard pruned > 0 else { return 0 }
        append(.info, L("按「原生 Dock 已固定的 App 不进自定义栏」规则剔除（\(reason)）", "Removed per the “apps pinned in the native Dock stay out of custom bars” rule (\(reason))"))
        updateSettings { $0.dockBars = bars }
        secondaryDock?.refresh()
        return pruned
    }

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
        append(.warning, L("已解绑 \(orphans.count) 根失效的 Dock 栏（对应桌面已不存在，应用保留）", "Unbound \(orphans.count) orphaned Dock bar(s) (their desktops are gone; apps preserved)"))
        secondaryDock?.refresh()
        return orphans.count
    }

    /// 新增一根空栏。名字自动避开已有名字。
    @discardableResult
    func addDockBar() -> UUID {
        let bar = DockBar(name: uniqueBarName(base: "Dock \(settings.dockBars.count + 1)"))
        updateSettings { $0.dockBars.append(bar) }
        append(.info, L("已添加 Dock 栏「\(bar.name)」", "Added Dock bar “\(bar.name)”"))
        return bar.id
    }

    func removeDockBar(id: UUID) {
        guard let bar = dockBar(id: id) else { return }
        // 只有**未绑定**的栏可以删（2026-10-06 用户规格）：绑了桌面的栏要删得先解绑，
        // 否则那条桌面会突然什么都没有——这一步交给用户显式做。
        guard bar.spaceID == nil else {
            append(.warning, L("「\(bar.name)」还绑着桌面，先解绑才能删除", "“\(bar.name)” is still bound to a desktop; unbind it before deleting"))
            return
        }
        updateSettings { $0.dockBars.removeAll { $0.id == id } }
        append(.info, L("已删除 Dock 栏「\(bar.name)」", "Deleted Dock bar “\(bar.name)”"))
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
        append(.info, L("Dock 栏改名 →「\(name)」", "Dock bar renamed → “\(name)”"))
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
            append(.info, L("「\(displacedName)」让出桌面（一个桌面只挂一根栏）", "“\(displacedName)” gave up the desktop (one bar per desktop)"))
        }
        append(.info, L("Dock 栏「\(bar.name)」：\(spaceID.map { "绑定桌面 \($0)" } ?? "已解绑")",
                        "Dock bar “\(bar.name)”: \(spaceID.map { "bound to desktop \($0)" } ?? "unbound")"))
        refreshAfterBarChange(bar)
    }

    /// 编辑器专用：**只改内存**，不落盘（拖拽排序过程中会连发）。
    func updateDockBarInMemory(_ bar: DockBar) {
        guard let index = settings.dockBars.firstIndex(where: { $0.id == bar.id }) else { return }
        settings.dockBars[index] = bar
    }

    /// 一次编辑结束：落盘一次；绑定的桌面是活动桌面时按开关应用 + 刷新条。
    func dockBarEdited(_ bar: DockBar, reason: String) {
        var bar = bar
        // 落盘前最后一道闸：任何入口都不许把「已固定在原生 Dock」的 App 留在栏里
        // （编辑器已经会拦下并给警告，这里是兜底 —— 用户规格 2026-10-06）。
        let (kept, removed) = DockStripRules.removingAppsPinnedInNativeDock(
            bar.apps,
            nativePinnedKeys: settings.freezeNativeDockSwitching ? nativeDockPinnedKeys : []
        )
        if !removed.isEmpty {
            bar.apps = kept
            append(.warning, L("「\(bar.name)」里 \(removed.count) 个 App 已固定在原生 Dock 中，未加入：\(removed.map(\.label).joined(separator: "、"))",
                               "\(removed.count) app(s) for “\(bar.name)” are already pinned in the native Dock and were not added: \(removed.map(\.label).joined(separator: ", "))"))
        }
        updateDockBarInMemory(bar)
        persistConfiguration()
        append(.info, L("Dock 栏「\(bar.name)」已修改：\(reason)", "Dock bar “\(bar.name)” edited: \(reason)"))
        refreshAfterBarChange(bar)
    }

    /// 次级条右键菜单改位置（2026-10-06）：与设置页同一落点（`dockBarEdited`）——
    /// 落盘、刷新条、按开关应用全在里面。栏不存在或位置没变就静默忽略
    /// （快照可能滞后一拍，菜单上带的栏 ID 过期是正常态）。
    func setDockBarPosition(id: UUID, to position: DockBarPosition) {
        guard let current = dockBar(id: id), current.position != position else { return }
        var updated = current
        updated.position = position
        dockBarEdited(updated, reason: L("位置改为\(position.displayName)（次级条右键菜单）", "position changed to \(position.displayName) (bar context menu)"))
    }

    private func refreshAfterBarChange(_ bar: DockBar) {
        secondaryDock?.refresh()
        guard let spaceID = bar.spaceID,
            !settings.freezeNativeDockSwitching,
            settings.autoApplyOnEdit,
            let space = desktops.first(where: { $0.id == spaceID })
        else { return }
        applyConfigForDesktop(space, reason: L("Dock 栏「\(bar.name)」已修改", "Dock bar “\(bar.name)” edited"))
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
        case .bottom: return L("当前在底部（位置=底部的栏附着在 Dock 内侧）", "Currently at the bottom (bars positioned bottom attach to the Dock's inner side)")
        case .left: return L("当前在左侧（位置=左侧的栏附着在 Dock 内侧）", "Currently on the left (bars positioned left attach to the Dock's inner side)")
        case .right: return L("当前在右侧（位置=右侧的栏附着在 Dock 内侧）", "Currently on the right (bars positioned right attach to the Dock's inner side)")
        case nil: return L("位置未识别（各栏按自身位置独立贴边）", "Position unrecognized (each bar sticks to its own edge)")
        }
    }

    /// 方位短文案（应用栏页脚用）：只报方位，不解释附着规则 —— 那条解释挂在 tooltip 上。
    var dockSideShortDescription: String {
        switch dockSide {
        case .bottom: return L("在底部", "at the bottom")
        case .left: return L("在左侧", "on the left")
        case .right: return L("在右侧", "on the right")
        case nil: return L("方位未识别", "edge unrecognized")
        }
    }

    /// 读一次环境（台前调度 + 原生 Dock 方位），值变化时更新缓存并记日志。
    /// 首次读取静默（启动日志里没必要多两条）。
    func refreshEnvironment() {
        let reading = environmentReader()
        if reading.stageManagerActive != stageManagerActive {
            stageManagerActive = reading.stageManagerActive
            if hasReadEnvironment, let active = reading.stageManagerActive {
                append(.info, L("台前调度：\(active ? "开启" : "关闭")——Dock 栏可选位置已更新",
                                "Stage Manager: \(active ? "on" : "off") — available bar positions updated"))
            }
        }
        if reading.dockSide != dockSide {
            dockSide = reading.dockSide
            if hasReadEnvironment, let side = reading.dockSide {
                append(.info, L("原生 Dock 位置变化 → \(side)", "Native Dock position changed → \(side)"))
            }
        }
        hasReadEnvironment = true
    }

    /// 打开设置窗口时即刷环境（不等 2 s 轮询拍）：台前调度开关与原生 Dock 方位
    /// 决定位置选项与提示。顺带重读原生 Dock 的固定内容 —— 用户可能刚在别处
    /// （原生 Dock 上拖入/拖出）改过，编辑器要靠它拦下重复添加（2026-10-06 用户规格）。
    func prepareSettingsPresentation() {
        refreshEnvironment()
        refreshNativeDockPinnedApps(reason: L("打开设置窗口", "opening Settings"))
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

    // MARK: - 应用当前桌面的 Dock（「立即应用」）

    /// 「立即应用」：把**当前桌面绑定的 Dock 栏**内容推到真实 Dock。
    ///
    /// 2026-10-06 起没有「默认 Dock」这个自动内容源（用户指令：去掉「最近添加的应用」），
    /// 所以这个按钮只对**绑了栏**的桌面有意义；没绑栏就如实说明，不做无效动作。
    func applyActiveDesktopDock() {
        guard let space = activeSpace else {
            append(.warning, L("当前不在用户桌面上（可能是全屏 App），没有可应用的 Dock 栏", "Not on a user desktop (possibly a full-screen app); no Dock bar to apply"))
            return
        }
        guard let bar = dockBar(for: space) else {
            append(.warning, L("\(displayName(for: space)) 未绑定 Dock 栏，没有可应用的内容", "\(displayName(for: space)) has no bound Dock bar; nothing to apply"))
            return
        }
        guard !bar.apps.isEmpty else {
            append(.warning, L("Dock 栏「\(bar.name)」还没有图标，跳过应用", "Dock bar “\(bar.name)” has no icons yet; skipping apply"))
            return
        }
        applyConfigForDesktop(space, reason: L("手动应用「\(bar.name)」", "manual apply “\(bar.name)”"))
    }

    /// 「立即应用」按钮的禁用说明（nil = 可以点）。绑定栏是唯一的内容来源。
    var activeDesktopApplyBlockedReason: String? {
        guard let space = activeSpace else { return L("当前不在用户桌面上", "not on a user desktop") }
        guard let bar = dockBar(for: space) else { return L("当前桌面未绑定 Dock 栏（在「应用栏」页配一根）", "this desktop has no bound Dock bar (set one up in the Dock Bars tab)") }
        if bar.apps.isEmpty { return L("Dock 栏「\(bar.name)」还没有图标", "Dock bar “\(bar.name)” has no icons yet") }
        return nil
    }

    // MARK: - 桌面生效配置

    /// 某个桌面实际生效的 Dock 配置：**只有绑定了 Dock 栏的桌面才有**。
    /// 没绑栏 = nil —— 本 App 不生成内容、也不改写原生 Dock（2026-10-06 用户指令）。
    func effectiveConfig(for space: DesktopSpace) -> DockConfig? {
        guard let bar = dockBar(for: space) else { return nil }
        return DockConfig(pinnedApps: bar.apps, otherItems: bar.otherItems)
    }

    /// 应用某个桌面实际生效的 Dock。**没绑栏的桌面没有可应用的内容**（什么都不写）。
    func applyConfigForDesktop(_ space: DesktopSpace, reason: String) {
        guard let config = effectiveConfig(for: space) else {
            append(.info, L("\(displayName(for: space)) 未绑定 Dock 栏，原生 Dock 保持原样", "\(displayName(for: space)) has no bound Dock bar; the native Dock is left as is"))
            return
        }
        guard !config.pinnedApps.isEmpty else {
            append(.warning, L("\(displayName(for: space)) 的 Dock 栏是空的，跳过应用 —— 先给它配图标", "\(displayName(for: space))'s Dock bar is empty; skipping apply — add icons first"))
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
            append(.info, L("原生 Dock 已冻结：跳过「\(reason)」，由次级 Dock 条呈现", "Native Dock is frozen: skipping “\(reason)”; the secondary Dock bar presents it"))
            return
        }
        applyConfigForDesktop(space, reason: reason)
    }

    /// 「冻结原生 Dock 逐桌面切换」开关（设置页调用）。
    ///
    /// 2026-10-06 起没有「默认 Dock」可对齐了，语义因此最诚实：
    /// **开 = 本 App 不再改写原生 Dock**（原生 Dock 保持用户自己现在的样子，切桌面零写入）；
    /// **关 = 恢复逐桌面写绑定栏**。
    func setFreezeNativeDockSwitching(_ enabled: Bool) {
        guard settings.freezeNativeDockSwitching != enabled else { return }
        updateSettings { $0.freezeNativeDockSwitching = enabled }
        secondaryDock?.refresh()
        // 冻结打开 = 原生 Dock 从此归用户，排除集开始生效（并就地剔除栏里的重复项）；
        // 关闭 = 原生 Dock 由我们写，排除集清空（否则会把自己的内容当成"原生固定"剔掉）。
        refreshNativeDockPinnedApps(reason: enabled ? L("开启冻结", "freeze enabled") : L("关闭冻结", "freeze disabled"))
        if !enabled, let space = activeSpace {
            applyForDesktopSwitch(space, reason: L("解冻：恢复逐桌面切换", "unfreeze: restore per-desktop switching"))
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
            append(.info, L("「识别手动改动并回存」已关闭，忽略这次改动", "“Detect manual edits and save back” is off; ignoring this change"))
            return
        }
        // 回存期间不能让 watcher 把这次写入又当成新的用户改动。
        dockWatcher?.stop()
        defer {
            dockWatcher?.acknowledge(dockController.appliedComparableFingerprint)
            dockWatcher?.start()
        }

        if settings.freezeNativeDockSwitching {
            append(.info, L("冻结模式：本 App 不改写原生 Dock，手动改动不回存", "Frozen mode: the app doesn't rewrite the native Dock; manual edits aren't saved back"))
            // 改动可能正是"往原生 Dock 里钉了一个 App" —— 重算固定集，栏里若因此出现
            // 重复项就地剔除（用户规格 2026-10-06）。不写偏好，只动配置。
            refreshNativeDockPinnedApps(reason: L("原生 Dock 手动改动", "manual change in the native Dock"))
            return
        }

        guard let space = activeSpace else {
            append(.info, L("当前不在用户桌面上（可能是全屏 App），手动改动不回存", "Not on a user desktop (possibly a full-screen app); manual edits aren't saved back"))
            return
        }
        guard var bar = dockBar(for: space) else {
            append(.info, L("当前桌面未绑定 Dock 栏，手动改动不回存（本 App 只回存到绑定栏）", "This desktop has no bound Dock bar; manual edits aren't saved back (save-backs only target bound bars)"))
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
        append(.info, L("已回存到 Dock 栏「\(bar.name)」（\(bar.apps.count) 个图标）", "Saved back to Dock bar “\(bar.name)” (\(bar.apps.count) icons)"))
        if settings.autoApplyOnEdit {
            applyConfigForDesktop(space, reason: L("回存手动改动", "save back manual edits"))
        }
    }

    // MARK: - 撤销自动回存

    /// 回存落点与 `handleUserDockEdit` 同一口径：活动桌面绑定的栏。
    /// 没有绑定栏 = 没有可撤销的落点（本 App 不回存到别处）。
    private func captureTargetKey(for space: DesktopSpace?) -> String? {
        guard let space, let bar = dockBar(for: space) else { return nil }
        return bar.id.uuidString
    }

    /// 回存永远落在**活动桌面**上，所以撤销的落点也按活动桌面算，不能由 UI 传。
    func canUndoAutoCapture() -> Bool {
        guard let key = captureTargetKey(for: activeSpace) else { return false }
        return editHistory.canUndo(for: key)
    }

    /// 撤销上一次自动回存。返回是否真的撤了。
    @discardableResult
    func undoLastAutoCapture() -> Bool {
        guard let key = captureTargetKey(for: activeSpace),
              let barID = UUID(uuidString: key),
              var bar = dockBar(id: barID),
              let previous = editHistory.pop(for: key)
        else { return false }
        bar.apps = previous.pinnedApps
        bar.otherItems = previous.otherItems
        dockBarEdited(bar, reason: L("撤销上一次自动回存", "undo last auto save-back"))
        return true
    }

    // MARK: - 生命周期

    func start() {
        append(.info, L("MultiDock 启动", "MultiDock launched"))
        append(.info, L("系统 \(ProcessInfo.processInfo.operatingSystemVersionString)", "System \(ProcessInfo.processInfo.operatingSystemVersionString)"))
        // 界面语言留痕：真机核对「语言怎么没切」只看得到这一份日志（见 L10n 注释）。
        append(.info, L("界面语言：中文（可在系统设置里按 App 指定）", "UI language: English (per-app language can be set in System Settings)"))

        if spaceProviderAvailable {
            append(.info, L("SkyLight 私有 API 加载成功", "SkyLight private API loaded"))
        } else {
            append(.error, spaceProviderWarning ?? L("SkyLight 不可用", "SkyLight unavailable"))
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
        append(.info, L("桌面观察已启动（300 ms 轮询 + 通知）", "Desktop observation started (300 ms polling + notifications)"))
        append(.info, L("识别到 \(observer.desktops.count) 个用户桌面", "Detected \(observer.desktops.count) user desktop(s)"))
        for space in observer.desktops {
            let bar = dockBar(for: space)
            append(.info, "  · \(displayName(for: space)) uuid=\(space.spaceUUID) id64=\(space.id64)"
                + (bar.map { L("（Dock 栏「\($0.name)」）", " (Dock bar “\($0.name)”)") } ?? L("（未绑定栏）", " (no bound bar)")))
        }
        if let active = observer.activeSpace {
            append(.info, L("当前桌面：\(displayName(for: active)) / id64=\(active.id64)", "Current desktop: \(displayName(for: active)) / id64=\(active.id64)"))
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
        // **不再有启动对齐**（2026-10-06）：没有「默认 Dock」要对齐了 ——
        // 冻结模式本 App 就不写原生 Dock，未冻结模式由观察器首个采样驱动逐桌面应用。
    }

    func stop() {
        observer.stop()
        dockWatcher?.stop()
        dockPresenceMonitor?.stop()
        secondaryDock?.stop()
        environmentTask?.cancel()
        environmentTask = nil
        append(.info, L("桌面观察已停止", "Desktop observation stopped"))
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
                append(.warning, L("上次未正常退出（PID \(stale.pid)），Dock 可能没还原 —— 启动后自动还原", "Last quit was abnormal (PID \(stale.pid)); the Dock may not have been restored — restoring automatically after launch"))
            } else {
                append(.info, L("发现上次未正常退出的残留标记，但上次未改动过 Dock，无需还原", "Found a stale marker from an abnormal quit, but the Dock wasn't changed; nothing to restore"))
            }
            baselineStore.clearSessionMarker()
        }

        do {
            baselineCapturedThisLaunch = try baselineStore.captureBaselineIfNeeded()
            if baselineCapturedThisLaunch {
                append(.info, L("已把当前 Dock 存为基准快照（首次运行，此后不再覆盖）", "Saved the current Dock as the baseline snapshot (first run; never overwritten afterwards)"))
            } else {
                append(.info, L("基准快照已存在，沿用不改", "Baseline snapshot already exists; kept as is"))
            }
        } catch {
            append(.error, L("基准快照写入失败：\(error.localizedDescription)", "Failed to write the baseline snapshot: \(error.localizedDescription)"))
        }
    }

    /// 配置归一化与迁移（**加载与导入共用一条路径**，两处各写一份迟早不一致）：
    /// 旧 override → 栏迁移（仅当还没有任何栏）、补足默认 5 栏、清掉废弃的 override 残留、
    /// 截断超长名并丢掉无名绑定。
    private func normalizePayload(_ payload: ConfigStore.Payload)
        -> (settings: AppSettings, bindings: [DesktopBinding], migratedBarCount: Int)
    {
        var settings = payload.settings
        var bindings = payload.bindings
        var migratedBarCount = 0
        if settings.dockBars.isEmpty {
            let migrated = DockBarCatalog.migratedBars(from: bindings)
            if !migrated.isEmpty {
                migratedBarCount = migrated.count
                for index in bindings.indices { bindings[index].override = nil }
            }
            settings.dockBars = DockBarCatalog.paddedToDefault(migrated)
        }
        let normalized = DesktopNaming.normalizedBindings(bindings)
        return (settings, normalized, migratedBarCount)
    }

    private func loadConfiguration() {
        let payload = configStore.load()
        let needsFormatUpgrade = payload.settings.dockBars.isEmpty
        let (loadedSettings, normalizedBindings, migratedBarCount) = normalizePayload(payload)
        if migratedBarCount > 0 {
            append(.info, L("已把 \(migratedBarCount) 条逐桌面 Dock 配置迁移为 Dock 栏", "Migrated \(migratedBarCount) per-desktop Dock config(s) into Dock bars"))
        }
        if normalizedBindings.count != payload.bindings.count {
            append(.warning, L("配置里有 \(payload.bindings.count - normalizedBindings.count) 条空绑定（没有名字），已清理", "Config had \(payload.bindings.count - normalizedBindings.count) empty binding(s) (no name); cleaned up"))
        }
        settings = loadedSettings
        bindings = normalizedBindings
        // v4 迁移/补栏发生时把配置格式一次性升上去（此后用户删光栏也不会再补）。
        // 落盘放在 self.bindings 赋值**之后**（persistConfiguration 用的是实例属性）。
        if needsFormatUpgrade {
            persistConfiguration()
        }
        append(.info, L("配置已载入：\(settings.dockBars.count) 根 Dock 栏、\(normalizedBindings.count) 条桌面命名", "Config loaded: \(settings.dockBars.count) Dock bar(s), \(normalizedBindings.count) desktop name(s)"))
        // 老配置里可能带着"原生 Dock 也有"的 App（本规则上线前加的）——载入时就地剔除。
        refreshNativeDockPinnedApps(reason: L("载入配置", "loading config"))
    }

    func persistConfiguration() {
        do {
            try configStore.save(.init(bindings: bindings, settings: settings))
        } catch {
            append(.error, L("配置保存失败：\(error.localizedDescription)", "Failed to save config: \(error.localizedDescription)"))
        }
    }

    // MARK: - 动作

    func switchToNextDesktop() {
        guard spaceProviderAvailable else {
            append(.error, L("桌面切换不可用：\(spaceProviderWarning ?? "未知原因")", "Desktop switching unavailable: \(spaceProviderWarning ?? "unknown reason")"))
            return
        }
        // **预应用**（计划 §3.4 第 8 条）：先算出目标、把它的 Dock 推下去，再切空间 ——
        // 切换动画结束时 Dock 已经是正确状态，不用等轮询发现变化才动。
        guard let target = switcher.target(.next) else {
            append(.warning, L("没有可切换的下一个桌面（当前显示器只有 1 个桌面，或尚未识别到活动桌面）", "No next desktop to switch to (this display has only one desktop, or the active desktop isn't known yet)"))
            return
        }
        applyForDesktopSwitch(target, reason: L("预应用：切到 \(displayName(for: target))", "pre-apply: switch to \(displayName(for: target))"))
        // 相邻一步可合成（借系统过渡动画）——**由配置开关控制，默认关**（实验 28：
        // 本机事件投递被拦，开了也没动画）。权限/相邻条件不满足时 SpaceSwitcher 内部回落硬切。
        let style: SpaceSwitcher.SwitchStyle =
            settings.animatedDesktopSwitch ? .animatedStep(.next) : .hard
        guard switcher.switchTo(target, style: style) != nil else {
            append(.warning, L("切换到 \(displayName(for: target)) 失败", "Failed to switch to \(displayName(for: target))"))
            return
        }
        append(.info, L("切换到 \(displayName(for: target))（id64=\(target.id64)）", "Switched to \(displayName(for: target)) (id64=\(target.id64))"))
    }

    /// ⇧ + 左键：切到上一个桌面。与 `switchToNextDesktop` 完全对称（同一条预应用链路）。
    func switchToPreviousDesktop() {
        guard spaceProviderAvailable else {
            append(.error, L("桌面切换不可用：\(spaceProviderWarning ?? "未知原因")", "Desktop switching unavailable: \(spaceProviderWarning ?? "unknown reason")"))
            return
        }
        guard let target = switcher.target(.previous) else {
            append(.warning, L("没有可切换的上一个桌面（当前显示器只有 1 个桌面，或尚未识别到活动桌面）", "No previous desktop to switch to (this display has only one desktop, or the active desktop isn't known yet)"))
            return
        }
        applyForDesktopSwitch(target, reason: L("预应用：切到 \(displayName(for: target))", "pre-apply: switch to \(displayName(for: target))"))
        let style: SpaceSwitcher.SwitchStyle =
            settings.animatedDesktopSwitch ? .animatedStep(.previous) : .hard
        guard switcher.switchTo(target, style: style) != nil else {
            append(.warning, L("切换到 \(displayName(for: target)) 失败", "Failed to switch to \(displayName(for: target))"))
            return
        }
        append(.info, L("切到上一个桌面：\(displayName(for: target))（id64=\(target.id64)）", "Switched to previous desktop: \(displayName(for: target)) (id64=\(target.id64))"))
    }

    func switchTo(_ space: DesktopSpace) {
        guard spaceProviderAvailable else {
            append(.error, L("桌面切换不可用：\(spaceProviderWarning ?? "未知原因")", "Desktop switching unavailable: \(spaceProviderWarning ?? "unknown reason")"))
            return
        }
        applyForDesktopSwitch(space, reason: L("预应用：切到 \(displayName(for: space))", "pre-apply: switch to \(displayName(for: space))"))
        guard switcher.switchTo(space) != nil else {
            append(.warning, L("切换到 \(displayName(for: space)) 失败", "Failed to switch to \(displayName(for: space))"))
            return
        }
        append(.info, L("切换到 \(displayName(for: space))（id64=\(space.id64)）", "Switched to \(displayName(for: space)) (id64=\(space.id64))"))
    }

    func refreshDesktops() {
        observer.refreshNow()
        append(.info, L("手动刷新桌面列表：\(desktops.count) 个用户桌面", "Manual desktop list refresh: \(desktops.count) user desktop(s)"))
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
        append(.info, L("显示器配置变化：桌面列表已刷新（\(before) → \(desktops.count) 个）", "Display configuration changed: desktop list refreshed (\(before) → \(desktops.count))"))
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

    /// 应用一套配置。连击会被合并，只对最终落点执行一次。
    func applyDock(_ config: DockConfig, reason: String) {
        guard !config.pinnedApps.isEmpty else {
            append(.warning, L("配置里没有图标，跳过「\(reason)」", "Config has no icons; skipping “\(reason)”"))
            return
        }
        append(.info, L("准备应用 Dock（\(reason)）：\(config.pinnedApps.count) 个图标，重载方式 \(settings.reloadStrategy.displayName)", "Preparing to apply the Dock (\(reason)): \(config.pinnedApps.count) icons, reload method \(settings.reloadStrategy.displayName)"))
        dockController.request(config, reason: reason, strategy: settings.reloadStrategy)
    }

    /// 把此刻真实的 Dock 读成一套配置（测试与回存用）。
    ///
    /// 走 `dockController` 而不是直接读静态的 `DockPreferences`，否则会绕过注入点 ——
    /// 测试里就会读到真实系统的偏好域。
    func captureLiveDockConfig() -> DockConfig? {
        guard let live = dockController.captureLiveConfig() else {
            append(.error, L("读不到 com.apple.dock，无法抓取", "Can't read com.apple.dock; nothing to capture"))
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
            append(.info, L("冻结模式：原生 Dock 就是自动生成的默认内容，没有「本桌面配置」可重置", "Frozen mode: the native Dock is the default content; there is no per-desktop config to reset"))
            return
        }
        guard let space = activeSpace, var bar = dockBar(for: space) else {
            append(.info, L("当前桌面未绑定 Dock 栏，没有可重置的配置", "This desktop has no bound Dock bar; nothing to reset"))
            return
        }
        bar.apps = Array(live.pinnedApps.prefix(DockBar.maxApps))
        bar.otherItems = live.otherItems
        dockBarEdited(bar, reason: L("用当前 Dock 重置（\(live.pinnedApps.count) 个图标）", "reset from the current Dock (\(live.pinnedApps.count) icons)"))
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
            append(.error, L("找不到基准快照（\(baselineStore.baselineURL.path)），无法还原", "Baseline snapshot not found (\(baselineStore.baselineURL.path)); can't restore"))
            return nil
        }
        let config = DockConfig.read(from: baseline)
        let extraEntries = baseline.filter { DockPreferences.whitelistedKeys.contains($0.key) }

        // 已经与基准一致就什么都不做 —— 省掉一次没必要的 Dock 重启（退出时会明显拖慢）。
        if liveMatchesBaseline(baseline) {
            append(.info, L("当前 Dock 已与基准一致，跳过还原（不重启 Dock）", "The Dock already matches the baseline; skipping restore (no Dock restart)"))
            return DockController.Outcome(
                result: .skippedIdentical, reason: L("还原到原始 Dock", "restore to original Dock"), reload: nil, writtenKeys: 0,
                verifyAttempts: 0, elapsed: 0, note: nil, fingerprint: config.fingerprint
            )
        }

        append(.info, L("开始还原到原始 Dock：\(config.pinnedApps.count) 个图标", "Restoring to the original Dock: \(config.pinnedApps.count) icons"))
        let outcome = await dockController.apply(
            config,
            reason: L("还原到原始 Dock", "restore to original Dock"),
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
            append(.info, L("已把当前 Dock 设为新基准", "The current Dock is now the new baseline"))
        } catch {
            append(.error, L("更新基准失败：\(error.localizedDescription)", "Failed to update the baseline: \(error.localizedDescription)"))
        }
    }

    private func handleDockOutcome(_ outcome: DockController.Outcome) {
        lastApplySummary = outcome.summary
        switch outcome.result {
        case .applied:
            append(.info, L("Dock 应用成功：\(outcome.summary)", "Dock applied: \(outcome.summary)"))
            hasAppliedDockConfig = true
            onDockApplied?(outcome.fingerprint)
            // 告诉 watcher「这次变化是我们自己造成的」，别当成用户手动改动。
            dockWatcher?.acknowledge(dockController.appliedComparableFingerprint)
            refreshDockCapabilities()
        case .skippedIdentical:
            append(.info, L("Dock 内容与当前一致，未写入也未重启（\(outcome.reason)）", "Dock content already matches; nothing written or restarted (\(outcome.reason))"))
        case .failed:
            append(.error, L("Dock 应用失败：\(outcome.summary)", "Dock apply failed: \(outcome.summary)"))
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
        append(.warning, L("开始自愈还原：上次（PID \(stale.pid)）没走完退出还原", "Starting self-heal restore: the last run (PID \(stale.pid)) didn't finish restore-on-quit"))
        let outcome = await restoreToBaseline()
        pendingSelfHeal = nil

        guard let outcome else {
            selfHealSummary = L("自愈还原失败（读不到基准快照）", "Self-heal restore failed (can't read the baseline snapshot)")
            append(.error, L("自愈还原失败：读不到基准快照 \(baselineStore.baselineURL.path)", "Self-heal restore failed: can't read the baseline snapshot \(baselineStore.baselineURL.path)"))
            return
        }
        switch outcome.result {
        case .applied:
            selfHealSummary = L("已自动还原上次未还原的 Dock", "Restored the Dock left over from the last abnormal quit")
            append(.info, L("自愈还原完成：\(outcome.summary)", "Self-heal restore finished: \(outcome.summary)"))
            toastPresenter?.announce(L("已自动还原上次未还原的 Dock", "Restored the Dock left over from the last abnormal quit"))
        case .skippedIdentical:
            selfHealSummary = L("Dock 已与原始状态一致，无需还原", "The Dock already matches the original state; nothing to restore")
            append(.info, L("自愈检查：真实 Dock 已经与基准一致，不用动它", "Self-heal check: the real Dock already matches the baseline; leaving it alone"))
        case .failed:
            selfHealSummary = L("自愈还原失败，请手动还原", "Self-heal restore failed; restore manually")
            append(.error, L("自愈还原失败，请到设置页点「立即还原到原始 Dock」", "Self-heal restore failed; click “Restore Original Dock” in Settings"))
        }
    }

    /// Dock 存活监视（P4 验收第 4 条）。Dock 被外部弄死时拉回来。
    private func startDockWatcher() {
        guard settings.autoCaptureUserEdits else {
            append(.info, L("「识别真实 Dock 上的手动改动并回存」已关闭，不启动监视", "“Detect manual edits in the real Dock and save back” is off; watcher not started"))
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
            self.append(.error, L("\(reason)。建议到「数据 → 备份与还原」恢复一份历史备份，或直接点「立即还原到原始 Dock」", "\(reason). Restore a backup from Data → Backups & Restore, or click “Restore Original Dock”"))
        }
        monitor.onRevived = { [weak self] count in
            guard let self else { return }
            self.dockFailureWarning = nil
            self.append(.info, L("Dock 已恢复（第 \(count) 次），警告解除", "Dock is back (recovery #\(count)); warning cleared"))
            self.toastPresenter?.announce(L("Dock 已恢复", "Dock is back"))
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
            append(.warning, L("Dock 存活监视未启动，无法重试拉回", "Dock presence monitor isn't running; can't retry the pull-back"))
            return false
        }
        let started = monitor.reviveNow()
        append(started ? .info : .warning,
               started ? L("已手动重试拉回 Dock，等下一次轮询确认", "Manual pull-back retry sent; waiting for the next poll to confirm") : L("手动重试拉回失败（launchctl 没跑起来）", "Manual pull-back retry failed (launchctl didn't run)"))
        return started
    }

    /// 「根据最近使用自动重排空间」。**只在用户主动点开关时调用**，不静默修改（计划 §1 风险项）。
    func setMRUSpaces(_ enabled: Bool) {
        let previous = mruSpaces
        guard dockController.writeMRUSpaces(enabled) else {
            mruSpaces = dockController.readMRUSpaces()
            append(.error, L("写 mru-spaces 失败（可能被系统策略锁住），保持原值", "Failed to write mru-spaces (possibly locked by policy); keeping the old value"))
            return
        }
        mruSpaces = enabled
        append(.info, L("mru-spaces：\(previous.map(String.init) ?? "未知") → \(enabled)",
                        "mru-spaces: \(previous.map(String.init) ?? "unknown") → \(enabled)"))
        // 这个键不在白名单里，`apply` 管不到它 —— 只能单独重启一次 Dock 让它生效。
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.dockController.reloadOnly(strategy: self.settings.reloadStrategy)
            self.append(.info, L("mru-spaces 生效重载：\(outcome.description)", "mru-spaces reload: \(outcome.description)"))
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
            append(.error, L("备份 \(entry.fileName) 读不出来或已损坏，未做任何改动", "Backup \(entry.fileName) is unreadable or corrupt; nothing changed"))
            return
        }
        let config = DockConfig.read(from: domain)
        append(.info, L("恢复备份 \(entry.fileName)：\(config.pinnedApps.count) 个图标", "Restoring backup \(entry.fileName): \(config.pinnedApps.count) icons"))
        applyDock(config, reason: L("恢复备份 \(entry.fileName)", "restore backup \(entry.fileName)"))
    }

    /// 登录启动状态（设置页显示）。真正的注册/注销在 `LoginItem`。
    func refreshLoginItemStatus() {
        loginItemStatus = LoginItem.statusDescription()
    }

    /// 开/关登录启动。用户主动点开关才会走到这里。
    func setLoginItemEnabled(_ enabled: Bool) {
        do {
            let how = enabled ? try LoginItem.enable() : try LoginItem.disable()
            append(.info, L("登录启动：\(enabled ? "开启" : "关闭") —— \(how)", "Launch at Login: \(enabled ? "on" : "off") — \(how)"))
        } catch {
            append(.error, L("登录启动设置失败：\(error.localizedDescription)", "Failed to change Launch at Login: \(error.localizedDescription)"))
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
        append(.info, L("桌面命名：\(previous) → 「\(displayName(for: space))」", "Desktop renamed: \(previous) → “\(displayName(for: space))”"))
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
        guard let space, var bar = dockBar(for: space), !bar.apps.isEmpty else { return nil }
        // 展示路径也过一道「原生 Dock 已固定的不进自定义栏」——配置在运行期被外部改过
        // （导入、手编 config.json）时，条上不该先冒出来再等剔除（用户规格 2026-10-06）。
        if settings.freezeNativeDockSwitching, !nativeDockPinnedKeys.isEmpty {
            bar.apps = DockStripRules.removingAppsPinnedInNativeDock(
                bar.apps,
                nativePinnedKeys: nativeDockPinnedKeys
            ).kept
            guard !bar.apps.isEmpty else { return nil }
        }
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
        snapshot.barID = bar.id
        return snapshot
    }

    // MARK: - 启动台（macOS 26 以下；「启动台」Tab）

    /// 重读启动台数据库并解析（打开「启动台」页时调用，「刷新」按钮也走它）。
    ///
    /// 系统闸门在最前：macOS 26 起没有启动台，状态直接给 `.unsupportedSystem`，
    /// 连数据库路径都不碰。读 + 解析都在主线程（一次全量读实测毫秒级；兜底的
    /// bundle id 索引只在有记录定位不到时才扫盘）。
    func refreshLaunchpadFolders() {
        guard launchpadLoader.isSystemSupported() else {
            launchpadFolders = []
            launchpadStatus = .unsupportedSystem
            logLaunchpadOnce(
                key: "unsupported",
                level: .info,
                message: L("本机系统没有启动台（macOS 26 起由「应用程序」取代），「启动台」页不可用",
                           "This macOS has no Launchpad (replaced by Applications in macOS 26); the Launchpad tab is unavailable")
            )
            return
        }
        do {
            let records = try launchpadLoader.loadRecords()
            launchpadFolders = launchpadLoader.resolve(records)
            launchpadStatus = .loaded
            let appCount = launchpadFolders.reduce(0) { $0 + $1.apps.count }
            logLaunchpadOnce(
                key: "ok-\(launchpadFolders.count)-\(appCount)",
                level: .info,
                message: L("启动台：读到 \(launchpadFolders.count) 个文件夹、共 \(appCount) 个 App",
                           "Launchpad: \(launchpadFolders.count) folder(s), \(appCount) app(s)")
            )
        } catch let error as LaunchpadDatabaseError {
            launchpadFolders = []
            launchpadStatus = .unavailable(error.userMessage)
            logLaunchpadOnce(key: "err-\(error.userMessage)", level: .warning, message: error.userMessage)
        } catch {
            launchpadFolders = []
            launchpadStatus = .unavailable(error.localizedDescription)
            logLaunchpadOnce(
                key: "err-\(error.localizedDescription)",
                level: .warning,
                message: L("启动台读取失败：\(error.localizedDescription)", "Launchpad read failed: \(error.localizedDescription)")
            )
        }
    }

    /// 同一结果只记一次日志（每次切回本页都会重读；重复灌日志没有信息量）。
    private func logLaunchpadOnce(key: String, level: LogEntry.Level, message: String) {
        guard lastLaunchpadLogKey != key else { return }
        lastLaunchpadLogKey = key
        append(level, message)
    }

    /// 「添加到某个 Dock」：把启动台文件夹里的 App **并入**目标栏末尾。
    func addLaunchpadFolder(_ folder: LaunchpadFolder, to barID: UUID) -> LaunchpadOperationOutcome {
        guard let bar = dockBar(id: barID) else {
            return launchpadFailure(L("目标 Dock 栏已不存在（可能在别处删掉了）", "The target Dock bar no longer exists (it may have been deleted elsewhere)"))
        }
        let (apps, report) = LaunchpadImport.appended(
            existing: bar.apps,
            folder: folder,
            pinnedIn: launchpadPinnedKeysForImport()
        )
        guard report.addedCount > 0 else {
            let reason: String
            if folder.apps.isEmpty {
                reason = L("这个文件夹是空的", "the folder is empty")
            } else if folder.resolvedApps.isEmpty {
                reason = L("文件夹里的 App 在这台机器上都定位不到", "none of the folder's apps could be located on this Mac")
            } else {
                reason = L("没有可添加的 App", "nothing could be added")
            }
            return launchpadFailure(
                L("启动台「\(folder.displayName)」→「\(bar.name)」：\(reason)", "Launchpad “\(folder.displayName)” → “\(bar.name)”: \(reason)")
                    + launchpadSkipSuffix(report)
            )
        }
        var updated = bar
        updated.apps = apps
        dockBarEdited(updated, reason: L("从启动台「\(folder.displayName)」添加 \(report.addedCount) 个 App",
                                         "added \(report.addedCount) app(s) from Launchpad “\(folder.displayName)”"))
        let message = L("已把启动台「\(folder.displayName)」的 \(report.addedCount) 个 App 添加到「\(bar.name)」",
                        "Added \(report.addedCount) app(s) from Launchpad “\(folder.displayName)” to “\(bar.name)”")
            + launchpadSkipSuffix(report)
        append(.info, message)
        return LaunchpadOperationOutcome(message: message, failed: false)
    }

    /// 「替换某个 Dock」：清空目标栏，换成启动台文件夹的内容。
    func replaceDockBar(_ barID: UUID, withLaunchpadFolder folder: LaunchpadFolder) -> LaunchpadOperationOutcome {
        guard let bar = dockBar(id: barID) else {
            return launchpadFailure(L("目标 Dock 栏已不存在（可能在别处删掉了）", "The target Dock bar no longer exists (it may have been deleted elsewhere)"))
        }
        let (apps, report) = LaunchpadImport.replaced(
            folder: folder,
            pinnedIn: launchpadPinnedKeysForImport()
        )
        guard !apps.isEmpty else {
            return launchpadFailure(
                L("没有替换：「\(folder.displayName)」里没有可用的 App", "Nothing replaced: “\(folder.displayName)” has no usable apps")
                    + launchpadSkipSuffix(report)
            )
        }
        let before = DockStripRules.barApps(bar.apps)
        guard apps != before else {
            return LaunchpadOperationOutcome(
                message: L("「\(bar.name)」已经就是这个文件夹的内容，未做改动", "“\(bar.name)” already matches this folder; nothing changed"),
                failed: false
            )
        }
        var updated = bar
        updated.apps = apps
        dockBarEdited(updated, reason: L("用启动台「\(folder.displayName)」替换（\(before.count) → \(apps.count) 个图标）",
                                         "replaced with Launchpad “\(folder.displayName)” (\(before.count) → \(apps.count) icons)"))
        let message = L("已用启动台「\(folder.displayName)」替换「\(bar.name)」：\(before.count) 个图标 → \(apps.count) 个",
                        "Replaced “\(bar.name)” with Launchpad “\(folder.displayName)”: \(before.count) → \(apps.count) icons")
            + launchpadSkipSuffix(report)
        append(.info, message)
        return LaunchpadOperationOutcome(message: message, failed: false)
    }

    /// 搬运的排除集：**冻结模式才有意义** —— 未冻结时原生 Dock 的内容就是我们写下去的
    /// 栏内容，拿它当排除集会把栏自己清空（与 `nativeDockPinnedKeys` 同一口径）。
    private func launchpadPinnedKeysForImport() -> Set<String> {
        settings.freezeNativeDockSwitching ? nativeDockPinnedKeys : []
    }

    private func launchpadFailure(_ message: String) -> LaunchpadOperationOutcome {
        append(.warning, message)
        return LaunchpadOperationOutcome(message: message, failed: true)
    }

    /// 跳过项的说明后缀（重复 / 原生已固定 / 定位不到 / 超上限），没有跳过项时为空串。
    private func launchpadSkipSuffix(_ report: LaunchpadImport.Report) -> String {
        var parts: [String] = []
        if report.duplicateCount > 0 {
            parts.append(L("\(report.duplicateCount) 个栏里已有", "\(report.duplicateCount) already in the bar"))
        }
        if !report.pinnedSkipped.isEmpty {
            parts.append(L("\(report.pinnedSkipped.count) 个已固定在原生 Dock", "\(report.pinnedSkipped.count) pinned in the native Dock"))
        }
        if !report.unresolvedTitles.isEmpty {
            parts.append(L("\(report.unresolvedTitles.count) 个定位不到", "\(report.unresolvedTitles.count) not found on disk"))
        }
        if report.overLimitCount > 0 {
            parts.append(L("\(report.overLimitCount) 个超出 \(DockBar.maxApps) 个上限", "\(report.overLimitCount) over the \(DockBar.maxApps)-icon limit"))
        }
        guard !parts.isEmpty else { return "" }
        return L("（跳过：\(parts.joined(separator: "、"))）", " (skipped: \(parts.joined(separator: ", ")))")
    }

    // MARK: - 数据（导出 / 导入，数据 Tab）

    /// 导出当前全部设置（Dock 栏、绑定、命名、各开关）为 JSON——与 config.json 同构，
    /// 导出的文件可直接再导入。
    @discardableResult
    func exportConfiguration(to url: URL) -> Bool {
        do {
            let data = try configStore.encode(.init(bindings: bindings, settings: settings))
            try data.write(to: url)
            lastDataOperationMessage = L("已导出到 \(url.path)", "Exported to \(url.path)")
            lastDataOperationFailed = false
            append(.info, L("配置已导出：\(url.path)（\(settings.dockBars.count) 根栏、\(bindings.count) 条命名）", "Config exported: \(url.path) (\(settings.dockBars.count) bars, \(bindings.count) names)"))
            return true
        } catch {
            lastDataOperationMessage = L("导出失败：\(error.localizedDescription)", "Export failed: \(error.localizedDescription)")
            lastDataOperationFailed = true
            append(.error, L("配置导出失败：\(error.localizedDescription)", "Config export failed: \(error.localizedDescription)"))
            return false
        }
    }

    /// 导入配置：**整份替换**当前设置（走与启动加载同一套归一化/迁移），落盘。
    ///
    /// 次级条与绑定导入即生效（refresh）；**不自动应用原生 Dock**——由「立即应用」/
    /// 切桌面 / 下次启动跟上；冻结开关方向变了则按同一入口把原生 Dock 掰到新模式
    /// （否则导入后会出现"原生 Dock 与次级条各显一套"——rules.md 冻结语义缺口的复刻）。
    @discardableResult
    func importConfiguration(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            recordDataOperation(L("读不到文件：\(url.path)", "Can't read file: \(url.path)"), failed: true)
            append(.error, L("配置导入失败：读不到 \(url.path)", "Config import failed: can't read \(url.path)"))
            return false
        }
        let payload: ConfigStore.Payload
        do {
            payload = try configStore.decode(from: data)
        } catch {
            recordDataOperation(L("不是有效的 MultiDock 配置文件（解码失败）", "Not a valid MultiDock configuration file (decode failed)"), failed: true)
            append(.error, L("配置导入失败：解码失败（\(error.localizedDescription)）——请确认文件来自本 App 的导出", "Config import failed: decode error (\(error.localizedDescription)) — make sure the file was exported by this app"))
            return false
        }

        let previousFreeze = settings.freezeNativeDockSwitching
        let (importedSettings, normalizedBindings, migratedBarCount) = normalizePayload(payload)
        settings = importedSettings
        bindings = normalizedBindings
        persistConfiguration()

        refreshDockCapabilities()
        // 导入的栏里可能带着"原生 Dock 也有"的 App —— 按同一套规则清洗（用户规格 2026-10-06）。
        refreshNativeDockPinnedApps(reason: L("导入配置", "importing config"))
        secondaryDock?.refresh()
        // 解冻方向要恢复逐桌面写（开向 = 不再写，无需动作）。
        if settings.freezeNativeDockSwitching != previousFreeze,
           !settings.freezeNativeDockSwitching,
           let space = activeSpace {
            applyForDesktopSwitch(space, reason: L("导入配置：解冻恢复逐桌面切换", "import config: unfreeze, restore per-desktop switching"))
        }

        append(.info, L("配置已导入：\(settings.dockBars.count) 根 Dock 栏、\(normalizedBindings.count) 条桌面命名", "Config imported: \(settings.dockBars.count) Dock bar(s), \(normalizedBindings.count) desktop name(s)")
            + (migratedBarCount > 0 ? L("（迁移 \(migratedBarCount) 条旧 override）", " (migrated \(migratedBarCount) legacy override(s))") : ""))
        recordDataOperation(
            L("已导入：\(settings.dockBars.count) 根 Dock 栏、\(normalizedBindings.count) 条桌面命名。", "Imported: \(settings.dockBars.count) Dock bar(s), \(normalizedBindings.count) desktop name(s). ")
                + L("次级条已生效；原生 Dock 由「立即应用」/ 切桌面 / 下次启动跟上。", "Secondary bars are active; the native Dock follows via “Apply” / desktop switching / next launch."),
            failed: false
        )
        return true
    }

    private func recordDataOperation(_ message: String, failed: Bool) {
        lastDataOperationMessage = message
        lastDataOperationFailed = failed
    }

    // MARK: - 更新检查（关于 Tab）

    /// 注入发布读取器（AppDelegate 组装真实实现；测试注入假值，不碰网络）。
    func configureUpdateChecking(_ fetcher: @escaping @Sendable () async -> UpdateCheckOutcome) {
        releaseFetcher = fetcher
    }

    /// 关于页首次出现时自动检查（每次启动最多一次）；手动按钮随时可再查。
    func checkForUpdatesOncePerLaunch() {
        guard !hasAutoCheckedForUpdates else { return }
        hasAutoCheckedForUpdates = true
        checkForUpdates()
    }

    /// 等在飞的检查落地（测试用；生产 UI 靠 @Observable 状态自动刷新）。
    func waitForUpdateCheck() async {
        await updateCheckTask?.value
    }

    /// 检查更新。连点会取消上一发，只认最后一次结果。
    func checkForUpdates() {
        guard let releaseFetcher else {
            updateCheckStatus = .failed(reason: L("更新检查未配置", "Update check not configured"))
            return
        }
        updateCheckTask?.cancel()
        updateCheckStatus = .checking
        let currentVersion = AppAbout.comparableVersion
        updateCheckTask = Task { [weak self] in
            let outcome = await releaseFetcher()
            guard !Task.isCancelled else { return }
            self?.finishUpdateCheck(outcome, currentVersion: currentVersion)
        }
    }

    private func finishUpdateCheck(_ outcome: UpdateCheckOutcome, currentVersion: String) {
        switch outcome {
        case .noRelease:
            updateCheckStatus = .failed(reason: L("仓库还没有发布版", "The repository has no releases yet"))
        case .failure(let reason):
            updateCheckStatus = .failed(reason: reason)
        case .release(let tag, let url):
            if UpdateCheck.isNewer(tag, than: currentVersion) {
                updateCheckStatus = .available(latest: tag, url: url)
                append(.info, L("发现新版本 \(tag)（本机 \(currentVersion)）", "New version \(tag) available (running \(currentVersion))"))
            } else {
                updateCheckStatus = .upToDate(latest: tag)
                append(.info, L("更新检查：已是最新（仓库 \(tag)，本机 \(currentVersion)）", "Update check: up to date (latest \(tag), running \(currentVersion))"))
            }
        }
    }

    // MARK: - toast

    /// 调试面板的「测试 toast」：手动弹一次当前桌面名，用来在不开设置页的情况下核对窗口行为。
    func showTestToast() {
        guard settings.showToastOnDesktopSwitch else {
            append(.warning, L("toast 已在设置里关闭，未显示", "The toast is disabled in Settings; not shown"))
            return
        }
        guard let toastPresenter else {
            append(.warning, L("toast 未接入（AppDelegate 没注入 presenter）", "Toast not wired up (AppDelegate didn't inject a presenter)"))
            return
        }
        let space = activeSpace
        let text = space.map { displayName(for: $0) } ?? L("测试提示", "Test notice")
        toastPresenter.show(text: text, displayUUID: space?.displayUUID)
        append(.info, L("手动触发 toast：\(text)", "Manually triggered toast: \(text)"))
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

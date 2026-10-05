import Foundation

/// Dock 偏好读写的能力抽象。测试替身用它模拟「Dock 有没有真的吃下写入」。
protocol DockPreferenceAccessing: Sendable {
    func readDomain() -> [String: PlistValue]
    @discardableResult func writeWhitelisted(_ entries: [String: PlistValue]) -> Int
    /// 写 `mru-spaces`。白名单之外的**唯一**例外，见 `DockPreferences.writeMRUSpaces(_:)`。
    @discardableResult func writeMRUSpaces(_ enabled: Bool) -> Bool
}

extension DockPreferenceAccessing {
    /// 读 `mru-spaces`。默认实现走 `readDomain()`，这样测试替身不必单独实现它，
    /// 也不会绕过注入点去读真实系统的偏好域。
    func readMRUSpaces() -> Bool? {
        readDomain()[DockPreferences.mruSpacesKey]?.boolValue
    }

    /// 读单个键。默认实现同样走 `readDomain()`（替身零成本；真实实现全量拷一次
    /// 也只有 0.1 ms 量级，次级条最多 5 次/秒的调用频率扛得住）。
    func readValue(forKey key: String) -> PlistValue? {
        readDomain()[key]
    }
}

struct RealDockPreferences: DockPreferenceAccessing {
    func readDomain() -> [String: PlistValue] { DockPreferences.readDomain() }
    @discardableResult
    func writeWhitelisted(_ entries: [String: PlistValue]) -> Int {
        DockPreferences.writeWhitelisted(entries)
    }
    @discardableResult
    func writeMRUSpaces(_ enabled: Bool) -> Bool {
        DockPreferences.writeMRUSpaces(enabled)
    }
}

/// 把一套 `DockConfig` 推到真实 Dock 的流水线（计划 §3.4）。
///
/// 顺序固定为：**内容相同则短路 → 备份 → 读全量域 → 只覆盖白名单键 → 单次原子写 →
/// 触发重载 → 读回校验，不一致重试一次**。
///
/// 两条铁律：绝不整域替换；绝不写当前域里不存在的键。
@MainActor
final class DockController {

    struct Outcome: Sendable, Equatable {
        enum Result: String, Sendable {
            /// 真的写了并重启了 Dock。
            case applied
            /// 与当前已应用内容一致，**完全没碰 Dock**（不重启、不闪烁）。
            case skippedIdentical
            /// 写了但校验不过，或读不到偏好域。
            case failed
        }

        var result: Result
        var reason: String
        var reload: ReloadOutcome?
        /// 实际写入的键数。
        var writtenKeys: Int
        /// 校验尝试次数（1 = 一次过，2 = 重试过一次）。
        var verifyAttempts: Int
        var elapsed: TimeInterval
        /// 非致命问题的说明（例如备份失败）。
        var note: String?
        /// 本次应用内容的指纹。`.applied` 时用于写进会话标记（强杀自愈的判据）。
        var fingerprint: String
        /// 只有退出流程的应用才有：一次"不等归位"的重启结果。见 `apply(_:reason:strategy:force:forQuit:)`。
        var quitRestart: QuitRestart?

        var succeeded: Bool { result == .applied || result == .skippedIdentical }

        /// 给日志/界面用的一句话。
        var summary: String {
            var text = "\(result.rawValue)：\(reason)"
            if let reload { text += "；\(reload.description)" }
            if let quitRestart { text += "；\(quitRestart.description)" }
            if result == .applied { text += "；写入 \(writtenKeys) 个键" }
            if verifyAttempts > 1 { text += "；校验重试 \(verifyAttempts) 次" }
            text += String(format: "；总耗时 %.0f ms", elapsed * 1000)
            if let note { text += "；注意：\(note)" }
            return text
        }
    }

    private let preferences: any DockPreferenceAccessing
    private let reloader: DockReloader
    private let backup: @MainActor () throws -> Void
    /// 应用结果回调。由 `AppState` 在构造后接上（构造时还拿不到 `self`）。
    var onOutcome: @MainActor (Outcome) -> Void

    /// 最近一次成功应用的配置指纹。用于「内容相同则短路」。
    private(set) var appliedFingerprint: String?
    /// 最近一次成功应用后，**读回口径**的指纹（只算白名单里当前域中真实存在的键）。
    ///
    /// `DockWatcher` 用它判断"当前真实 Dock 还是不是我们写的那份"。
    /// 与写入校验同一口径，所以可以直接比字符串。
    private(set) var appliedComparableFingerprint: String?
    /// 最近一次成功写入的时间。给"别把自己的写入当成用户改动"用。
    private(set) var appliedAt: Date?

    /// 待应用的目标。连击时只保留最后一个（计划 §3.4 第 7 条）。
    private var pending: (config: DockConfig, reason: String, force: Bool, strategy: ReloadStrategy)?
    private var drainTask: Task<Void, Never>?

    init(
        preferences: any DockPreferenceAccessing = RealDockPreferences(),
        reloader: DockReloader = DockReloader(autoHide: HIServicesDockAutoHide.make()),
        backup: @escaping @MainActor () throws -> Void = { try BaselineStore().rotateBackup() },
        onOutcome: @escaping @MainActor (Outcome) -> Void = { _ in }
    ) {
        self.preferences = preferences
        self.reloader = reloader
        self.backup = backup
        self.onOutcome = onOutcome
    }
    /// Dock 进程此刻在不在。走 `reloader` 的进程控制，所以测试里同样是替身。
    var isDockAlive: Bool { reloader.isDockAlive }

    /// 当前 Dock 域里存在、因而可以安全写入的白名单键。
    func presentWhitelistedKeys() -> Set<String> {
        Set(preferences.readDomain().keys).intersection(DockPreferences.whitelistedKeys)
    }

    /// 读 `mru-spaces`。走注入点，不要在 `AppState` 里直接调 `DockPreferences`。
    func readMRUSpaces() -> Bool? { preferences.readMRUSpaces() }

    /// 系统当前的 Dock 图标尺寸（只读**不写**，2026-10-05 起外观跟随系统）。
    /// 域里没有这个键时返回 nil，调用方用默认值兜底。
    func readSystemTileSize() -> Double? {
        preferences.readValue(forKey: "tilesize")?.doubleValue
    }

    /// 写 `mru-spaces`。写完之后要自己 `reloadOnly` 一次才生效。
    @discardableResult
    func writeMRUSpaces(_ enabled: Bool) -> Bool { preferences.writeMRUSpaces(enabled) }

    /// 读当前真实的 Dock 全量域。
    ///
    /// 所有需要"看现在 Dock 长什么样"的地方都必须走这里，**不要直接调 `DockPreferences.readDomain()`** ——
    /// 那样会绕过注入点，测试里就会读到真实系统的偏好域。
    func readDomain() -> [String: PlistValue] {
        preferences.readDomain()
    }

    /// 把当前真实的 Dock 读成一套配置。域读不到时返回 nil。
    func captureLiveConfig() -> DockConfig? {
        let domain = preferences.readDomain()
        guard !domain.isEmpty else { return nil }
        return DockConfig.read(from: domain)
    }

    /// 把"此刻真实 Dock 的内容"记成已应用状态。
    ///
    /// 启动时调用：如果真实 Dock 已经等于要应用的那份配置，`apply` 会被指纹短路，
    /// 于是**不写、不重启 Dock**。这不改变无痕语义 —— 只是避免一次毫无必要的重启。
    ///
    /// 注意**不设 `appliedAt`**：这不是我们写的，不该被当成"我们自己刚写完"。
    func adoptLiveDockAsApplied() {
        guard let live = captureLiveConfig() else { return }
        appliedFingerprint = live.fingerprint
        appliedComparableFingerprint = comparableFingerprint(of: live)
    }

    /// 一套配置在**读回口径**下的指纹：只算白名单里**当前域中真实存在**的键。
    ///
    /// 与 `verify` 用的是同一套口径，所以「Dock 是否还是我们写的那份」可以直接比字符串。
    /// 本机缺失的外观键（`show-process-indicators`）两边都不参与，不会产生假差异。
    func comparableFingerprint(of config: DockConfig) -> String {
        let present = Set(preferences.readDomain().keys)
        let keys = Set(Self.entries(for: config, restrictedTo: present).keys)
        return config.fingerprint(restrictedTo: keys)
    }

    /// 当前真实 Dock 在读回口径下的指纹。域读不到时返回 nil。
    func currentComparableFingerprint() -> String? {
        let domain = preferences.readDomain()
        guard !domain.isEmpty else { return nil }
        return comparableFingerprint(of: DockConfig.read(from: domain))
    }

    /// 请求应用。连击时只对**最终落点**执行一次；应用进行中又有新目标，本轮结束立即补跑。
    func request(_ config: DockConfig, reason: String, strategy: ReloadStrategy, force: Bool = false) {
        pending = (config, reason, force, strategy)
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in await self?.drain() }
    }

    /// 等到当前所有待办跑完。测试与「立即应用」按钮用。
    ///
    /// `drain()` 在 `pending` 清空后、置 `drainTask = nil` 之前没有 `await`，
    /// 所以这里每轮 `await` 完再看 `drainTask` 是可靠的。
    func waitForIdle() async {
        while let task = drainTask {
            await task.value
        }
    }

    /// 带上限地等待办跑完。返回 `true` = 真的干净了。
    ///
    /// 退出流程用它：一次在飞的应用最坏要等完整条 ladder（真机实测几十秒），
    /// 而"等满"本身没有任何收益（见 `DockReloader.reloadForQuit(strategy:deadline:)`）。
    /// 超时不等于可以继续 —— 那笔在飞的写入可能落在我们的还原**之后**。
    /// 所以调用方必须把 `false` 当成"没还干净"来处理：**留下会话标记**，交给下次启动自愈。
    ///
    /// ⚠️ **刻意轮询，不用 `withTaskGroup` 赛跑。** 任务组在闭包返回时会等**所有**子任务收尾，
    /// 而 `await drainTask.value` 那种子任务对取消毫无反应 —— 于是"上限"会**静默失效**，
    /// 变成"一直等到那笔应用跑完"。阴险的是**返回值看着是对的**（`group.next()` 在 20 ms 就报了
    /// `false`），只有墙钟不对：实测上限 20 ms、实际返回用了 625 ms（正好是降级链的总时长）。
    /// 真机 2026-09-19 的"每次退出都卡住几十秒"就是这个形状 —— 上限写在了参数里，却没人真的受它约束。
    func waitForIdle(upTo limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while drainTask != nil, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return drainTask == nil
    }

    /// 丢掉还没起跑的待办。给退出流程用：紧接着就要还原到基准，
    /// 那笔待办的目标已经被取代了，等它只会白等。
    func dropPendingRequests() {
        pending = nil
    }

    /// 是否有待办正在排队/执行。
    ///
    /// `request()` 会**同步**建好任务，所以调用方在 `request()` 返回后立刻读它是 `true`。
    /// 「预应用」正是靠这一点验证"切空间之前就已经发起应用，没等轮询"。
    var isApplying: Bool { drainTask != nil }

    /// 只重启 Dock，不写任何偏好。
    ///
    /// 给「改了白名单之外的键」用 —— 目前只有 `mru-spaces`。**不要**走 `request`/`apply`：
    /// 那条路会把当前配置的白名单键重写一遍，而这里根本没有配置要应用，
    /// 只是让 Dock 重新读一遍偏好域。
    ///
    /// 刻意不合成一个 `Outcome` 出来：`appliedFingerprint` 在这里没变，
    /// 硬造一个 Outcome 会让"最近一次应用摘要"显示出一次并不存在的应用。
    func reloadOnly(strategy: ReloadStrategy = .auto) async -> ReloadOutcome {
        await reloader.reload(strategy: strategy)
    }

    private func drain() async {
        while let next = pending {
            pending = nil
            let outcome = await apply(next.config, reason: next.reason, strategy: next.strategy, force: next.force)
            onOutcome(outcome)
        }
        // 这里到 drainTask = nil 之间没有 await，所以不会有「新请求看到 drainTask 非空而不启动」的窗口。
        drainTask = nil
    }

    /// 应用一套配置。
    ///
    /// - Parameter forQuit: 退出流程专用。写入照旧，但**重启不等归位、不升级兜底**
    ///   （见 `DockReloader.reloadForQuit(strategy:deadline:)`），并且**只用 SIGHUP** ——
    ///   `SIGTERM` 那条有约 255 ms 的退出清理窗口、Dock 可能回写覆盖我们的写入，
    ///   而退出流程没有重试的机会去发现它。真机 2026-09-19：走完整 ladder 的退出还原
    ///   在 launchd 退避期间耗时 53–54 秒，用户看到的就是"退出时卡住、Dock 没了"。
    /// - Parameter extraEntries: 随本次写入一并落盘的白名单键值（外观键，还原路径专用）。
    ///   **只写不校验**：它们来自基准快照原值，Dock 只会原样吃下；内容键的校验口径不变。
    func apply(
        _ config: DockConfig,
        reason: String,
        strategy: ReloadStrategy = .auto,
        force: Bool = false,
        forQuit: Bool = false,
        extraEntries: [String: PlistValue] = [:]
    ) async -> Outcome {
        let started = Date()
        func elapsed() -> TimeInterval { Date().timeIntervalSince(started) }

        // 1. 内容相同 → 短路。两个桌面共用同一份 Dock 时，切桌面零开销、零闪烁。
        if !force, config.fingerprint == appliedFingerprint {
            return Outcome(result: .skippedIdentical, reason: reason, reload: nil, writtenKeys: 0,
                           verifyAttempts: 0, elapsed: elapsed(), note: nil,
                           fingerprint: config.fingerprint)
        }

        // 1b. **真实 Dock 已经是这份内容** → 同样不写、不备份、不重启，只把它记成"已应用"。
        //
        // 为什么必须单独有这一条：上面那条比的是「我们上次写下去的那份」（`appliedFingerprint`），
        // 一旦发生过**外部改动**（用户手拖图标、别的 App 改、或 `DockWatcher` 刚回存的那份），
        // 它就**过期**了。此时再应用一份与真实 Dock 完全相同的配置，会白写一遍 + 白重启一次 Dock。
        //
        // 实测（`DockAcceptanceTests.testExternalDockChangeIsCapturedBackToActiveDesktop`）：
        // 桌面**有独立 Dock** 时回存会白重启一次（PID 68667 → 68672，约 50 ms 闪烁）；
        // 没有独立 Dock 时不会（回存只写配置、不应用）—— 所以只有 override 那条路中招，
        // 而逐桌面 Dock 恰恰是本 App 的常态用法。
        //
        // 判据复用 `verify` 的同一套比较，所以「跳过」与「写下去之后立刻验过」**严格等价**，
        // 不会漏掉真正需要的写入。
        if !force, extraEntries.isEmpty, liveAlreadyMatches(config) {
            adoptLiveDockAsApplied()
            return Outcome(result: .skippedIdentical, reason: reason, reload: nil, writtenKeys: 0,
                           verifyAttempts: 0, elapsed: elapsed(), note: nil,
                           fingerprint: config.fingerprint)
        }

        // 2. 备份当前全量域。失败不阻断（基准快照才是最后一道防线），但要把话说明白。
        var note: String?
        do {
            try backup()
        } catch {
            note = "写入前的备份失败：\(error.localizedDescription)（基准快照仍在，可一键还原）"
        }

        // 3. 读全量域 → 只覆盖白名单键 → 单次原子写。
        let domain = preferences.readDomain()
        guard !domain.isEmpty else {
            return Outcome(result: .failed, reason: "\(reason)（读不到 com.apple.dock 偏好域）", reload: nil,
                           writtenKeys: 0, verifyAttempts: 0, elapsed: elapsed(), note: note,
                           fingerprint: config.fingerprint)
        }

        let present = Set(domain.keys)
        var entries = Self.entries(for: config, restrictedTo: present)
        for (key, value) in extraEntries where present.contains(key) {
            entries[key] = value
        }
        let comparableKeys = Set(Self.entries(for: config, restrictedTo: present).keys)
        // 外观跟随系统（2026-10-05）：配置不再携带 autohide，三明治的"目标可见性"以
        // 当前域里的实时值为准 —— 自动隐藏开着就别强推显出，关着才需要在重启后滑回来。
        let liveAutohide = domain["autohide"]?.boolValue ?? false

        // 4. 写 → 重载 → 读回校验；不一致重试一次（SIGTERM 的清理窗口竞态，见 docs/spikes.md）。
        //    退出流程例外：一次写入 + 一发信号 + 一次校验，**不重试也不升级**（见 `apply` 的 `forQuit`）。
        var verifyAttempts = 0
        var reload: ReloadOutcome?
        var quitRestart: QuitRestart?
        var verified = false
        if forQuit {
            verifyAttempts = 1
            preferences.writeWhitelisted(entries)
            quitRestart = await reloader.reloadForQuit(strategy: .auto)
            verified = verify(config, comparableKeys: comparableKeys)
        } else {
            for attempt in 1...2 {
                verifyAttempts = attempt
                preferences.writeWhitelisted(entries)
                // reveal = 目标可见性。域里 autohide 开着（true）时不启用三明治：
                // 重启后的 Dock 本来就以隐藏态出现，不会闪。
                reload = await reloader.reload(strategy: strategy,
                                               sandwichRevealAutoHideTo: liveAutohide ? nil : false)
                verified = verify(config, comparableKeys: comparableKeys)
                if verified { break }
            }
        }

        if verified {
            appliedFingerprint = config.fingerprint
            appliedComparableFingerprint = config.fingerprint(restrictedTo: comparableKeys)
            appliedAt = Date()
        }

        return Outcome(
            result: verified ? .applied : .failed,
            reason: reason,
            reload: reload,
            writtenKeys: entries.count,
            verifyAttempts: verifyAttempts,
            elapsed: elapsed(),
            note: note,
            fingerprint: config.fingerprint,
            quitRestart: quitRestart
        )
    }

    /// 把配置摊成要写入的键值对。**只写 `present` 里存在的键**。
    ///
    /// 2026-10-05 起**只产内容键**（persistent-apps / persistent-others）：
    /// 大小 / 放大 / 自动隐藏 / 特效 / 最小化到应用全部跟随系统，App 不再写任何外观键。
    /// 外观键只在**还原路径**上经 `apply` 的 `extraEntries` 回写（来自基准快照原值）。
    nonisolated static func entries(for config: DockConfig, restrictedTo present: Set<String>) -> [String: PlistValue] {
        var entries: [String: PlistValue] = [:]
        if present.contains("persistent-apps") {
            entries["persistent-apps"] = .array(config.pinnedApps.map { .dictionary($0.raw) })
        }
        if present.contains("persistent-others") {
            entries["persistent-others"] = .array(config.otherItems.map { .dictionary($0.raw) })
        }
        return entries
    }

    /// 读回白名单键比对。
    ///
    /// 只比 `comparableKeys`（实际写进去的那些键）—— 本机缺失的外观键没被写，
    /// 若算进比对会变成假阴性。
    private func verify(_ config: DockConfig, comparableKeys: Set<String>) -> Bool {
        let live = DockConfig.read(from: preferences.readDomain())
        return live.fingerprint(restrictedTo: comparableKeys) == config.fingerprint(restrictedTo: comparableKeys)
    }

    /// 真实 Dock 是否**已经**等于这份配置（在"读回口径"下）。
    ///
    /// 与 `verify` 是**同一套比较**，只是把域一次读进来、不再读第二遍。
    /// 口径一致很关键：否则"跳过"与"写了也会立刻验过"就会不等价，
    /// 可能出现"以为不用写、其实该写"的漏写。
    private func liveAlreadyMatches(_ config: DockConfig) -> Bool {
        let domain = preferences.readDomain()
        guard !domain.isEmpty else { return false }
        let present = Set(domain.keys)
        // 只比"我们真要写的那些键"——本机缺失的外观键两边都不参与，不会造成假不等。
        let comparableKeys = Set(Self.entries(for: config, restrictedTo: present).keys)
        let live = DockConfig.read(from: domain)
        return live.fingerprint(restrictedTo: comparableKeys)
            == config.fingerprint(restrictedTo: comparableKeys)
    }
}

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
        /// 因为当前域里没有而**被跳过的外观键**。
        var skippedKeys: Set<String>
        /// 非致命问题的说明（例如备份失败）。
        var note: String?
        /// 本次应用内容的指纹。`.applied` 时用于写进会话标记（强杀自愈的判据）。
        var fingerprint: String

        var succeeded: Bool { result == .applied || result == .skippedIdentical }

        /// 给日志/界面用的一句话。
        var summary: String {
            var text = "\(result.rawValue)：\(reason)"
            if let reload { text += "；\(reload.description)" }
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
        reloader: DockReloader = DockReloader(),
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
    func apply(
        _ config: DockConfig,
        reason: String,
        strategy: ReloadStrategy = .auto,
        force: Bool = false
    ) async -> Outcome {
        let started = Date()
        func elapsed() -> TimeInterval { Date().timeIntervalSince(started) }

        // 1. 内容相同 → 短路。两个桌面共用同一份 Dock 时，切桌面零开销、零闪烁。
        if !force, config.fingerprint == appliedFingerprint {
            return Outcome(result: .skippedIdentical, reason: reason, reload: nil, writtenKeys: 0,
                           verifyAttempts: 0, elapsed: elapsed(), skippedKeys: [],
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
        if !force, liveAlreadyMatches(config) {
            adoptLiveDockAsApplied()
            return Outcome(result: .skippedIdentical, reason: reason, reload: nil, writtenKeys: 0,
                           verifyAttempts: 0, elapsed: elapsed(), skippedKeys: [],
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
                           writtenKeys: 0, verifyAttempts: 0, elapsed: elapsed(), skippedKeys: [], note: note,
                           fingerprint: config.fingerprint)
        }

        let present = Set(domain.keys)
        let entries = Self.entries(for: config, restrictedTo: present)
        let skipped = config.appearance.unavailableKeys(in: present)
        let comparableKeys = Set(entries.keys)

        // 4. 写 → 重载 → 读回校验；不一致重试一次（SIGTERM 的清理窗口竞态，见 docs/spikes.md）。
        var verifyAttempts = 0
        var reload: ReloadOutcome?
        var verified = false
        for attempt in 1...2 {
            verifyAttempts = attempt
            preferences.writeWhitelisted(entries)
            reload = await reloader.reload(strategy: strategy)
            verified = verify(config, comparableKeys: comparableKeys)
            if verified { break }
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
            skippedKeys: skipped,
            note: note,
            fingerprint: config.fingerprint
        )
    }

    /// 把配置摊成要写入的键值对。**只写 `present` 里存在的键**。
    static func entries(for config: DockConfig, restrictedTo present: Set<String>) -> [String: PlistValue] {
        var entries: [String: PlistValue] = [:]
        if present.contains("persistent-apps") {
            entries["persistent-apps"] = .array(config.pinnedApps.map { .dictionary($0.raw) })
        }
        if present.contains("persistent-others") {
            entries["persistent-others"] = .array(config.otherItems.map { .dictionary($0.raw) })
        }
        entries.merge(config.appearance.domainEntries(restrictedTo: present)) { _, new in new }
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

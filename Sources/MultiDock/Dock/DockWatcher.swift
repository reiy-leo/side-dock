import Foundation

/// 识别用户在**真实 Dock** 上的手动改动，并回存到配置（`docs/PLAN.md` §3.8）。
///
/// 为什么需要它：用户随时可能自己拖一个图标进 Dock。如果 App 不管这件事，
/// 下次切桌面时会把他的改动覆盖掉 —— 那是"App 赢"，不是用户想要的。
///
/// **判据是"当前 Dock 的指纹变了"**：每轮取一次当前真实 Dock 的**可比指纹**
/// （与写入校验同一口径：只算白名单里当前域中真实存在的键），与上一轮比。
/// - 没变 → 什么都不做。
/// - 变了，且等于"我们上次写下去的那份" → 是我们自己的写入，忽略。
/// - 变了，且不等于 → 用户改的，交给上层回存。
///
/// **指纹归一化必须剔除** Dock 每次重载都会重算的字段（`GUID` / `file-mod-date` /
/// `parent-mod-date` / `book`），否则每次重启 Dock 都会被误判成"用户改了"。
/// 这件事由 `DockTile.normalizedKey` + `DockConfig.fingerprint` 负责。
///
/// 纯逻辑 + 注入式读写，所以能脱离真实 Dock 单测。
@MainActor
final class DockWatcher {

    /// 取当前真实 Dock 的可比指纹。nil = 读不到域（例如 Dock 不在）。
    private let currentFingerprint: @MainActor () -> String?
    /// 我们上次写下去的那份内容的可比指纹。nil = 本次运行还没写过。
    private let appliedFingerprint: @MainActor () -> String?
    /// 读当前真实 Dock 的配置（回存用）。
    private let readLiveConfig: @MainActor () -> DockConfig?
    /// 发现手动改动时回调。
    private let onUserEdit: @MainActor (DockConfig) -> Void
    private let log: @MainActor (String) -> Void

    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    private var lastSeenFingerprint: String?

    /// 累计识别到几次手动改动。调试面板可见。
    private(set) var detectedCount = 0
    /// 当前是否处于"真实 Dock 与我们的记录不一致"状态。调试面板可见。
    private(set) var isDiverged = false

    init(
        pollInterval: Duration = .seconds(2),
        currentFingerprint: @escaping @MainActor () -> String?,
        appliedFingerprint: @escaping @MainActor () -> String?,
        readLiveConfig: @escaping @MainActor () -> DockConfig?,
        onUserEdit: @escaping @MainActor (DockConfig) -> Void,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.pollInterval = pollInterval
        self.currentFingerprint = currentFingerprint
        self.appliedFingerprint = appliedFingerprint
        self.readLiveConfig = readLiveConfig
        self.onUserEdit = onUserEdit
        self.log = log
    }

    func start() {
        guard pollTask == nil else { return }
        lastSeenFingerprint = currentFingerprint()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.pollInterval)
                guard !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    var isRunning: Bool { pollTask != nil }

    /// 单次检查。测试直接调它，不用等轮询。
    func tick() {
        guard let fingerprint = currentFingerprint() else { return }
        guard fingerprint != lastSeenFingerprint else { return }
        lastSeenFingerprint = fingerprint

        isDiverged = (fingerprint != appliedFingerprint())

        // 等于我们上次写下去的那份 → 是我们自己造成的（Dock 重启后的规范化），不是用户改的。
        guard isDiverged else { return }
        // 本次运行还没写过任何东西 → 没有"我们的版本"可比，不动用户的配置。
        guard appliedFingerprint() != nil else { return }
        guard let config = readLiveConfig() else { return }

        detectedCount += 1
        log("检测到真实 Dock 上的手动改动：\(config.pinnedApps.count) 个图标、"
            + "\(config.otherItems.count) 个其他项")
        onUserEdit(config)
    }

    /// 把我们自己刚应用的指纹记成"已见过"，避免把自己的写入当成用户改动。
    func acknowledge(_ fingerprint: String?) {
        guard let fingerprint else { return }
        lastSeenFingerprint = fingerprint
        isDiverged = false
    }
}

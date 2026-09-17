import Foundation

/// 盯着 Dock 还在不在，不在就拉回来（`docs/PLAN.md` §4 P4 验收第 4 条：3 秒内恢复）。
///
/// 为什么需要它：`DockReloader` 的兜底只覆盖「**我们主动**重启 Dock」这条路。
/// 如果 Dock 是被外部弄死的（`kill -9`、自己崩了、launchd 打嗝），我们这边一无所知，
/// 用户会面对一个没有 Dock 的桌面且不知道为什么。这个监视器补的就是这一环。
///
/// 两个刻意的设计：
/// 1. **连续缺失达到阈值才算数**。Dock 重启窗口里本来就有一瞬间查不到（P0 实测），
///    一次缺失就动手会让每次正常切换都白打一次 `launchctl`。
/// 2. **拉回不是每轮都打**。判定不在之后按 `kickstartEvery` 间隔重试，
///    否则 500 ms 一次轮询会把 `launchctl` 打成风暴（`launchctl` 是子进程，一次约 10 ms）。
@MainActor
final class DockPresenceMonitor {

    private let process: any DockProcessControlling
    private let pollInterval: Duration
    /// 连续缺失多少次才判定「Dock 真的不在了」。
    private let missThreshold: Int
    /// 判定不在之后，每隔多少次轮询重试一次拉回。
    private let kickstartEvery: Int
    private let log: @MainActor (String) -> Void

    private var task: Task<Void, Never>?

    /// 连续缺失次数。Dock 一归位就清零。
    private(set) var consecutiveMisses = 0
    /// 从「Dock 不在」恢复到「归位」的次数。验收与调试面板据此断言。
    private(set) var recoveryCount = 0
    /// 主动拉回的尝试次数。
    private(set) var kickstartCount = 0
    private(set) var lastSeenPID: pid_t?
    private(set) var isRunning = false

    init(
        process: any DockProcessControlling = RealDockProcessControl(),
        pollInterval: Duration = .milliseconds(500),
        missThreshold: Int = 2,
        kickstartEvery: Int = 4,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.process = process
        self.pollInterval = pollInterval
        self.missThreshold = max(1, missThreshold)
        self.kickstartEvery = max(1, kickstartEvery)
        self.log = log
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// 单次检查。轮询会调它，测试也直接调它 —— 这样"何时判定、何时拉回"是确定性的，
    /// 不受轮询时机影响（与 `DockWatcher.tick()` 同一套路）。
    func tick() {
        if let pid = process.dockPID(), pid > 0 {
            if consecutiveMisses >= missThreshold {
                recoveryCount += 1
                log("Dock 已归位（PID \(pid)，第 \(recoveryCount) 次恢复）")
            }
            consecutiveMisses = 0
            lastSeenPID = pid
            return
        }

        consecutiveMisses += 1
        guard consecutiveMisses >= missThreshold else { return }
        // 阈值那一次必打，之后每 kickstartEvery 次再打一次。
        guard (consecutiveMisses - missThreshold) % kickstartEvery == 0 else { return }

        kickstartCount += 1
        let recovered = process.kickstart()
        log(recovered
            ? "检测到 Dock 不在（连续 \(consecutiveMisses) 次），已用 launchctl 拉回"
            : "检测到 Dock 不在（连续 \(consecutiveMisses) 次），launchctl 拉回失败，会继续重试")
    }
}

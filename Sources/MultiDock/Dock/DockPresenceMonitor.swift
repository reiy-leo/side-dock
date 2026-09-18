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
/// 2. **拉回不是每轮都打，而且打得越勤越糟**。判定不在之后按 `kickstartEvery`（默认 30 秒）
///    间隔重试。2026-09-19 真机踩过反面：默认值曾经是「1 秒就动手 + 每 2 秒催一发」，
///    每一发 `launchctl kickstart -k` 都会把 launchd 正要拉起的 Dock 再杀一次并加深退避，
///    于是每次切换的 Dock 缺失被自我放大成 60–126 秒（`docs/spikes.md` 实验 8.5 同结论：
///    **静置等待比反复 `kickstart` 更快**）。
/// 3. **拉不回来要吭声**。缺失持续到 `persistentFailureThreshold` 轮还没回来，
///    就回调 `onPersistentlyDown` 一次，让 UI 提示用户从备份恢复 ——
///    静默重试到天荒地老等于"用户面对一个没有 Dock 的桌面且不知道为什么"（计划 §3.9 第 3 条）。
@MainActor
final class DockPresenceMonitor {

    private let process: any DockProcessControlling
    private let pollInterval: Duration
    /// 连续缺失多少次才判定「Dock 真的不在了」（默认 8 轮 = 4 秒）。
    ///
    /// 这个数**必须比 launchd 的正常拉起时间长**：`kill -9` 之后实测 1072 ms 归位，
    /// 而退避期是几十秒。1 秒就动手会在 launchd 正要拉起时插一发 `kickstart -k`，
    /// 把一次慢恢复滚成持续的 Dock 死亡（2026-09-19 真机踩过，见 `docs/spikes.md` 实验 8.5）。
    private let missThreshold: Int
    /// 判定不在之后，每隔多少次轮询重试一次拉回（默认 60 轮 = 30 秒）。
    ///
    /// 刻意稀疏：反复 `kickstart` 只会加深 launchd 的递增退避，**静置等待比反复催更快**。
    private let kickstartEvery: Int
    /// 连续缺失达到这么多次轮询还没回来 → 判定「拉不回来」，报给 UI（计划 §3.9 第 3 条）。
    ///
    /// 默认 120 轮 = 60 秒。尺度是 launchd 的退避，不是我们的轮询：几十秒的缺失在本机是
    /// 「系统正在恢复」，此时就报警会把一次正常恢复说成故障。
    private let persistentFailureThreshold: Int
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

    /// 是否已判定「持续拉不回来」。**边沿触发**：只在跨过阈值时报一次，Dock 回来时清掉。
    ///
    /// 判据刻意用**缺失轮数**而不是 `kickstart()` 的返回值 —— 那个返回值只说明
    /// `launchctl` 命令跑起来了，不说明 Dock 回来了。拉回成功但 Dock 依然不在的情形是可能的。
    private(set) var isPersistentlyDown = false

    /// 判定「拉不回来」时回调一次。参数是给用户看的一句话。
    ///
    /// 用 `var` 而不是 init 参数，与下面的 `log` 不同：这两个回调写的是 **`AppState` 自己的状态**，
    /// 必须由 `AppState` 无条件挂上 —— 而监视器可能是测试里构造好再注入的，那时 init 参数没人填。
    var onPersistentlyDown: @MainActor (String) -> Void = { _ in }
    /// 从「持续拉不回来」恢复时回调一次。参数是累计恢复次数。
    var onRevived: @MainActor (Int) -> Void = { _ in }

    init(
        process: any DockProcessControlling = RealDockProcessControl(),
        pollInterval: Duration = .milliseconds(500),
        missThreshold: Int = 8,
        kickstartEvery: Int = 60,
        persistentFailureThreshold: Int = 120,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.process = process
        self.pollInterval = pollInterval
        self.missThreshold = max(1, missThreshold)
        self.kickstartEvery = max(1, kickstartEvery)
        // 必须严格大于 missThreshold，否则"还没到该动手的轮数就先报拉不回来"。
        self.persistentFailureThreshold = max(self.missThreshold + 1, persistentFailureThreshold)
        self.log = log
    }

    /// 轮询周期折算成秒，用来把"缺了多少轮"翻译成人能读的秒数。
    private var pollIntervalSeconds: Double {
        let parts = pollInterval.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
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
                if isPersistentlyDown {
                    isPersistentlyDown = false
                    onRevived(recoveryCount)
                }
            }
            consecutiveMisses = 0
            lastSeenPID = pid
            return
        }

        consecutiveMisses += 1

        // 「拉不回来」：缺够久就认定 launchctl 也没用，报一次让 UI 提示用户从备份恢复。
        if !isPersistentlyDown, consecutiveMisses >= persistentFailureThreshold {
            isPersistentlyDown = true
            let seconds = Int((Double(consecutiveMisses) * pollIntervalSeconds).rounded())
            onPersistentlyDown(
                "Dock 已连续约 \(seconds) 秒没有回来，已尝试用 launchctl 拉回 \(kickstartCount) 次"
            )
        }

        guard consecutiveMisses >= missThreshold else { return }
        // 阈值那一次必打，之后每 kickstartEvery 次再打一次。
        guard (consecutiveMisses - missThreshold) % kickstartEvery == 0 else { return }

        kickstartCount += 1
        let recovered = process.kickstart()
        log(recovered
            ? "检测到 Dock 不在（连续 \(consecutiveMisses) 次），已用 launchctl 拉回"
            : "检测到 Dock 不在（连续 \(consecutiveMisses) 次），launchctl 拉回失败，会继续重试")
    }

    /// 立刻再试一次拉回。给 UI 上那个「再试一次拉回」按钮用。
    ///
    /// 不动 `consecutiveMisses` —— 拉没拉回来由下一次 `tick()` 判定，这里不预支结论。
    @discardableResult
    func reviveNow() -> Bool {
        kickstartCount += 1
        let started = process.kickstart()
        log(started ? "手动重试拉回 Dock" : "手动重试拉回 Dock 失败（launchctl 没跑起来）")
        return started
    }
}

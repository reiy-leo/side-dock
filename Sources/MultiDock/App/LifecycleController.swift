import AppKit
import Foundation

/// 启动自检、退出还原、异常退出自愈（计划 §3.3 / §3.9）。
///
/// 无痕原则的三条腿都在这里接线：
/// 1. **正常退出还原**：`shouldTerminate` 挂起退出（`terminateLater`），还原完成后才真正退出。
/// 2. **强杀/崩溃自愈**：会话标记残留 → 下次启动由 `AppState.performSelfHeal` 把基准写回去。
/// 3. **注销/关机**：`willPowerOffNotification` 尽力还原（这条路上系统不给等待时间）。
@MainActor
final class LifecycleController {

    private let state: AppState
    private let baselineStore: BaselineStore
    private var marker: BaselineStore.SessionMarker?
    /// 退出时的还原动作。`AppDelegate` 把它接到 `AppState.restoreToBaseline()`。
    ///
    /// 必须回传真实结果：还原失败时要把会话标记**留下来**，交给下次启动自愈。
    var restoreHandler: (@MainActor () async -> DockController.Outcome?)?

    /// 真正放行退出。抽成可注入的闭包，测试里换成 no-op ——
    /// 否则单测会去碰 `NSApplication.shared.reply`，而测试进程根本没有在退出。
    var finishTermination: @MainActor () -> Void = {
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    /// 挂起的退出流程。留句柄是为了能 await（测试与"退出前等自愈"都用）。
    private var terminationTask: Task<Void, Never>?

    /// 等退出流程跑完。测试用。
    func waitForTermination() async {
        await terminationTask?.value
    }

    init(state: AppState, baselineStore: BaselineStore = BaselineStore()) {
        self.state = state
        self.baselineStore = baselineStore
    }

    func applicationDidFinishLaunching() {
        state.start()
        beginSession()
    }

    func applicationWillTerminate() {
        state.stop()
    }

    /// 建立会话标记。写入失败不阻塞启动 —— 只是失去强杀自愈的保障。
    private func beginSession() {
        let inheritsDebt = state.hasPendingSelfHeal
        let newMarker = BaselineStore.SessionMarker(
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: Date(),
            appliedFingerprint: nil,
            appliedAt: nil,
            // 继承上次没做完的自愈债务。写进标记而不是只放在内存里：
            // 万一这次又崩在还原途中，下次启动还能接着还。
            needsSelfHeal: inheritsDebt ? true : nil
        )
        marker = newMarker
        do {
            try baselineStore.writeSessionMarker(newMarker)
            let suffix = inheritsDebt ? L("，继承上次未完成的自愈", ", inheriting the previous unfinished self-heal") : ""
            state.append(.info, L("会话标记已建立（PID \(newMarker.pid)\(suffix)）", "Session marker created (PID \(newMarker.pid)\(suffix))"))
        } catch {
            state.append(.warning, L("会话标记写入失败，强杀自愈将不可用：\(error.localizedDescription)", "Failed to write the session marker; force-quit self-heal will be unavailable: \(error.localizedDescription)"))
        }
    }

    /// 记录「本次运行改过 Dock」，供下次启动判断是否需要还原。
    func noteDockApplied(fingerprint: String) {
        marker?.appliedFingerprint = fingerprint
        marker?.appliedAt = Date()
        // 应用成功 = 自愈债务结清（真写进去了，说明这次是完整跑完的）。
        marker?.needsSelfHeal = nil
        if let marker { try? baselineStore.writeSessionMarker(marker) }
    }

    /// 退出流程。返回 `false` 表示需要挂起退出（`terminateLater`），
    /// 等还原完成后再由 `clearMarkerAndFinish()` / `keepMarkerAndFinish()` 真正退出。
    ///
    /// 计划 §3.3：**绝不在还原未完成前就退出进程**，否则用户会看到「退出后 Dock 还是错的」。
    ///
    /// **只还原我们自己改过的东西**：`appliedFingerprint` 为 nil 且没有继承债务时，
    /// 表示本次运行从未写过 Dock。那种情况下绝不能去"还原" —— 用户可能在运行期间
    /// 手动拖了图标，无条件写回基准会把他的改动一起抹掉，那就不是无痕，是破坏。
    func shouldTerminate() -> Bool {
        guard state.settings.restoreOnQuit else {
            state.append(.info, L("已关闭退出还原，直接退出", "Restore-on-quit is off; quitting directly"))
            clearMarkerAndFinish()
            return true
        }
        guard sessionChangedDock else {
            state.append(.info, L("本次运行没有改动过 Dock，无需还原", "The Dock wasn't changed this run; nothing to restore"))
            clearMarkerAndFinish()
            return true
        }
        guard let restore = restoreHandler else {
            state.append(.warning, L("改过 Dock 但还原动作未接线，直接退出", "The Dock was changed but no restore action is wired up; quitting directly"))
            keepMarkerAndFinish(reason: L("还原动作未接线", "restore action not wired up"))
            return true
        }

        state.append(.info, L("开始退出还原…", "Starting restore-on-quit…"))
        terminationTask = Task { @MainActor in
            // **先等排队的应用跑完再还原**。`DockController.request` 是异步排队的，
            // 如果还有一笔待办没落地，它会在还原**之后**才写进去 ——
            // 用户看到的结果就是"退出时还原了，Dock 却还是错的"。
            let settled = await state.prepareForTermination()

            // 超时由还原实现自己控制（它最清楚 Dock 该在多久内归位）。
            // 这里不做外部取消：中途取消一次写了一半的还原比等久一点更危险。
            let started = Date()
            let outcome = await restore()
            let elapsed = Date().timeIntervalSince(started)
            state.append(.info, String(format: L("退出还原流程结束，用时 %.2fs", "Restore-on-quit finished in %.2fs"), elapsed))
            if elapsed > 5 {
                state.append(.warning, L("还原用时超过 5 秒，请检查 Dock 是否正常", "Restore took longer than 5 s — check that the Dock is healthy"))
            }

            if outcome?.succeeded == true, !settled {
                // 还原本身写干净了，但退出时还有一笔应用没落地 —— 它可能在我们之后又写了一次。
                // **不能清标记**：让下次启动的自检去看真实域，不一致就还原。
                keepMarkerAndFinish(reason: L("退出时还有一次应用没落地", "an apply hadn't finished when quitting"))
            } else if outcome?.succeeded == true {
                clearMarkerAndFinish()
            } else {
                // 还原没成功 → **标记必须留着**。这正是"强杀自愈"要接手的场景，
                // 清掉标记等于把下次启动的自愈能力一起扔了。
                keepMarkerAndFinish(
                    reason: outcome.map { L("还原结果 \($0.result.rawValue)", "restore result \($0.result.rawValue)") } ?? L("读不到基准快照", "can't read the baseline snapshot")
                )
            }
        }
        return false
    }

    /// 本次会话是否可能让 Dock 处于非基准状态。
    ///
    /// 判据是标记本身（`appliedFingerprint` 或继承来的 `needsSelfHeal`），
    /// 不只是"本次运行写过没有" —— 上次没还完的自愈债务也算。
    var sessionChangedDock: Bool { marker?.impliesDirtyDock == true }

    private func clearMarkerAndFinish() {
        baselineStore.clearSessionMarker()
        state.stop()
        finishTermination()
    }

    /// 还原没成功时的退出：**保留标记**，并把它标成"非活动会话"。
    ///
    /// `pid = 0` 是关键：`detectInterruptedSession()` 会用 `kill(pid, 0)` 判断"标记是不是
    /// 另一个还活着的实例"，pid 为 0 时它跳过这个检查。这里我们是主动留下标记的，
    /// 必须让它在下一次启动时被当成残留处理。
    private func keepMarkerAndFinish(reason: String) {
        if var marker {
            marker.needsSelfHeal = true
            marker.pid = 0
            try? baselineStore.writeSessionMarker(marker)
        }
        state.append(.warning, L("还原未完成（\(reason)），已留下标记，下次启动会自动重试", "Restore incomplete (\(reason)); a marker was left behind and the next launch retries automatically"))
        state.stop()
        finishTermination()
    }

    /// 注销/关机路径。
    ///
    /// ⚠️ **这条路上系统不给等待时间**（不像 `applicationShouldTerminate` 能挂起）。
    /// 所以只能尽力：先把债务写进标记，再发起一次还原并等它跑完；没跑完的部分
    /// 由下次启动的自愈接手。**不要**在这里改成"同步阻塞等还原" —— 会拖住关机。
    func systemWillPowerOff() {
        guard state.settings.restoreOnQuit, sessionChangedDock else {
            state.append(.info, L("系统即将关机/注销，本次未改动过 Dock，无需还原", "System is powering off/logging out; the Dock wasn't changed this run, nothing to restore"))
            return
        }
        state.append(.warning, L("系统即将关机/注销，正在尽力还原 Dock", "System is powering off/logging out; restoring the Dock as best we can"))
        guard let restore = restoreHandler else { return }

        // 先留标记：即使下面的还原没跑完，下次启动也会自愈。
        if var marker {
            marker.needsSelfHeal = true
            marker.pid = 0
            try? baselineStore.writeSessionMarker(marker)
        }
        Task { @MainActor in
            let outcome = await restore()
            state.append(.info, L("关机前还原：\(outcome?.summary ?? "读不到基准快照")",
                                  "Pre-shutdown restore: \(outcome?.summary ?? "can't read the baseline snapshot")"))
            if outcome?.succeeded == true {
                self.baselineStore.clearSessionMarker()
            }
        }
    }
}

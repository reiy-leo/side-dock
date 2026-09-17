import AppKit
import Foundation

/// 启动自检、退出还原、异常退出检测（计划 §3.3 / §3.9）。
///
/// **P1 边界**：本阶段不写任何 Dock 设置，因此 `restoreDock` 是空实现，
/// 会话标记里的 `appliedFingerprint` 恒为 nil —— 强杀后重启不会产生误报。
/// 真正把基准写回 Dock 要等 P2（写路径）与 P4（还原全链路）。
@MainActor
final class LifecycleController {

    private let state: AppState
    private let baselineStore = BaselineStore()
    private var marker: BaselineStore.SessionMarker?
    /// 退出时的还原动作。P2/P4 会把它接到 `DockController` 上。
    var restoreHandler: (@MainActor () async -> Void)?

    init(state: AppState) {
        self.state = state
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
        let newMarker = BaselineStore.SessionMarker(
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: Date(),
            appliedFingerprint: nil,
            appliedAt: nil
        )
        marker = newMarker
        do {
            try baselineStore.writeSessionMarker(newMarker)
            state.append(.info, "会话标记已建立（PID \(newMarker.pid)）")
        } catch {
            state.append(.warning, "会话标记写入失败，强杀自愈将不可用：\(error.localizedDescription)")
        }
    }

    /// 记录「本次运行改过 Dock」，供下次启动判断是否需要还原。
    func noteDockApplied(fingerprint: String) {
        marker?.appliedFingerprint = fingerprint
        marker?.appliedAt = Date()
        if let marker { try? baselineStore.writeSessionMarker(marker) }
    }

    /// 退出流程。返回 `false` 表示需要挂起退出（`terminateLater`），
    /// 等还原完成后再由 `finishTermination()` 真正退出。
    ///
    /// 计划 §3.3：**绝不在还原未完成前就退出进程**，否则用户会看到「退出后 Dock 还是错的」。
    func shouldTerminate() -> Bool {
        guard state.settings.restoreOnQuit, let restore = restoreHandler else {
            // 没有还原动作（P1）或用户关掉了还原 → 直接放行。
            state.append(.info, state.settings.restoreOnQuit ? "无需还原，直接退出" : "已关闭退出还原，直接退出")
            clearMarkerAndFinish()
            return true
        }

        state.append(.info, "开始退出还原…")
        Task { @MainActor in
            // 超时由还原实现自己控制（它最清楚 Dock 该在多久内归位）。
            // 这里不做外部取消：中途取消一次写了一半的还原比等久一点更危险。
            let started = Date()
            await restore()
            let elapsed = Date().timeIntervalSince(started)
            state.append(.info, String(format: "退出还原流程结束，用时 %.2fs", elapsed))
            if elapsed > 5 {
                state.append(.warning, "还原用时超过 5 秒，请检查 Dock 是否正常")
            }
            self.clearMarkerAndFinish()
        }
        return false
    }

    private func clearMarkerAndFinish() {
        baselineStore.clearSessionMarker()
        state.stop()
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    /// 供 P4 的「注销/关机」路径复用：系统要关机时同样先还原。
    func systemWillPowerOff() {
        state.append(.warning, "系统即将关机/注销，准备还原 Dock")
    }
}

import AppKit
import Foundation
import Observation

/// 观察「当前在哪个桌面」以及「有哪些桌面」。
///
/// **事件源主次与计划原文相反**（P0 实测后修正，见 `docs/spikes.md`）：
/// 程序化切桌面时 `NSWorkspaceActiveSpaceDidChangeNotification` 根本不触发
/// （对照实验已排除环境因素），所以：
///
/// - **主：300 ms 轮询**。切桌面本身只要 20 ms，1 s 的检测延迟会明显滞后；
///   一次 `CGSGetActiveSpace` + `CGSCopyManagedDisplaySpaces` 是纯内存调用，开销可忽略。
/// - **辅：通知**。仅在**用户主动切换**时可能触发，用作降低延迟的快速通道。
///
/// 两条路都进同一个幂等的 `refresh()`，用 `(displayUUID, spaceUUID)` 去重。
@MainActor
@Observable
final class SpaceObserver {

    private(set) var desktops: [DesktopSpace] = []
    private(set) var activeSpace: DesktopSpace?
    /// 桌面列表发生变化（插拔显示器、增删桌面）时递增，供 UI 判断是否需要重建列表。
    private(set) var desktopListGeneration = 0

    /// 活动桌面变化时回调（已去重）。
    var onActiveSpaceChanged: ((DesktopSpace?) -> Void)?

    let provider: any SpaceProviding
    private let pollInterval: Duration

    private var pollTask: Task<Void, Never>?
    private var notificationToken: NSObjectProtocol?
    private var lastNotifiedKey: String?

    init(provider: any SpaceProviding, pollInterval: Duration = .milliseconds(300)) {
        self.provider = provider
        self.pollInterval = pollInterval
    }

    func start() {
        guard pollTask == nil else { return }
        observeSpaceChangeNotification()
        refresh()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let token = notificationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            notificationToken = nil
        }
    }

    /// 立即刷新一次（例如刚自己切换完桌面，不必等下一个轮询周期）。
    func refreshNow() { refresh() }

    private func observeSpaceChangeNotification() {
        notificationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    /// 幂等：两条事件源都会调它，重复调用不产生副作用。
    private func refresh() {
        let currentDesktops = provider.userDesktops()
        if currentDesktops != desktops {
            desktops = currentDesktops
            desktopListGeneration += 1
        }

        let activeID = provider.activeSpaceID()
        // 找不到匹配时保持 nil：可能正处于全屏 App 空间（type != 0），
        // 那不是用户桌面，不该被当作「切换了桌面」。
        let newActive = desktops.first { $0.id64 == activeID }

        if newActive != activeSpace {
            activeSpace = newActive
        }
        // 回调只在「桌面身份」变化时触发；同一桌面的重复采样不打扰上层。
        let key = newActive?.id
        if key != lastNotifiedKey {
            lastNotifiedKey = key
            onActiveSpaceChanged?(newActive)
        }
    }
}

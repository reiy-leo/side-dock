import Foundation

/// toast 的落地面：真实窗口 / 测试替身。
///
/// 参数刻意只收纯数据（文本 + `displayUUID`），这样调度逻辑完全不依赖 AppKit，
/// 可以脱离窗口单测 —— 和 `SpaceProviding` 隔离私有 API 是同一套路。
@MainActor
protocol ToastPresenting: AnyObject {
    func show(text: String, displayUUID: String?)
    func hide()
}

/// toast 调度：决定「什么时候弹、弹什么、什么时候收」，具体画在哪儿交给 `ToastPresenting`。
///
/// **触发点只有 `SpaceObserver.onActiveSpaceChanged` 一个。** 轮询每 300 ms 读活动空间，
/// 与切换来源无关，所以用户自己用触控板/快捷键/Mission Control 切桌面也会走这里。
/// 见 `docs/PLAN.md` §3.10。
@MainActor
final class ToastPresenter {

    private let presenter: ToastPresenting
    private let duration: Duration
    private let displayName: @MainActor (DesktopSpace) -> String
    private let isEnabled: @MainActor () -> Bool
    private let log: @MainActor (String) -> Void

    private var hideTask: Task<Void, Never>?

    /// 上一次通知到的桌面。**全屏空间（nil）会把它清成 nil**，于是
    /// 「启动首次采样」与「从全屏 App 退回桌面」都不会弹 —— 这两个是主要噪音源。
    private var lastDesktop: DesktopSpace?

    /// 累计弹出次数，供调试与测试断言。
    private(set) var shownCount = 0

    init(
        presenter: ToastPresenting,
        duration: Duration = .seconds(1),
        displayName: @escaping @MainActor (DesktopSpace) -> String,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.presenter = presenter
        self.duration = duration
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.log = log
    }

    /// 由观察器驱动。全屏 App 空间传 `nil`。
    func handleActiveSpaceChanged(_ space: DesktopSpace?) {
        // 记账放在最前面且无条件：即使当前关着开关，也要记住「上一个桌面是谁」，
        // 否则用户打开开关的瞬间会被补弹一次。
        defer { lastDesktop = space }

        guard let space, lastDesktop != nil else { return }
        show(text: displayName(space), displayUUID: space.displayUUID)
    }

    /// 手动触发（调试面板用）。
    func show(text: String, displayUUID: String? = nil) {
        guard isEnabled() else { return }
        present(text: text, displayUUID: displayUUID)
    }

    /// **无条件**提示。给"自愈还原"这类系统级告知用：它不是桌面切换提示，
    /// 不该被「切换桌面时显示桌面名称」这个开关关掉 —— 用户必须知道 Dock 被我们动过。
    func announce(_ text: String, displayUUID: String? = nil) {
        present(text: text, displayUUID: displayUUID)
    }

    private func present(text: String, displayUUID: String?) {
        // 1 秒内又切了桌面 → 取消上一次计时，直接换文字并重新计时。
        // 绝不并发多个计时器：否则旧计时器会把新提示提前收走。
        hideTask?.cancel()
        presenter.show(text: text, displayUUID: displayUUID)
        shownCount += 1
        log("toast 显示「\(text)」")

        hideTask = Task { [weak self, duration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.presenter.hide()
            self.hideTask = nil
            self.log("toast 隐藏")
        }
    }

    /// 立刻收起（关掉开关、或退出前）。
    func dismissNow() {
        hideTask?.cancel()
        hideTask = nil
        presenter.hide()
    }
}

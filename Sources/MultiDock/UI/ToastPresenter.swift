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
/// **两条落地通路**（2026-10-06 起）：
/// - 桌面名称（`show`）→ `namePresenter`（`DesktopNameOverlayWindow`，iPhone 锁屏式大字）
/// - 系统级告知（`announce`，自愈还原等）→ `presenter`（`HudToastWindow` 胶囊 HUD，
///   不受「切换桌面显示名称」开关影响——用户必须知道 Dock 被我们动过）
///
/// **触发点只有 `SpaceObserver.onActiveSpaceChanged` 一个。** 轮询每 300 ms 读活动空间，
/// 与切换来源无关，所以用户自己用触控板/快捷键/Mission Control 切桌面也会走这里。
/// 见 `docs/PLAN.md` §3.10。
@MainActor
final class ToastPresenter {

    private let presenter: ToastPresenting
    private let namePresenter: ToastPresenting
    private let duration: Duration
    private let displayName: @MainActor (DesktopSpace) -> String
    private let isEnabled: @MainActor () -> Bool
    private let log: @MainActor (String) -> Void

    private var hideTask: Task<Void, Never>?

    /// 当前正在展示的那条提示走的是哪条通路。超时/立即收起只收它，
    /// 不动另一条通路（省得把无关窗口拍灭）；两条通路接替时旧通路提前收。
    private var currentSink: ToastPresenting?

    /// 上一次通知到的桌面。**全屏空间（nil）会把它清成 nil**，于是
    /// 「启动首次采样」与「从全屏 App 退回桌面」都不会弹 —— 这两个是主要噪音源。
    private var lastDesktop: DesktopSpace?

    /// 累计弹出次数，供调试与测试断言。
    private(set) var shownCount = 0

    init(
        presenter: ToastPresenting,
        /// 桌面名称通路；不传则与 `presenter` 同窗（测试替身与旧行为都用这个默认）。
        namePresenter: ToastPresenting? = nil,
        duration: Duration = .seconds(1),
        displayName: @escaping @MainActor (DesktopSpace) -> String,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.presenter = presenter
        self.namePresenter = namePresenter ?? presenter
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

    /// 手动触发（调试面板用）：预览的是「桌面名称」展示，走锁屏式窗口。
    func show(text: String, displayUUID: String? = nil) {
        guard isEnabled() else { return }
        present(text: text, displayUUID: displayUUID, sink: namePresenter)
    }

    /// **无条件**提示。给"自愈还原"这类系统级告知用：它不是桌面切换提示，
    /// 不该被「切换桌面时显示桌面名称」这个开关关掉 —— 用户必须知道 Dock 被我们动过。
    /// 走胶囊 HUD 通路，与名称展示互不干扰。
    func announce(_ text: String, displayUUID: String? = nil) {
        present(text: text, displayUUID: displayUUID, sink: presenter)
    }

    private func present(text: String, displayUUID: String?, sink: ToastPresenting) {
        // 1 秒内又切了桌面 → 取消上一次计时，直接换文字并重新计时。
        // 绝不并发多个计时器：否则旧计时器会把新提示提前收走。
        // 换通路接替时（告知 → 名称或反过来），旧通路的计时已随取消作废，立即收掉，
        // 否则旧窗口会一直挂着等不到自己的计时器。
        hideTask?.cancel()
        if let currentSink, currentSink !== sink {
            currentSink.hide()
        }
        sink.show(text: text, displayUUID: displayUUID)
        currentSink = sink
        shownCount += 1
        log(L("toast 显示「\(text)」", "toast shown: “\(text)”"))

        hideTask = Task { [weak self, duration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.currentSink?.hide()
            self.currentSink = nil
            self.hideTask = nil
            self.log(L("toast 隐藏", "toast hidden"))
        }
    }

    /// 立刻收起（关掉开关、或退出前）。
    func dismissNow() {
        hideTask?.cancel()
        hideTask = nil
        currentSink?.hide()
        currentSink = nil
    }
}

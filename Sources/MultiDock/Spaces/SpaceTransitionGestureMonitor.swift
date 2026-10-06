import CoreGraphics
import Foundation

/// 三/四指切桌面前置手势的监视器（实验 26）。
///
/// HID 事件 type 30 是切桌面手势的指纹：翻转前 ~620 ms 内必现（13 次手势切换全有、
/// 8 次 ⌃→ 键盘切换零 30，实验 26 26c）；两指滚动（22）/翻页（31）与 MC/捏合手势
///（29 带 110=32）都不触发。监视到即回调，调用方（次级 Dock 条）在翻转发生前把条藏掉
/// —— 切桌面就「不跟着滑」。
///
/// **零权限**：listen-only tap 只要 mask 不含键盘事件（10/11/12）就能创建成功
/// （macOS 15.8.1 实测，实验 26 第 2 轮）；mask 刻意只有 type 30 一位
/// （spike 验证过的宽 mask 的子集，29 的环境采样流 ~200/s 一条都不要）。
@MainActor
final class SpaceTransitionGestureMonitor {

    /// type 30 没有公开的 CGEventType 名字（私有手势子事件），按位掩。
    private static let spaceSwitchGestureMask = CGEventMask(1 << 30)
    /// tap 创建失败时的重试间隔（偶发 nil 是环境态，不是代码错）。
    private static let retryInterval: Duration = .seconds(3)

    private let onGesture: () -> Void
    private let log: (String) -> Void
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTask: Task<Void, Never>?
    private var attempts = 0

    init(onGesture: @escaping () -> Void, log: @escaping (String) -> Void = { _ in }) {
        self.onGesture = onGesture
        self.log = log
    }

    func start() {
        tryTap()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.retryInterval)
                guard let self, self.tap == nil else { continue }
                self.tryTap()
            }
        }
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    private func tryTap() {
        guard tap == nil else { return }
        attempts += 1
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.spaceSwitchGestureMask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let monitor = Unmanaged<SpaceTransitionGestureMonitor>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                    // tap 源挂在主 run loop 的 .commonModes 上：回调必然已在主线程。
                    MainActor.assumeIsolated {
                        monitor.handleTapEvent(type)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if attempts == 1 || attempts % 10 == 0 {
                log(L("手势监视器：tap 创建失败（第 \(attempts) 次），\(Self.retryInterval) 后重试", "Gesture monitor: tap creation failed (attempt \(attempts)); retrying in \(Self.retryInterval)"))
            }
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        self.tap = tap
        CGEvent.tapEnable(tap: tap, enable: true)
        log(L("手势监视器：type 30 listen-only tap 已挂（零权限）", "Gesture monitor: type 30 listen-only tap installed (zero permissions)"))
    }

    /// tap 回调（主线程）：type 30 = 切桌面前置手势；tap 被系统超时禁用时立即重挂。
    private func handleTapEvent(_ type: CGEventType) {
        if type == .tapDisabledByTimeout, let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        if type.rawValue == 30 {
            onGesture()
        }
    }
}

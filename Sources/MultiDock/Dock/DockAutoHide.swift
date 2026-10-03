import Darwin
import Foundation

/// Dock「自动隐藏」的实时开关能力抽象（实验 20，`docs/spikes.md`）。
///
/// HIServices 的 `CoreDockSetAutoHideEnabled`（typed setter，与实测可用的
/// `CoreDockSetTileSize` 同族）对第三方**可用**：实时生效、Dock 自己持久化到域、
/// PID 不变。它让「重启 Dock」可以整个发生在屏幕外——
/// **先把 Dock 滑走 → 隐形重启 → 再滑回来**，用户看到的是两次平滑滑动，
/// 而不是「黑一下 + 图标重铺」（用户 2026-10-04 的原始诉求）。
protocol DockAutoHideControlling: Sendable {
    /// 实时切换自动隐藏。返回 false = 未生效（调用方退回不隐藏的老路径，别硬撑）。
    ///
    /// 以 getter 回读为准：MIG 发出去 ≠ Dock 认账（协议见证位同款教训）。
    @discardableResult
    func setAutoHide(_ on: Bool) -> Bool
    /// 当前自动隐藏状态（typed getter）。
    func autoHideIsOn() -> Bool
}

/// 真实实现：dlopen + dlsym（§5 约定：私有 API 不建立链接期依赖）。
///
/// HIServices 是 ApplicationServices 的公开子框架、每个 AppKit 进程里必然已加载，
/// 所以优先 `dlsym(RTLD_DEFAULT)`，拿不到再按安装名 dlopen。符号缺失（未来系统
/// 改名/移除）时构造返回 nil，调用方优雅降级为"不隐藏"。
struct HIServicesDockAutoHide: DockAutoHideControlling, Sendable {
    static func make() -> (any DockAutoHideControlling)? {
        HIServicesDockAutoHide()
    }

    private let setFn: @convention(c) (Bool) -> OSStatus
    private let getFn: @convention(c) () -> Bool

    /// Darwin 的 `RTLD_DEFAULT`（dlfcn.h 的 `((void*) -1)`，Swift 不导出这个常量）。
    init?() {
        let symbolNames = ["CoreDockSetAutoHideEnabled", "CoreDockGetAutoHideEnabled"]
        // Darwin 的 RTLD_DEFAULT = ((void*) -1)（dlfcn.h，Swift 不导出该常量），内联构造。
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -1)
        guard
            let s = dlsym(defaultHandle, symbolNames[0]),
            let g = dlsym(defaultHandle, symbolNames[1])
        else { return nil }
        setFn = unsafeBitCast(s, to: (@convention(c) (Bool) -> OSStatus).self)
        getFn = unsafeBitCast(g, to: (@convention(c) () -> Bool).self)
    }

    func setAutoHide(_ on: Bool) -> Bool {
        setFn(on) == 0 && getFn() == on
    }

    func autoHideIsOn() -> Bool { getFn() }
}

// spike-swipe-prefetch.swift — 实验 27：swipe 预隐藏（第 5 轮，26e）
//
// 第 1 轮：NSEvent .swipe 监视器在真实切桌面全程零事件 → 零权限 NSEvent 通道判死。
//          spike bug：CGSGetActiveSpace 签名抄错致轮询失明（已修）。
// 第 2 轮：listen-only CGEventTap 实测免授权挂上（mask 不含键盘）；两指横扫能触发
//          预隐藏（type 22 水平 burst，dx 20–48）；但 14 次三/四指真实切桌面
//          零 scroll(22)、零 swipe(31) 事件——切桌面手势只混在 type 29（gesture，
//          ~200/s 环境采样流）里，常规字段（39/40/45/50/55/58/85/87/101）与普通
//          触摸无区别，触发从未发生。
// 第 3 轮（26c）：宽 mask 指纹采集。指纹锁定 type 30：13 次三/四指手势切桌面的翻转
//          前 ~620ms 内全部出现 30（burst 30×1–30×5）；8 次 ⌃→ 键盘切换零 30。
//          首见字段：110=23 123=1 132=1 134=1 135=… 136=1 138=3 165=1（138 疑似指头数）。
//          另证：字段 55 镜像事件类型；169 是环境时间戳（本轮并入 29 基线）。
// 第 4 轮（26d）：30 → 预隐藏（生产候选规则）；22/31 只记不触发；每条 30 全字段落日志。
//          手测：横扫切桌面第一拍即隐 ✓、⌃→ 对照 ✓；但 MC/打断横扫/Launchpad 三场景
//          条永久消失。日志判读：状态机全对（超时渐回都触发、hidden 正确复位），
//          罪魁 = 「pullAndRise 的 +16ms moveToActiveSpace 把窗口绑进 MC/Launchpad
//          瞬态空间」→ 空间 ID 稳定后无人救 → 孤儿窗口。
// 第 5 轮（26e）：pollSpace 加安全网 + 心跳遥测。手测：三场景条能回来但延迟数秒。
//          日志定罪：九次超时渐回七次被安全网抓到 alpha=0.0 —— window.animator()
//          渐回 alpha 在本窗口上随机静默失效（26d「永久消失」同因，当时无网可救）；
//          onActive=false 全程仅 4 次（孤儿偶发，非主犯）。
// 第 6 轮（26f）：animator alpha 全部换成分步直设（fadeAlpha，6 步 × 20ms）；
//          安全网静默窗 800 → 250ms（连续未愈退避到 500ms）；
//          新增故障特征「hidden=false 但 alpha<1」。
//
// 手测项：
// ① 三/四指横扫切桌面 3–5 次（条应第一拍即隐、切换后沉没位升起）；
// ② 两指横扫网页（条应保持可见；若隐了=30 被两指误触发）；
// ③ 三指上滑 Mission Control / 四指捏合 Launchpad（条可隐藏，但关掉后 ≤1s 必须回来）；
// ④ 打断横扫（条隐藏后 600ms 应渐回）；
// ⑤ ⌃→ 键盘切换（对照：条不应消失）。

import AppKit
import CoreGraphics

setvbuf(stdout, nil, _IONBF, 0)

let t0 = DispatchTime.now().uptimeNanoseconds
func stamp() -> Int64 { Int64((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000) }
func log(_ s: String) { print("[\(stamp())ms] \(s)") }

// MARK: - SkyLight（空间检测，16 ms 轮询）

let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)!
let conn = unsafeBitCast(
    dlsym(sky, "CGSMainConnectionID")!, to: (@convention(c) () -> UInt32).self
)()
let getSpace = unsafeBitCast(
    dlsym(sky, "CGSGetActiveSpace")!, to: (@convention(c) (UInt32) -> UInt64).self
)
func activeSpace() -> UInt64 { getSpace(conn) }

// MARK: - 测试窗（复刻生产配方：层级 19、单空间、半露贴原生 Dock 上缘）

final class StripWindow: NSWindow {
    let targetFrame: NSRect

    init() {
        guard let screen = NSScreen.main,
              let face = SecondaryLayout.detectDockFace(screen: screen.frame, visible: screen.visibleFrame)
        else { fatalError("探测不到原生 Dock（须在屏、非自动隐藏）") }
        let size = SecondaryLayout.barSize(itemCount: 5, iconSize: 36)
        let placement = SecondaryLayout.placement(barSize: size, face: face)
        let tucked = placement.tucked
        targetFrame = placement.revealed
        super.init(
            contentRect: tucked,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: 19) // 原生 Dock（20）身后，与生产一致
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = false
        let strip = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: tucked.width, height: tucked.height))
        strip.material = .popover
        strip.blendingMode = .behindWindow
        strip.layer?.cornerRadius = 14
        strip.layer?.masksToBounds = true
        let tint = NSView(frame: NSRect(x: 0, y: 0, width: tucked.width, height: tucked.height))
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.55).cgColor
        tint.layer?.cornerRadius = 14
        let crown = NSView(frame: NSRect(x: 0, y: tucked.height - 3, width: tucked.width, height: 3))
        crown.wantsLayer = true
        crown.layer?.backgroundColor = NSColor.systemYellow.cgColor
        let label = NSTextField(labelWithString: "swipe 预隐藏测试")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: 10, y: tucked.height - 26))
        [strip, tint, crown, label].forEach { $0.autoresizingMask = [.width, .height] }
        contentView = NSView(frame: tucked)
        [strip, tint, crown, label].forEach { contentView!.addSubview($0) }
        orderFrontRegardless()
        log("测试窗已挂：半露 \(tucked)（黄顶线可见即半露正确）")
    }
}

enum SecondaryLayout {
    static func detectDockFace(screen: CGRect, visible: CGRect) -> (visible: CGRect, orientation: Int)? {
        let bottom = visible.minY - screen.minY
        let left = visible.minX - screen.minX
        let right = screen.maxX - visible.maxX
        if bottom >= 30 { return (visible, 0) }
        if left >= 30 { return (visible, 1) }
        if right >= 30 { return (visible, 2) }
        return nil
    }
    static func barSize(itemCount: Int, iconSize: CGFloat) -> CGSize {
        CGSize(width: CGFloat(max(itemCount, 1)) * (iconSize + 8) + 16, height: iconSize + 20)
    }
    static func placement(barSize: CGSize, face: (visible: CGRect, orientation: Int))
        -> (revealed: NSRect, tucked: NSRect)
    {
        let revealed = NSRect(
            x: face.visible.midX - barSize.width / 2,
            y: face.visible.minY + 4,
            width: barSize.width,
            height: barSize.height
        )
        return (revealed, revealed.offsetBy(dx: 0, dy: -barSize.height / 2))
    }
}

// MARK: - 编排

final class Spike {
    let window: StripWindow
    var lastSpace = activeSpace()
    var revealTask: Task<Void, Never>?
    var hidden = false
    /// 最近一次状态机动作（预隐藏/翻转/超时渐回/拉回）时刻；安全网静默窗基准。
    var lastEventAt: Int64 = 0
    /// 心跳计数（每 ~125 拍 ≈ 2s 遥测一行）。
    var beat = 0
    /// 分步 alpha 渐变任务（animator 渐回实测不可靠：26e 九次超时渐回七次卡 alpha=0.0，
    /// 26d「永久消失」同因——当时无安全网。26f 起改手动分步直设）。
    var revealFadeTask: Task<Void, Never>?
    /// 安全网连续未愈次数（退避：250 → 500ms，防 MC 打开期间反复闪动）。
    var netBackoff = 0
    var crossBehavior: NSWindow.CollectionBehavior {
        [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
    var singleBehavior: NSWindow.CollectionBehavior {
        [.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    init() { window = StripWindow() }

    private var seenTypes: Set<Int64> = []
    private var lastTap: (t: Int64, type: Int64, dx: Int64, dy: Int64)?
    private var recentEvents: [(t: Int64, type: Int64)] = []

    /// 29 的环境基线字段：普通触控板接触每次采样都带（含 169 时间戳，26c 实测）。
    private static let ambient29Fields: Set<UInt32> = [39, 40, 45, 50, 55, 58, 85, 87, 101, 169]

    /// tap 事件入口（26d）。职责：
    /// 1) 每类型首见 → 全字段转储（0...255 非零）；
    /// 2) 29 → 只转储基线外非常规字段（环境采样静默，不刷屏）；
    /// 3) 30 → 预隐藏（26c 实证：手势切桌面翻转前 ~620ms 内必现；键盘切换零 30），
    ///    每条全字段落日志（验证每次手势都发 30 + 采集误报面）；
    /// 4) 22 / 31 → 只记不触发（两指滚动/翻页是生产要排除的误报源）。
    func onTapEvent(event: CGEvent, type: Int64) {
        let now = stamp()
        let dx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let dy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        lastTap = (now, type, dx, dy)
        recentEvents.append((now, type))
        if recentEvents.count > 512 { recentEvents = Array(recentEvents.suffix(512)) }

        if !seenTypes.contains(type) {
            seenTypes.insert(type)
            log("tap 首见 type=\(type) dx=\(dx) dy=\(dy) 字段：\(Self.fieldDump(event, skip: []))")
        }

        if type == 29 {
            let fields = Self.fieldDump(event, skip: Self.ambient29Fields)
            if !fields.isEmpty { log("29 非常规字段：\(fields)") }
            return
        }

        if type == 30 {
            log("tap30 字段：\(Self.fieldDump(event, skip: [])) → 预隐藏")
            onSwipe(source: "tap30")
            return
        }

        if type == 22, abs(dx) >= 20 {
            log("tap22 dx=\(dx)（只记不触发）")
        } else if type == 31 {
            log("tap31 dx=\(dx)（只记不触发）")
        }
    }

    private static func fieldDump(_ event: CGEvent, skip: Set<UInt32>) -> String {
        var fields: [String] = []
        for raw in 0...255 {
            guard let f = CGEventField(rawValue: UInt32(raw)), !skip.contains(UInt32(raw)) else { continue }
            let v = event.getIntegerValueField(f)
            if v != 0 { fields.append("\(raw)=\(v)") }
        }
        return fields.joined(separator: " ")
    }

    func onSwipe(source: String, deltaX: CGFloat = 0) {
        revealTask?.cancel()
        revealFadeTask?.cancel()
        lastEventAt = stamp()
        if hidden {
            log("swipe(\(source)) 但已在预隐藏态 → 保持（续 600ms 超时）")
        } else {
            hidden = true
            window.alphaValue = 0
            log("swipe(\(source), dx=\(Int(deltaX))) → 预隐藏 alpha=0")
        }
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.revealOnTimeout()
        }
    }

    /// 分步直设 alpha（不用 animator：26e 实测九次渐回七次静默卡死 alpha=0.0）。
    /// 被取消时 alpha 停在中间值——调用方（onSwipe/pullAndRise）随即置 0，无残留。
    private func fadeAlpha(to target: CGFloat, steps: Int = 6, intervalMs: UInt64 = 20) {
        revealFadeTask?.cancel()
        let from = window.alphaValue
        let delta = target - from
        guard abs(delta) > 0.005 else { return }
        revealFadeTask = Task { @MainActor [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(intervalMs))
                guard !Task.isCancelled, let self else { return }
                self.window.alphaValue = from + delta * CGFloat(step) / CGFloat(steps)
            }
        }
    }

    private func revealOnTimeout() {
        lastEventAt = stamp()
        log("600ms 无空间切换 → 超时渐回（误扫）onActive=\(window.isOnActiveSpace)")
        fadeAlpha(to: 1)
        hidden = false
    }

    func pollSpace() {
        let s = activeSpace()
        let now = stamp()
        beat += 1
        if beat % 125 == 0 {
            log("心跳：space=\(s) onActive=\(window.isOnActiveSpace) alpha=\(window.alphaValue) frame=\(Int(window.frame.minX)),\(Int(window.frame.minY)) hidden=\(hidden)")
        }
        guard s != lastSpace else {
            // 安全网：animator 卡死 / 孤儿绑定 / 卡沉没位的兜底。静默窗随连续未愈退避
            // （250 → 500ms，防 MC 打开期间反复闪动）。正常预隐藏不会踩中条件：
            // hidden=true 期间不查 alpha，30s 会持续续 lastEventAt，翻转前 ≤600ms。
            if now - lastEventAt > 250 << min(netBackoff, 1),
               !window.isOnActiveSpace
               || window.frame.minX < 0 || window.frame.minY < 0
               || (!hidden && window.alphaValue < 0.99) {
                netBackoff += 1
                log("安全网 #\(netBackoff)：onActive=\(window.isOnActiveSpace) alpha=\(window.alphaValue) frame=\(Int(window.frame.minX)),\(Int(window.frame.minY)) → 重挂")
                pullAndRise()
            }
            return
        }
        lastSpace = s
        revealTask?.cancel()
        revealFadeTask?.cancel()
        lastEventAt = now
        netBackoff = 0
        var windowCounts: [Int64: Int] = [:]
        for e in recentEvents where now - e.t <= 600 {
            windowCounts[e.type, default: 0] += 1
        }
        let windowSummary = windowCounts.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        if let last = lastTap {
            log("空间切换 → 前600ms类型：\(windowSummary.isEmpty ? "无" : windowSummary)；距最近 tap \(now - last.t)ms（type=\(last.type)）hidden=\(hidden) → 拉回 + 沉没位升起")
        } else {
            log("空间切换 → 前600ms类型：\(windowSummary.isEmpty ? "无" : windowSummary)；零 tap hidden=\(hidden) → 拉回 + 沉没位升起")
        }
        pullAndRise()
    }

    private func pullAndRise() {
        lastEventAt = stamp()
        let target = window.targetFrame
        let sinkY = (window.screen ?? NSScreen.main)!.visibleFrame.minY - target.height - 6
        window.alphaValue = 0
        window.setFrame(
            NSRect(x: target.minX, y: sinkY, width: target.width, height: target.height),
            display: false
        )
        window.collectionBehavior = crossBehavior
        window.orderFrontRegardless()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self else { return }
            self.window.collectionBehavior = self.singleBehavior
            log("拉回 +16ms：onActive=\(self.window.isOnActiveSpace) space=\(activeSpace())")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            self?.hidden = false
        }
        fadeAlpha(to: 1)
    }
}

// MARK: - main

let spike = Spike()

// 通道 A：NSEvent 全局 monitor（零权限）
NSEvent.addGlobalMonitorForEvents(matching: [.swipe]) { e in
    spike.onSwipe(source: "global", deltaX: CGFloat(e.deltaX))
}
NSEvent.addLocalMonitorForEvents(matching: [.swipe]) { e in
    spike.onSwipe(source: "local", deltaX: CGFloat(e.deltaX))
    return e
}
log("通道 A 已挂：NSEvent global+local（.swipe，零权限）")

// 通道 B：CGEventTap 宽 mask（scrollWheel 22 | gesture 29 | swipe 31），listen-only，3 秒重试
var tapEstablished = false
var tapAttempts = 0
func tryTap() {
    guard !tapEstablished else { return }
    tapAttempts += 1
    var maskBits: UInt64 = 0
    for t: UInt32 in 0...63 where t != 10 && t != 11 && t != 12 {
        maskBits |= 1 << UInt64(t)
    }
    let mask = CGEventMask(maskBits) // 26c：除键盘外全类型，找切桌面手势的 HID 指纹
    guard let tap = CGEvent.tapCreate(
        tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
        callback: { _, type, event, _ in
            spike.onTapEvent(event: event, type: Int64(type.rawValue))
            return Unmanaged.passUnretained(event)
        }, userInfo: nil
    ) else {
        if tapAttempts == 1 || tapAttempts % 10 == 0 {
            log("通道 B 仍不可用：tapCreate nil（未授「输入监控」），已试 \(tapAttempts) 次")
        }
        return
    }
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    tapEstablished = true
    log("通道 B 已挂：CGEventTap listen-only（除键盘外全类型）")
}
tryTap()
Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in tryTap() }

// 16 ms 空间轮询（实验 25 教训：必须用 RunLoop Timer，DispatchSourceTimer 不 fire）
Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in spike.pollSpace() }
log("轮询已挂：16 ms CGSGetActiveSpace")
log("── 26e 手测：① 横扫切桌面（第一拍即隐）；② 两指横扫（不隐）；③ MC/Launchpad（关掉后 ≤1s 回来）；④ 打断横扫（600ms 渐回）；⑤ ⌃→（不隐）──")

RunLoop.main.run()

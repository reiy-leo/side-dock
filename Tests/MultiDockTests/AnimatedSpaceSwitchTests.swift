import XCTest
@testable import MultiDock

/// 带动画切换（合成系统快捷键）的路由与兜底。
///
/// 这组测试防的坑：**合成了但系统没切**（热键被用户改过、事件被吞）时不能没有下文——
/// 必须超时兜底硬切；以及跨选/循环跳**不许**走合成（合成只能表达相邻一步）。
@MainActor
final class AnimatedSpaceSwitchTests: XCTestCase {

    /// 合成器替身：记录调用、可配置"合成后系统到底切没切"。
    private final class FakeSynthesizer: SpaceStepSynthesizing {
        var isPermitted = true
        /// false = 模拟"投递了但系统没反应"（热键被改/被拦）。
        var systemActuallySwitches = true
        private(set) var calls: [Bool] = []   // true = previous

        @discardableResult
        func synthesizeStep(previous: Bool) -> Bool {
            calls.append(previous)
            return true
        }
    }

    private func makeObserver(
        _ provider: FakeSpaceProvider
    ) -> SpaceObserver {
        let observer = SpaceObserver(provider: provider)
        observer.refreshNow()
        return observer
    }

    private func makeSwitcher<S: SpaceStepSynthesizing>(
        _ provider: FakeSpaceProvider,
        synthesizer: S,
        timeout: Duration = .milliseconds(120),
        poll: Duration = .milliseconds(5)
    ) -> SpaceSwitcher {
        SpaceSwitcher(
            observer: makeObserver(provider),
            synthesizer: synthesizer,
            synthesisTimeout: timeout,
            pollInterval: poll
        )
    }

    /// 真的把 active 切走的替身（模拟"系统快捷键生效"）。
    private final class LiveSynthesizer: SpaceStepSynthesizing {
        let provider: FakeSpaceProvider
        var isPermitted = true
        private(set) var calls: [Bool] = []

        init(provider: FakeSpaceProvider) { self.provider = provider }

        func synthesizeStep(previous: Bool) -> Bool {
            calls.append(previous)
            let list = provider.userDesktops()
            guard
                let current = list.first(where: { $0.id64 == provider.activeSpaceID() }),
                let index = list.firstIndex(of: current)
            else { return false }
            let next = previous ? index - 1 : index + 1
            guard list.indices.contains(next) else { return false }
            _ = provider.setCurrentSpace(list[next])
            return true
        }
    }

    // MARK: - 相邻一步走合成

    func testAdjacentNextUsesSynthesizerAndDoesNotHardSwitch() async throws {
        let spaces = FakeSpaceProvider.desktops(count: 3)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let observer = makeObserver(provider)
        let synthesizer = FakeSynthesizer()

        let switcher = SpaceSwitcher(
            observer: observer,
            synthesizer: synthesizer,
            synthesisTimeout: .milliseconds(50),
            pollInterval: .milliseconds(5)
        )
        switcher.switchTo(spaces[1], style: .animatedStep(.next))

        XCTAssertEqual(synthesizer.calls, [false], "⌃→ 合成了一次")
        XCTAssertTrue(
            provider.switchTargets.isEmpty,
            "合成投递后不该立刻硬切——先等系统动画（确认在异步进行）"
        )
    }

    func testAdjacentPreviousSynthesizesControlLeft() {
        let spaces = FakeSpaceProvider.desktops(count: 3)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[1].id64)
        let synthesizer = FakeSynthesizer()

        let switcher = SpaceSwitcher(
            observer: makeObserver(provider),
            synthesizer: synthesizer,
            synthesisTimeout: .milliseconds(50),
            pollInterval: .milliseconds(5)
        )
        switcher.switchTo(spaces[0], style: .animatedStep(.previous))

        XCTAssertEqual(synthesizer.calls, [true], "⌃← 合成了一次")
    }

    // MARK: - 不该走合成的情形

    func testCrossDesktopSelectionHardSwitches() {
        // 菜单里直接点某个桌面（不是相邻一步）：合成表达不了，走硬切。
        let spaces = FakeSpaceProvider.desktops(count: 4)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let synthesizer = FakeSynthesizer()
        let switcher = makeSwitcher(provider, synthesizer: synthesizer)

        switcher.switchTo(spaces[3])   // 默认 .hard

        XCTAssertTrue(synthesizer.calls.isEmpty, "跨选不该合成")
        XCTAssertEqual(provider.switchTargets, [spaces[3].id64], "直接硬切到位")
    }

    func testWrapAroundDoesNotSynthesize() {
        // 三个桌面、当前在最后一个：⌃→ 在系统里不循环，所以要走「下一步 = 首个」的硬切。
        let spaces = FakeSpaceProvider.desktops(count: 3)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[2].id64)
        let synthesizer = FakeSynthesizer()
        let switcher = makeSwitcher(provider, synthesizer: synthesizer)

        let target = switcher.target(.next)
        XCTAssertEqual(target?.id64, spaces[0].id64, "语义上仍是循环到首个")
        switcher.switchTo(spaces[0], style: .animatedStep(.next))

        XCTAssertTrue(synthesizer.calls.isEmpty, "循环跳不合成（系统键盘不循环）")
        XCTAssertEqual(provider.switchTargets, [spaces[0].id64])
    }

    func testNotPermittedFallsBackToHardSwitch() {
        let spaces = FakeSpaceProvider.desktops(count: 3)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let synthesizer = FakeSynthesizer()
        synthesizer.isPermitted = false
        let switcher = makeSwitcher(provider, synthesizer: synthesizer)

        switcher.switchTo(spaces[1], style: .animatedStep(.next))

        XCTAssertTrue(synthesizer.calls.isEmpty, "没权限时不投递")
        XCTAssertEqual(provider.switchTargets, [spaces[1].id64], "退化为硬切，功能不受影响")
    }

    func testNoSynthesizerKeepsLegacyBehavior() {
        // 不注入合成器（测试/特殊环境）：与旧版完全一致。
        let spaces = FakeSpaceProvider.desktops(count: 3)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let switcher = SpaceSwitcher(observer: makeObserver(provider))

        let result = switcher.step(.next)

        XCTAssertEqual(result?.id64, spaces[1].id64)
        XCTAssertEqual(provider.switchTargets, [spaces[1].id64], "硬切")
    }

    // MARK: - 兜底（合成没生效）

    func testSynthesisThatDoesNothingFallsBackToHardSwitch() async throws {
        // 合成投递了但系统没切（热键被改/被拦）：超时后必须硬切兜底，不能卡住不切。
        let spaces = FakeSpaceProvider.desktops(count: 3)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let synthesizer = FakeSynthesizer()
        synthesizer.systemActuallySwitches = false   // 替身只记录，不改 active
        let switcher = makeSwitcher(provider, synthesizer: synthesizer, timeout: .milliseconds(80))

        switcher.switchTo(spaces[1], style: .animatedStep(.next))
        XCTAssertEqual(synthesizer.calls, [false], "先合成")
        XCTAssertTrue(provider.switchTargets.isEmpty, "刚投递时还没硬切")

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(
            provider.switchTargets,
            [spaces[1].id64],
            "超时后兜底硬切——绝不能停在「合成了但没切」的状态"
        )
    }

    func testSynthesisThatWorksDoesNotHardSwitchAfterwards() async throws {
        // 反方向：合成真的把系统切过去了，兜底就不该再硬切一次（否则会多跳一拍）。
        let spaces = FakeSpaceProvider.desktops(count: 3)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let synthesizer = LiveSynthesizer(provider: provider)
        let switcher = makeSwitcher(provider, synthesizer: synthesizer, timeout: .milliseconds(60))

        switcher.switchTo(spaces[1], style: .animatedStep(.next))
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            provider.switchTargets,
            [spaces[1].id64],
            "合成生效后不该再补一次硬切（那会多跳一拍）"
        )
    }

    // MARK: - 相邻判定

    func testAdjacencyRules() {
        let spaces = FakeSpaceProvider.desktops(count: 4)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let switcher = makeSwitcher(provider, synthesizer: FakeSynthesizer())

        XCTAssertTrue(switcher.isAdjacentStep(to: spaces[1], direction: .next))
        XCTAssertFalse(switcher.isAdjacentStep(to: spaces[2], direction: .next), "隔一个不是相邻")
        XCTAssertFalse(switcher.isAdjacentStep(to: spaces[3], direction: .next), "跨选不是相邻")
        XCTAssertFalse(
            switcher.isAdjacentStep(to: spaces[3], direction: .previous),
            "当前在第一个桌面时，回退是循环跳（不是相邻）"
        )

        // 从末尾回退一格才是相邻。
        let tail = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[3].id64)
        let tailSwitcher = makeSwitcher(tail, synthesizer: FakeSynthesizer())
        XCTAssertTrue(tailSwitcher.isAdjacentStep(to: spaces[2], direction: .previous))

        // 只有两个桌面时 0→1 是正常一步（可合成）。
        let two = FakeSpaceProvider.desktops(count: 2)
        let twoProvider = FakeSpaceProvider(desktops: two, activeSpaceID: two[0].id64)
        let twoSwitcher = makeSwitcher(twoProvider, synthesizer: FakeSynthesizer())
        XCTAssertTrue(
            twoSwitcher.isAdjacentStep(to: two[1], direction: .next),
            "两桌面时下一步就是相邻一步"
        )
        XCTAssertFalse(
            twoSwitcher.isAdjacentStep(to: two[0], direction: .previous),
            "两桌面时回退是循环跳"
        )
    }

    /// 兜底防抢跑：超时时空间已不在起点（系统过渡迟到）→ 不该再硬切。
    func testLateSystemTransitionIsNotOverriddenByFallback() async throws {
        let spaces = FakeSpaceProvider.desktops(count: 3)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let synthesizer = FakeSynthesizer()
        let switcher = makeSwitcher(provider, synthesizer: synthesizer, timeout: .milliseconds(60))

        switcher.switchTo(spaces[1], style: .animatedStep(.next))
        // 模拟系统过渡"迟到"：超时窗口内先切到别处（不是目标，也不是起点）。
        provider.setCurrentSpace(spaces[2])
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(
            provider.switchTargets,
            [spaces[2].id64],
            "空间已不在起点时不该兜底硬切——会和迟到的系统过渡打架"
        )
    }

    // MARK: - 「切换到桌面 N」（2026-10-25）

    /// 可配置的合成器替身：相邻快捷键开没开、哪些「桌面 N」可用。
    private final class JumpSynthesizer: SpaceStepSynthesizing {
        var isPermitted = true
        var stepKeysEnabled = true
        var jumpable: Set<Int> = []
        private(set) var steps: [Bool] = []
        private(set) var jumps: [Int] = []

        func synthesizeStep(previous: Bool) -> Bool {
            guard stepKeysEnabled else { return false }
            steps.append(previous)
            return true
        }
        func canJump(toDesktop number: Int) -> Bool { jumpable.contains(number) }
        func synthesizeJump(toDesktop number: Int) -> Bool {
            guard jumpable.contains(number) else { return false }
            jumps.append(number)
            return true
        }
    }

    func testWrapAroundUsesSwitchToDesktopNInsteadOfManySteps() {
        // 从最后一个（第 10 个）循环回第 1 个：一次「切换到桌面 1」，不连按 9 次 ⌃←。
        let spaces = FakeSpaceProvider.desktops(count: 10)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[9].id64)
        let synthesizer = JumpSynthesizer()
        synthesizer.jumpable = Set(1...9)
        let switcher = makeSwitcher(provider, synthesizer: synthesizer)

        switcher.switchTo(spaces[0], style: .animatedStep(.next))

        XCTAssertTrue(synthesizer.steps.isEmpty, "循环跳不连打相邻步")
        XCTAssertEqual(synthesizer.jumps, [1], "一次直接跳到桌面 1")
        XCTAssertTrue(provider.switchTargets.isEmpty, "投递后先等系统动画，不立刻硬切")
    }

    func testMenuSelectionJumpsDirectly() {
        let spaces = FakeSpaceProvider.desktops(count: 5)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let synthesizer = JumpSynthesizer()
        synthesizer.jumpable = [4]
        let switcher = makeSwitcher(provider, synthesizer: synthesizer)

        switcher.switchTo(spaces[3], style: .animated)

        XCTAssertEqual(synthesizer.jumps, [4])
        XCTAssertTrue(synthesizer.steps.isEmpty)
    }

    func testMenuSelectionOfNeighbourUsesStep() {
        let spaces = FakeSpaceProvider.desktops(count: 5)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[2].id64)
        let synthesizer = JumpSynthesizer()
        synthesizer.jumpable = Set(1...5)
        let switcher = makeSwitcher(provider, synthesizer: synthesizer)

        switcher.switchTo(spaces[1], style: .animated)

        XCTAssertEqual(synthesizer.steps, [true], "菜单点相邻桌面走 ⌃←")
        XCTAssertTrue(synthesizer.jumps.isEmpty)
    }

    func testJumpShortcutOffHardSwitchesImmediately() {
        let spaces = FakeSpaceProvider.desktops(count: 4)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[3].id64)
        let synthesizer = JumpSynthesizer()   // 没开任何「桌面 N」
        let switcher = makeSwitcher(provider, synthesizer: synthesizer)

        switcher.switchTo(spaces[0], style: .animatedStep(.next))

        XCTAssertTrue(synthesizer.jumps.isEmpty)
        XCTAssertEqual(provider.switchTargets, [spaces[0].id64], "快捷键没开：当场硬切，不白等超时")
    }

    func testStepShortcutOffFallsBackToJumpThenHard() {
        let spaces = FakeSpaceProvider.desktops(count: 3)
        let provider = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let synthesizer = JumpSynthesizer()
        synthesizer.stepKeysEnabled = false
        synthesizer.jumpable = [2]
        let switcher = makeSwitcher(provider, synthesizer: synthesizer)

        switcher.switchTo(spaces[1], style: .animatedStep(.next))
        XCTAssertEqual(synthesizer.jumps, [2], "⌃→ 关着时用「切换到桌面 2」")

        let provider2 = FakeSpaceProvider(desktops: spaces, activeSpaceID: spaces[0].id64)
        let synthesizer2 = JumpSynthesizer()
        synthesizer2.stepKeysEnabled = false
        let switcher2 = makeSwitcher(provider2, synthesizer: synthesizer2)
        switcher2.switchTo(spaces[1], style: .animatedStep(.next))
        XCTAssertEqual(provider2.switchTargets, [spaces[1].id64], "两种快捷键都关：硬切")
    }

    func testMultipleDisplaysNeverJump() {
        let left = FakeSpaceProvider.desktops(count: 3, displayUUID: "DISP-1")
        let right = FakeSpaceProvider.desktops(count: 3, displayUUID: "DISP-2", baseID: 200)
        let provider = FakeSpaceProvider(desktops: left + right, activeSpaceID: left[2].id64)
        let synthesizer = JumpSynthesizer()
        synthesizer.jumpable = Set(1...16)
        let switcher = makeSwitcher(provider, synthesizer: synthesizer)

        XCTAssertNil(switcher.jumpNumber(for: left[0]), "多屏编号规则未验证，不给 N")
        switcher.switchTo(left[0], style: .animatedStep(.next))
        XCTAssertTrue(synthesizer.jumps.isEmpty)
        XCTAssertEqual(provider.switchTargets, [left[0].id64])
    }

    // MARK: - 系统热键表解析

    func testHotKeyIDs() {
        XCTAssertEqual(SpaceShortcut.step(previous: true).hotKeyID, 79)
        XCTAssertEqual(SpaceShortcut.step(previous: false).hotKeyID, 81)
        XCTAssertEqual(SpaceShortcut.desktop(1).hotKeyID, 118)
        XCTAssertEqual(SpaceShortcut.desktop(16).hotKeyID, 133)
        XCTAssertNil(SpaceShortcut.desktop(17).hotKeyID)
        XCTAssertNil(SpaceShortcut.desktop(0).hotKeyID)
    }

    func testParseKeepsRegisteredModifiersIncludingFn() {
        // 实验 28 实测的 ⌃→ 登记：[65535, 124, 8650752] = Control + SecondaryFn。
        let table: [String: Any] = [
            "81": ["enabled": true, "value": ["parameters": [65535, 124, 8_650_752], "type": "standard"]],
            "118": ["enabled": false, "value": ["parameters": [49, 18, 262_144], "type": "standard"]],
            "119": ["enabled": NSNumber(value: 1), "value": ["parameters": [NSNumber(value: 50), NSNumber(value: 19), NSNumber(value: 262_144)], "type": "standard"]],
            "120": ["enabled": true, "value": ["parameters": [65535, 65535, 0], "type": "standard"]],
        ]
        let right = SymbolicHotKeys.parse(table, id: 81)
        XCTAssertEqual(right?.keyCode, 124)
        XCTAssertTrue(right?.eventFlags.contains(.maskControl) ?? false)
        XCTAssertTrue(right?.eventFlags.contains(.maskSecondaryFn) ?? false, "方向键热键带 fn 位，合成必须原样带上")
        XCTAssertNil(SymbolicHotKeys.parse(table, id: 118), "关着的不算")
        XCTAssertEqual(SymbolicHotKeys.parse(table, id: 119)?.keyCode, 19, "NSNumber 形式也能读")
        XCTAssertNil(SymbolicHotKeys.parse(table, id: 120), "没设键（65535）不算")
        XCTAssertNil(SymbolicHotKeys.parse(table, id: 121), "表里没有不算")
    }
}

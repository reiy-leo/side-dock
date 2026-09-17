import XCTest
@testable import MultiDock

/// 桌面循环切换与观察器去重。对应 `docs/PLAN.md` §4 里「循环取下一个」的验收点。
@MainActor
final class SpaceSwitcherTests: XCTestCase {

    /// 测试替身：能记录切换历史、并真的改变"当前活动空间"。
    private final class FakeProvider: SpaceProviding, @unchecked Sendable {
        var isAvailable = true
        var unavailableReason: String?
        var desktops: [DesktopSpace] = []
        var activeID: UInt64 = 0
        private(set) var switchHistory: [UInt64] = []

        func userDesktops() -> [DesktopSpace] { desktops }
        func activeSpaceID() -> UInt64 { activeID }
        @discardableResult
        func setCurrentSpace(_ space: DesktopSpace) -> Bool {
            switchHistory.append(space.id64)
            activeID = space.id64
            return true
        }
    }

    private let displayA = "DISPLAY-A"
    private let displayB = "DISPLAY-B"

    private func space(_ ordinal: Int, id: UInt64, display: String? = nil, type: Int = 0) -> DesktopSpace {
        DesktopSpace(
            displayUUID: display ?? displayA,
            spaceUUID: String(format: "UUID-%02d", ordinal),
            id64: id,
            type: type,
            ordinal: ordinal
        )
    }

    private func makeObserver(_ provider: FakeProvider) -> SpaceObserver {
        let observer = SpaceObserver(provider: provider)
        observer.refreshNow()
        return observer
    }

    // MARK: - 循环

    func testNextWrapsAroundAtTheEnd() {
        let provider = FakeProvider()
        provider.desktops = [space(1, id: 6), space(2, id: 7), space(3, id: 8)]
        provider.activeID = 8
        let switcher = SpaceSwitcher(observer: makeObserver(provider))

        XCTAssertEqual(switcher.step(.next)?.id64, 6, "最后一个桌面再往后应回到第一个")
    }

    func testPreviousWrapsAroundAtTheStart() {
        let provider = FakeProvider()
        provider.desktops = [space(1, id: 6), space(2, id: 7), space(3, id: 8)]
        provider.activeID = 6
        let switcher = SpaceSwitcher(observer: makeObserver(provider))

        XCTAssertEqual(switcher.step(.previous)?.id64, 8, "第一个桌面再往前应回到最后一个")
    }

    func testCycleVisitsEveryDesktopExactlyOnce() {
        let provider = FakeProvider()
        provider.desktops = [space(1, id: 6), space(2, id: 7), space(3, id: 8)]
        provider.activeID = 6
        let switcher = SpaceSwitcher(observer: makeObserver(provider))

        var visited: [UInt64] = []
        for _ in 0..<3 {
            if let target = switcher.step(.next) { visited.append(target.id64) }
        }
        XCTAssertEqual(visited, [7, 8, 6], "三次「下一个」应正好走完一圈")
    }

    // MARK: - 多显示器

    func testSwitchingStaysOnTheSameDisplay() {
        // 多显示器时映射键是 (displayUUID, spaceUUID)，绝不能跨显示器循环。
        let provider = FakeProvider()
        provider.desktops = [
            space(1, id: 6, display: displayA),
            space(2, id: 7, display: displayA),
            space(1, id: 20, display: displayB),
            space(2, id: 21, display: displayB),
        ]
        provider.activeID = 7
        let switcher = SpaceSwitcher(observer: makeObserver(provider))

        let target = switcher.step(.next)
        XCTAssertEqual(target?.displayUUID, displayA, "不能跳到另一台显示器的桌面")
        XCTAssertEqual(target?.id64, 6)
    }

    func testNoSwitchWhenOnlyOneDesktopOnDisplay() {
        let provider = FakeProvider()
        provider.desktops = [
            space(1, id: 6, display: displayA),
            space(1, id: 20, display: displayB),
            space(2, id: 21, display: displayB),
        ]
        provider.activeID = 6
        let switcher = SpaceSwitcher(observer: makeObserver(provider))

        XCTAssertNil(switcher.step(.next), "当前显示器只有一个桌面时不该切换")
        XCTAssertTrue(provider.switchHistory.isEmpty)
    }

    func testSwitchToSpecificDesktop() {
        let provider = FakeProvider()
        provider.desktops = [space(1, id: 6), space(2, id: 7)]
        provider.activeID = 6
        let observer = makeObserver(provider)
        let switcher = SpaceSwitcher(observer: observer)

        let target = space(2, id: 7)
        XCTAssertEqual(switcher.switchTo(target)?.id64, 7)
        XCTAssertEqual(provider.switchHistory, [7])
        XCTAssertEqual(observer.activeSpace?.id64, 7, "切换后应立即刷新，不等下一个轮询周期")
    }

    // MARK: - 降级

    func testUnavailableProviderRefusesToSwitch() {
        let provider = FakeProvider()
        provider.isAvailable = false
        provider.unavailableReason = "SkyLight 不可用"
        provider.desktops = [space(1, id: 6), space(2, id: 7)]
        provider.activeID = 6
        let switcher = SpaceSwitcher(observer: makeObserver(provider))

        XCTAssertNil(switcher.step(.next))
        XCTAssertTrue(provider.switchHistory.isEmpty)
    }

    // MARK: - 观察器去重与全屏过滤

    func testActiveSpaceChangeFiresCallbackOncePerRealChange() {
        let provider = FakeProvider()
        provider.desktops = [space(1, id: 6), space(2, id: 7)]
        provider.activeID = 6
        let observer = SpaceObserver(provider: provider)

        var changes: [UInt64?] = []
        observer.onActiveSpaceChanged = { changes.append($0?.id64) }
        observer.refreshNow()

        // 模拟 300 ms 轮询：同一个桌面上反复采样不该重复回调。
        for _ in 0..<5 { observer.refreshNow() }
        XCTAssertEqual(changes.count, 1, "同一桌面重复采样不应重复回调")

        provider.activeID = 7
        observer.refreshNow()
        observer.refreshNow()
        XCTAssertEqual(changes.count, 2, "真正换了桌面才回调")
        XCTAssertEqual(changes.last!, 7)
    }

    func testFullscreenSpaceIsNotTreatedAsDesktop() {
        // 关键回归：进入全屏 App 时活动空间不属于任何用户桌面，
        // 绝不能被当成"切了桌面"（否则每次全屏都会重写 Dock）。
        let provider = FakeProvider()
        provider.desktops = [space(1, id: 6), space(2, id: 7)]
        provider.activeID = 6
        let observer = SpaceObserver(provider: provider)

        var changes: [UInt64?] = []
        observer.onActiveSpaceChanged = { changes.append($0?.id64) }
        observer.refreshNow()
        XCTAssertEqual(changes, [6])

        // 进入全屏 App：活动空间 id 变成 4（全屏空间的 id64），不在用户桌面列表里。
        provider.activeID = 4
        observer.refreshNow()
        XCTAssertNil(observer.activeSpace, "全屏空间不应被认成用户桌面")
        XCTAssertEqual(changes.last!, nil as UInt64?)
    }

    func testDesktopListGenerationIncrementsOnlyOnListChange() {
        let provider = FakeProvider()
        provider.desktops = [space(1, id: 6), space(2, id: 7)]
        provider.activeID = 6
        let observer = makeObserver(provider)
        let generation = observer.desktopListGeneration

        observer.refreshNow()
        XCTAssertEqual(observer.desktopListGeneration, generation, "桌面列表没变就不该递增")

        // 模拟插上外接显示器，多了一个桌面。
        provider.desktops.append(space(3, id: 8))
        observer.refreshNow()
        XCTAssertGreaterThan(observer.desktopListGeneration, generation)
    }
}

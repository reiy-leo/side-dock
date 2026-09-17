import XCTest
@testable import MultiDock

/// toast 的调度行为。对应 `docs/PLAN.md` §3.10 的 toast 规格。
///
/// 全部用测试替身，不碰真实窗口 —— 窗口属性（跨空间、不抢焦点）只能实测，
/// 见 `scripts/check-toast-window.sh`。
@MainActor
final class ToastPresenterTests: XCTestCase {

    private final class FakeToast: ToastPresenting {
        private(set) var shown: [(text: String, displayUUID: String?)] = []
        private(set) var hideCount = 0

        func show(text: String, displayUUID: String?) {
            shown.append((text, displayUUID))
        }

        func hide() { hideCount += 1 }

        var texts: [String] { shown.map(\.text) }
    }

    private func space(_ ordinal: Int) -> DesktopSpace {
        DesktopSpace(
            displayUUID: "DISPLAY-A",
            spaceUUID: String(format: "UUID-%02d", ordinal),
            id64: UInt64(ordinal),
            type: 0,
            ordinal: ordinal
        )
    }

    /// 闭包里要读写的可变状态（开关、日志），用盒子装起来避免捕获局部变量。
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// 短 duration 让测试跑得快；断言都留了足够余量。
    private func makePresenter(
        _ fake: FakeToast,
        duration: Duration = .milliseconds(120),
        enabled: @escaping @MainActor () -> Bool = { true }
    ) -> ToastPresenter {
        ToastPresenter(
            presenter: fake,
            duration: duration,
            displayName: { "名字\($0.ordinal)" },
            isEnabled: enabled
        )
    }

    // MARK: - 什么时候弹

    func testNoToastOnFirstSample() {
        // 启动时观察器第一次采样就会回调一次；那不是"切换"，不该弹。
        let fake = FakeToast()
        let presenter = makePresenter(fake)

        presenter.handleActiveSpaceChanged(space(1))

        XCTAssertTrue(fake.shown.isEmpty, "启动首次采样不该弹 toast")
    }

    func testToastOnDesktopToDesktopSwitch() {
        let fake = FakeToast()
        let presenter = makePresenter(fake)

        presenter.handleActiveSpaceChanged(space(1))
        presenter.handleActiveSpaceChanged(space(2))

        XCTAssertEqual(fake.texts, ["名字2"])
        XCTAssertEqual(presenter.shownCount, 1)
        XCTAssertEqual(fake.shown.first?.displayUUID, "DISPLAY-A", "要带上 displayUUID，才能定位到正确的显示器")
    }

    func testNoToastWhenEnteringFullscreenSpace() {
        let fake = FakeToast()
        let presenter = makePresenter(fake)

        presenter.handleActiveSpaceChanged(space(1))
        presenter.handleActiveSpaceChanged(nil)   // 进全屏 App：活动空间不属于任何用户桌面

        XCTAssertTrue(fake.shown.isEmpty)
    }

    func testNoToastWhenReturningFromFullscreenSpace() {
        // 关键噪音源：从全屏退回桌面时 activeSpace 会先变 nil 再变回，
        // 若只看"新值非 nil"就会误弹。
        let fake = FakeToast()
        let presenter = makePresenter(fake)

        presenter.handleActiveSpaceChanged(space(1))
        presenter.handleActiveSpaceChanged(nil)
        presenter.handleActiveSpaceChanged(space(1))

        XCTAssertTrue(fake.shown.isEmpty, "从全屏退回桌面不该弹")
    }

    func testToastResumesAfterReturningFromFullscreenToADifferentDesktop() {
        // 全屏回来后落到的是**另一个**桌面：仍然不弹（上一次通知值是 nil）。
        // 这条是为了把规则钉死：判据是"上一次也是非 nil 桌面"，不是"是不是同一个桌面"。
        let fake = FakeToast()
        let presenter = makePresenter(fake)

        presenter.handleActiveSpaceChanged(space(1))
        presenter.handleActiveSpaceChanged(nil)
        presenter.handleActiveSpaceChanged(space(2))

        XCTAssertTrue(fake.shown.isEmpty)
    }

    func testToastAfterFullscreenRoundTripThenRealSwitch() {
        let fake = FakeToast()
        let presenter = makePresenter(fake)

        presenter.handleActiveSpaceChanged(space(1))
        presenter.handleActiveSpaceChanged(nil)
        presenter.handleActiveSpaceChanged(space(1))   // 回到桌面 1：不弹，但记账恢复
        presenter.handleActiveSpaceChanged(space(2))   // 真正的桌面→桌面

        XCTAssertEqual(fake.texts, ["名字2"])
    }

    // MARK: - 什么时候收

    func testToastHidesAfterDuration() async throws {
        let fake = FakeToast()
        let presenter = makePresenter(fake)

        presenter.handleActiveSpaceChanged(space(1))
        presenter.handleActiveSpaceChanged(space(2))
        XCTAssertEqual(fake.hideCount, 0, "刚弹出来不该已经收起")

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fake.hideCount, 1)
    }

    func testRapidSwitchKeepsOnlyLatestTextAndHidesOnce() async throws {
        let fake = FakeToast()
        let presenter = makePresenter(fake, duration: .milliseconds(150))

        presenter.handleActiveSpaceChanged(space(1))
        presenter.handleActiveSpaceChanged(space(2))
        presenter.handleActiveSpaceChanged(space(3))
        presenter.handleActiveSpaceChanged(space(4))

        XCTAssertEqual(fake.texts, ["名字2", "名字3", "名字4"], "连击时换文字，不排队弹多条")
        XCTAssertEqual(fake.hideCount, 0)

        // 第 2、3 次弹出的旧计时器必须被取消，否则它们会提前把第 4 条收走。
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fake.hideCount, 0, "旧计时器不该提前收起新提示")

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.hideCount, 1, "四次连击只收起一次")
    }

    func testManualShowWorksWithoutPreviousDesktop() {
        // 调试面板的「测试 toast」不受"上一个桌面"条件限制。
        let fake = FakeToast()
        let presenter = makePresenter(fake)

        presenter.show(text: "测试提示")

        XCTAssertEqual(fake.texts, ["测试提示"])
        XCTAssertEqual(presenter.shownCount, 1)
    }

    func testDismissNowHidesImmediately() {
        let fake = FakeToast()
        let presenter = makePresenter(fake)

        presenter.show(text: "A")
        presenter.dismissNow()

        XCTAssertEqual(fake.hideCount, 1)
    }

    // MARK: - 开关

    func testDisabledSkipsToast() {
        let fake = FakeToast()
        let presenter = makePresenter(fake, enabled: { false })

        presenter.handleActiveSpaceChanged(space(1))
        presenter.handleActiveSpaceChanged(space(2))

        XCTAssertTrue(fake.shown.isEmpty)
        XCTAssertEqual(presenter.shownCount, 0)
    }

    func testDisabledStillTracksLastDesktop() {
        // 关着开关时也要记账：否则用户打开开关的瞬间会被补弹一次。
        // 注意：真实情况下观察器会按桌面身份去重，同一个桌面不会连着回调两次，
        // 所以这里只发真实会发生的序列（桌面 1 → 桌面 2 → 桌面 3）。
        let fake = FakeToast()
        let enabled = Box(false)
        let presenter = makePresenter(fake, enabled: { enabled.value })

        presenter.handleActiveSpaceChanged(space(1))
        presenter.handleActiveSpaceChanged(space(2))
        XCTAssertTrue(fake.shown.isEmpty)

        enabled.value = true
        XCTAssertTrue(fake.shown.isEmpty, "打开开关不该为已经发生的切换补弹")

        presenter.handleActiveSpaceChanged(space(3))
        XCTAssertEqual(fake.texts, ["名字3"], "打开开关后的新切换照常弹")
    }

    func testManualShowRespectsDisabledFlag() {
        let fake = FakeToast()
        let presenter = makePresenter(fake, enabled: { false })

        presenter.show(text: "测试提示")

        XCTAssertTrue(fake.shown.isEmpty)
    }

    // MARK: - 日志

    func testLogsShowAndHide() async throws {
        let fake = FakeToast()
        let messages = Box<[String]>([])
        let presenter = ToastPresenter(
            presenter: fake,
            duration: .milliseconds(80),
            displayName: { "名字\($0.ordinal)" },
            log: { messages.value.append($0) }
        )

        presenter.handleActiveSpaceChanged(space(1))
        presenter.handleActiveSpaceChanged(space(2))
        XCTAssertEqual(messages.value, ["toast 显示「名字2」"])

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(messages.value, ["toast 显示「名字2」", "toast 隐藏"],
                       "显示与隐藏各记一行，便于核对 1 秒时长")
    }
}

import XCTest
@testable import MultiDock

/// Dock 拉不回来 / 桌面切换不可用时，**设置窗口的报警横幅**有没有内容。
///
/// 计划 §3.1 末段要求"降级时在 UI 明确报警，而不是静默失效"，§3.9 第 3 条要求
/// "Dock 3 秒未归位仍异常则提示从备份恢复"。这两条原先只进日志与调试面板 ——
/// 用户不看日志，等于没报警。本文件钉住"AppState 有没有把该报警的话接住"。
///
/// 视图本身（`WarningBanner`）不做快照测试：本机无屏幕录制权限，
/// 能验的是"状态对了没有"，渲染出来的横幅由 DebugPanelView 那一套客观信号兜。
@MainActor
final class DockFailureWarningTests: XCTestCase {

    // MARK: - 替身

    /// 可以「被弄死」也能「被拉回来」的 Dock。与 `DockPresenceMonitorTests.FlakyDock` 的差别是
    /// 这里的归位是**即时**的（拉一次就回来），用来测 AppState 那侧的接线。
    private final class RevivableDock: DockProcessControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t?
        private var nextPID: pid_t = 7000
        private var kickstarts = 0
        /// false = launchctl 拉不回来（模拟 launchd 彻底不管了）。
        private var recoversOnKickstart: Bool

        init(alive: Bool = true, recoversOnKickstart: Bool = false) {
            self.pid = alive ? 7000 : nil
            self.recoversOnKickstart = recoversOnKickstart
        }

        func vanish() { lock.withLock { pid = nil } }

        func setRecoversOnKickstart(_ value: Bool) { lock.withLock { recoversOnKickstart = value } }

        func dockPID() -> pid_t? { lock.withLock { pid } }

        @discardableResult
        func signal(_ pid: pid_t, _ sig: Int32) -> Bool { true }

        @discardableResult
        func kickstart() -> Bool {
            lock.withLock {
                kickstarts += 1
                guard recoversOnKickstart else { return true }
                nextPID += 1
                pid = nextPID
                return true
            }
        }

        var kickstartCount: Int { lock.withLock { kickstarts } }
    }

    private struct Fixture {
        let state: AppState
        let monitor: DockPresenceMonitor
        let dock: RevivableDock
    }

    /// 一条**不碰真实 Dock、不碰真实配置文件**的 AppState。
    ///
    /// `DockController` 必须注入替身偏好域：`AppState.start()` 会调 `adoptLiveDockAsApplied()`，
    /// 用默认控制器就会读到（并影响）用户真实的 `com.apple.dock`。
    private func makeFixture(
        name: String,
        providerAvailable: Bool = true,
        providerReason: String? = nil,
        alive: Bool = true,
        recoversOnKickstart: Bool = false,
        persistentFailureThreshold: Int = 4
    ) throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-warn-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let dock = RevivableDock(alive: alive, recoversOnKickstart: recoversOnKickstart)
        // pollInterval 设大：测试手动 tick()，不让后台循环插进来搅局。
        let monitor = DockPresenceMonitor(
            process: dock,
            pollInterval: .seconds(60),
            missThreshold: 2,
            kickstartEvery: 4,
            persistentFailureThreshold: persistentFailureThreshold
        )

        let state = AppState(
            dockController: DockController(
                preferences: FakePreferences(domain: [
                    "orientation": .string("bottom"),
                    "tilesize": .double(36),
                    "magnification": .bool(false),
                    "persistent-apps": .array([]),
                    "persistent-others": .array([]),
                    "mru-spaces": .bool(true),
                ]),
                reloader: DockReloader(
                    process: FakeDockProcess(),
                    timeout: .milliseconds(200),
                    pollInterval: .milliseconds(2),
                    fallbackGrace: .milliseconds(20),
                    minimumSpacing: .zero
                ),
                backup: {}
            ),
            configStore: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            baselineStore: BaselineStore(
                baselineURL: directory.appendingPathComponent("baseline.plist"),
                markerURL: directory.appendingPathComponent("session.state"),
                backupsURL: directory.appendingPathComponent("backups", isDirectory: true)
            ),
            provider: FakeSpaceProvider(
                isAvailable: providerAvailable,
                reason: providerReason
            ),
            presenceMonitor: monitor,
            fileLog: makeTestFileLog()
        )
        return Fixture(state: state, monitor: monitor, dock: dock)
    }

    // MARK: - Dock 拉不回来

    func testBannerAppearsOnlyAfterPersistentFailure() throws {
        let fixture = try makeFixture(name: "appear", alive: false)
        fixture.state.start()
        XCTAssertNil(fixture.state.dockFailureWarning, "启动瞬间不该就有报警")

        for _ in 0..<3 { fixture.monitor.tick() }
        XCTAssertNil(fixture.state.dockFailureWarning, "还没到阈值，别吓人")

        fixture.monitor.tick()
        let warning = try XCTUnwrap(fixture.state.dockFailureWarning, "跨过阈值必须报警")
        XCTAssertTrue(warning.contains("Dock"), "文案要指名道姓：\(warning)")
        XCTAssertTrue(fixture.monitor.isPersistentlyDown)
        XCTAssertTrue(
            fixture.state.log.contains { $0.level == .error && $0.message.contains("备份") },
            "日志里要指路（备份与还原）：\(fixture.state.log.map(\.message))"
        )
    }

    func testBannerClearsWhenDockComesBack() throws {
        let fixture = try makeFixture(name: "clear", alive: false)
        fixture.state.start()

        for _ in 0..<4 { fixture.monitor.tick() }
        XCTAssertNotNil(fixture.state.dockFailureWarning)

        // launchd 后来又能拉回来了。拉回有节奏（每 `kickstartEvery` 轮才打一次 launchctl），
        // 所以要 tick 够几轮：到节奏那轮打 launchctl，下一轮才看得到新 PID。
        fixture.dock.setRecoversOnKickstart(true)
        for _ in 0..<5 { fixture.monitor.tick() }
        XCTAssertEqual(fixture.monitor.recoveryCount, 1, "Dock 应该已经归位了")

        XCTAssertNil(fixture.state.dockFailureWarning, "回来了必须撤报警")
        XCTAssertFalse(fixture.monitor.isPersistentlyDown)
        XCTAssertTrue(
            fixture.state.log.contains { $0.message.contains("警告解除") },
            "日志要留痕：\(fixture.state.log.map(\.message))"
        )
    }

    func testHealthyDockNeverRaisesTheBanner() throws {
        let fixture = try makeFixture(name: "healthy")
        fixture.state.start()

        for _ in 0..<20 { fixture.monitor.tick() }

        XCTAssertNil(fixture.state.dockFailureWarning)
        XCTAssertEqual(fixture.dock.kickstartCount, 0, "Dock 好好的，一次都不该拉")
    }

    func testRetryRevivalGoesThroughTheMonitor() throws {
        let fixture = try makeFixture(name: "retry", alive: false)
        fixture.state.start()
        for _ in 0..<4 { fixture.monitor.tick() }
        XCTAssertNotNil(fixture.state.dockFailureWarning)

        let before = fixture.dock.kickstartCount
        XCTAssertTrue(fixture.state.retryDockRevival(), "launchctl 跑起来了就该返回 true")
        XCTAssertEqual(fixture.dock.kickstartCount, before + 1, "按钮必须真的再拉一次")
        XCTAssertNotNil(fixture.state.dockFailureWarning, "重试不代表已经回来，报警不能提前撤")
    }

    func testRetryRevivalBeforeStartIsReported() throws {
        // `start()` 没跑过 → 监视器还没建，按钮不能假装成功。
        let fixture = try makeFixture(name: "nostart", alive: false)

        XCTAssertFalse(fixture.state.retryDockRevival())
        XCTAssertTrue(
            fixture.state.log.contains { $0.message.contains("未启动") },
            "要如实说「监视未启动」：\(fixture.state.log.map(\.message))"
        )
    }

    // MARK: - 桌面切换不可用

    func testSpaceProviderWarningIsExposedForTheBanner() throws {
        let fixture = try makeFixture(
            name: "provider",
            providerAvailable: false,
            providerReason: "SkyLight 符号缺失"
        )
        fixture.state.start()

        XCTAssertFalse(fixture.state.spaceProviderAvailable)
        XCTAssertEqual(fixture.state.spaceProviderWarning, "SkyLight 符号缺失",
                       "横幅读的就是这个字段，不能只往日志里写")
    }

    func testAvailableProviderHasNoWarning() throws {
        let fixture = try makeFixture(name: "provider-ok", providerAvailable: true)
        fixture.state.start()

        XCTAssertTrue(fixture.state.spaceProviderAvailable)
        XCTAssertNil(fixture.state.spaceProviderWarning, "正常时不该有横幅")
    }
}

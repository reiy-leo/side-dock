import XCTest
@testable import MultiDock

/// `DockWatcher` —— 识别用户在真实 Dock 上的手动改动。
///
/// 全部走注入的闭包，不读真实偏好域、不碰真实 Dock。
/// 被测的核心是**判据**：什么样的指纹变化算"用户改的"，什么算"我们自己写的"。
@MainActor
final class DockWatcherTests: XCTestCase {

    private func makeConfig(apps: [String] = ["Safari"]) -> DockConfig {
        DockConfig(pinnedApps: DockStripRules.normalizedApps(
            apps.map {
                DockTile.makeFileTile(
                    url: URL(fileURLWithPath: "/Applications/\($0).app", isDirectory: true),
                    label: $0,
                    bundleIdentifier: "com.example.\($0)"
                )
            }
        ))
    }

    /// 一个可编程的假环境：当前指纹与"我们写下去的那份"都能随时改。
    ///
    /// 必须标 `@MainActor`：嵌套类型不继承外层测试类的 actor 隔离，
    /// 而 `DockWatcher` 的闭包都是 `@MainActor` 的。
    @MainActor
    private final class Harness {
        var current: String?
        var applied: String?
        var live: DockConfig?
        var detected: [DockConfig] = []
        var logs: [String] = []
        /// Dock 进程在不在。默认在 —— 只有专门测"缺失期间不采样"的用例才改成 false。
        var dockAlive = true

        func makeWatcher(pollInterval: Duration = .seconds(60)) -> DockWatcher {
            DockWatcher(
                pollInterval: pollInterval,
                currentFingerprint: { [self] in current },
                appliedFingerprint: { [self] in applied },
                readLiveConfig: { [self] in live },
                isDockPresent: { [self] in dockAlive },
                onUserEdit: { [self] config in detected.append(config) },
                log: { [self] message in logs.append(message) }
            )
        }
    }

    // MARK: - 不误判

    func testTickWithoutChangeDoesNothing() {
        let harness = Harness()
        let config = makeConfig()
        harness.current = "fp-a"
        harness.applied = "fp-a"
        harness.live = config
        let watcher = harness.makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        watcher.tick()

        XCTAssertTrue(harness.detected.isEmpty)
        XCTAssertEqual(watcher.detectedCount, 0)
        XCTAssertFalse(watcher.isDiverged)
    }

    func testOurOwnWriteIsNotTreatedAsUserEdit() {
        // Dock 重启后会规范化我们写下去的内容（补 GUID 等），指纹会变。
        // 只要变完等于"我们写下去的那份"，就必须当成自己的写入。
        let harness = Harness()
        harness.current = "before"
        harness.applied = "before"
        harness.live = makeConfig()
        let watcher = harness.makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        harness.current = "after-normalization"
        harness.applied = "after-normalization"
        watcher.tick()

        XCTAssertTrue(harness.detected.isEmpty, "自己写下去的内容不能被当成用户改动")
        XCTAssertFalse(watcher.isDiverged)
    }

    func testNothingAppliedThisRunMeansNoCapture() {
        // 本次运行还没写过任何东西 → 没有"我们的版本"可比，
        // 此时真实 Dock 变了也只是用户自己的事，不该回存进配置。
        let harness = Harness()
        harness.current = "whatever"
        harness.applied = nil
        harness.live = makeConfig()
        let watcher = harness.makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        harness.current = "changed"
        watcher.tick()

        XCTAssertTrue(harness.detected.isEmpty)
        XCTAssertEqual(watcher.detectedCount, 0)
    }

    func testUnreadableDomainIsIgnored() {
        let harness = Harness()
        harness.current = nil
        harness.applied = "fp-a"
        let watcher = harness.makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        watcher.tick()

        XCTAssertTrue(harness.detected.isEmpty)
    }

    func testMissingLiveConfigDoesNotCrashOrReport() {
        // 指纹变了但读不出配置（例如 Dock 正在重启）→ 只能放弃这一轮，不能崩。
        let harness = Harness()
        harness.current = "fp-a"
        harness.applied = "fp-a"
        harness.live = nil
        let watcher = harness.makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        harness.current = "fp-b"
        watcher.tick()

        XCTAssertTrue(harness.detected.isEmpty)
        XCTAssertEqual(watcher.detectedCount, 0)
    }

    // MARK: - 该判的时候要判出来

    func testDetectsUserEdit() {
        let harness = Harness()
        harness.current = "fp-a"
        harness.applied = "fp-a"
        let edited = makeConfig(apps: ["Safari", "Notes"])
        harness.live = edited
        let watcher = harness.makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        harness.current = "fp-user-edit"
        watcher.tick()

        XCTAssertEqual(harness.detected.count, 1)
        XCTAssertEqual(harness.detected.first?.pinnedApps.count, edited.pinnedApps.count)
        XCTAssertEqual(watcher.detectedCount, 1)
        XCTAssertTrue(watcher.isDiverged)
        XCTAssertTrue(harness.logs.contains { $0.contains("检测到真实 Dock 上的手动改动") })
    }

    func testSameFingerprintOnlyReportedOnce() {
        let harness = Harness()
        harness.current = "fp-a"
        harness.applied = "fp-a"
        harness.live = makeConfig()
        let watcher = harness.makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        harness.current = "fp-b"
        watcher.tick()
        watcher.tick()
        watcher.tick()

        XCTAssertEqual(watcher.detectedCount, 1, "指纹没再变就不该重复回存")
    }

    func testReturningToAppliedContentIsNotAnEdit() {
        // 用户改回原样：不是"新的用户改动"，因为内容已经等于我们写下去的那份。
        let harness = Harness()
        harness.current = "fp-a"
        harness.applied = "fp-a"
        harness.live = makeConfig()
        let watcher = harness.makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        harness.current = "fp-b"
        watcher.tick()
        XCTAssertEqual(watcher.detectedCount, 1)

        harness.current = "fp-a"
        watcher.tick()
        XCTAssertEqual(watcher.detectedCount, 1, "内容等于已应用的那份，不算新改动")
        XCTAssertFalse(watcher.isDiverged)

        harness.current = "fp-c"
        watcher.tick()
        XCTAssertEqual(watcher.detectedCount, 2, "再改一次要能重新识别")
    }

    // MARK: - acknowledge

    func testAcknowledgeSuppressesTheNextTick() {
        // 回存流程：我们先写下去 → 立刻 acknowledge，避免把这次写入当成新的用户改动。
        let harness = Harness()
        harness.current = "fp-a"
        harness.applied = "fp-a"
        harness.live = makeConfig()
        let watcher = harness.makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        harness.applied = "fp-restored"
        watcher.acknowledge("fp-restored")
        harness.current = "fp-restored"
        watcher.tick()

        XCTAssertEqual(watcher.detectedCount, 0)
        XCTAssertFalse(watcher.isDiverged)
    }

    func testAcknowledgeNilIsIgnored() {
        let harness = Harness()
        harness.current = "fp-a"
        harness.applied = "fp-a"
        harness.live = makeConfig()
        let watcher = harness.makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        watcher.acknowledge(nil)

        harness.current = "fp-b"
        watcher.tick()
        XCTAssertEqual(watcher.detectedCount, 1, "acknowledge(nil) 不该把指纹清掉")
    }

    // MARK: - 轮询开关

    func testNeverSamplesWhileDockProcessIsMissing() {
        // 真机踩过（2026-09-19）：Dock 死掉的窗口里偏好域读回来是残缺的
        // （「3 个图标、0 个其他项」，真实 Dock 是 15 + 1），被当成用户改动回存，写坏了那个桌面的 override。
        let harness = Harness()
        harness.current = "fp-a"
        harness.applied = "fp-a"
        harness.live = makeConfig(apps: ["Notes"])
        let watcher = harness.makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        harness.dockAlive = false
        harness.current = "fp-partial-garbage"
        watcher.tick()

        XCTAssertTrue(harness.detected.isEmpty, "Dock 不在时一次都不该采样")
        XCTAssertEqual(watcher.detectedCount, 0)
        XCTAssertFalse(watcher.isDiverged)
    }

    func testDockReturnRebaselinesBeforeCapturingAnything() {
        // Dock 回来之后的第一次读只用来对齐基线；紧接着的真实改动仍然要抓到。
        let harness = Harness()
        harness.current = "fp-a"
        harness.applied = "fp-a"
        harness.live = makeConfig(apps: ["Notes"])
        let watcher = harness.makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        harness.dockAlive = false
        harness.current = "fp-partial-garbage"
        watcher.tick()

        harness.dockAlive = true
        harness.current = "fp-back"
        watcher.tick()
        XCTAssertTrue(harness.detected.isEmpty, "中间态分不清是不是用户改的，一律先认成新基线")

        harness.current = "fp-user-edit"
        watcher.tick()
        XCTAssertEqual(harness.detected.count, 1, "对齐之后的真实改动照常回存")
        XCTAssertEqual(watcher.detectedCount, 1)
    }

    func testStartAndStopToggleRunningFlag() {
        let harness = Harness()
        harness.current = "fp-a"
        harness.applied = "fp-a"
        let watcher = harness.makeWatcher()

        XCTAssertFalse(watcher.isRunning)
        watcher.start()
        XCTAssertTrue(watcher.isRunning)
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
    }

    func testRepeatedStartIsIdempotent() {
        let harness = Harness()
        harness.current = "fp-a"
        harness.applied = "fp-a"
        let watcher = harness.makeWatcher()
        watcher.start()
        watcher.start()
        XCTAssertTrue(watcher.isRunning)
        watcher.stop()
    }
}

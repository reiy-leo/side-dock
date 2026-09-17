import XCTest
@testable import MultiDock

/// Dock 重载策略。对应 `docs/PLAN.md` §3.5 与 `docs/spikes.md` 的 P0 结论。
///
/// 这里钉死的是**顺序**：SIGHUP 优先 → 失败才 SIGTERM → 再失败才 `launchctl kickstart`。
/// 真正"这台上多久恢复"只能实测（P0 已测得 101 ms / 395 ms）。
@MainActor
final class DockReloaderTests: XCTestCase {

    private func makeReloader(_ process: FakeDockProcess) -> DockReloader {
        DockReloader(
            process: process,
            timeout: .milliseconds(200),
            pollInterval: .milliseconds(2),
            fallbackGrace: .milliseconds(20)
        )
    }

    func testAutoStrategyUsesSighupFirst() async {
        let process = FakeDockProcess(pid: 100, restartsOn: [SIGHUP])
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .sighup)
        XCTAssertEqual(process.signals, [SIGHUP], "主路径必须是 SIGHUP，且只发一次")
        XCTAssertEqual(process.kickstartCount, 0)
        XCTAssertEqual(outcome.oldPID, 100)
        XCTAssertNotNil(outcome.newPID)
        XCTAssertTrue(outcome.succeeded)
    }

    func testNeverUsesSigtermWhenSighupWorks() async {
        // 回归护栏：SIGTERM 会让 Dock 做约 255 ms 清理（总不可用约 395 ms），
        // 比 SIGHUP 慢 4 倍。SIGHUP 有效时绝不能发 SIGTERM。
        let process = FakeDockProcess(restartsOn: [SIGHUP, SIGTERM])
        _ = await makeReloader(process).reload(strategy: .auto)

        XCTAssertFalse(process.signals.contains(SIGTERM))
    }

    func testFallsBackToSigtermThenKickstart() async {
        // SIGHUP 不生效（模拟 Dock 卡住），SIGTERM 也不生效，最后靠 launchd 拉回。
        let process = FakeDockProcess(restartsOn: [], kickstartRestarts: true)
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertEqual(process.signals.first, SIGHUP, "先试主路径")
        XCTAssertTrue(process.signals.contains(SIGTERM), "主路径失败要补 SIGTERM")
        XCTAssertEqual(process.kickstartCount, 1, "最后才动 launchctl")
        XCTAssertEqual(outcome.method, .kickstart)
        XCTAssertTrue(outcome.succeeded)
    }

    func testStopsAtSigtermWhenItWorks() async {
        // SIGHUP 无效、SIGTERM 有效 → 不该再多此一举 kickstart。
        let process = FakeDockProcess(restartsOn: [SIGTERM])
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .sigterm)
        XCTAssertEqual(process.kickstartCount, 0)
    }

    func testSigtermStrategySkipsSighupEntirely() async {
        let process = FakeDockProcess(restartsOn: [SIGHUP, SIGTERM])
        let outcome = await makeReloader(process).reload(strategy: .sigterm)

        XCTAssertEqual(outcome.method, .sigterm)
        XCTAssertEqual(process.signals, [SIGTERM], "用户选了 SIGTERM 就别再试 SIGHUP")
    }

    func testFailsWhenDockIsNotRunning() async {
        let process = FakeDockProcess(pid: nil)
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .failed)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(process.signals.isEmpty, "没有 Dock 进程就没得发信号")
        XCTAssertEqual(process.kickstartCount, 0)
    }

    func testReportsFailureWhenDockNeverComesBack() async {
        let process = FakeDockProcess(restartsOn: [], kickstartRestarts: false)
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .failed)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertNil(outcome.newPID)
        XCTAssertTrue(outcome.description.contains("失败"))
        XCTAssertGreaterThan(outcome.elapsed, 0)
    }

    func testWaitsForANewPIDNotJustAPID() async {
        // 关键：判据是"PID 变了"，不是"Dock 还在"。只看存在性会把还没重启完的旧进程
        // 当成重启成功，于是新配置根本没被读进去。
        let process = FakeDockProcess(pid: 100, restartsOn: [SIGHUP], restartDelayPolls: 5)
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertEqual(outcome.method, .sighup)
        XCTAssertEqual(outcome.oldPID, 100)
        XCTAssertNotEqual(outcome.newPID, 100, "拿到的必须是新 PID")
    }

    func testOutcomeDescriptionIncludesPIDAndDuration() async {
        let process = FakeDockProcess(pid: 4242, restartsOn: [SIGHUP])
        let outcome = await makeReloader(process).reload(strategy: .auto)

        XCTAssertTrue(outcome.description.contains("4242"))
        XCTAssertTrue(outcome.description.contains("ms"), "日志里要有耗时，P2 验收靠它")
    }

    func testReloadIsIdempotentAcrossRepeatedCalls() async {
        let process = FakeDockProcess(restartsOn: [SIGHUP])
        let reloader = makeReloader(process)

        let first = await reloader.reload(strategy: .auto)
        let second = await reloader.reload(strategy: .auto)

        XCTAssertEqual(first.method, .sighup)
        XCTAssertEqual(second.method, .sighup)
        XCTAssertNotEqual(first.newPID, second.newPID, "每次都要真的换一个进程")
    }
}

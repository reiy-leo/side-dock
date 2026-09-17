import XCTest
@testable import MultiDock

/// `RealDockProcessControl` 的**安全闸门**。
///
/// 这组测试守的是一条能毁掉用户整个图形会话的不变量：
/// `kill(-1, sig)` 的语义是"发给当前用户的**全部**进程"，`kill(0, sig)` 是"发给整个进程组"。
/// 而 `NSRunningApplication` 在 Dock 重启窗口里**真的会**返回 `processIdentifier == -1`（实测复现），
/// 所以"PID 会不会是 -1"不是理论问题。
///
/// 所有断言都用**信号 0**（空信号，只做权限/存在性检查，不投递任何东西）。
/// 这样万一闸门被改坏了，测试是**失败**而不是把测试进程自己打死。
@MainActor
final class DockProcessSafetyTests: XCTestCase {

    private let control = RealDockProcessControl()

    func testSignalRefusesNegativeOne() {
        // 这是最危险的那个值：`kill(-1, SIGTERM)` 会杀掉当前用户的所有进程。
        XCTAssertFalse(control.signal(-1, 0), "绝不能把信号发给 -1（当前用户的全部进程）")
        XCTAssertFalse(control.signal(-1, SIGTERM), "即使是 SIGTERM 也必须拒绝")
    }

    func testSignalRefusesZero() {
        // `kill(0, sig)` 发给整个进程组。
        XCTAssertFalse(control.signal(0, 0), "绝不能把信号发给 0（整个进程组）")
    }

    func testSignalRefusesAnyNonPositivePID() {
        for pid: pid_t in [-999, -2, -1, 0] {
            XCTAssertFalse(control.signal(pid, 0), "非正数 PID \(pid) 必须被拒绝")
        }
    }

    func testSignalRefusesPIDsThatAreNotTheDock() {
        // 用信号 0 探自己：闸门若只挡了非正数而漏了身份确认，这里会返回 true 而**不会**打死我们。
        XCTAssertFalse(control.signal(getpid(), 0),
                       "我们自己的进程名不是 Dock，不该被当成 Dock 发信号")
        // launchd 也不是 Dock。同样用信号 0，不会真的动它。
        XCTAssertFalse(control.signal(1, 0), "launchd 不是 Dock")
    }

    func testDockPIDIsAPositiveRealProcess() throws {
        // 真实系统读取（只读进程表，不改任何东西）。Dock 不在就跳过。
        let pid = try XCTUnwrap(control.dockPID(), "Dock 不在运行，跳过")
        XCTAssertGreaterThan(pid, 0, "dockPID() 绝不能返回非正数")
        // 与 LaunchServices 的答案对得上（说明走的不是野路子）。
        let fromLaunchServices = NSRunningApplication
            .runningApplications(withBundleIdentifier: RealDockProcessControl.dockBundleIdentifier)
            .first { !$0.isTerminated && $0.processIdentifier > 0 }?
            .processIdentifier
        if let fromLaunchServices {
            XCTAssertEqual(pid, fromLaunchServices)
        }
    }

    func testDockPIDIsCheapEnoughForPolling() throws {
        // 重启判定是 15 ms 一轮的轮询。实测 `/usr/bin/pgrep` 单次约 110 ms，
        // 会把"等 Dock 回来"从 0.1 秒拖到 1 秒以上；`proc_listpids` 只要 0.02 ms。
        // 这条测试守的就是"别再把子进程塞回热路径"。
        _ = try XCTUnwrap(control.dockPID())
        let started = Date()
        for _ in 0..<50 { _ = control.dockPID() }
        let average = Date().timeIntervalSince(started) / 50
        XCTAssertLessThan(average, 0.02,
                          "dockPID() 平均 \(Int(average * 1000)) ms，太慢会拖慢每一次重启判定")
    }

    func testDockProcessNameMatchesTheGuardConstant() throws {
        // 身份确认依赖进程名恰好是 "Dock"。若系统改了名字，闸门会静默失效（永远返回 false），
        // 表现为"Dock 重启失败"而不是"杀错进程"—— 但也要能被发现。
        let pid = try XCTUnwrap(control.dockPID())
        XCTAssertTrue(control.signal(pid, 0), "身份确认应当认出真正的 Dock")
    }

    func testRealDockStartTimeIsReadable() throws {
        // `DockReloader` 靠进程年龄推算 launchd 的节流窗口（`proc_pidinfo(PROC_PIDTBSDINFO)`）。
        // 读不出来会退回内存记忆 —— 那条路在"别人刚重启过 Dock"时是错的，
        // 所以这里守住"在真实系统上读得到"。
        let pid = try XCTUnwrap(control.dockPID())
        let startedAt = try XCTUnwrap(control.startTime(of: pid), "读不到 Dock 启动时刻")
        let age = Date().timeIntervalSince1970 - startedAt

        XCTAssertGreaterThan(age, 0, "启动时刻不该在未来")
        XCTAssertLessThan(age, 60 * 60 * 24 * 30, "启动时刻看起来不对：\(startedAt)")
    }

    func testStartTimeRefusesNonPositivePID() {
        // 与信号闸门同理：别拿 -1 去问 libproc。
        XCTAssertNil(control.startTime(of: 0))
        XCTAssertNil(control.startTime(of: -1))
    }
}

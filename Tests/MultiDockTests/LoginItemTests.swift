import XCTest
@testable import MultiDock

/// 登录启动。
///
/// **不测 `SMAppService` 本身** —— 那是系统的东西，在 `swift test` 里根本没有 bundle 可用，
/// 测它只会得到"不可用"这一个结论。真正值得守的是：
/// 1. 不可用时**明确报错**而不是假装成功（否则用户开了开关、下次开机什么都没发生）；
/// 2. LaunchAgent 退回方案的 plist 内容正确 —— 真去写用户的 `~/Library/LaunchAgents`
///    是测试不该干的事，所以把它抽成纯函数来断言。
final class LoginItemTests: XCTestCase {

    func testAgentPlistIsARunAtLoadItem() {
        let plist = LoginItem.agentPlist(executablePath: "/Applications/MultiDock.app")

        XCTAssertEqual(plist["Label"], .string(LoginItem.agentLabel))
        XCTAssertEqual(plist["RunAtLoad"], .bool(true))
        XCTAssertEqual(plist["ProgramArguments"], .array([.string("/Applications/MultiDock.app")]))
    }

    func testAgentPlistHasNoKeepAlive() {
        // 这是登录启动项，不是守护进程：App 被用户退出后不该被 launchd 反复拉起。
        let plist = LoginItem.agentPlist(executablePath: "/Applications/MultiDock.app")
        XCTAssertNil(plist["KeepAlive"], "设了 KeepAlive 会让退出 App 变成一件不可能的事")
    }

    func testAgentLabelIsStable() {
        // 改这个字符串会让已经装好的 LaunchAgent 变成孤儿（旧文件还在、我们却找不到它）。
        XCTAssertEqual(LoginItem.agentLabel, "local.multidock.loginitem")
        XCTAssertTrue(LoginItem.agentPlistURL.path.hasSuffix("Library/LaunchAgents/local.multidock.loginitem.plist"),
                      "实际路径：\(LoginItem.agentPlistURL.path)")
    }

    func testUnavailableOutsideAnAppBundle() {
        // `swift test` 的 runner 不是 .app，所以这里必须报告不可用。
        XCTAssertFalse(LoginItem.isRunningFromBundle)
        XCTAssertFalse(LoginItem.isAvailable)
        XCTAssertFalse(LoginItem.isEnabled)
    }

    func testEnableThrowsWhenUnavailable() {
        XCTAssertThrowsError(try LoginItem.enable()) { error in
            XCTAssertEqual(error as? LoginItemError, .notInAppBundle)
        }
    }

    func testStatusDescriptionExplainsWhyUnavailable() {
        XCTAssertTrue(LoginItem.statusDescription().contains("不可用"),
                      "实际：\(LoginItem.statusDescription())")
    }
}

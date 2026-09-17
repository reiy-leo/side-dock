import XCTest
@testable import MultiDock

/// P2 验收：**真的**改写 `com.apple.dock`、**真的**重启 Dock，然后还原。
///
/// 因为会动用户真实的 Dock，默认**跳过**；显式开启才跑：
/// ```
/// MULTIDOCK_DOCK_ACCEPTANCE=1 swift test --filter DockAcceptanceTests
/// ```
///
/// 验收标准（`docs/PLAN.md` §4 的 P2 行）：
/// 1. 写完之后，与操作前的全量域 diff，**除白名单键外无任何差异**；
/// 2. 新写进去的 tile 被 Dock **补上 `GUID`** —— 这是"Dock 真的读进去了"的客观判据（P0 实测）；
/// 3. 还原后**逐键等于**操作前的全量域。
///
/// 无论成败都会把操作前的全量域写回去，不会留下被改坏的 Dock。
///
/// ⚠️ **跑的时候别手动改 Dock**（拖图标、改大小、启动/退出 App 都可能让 Dock 回写偏好）。
/// 实测踩过：有一次测试窗口内 Dock 被外部改动，`persistent-others` 从 4 项变 1 项，
/// 于是"还原后仍有差异"报了假失败。差异里只有 `mod-count` / `recent-apps` 才算正常。
@MainActor
final class DockAcceptanceTests: XCTestCase {

    private static let enableFlag = "MULTIDOCK_DOCK_ACCEPTANCE"
    private static let dumpDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
    private static let calculatorPath = "/System/Applications/Calculator.app"

    func testApplyThenRestoreLeavesDockUntouched() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.enableFlag] == "1",
            "会真的重启 Dock；设 \(Self.enableFlag)=1 才跑"
        )

        let before = DockPreferences.readDomain()
        XCTAssertFalse(before.isEmpty, "读不到 com.apple.dock，验收无意义")
        try Self.dump(before, named: "before")

        // 断言失败不会抛错，所以正常路径一路跑到底；只有 XCTUnwrap 之类的 throw 会跳出。
        // 两条路都必须还原。
        do {
            try await runApplyPhase(before: before)
        } catch {
            await Self.writeBack(before, label: "异常还原")
            throw error
        }

        let restored = await Self.writeBack(before, label: "验收结束还原")
        try Self.dump(restored, named: "after-restore")

        let stillDifferent = Self.differences(between: before, and: restored)
        // Dock 自己会改的键：重启一次 `mod-count` 就 +1，`recent-apps` 是它自己的记账。
        // 这些不在白名单里、我们从不写，所以差异里出现它们是正常的。
        let illegal = stillDifferent.subtracting(DockPreferences.whitelistedKeys)
            .subtracting(Self.dockSelfMutatingKeys)
        XCTAssertTrue(illegal.isEmpty, "还原后白名单外的键仍有差异：\(illegal.sorted())")
        XCTAssertEqual(Set(before.keys), Set(restored.keys), "键集合必须完全一致")
        print("""
        [验收] 还原后仍有差异的键：\(stillDifferent.sorted())（只允许是 Dock 自己的计数器）
        [验收] 图标顺序 after-restore：\(Self.labels(of: restored))
        [验收] 还原后白名单键逐键一致，键集合一致（\(restored.count) 个键）
        """)
    }

    /// Dock 自己会改、我们从不写的键。重启 Dock 就会动。
    private static let dockSelfMutatingKeys: Set<String> = ["mod-count", "recent-apps", "trash-full"]

    /// 写入 + 校验 + 差异核对。
    private func runApplyPhase(before: [String: PlistValue]) async throws {
        // ---- 1. 构造一套与现状不同的配置 ----
        var config = DockConfig.read(from: before)
        let originalTilesize = config.appearance.tilesize
        config.appearance.tilesize = originalTilesize == 52 ? 44 : 52
        config.appearance.magnification.toggle()

        // 加一个**全新的、不带 GUID** 的条目：只有它被 Dock 补上 GUID，才能证明写入被吃下。
        let probe = try XCTUnwrap(
            DockStripRules.tile(forAppAt: Self.calculatorPath),
            "找不到 \(Self.calculatorPath)"
        )
        config.pinnedApps = DockStripRules.normalizedApps(config.pinnedApps + [probe])
        XCTAssertEqual(config.pinnedApps.count, DockConfig.read(from: before).pinnedApps.count + 1)

        let controller = DockController(backup: {})   // 验收不写 App 的备份目录
        let outcome = await controller.apply(config, reason: "P2 验收", strategy: .auto)

        // ---- 2. 应用结果 ----
        XCTAssertEqual(outcome.result, .applied, "应用失败：\(outcome.summary)")
        XCTAssertEqual(outcome.verifyAttempts, 1, "不该需要重试")
        XCTAssertEqual(outcome.reload?.method, .sighup, "主路径必须是 SIGHUP")
        // 本机缺失的外观键只有 show-process-indicators。autohide-delay / autohide-time-modifier
        // 因为域里没有、读回来是 nil，压根不会进 domainEntries，所以不算"被跳过"。
        XCTAssertEqual(outcome.skippedKeys, ["show-process-indicators"],
                       "本机缺失的外观键，实际：\(outcome.skippedKeys)")
        print("[验收] 应用：\(outcome.summary)")

        // ---- 3. 差异只允许出现在白名单键上 ----
        let after = DockPreferences.readDomain()
        try Self.dump(after, named: "after-apply")

        let changed = Self.differences(between: before, and: after)
        let illegal = changed.subtracting(DockPreferences.whitelistedKeys)
        XCTAssertTrue(illegal.isEmpty, "白名单外的键被改动了：\(illegal.sorted())")
        XCTAssertTrue(changed.contains("tilesize"), "白名单键该改的必须真的改了")
        XCTAssertTrue(changed.contains("persistent-apps"))
        print("""
        [验收] 变化的键：\(changed.sorted())
        [验收] 图标顺序 before    ：\(Self.labels(of: before))
        [验收] 图标顺序 after-apply：\(Self.labels(of: after))
        """)

        // ---- 4. Dock 真的读进去了吗：新 tile 必须被补上 GUID ----
        // Dock 的回写是异步的，P0 是"重启后去看"；这里轮询等它落盘。
        let guid = await Self.waitForDockToBackfillGUID(of: probe, timeout: .seconds(8))
        XCTAssertNotNil(guid, "Dock 没给条目补 GUID → 说明它根本没读这份写入（P0 判据）")
        XCTAssertEqual(DockPreferences.readDomain()["tilesize"]?.doubleValue, config.appearance.tilesize)
        print("[验收] Dock 已为写入的条目补上 GUID：\(guid?.fingerprintToken ?? "?")")
    }

    /// 域里所有 `persistent-apps` + `persistent-others` 条目的标签，按顺序。
    /// 用来把"顺序/成员变了"和"值变了"分开看 —— 用 `diff` 比对长数组会因为行错位产生假差异。
    private static func labels(of domain: [String: PlistValue]) -> [String] {
        let config = DockConfig.read(from: domain)
        return (config.pinnedApps + config.otherItems).map { $0.label }
    }

    /// 轮询等 Dock 把 `persistent-apps` 规范化回写（补 `GUID`）。
    ///
    /// P0 观测到的是"重启后就有了"，但没测具体延迟。Dock 回写是异步的，
    /// 所以这里必须等，不能读完立刻断言 —— 否则会误判成"写入没生效"。
    private static func waitForDockToBackfillGUID(
        of probe: DockTile,
        timeout: Duration
    ) async -> PlistValue? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let live = DockConfig.read(from: DockPreferences.readDomain()).pinnedApps
            if let tile = live.first(where: { $0.normalizedKey == probe.normalizedKey }),
               let guid = tile.raw["GUID"] {
                return guid
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// 两个全量域的差异键集合。
    private static func differences(
        between lhs: [String: PlistValue],
        and rhs: [String: PlistValue]
    ) -> Set<String> {
        Set(lhs.keys).union(rhs.keys).filter { lhs[$0] != rhs[$0] }
    }

    /// 把一份全量域里的白名单键写回真实 Dock，并回读。返回回读到的全量域。
    @discardableResult
    private static func writeBack(_ domain: [String: PlistValue], label: String) async -> [String: PlistValue] {
        let entries = DockPreferences.whitelistedKeys.reduce(into: [String: PlistValue]()) { result, key in
            if let value = domain[key] { result[key] = value }
        }
        DockPreferences.writeWhitelisted(entries)
        let outcome = await DockReloader().reload(strategy: .auto)
        print("[验收] \(label)：\(outcome.description)")
        return DockPreferences.readDomain()
    }

    private static func dump(_ domain: [String: PlistValue], named name: String) throws {
        var payload: [String: Any] = [:]
        for (key, value) in domain { payload[key] = value.anyValue }
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        try data.write(to: dumpDirectory.appendingPathComponent("multidock-acceptance-\(name).plist"))
    }
}

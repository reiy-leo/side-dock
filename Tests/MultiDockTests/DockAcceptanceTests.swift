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

    // MARK: - P3 验收：两个桌面来回切，结果稳定

    /// P3 验收标准（`docs/PLAN.md` §4 的 P3 行）里可脚本化的部分：
    /// - 桌面 1 与桌面 2 配置不同，来回切 20 次，**每次真实 Dock 都等于目标那份**；
    /// - 两桌面配置相同时切换**无 Dock 刷新**（`mod-count` 不动）；
    /// - 我们自己的写入**不会被 `DockWatcher` 误判成用户手动改动**（这会让配置被污染）。
    ///
    /// 无法脚本化的两条（需要真的拖图标）留在 `AGENTS.md` §6.3 交给用户手测。
    func testSwitchingBetweenTwoDesktopConfigsIsStable() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.enableFlag] == "1",
            "会真的重启 Dock；设 \(Self.enableFlag)=1 才跑"
        )

        let before = DockPreferences.readDomain()
        XCTAssertFalse(before.isEmpty, "读不到 com.apple.dock，验收无意义")
        try Self.dump(before, named: "p3-before")

        do {
            try await runDesktopSwitchPhase(before: before)
        } catch {
            await Self.writeBack(before, label: "异常还原")
            throw error
        }

        let restored = await Self.writeBack(before, label: "P3 验收结束还原")
        try Self.dump(restored, named: "p3-after-restore")

        let illegal = Self.differences(between: before, and: restored)
            .subtracting(DockPreferences.whitelistedKeys)
            .subtracting(Self.dockSelfMutatingKeys)
        XCTAssertTrue(illegal.isEmpty, "还原后白名单外的键仍有差异：\(illegal.sorted())")
        XCTAssertEqual(Set(before.keys), Set(restored.keys), "键集合必须完全一致")
        print("""
        [P3 验收] 还原后差异键：\(Self.differences(between: before, and: restored).sorted())
        [P3 验收] 图标顺序 after-restore：\(Self.labels(of: restored))
        """)
    }

    private func runDesktopSwitchPhase(before: [String: PlistValue]) async throws {
        let controller = DockController(backup: {})   // 验收不写 App 的备份目录

        // 用真的 `DockWatcher`，但轮询周期拉长到 60 s —— 我们手动 `tick()`，
        // 这样"它有没有把我们的写入误判成用户改动"是确定性的，不受轮询时机影响。
        let misdetected = Box<[DockConfig]>([])
        let watcher = DockWatcher(
            pollInterval: .seconds(60),
            currentFingerprint: { controller.currentComparableFingerprint() },
            appliedFingerprint: { controller.appliedComparableFingerprint },
            readLiveConfig: { controller.captureLiveConfig() },
            onUserEdit: { misdetected.value.append($0) }
        )

        // ---- 两套明显不同的配置：图标大小与放大效果都不同 ----
        let base = DockConfig.read(from: before)
        var desktop1 = base
        desktop1.appearance.tilesize = 40
        desktop1.appearance.magnification = false
        var desktop2 = base
        desktop2.appearance.tilesize = 60
        desktop2.appearance.magnification = true
        XCTAssertNotEqual(desktop1.fingerprint, desktop2.fingerprint)

        let targets = [desktop1, desktop2]
        var switches = 0
        /// Dock **真正不可用**的时长（重载本身）。这才是用户能感觉到的那个数。
        var dockDownTimings: [Int] = []
        /// 一次应用的**总**耗时。包含为错开 launchd 节流而主动等待的时间（期间 Dock 可用）。
        var totalTimings: [Int] = []
        var lastApplied = desktop1

        // ---- 来回切 20 次，每次都核对真实 Dock 是否等于目标那份 ----
        for round in 0..<20 {
            let target = targets[round % targets.count]
            let outcome = await controller.apply(target, reason: "P3 验收 第 \(round + 1) 次")
            switches += 1
            lastApplied = target
            dockDownTimings.append(Int((outcome.reload?.elapsed ?? 0) * 1000))
            totalTimings.append(Int(outcome.elapsed * 1000))

            XCTAssertEqual(outcome.result, .applied, "第 \(round + 1) 次应用失败：\(outcome.summary)")
            XCTAssertEqual(outcome.verifyAttempts, 1, "第 \(round + 1) 次需要重试，不该发生")
            XCTAssertEqual(outcome.reload?.method, .sighup, "主路径必须是 SIGHUP")
            // 节流窗口错开后，Dock 每次只该消失几十毫秒。
            // 若这里出现约 1000 ms，说明 minimumSpacing 失效了，用户会看到 Dock 消失一秒。
            XCTAssertLessThan(outcome.reload?.elapsed ?? 99, 0.3,
                              "第 \(round + 1) 次 Dock 不可用 \(Int((outcome.reload?.elapsed ?? 0) * 1000)) ms，节流没被错开")

            let live = DockPreferences.readDomain()
            XCTAssertEqual(live["tilesize"]?.doubleValue, target.appearance.tilesize,
                           "第 \(round + 1) 次切换后真实 Dock 的 tilesize 不对")
            XCTAssertEqual(live["magnification"]?.boolValue, target.appearance.magnification,
                           "第 \(round + 1) 次切换后真实 Dock 的 magnification 不对")

            // 关键：我们刚写完，Dock 会规范化回写（补 GUID 等）。
            // 这次"变化"绝不能被当成用户手动改动 —— 否则配置会被污染成 Dock 的规范化结果。
            watcher.tick()
            watcher.acknowledge(controller.appliedComparableFingerprint)
        }

        XCTAssertEqual(switches, 20)
        XCTAssertEqual(misdetected.value.count, 0,
                       "我们的写入被误判成用户手动改动 \(misdetected.value.count) 次")
        XCTAssertEqual(watcher.detectedCount, 0)
        print("""
        [P3 验收] 来回切 \(switches) 次全部成功
        [P3 验收] Dock 不可用时长（ms）：\(dockDownTimings)　最坏 \(dockDownTimings.max() ?? 0) ms
        [P3 验收] 应用总耗时（ms）　：\(totalTimings)　最坏 \(totalTimings.max() ?? 0) ms
        [P3 验收] DockWatcher 误判次数：\(watcher.detectedCount)（必须为 0）
        """)

        // ---- 两桌面配置相同时，切换必须零开销（不重启 Dock） ----
        // 用循环里最后落点那份来试，它此刻正是真实 Dock 的内容。
        let modCountBefore = DockPreferences.readDomain()["mod-count"]?.intValue
        let identical = await controller.apply(lastApplied, reason: "P3 验收 内容相同")
        XCTAssertEqual(identical.result, .skippedIdentical, "内容相同必须短路")
        XCTAssertNil(identical.reload, "短路时不该重启 Dock")
        XCTAssertEqual(DockPreferences.readDomain()["mod-count"]?.intValue, modCountBefore,
                       "短路时 mod-count 不该变 —— 变了说明 Dock 其实被重启了")
        print("[P3 验收] 内容相同时短路：\(identical.summary)")
    }

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

import XCTest
@testable import MultiDock

/// 基准快照、会话标记与备份轮转。对应 `docs/PLAN.md` §4 里「还原逻辑」的验收点。
final class BaselineStoreTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MultiDockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
        try super.tearDownWithError()
    }

    private func makeStore() -> BaselineStore {
        BaselineStore(
            baselineURL: sandbox.appendingPathComponent("baseline.plist"),
            markerURL: sandbox.appendingPathComponent("session.state"),
            backupsURL: sandbox.appendingPathComponent("backups", isDirectory: true)
        )
    }

    // MARK: - 会话标记

    func testMarkerRoundTrip() throws {
        let store = makeStore()
        XCTAssertNil(store.readSessionMarker())

        let marker = BaselineStore.SessionMarker(
            pid: 4242,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appliedFingerprint: "abc123",
            appliedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try store.writeSessionMarker(marker)

        let loaded = try XCTUnwrap(store.readSessionMarker())
        XCTAssertEqual(loaded.pid, 4242)
        XCTAssertEqual(loaded.appliedFingerprint, "abc123")
        XCTAssertTrue(loaded.impliesDirtyDock)
    }

    func testMarkerWithoutAppliedFingerprintIsNotDirty() throws {
        // P1 阶段不写 Dock，标记里的 appliedFingerprint 恒为 nil。
        // 这时残留标记不该被当成"Dock 被改脏了"，否则每次强杀都会误报。
        let store = makeStore()
        try store.writeSessionMarker(.init(pid: 4242, startedAt: Date()))

        let loaded = try XCTUnwrap(store.readSessionMarker())
        XCTAssertNil(loaded.appliedFingerprint)
        XCTAssertFalse(loaded.impliesDirtyDock)
    }

    func testInterruptedSessionDetectedWhenProcessIsGone() throws {
        let store = makeStore()
        // PID 1 存在但一定不是我们；用一个几乎不可能存在的 PID 模拟"进程已死"。
        // 这里直接写一个极大 PID：kill 会返回 ESRCH。
        try store.writeSessionMarker(.init(pid: 999_999, startedAt: Date()))

        let detected = try XCTUnwrap(store.detectInterruptedSession())
        XCTAssertEqual(detected.pid, 999_999)
    }

    func testLiveProcessIsNotTreatedAsInterruptedSession() throws {
        // 多实例场景：标记里的 PID 还活着 → 那是另一个正在跑的实例，不是残留。
        let store = makeStore()
        try store.writeSessionMarker(
            .init(pid: ProcessInfo.processInfo.processIdentifier, startedAt: Date())
        )
        XCTAssertNil(store.detectInterruptedSession())
    }

    func testClearMarker() throws {
        let store = makeStore()
        try store.writeSessionMarker(.init(pid: 999_999, startedAt: Date()))
        store.clearSessionMarker()
        XCTAssertNil(store.readSessionMarker())
    }

    // MARK: - 基准快照

    func testBaselineIsCapturedOnlyOnce() throws {
        let store = makeStore()
        XCTAssertFalse(store.hasBaseline)

        let firstCapture = try store.captureBaselineIfNeeded()
        XCTAssertTrue(firstCapture, "首次运行应当新建基准")
        XCTAssertTrue(store.hasBaseline)

        // 改动基准文件内容，确认第二次调用不会覆盖它。
        let sentinel = Data("sentinel-not-a-real-plist".utf8)
        try sentinel.write(to: store.baselineURL)

        let secondCapture = try store.captureBaselineIfNeeded()
        XCTAssertFalse(secondCapture, "基准已存在时不该再捕获")
        XCTAssertEqual(try Data(contentsOf: store.baselineURL), sentinel, "基准快照绝不能被覆盖")
    }

    func testBaselineContainsFullDockDomain() throws {
        let store = makeStore()
        try store.captureBaselineIfNeeded()
        let baseline = store.readBaseline()

        // 只读校验：基准必须包含真实 Dock 的全部键（含被排除的那些），
        // 因为它是"还原到出厂状态"的唯一依据。
        XCTAssertFalse(baseline.isEmpty)
        XCTAssertNotNil(baseline["persistent-apps"])
        XCTAssertNotNil(baseline["tilesize"])
    }

    func testResetBaselineOverwritesDeliberately() throws {
        let store = makeStore()
        try store.captureBaselineIfNeeded()
        try Data("old".utf8).write(to: store.baselineURL)

        try store.resetBaselineToCurrent()
        XCTAssertNotEqual(try Data(contentsOf: store.baselineURL), Data("old".utf8))
        XCTAssertFalse(store.readBaseline().isEmpty)
    }

    // MARK: - 备份轮转

    func testBackupRotationKeepsOnlyMostRecent() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.backupsURL, withIntermediateDirectories: true)

        // 预置 25 份历史备份，文件名按时间递增。
        for index in 0..<25 {
            let name = String(format: "dock-20260101-%05d.plist", index)
            try Data("backup".utf8).write(to: store.backupsURL.appendingPathComponent(name))
        }

        try store.rotateBackup()

        let remaining = store.existingBackups()
        XCTAssertEqual(remaining.count, store.maxBackups, "应只保留最近 \(store.maxBackups) 份")
        // 最旧的几份必须被裁掉。
        XCTAssertFalse(
            remaining.contains { $0.lastPathComponent == "dock-20260101-00000.plist" },
            "最旧的备份应被裁掉"
        )
        XCTAssertFalse(
            remaining.contains { $0.lastPathComponent == "dock-20260101-00005.plist" },
            "第 6 旧的备份也应被裁掉"
        )
    }

    func testExistingBackupsAreSortedNewestFirst() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.backupsURL, withIntermediateDirectories: true)
        for name in ["dock-20260101-00001.plist", "dock-20260101-00003.plist", "dock-20260101-00002.plist"] {
            try Data("x".utf8).write(to: store.backupsURL.appendingPathComponent(name))
        }
        let names = store.existingBackups().map(\.lastPathComponent)
        XCTAssertEqual(names, [
            "dock-20260101-00003.plist",
            "dock-20260101-00002.plist",
            "dock-20260101-00001.plist",
        ])
    }

    func testNonPlistFilesAreIgnored() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.backupsURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.backupsURL.appendingPathComponent("readme.txt"))
        try Data("x".utf8).write(to: store.backupsURL.appendingPathComponent("dock-20260101-00001.plist"))
        XCTAssertEqual(store.existingBackups().count, 1)
    }

    // MARK: - 自愈债务（P4）

    func testNeedsSelfHealSurvivesRoundTripAndMarksDirty() throws {
        let store = makeStore()
        try store.writeSessionMarker(.init(pid: 999_999, startedAt: Date(), needsSelfHeal: true))

        let loaded = try XCTUnwrap(store.readSessionMarker())
        XCTAssertEqual(loaded.needsSelfHeal, true)
        XCTAssertTrue(loaded.impliesDirtyDock, "继承来的自愈债务也算 Dock 可能不干净")
    }

    func testMarkerWrittenByOlderVersionStillDecodes() throws {
        // 老版本的 `session.state` 里没有 needsSelfHeal。用非可选字段会让解码失败，
        // 而解码失败等于"没有残留标记" —— 会静默丢掉自愈能力。
        let store = makeStore()
        let legacy = #"{"pid":999999,"startedAt":"2026-09-01T00:00:00Z","appliedFingerprint":"abc"}"#
        try Data(legacy.utf8).write(to: store.markerURL)

        let loaded = try XCTUnwrap(store.readSessionMarker())
        XCTAssertNil(loaded.needsSelfHeal)
        XCTAssertEqual(loaded.appliedFingerprint, "abc")
        XCTAssertTrue(loaded.impliesDirtyDock)
    }

    func testInactiveMarkerWithZeroPIDIsAlwaysTreatedAsInterrupted() throws {
        // 退出还原失败时我们主动留下的标记：pid = 0 表示"不是另一个还活着的实例"，
        // 所以必须被当成残留，而不是被 `kill(pid, 0)` 那条多实例检查忽略掉。
        let store = makeStore()
        try store.writeSessionMarker(.init(pid: 0, startedAt: Date(), needsSelfHeal: true))

        let detected = try XCTUnwrap(store.detectInterruptedSession())
        XCTAssertEqual(detected.pid, 0)
    }

    // MARK: - 历史备份（P4）

    func testBackupDateIsParsedFromFileName() throws {
        let parsed = try XCTUnwrap(BaselineStore.date(fromBackupName: "dock-20260918-010203.plist"))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        XCTAssertEqual(formatter.string(from: parsed), "20260918-010203")
    }

    func testUnparseableBackupNameFallsBackToModificationDate() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.backupsURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.backupsURL.appendingPathComponent("my-dock-backup.plist"))

        let entry = try XCTUnwrap(store.listBackups().first)
        XCTAssertEqual(entry.fileName, "my-dock-backup.plist")
        XCTAssertNotEqual(entry.date, .distantPast, "文件名解析不出来时要退回文件修改时间")
    }

    func testListBackupsIsNewestFirstWithParsedDates() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.backupsURL, withIntermediateDirectories: true)
        for name in ["dock-20260101-000001.plist", "dock-20260918-090000.plist"] {
            try Data("x".utf8).write(to: store.backupsURL.appendingPathComponent(name))
        }

        let entries = store.listBackups()
        XCTAssertEqual(entries.map(\.fileName), [
            "dock-20260918-090000.plist",
            "dock-20260101-000001.plist",
        ])
        XCTAssertGreaterThan(entries[0].date, entries[1].date)
    }

    func testReadBackupParsesTheSnapshot() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.backupsURL, withIntermediateDirectories: true)
        let url = store.backupsURL.appendingPathComponent("dock-20260918-090000.plist")
        let payload: [String: Any] = ["tilesize": 44.0, "orientation": "left"]
        try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
            .write(to: url)

        let domain = store.readBackup(at: url)
        XCTAssertEqual(domain["tilesize"], .double(44))
        XCTAssertEqual(domain["orientation"], .string("left"))
    }

    func testReadBackupReturnsEmptyForCorruptFile() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.backupsURL, withIntermediateDirectories: true)
        let url = store.backupsURL.appendingPathComponent("dock-20260918-090000.plist")
        try Data("not a plist".utf8).write(to: url)

        XCTAssertTrue(store.readBackup(at: url).isEmpty, "坏文件必须返回空，让调用方拒绝写 Dock")
    }
}

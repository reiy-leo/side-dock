import Foundation

/// 基准快照 + 会话标记 + 备份轮转。无痕原则的三根支柱（计划 §3.3）。
///
/// P1 只做「读 + 落盘」这部分（不改任何 Dock 设置）：
/// - 首次运行把当时的 `com.apple.dock` **全量域**存为基准，此后不覆盖。
/// - 会话标记照常读写，但里面记录了「本次是否真的改过 Dock」；
///   由于 P1 不写 Dock，`appliedFingerprint` 恒为 nil，因此不会产生误报。
///   真正触发还原要等 P2/P4 的写路径就位。
struct BaselineStore: Sendable {

    /// 会话标记。正常退出还原成功后删除；残留即代表上次被强杀/崩溃/断电。
    struct SessionMarker: Codable, Sendable {
        var pid: Int32
        var startedAt: Date
        /// 最近一次应用到真实 Dock 的归一化指纹。nil 表示本次运行从未改过 Dock。
        var appliedFingerprint: String?
        var appliedAt: Date?

        /// 残留标记是否意味着「Dock 可能处于非基准状态」。
        var impliesDirtyDock: Bool { appliedFingerprint != nil }
    }

    var baselineURL: URL = AppPaths.baselineFile
    var markerURL: URL = AppPaths.sessionMarkerFile
    var backupsURL: URL = AppPaths.backupsDirectory
    var maxBackups = 20

    // MARK: - 基准快照

    /// 基准是否已存在。
    var hasBaseline: Bool { FileManager.default.fileExists(atPath: baselineURL.path) }

    /// 首次运行时捕获基准。**已存在则不做任何事**（基准此后不覆盖）。
    /// - Returns: 本次是否真的新建了基准。
    @discardableResult
    func captureBaselineIfNeeded() throws -> Bool {
        guard !hasBaseline else { return false }
        try AppPaths.ensureDirectory()
        guard let data = DockPreferences.exportDomainData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: baselineURL, options: .atomic)
        return true
    }

    /// 读基准快照的全量域。
    func readBaseline() -> [String: PlistValue] {
        guard
            let data = try? Data(contentsOf: baselineURL),
            let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        var result: [String: PlistValue] = [:]
        for (key, value) in raw {
            if let converted = PlistValue(any: value) { result[key] = converted }
        }
        return result
    }

    /// 用当前 Dock 现状覆盖基准（用户满意当前状态时的「设为新基准」）。
    func resetBaselineToCurrent() throws {
        try AppPaths.ensureDirectory()
        guard let data = DockPreferences.exportDomainData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: baselineURL, options: .atomic)
    }

    // MARK: - 会话标记

    func readSessionMarker() -> SessionMarker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionMarker.self, from: data)
    }

    func writeSessionMarker(_ marker: SessionMarker) throws {
        try AppPaths.ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
    }

    func clearSessionMarker() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// 启动自检：是否存在「上次没走完还原」的残留标记。
    ///
    /// 会校验标记里的 PID 是否还活着，避免多实例或误判。
    func detectInterruptedSession() -> SessionMarker? {
        guard let marker = readSessionMarker() else { return nil }
        // 进程还活着 → 是另一个实例，不是残留。
        if marker.pid != 0, kill(marker.pid, 0) == 0 { return nil }
        return marker
    }

    // MARK: - 备份轮转

    /// 写真实 Dock 前留一份全量域备份，保留最近 `maxBackups` 份。
    @discardableResult
    func rotateBackup() throws -> URL {
        try AppPaths.ensureDirectory()
        try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        guard let data = DockPreferences.exportDomainData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let file = backupsURL.appendingPathComponent("dock-\(formatter.string(from: Date())).plist")
        try data.write(to: file, options: .atomic)
        try pruneBackups()
        return file
    }

    func existingBackups() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: backupsURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func pruneBackups() throws {
        let files = existingBackups()
        guard files.count > maxBackups else { return }
        for stale in files.dropFirst(maxBackups) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}

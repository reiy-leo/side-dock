import Foundation

/// 应用数据目录：`~/Library/Application Support/MultiDock/`
enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MultiDock", isDirectory: true)
    }

    static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    static var baselineFile: URL { supportDirectory.appendingPathComponent("baseline.plist") }
    static var sessionMarkerFile: URL { supportDirectory.appendingPathComponent("session.state") }
    static var backupsDirectory: URL { supportDirectory.appendingPathComponent("backups", isDirectory: true) }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}

/// 用户配置的持久化：桌面绑定 + 全局设置。
///
/// 原子写：先写临时文件再 `rename`（计划 §3.2）。
struct ConfigStore: Sendable {

    struct Payload: Codable, Sendable {
        var bindings: [DesktopBinding] = []
        var settings = AppSettings()
        var schemaVersion = 1
    }

    var fileURL: URL = AppPaths.configFile

    func load() -> Payload {
        guard let data = try? Data(contentsOf: fileURL) else { return Payload() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Payload.self, from: data)) ?? Payload()
    }

    func save(_ payload: Payload) throws {
        try AppPaths.ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".config-\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        // rename 是原子的：要么旧文件完整，要么新文件完整，不会出现半个 JSON。
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
    }
}

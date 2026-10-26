import Foundation

// 配置同步到云盘文件夹（2026-10-26 用户规格：「每台电脑有一个单独的同步，互不干扰」）。
//
// App 只读写文件，上传下载交给云盘客户端（Google Drive 桌面版、iCloud Drive、Dropbox、
// 访达里挂载的 WebDAV 卷都行）。每台 Mac 只写自己那份：
// `<同步文件夹>/SideDock/<硬件 UUID>.json`，永远不写、不删别的设备的文件。
// 规格见 docs/PLAN.md §3.14。

/// 同步设置：**只存本机**（`sync-settings.json`），不进 config.json，也不进同步文件。
struct SyncSettings: Codable, Equatable, Sendable {
    /// 用户选的同步文件夹（普通路径；App 未沙盒，不需要 security-scoped bookmark）。nil = 没开同步。
    var folderPath: String?
    /// 配置每次落盘后约 2 秒自动写一次自己那份。
    var autoSync = true
    /// 上次真的写出（或确认已是最新）的时间。
    var lastSyncAt: Date?

    init(folderPath: String? = nil, autoSync: Bool = true, lastSyncAt: Date? = nil) {
        self.folderPath = folderPath
        self.autoSync = autoSync
        self.lastSyncAt = lastSyncAt
    }

    enum CodingKeys: String, CodingKey {
        case folderPath, autoSync, lastSyncAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath)
        autoSync = try container.decodeIfPresent(Bool.self, forKey: .autoSync) ?? true
        lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
    }
}

/// 同步设置的读写。`fileURL == nil` = 只在内存（测试默认，绝不碰真实目录）。
struct SyncSettingsStore: Sendable {
    var fileURL: URL?

    static var live: SyncSettingsStore {
        SyncSettingsStore(fileURL: AppPaths.supportDirectory.appendingPathComponent("sync-settings.json"))
    }

    static var inMemory: SyncSettingsStore { SyncSettingsStore(fileURL: nil) }

    func load() -> SyncSettings {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return SyncSettings() }
        return (try? ConfigSync.makeDecoder().decode(SyncSettings.self, from: data)) ?? SyncSettings()
    }

    func save(_ settings: SyncSettings) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ConfigSync.makeEncoder().encode(settings).write(to: fileURL, options: .atomic)
    }
}

/// 桌面的序号：第几块屏（1 = 主屏）· 这块屏上第几个桌面（从 1 起）。
/// 跨机导入时桌面 UUID 必然对不上，按序号映射到本机同序号的桌面。
struct SpaceOrdinal: Codable, Hashable, Sendable {
    var display: Int
    var desktop: Int
}

/// 一台 Mac 写出的同步文件。`config` 与 config.json 同构（同一个 `ConfigStore.Payload`）。
struct SyncSnapshot: Codable, Sendable {
    static let currentFormat = 1

    var format = SyncSnapshot.currentFormat
    var deviceID: String
    var deviceName: String
    var appVersion: String
    var writtenAt: Date
    /// 写出时每个桌面的序号（`DesktopSpace.id` → 序号）。附加字段，不改 config.json 格式。
    var spaceOrdinals: [String: SpaceOrdinal] = [:]
    var config: ConfigStore.Payload

    init(
        deviceID: String,
        deviceName: String,
        appVersion: String,
        writtenAt: Date,
        spaceOrdinals: [String: SpaceOrdinal],
        config: ConfigStore.Payload
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.writtenAt = writtenAt
        self.spaceOrdinals = spaceOrdinals
        self.config = config
    }

    enum CodingKeys: String, CodingKey {
        case format, deviceID, deviceName, appVersion, writtenAt, spaceOrdinals, config
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(Int.self, forKey: .format) ?? SyncSnapshot.currentFormat
        deviceID = try container.decode(String.self, forKey: .deviceID)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? deviceID
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        writtenAt = try container.decodeIfPresent(Date.self, forKey: .writtenAt) ?? Date(timeIntervalSince1970: 0)
        spaceOrdinals = try container.decodeIfPresent([String: SpaceOrdinal].self, forKey: .spaceOrdinals) ?? [:]
        config = try container.decode(ConfigStore.Payload.self, forKey: .config)
    }
}

/// 同步的纯规则（不碰磁盘，全部可单测）。
enum ConfigSync {
    /// 同步文件夹里放各设备文件的子目录。
    static let folderName = "SideDock"

    /// 与 `ConfigStore.encode` 同一套格式：缩进、键排序、日期 ISO8601。
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 设备文件名：`<设备 ID>.json`。ID 里只留字母、数字、`-`、`_`，别的换成 `-`，
    /// 防止怪字符变成子目录或隐藏文件。
    static func fileName(deviceID: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var cleaned = String(deviceID.map { allowed.contains($0) ? $0 : "-" })
        while cleaned.hasPrefix("-") || cleaned.hasPrefix("_") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "device" }
        return cleaned + ".json"
    }

    /// 写进同步文件的那份配置：去掉本机专属内容。
    ///
    /// - `secondaryDockRowPrefs`：按本机桌面 UUID 记的「上次滚到哪一行」，换台机器没意义；
    /// - `DesktopBinding.override`：已废弃的迁移字段，一律不带。
    ///
    /// 基准快照、备份、会话标记、mru-spaces、登录启动项、同步设置本来就不在 Payload 里。
    static func syncPayload(from payload: ConfigStore.Payload) -> ConfigStore.Payload {
        var result = payload
        result.settings.secondaryDockRowPrefs = [:]
        for index in result.bindings.indices { result.bindings[index].override = nil }
        return result
    }

    /// 导入同步文件时，本机专属字段保留本机的值（与 `syncPayload` 去掉的是同一批）。
    static func keepingLocalOnlyFields(_ incoming: ConfigStore.Payload, local: AppSettings) -> ConfigStore.Payload {
        var result = incoming
        result.settings.secondaryDockRowPrefs = local.secondaryDockRowPrefs
        return result
    }

    /// 每个桌面的序号。屏的顺序：主屏第一，其余按桌面列表里出现的先后。
    /// SkyLight 在「显示器使用不同空间」关掉时把屏叫作 `Main`，也算主屏。
    static func ordinals(for desktops: [DesktopSpace], mainDisplayUUID: String?) -> [String: SpaceOrdinal] {
        var displays: [String] = []
        for space in desktops where !displays.contains(space.displayUUID) {
            displays.append(space.displayUUID)
        }
        func isMain(_ uuid: String) -> Bool {
            if uuid == "Main" { return true }
            guard let mainDisplayUUID else { return false }
            return uuid.caseInsensitiveCompare(mainDisplayUUID) == .orderedSame
        }
        if let mainIndex = displays.firstIndex(where: isMain), mainIndex > 0 {
            displays.insert(displays.remove(at: mainIndex), at: 0)
        }
        var result: [String: SpaceOrdinal] = [:]
        for space in desktops {
            guard let index = displays.firstIndex(of: space.displayUUID) else { continue }
            result[space.id] = SpaceOrdinal(display: index + 1, desktop: space.ordinal)
        }
        return result
    }

    /// 绑定映射的结果（只数 Dock 栏；桌面命名同一规则，不单独报）。
    struct MappingReport: Equatable, Sendable {
        /// 桌面 ID 本机就有（多半是本机自己的快照）。
        var kept = 0
        /// 按「第几块屏 · 第几个桌面」映射到本机桌面。
        var mapped = 0
        /// 映射不到，保留原 ID（孤儿栏，设置页有提示和一键解绑）。
        var orphaned = 0
    }

    /// 把快照里的桌面绑定换成本机的桌面。
    ///
    /// 规则：本机有这个桌面 ID → 不动；否则按快照里记的序号找本机同序号的桌面；
    /// 再找不到 → 保留原 ID（成孤儿）。桌面命名同理，一个桌面只留第一条名字。
    static func mapSpaces(
        in payload: ConfigStore.Payload,
        sourceOrdinals: [String: SpaceOrdinal],
        localDesktops: [DesktopSpace],
        mainDisplayUUID: String?
    ) -> (payload: ConfigStore.Payload, report: MappingReport) {
        let localByID = Dictionary(localDesktops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var localByOrdinal: [SpaceOrdinal: DesktopSpace] = [:]
        for (id, ordinal) in ordinals(for: localDesktops, mainDisplayUUID: mainDisplayUUID) {
            if let space = localByID[id] { localByOrdinal[ordinal] = space }
        }

        enum Resolution { case kept(DesktopSpace), mapped(DesktopSpace), orphan }
        func resolve(_ id: String) -> Resolution {
            if let space = localByID[id] { return .kept(space) }
            if let ordinal = sourceOrdinals[id], let space = localByOrdinal[ordinal] { return .mapped(space) }
            return .orphan
        }

        var result = payload
        var report = MappingReport()
        for index in result.settings.dockBars.indices {
            guard let spaceID = result.settings.dockBars[index].spaceID else { continue }
            switch resolve(spaceID) {
            case .kept:
                report.kept += 1
            case .mapped(let space):
                result.settings.dockBars[index].spaceID = space.id
                report.mapped += 1
            case .orphan:
                report.orphaned += 1
            }
        }

        var bindings: [DesktopBinding] = []
        var seen: Set<String> = []
        for binding in result.bindings {
            var updated = binding
            switch resolve(binding.id) {
            case .kept, .orphan:
                break
            case .mapped(let space):
                updated.displayUUID = space.displayUUID
                updated.spaceUUID = space.spaceUUID
            }
            guard seen.insert(updated.id).inserted else { continue }
            bindings.append(updated)
        }
        result.bindings = bindings
        return (result, report)
    }

    /// 比较「内容变没变」用的键：写入时间不算（每次都不同），其余照原样编码。
    static func contentKey(of snapshot: SyncSnapshot) -> Data? {
        var copy = snapshot
        copy.writtenAt = Date(timeIntervalSince1970: 0)
        return try? makeEncoder().encode(copy)
    }
}

/// 同步文件夹的读写（只碰磁盘，不碰 UI；`Sendable`，可以放到后台线程跑——
/// 云盘目录偶尔会因为下载占位文件卡一下，不能卡主线程）。
struct ConfigSyncFolder: Sendable {
    /// 用户选的那个文件夹（例如 Google Drive 的「我的云端硬盘」）。
    var root: URL

    var directory: URL { root.appendingPathComponent(ConfigSync.folderName, isDirectory: true) }

    enum WriteResult: Equatable, Sendable {
        case written
        /// 内容和文件里的一样，没重写（不惊动云盘客户端）。
        case unchanged
    }

    enum SyncError: Error, Equatable, LocalizedError {
        /// 同步文件夹不在：云盘客户端没开、卷没挂载，或文件夹被删了。
        case folderMissing(String)
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .folderMissing(let path):
                return L("找不到同步文件夹：\(path)。云盘没开，或者没挂载？",
                         "Sync folder not found: \(path). Is the cloud drive running or mounted?")
            case .encodeFailed:
                return L("同步内容编码失败", "Couldn't encode the sync content")
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        var fileName: String
        var fileURL: URL
        var snapshot: SyncSnapshot
        var id: String { fileName }
    }

    func rootExists() -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// 写自己那份。只写 `fileName(deviceID:)` 这一个文件，别的设备的文件一概不碰。
    ///
    /// 原子写：同目录下点开头的临时文件 → `replaceItemAt`（目标还没有时 `moveItem`）。
    /// 内容和现有文件一样就不写，返回 `.unchanged`。
    func write(_ snapshot: SyncSnapshot) throws -> WriteResult {
        guard rootExists() else { throw SyncError.folderMissing(root.path) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = ConfigSync.fileName(deviceID: snapshot.deviceID)
        let target = directory.appendingPathComponent(name)
        guard let newKey = ConfigSync.contentKey(of: snapshot) else { throw SyncError.encodeFailed }
        if let existing = try? Data(contentsOf: target),
           let decoded = try? ConfigSync.makeDecoder().decode(SyncSnapshot.self, from: existing),
           ConfigSync.contentKey(of: decoded) == newKey {
            return .unchanged
        }

        let data: Data
        do {
            data = try ConfigSync.makeEncoder().encode(snapshot)
        } catch {
            throw SyncError.encodeFailed
        }
        let temporary = directory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: target)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        return .written
    }

    /// 列出文件夹里所有设备的快照（只读）。读不懂的文件跳过并计数。
    func list() throws -> (entries: [Entry], unreadable: Int) {
        guard rootExists() else { throw SyncError.folderMissing(root.path) }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return ([], 0) }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var entries: [Entry] = []
        var unreadable = 0
        let decoder = ConfigSync.makeDecoder()
        for url in urls where url.pathExtension.lowercased() == "json" && !url.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? decoder.decode(SyncSnapshot.self, from: data) else {
                unreadable += 1
                continue
            }
            entries.append(Entry(fileName: url.lastPathComponent, fileURL: url, snapshot: snapshot))
        }
        entries.sort { $0.snapshot.writtenAt > $1.snapshot.writtenAt }
        return (entries, unreadable)
    }
}

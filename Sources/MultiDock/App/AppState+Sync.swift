import Foundation

/// 同步的外部依赖（2026-10-26）。全部可注入：测试默认 `.inert`，不碰真实目录、不读硬件。
struct SyncEnvironment {
    var settingsStore: SyncSettingsStore
    var identity: () -> DeviceIdentity
    var appVersion: String
    /// 配置落盘后等多久再写同步文件（防抖）。
    var debounce: Duration

    /// 测试与快照默认：设置只在内存、固定的假设备、不会自动写任何文件夹（没有文件夹）。
    static var inert: SyncEnvironment {
        SyncEnvironment(
            settingsStore: .inMemory,
            identity: { DeviceIdentity(id: "TEST-DEVICE", name: "Test Mac") },
            appVersion: "dev",
            debounce: .seconds(2)
        )
    }

    /// 真机：设置存 `sync-settings.json`，身份读硬件 UUID 与电脑名。
    static var live: SyncEnvironment {
        SyncEnvironment(
            settingsStore: .live,
            identity: { DeviceIdentity.current() },
            appVersion: currentAppVersion(),
            debounce: .seconds(2)
        )
    }

    static func currentAppVersion(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "dev"
        }
    }
}

/// 配置同步到云盘文件夹（2026-10-26 用户规格：「每台电脑有一个单独的同步，互不干扰」）。
/// 规格见 docs/PLAN.md §3.14；纯规则在 `ConfigSync`，磁盘读写在 `ConfigSyncFolder`。
extension AppState {

    var syncFolderURL: URL? {
        syncSettings.folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// 同步文件夹此刻在不在（云盘客户端没开 / 卷没挂载时是 false）。
    var syncFolderAvailable: Bool {
        guard let url = syncFolderURL else { return false }
        return ConfigSyncFolder(root: url).rootExists()
    }

    func isThisDevice(_ entry: ConfigSyncFolder.Entry) -> Bool {
        entry.snapshot.deviceID == deviceIdentity.id
    }

    // MARK: - 设置

    func chooseSyncFolder(_ url: URL) {
        syncSettings.folderPath = url.standardizedFileURL.path
        saveSyncSettings()
        append(.info, L("同步文件夹设为 \(url.path)", "Sync folder set to \(url.path)"))
        syncStatusMessage = nil
        syncStatusFailed = false
        refreshSyncSnapshots()
        if syncSettings.autoSync { syncNow(manual: false) }
    }

    /// 不再同步：只忘掉文件夹，文件夹里已有的文件一个不删。
    func clearSyncFolder() {
        syncDebounceTask?.cancel()
        syncSettings.folderPath = nil
        saveSyncSettings()
        syncSnapshots = []
        syncUnreadableCount = 0
        syncStatusMessage = L("已停止同步。云盘里已有的文件没删。", "Sync stopped. Files already in the cloud folder were kept.")
        syncStatusFailed = false
        append(.info, L("已停止同步（云盘里的文件保留）", "Sync stopped (files in the cloud folder kept)"))
    }

    func setAutoSync(_ enabled: Bool) {
        guard syncSettings.autoSync != enabled else { return }
        syncSettings.autoSync = enabled
        saveSyncSettings()
        if enabled {
            syncNow(manual: false)
        } else {
            syncDebounceTask?.cancel()
        }
    }

    private func saveSyncSettings() {
        do {
            try syncEnvironment.settingsStore.save(syncSettings)
        } catch {
            append(.error, L("同步设置保存失败：\(error.localizedDescription)", "Failed to save sync settings: \(error.localizedDescription)"))
        }
    }

    // MARK: - 写自己那份

    /// 配置落盘后调用：开了自动同步就防抖约 2 秒再写（连续改动只写最后一次）。
    func scheduleAutoSync() {
        guard syncSettings.autoSync, syncSettings.folderPath != nil else { return }
        syncDebounceTask?.cancel()
        let delay = syncEnvironment.debounce
        syncDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.syncNow(manual: false)
        }
    }

    /// 这台 Mac 此刻的同步内容（去掉本机专属字段，附上桌面序号）。
    func makeSyncSnapshot(at date: Date = Date()) -> SyncSnapshot {
        SyncSnapshot(
            deviceID: deviceIdentity.id,
            deviceName: deviceIdentity.name,
            appVersion: syncEnvironment.appVersion,
            writtenAt: date,
            spaceOrdinals: ConfigSync.ordinals(for: desktops, mainDisplayUUID: displayScreens.first?.uuid),
            config: ConfigSync.syncPayload(from: .init(bindings: bindings, settings: settings))
        )
    }

    /// 立即写一次自己那份。磁盘读写放到后台线程（云盘目录偶尔会卡）。
    /// 返回在飞的任务（测试用来等结果）；没选文件夹时返回 nil。
    @discardableResult
    func syncNow(manual: Bool = true) -> Task<Void, Never>? {
        guard let root = syncFolderURL else {
            if manual {
                syncStatusMessage = L("先选一个同步文件夹。", "Choose a sync folder first.")
                syncStatusFailed = true
            }
            return nil
        }
        syncDebounceTask?.cancel()
        let folder = ConfigSyncFolder(root: root)
        let snapshot = makeSyncSnapshot()
        let task = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                () -> Result<ConfigSyncFolder.WriteResult, any Error> in
                Result { try folder.write(snapshot) }
            }.value
            self?.finishSync(result, manual: manual, at: snapshot.writtenAt)
        }
        syncWriteTask = task
        return task
    }

    private func finishSync(_ result: Result<ConfigSyncFolder.WriteResult, any Error>, manual: Bool, at date: Date) {
        let time = date.formatted(date: .omitted, time: .shortened)
        switch result {
        case .success(.written):
            syncSettings.lastSyncAt = date
            saveSyncSettings()
            syncStatusMessage = L("\(time) 已同步。", "Synced at \(time).")
            syncStatusFailed = false
            append(.info, L("配置已同步到 \(syncSettings.folderPath ?? "")", "Config synced to \(syncSettings.folderPath ?? "")"))
            refreshSyncSnapshots()
        case .success(.unchanged):
            syncSettings.lastSyncAt = date
            saveSyncSettings()
            if manual || syncStatusFailed {
                syncStatusMessage = L("\(time) 查过，已是最新，没重写。", "Checked at \(time): already up to date, not rewritten.")
                syncStatusFailed = false
            }
            if manual { refreshSyncSnapshots() }
        case .failure(let error):
            syncStatusMessage = L("同步失败：\(error.localizedDescription)", "Sync failed: \(error.localizedDescription)")
            syncStatusFailed = true
            append(.warning, L("配置同步失败：\(error.localizedDescription)", "Config sync failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - 读各设备的快照

    /// 重读同步文件夹里的设备列表（只读，后台线程）。
    @discardableResult
    func refreshSyncSnapshots() -> Task<Void, Never>? {
        guard let root = syncFolderURL else {
            syncSnapshots = []
            syncUnreadableCount = 0
            return nil
        }
        let folder = ConfigSyncFolder(root: root)
        syncListTask?.cancel()
        let task = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                () -> Result<[ConfigSyncFolder.Entry], any Error> in
                Result {
                    let listed = try folder.list()
                    if listed.unreadable > 0 {
                        throw UnreadableCount(entries: listed.entries, count: listed.unreadable)
                    }
                    return listed.entries
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let entries):
                self.syncSnapshots = self.sortedSnapshots(entries)
                self.syncUnreadableCount = 0
            case .failure(let error as UnreadableCount):
                self.syncSnapshots = self.sortedSnapshots(error.entries)
                self.syncUnreadableCount = error.count
            case .failure(let error):
                self.syncSnapshots = []
                self.syncUnreadableCount = 0
                self.syncStatusMessage = error.localizedDescription
                self.syncStatusFailed = true
            }
        }
        syncListTask = task
        return task
    }

    /// 本机那份排最前，其余按写入时间新到旧。
    private func sortedSnapshots(_ entries: [ConfigSyncFolder.Entry]) -> [ConfigSyncFolder.Entry] {
        entries.sorted { lhs, rhs in
            let lhsMine = isThisDevice(lhs)
            let rhsMine = isThisDevice(rhs)
            if lhsMine != rhsMine { return lhsMine }
            return lhs.snapshot.writtenAt > rhs.snapshot.writtenAt
        }
    }

    // MARK: - 导入（从云端恢复 / 导入到本机）

    /// 用一份快照**整份替换**本机设置（与「导入配置」同一套归一化）。
    ///
    /// 桌面绑定按「第几块屏 · 第几个桌面」映射到本机；映射不到的留成孤儿栏。
    /// 本机专属字段（次级条上次滚到的行）保留本机的值。不自动应用原生 Dock。
    @discardableResult
    func importSyncSnapshot(_ entry: ConfigSyncFolder.Entry) -> ConfigSync.MappingReport {
        let mine = isThisDevice(entry)
        let (mapped, report) = ConfigSync.mapSpaces(
            in: entry.snapshot.config,
            sourceOrdinals: entry.snapshot.spaceOrdinals,
            localDesktops: desktops,
            mainDisplayUUID: displayScreens.first?.uuid
        )
        let payload = ConfigSync.keepingLocalOnlyFields(mapped, local: settings)
        replaceConfiguration(with: payload)

        let name = entry.snapshot.deviceName
        var message = mine
            ? L("已从云端恢复本机设置。", "Restored this Mac's settings from the cloud.")
            : L("已导入「\(name)」的设置。", "Imported settings from “\(name)”.")
        if report.mapped > 0 {
            message += L("\(report.mapped) 根栏按桌面序号对上了本机桌面。", " \(report.mapped) bar(s) matched desktops by order.")
        }
        if report.orphaned > 0 {
            message += L("\(report.orphaned) 根栏没对上，在「应用栏」页可解绑。", " \(report.orphaned) bar(s) didn't match; unbind them in the Dock Bars tab.")
        }
        syncStatusMessage = message
        syncStatusFailed = false
        append(.info, L("同步导入：\(name)（\(entry.fileName)）· 原样 \(report.kept)、映射 \(report.mapped)、孤儿 \(report.orphaned)",
                        "Sync import: \(name) (\(entry.fileName)) · kept \(report.kept), mapped \(report.mapped), orphaned \(report.orphaned)"))
        return report
    }
}

/// 列表里有读不懂的文件：带着读得懂的那些一起返回（只在 `refreshSyncSnapshots` 内部用）。
private struct UnreadableCount: Error {
    var entries: [ConfigSyncFolder.Entry]
    var count: Int
}

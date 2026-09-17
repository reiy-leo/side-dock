import Foundation

/// 把日志追加写入 `~/Library/Application Support/MultiDock/multidock.log`。
///
/// 为什么除了统一日志还要落盘：本机实测 `log show` 在沙箱/受限环境下读不到，
/// 而"切桌面 10 次、spaceUUID 全对"这类验收需要能事后核对。
/// 出问题时用户也能直接把日志文件发出来。
///
/// 只保留最近 `maxBytes`，避免无限增长。
struct FileLogSink: Sendable {

    let fileURL: URL
    let maxBytes: Int

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("multidock.log"),
         maxBytes: Int = 512 * 1024) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    func append(_ entry: LogEntry) {
        let line = "\(Self.timestampFormatter.string(from: entry.timestamp)) "
            + "[\(entry.level.rawValue.uppercased())] \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }

        try? AppPaths.ensureDirectory()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
        truncateIfNeeded()
    }

    /// 超过上限就把文件截成后半段（保留最近的日志）。
    private func truncateIfNeeded() {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? Int,
            size > maxBytes
        else { return }

        guard let data = try? Data(contentsOf: fileURL) else { return }
        let tail = data.suffix(maxBytes / 2)
        // 从第一个完整行开始，避免留下半行。
        if let newline = tail.firstIndex(of: 0x0A) {
            try? Data(tail[tail.index(after: newline)...]).write(to: fileURL, options: .atomic)
        } else {
            try? Data(tail).write(to: fileURL, options: .atomic)
        }
    }
}

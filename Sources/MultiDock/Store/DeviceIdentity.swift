import Foundation
import IOKit
import SystemConfiguration

/// 这台 Mac 的身份（配置同步用，2026-10-26）。
///
/// - `id`：硬件 UUID（`IOPlatformUUID`），重装系统也不变，用作同步文件名；
///   读不到时退回本机配置目录里一份随机 ID（只生成一次）。
/// - `name`：人看的电脑名（系统设置 → 通用 → 关于本机 → 名称）。
struct DeviceIdentity: Equatable, Sendable {
    var id: String
    var name: String

    /// 真机身份。读 IOKit / SystemConfiguration，都不需要权限。
    static func current(fallbackIDFile: URL = AppPaths.supportDirectory.appendingPathComponent("device-id")) -> DeviceIdentity {
        DeviceIdentity(
            id: hardwareUUID() ?? fallbackID(file: fallbackIDFile),
            name: computerName()
        )
    }

    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )
        guard let value = property?.takeRetainedValue() as? String, !value.isEmpty else { return nil }
        return value
    }

    static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        return ProcessInfo.processInfo.hostName
    }

    private static func fallbackID(file: URL) -> String {
        if let data = try? Data(contentsOf: file),
           let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        let fresh = UUID().uuidString
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(fresh.utf8).write(to: file, options: .atomic)
        return fresh
    }
}

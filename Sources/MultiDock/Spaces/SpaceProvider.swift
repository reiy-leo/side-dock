import Foundation

/// 一个用户桌面（macOS 的 Space）。
///
/// 主键是 `spaceUUID`：P0 实测它跨重启稳定。多显示器时完整映射键为 `(displayUUID, spaceUUID)`。
struct DesktopSpace: Hashable, Sendable, Identifiable {
    let displayUUID: String
    let spaceUUID: String
    let id64: UInt64
    /// 0 = 用户桌面；4 = 全屏 App 空间；其他 = 系统空间。
    let type: Int
    /// 该显示器内用户桌面的序号，从 1 起。仅 `type == 0` 有值，用于显示「桌面 2」。
    let ordinal: Int

    var id: String { "\(displayUUID)#\(spaceUUID)" }

    var displayName: String { "桌面 \(ordinal)" }
}

/// 桌面枚举与切换的能力抽象。
///
/// 存在的意义：SkyLight 私有 API 失效时（系统升级、符号改名）能整体换成降级实现，
/// 而不是让 App 静默失效。见 `docs/PLAN.md` §3.1。
protocol SpaceProviding: Sendable {
    /// 私有 API 是否可用。false 时只能"手动改 Dock"，不能自动跟随与切换。
    var isAvailable: Bool { get }
    /// 不可用原因，用于 UI 报警。
    var unavailableReason: String? { get }

    /// 枚举所有显示器上的**用户桌面**（`type == 0`）。
    /// 非 0 的 space（全屏 App、系统空间）一律不返回：否则每次进全屏都会被当成切桌面。
    func userDesktops() -> [DesktopSpace]

    /// 当前活动空间的 id64。
    func activeSpaceID() -> UInt64

    /// 切换某显示器上的当前空间。返回是否成功发起。
    @discardableResult
    func setCurrentSpace(_ space: DesktopSpace) -> Bool
}

/// 基于 SkyLight 私有 API 的实现。
struct SkyLightSpaceProvider: SpaceProviding {
    let bridge: SkyLightBridge

    var isAvailable: Bool { true }
    var unavailableReason: String? { nil }

    func userDesktops() -> [DesktopSpace] {
        var result: [DesktopSpace] = []
        for display in bridge.managedDisplaySpaces() {
            let displayUUID = display["Display Identifier"] as? String ?? ""
            guard !displayUUID.isEmpty else { continue }
            let rawSpaces = display["Spaces"] as? [[String: Any]] ?? []
            // 序号只数用户桌面，且保持 Spaces 数组顺序（即左右顺序）。
            var ordinal = 0
            for raw in rawSpaces {
                guard let type = (raw["type"] as? NSNumber)?.intValue else { continue }
                guard type == 0 else { continue }
                guard
                    let uuid = raw["uuid"] as? String,
                    let id64 = (raw["id64"] as? NSNumber)?.uint64Value
                else { continue }
                ordinal += 1
                result.append(
                    DesktopSpace(
                        displayUUID: displayUUID,
                        spaceUUID: uuid,
                        id64: id64,
                        type: type,
                        ordinal: ordinal
                    )
                )
            }
        }
        return result
    }

    func activeSpaceID() -> UInt64 { bridge.activeSpaceID() }

    @discardableResult
    func setCurrentSpace(_ space: DesktopSpace) -> Bool {
        bridge.setCurrentSpace(displayUUID: space.displayUUID, spaceID: space.id64)
        return true
    }
}

/// 降级实现：私有 API 不可用时使用。
///
/// 枚举不出桌面、也切不了，但 App 仍能启动并把问题**显式**告诉用户，
/// 而不是静默失效（计划 §3.1 明确要求「在 UI 明确报警，而不是静默失效」）。
struct UnavailableSpaceProvider: SpaceProviding {
    let reason: String

    var isAvailable: Bool { false }
    var unavailableReason: String? { reason }

    func userDesktops() -> [DesktopSpace] { [] }
    func activeSpaceID() -> UInt64 { 0 }
    @discardableResult
    func setCurrentSpace(_ space: DesktopSpace) -> Bool { false }
}

enum SpaceProviderFactory {
    /// 优先用私有 API，失败则降级。
    static func make() -> any SpaceProviding {
        if let bridge = SkyLightBridge.shared {
            return SkyLightSpaceProvider(bridge: bridge)
        }
        let reason = SkyLightBridge.loadError ?? "未知原因"
        return UnavailableSpaceProvider(
            reason: "无法加载 SkyLight 私有 API（\(reason)）。桌面识别与切换不可用，只能手动改 Dock。"
        )
    }
}

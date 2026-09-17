import CoreGraphics
import Foundation

/// SkyLight 私有 API 的运行时桥。
///
/// 只负责「加载符号 + 原样转发调用」，不做任何策略判断（策略在 `SpaceProvider`）。
/// 一律 `dlopen` + `dlsym`，**不链接私有框架**：框架路径或符号名变化时只是加载失败，
/// 不会导致 App 启动即崩。
final class SkyLightBridge: @unchecked Sendable {

    typealias ConnectionID = UInt32
    typealias SpaceID = UInt64

    private typealias MainConnectionFn = @convention(c) () -> ConnectionID
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (ConnectionID) -> Unmanaged<CFArray>?
    private typealias GetActiveSpaceFn = @convention(c) (ConnectionID) -> SpaceID
    private typealias ManagedDisplaySetCurrentSpaceFn = @convention(c) (ConnectionID, CFString, SpaceID) -> Void

    /// 符号缺失时抛错，由调用方降级处理。
    enum LoadError: Error, CustomStringConvertible {
        case frameworkUnavailable(String)
        case missingSymbol(String)

        var description: String {
            switch self {
            case .frameworkUnavailable(let path): return "无法加载 \(path)"
            case .missingSymbol(let name): return "符号缺失：\(name)"
            }
        }
    }

    private static let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    private let mainConnectionFn: MainConnectionFn
    private let copyManagedDisplaySpacesFn: CopyManagedDisplaySpacesFn
    private let getActiveSpaceFn: GetActiveSpaceFn
    private let managedDisplaySetCurrentSpaceFn: ManagedDisplaySetCurrentSpaceFn

    private static let loadResult: Result<SkyLightBridge, Error> = Result { try SkyLightBridge() }

    /// 加载失败时为 nil —— 调用方据此进入降级模式。
    static var shared: SkyLightBridge? { try? loadResult.get() }

    /// 供降级提示使用：记录加载失败的具体原因。
    static var loadError: String? {
        if case .failure(let error) = loadResult { return String(describing: error) }
        return nil
    }

    init() throws {
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else {
            throw LoadError.frameworkUnavailable(Self.frameworkPath)
        }
        func load<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw LoadError.missingSymbol(name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        mainConnectionFn = try load("CGSMainConnectionID", as: MainConnectionFn.self)
        copyManagedDisplaySpacesFn = try load("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
        getActiveSpaceFn = try load("CGSGetActiveSpace", as: GetActiveSpaceFn.self)
        managedDisplaySetCurrentSpaceFn = try load("CGSManagedDisplaySetCurrentSpace", as: ManagedDisplaySetCurrentSpaceFn.self)
    }

    var connectionID: ConnectionID { mainConnectionFn() }

    /// 当前活动空间的 id64。这是唯一可靠的「现在在哪个桌面」来源：
    /// 实测程序化切桌面时 `NSWorkspaceActiveSpaceDidChangeNotification` 不会触发。
    func activeSpaceID() -> SpaceID {
        getActiveSpaceFn(connectionID)
    }

    /// 原始的空间字典树，每个元素对应一个显示器。
    /// 实测键为：`Display Identifier` / `Current Space` / `Spaces`，
    /// space 元素键为：`uuid` / `ManagedSpaceID` / `id64` / `type` / `WindowManagerInfo`。
    func managedDisplaySpaces() -> [[String: Any]] {
        guard let array = copyManagedDisplaySpacesFn(connectionID) else { return [] }
        return array.takeRetainedValue() as? [[String: Any]] ?? []
    }

    /// 主动切换某显示器上的当前空间。P0 实测可用，约 20 ms 生效，带系统动画。
    func setCurrentSpace(displayUUID: String, spaceID: SpaceID) {
        managedDisplaySetCurrentSpaceFn(connectionID, displayUUID as CFString, spaceID)
    }
}

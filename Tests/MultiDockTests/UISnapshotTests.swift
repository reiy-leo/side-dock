import AppKit
import SwiftUI
import XCTest
@testable import MultiDock

/// 离屏渲染设置窗口成 PNG —— 本机没有屏幕录制权限，`screencapture` 只能拍到壁纸
/// （AGENTS.md §4），所以 UI 的视觉验收用「自己窗口的 cacheDisplay」（零权限，
/// 与 `scripts/preview-toast.swift` 同一手法）。
///
/// 默认跳过：`MULTIDOCK_UI_SNAPSHOT=1` 才跑（会开 AppKit 窗口，普通单测不需要）。
/// 产物：`$(NSTemporaryDirectory)/multidock-ui-snapshot/*.png`，亮 / 暗各一套，
/// 路径会随测试日志打印出来。
@MainActor
final class UISnapshotTests: XCTestCase {

    func testSnapshotSettingsTabsInLightAndDark() throws {
        guard ProcessInfo.processInfo.environment["MULTIDOCK_UI_SNAPSHOT"] == "1" else {
            throw XCTSkip("需要 MULTIDOCK_UI_SNAPSHOT=1（生成 /tmp/multidock-ui-snapshot/*.png）")
        }

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-ui-snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let state = makeState()
        // 不走 start()（那会启动轮询与监视器）；手动把桌面列表与键可用性缓存填上。
        state.refreshDesktops()
        state.refreshDockCapabilities()
        seed(state)
        let tabModel = SettingsTabModel()
        // 用真的窗口装配（含隐藏 titlebar 的窗口样式），而不是测试里另拼一个 —— 否则验出来的不是真窗口。
        let window = SettingsWindowFactory.makeWindow(state: state, tabModel: tabModel)

        for appearance in [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua] {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            window.appearance = NSAppearance(named: appearance)

            for (tab, name) in [(SettingsTab.general, "general"), (SettingsTab.appBars, "app-bars"),
                                (SettingsTab.desktop, "desktop"), (SettingsTab.data, "data"),
                                (SettingsTab.about, "about")] {
                tabModel.tab = tab
                try capture(window, to: outDir.appendingPathComponent("settings-\(name)-\(suffix).png"))
            }
        }
        print("UI 快照 → \(outDir.path)")
    }

    /// 次级 Dock 条：与真窗口同一条装配路径（`SecondaryDockWindowFactory`），
    /// 摆放用与运行时同一套几何（底部 Dock、内缩 53），验图标条本身的视觉。
    func testSnapshotSecondaryDockInLightAndDark() throws {
        guard ProcessInfo.processInfo.environment["MULTIDOCK_UI_SNAPSHOT"] == "1" else {
            throw XCTSkip("需要 MULTIDOCK_UI_SNAPSHOT=1（生成 /tmp/multidock-ui-snapshot/*.png）")
        }

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-ui-snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var config = DockConfig()
        config.pinnedApps = DockStripRules.normalizedApps([
            DockStripRules.tile(forAppAt: "/System/Applications/Calculator.app"),
            DockStripRules.tile(forAppAt: "/System/Applications/Notes.app"),
            DockStripRules.tile(forAppAt: "/Applications/Safari.app"),
            DockStripRules.tile(forAppAt: "/System/Applications/Weather.app"),
        ].compactMap { $0 })
        let snapshot = try XCTUnwrap(
            SecondaryDockContentBuilder.snapshot(
                from: config,
                runningBundleIDs: ["com.apple.Safari"],
                iconSize: 36
            )
        )
        let face = DockFaceGeometry(
            orientation: .bottom,
            screen: CGRect(x: 0, y: 0, width: 1920, height: 1200),
            visible: CGRect(x: 0, y: 53, width: 1920, height: 1147)
        )
        let placement = SecondaryDockLayout.placement(
            barSize: SecondaryDockLayout.barSize(
                itemCount: snapshot.items.count,
                iconSize: snapshot.iconSize,
                isVertical: false
            ),
            face: face
        )
        let window = SecondaryDockWindowFactory.makeWindow(
            items: snapshot.items,
            isVertical: false,
            iconSize: snapshot.iconSize,
            frame: placement.revealed
        )

        for appearance in [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua] {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            window.appearance = NSAppearance(named: appearance)
            try capture(window, to: outDir.appendingPathComponent("secondary-dock-\(suffix).png"))
        }
        print("次级 Dock 快照 → \(outDir.path)")
    }
    // MARK: - 夹具

    /// 与 `AppStateDockTests` 同一套注入姿势：临时目录的存储 + 假 Provider + 测试专用日志。
    private func makeState() -> AppState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-snapshot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let displayUUID = "AB24BB32-C5EC-D10A-6F9D-F01F35552F60"
        let spaces = [
            DesktopSpace(
                displayUUID: displayUUID,
                spaceUUID: "1DAA5EC4-6F9D-4A24-BB32-SNAPSHOT000001",
                id64: 6, type: 0, ordinal: 1
            ),
            DesktopSpace(
                displayUUID: displayUUID,
                spaceUUID: "1DAA5EC4-6F9D-4A24-BB32-SNAPSHOT000002",
                id64: 7, type: 0, ordinal: 2
            ),
        ]
        let state = AppState(
            dockController: DockController(
                preferences: FakePreferences(domain: baseDomain()),
                reloader: DockReloader(
                    process: FakeDockProcess(),
                    timeout: .milliseconds(200),
                    pollInterval: .milliseconds(2),
                    fallbackGrace: .milliseconds(20),
                    minimumSpacing: .zero
                ),
                backup: {}
            ),
            configStore: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            baselineStore: BaselineStore(
                baselineURL: directory.appendingPathComponent("baseline.plist"),
                markerURL: directory.appendingPathComponent("session.state"),
                backupsURL: directory.appendingPathComponent("backups", isDirectory: true)
            ),
            provider: FakeSpaceProvider(desktops: spaces, activeSpaceID: 6),
            fileLog: makeTestFileLog(),
            recentAppsProvider: { limit in
                Array(Self.previewApps().prefix(limit))
            },
            environmentReader: { EnvironmentReading(stageManagerActive: false, dockSide: .bottom) }
        )
        // 冻结是产品默认值；快照按「未冻结」的设置页文案出图，别让横幅文案跟着默认值漂移。
        state.updateSettings { $0.freezeNativeDockSwitching = false }
        return state
    }

    private func baseDomain() -> [String: PlistValue] {
        [
            "orientation": .string("bottom"),
            "tilesize": .double(36),
            "magnification": .bool(true),
            "largesize": .double(98),
            "autohide": .bool(false),
            "mineffect": .string("scale"),
            "minimize-to-application": .bool(true),
            "persistent-apps": .array([]),
            "persistent-others": .array([]),
            "mru-spaces": .bool(true),
            "mod-count": .int(1),
        ]
    }

    /// 快照用的真实 App（有图标）。默认 Dock 与绑定栏都用它。
    private static func previewApps() -> [DockTile] {
        [
            DockStripRules.tile(forAppAt: "/System/Applications/Calculator.app"),
            DockStripRules.tile(forAppAt: "/System/Applications/Notes.app"),
            DockStripRules.tile(forAppAt: "/Applications/Safari.app"),
            DockStripRules.tile(forAppAt: "/System/Applications/Weather.app"),
        ].compactMap { $0 }
    }

    /// 让两个 Tab 都有内容可看：默认 Dock 是注入的最近应用（有真实图标）、
    /// 第一个桌面绑了一根 Dock 栏 + 自定义名，第二个桌面沿用默认。
    private func seed(_ state: AppState) {
        state.rebuildDefaultDock(reason: "快照预览")

        guard let first = state.desktops.first else { return }
        state.setCustomName("工作", for: first)
        state.updateSettings { $0.autoApplyOnEdit = false }
        let id = state.addDockBar()
        state.updateDockBarInMemory(DockBar(
            id: id,
            name: "工作栏",
            position: .bottom,
            spaceID: first.id,
            apps: DockStripRules.normalizedApps(Self.previewApps())
        ))
    }

    // MARK: - 离屏渲染

    /// 窗口不 orderFront（离屏），直接抓主题框视图 —— 零权限，含标题栏与工具栏。
    private func capture(_ window: NSWindow, to url: URL) throws {
        // @Observable 的失效要等一个 RunLoop 拍子才会重算 SwiftUI body —— 不等就会拍到旧页。
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
        guard let content = window.contentView else {
            XCTFail("窗口没有 contentView")
            return
        }
        content.layoutSubtreeIfNeeded()
        // cacheDisplay 只抓 contentView —— 标题栏与工具栏在它的 superview（主题框视图）里。
        // 私有层级只用于快照，拿不到就退回只拍内容区。
        let target = content.superview ?? content
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
            XCTFail("创建位图失败")
            return
        }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("PNG 编码失败")
            return
        }
        try data.write(to: url)
    }
}

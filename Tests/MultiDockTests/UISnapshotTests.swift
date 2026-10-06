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

            for (tab, name) in [(SettingsTab.general, "general"), (SettingsTab.menuBar, "menu-bar"),
                                (SettingsTab.appBars, "app-bars"), (SettingsTab.desktop, "desktop"),
                                (SettingsTab.launchpad, "launchpad"),
                                (SettingsTab.data, "data"), (SettingsTab.about, "about")] {
                tabModel.tab = tab
                try capture(window, to: outDir.appendingPathComponent("settings-\(name)-\(suffix).png"))
            }
        }
        print("UI 快照 → \(outDir.path)")
    }

    /// **英文界面快照**（2026-10-06 双语支持）：同一套夹具与装配，只把语言切成 en。
    /// 用途：核对英文文案在六页里有没有溢出/截断，并确认没有中文残留（人工逐张看）。
    func testSnapshotSettingsTabsInEnglish() throws {
        guard ProcessInfo.processInfo.environment["MULTIDOCK_UI_SNAPSHOT"] == "1" else {
            throw XCTSkip("需要 MULTIDOCK_UI_SNAPSHOT=1（生成 /tmp/multidock-ui-snapshot/*.png）")
        }

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-ui-snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 语言要在建 `AppState` **之前**切 —— 它的几个默认文案是存储属性，构造时求值。
        let previous = L10n.language
        defer { L10n.language = previous }
        L10n.language = .en

        let state = makeState()
        state.refreshDesktops()
        state.refreshDockCapabilities()
        seed(state)
        let tabModel = SettingsTabModel()
        let window = SettingsWindowFactory.makeWindow(state: state, tabModel: tabModel)

        for (tab, name) in [(SettingsTab.general, "general"), (SettingsTab.menuBar, "menu-bar"),
                            (SettingsTab.appBars, "app-bars"), (SettingsTab.desktop, "desktop"),
                            (SettingsTab.launchpad, "launchpad"),
                            (SettingsTab.data, "data"), (SettingsTab.about, "about")] {
            tabModel.tab = tab
            try capture(window, to: outDir.appendingPathComponent("settings-en-\(name).png"))
        }
        print("英文快照 → \(outDir.path)")
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
        config.pinnedApps = DockStripRules.barApps([
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

    /// 桌面名称面板（锁屏式大字 + 磨砂玻璃，2026-10-06 第 2 版）：
    /// 取最长名字（10 字素簇）——**重点验不出现省略号**，以及字重 800 的观感。
    ///
    /// ⚠️ 面板用 `.behindWindow` 混合（真机模糊屏幕内容），离屏抓图没有"身后"可模糊 ——
    /// 抓出来的底是透明的，文字与描边正常。因此它验的是**文字与面板几何**，不是玻璃质感
    /// （质感只能在真机看）。
    func testSnapshotDesktopNamePanel() throws {
        guard ProcessInfo.processInfo.environment["MULTIDOCK_UI_SNAPSHOT"] == "1" else {
            throw XCTSkip("需要 MULTIDOCK_UI_SNAPSHOT=1（生成 /tmp/multidock-ui-snapshot/*.png）")
        }

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-ui-snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 最长（10 字素簇）+ 短名各出一张：前者是"会不会被截"的关键用例。
        let cases: [(text: String, name: String)] = [
            ("一二三四五六七八九十", "desktop-name-long"),
            ("工作", "desktop-name-short"),
        ]
        let presenter = DesktopNameOverlayWindow(placementProvider: { .top })
        let window = presenter.snapshotWindow

        for appearance in [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua] {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            window.appearance = NSAppearance(named: appearance)
            for entry in cases {
                presenter.show(text: entry.text, displayUUID: nil)
                try capture(window, to: outDir.appendingPathComponent("\(entry.name)-\(suffix).png"))
            }
        }
        presenter.hide()
        print("名称面板快照 → \(outDir.path)")
    }

    /// **三种展示背景效果**（2026-10-06 用户规格：默认 / 流动霓虹 / 赛博紫韵；
    /// 同日用户澄清：效果修饰**背景**，文字始终是同一个 label）。
    /// 每个效果 × 亮/暗外观各一张；霓虹档用 `apply`（不 order front）抓同一渲染路径。
    ///
    /// 相位刻意固定在中段（0.45）——`show()` 的动画会实时推进相位，抓图时点不同画面就不同，
    /// 快照不再确定；这里要验的是背景配方与文字可读性，不是动画帧。
    func testSnapshotDesktopNameEffects() throws {
        guard ProcessInfo.processInfo.environment["MULTIDOCK_UI_SNAPSHOT"] == "1" else {
            throw XCTSkip("需要 MULTIDOCK_UI_SNAPSHOT=1（生成 /tmp/multidock-ui-snapshot/*.png）")
        }

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("multidock-ui-snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let cases: [(effect: DesktopNameEffect, name: String)] = [
            (.standard, "desktop-effect-standard"),
            (.neonFlow, "desktop-effect-neon"),
            (.cyberPurple, "desktop-effect-cyber"),
        ]

        for appearance in [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua] {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            for entry in cases {
                // 每个用例一口新窗口：避免上一档的计时器/相位影响这一档的抓图。
                let presenter = DesktopNameOverlayWindow(placementProvider: { .top })
                presenter.snapshotWindow.appearance = NSAppearance(named: appearance)
                presenter.apply(DesktopNameOverlayWindow.presentation(
                    text: "工作环境",
                    available: screen,
                    placement: .top,
                    effect: entry.effect
                ))
                if entry.effect.spec != nil {
                    // 停在循环中段：文字上渐变两色分明（起点/终点同色，不便于看配色）。
                    presenter.snapshotCanvas.phase = 0.45
                    presenter.snapshotCanvas.stopAnimating()
                    presenter.snapshotCanvas.display()
                }
                try capture(presenter.snapshotWindow, to: outDir.appendingPathComponent("\(entry.name)-\(suffix).png"))
                presenter.hide()
            }
        }
        print("名称效果快照 → \(outDir.path)")
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
            // 启动台读的是**固定夹具**而不是真机数据库：快照要确定、可复现，
            // 也不该因为用户改了自己的启动台而变。
            launchpadLoader: makeFakeLaunchpadLoader(folders: Self.launchpadFixtures()),
            environmentReader: { EnvironmentReading(stageManagerActive: false, dockSide: .bottom) }
        )
        return state
    }

    /// 启动台页的快照夹具：两三个文件夹、真实系统 App 的图标（含一个定位不到的占位）。
    private static func launchpadFixtures() -> [LaunchpadFolder] {
        let calculator = DockStripRules.tile(forAppAt: "/System/Applications/Calculator.app")
        let notes = DockStripRules.tile(forAppAt: "/System/Applications/Notes.app")
        let safari = DockStripRules.tile(forAppAt: "/Applications/Safari.app")
        let weather = DockStripRules.tile(forAppAt: "/System/Applications/Weather.app")
        let music = DockStripRules.tile(forAppAt: "/System/Applications/Music.app")
        return [
            makeLaunchpadFolder(itemID: 1, name: "实用工具", apps: [
                ("计算器", calculator), ("备忘录", notes), ("天气", weather),
            ]),
            makeLaunchpadFolder(itemID: 2, name: "网络", apps: [
                ("Safari浏览器", safari), ("音乐", music),
            ]),
            makeLaunchpadFolder(itemID: 3, name: "", apps: [
                ("定位不到的例子", nil),
            ]),
        ]
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

    /// 让两个 Tab 都有内容可看：第一个桌面绑一根 Dock 栏（真实图标）+ 自定义名，
    /// 第二个桌面不绑（应用栏页显示两种行态）；另加一根**未绑定**的空栏。
    private func seed(_ state: AppState) {
        guard let first = state.desktops.first else { return }
        state.setCustomName("工作", for: first)
        state.updateSettings { $0.autoApplyOnEdit = false }
        let id = state.addDockBar()
        state.updateDockBarInMemory(DockBar(
            id: id,
            // 名字取满 10 字素簇：每次快照都在最坏长度下核对栏名输入框不出现省略号
            // （2026-10-06 用户规格：输入框宽 = 10 个中文字宽；守卫 `NameFieldTests`）。
            name: "工作空间备份归档整理",
            position: .bottom,
            spaceID: first.id,
            apps: DockStripRules.barApps(Self.previewApps())
        ))
        state.addDockBar()
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

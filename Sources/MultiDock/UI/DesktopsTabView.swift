import SwiftUI

/// 桌面 Tab（2026-10-06 用户规格：只管桌面本身——**命名** + **名称展示**；
/// Dock 栏的编辑拆去「应用栏」页）。
///
/// - 「桌面名称」：每个桌面一行（当前桌面带活动标记 + 壁纸缩略图 + 输入框），
///   最长 10 个字符（字素簇），仅存本地——macOS 没有系统接口。
/// - 「名称展示」：开关 + 位置（顶部/中部/底部）+ 背景效果（默认 / 流动霓虹 / 赛博紫韵）。
///   默认档 = 磨砂玻璃面板；霓虹两档由 `DesktopNameEffectCanvas` 自绘**背景**
///   （暗底 + 流动光带 + 霓虹描边，只在展示的那 1 秒里播动画）——文字始终是同一个 label。
///   切换桌面后展示 1 秒，实现在 `DesktopNameOverlayWindow`。
struct DesktopsTab: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section(L("桌面名称", "Desktop Names")) {
                if state.desktops.isEmpty {
                    Text(state.spaceProviderAvailable
                         ? L("未识别到桌面", "No desktops detected")
                         : L("桌面功能不可用", "Desktop features unavailable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.desktops) { space in
                        desktopNameRow(space)
                    }
                }
                HStack {
                    Button(L("刷新桌面列表", "Refresh Desktop List")) { state.refreshDesktops() }
                    Text(L("列表自动每 300 ms 刷新 · 名字最长 \(DesktopNaming.maxLength) 个字符（超出即截断），切换到该桌面时展示",
                           "The list refreshes every 300 ms · names are at most \(DesktopNaming.maxLength) characters (truncated), shown when switching to that desktop"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L("名称展示", "Name Display")) {
                Toggle(L("切换桌面时显示桌面名称", "Show Desktop Name When Switching"), isOn: toastBinding)
                Picker(L("显示位置", "Position"), selection: placementBinding) {
                    ForEach(DesktopNamePlacement.allCases, id: \.self) { placement in
                        Text(placement.displayName).tag(placement)
                    }
                }
                .pickerStyle(.segmented)
                Picker(L("显示效果", "Effect"), selection: effectBinding) {
                    ForEach(DesktopNameEffect.allCases, id: \.self) { effect in
                        Text(effect.displayName).tag(effect)
                    }
                }
                .pickerStyle(.segmented)
                Text(L("效果修饰的是面板背景（文字不变）：「默认」为磨砂玻璃；「流动霓虹」在深色底上扫过青/品红双色光带、带霓虹描边；「赛博紫韵」在深紫底上慢扫紫色光带、光晕呼吸。两个效果档只在展示的那 1 秒里播动画。1 秒后自动消失，不抢焦点、不挡点击；「顶部」即锁屏时钟的位置。",
                       "The effect styles the panel background (the text is unchanged): “Default” is frosted glass; “Flowing Neon” sweeps cyan/magenta bands over a dark base with a neon border; “Cyber Purple” drifts purple bands over a deep-purple base with a breathing glow. Both animate only during the one-second display. It disappears after a second, never steals focus or blocks clicks; “Top” matches the lock-screen clock position."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// 一行 = 缩略图 + 桌面名 + 名称输入框，**单行对齐**（2026-10-06 用户规格：
    /// 去掉行首的"当前桌面"圆点指示、名称与标签同行）。
    ///
    /// 不用 `LabeledContent`：它把标签与控件分列两侧、各按自身高度居中，输入框比文字高，
    /// 视觉上会错开半行。这里显式 `HStack` 保证三者同一基线排布。
    private func desktopNameRow(_ space: DesktopSpace) -> some View {
        HStack(spacing: 8) {
            SpaceThumbnailView(spaceID: space.id, width: 24, height: 15)
            Text(L("桌面 \(space.ordinal)", "Desktop \(space.ordinal)"))
            Spacer(minLength: 12)
            NameField(
                value: state.customName(for: space) ?? "",
                placeholder: L("名称", "Name"),
                width: 200,
                onCommit: { raw in
                    state.setCustomName(raw, for: space)
                    return state.customName(for: space) ?? ""
                }
            )
            // representable 默认吃满可用宽度，这里钉回固定尺寸。
            .fixedSize()
        }
    }

    // MARK: - 绑定

    private var toastBinding: Binding<Bool> {
        Binding(
            get: { state.settings.showToastOnDesktopSwitch },
            set: { value in
                state.updateSettings { $0.showToastOnDesktopSwitch = value }
                if !value { state.toastPresenter?.dismissNow() }
            }
        )
    }

    private var placementBinding: Binding<DesktopNamePlacement> {
        Binding(
            get: { state.settings.desktopNamePlacement },
            set: { value in state.updateSettings { $0.desktopNamePlacement = value } }
        )
    }

    /// 切效果立即生效：窗口每次展示都从 provider 实时读，改完下一次切换桌面就看到。
    private var effectBinding: Binding<DesktopNameEffect> {
        Binding(
            get: { state.settings.desktopNameEffect },
            set: { value in state.updateSettings { $0.desktopNameEffect = value } }
        )
    }
}

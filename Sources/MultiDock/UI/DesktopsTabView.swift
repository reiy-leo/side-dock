import SwiftUI

/// 桌面 Tab（2026-10-06 用户规格：只管桌面本身——**命名** + **名称展示**；
/// Dock 栏的编辑拆去「应用栏」页）。
///
/// - 「桌面名称」：每个桌面一行（当前桌面带活动标记 + 壁纸缩略图 + 输入框），
///   最长 10 个字符（字素簇），仅存本地——macOS 没有系统接口。
/// - 「名称展示」：开关 + 位置（顶部/中部/底部）。样式对标 iPhone 锁屏时钟
///   （大号极细白字压壁纸 + 柔和投影），切换桌面后展示 1 秒，
///   实现在 `DesktopNameOverlayWindow`。
struct DesktopsTab: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("桌面名称") {
                if state.desktops.isEmpty {
                    Text(state.spaceProviderAvailable ? "未识别到桌面" : "桌面功能不可用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.desktops) { space in
                        desktopNameRow(space)
                    }
                }
                HStack {
                    Button("刷新桌面列表") { state.refreshDesktops() }
                    Text("列表自动每 300 ms 刷新 · 名字最长 \(DesktopNaming.maxLength) 个字符（超出即截断），切换到该桌面时展示")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("名称展示") {
                Toggle("切换桌面时显示桌面名称", isOn: toastBinding)
                Picker("显示位置", selection: placementBinding) {
                    ForEach(DesktopNamePlacement.allCases, id: \.self) { placement in
                        Text(placement.displayName).tag(placement)
                    }
                }
                .pickerStyle(.segmented)
                Text("样式对标 iPhone 锁屏时钟：大号极细白字压在壁纸上，1 秒后自动消失。不抢焦点、不挡点击；「顶部」即锁屏时钟的位置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func desktopNameRow(_ space: DesktopSpace) -> some View {
        let isActive = space.id == state.activeSpace?.id
        return LabeledContent {
            NameField(
                value: state.customName(for: space) ?? "",
                placeholder: "名称",
                width: 200,
                onCommit: { raw in
                    state.setCustomName(raw, for: space)
                    return state.customName(for: space) ?? ""
                }
            )
            // representable 默认吃满可用宽度，这里钉回固定尺寸。
            .fixedSize()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .help(isActive ? "当前桌面" : "")
                SpaceThumbnailView(spaceID: space.id, width: 24, height: 15)
                Text("桌面 \(space.ordinal)")
            }
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
}

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

    /// 桌面命名草稿。**不直接绑到模型**：中文输入法组字期间改写绑定值会打断候选词。
    @State private var desktopNameDrafts: [String: String] = [:]
    @FocusState private var focusedDesktop: String?

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
                    Text("列表自动每 300 ms 刷新 · 名字最长 \(DesktopNaming.maxLength) 个字符，切换到该桌面时展示")
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
        .onAppear {
            syncDrafts()
        }
        .onChange(of: state.desktopListGeneration) {
            syncDrafts()
        }
        .onChange(of: focusedDesktop) { previous, _ in
            // 失焦即提交，避免用户改完直接点别处导致改动丢失。
            guard let previous, let space = state.desktops.first(where: { $0.id == previous }) else { return }
            commitDesktopName(space)
        }
    }

    private func desktopNameRow(_ space: DesktopSpace) -> some View {
        let draft = desktopNameDrafts[space.id] ?? state.customName(for: space) ?? ""
        let isActive = space.id == state.activeSpace?.id
        return LabeledContent {
            HStack(spacing: 6) {
                // ⚠️ 分组 Form 会把 TextField 的**标题**提升成行首加粗标签——标题走
                // `prompt:` 留在框内，不生成行标签。
                TextField("", text: desktopNameDraftBinding(for: space), prompt: Text("名称"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .focused($focusedDesktop, equals: space.id)
                    .onSubmit { commitDesktopName(space) }
                Text("\(draft.count)/\(DesktopNaming.maxLength)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(draft.count > DesktopNaming.maxLength ? Color.orange : Color.secondary)
            }
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

    // MARK: - 草稿与提交

    private func desktopNameDraftBinding(for space: DesktopSpace) -> Binding<String> {
        Binding(
            get: { desktopNameDrafts[space.id] ?? state.customName(for: space) ?? "" },
            set: { desktopNameDrafts[space.id] = $0 }
        )
    }

    /// 提交桌面名：归一化（去空白、截断到 10）并落盘，草稿对齐成归一化后的结果。
    private func commitDesktopName(_ space: DesktopSpace) {
        let raw = desktopNameDrafts[space.id] ?? state.customName(for: space) ?? ""
        state.setCustomName(raw, for: space)
        desktopNameDrafts[space.id] = state.customName(for: space) ?? ""
    }

    private func syncDrafts() {
        var desktops: [String: String] = [:]
        for space in state.desktops {
            desktops[space.id] = state.customName(for: space) ?? ""
        }
        desktopNameDrafts = desktops
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

import SwiftUI

/// 桌面 Tab：列出所有桌面，并给每个桌面配一套独立的 Dock（`docs/PLAN.md` §3.7）。
///
/// 左侧列表 + 右侧详情。每个桌面只有两种状态：
/// - **沿用默认 Dock**（没有 override）→ 详情页只给一个「复制默认 Dock 到本桌面」。
/// - **独立 Dock**（有 override）→ 详情页给出完整的图标条 + 外观控件。
///
/// 「位置」在这里的含义与「通用」页完全一致：**Dock 贴在屏幕哪一边 + 图标大小**（用户已确认）。
struct DesktopListView: View {
    @Bindable var state: AppState

    @State private var selection: String?
    /// 改名草稿。**不直接绑到模型**：中文输入法组字期间改写绑定值会打断候选词。
    @State private var drafts: [String: String] = [:]
    @FocusState private var focused: String?
    @State private var confirmingPrune = false

    private var selectedSpace: DesktopSpace? {
        state.desktops.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)
            detail
                .frame(minWidth: 340)
        }
        .onAppear {
            syncDrafts()
            if selection == nil { selection = state.activeSpace?.id ?? state.desktops.first?.id }
        }
        .onChange(of: state.desktopListGeneration) {
            syncDrafts()
            if let selection, !state.desktops.contains(where: { $0.id == selection }) {
                self.selection = state.desktops.first?.id
            }
        }
        .onChange(of: focused) { previous, _ in
            // 失焦即提交，避免用户改完直接切走导致改动丢失。
            guard let previous, let space = state.desktops.first(where: { $0.id == previous }) else { return }
            commitName(space)
        }
    }

    // MARK: - 左：桌面列表

    /// 桌面列表按显示器分组用的数据。计划 §3.7 要求列表里带**显示器名** ——
    /// 多显示器时用户必须能一眼看出哪个桌面在哪台屏上（映射键是 `(displayUUID, spaceUUID)`）。
    private struct DisplayGroup: Identifiable {
        let id: String
        let name: String
        let spaces: [DesktopSpace]
    }

    /// 按 `displayUUID` 分组，保持桌面原有顺序（与 `NSScreen.screens` 同序，主屏在最前）。
    private var displayGroups: [DisplayGroup] {
        var order: [String] = []
        var bucket: [String: [DesktopSpace]] = [:]
        for space in state.desktops {
            if bucket[space.displayUUID] == nil { order.append(space.displayUUID) }
            bucket[space.displayUUID, default: []].append(space)
        }
        return order.map {
            DisplayGroup(id: $0, name: state.screenName(for: $0), spaces: bucket[$0] ?? [])
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                if state.desktops.isEmpty {
                    Section("显示器上的用户桌面") {
                        Text(state.spaceProviderAvailable ? "未识别到桌面" : "桌面功能不可用")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(displayGroups) { group in
                        Section(group.name) {
                            ForEach(group.spaces) { space in
                                desktopRow(space).tag(space.id)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button("刷新桌面列表") { state.refreshDesktops() }
                Spacer()
                Text("自动每 300 ms 刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)

            orphanBanner
        }
    }

    /// 桌面被系统删掉、或外接显示器被拔走后，绑定会变成孤儿。
    /// **只提示不自动删** —— 显示器插回来那些绑定还要用。
    @ViewBuilder
    private var orphanBanner: some View {
        if !state.orphanedBindings.isEmpty {
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("有 \(state.orphanedBindings.count) 条绑定对应的桌面已不存在")
                        .font(.caption)
                    Text("可能是桌面被删了，也可能是外接显示器被拔走。后者插回来还要用，所以不会自动删。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("清理") { confirmingPrune = true }
                    .help("只在确认这些桌面不会再回来时才清理。")
            }
            .padding(10)
            .alert("清理 \(state.orphanedBindings.count) 条无效绑定？", isPresented: $confirmingPrune) {
                Button("清理", role: .destructive) { state.pruneOrphanedBindings() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("这些绑定对应的桌面当前不存在。如果是因为外接显示器被拔走，插回来后需要重新配置。")
            }
        }
    }

    private func desktopRow(_ space: DesktopSpace) -> some View {
        let draft = drafts[space.id] ?? ""
        let isActive = space.id == state.activeSpace?.id
        return HStack(spacing: 6) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                TextField("桌面 \(space.ordinal)", text: draftBinding(for: space))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: space.id)
                    .onSubmit { commitName(space) }
                HStack(spacing: 4) {
                    Text("\(draft.count)/\(DesktopNaming.maxLength)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(draft.count > DesktopNaming.maxLength ? Color.orange : Color.secondary)
                    Text(state.hasOverride(for: space) ? "独立 Dock" : "沿用默认")
                        .font(.caption2)
                        .foregroundStyle(state.hasOverride(for: space) ? Color.accentColor : Color.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func draftBinding(for space: DesktopSpace) -> Binding<String> {
        Binding(
            get: { drafts[space.id] ?? state.customName(for: space) ?? "" },
            set: { drafts[space.id] = $0 }
        )
    }

    /// 提交改名：归一化（去空白、截断到 10）并落盘，然后把草稿对齐成归一化后的结果。
    private func commitName(_ space: DesktopSpace) {
        let raw = drafts[space.id] ?? state.customName(for: space) ?? ""
        state.setCustomName(raw, for: space)
        drafts[space.id] = state.customName(for: space) ?? ""
    }

    private func syncDrafts() {
        var next: [String: String] = [:]
        for space in state.desktops {
            next[space.id] = state.customName(for: space) ?? ""
        }
        drafts = next
    }

    // MARK: - 右：选中桌面的 Dock

    @ViewBuilder
    private var detail: some View {
        if let space = selectedSpace {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(space)
                    Divider()
                    inheritToggle(space)
                    if state.hasOverride(for: space) {
                        overrideEditor(space)
                    } else {
                        inheritHint
                    }
                }
                .padding(14)
            }
        } else {
            VStack {
                Spacer()
                Text(state.desktops.isEmpty ? "还没有识别到桌面" : "在左边选一个桌面")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ space: DesktopSpace) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(state.displayName(for: space))
                    .font(.headline)
                if space.id == state.activeSpace?.id {
                    Text("当前")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
            }
            Text("显示器：\(state.screenName(for: space.displayUUID))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("displayUUID：\(space.displayUUID)")
            Text(space.spaceUUID)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("id64 = \(space.id64)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func inheritToggle(_ space: DesktopSpace) -> some View {
        Toggle("沿用默认 Dock", isOn: inheritBinding(for: space))
            .help("打开后这个桌面用「通用」页里的默认 Dock；关掉就能给它单独配一套。")
    }

    private var inheritHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这个桌面目前使用「通用」页的默认 Dock，切到它时不会重启 Dock。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("复制默认 Dock 到本桌面") {
                    guard let space = selectedSpace else { return }
                    state.copyDefaultToOverride(for: space)
                }
                .disabled(state.settings.defaultDock.pinnedApps.isEmpty)
                if state.settings.defaultDock.pinnedApps.isEmpty {
                    Text("默认 Dock 还是空的，先到「通用」页点「从当前 Dock 抓取」。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func overrideEditor(_ space: DesktopSpace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("这个桌面的图标条").font(.subheadline.weight(.medium))
                DockStripEditor(
                    config: configBinding(for: space),
                    availableKeys: state.availableWhitelistedKeys,
                    captureLive: { state.captureLiveDockConfig() }
                ) { reason in
                    state.dockEdited(.desktop(space), reason: reason)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("这个桌面的外观").font(.subheadline.weight(.medium))
                DockAppearanceEditor(
                    appearance: appearanceBinding(for: space),
                    unavailableKeys: state.unavailableAppearanceKeys
                ) { reason in
                    state.dockEdited(.desktop(space), reason: reason)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("立即应用") { state.applyConfigForDesktop(space, reason: "手动应用 \(state.displayName(for: space)) 的 Dock") }
                Button("从当前真实 Dock 抓取") {
                    guard let live = state.captureLiveDockConfig() else { return }
                    state.setOverride(live, for: space, reason: "从当前真实 Dock 抓取")
                }
                Button("重置为默认") {
                    state.setOverride(nil, for: space, reason: "重置为沿用默认 Dock")
                }
                Button("撤销自动回存") { state.undoLastAutoCapture() }
                    .disabled(!state.canUndoAutoCapture())
                    .help("撤销上一次「识别到你在真实 Dock 上的改动并回存」的覆盖（回存只落在当前活动桌面上）。")
            }
            Text("切到这个桌面时会自动应用这套 Dock。与默认一致时会被指纹短路，不会重启 Dock。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 绑定

    private func inheritBinding(for space: DesktopSpace) -> Binding<Bool> {
        Binding(
            get: { !state.hasOverride(for: space) },
            set: { inherit in
                if inherit {
                    state.setOverride(nil, for: space, reason: "改为沿用默认 Dock")
                } else {
                    state.copyDefaultToOverride(for: space)
                }
            }
        )
    }

    /// 编辑器用的绑定：只改内存（拖拽过程中会连续触发），落盘由 `dockEdited` 做一次。
    private func configBinding(for space: DesktopSpace) -> Binding<DockConfig> {
        Binding(
            get: { state.dockConfig(for: .desktop(space)) },
            set: { state.setDockConfigInMemory($0, for: .desktop(space)) }
        )
    }

    /// 外观同理：滑杆只在松手时由 `DockAppearanceEditor` 提交。
    private func appearanceBinding(for space: DesktopSpace) -> Binding<DockAppearance> {
        Binding(
            get: { state.dockAppearance(for: .desktop(space)) },
            set: { state.setDockAppearanceInMemory($0, for: .desktop(space)) }
        )
    }
}

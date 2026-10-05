import SwiftUI

/// 桌面 Tab：**Dock 栏列表**（2026-10-05 用户规格重写）。
///
/// 模型：栏是主实体 —— 每根栏有名字、屏幕位置（底部/左/右，台前调度占用的一侧自动避开）、
/// 绑定的桌面（下拉，带缩略图）与图标（1...15）。一个桌面同时只挂一根栏。
/// 没绑栏的桌面在冻结模式下只有原生 Dock（默认 Dock = 最近添加的应用）可看。
///
/// 编辑器永远**横向**显示（不管栏在屏幕上是横是竖）；默认露出 8 个槽位，超出走滚动。
/// 桌面命名（切换提示 toast 用）保留在本页底部 —— 命名是桌面的属性，不是栏的。
struct DesktopListView: View {
    @Bindable var state: AppState

    @State private var selection: UUID?
    /// 栏名草稿。**不直接绑到模型**：中文输入法组字期间改写绑定值会打断候选词。
    @State private var barNameDrafts: [UUID: String] = [:]
    /// 桌面命名草稿（同上）。
    @State private var desktopNameDrafts: [String: String] = [:]
    @FocusState private var focusedBar: UUID?
    @FocusState private var focusedDesktop: String?
    @State private var confirmingUnbind = false

    private var selectedBar: DockBar? {
        state.dockBars.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            barList
            Divider()
            editor
            Divider()
            desktopNamesSection
        }
        .onAppear {
            syncDrafts()
            // 打开就选中第一根栏：编辑器不用等一次点击才出现，中部也不留大片空白。
            if selection == nil {
                selection = state.dockBars.first?.id
            }
        }
        .onChange(of: state.desktopListGeneration) {
            syncDrafts()
        }
        .onChange(of: focusedBar) { previous, _ in
            // 失焦即提交，避免用户改完直接点别处导致改动丢失。
            guard let previous else { return }
            commitBarName(previous)
        }
        .onChange(of: focusedDesktop) { previous, _ in
            guard let previous, let space = state.desktops.first(where: { $0.id == previous }) else { return }
            commitDesktopName(space)
        }
    }

    // MARK: - Dock 栏列表

    private var barList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Dock 栏（\(state.dockBars.count)）") {
                    ForEach(state.dockBars) { bar in
                        barRow(bar).tag(bar.id)
                    }
                }
            }
            .listStyle(.inset)
            .overlay(alignment: .bottom) {
                if state.dockBars.isEmpty {
                    Text("还没有 Dock 栏，点下面「添加 Dock 栏」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
            }

            HStack {
                Button("添加 Dock 栏") {
                    selection = state.addDockBar()
                    syncDrafts()
                }
                Spacer()
                Text("一个桌面只挂一根栏；绑定时另一根会自动让出")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            orphanBanner
        }
    }

    private func barRow(_ bar: DockBar) -> some View {
        let draft = barNameDrafts[bar.id] ?? bar.name
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("名称", text: barNameDraftBinding(for: bar))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedBar, equals: bar.id)
                    .onSubmit { commitBarName(bar.id) }
                Text("\(draft.count)/\(DesktopNaming.maxLength)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(draft.count > DesktopNaming.maxLength ? Color.orange : Color.secondary)
            }
            .frame(width: 110, alignment: .leading)

            Spacer(minLength: 2)

            desktopPicker(bar)
            positionPicker(bar)

            Button {
                state.removeDockBar(id: bar.id)
                if selection == bar.id { selection = nil }
                syncDrafts()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("删除这根 Dock 栏")
        }
        .padding(.vertical, 2)
    }

    /// 桌面下拉：当前绑定以「缩略图 + 文本」常显，菜单行是纯文本（桌面名 · 显示器名）。
    ///
    /// ⚠️ 缩略图**不能塞进 Picker 的行视图**：SwiftUI 的 menu Picker 会把自定义行标签
    /// 渲染成一块高亮色（实测），关闭态什么都看不出来 —— 所以缩略图放在控件外面。
    private func desktopPicker(_ bar: DockBar) -> some View {
        HStack(spacing: 6) {
            Group {
                if let spaceID = bar.spaceID {
                    SpaceThumbnailView(spaceID: spaceID, width: 24, height: 15)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
                        .foregroundStyle(Color(nsColor: .separatorColor))
                        .frame(width: 24, height: 15)
                }
            }
            Picker("桌面", selection: desktopBinding(for: bar)) {
                Text("未绑定").tag(String?.none)
                ForEach(state.desktops) { space in
                    Text("\(state.displayName(for: space)) · \(state.screenName(for: space.displayUUID))")
                        .tag(String?.some(space.id))
                }
            }
            .frame(width: 176)
        }
        .help("这根栏显示在哪个桌面上。缩略图是空间的壁纸（本机各空间共用系统壁纸时显示同一张）。")
    }

    /// 位置分段按钮。台前调度开着时左不在选项里（其窗口条占屏幕左缘）；
    /// 已经存成左的栏仍会把当前值显示出来（可以改走，改回来不行）。
    private func positionPicker(_ bar: DockBar) -> some View {
        Picker("位置", selection: positionBinding(for: bar)) {
            ForEach(positionOptions(for: bar), id: \.self) { position in
                Text(position.displayName).tag(position)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 150)
        .help("栏贴在哪条屏幕边。台前调度开启时自动避开左侧。")
    }

    private func positionOptions(for bar: DockBar) -> [DockBarPosition] {
        var options = state.availableBarPositions
        if !options.contains(bar.position) {
            options.insert(bar.position, at: 0)
        }
        return options
    }

    // MARK: - 选中栏的编辑器

    @ViewBuilder
    private var editor: some View {
        if let bar = selectedBar {
            let boundSpace = bar.spaceID.flatMap { id in state.desktops.first { $0.id == id } }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("「\(bar.name)」的图标")
                        .font(.headline)
                    if let boundSpace {
                        Text("显示在 \(state.displayName(for: boundSpace))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if state.orphanedBars.contains(where: { $0.id == bar.id }) {
                        Label("绑定的桌面已不存在", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
                DockBarEditor(
                    bar: barBinding(for: bar),
                    onCommit: { state.dockBarEdited($0, reason: $1) }
                )
                Text("从访达拖 .app 进来，或点「＋」选择；拖动排序，右键或拖到垃圾桶移除。每根栏 1–\(DockBar.maxApps) 个图标，编辑器里超过 8 个走横向滚动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
        } else {
            Text("在上方选一根 Dock 栏编辑它的图标")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(14)
        }
    }

    /// 孤儿栏提示：绑定的桌面被系统删了 / 显示器被拔了。**只解绑不删栏**（应用要保留）。
    @ViewBuilder
    private var orphanBanner: some View {
        if !state.orphanedBars.isEmpty {
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("有 \(state.orphanedBars.count) 根栏绑定的桌面已不存在")
                        .font(.caption)
                    Text("可能是桌面被删了，也可能是外接显示器被拔走。插回来还能继续用，所以不会自动动它们。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("解绑") { confirmingUnbind = true }
            }
            .padding(10)
            .alert("解绑 \(state.orphanedBars.count) 根失效栏的桌面绑定？", isPresented: $confirmingUnbind) {
                Button("解绑", role: .destructive) { state.unbindOrphanedBars() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只解除绑定，栏的名字、位置与图标都保留。")
            }
        }
    }

    // MARK: - 桌面命名（toast 用）

    private var desktopNamesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("桌面名称（切换提示用）")
                    .font(.headline)
                Spacer()
                Button("刷新桌面列表") { state.refreshDesktops() }
                    .controlSize(.small)
                Text("自动每 300 ms 刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            if state.desktops.isEmpty {
                Text(state.spaceProviderAvailable ? "未识别到桌面" : "桌面功能不可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(state.desktops) { space in
                            desktopNameRow(space)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 110)
            }
        }
    }

    private func desktopNameRow(_ space: DesktopSpace) -> some View {
        let draft = desktopNameDrafts[space.id] ?? state.customName(for: space) ?? ""
        let isActive = space.id == state.activeSpace?.id
        return HStack(spacing: 6) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .help(isActive ? "当前桌面" : "")
            SpaceThumbnailView(spaceID: space.id, width: 24, height: 15)
            TextField("桌面 \(space.ordinal)", text: desktopNameDraftBinding(for: space))
                .textFieldStyle(.roundedBorder)
                .focused($focusedDesktop, equals: space.id)
                .onSubmit { commitDesktopName(space) }
            Text("\(draft.count)/\(DesktopNaming.maxLength)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(draft.count > DesktopNaming.maxLength ? Color.orange : Color.secondary)
            Text(state.dockBar(for: space)?.name ?? "未绑定栏")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }

    // MARK: - 草稿与提交

    private func barNameDraftBinding(for bar: DockBar) -> Binding<String> {
        Binding(
            get: { barNameDrafts[bar.id] ?? bar.name },
            set: { barNameDrafts[bar.id] = $0 }
        )
    }

    /// 提交栏名：归一化（≤10 字素簇）并落盘，草稿对齐成归一化后的结果。
    private func commitBarName(_ id: UUID) {
        guard let bar = state.dockBar(id: id) else { return }
        let raw = barNameDrafts[id] ?? bar.name
        state.renameDockBar(id, to: raw)
        barNameDrafts[id] = state.dockBar(id: id)?.name ?? ""
    }

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
        var bars: [UUID: String] = [:]
        for bar in state.dockBars {
            bars[bar.id] = bar.name
        }
        barNameDrafts = bars

        var desktops: [String: String] = [:]
        for space in state.desktops {
            desktops[space.id] = state.customName(for: space) ?? ""
        }
        desktopNameDrafts = desktops
    }

    // MARK: - 绑定

    /// 编辑器用的栏绑定：只改内存（拖拽过程中会连续触发），落盘由 `dockBarEdited` 做一次。
    private func barBinding(for bar: DockBar) -> Binding<DockBar> {
        Binding(
            get: { state.dockBars.first { $0.id == bar.id } ?? bar },
            set: { state.updateDockBarInMemory($0) }
        )
    }

    private func desktopBinding(for bar: DockBar) -> Binding<String?> {
        Binding(
            get: { bar.spaceID },
            set: { state.bindDockBar(bar.id, to: $0) }
        )
    }

    private func positionBinding(for bar: DockBar) -> Binding<DockBarPosition> {
        Binding(
            get: { bar.position },
            set: { newValue in
                guard newValue != bar.position, let current = state.dockBar(id: bar.id) else { return }
                var updated = current
                updated.position = newValue
                state.dockBarEdited(updated, reason: "位置改为\(newValue.displayName)")
            }
        )
    }
}

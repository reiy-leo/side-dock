import SwiftUI

/// 应用栏 Tab：**Dock 栏列表**（2026-10-06 用户规格：原「桌面」页拆分——栏的编辑在这里，
/// 桌面命名与名称展示在「桌面」页）。
///
/// 模型：栏是主实体 —— 每根栏有名字、屏幕位置（底部/左/右，台前调度占用的一侧自动避开）、
/// 绑定的桌面（下拉，带缩略图）与图标（0...15，栏不固定任何 App）。一个桌面同时只挂一根栏。
/// 没绑栏的桌面在冻结模式下只有原生 Dock（默认 Dock = 最近添加的应用）可看。
///
/// 编辑器永远**横向**显示（不管栏在屏幕上是横是竖）；默认露出 8 个槽位，超出走滚动。
struct DockBarsTab: View {
    @Bindable var state: AppState

    @State private var selection: UUID?
    @State private var confirmingUnbind = false

    private var selectedBar: DockBar? {
        state.dockBars.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            barList
            Divider()
            editor
        }
        .onAppear {
            // 打开就选中第一根栏：编辑器不用等一次点击才出现，中部也不留大片空白。
            if selection == nil {
                selection = state.dockBars.first?.id
            }
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
                }
                Spacer()
                Text("一个桌面只挂一根栏；绑定时另一根会自动让出 · 原生 Dock \(state.dockSideDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            orphanBanner
        }
    }

    private func barRow(_ bar: DockBar) -> some View {
        HStack(spacing: 8) {
            NameField(
                value: bar.name,
                placeholder: "名称",
                width: 110,
                onCommit: { raw in
                    state.renameDockBar(bar.id, to: raw)
                    return state.dockBar(id: bar.id)?.name ?? bar.name
                }
            )
            // representable 默认吃满可用宽度，这里钉回固定尺寸。
            .fixedSize()

            Spacer(minLength: 2)

            desktopPicker(bar)
            positionPicker(bar)

            // 只有未绑定的栏能删（2026-10-06 用户规格）：绑着桌面的栏先解绑——
            // 否则那条桌面会突然没有栏可用。闸门在 AppState.removeDockBar，这里只做呈现。
            if bar.spaceID == nil {
                Button {
                    state.removeDockBar(id: bar.id)
                    if selection == bar.id { selection = nil }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("删除这根 Dock 栏")
            } else {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("这根栏绑着桌面，先解绑才能删除")
            }
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
                Text("从访达拖 .app 进来，或点「＋」选择；拖动排序，右键或拖到垃圾桶移除。栏不固定任何图标（启动台也只是普通条目），可以清空；最多 \(DockBar.maxApps) 个，编辑器里超过 \(DockBar.visibleSlots) 个走横向滚动。")
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

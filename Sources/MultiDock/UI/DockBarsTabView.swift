import SwiftUI

/// 应用栏 Tab：**Dock 栏列表**（2026-10-06 用户规格：原「桌面」页拆分——栏的编辑在这里，
/// 桌面命名与名称展示在「桌面」页）。
///
/// 模型：栏是主实体 —— 每根栏有名字、屏幕位置（底部/左/右，台前调度占用的一侧自动避开）、
/// 绑定的桌面（下拉，带缩略图）与图标（0...15，栏不固定任何 App）。一个桌面同时只挂一根栏。
/// 没绑栏的桌面只有原生 Dock 可看（本 App 不生成内容、也不改写它）。
///
/// 编辑器永远**横向**显示（不管栏在屏幕上是横是竖）；默认露出 8 个槽位，超出走滚动。
struct DockBarsTab: View {
    @Bindable var state: AppState

    @State private var selection: UUID?
    @State private var hoveredRow: UUID?
    @State private var confirmingUnbind = false

    private var selectedBar: DockBar? {
        state.dockBars.first { $0.id == selection }
    }

    var body: some View {
        // 整页可滚动（栏多时可往下滚）+ 列表**按内容自适应高度**（2026-10-06 用户规格 ⑥：
        // 列表不该撑满整页、在底部留一大片空）。不用 `List`：它的白底会一路铺到窗口顶部，
        // 看着像"列表延伸上去了"（用户规格 ①），而这里只需要几行自定义行 + 手绘选中态。
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                barList
                editor
            }
            // 与其它页的 Form 分组保持同一版心：两侧各让 60 pt
            // （实测 Form 分组框距面板边缘 ≈61 pt；统一后各页签内容列对齐）。
            .padding(.horizontal, 60)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            // 打开就选中第一根栏：编辑器不用等一次点击才出现，中部也不留大片空白。
            if selection == nil {
                selection = state.dockBars.first?.id
            }
        }
    }

    // MARK: - Dock 栏列表

    /// 标题行（计数 + 右上角「＋」）+ 行列表 + 一句规则提示，全部**按内容撑高**。
    private var barList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L("Dock 栏（\(state.dockBars.count)）", "Dock Bars (\(state.dockBars.count))"))
                    .font(.headline)
                Spacer(minLength: 8)
                // 「添加」用「＋」，放在右上角（2026-10-06 用户规格 ②）。
                Button {
                    selection = state.addDockBar()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L("添加 Dock 栏", "Add Dock Bar"))
            }
            .padding(.bottom, 6)

            if state.dockBars.isEmpty {
                Text(L("还没有 Dock 栏，点右上角「＋」添加。", "No Dock bars yet — use “+” at the top right."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 2) {
                    ForEach(state.dockBars) { bar in
                        barRow(bar)
                    }
                }
            }

            Text(L("一个桌面只挂一根栏 · 原生 Dock \(state.dockSideShortDescription)",
                   "One bar per desktop · Native Dock \(state.dockSideShortDescription)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 8)
                .help(state.dockSideDescription)

            orphanBanner
        }
    }

    /// 一行：**手绘选中/悬停态**（原 `List` 的选中高亮换成同一个圆角底色配方），
    /// 点行即选中（决定下方编辑器编辑哪根栏）。
    private func barRow(_ bar: DockBar) -> some View {
        let isSelected = selection == bar.id
        let isHovered = hoveredRow == bar.id
        return HStack(spacing: 8) {
            NameField(
                value: bar.name,
                placeholder: L("名称", "Name"),
                // 10 个中文字宽（2026-10-06 用户规格）——名字上限就是 10 字素簇。
                width: NameField.tenCharacterWidth,
                onCommit: { raw in
                    state.renameDockBar(bar.id, to: raw)
                    return state.dockBar(id: bar.id)?.name ?? bar.name
                }
            )
            // representable 默认吃满可用宽度，这里钉回固定尺寸。
            .fixedSize()

            Spacer(minLength: 8)

            desktopPicker(bar)
            positionPicker(bar)
            trailingAccessory(for: bar)
                .frame(width: 20)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected
                      ? Color.primary.opacity(0.10)
                      : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = bar.id }
        .onHover { inside in
            if inside { hoveredRow = bar.id }
            else if hoveredRow == bar.id { hoveredRow = nil }
        }
    }

    /// 行尾配件：未绑定 = 可删（−），绑定 = 锁形（先解绑）。
    /// **两态同列宽**（20pt），换栏/解绑时右边一列不跳。
    ///
    /// 「只有未绑定的栏能删」（2026-10-06 用户规格）：闸门在 `AppState.removeDockBar`，
    /// 这里只做呈现。
    @ViewBuilder
    private func trailingAccessory(for bar: DockBar) -> some View {
        if bar.spaceID == nil {
            Button {
                state.removeDockBar(id: bar.id)
                if selection == bar.id { selection = nil }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L("删除这根 Dock 栏", "Delete this Dock bar"))
        } else {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help(L("这根栏绑着桌面，先解绑才能删除", "Bound to a desktop; unbind before deleting"))
        }
    }

    /// 桌面下拉：**关闭态只显示桌面名**（少截断、一眼可读），菜单里给全信息
    /// （桌面名 · 显示器名）+ 勾选当前绑定 —— Apple §6：常见路径短，细节在下一层。
    ///
    /// ⚠️ 缩略图**不能塞进 Picker 的行视图**：SwiftUI 的 menu Picker 会把自定义行标签
    /// 渲染成一块高亮色（实测），关闭态什么都看不出来 —— 所以缩略图放在控件外面。
    /// 用 `Menu` + `Toggle` 而不是 `Picker`：Picker 的关闭态与菜单行共用同一视图，
    /// 长显示器名会把关闭态撑出省略号，且没有勾选态。
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
            Menu {
                Toggle(L("未绑定", "Unbound"), isOn: binding(bar, isBoundTo: nil))
                Divider()
                ForEach(state.desktops) { space in
                    Toggle(
                        "\(state.displayName(for: space)) · \(state.screenName(for: space.displayUUID))",
                        isOn: binding(bar, isBoundTo: space.id)
                    )
                }
            } label: {
                Text(closedDesktopText(bar))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 150)
        }
        .help(L("这根栏显示在哪个桌面上。缩略图是空间的壁纸（本机各空间共用系统壁纸时显示同一张）。",
                "Which desktop this bar appears on. The thumbnail is the space's wallpaper (the same one when spaces share the system wallpaper)."))
    }

    /// 下拉关闭态的短文案：绑定了就只显示桌面名（不带显示器名，避免截断）。
    private func closedDesktopText(_ bar: DockBar) -> String {
        guard
            let spaceID = bar.spaceID,
            let space = state.desktops.first(where: { $0.id == spaceID })
        else { return L("未绑定", "Unbound") }
        return state.displayName(for: space)
    }

    /// 单选开关绑定：勾选当前项；点已勾选项不重复落盘（`bindDockBar` 自带去重）。
    private func binding(_ bar: DockBar, isBoundTo spaceID: String?) -> Binding<Bool> {
        Binding(
            get: { bar.spaceID == spaceID },
            set: { isOn in
                guard isOn else { return }
                state.bindDockBar(bar.id, to: spaceID)
            }
        )
    }

    /// 位置下拉（2026-10-06 用户规格：分段控件改下拉列表；**不能用的选项灰掉、不消失**）。
    /// 与条上右键菜单**同一口径**（共用 `DockBarPosition.choices`）：三条边都列出，
    /// 台前调度占左缘时「左侧」置灰；勾标在当前位置上 —— 即使它已不可用也如实展示
    /// （改走可以，改回来不行）。
    private func positionPicker(_ bar: DockBar) -> some View {
        let choices = DockBarPosition.choices(current: bar.position, available: state.availableBarPositions)
        return Menu {
            ForEach(choices, id: \.position) { choice in
                Toggle(choice.position.displayName, isOn: positionBinding(for: bar, at: choice.position))
                    .disabled(!choice.isEnabled)
            }
        } label: {
            Text(bar.position.displayName)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 96)
        .help(L("栏贴在哪条屏幕边。台前调度开启时「左侧」选项置灰。",
                "Which screen edge the bar sticks to. “Left” is greyed out while Stage Manager is on."))
    }

    // MARK: - 选中栏的编辑器

    /// 选中栏的图标编辑器。**没有标题行与分割线**（2026-10-06 用户规格 ③：
    /// 「预览上方的文字和分割线去掉」）——编辑哪根栏由上方行的选中态指示。
    /// 只有异常提示（绑定的桌面不存在）仍会出现在条上方 —— 那是报警，不是标题。
    @ViewBuilder
    private var editor: some View {
        if let bar = selectedBar {
            VStack(alignment: .leading, spacing: 8) {
                if state.orphanedBars.contains(where: { $0.id == bar.id }) {
                    Label(L("「\(bar.name)」绑定的桌面已不存在", "“\(bar.name)” is bound to a desktop that no longer exists"),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                DockBarEditor(
                    bar: barBinding(for: bar),
                    onCommit: { state.dockBarEdited($0, reason: $1) },
                    // 原生 Dock 已固定的 App 不许加进来（2026-10-06 用户规格）——
                    // 排除集由 `AppState` 维护（冻结模式有效），这里只透传判断。
                    isPinnedInNativeDock: { state.isPinnedInNativeDock($0) }
                )
                Text(L("从访达拖 .app 进来，或点「＋」添加；拖动排序，拖到垃圾桶移除。栏可以清空，最多 \(DockBar.maxApps) 个，超出 \(DockBar.visibleSlots) 个横向滚动。",
                       "Drag .app bundles in from Finder, or click “+”; drag to reorder, drop on the trash to remove. Bars can be empty; up to \(DockBar.maxApps) icons, scrolling past \(DockBar.visibleSlots)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 冻结模式（原生 Dock 归用户自己）下才提这条规则：未冻结时原生 Dock 的内容
                // 就是本栏内容，说"原生已固定的不进栏"只会让人困惑。
                if state.settings.freezeNativeDockSwitching {
                    Text(L("已固定在原生 Dock 里的 App 不会在这里重复显示（每个桌面本来就能看到它们）——添加时会提示。",
                           "Apps pinned in the native Dock aren't duplicated here (they're visible on every desktop already) — you'll be told when adding one."))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text(L("在上方选一根 Dock 栏编辑它的图标", "Select a Dock bar above to edit its icons"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
    }

    /// 孤儿栏提示：绑定的桌面被系统删了 / 显示器被拔了。**只解绑不删栏**（应用要保留）。
    /// 底色卡片而不是分割线 + 裸文字（列表改成手绘行之后，分割线样式不再成套）。
    @ViewBuilder
    private var orphanBanner: some View {
        if !state.orphanedBars.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("有 \(state.orphanedBars.count) 根栏绑定的桌面已不存在",
                           "\(state.orphanedBars.count) bar(s) are bound to desktops that no longer exist"))
                        .font(.caption)
                    Text(L("可能是桌面被删了，也可能是外接显示器被拔走。插回来还能继续用，所以不会自动动它们。",
                           "The desktop may have been deleted or an external display unplugged. They're left untouched in case it comes back."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(L("解绑", "Unbind")) { confirmingUnbind = true }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.10))
            )
            .padding(.top, 8)
            .alert(L("解绑 \(state.orphanedBars.count) 根失效栏的桌面绑定？",
                     "Unbind \(state.orphanedBars.count) orphaned bar(s)?"),
                   isPresented: $confirmingUnbind) {
                Button(L("解绑", "Unbind"), role: .destructive) { state.unbindOrphanedBars() }
                Button(L("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(L("只解除绑定，栏的名字、位置与图标都保留。",
                       "Only the binding is removed; the bar's name, position and icons are kept."))
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

    /// 下拉里单项的开关绑定：勾选它 = 把栏移到该位置。只允许移到**可用**的位置
    /// （不可用项在菜单里已置灰，这里是第二道闸）；点当前项不重复落盘。
    private func positionBinding(for bar: DockBar, at position: DockBarPosition) -> Binding<Bool> {
        Binding(
            get: { bar.position == position },
            set: { isOn in
                guard isOn,
                      bar.position != position,
                      state.availableBarPositions.contains(position),
                      let current = state.dockBar(id: bar.id)
                else { return }
                var updated = current
                updated.position = position
                state.dockBarEdited(updated, reason: L("位置改为\(position.displayName)", "Position changed to \(position.displayName)"))
            }
        )
    }
}

import SwiftUI

/// Dock 外观控件（位置 / 大小 / 放大 / 自动隐藏 / 最小化特效…）。
///
/// 通用 Tab（默认 Dock）与桌面 Tab（某个桌面的独立 Dock）复用同一个控件。
/// **本机 Dock 域里不存在的键对应的控件会被禁用并说明原因** —— 不做"能改但没反应"的假开关
/// （`docs/PLAN.md` §3.2，P2 实测本机缺 `show-process-indicators`）。
///
/// `appearance` 是**只改内存**的绑定；真正的落盘 + 应用由 `onCommit` 触发。
/// 必须这么分：滑杆一次拖动能产生几十次赋值，若每次都落盘并重启 Dock，用户会看到连续闪烁。
/// 所以滑杆只在**松手**时提交，开关与下拉框在值变化时提交。
struct DockAppearanceEditor: View {

    @Binding var appearance: DockAppearance
    /// 本机 Dock 域里不存在、写不进去的键。
    var unavailableKeys: Set<String>
    /// 一次编辑结束时回调，参数是给日志用的一句话。
    var onCommit: (String) -> Void = { _ in }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            orientationRow
            tilesizeRow
            magnificationRow
            autohideRow
            mineffectRow
            minimizeToApplicationRow
            processIndicatorsRow
        }
    }

    // MARK: - 各行

    private var orientationRow: some View {
        GridRow {
            Text("位置")
            Picker("", selection: $appearance.orientation) {
                Text("下").tag("bottom")
                Text("左").tag("left")
                Text("右").tag("right")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)
            .onChange(of: appearance.orientation) { _, new in
                onCommit("Dock 位置改为 \(Self.orientationName(new))")
            }
            Text("Dock 贴在屏幕的哪一边。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tilesizeRow: some View {
        GridRow {
            Text("大小")
            HStack(spacing: 8) {
                Slider(value: $appearance.tilesize, in: 16...128, step: 1) { editing in
                    if !editing { onCommit("图标大小改为 \(Int(appearance.tilesize))") }
                }
                .frame(width: 160)
                Text("\(Int(appearance.tilesize))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 28, alignment: .trailing)
            }
            Text("图标大小（16–128）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var magnificationRow: some View {
        GridRow {
            Text("放大")
            HStack(spacing: 8) {
                Toggle("", isOn: $appearance.magnification)
                    .labelsHidden()
                    .onChange(of: appearance.magnification) { _, new in
                        onCommit(new ? "打开放大效果" : "关闭放大效果")
                    }
                Slider(value: $appearance.largesize, in: 32...256, step: 1) { editing in
                    if !editing { onCommit("放大最大尺寸改为 \(Int(appearance.largesize))") }
                }
                .frame(width: 120)
                .disabled(!appearance.magnification)
                Text("\(Int(appearance.largesize))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 28, alignment: .trailing)
                    .foregroundStyle(appearance.magnification ? .primary : .secondary)
            }
            Text("鼠标扫过时放大的最大尺寸。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var autohideRow: some View {
        GridRow {
            Text("自动隐藏")
            Toggle("", isOn: $appearance.autohide)
                .labelsHidden()
                .onChange(of: appearance.autohide) { _, new in
                    onCommit(new ? "打开自动隐藏" : "关闭自动隐藏")
                }
            Text("不碰鼠标时把 Dock 藏起来。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var mineffectRow: some View {
        GridRow {
            Text("最小化特效")
            Picker("", selection: $appearance.mineffect) {
                Text("精灵球").tag("genie")
                Text("缩放").tag("scale")
            }
            .labelsHidden()
            .frame(width: 120)
            .onChange(of: appearance.mineffect) { _, new in
                onCommit("最小化特效改为 \(new == "genie" ? "精灵球" : "缩放")")
            }
            Text("窗口最小化时的动画。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var minimizeToApplicationRow: some View {
        GridRow {
            Text("最小化到应用图标")
            Toggle("", isOn: $appearance.minimizeToApplication)
                .labelsHidden()
                .onChange(of: appearance.minimizeToApplication) { _, new in
                    onCommit(new ? "打开最小化到应用图标" : "关闭最小化到应用图标")
                }
            Text("最小化后收进应用自己的图标，而不是单独占一格。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var processIndicatorsRow: some View {
        GridRow {
            Text("运行指示点")
            HStack(spacing: 6) {
                Toggle("", isOn: $appearance.showProcessIndicators)
                    .labelsHidden()
                    .disabled(isUnavailable("show-process-indicators"))
                    .onChange(of: appearance.showProcessIndicators) { _, new in
                        onCommit(new ? "打开运行指示点" : "关闭运行指示点")
                    }
                if isUnavailable("show-process-indicators") {
                    Label("本机不支持", systemImage: "nosign")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text(isUnavailable("show-process-indicators")
                 ? "当前 macOS 的 com.apple.dock 里没有 show-process-indicators 这个键，写进去不会生效，所以这里禁用。"
                 : "Dock 上正在运行的 App 下方显示一个小点。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func isUnavailable(_ key: String) -> Bool { unavailableKeys.contains(key) }

    private static func orientationName(_ value: String) -> String {
        switch value {
        case "left": return "左侧"
        case "right": return "右侧"
        default: return "底部"
        }
    }
}

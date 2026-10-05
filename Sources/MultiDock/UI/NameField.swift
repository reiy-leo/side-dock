import AppKit
import SwiftUI

/// 名称输入框（Dock 栏名与桌面名共用；2026-10-06 用户规格）。
///
/// **为什么不是 SwiftUI 的 `TextField`**：
/// 1. **输入超过 10 个字符即删**：截断必须看得到输入法组字状态——marked text 期间动文本会
///    打断候选词，只有 AppKit 的 field editor 有 `hasMarkedText()` 这个信号
///    （`controlTextDidChange` + 判断）。提交时再过一遍 `DesktopNaming.normalize`
///    （换行折空格、去首尾空白）。
/// 2. **观感**：自绘圆角容器（1px 描边、聚焦换强调色、内边距 7pt）——
///    SwiftUI 的 `roundedBorder` 调不了内边距，在分组 Form 里显得又挤又生硬。
///
/// 编辑期间**不写模型**（所以不会打断组字）；回车 / 失焦 / 点别处时提交一次。
/// 截断按**字素簇**（`prefix(10)`），中文、emoji 组合都不会被劈开。
struct NameField: NSViewRepresentable {
    /// 当前模型值。视图只负责显示它；输入过程不写回。
    let value: String
    let placeholder: String
    var maxLength: Int = DesktopNaming.maxLength
    var width: CGFloat = 160
    /// 提交（回车 / 失焦）回调。**返回模型最终接受的名字**——模型可能归一化或拒绝
    /// （空名保持原值 / 清空桌面名回落「桌面 N」），输入框用它对齐回真实值。
    let onCommit: (String) -> String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NameFieldContainer {
        let container = NameFieldContainer()
        container.preferredWidth = width
        let field = container.field
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.placeholderString = placeholder
        field.stringValue = value
        return container
    }

    func updateNSView(_ container: NameFieldContainer, context: Context) {
        context.coordinator.parent = self
        container.preferredWidth = width
        container.field.placeholderString = placeholder
        // 编辑中绝不回写（会顶掉光标/组字）；闲时只在与模型不一致时同步。
        if container.field.currentEditor() == nil, container.field.stringValue != value {
            container.field.stringValue = value
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NameField

        init(_ parent: NameField) {
            self.parent = parent
        }

        /// 输入即截断。组字期间（拼音 / 仓颉候选）跳过，等字定下来后的那次 change 再截。
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            guard field.stringValue.count > parent.maxLength else { return }
            let truncated = String(field.stringValue.prefix(parent.maxLength))
            field.stringValue = truncated
            // 截断发生在光标后面时 AppKit 自己会收敛；显式把光标收到末尾，避免越界。
            field.currentEditor()?.selectedRange = NSRange(
                location: (truncated as NSString).length, length: 0
            )
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? NSTextField)?.enclosingNameFieldContainer?.isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            field.enclosingNameFieldContainer?.isFocused = false
            commit(field)
        }

        /// 回车：显式结束编辑（提交统一走 `controlTextDidEndEditing`，只留一条路径）。
        @objc func submit(_ sender: NSTextField) {
            sender.window?.makeFirstResponder(nil)
        }

        private func commit(_ field: NSTextField) {
            let accepted = parent.onCommit(DesktopNaming.normalize(field.stringValue))
            if field.stringValue != accepted {
                field.stringValue = accepted
            }
        }
    }
}

/// 输入框的容器：负责圆角 / 描边 / 聚焦态与内边距（NSTextField 本身调不了这些）。
@MainActor
final class NameFieldContainer: NSView {
    let field = NSTextField()
    /// SwiftUI 布局用的首选宽度（高度固定 26）。
    var preferredWidth: CGFloat = 160 {
        didSet { invalidateIntrinsicContentSize() }
    }
    var isFocused = false {
        didSet { if isFocused != oldValue { needsDisplay = true } }
    }

    private static let height: CGFloat = 26
    private static let cornerRadius: CGFloat = 7
    private static let horizontalPadding: CGFloat = 7

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: Self.height)
    }

    override func layout() {
        super.layout()
        let textHeight = field.intrinsicContentSize.height
        field.frame = NSRect(
            x: Self.horizontalPadding,
            y: (bounds.height - textHeight) / 2,
            width: max(0, bounds.width - Self.horizontalPadding * 2),
            height: textHeight
        )
    }

    /// 点内边距也要能进编辑（否则只有点中文字本身才有反应）。
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        (isFocused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isFocused ? 1.5 : 1
        path.stroke()
    }
}

private extension NSTextField {
    /// 从 field editor 的通知对象找回容器（委托链上没有直接持有）。
    var enclosingNameFieldContainer: NameFieldContainer? {
        superview as? NameFieldContainer
    }
}

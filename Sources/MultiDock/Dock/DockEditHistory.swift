import Foundation

/// 自动回存前的旧配置暂存（计划 §3.8「覆盖前存一份历史版本」）。
///
/// **只在内存里，不落盘**，这是刻意的：
/// - 落盘一堆没有恢复入口的文件等于花架子 —— 用户翻到 `history/` 也用不上；
/// - 回存要防的风险是"误判一次、把用户在真实 Dock 上的改动写坏了配置"，一步撤销就够；
/// - 真正要长期保命的是 `baseline.plist` 与 `backups/`，那两个已经在落盘了。
///
/// 撤销后 watcher 不会立刻再触发：它只在**真实 Dock 的指纹变化**时才回调，
/// 撤销改的是配置、没动 Dock。
struct DockEditHistory {

    static let defaultDockKey = "default"

    /// 每个目标保留的版本数。回存是低频操作，5 层足够。
    let depth: Int

    private var stacks: [String: [DockConfig]] = [:]

    init(depth: Int = 5) {
        self.depth = max(1, depth)
    }

    /// 覆盖**之前**调用：把即将被覆盖的旧配置压栈。
    mutating func push(_ config: DockConfig, for key: String) {
        var stack = stacks[key] ?? []
        stack.append(config)
        if stack.count > depth { stack.removeFirst(stack.count - depth) }
        stacks[key] = stack
    }

    /// 弹出最近一份旧配置；没有则 nil。
    mutating func pop(for key: String) -> DockConfig? {
        guard var stack = stacks[key], let last = stack.popLast() else { return nil }
        stacks[key] = stack.isEmpty ? nil : stack
        return last
    }

    func canUndo(for key: String) -> Bool {
        !(stacks[key]?.isEmpty ?? true)
    }

    /// 调试与测试用：当前还有哪些目标存着历史。
    var keys: [String] { stacks.keys.sorted() }
}

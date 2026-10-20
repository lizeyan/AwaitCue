import AwaitCueCapture

/// 将窗口发现结果转换为明确前后顺序的内部边界。
protocol WindowZOrderProviding: Sendable {
    /// 返回从最前到最后排列的窗口；无法读取系统顺序时必须失败而不是猜测。
    func orderFrontToBack(_ windows: [DiscoveredWindow]) throws -> [DiscoveredWindow]
}

/// 用明确的 window ID 列表稳定排列 DiscoveredWindow，并保留未列出项的原相对顺序。
enum WindowZOrder {
    /// 排序时不使用标题或 bundle 猜测，只关联完全相同的 window ID。
    static func order(
        _ windows: [DiscoveredWindow],
        identifiersFrontToBack: [UInt32]
    ) -> [DiscoveredWindow] {
        var ranks: [UInt32: Int] = [:]
        for (index, identifier) in identifiersFrontToBack.enumerated()
        where ranks[identifier] == nil {
            ranks[identifier] = index
        }

        return windows.enumerated().sorted { lhs, rhs in
            let lhsRank = ranks[lhs.element.windowIdentifier] ?? Int.max
            let rhsRank = ranks[rhs.element.windowIdentifier] ?? Int.max
            if lhsRank == rhsRank {
                return lhs.offset < rhs.offset
            }
            return lhsRank < rhsRank
        }.map(\.element)
    }
}

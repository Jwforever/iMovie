import Foundation

/// 来源的固定排序。
///
/// 排序只在"导入配置 / 探测结束 / 用户改默认源"这几个时刻算一次，并把结果存下来；
/// 界面永远按这份固定顺序渲染，不会因为后台探测回来而跳动。
public enum SourceOrdering {
    /// 默认源 → 出过内容 → 未测过 → 拉取失败；同档保持配置里的原始顺序。
    public static func arrange(_ sites: [SourceSite],
                               ranks: [String: Int],
                               preferred: String?) -> [SourceSite] {
        sites.enumerated().sorted { lhs, rhs in
            let leftPreferred = lhs.element.key == preferred
            let rightPreferred = rhs.element.key == preferred
            if leftPreferred != rightPreferred { return leftPreferred }

            let left = ranks[lhs.element.key] ?? 2
            let right = ranks[rhs.element.key] ?? 2
            if left != right { return left > right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 按已保存的顺序重排；配置里新增的来源追加在末尾。
    public static func apply(order: [String], to sites: [SourceSite]) -> [SourceSite] {
        guard !order.isEmpty else { return sites }
        var index: [String: Int] = [:]
        for (position, key) in order.enumerated() { index[key] = position }
        return sites.enumerated().sorted { lhs, rhs in
            let left = index[lhs.element.key] ?? Int.max
            let right = index[rhs.element.key] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }
}

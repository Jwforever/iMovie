import Foundation

public enum SearchRanking {
    public static func score(title: String, query: String) -> Int {
        let title = normalize(title), query = normalize(query)
        guard !query.isEmpty, !title.isEmpty else { return 0 }
        if title == query { return 100_000 }
        if title.hasPrefix(query) { return 80_000 - min(10_000, title.count - query.count) }
        if title.contains(query) { return 60_000 - min(10_000, title.count - query.count) }
        let target = Array(title.prefix(200)), needle = Array(query.prefix(120))
        var previous = Array(repeating: 0, count: target.count + 1)
        for character in needle {
            var current = Array(repeating: 0, count: target.count + 1)
            for (index, value) in target.enumerated() {
                current[index + 1] = value == character ? previous[index] + 1 : max(previous[index + 1], current[index])
            }
            previous = current
        }
        let matched = previous.max() ?? 0
        guard matched > 0 else { return 0 }
        return matched * 10_000 / max(1, needle.count) + matched * 1_000 / max(1, target.count)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN"))
            .filter { $0.isLetter || $0.isNumber }
    }
}

import Foundation

public struct DoubanRecommendation: Identifiable, Codable, Hashable {
    public var id: String
    public var title: String
    public var poster: String
    public var rating: Double
    public var votes: Int
    public var subtitle: String
    public var subjectURL: URL { URL(string: "https://movie.douban.com/subject/\(id)/")! }
}

public struct DoubanRecommendations {
    public init() {}
    public func fetch() async throws -> [DoubanRecommendation] {
        #if DEBUG
        if let address = ProcessInfo.processInfo.environment["IMOVIE_DOUBAN_URL"], let url = HTTPAddress.optional(address) {
            let (data, _) = try await HTTPClient().data(from: url)
            return try Self.decode(data)
        }
        #endif
        return await withTaskGroup(of: [DoubanRecommendation].self) { group in
            for collection in ["movie_top250", "tv_hot", "movie_showing"] {
                group.addTask {
                    let url = URL(string: "https://m.douban.com/rexxar/api/v2/subject_collection/\(collection)/items?start=0&count=30")!
                    guard let (data, _) = try? await HTTPClient().data(from: url, headers: ["Referer": "https://m.douban.com/", "User-Agent": HTMLSourceAdapter.userAgent], cacheLifetime: 6 * 60 * 60) else { return [] }
                    return (try? Self.decode(data)) ?? []
                }
            }
            var seen = Set<String>(), results: [DoubanRecommendation] = []
            for await batch in group { results += batch.filter { seen.insert($0.id).inserted } }
            return results.sorted { $0.rating == $1.rating ? $0.votes > $1.votes : $0.rating > $1.rating }
        }
    }

    static func decode(_ data: Data) throws -> [DoubanRecommendation] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["subject_collection_items"] as? [[String: Any]] else {
            throw ViewerError.message("暂时无法读取豆瓣推荐。")
        }
        var seen = Set<String>()
        return list.compactMap { row in
            let id = JSONValue.text(row["id"]), title = JSONValue.text(row["title"])
            guard !id.isEmpty, id.allSatisfy(\.isNumber), !title.isEmpty, seen.insert(id).inserted,
                  let rating = row["rating"] as? [String: Any],
                  let value = rating["value"] as? Double, value >= 7, value <= 10,
                  JSONValue.integer(rating["count"]) >= 100 else { return nil }
            return DoubanRecommendation(id: id, title: title, poster: (row["cover"] as? [String: Any])?["url"] as? String ?? "", rating: value,
                                        votes: JSONValue.integer(rating["count"]), subtitle: JSONValue.text(row["card_subtitle"]))
        }.sorted { $0.rating == $1.rating ? $0.votes > $1.votes : $0.rating > $1.rating }
    }

    public static func matches(_ title: String, video: Video) -> Bool {
        func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        return normalized(title) == normalized(video.title)
    }
}

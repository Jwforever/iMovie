import Foundation

public struct BilibiliAdapter {
    private let http = HTTPClient()
    public static let headers = ["User-Agent": "Mozilla/5.0", "Referer": "https://www.bilibili.com/"]
    private let site: SourceSite
    public init(site: SourceSite) { self.site = site }

    public func page(category: String?, search: String?, page: Int) async throws -> VideoPage {
        let categories = await sourceCategories()
        let query = (search?.isEmpty == false ? search : category) ?? ""
        let root: [String: Any]
        if query.isEmpty {
            root = try await object(path: "/x/web-interface/popular", query: ["pn": String(page), "ps": "20"])
        } else {
            root = try await object(path: "/x/web-interface/search/type", query: ["search_type": "video", "keyword": query, "page": String(page), "page_size": "20"])
        }
        let content = root["data"] as? [String: Any] ?? [:]
        guard content["v_voucher"] == nil else { throw ViewerError.message("网站要求验证，请稍后重试或更换来源。") }
        let rows = (content[query.isEmpty ? "list" : "result"] as? [[String: Any]] ?? [])
        let videos = rows.compactMap(Self.video)
        let pages = query.isEmpty ? (JSONValue.flag(content["no_more"]) ? page : page + 1) : max(page, JSONValue.integer(content["numPages"], default: page))
        return VideoPage(categories: categories, videos: videos, page: page, pageCount: videos.isEmpty ? page : pages)
    }

    public func detail(id: String) async throws -> Video {
        guard Self.validBVID(id) else { throw ViewerError.message("视频编号无效。") }
        let root = try await object(path: "/x/web-interface/view", query: ["bvid": id])
        guard let content = root["data"] as? [String: Any], var result = Self.video(content) else { throw ViewerError.message("没有返回视频详情。") }
        let pages = content["pages"] as? [[String: Any]] ?? []
        result.summary = JSONValue.text(content["desc"])
        result.playFrom = "公开视频"
        result.playURL = pages.compactMap { row -> String? in
            let cid = JSONValue.text(row["cid"])
            guard !cid.isEmpty else { return nil }
            let label = JSONValue.text(row["part"]).replacingOccurrences(of: "$", with: " ").replacingOccurrences(of: "#", with: " ")
            return (label.isEmpty ? "播放" : label) + "$bili:" + id + ":" + cid
        }.joined(separator: "#")
        return result
    }

    public func resolve(episode: Episode, title: String) async throws -> MediaLink {
        let parts = episode.value.components(separatedBy: ":")
        guard parts.count == 3, parts[0] == "bili", Self.validBVID(parts[1]), parts[2].allSatisfy(\.isNumber) else { throw ViewerError.message("分集编号无效。") }
        let root = try await object(path: "/x/player/playurl", query: ["bvid": parts[1], "cid": parts[2], "qn": "32", "fnval": "0", "platform": "html5", "high_quality": "0"])
        guard let content = root["data"] as? [String: Any], let clips = content["durl"] as? [[String: Any]], clips.count == 1,
              let value = clips.first?["url"] as? String, let url = HTTPAddress.optional(value) else {
            throw ViewerError.message("该内容没有返回可直接播放的公开单文件地址。登录、付费及分离音视频暂未适配。")
        }
        return MediaLink(title: title, url: url.absoluteString, headers: Self.headers, group: site.name)
    }

    private func sourceCategories() async -> [VideoCategory] {
        let fallback = [VideoCategory(id: "纪录片", name: "纪录片"), VideoCategory(id: "动画", name: "动画"), VideoCategory(id: "音乐", name: "音乐")]
        guard let raw = site.extensionValue, let bytes = raw.data(using: .utf8),
              let ext = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let address = ext["json"] as? String, let url = HTTPAddress.optional(address),
              let (data, _) = try? await http.data(from: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
        let entries = (root["class"] as? [[String: Any]] ?? []).compactMap { row -> VideoCategory? in
            let id = JSONValue.text(row["type_id"])
            guard !id.isEmpty, id != "peizhi" else { return nil }
            return VideoCategory(id: id, name: JSONValue.text(row["type_name"]))
        }
        return entries.isEmpty ? fallback : entries
    }

    private func object(path: String, query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://api.bilibili.com" + path)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, _) = try await http.data(from: components.url!, headers: Self.headers)
        let root = try Self.decode(data)
        return root
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ViewerError.message("接口没有返回 JSON。") }
        guard JSONValue.integer(root["code"], default: -1) == 0 else {
            let message = JSONValue.text(root["message"])
            throw ViewerError.message(message.isEmpty ? "来源暂时不可用。" : message)
        }
        return root
    }

    static func video(_ row: [String: Any]) -> Video? {
        let id = JSONValue.text(row["bvid"])
        guard validBVID(id) else { return nil }
        let picture = JSONValue.text(row["pic"])
        let value = picture.hasPrefix("//") ? "https:" + picture : picture
        return Video(id: id, title: TVAPIClient.clean(JSONValue.text(row["title"])), poster: HTTPAddress.optional(value)?.absoluteString ?? "", note: JSONValue.text(row["author"]), summary: JSONValue.text(row["description"]), playFrom: "", playURL: "")
    }

    private static func validBVID(_ value: String) -> Bool {
        value.hasPrefix("BV") && (10...20).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

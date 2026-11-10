import Foundation

/// 为已知公开网站独立实现的适配；不会下载或执行其 drpy / Android 爬虫。
public struct TuxiaobeiAdapter {
    static let origin = "https://www.tuxiaobei.com"
    static let headers = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 Version/16.0 Mobile/15E148 Safari/604.1",
        "Referer": origin + "/"
    ]
    static let categories = [
        VideoCategory(id: "2", name: "儿歌"), VideoCategory(id: "3", name: "故事"),
        VideoCategory(id: "4", name: "国学"), VideoCategory(id: "25", name: "启蒙")
    ]
    private let http = HTTPClient()
    public init() {}

    public func page(category: String?, search: String?, page: Int) async throws -> VideoPage {
        if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var components = URLComponents(string: Self.origin + "/search/index")!
            components.queryItems = [URLQueryItem(name: "key", value: search)]
            let (data, _) = try await http.data(from: components.url!, headers: Self.headers)
            return try Self.decodeSearch(data)
        }
        let selected = category.flatMap { candidate in Self.categories.first { $0.id == candidate }?.id } ?? "2"
        var components = URLComponents(string: Self.origin + "/list/mip-data")!
        components.queryItems = [URLQueryItem(name: "typeId", value: selected), URLQueryItem(name: "page", value: String(max(1, page))), URLQueryItem(name: "callback", value: "")]
        let (data, _) = try await http.data(from: components.url!, headers: Self.headers)
        return try Self.decodeCategory(data, page: max(1, page))
    }

    public func detail(id: String) async throws -> Video {
        guard !id.isEmpty, id.allSatisfy(\.isNumber), id.utf8.count <= 16 else {
            throw ViewerError.message("这个来源的内容编号无效。")
        }
        let (data, _) = try await http.data(from: HTTPAddress.parse(Self.origin + "/play/" + id), headers: Self.headers)
        return try Self.decodeDetail(data, id: id)
    }

    static func decodeCategory(_ data: Data, page: Int) throws -> VideoPage {
        let root = try jsonObject(data)
        guard JSONValue.integer(root["status"], default: -1) == 0,
              let content = root["data"] as? [String: Any], let items = content["items"] as? [[String: Any]] else {
            throw ViewerError.message("分类接口结构已变化，需要更新这个来源的适配。")
        }
        var seen = Set<String>()
        let videos = items.compactMap { item -> Video? in
            let id = JSONValue.text(item["video_id"])
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let poster = JSONValue.text(item["image"])
            return Video(id: id, title: plain(JSONValue.text(item["name"])),
                         poster: HTTPAddress.optional(poster)?.absoluteString ?? "",
                         note: JSONValue.text(item["duration_string"]), summary: "", playFrom: "", playURL: "")
        }
        return VideoPage(categories: categories, videos: videos, page: page, pageCount: items.count >= 30 ? page + 1 : page)
    }

    static func decodeSearch(_ data: Data) throws -> VideoPage {
        let html = try htmlText(data)
        guard html.contains("list-con") || html.contains("search-result") else {
            throw ViewerError.message("搜索页面结构已变化，需要更新这个来源的适配。")
        }
        let blocks = html.components(separatedBy: "<!--items end-->")
        var seen = Set<String>()
        let videos = blocks.compactMap { block -> Video? in
            guard let id = capture(#"href\s*=\s*["']/play/(\d+)["']"#, in: block), seen.insert(id).inserted else { return nil }
            let title = capture(#"<p\b[^>]*class\s*=\s*["']title["'][^>]*>([\s\S]*?)</p>"#, in: block) ?? "内容 \(id)"
            let imageTag = capture(#"(<mip-img\b[^>]*>)"#, in: block) ?? ""
            let poster = attribute("src", in: imageTag) ?? ""
            let note = capture(#"<[^>]+class\s*=\s*["']time["'][^>]*>([\s\S]*?)</[^>]+>"#, in: block) ?? ""
            return Video(id: id, title: plain(title), poster: HTTPAddress.optional(poster, relativeTo: URL(string: origin))?.absoluteString ?? "",
                         note: plain(note), summary: "", playFrom: "", playURL: "")
        }
        return VideoPage(categories: categories, videos: videos, page: 1, pageCount: 1)
    }

    static func decodeDetail(_ data: Data, id: String) throws -> Video {
        let html = try htmlText(data)
        guard let tag = capture(#"(<mip-search-video\b[^>]*>)"#, in: html),
              let media = attribute("video-src", in: tag), let url = HTTPAddress.optional(media), HTTPAddress.isMedia(url.absoluteString) else {
            throw ViewerError.message("播放页面没有公开的媒体地址，或页面结构已变化。")
        }
        let title = capture(#"<div\b[^>]*class\s*=\s*["']title["'][^>]*>([\s\S]*?)</div>"#, in: html) ?? "内容 \(id)"
        let poster = attribute("poster", in: tag) ?? ""
        return Video(id: id, title: plain(title), poster: HTTPAddress.optional(poster)?.absoluteString ?? "",
                     note: "本机适配 · 实验", summary: "", playFrom: "网站公开视频", playURL: "播放$" + url.absoluteString)
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        var text = try htmlText(data).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasPrefix("{") {
            guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last else {
                throw ViewerError.message("来源没有返回 JSON 或 JSONP。")
            }
            let prefix = String(text[..<first])
            let suffix = String(text[text.index(after: last)...])
            guard prefix.range(of: #"^\s*(?:[$A-Za-z_][$\w.]*)?\s*\(\s*$"#, options: .regularExpression) != nil,
                  suffix.range(of: #"^\s*\)\s*;?\s*$"#, options: .regularExpression) != nil else {
                throw ViewerError.message("不支持这个来源的响应封装。")
            }
            text = String(text[first...last])
        }
        guard let bytes = text.data(using: .utf8), let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ViewerError.message("来源 JSON 格式不正确。")
        }
        return root
    }

    private static func htmlText(_ data: Data) throws -> String {
        guard data.count <= ConfigDecoder.maximumBytes, let value = String(data: data, encoding: .utf8) else {
            throw ViewerError.message("来源返回的文本为空、超过大小限制或编码不受支持。")
        }
        return value.replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        capture("\\b" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*["']([^"']*)["']"#, in: tag).map(plain)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func plain(_ value: String) -> String {
        TVAPIClient.clean(value).replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}

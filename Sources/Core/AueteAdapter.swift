import Foundation
import SwiftSoup

/// Auete's public site, implemented locally for the TVBox csp_Auete entry.
public struct AueteAdapter {
    public static let origin = URL(string: "https://www.aeete.com")!
    public static let categories = [
        VideoCategory(id: "Movie", name: "电影"), VideoCategory(id: "Tv", name: "电视剧"),
        VideoCategory(id: "Zy", name: "综艺"), VideoCategory(id: "Dm", name: "动漫"),
        VideoCategory(id: "qita", name: "其他")
    ]
    public static var headers: [String: String] {
        ["User-Agent": HTMLSourceAdapter.userAgent, "Referer": origin.absoluteString + "/"]
    }
    private let http = HTTPClient()
    public init() {}

    public func page(category: String?, search: String?, page: Int) async throws -> VideoPage {
        let url = try Self.pageURL(category: category, search: search, page: page)
        let (data, final) = try await http.data(from: url, headers: Self.headers)
        return try Self.decodePage(data, baseURL: final, page: max(1, page))
    }

    static func pageURL(category: String?, search: String?, page: Int) throws -> URL {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        let requested = max(1, page)
        if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.path = "/auete4so.php"
            components.queryItems = [URLQueryItem(name: "searchword", value: search), URLQueryItem(name: "page", value: String(requested))]
        } else if let category, !category.isEmpty {
            guard categories.contains(where: { $0.id == category }) else { throw ViewerError.message("分类不存在。") }
            components.path = "/\(category)/index\(requested == 1 ? "" : String(requested)).html"
        } else { components.path = "/" }
        guard let url = components.url else { throw ViewerError.message("无法构造来源地址。") }
        return url
    }

    public func detail(id: String) async throws -> Video {
        let url = try Self.contentURL(id)
        let (data, final) = try await http.data(from: url, headers: Self.headers)
        return try Self.decodeDetail(data, baseURL: final, id: id)
    }

    public func resolve(episode: Episode, title: String, group: String) async throws -> MediaLink {
        let url = try HTTPAddress.parse(episode.value)
        guard Self.allowedHost(url), Self.contentPath(url.path, episode: true) else { throw ViewerError.message("选集地址与来源不匹配。") }
        let (data, final) = try await http.data(from: url, headers: Self.headers)
        if let mediaURL = Self.decodePlayer(data) {
            return MediaLink(title: title, url: mediaURL.absoluteString, headers: Self.headers, group: group)
        }
        return MediaLink(title: title, url: final.absoluteString, headers: Self.headers, group: group, kind: .web)
    }

    static func decodePlayer(_ data: Data) -> URL? {
        guard let html = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"\bvar\s+now\s*=\s*base64decode\(["']([A-Za-z0-9+/=]+)["']\)"#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let bytes = Data(base64Encoded: String(html[range])), let value = String(data: bytes, encoding: .utf8),
              HTTPAddress.isMedia(value) else { return nil }
        return HTTPAddress.optional(value)
    }

    static func decodePage(_ data: Data, baseURL: URL, page: Int) throws -> VideoPage {
        let doc = try document(data, baseURL: baseURL)
        var seen = Set<String>(), videos: [Video] = []
        for item in try doc.select("li[data-href], .carousel-item").array() {
            guard let anchor = try item.select("h2 a[href], a.carousel-link[href]").first() else { continue }
            let url = try HTTPAddress.parse(anchor.attr("href"), relativeTo: baseURL)
            let id = url.path.hasSuffix("/") ? url.path : url.path + "/"
            guard allowedHost(url), contentPath(url.path, episode: false), seen.insert(id).inserted else { continue }
            let image = try item.select("img").first()
            let label = try anchor.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let title = label.isEmpty ? (try image?.attr("alt") ?? "") : label
            let lazy = try image?.attr("data-original") ?? ""
            let poster = lazy.isEmpty ? (try image?.attr("src") ?? "") : lazy
            videos.append(Video(id: id, title: title, poster: HTTPAddress.optional(poster, relativeTo: baseURL)?.absoluteString ?? "", note: try item.select(".hdtag").text(), summary: "", playFrom: "", playURL: ""))
        }
        if videos.isEmpty {
            let text = try doc.text()
            if text.contains("Just a moment") || text.contains("验证码") || text.contains("Access denied") {
                throw ViewerError.message("网站要求验证，暂时无法读取。")
            }
        }
        let hasNext = try doc.select(".pagination a[href]").array().contains {
            let label = try $0.text()
            let href = try $0.attr("href")
            return label.contains("下一页") && href != "#" && !href.isEmpty
        }
        return VideoPage(categories: categories, videos: videos, page: page, pageCount: hasNext ? page + 1 : page)
    }

    static func decodeDetail(_ data: Data, baseURL: URL, id: String) throws -> Video {
        let doc = try document(data, baseURL: baseURL)
        let title = try doc.select("h1.detail-title").text().trimmingCharacters(in: CharacterSet(charactersIn: "《》 \n"))
        guard !title.isEmpty else { throw ViewerError.message("来源没有返回影片详情。") }
        let image = try doc.select(".detail-poster img").attr("src")
        let lists = try doc.select("ul.episode-list").array()
        var names: [String] = [], blocks: [String] = []
        for (index, list) in lists.enumerated() {
            var episodes: [String] = []
            for anchor in try list.select("a[href]").array() {
                let url = try HTTPAddress.parse(anchor.attr("href"), relativeTo: baseURL)
                guard allowedHost(url), contentPath(url.path, episode: true) else { continue }
                let label = try anchor.text().replacingOccurrences(of: "$", with: " ").replacingOccurrences(of: "#", with: " ")
                episodes.append(label + "$" + url.absoluteString)
            }
            if !episodes.isEmpty { names.append("线路 \(index + 1)"); blocks.append(episodes.joined(separator: "#")) }
        }
        let summary = try doc.select(".detail-info-body").text()
        return Video(id: id, title: title, poster: HTTPAddress.optional(image, relativeTo: baseURL)?.absoluteString ?? "", note: try doc.select(".detail-status").text(), summary: summary, playFrom: names.joined(separator: "$$$"), playURL: blocks.joined(separator: "$$$"))
    }

    private static func contentURL(_ id: String) throws -> URL {
        let url = try HTTPAddress.parse(id, relativeTo: origin)
        guard allowedHost(url), contentPath(url.path, episode: false), url.query == nil else { throw ViewerError.message("影片地址与来源不匹配。") }
        return url
    }

    private static func allowedHost(_ url: URL) -> Bool {
        ["www.aeete.com", "aeete.com"].contains(url.host?.lowercased() ?? "")
    }

    private static func contentPath(_ path: String, episode: Bool) -> Bool {
        let suffix = episode ? #"/play-\d+-\d+\.html$"# : #"/?$"#
        let pattern = #"^/(Movie|Tv|Zy|Dm|qita)/[A-Za-z0-9_-]+/[A-Za-z0-9_%.-]+"# + suffix
        return path.range(of: pattern, options: .regularExpression) != nil
    }

    private static func document(_ data: Data, baseURL: URL) throws -> Document {
        guard let html = String(data: data, encoding: .utf8) else { throw ViewerError.message("来源网页编码不受支持。") }
        return try SwiftSoup.parse(html, baseURL.absoluteString)
    }
}

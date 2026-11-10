import Foundation
import SwiftSoup

/// 本机 HTML 适配；按已知站点解析公开页面，不执行 Android 插件。
public struct HTMLSourceAdapter {
    public let adapter: NativeSourceAdapter
    public let origin: URL
    private let http = HTTPClient()
    public static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"

    public init(site: SourceSite) throws {
        guard let adapter = site.nativeAdapter, [.dm84, .libvio].contains(adapter) else { throw ViewerError.message("没有对应的网站适配。") }
        self.adapter = adapter
        if adapter == .dm84 { origin = URL(string: "https://dm84.tv")! }
        else {
            var base = "https://www.libvio.pw"
            if let value = site.extensionValue, let data = value.data(using: .utf8),
               let ext = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let candidate = ext["siteUrl"] as? String, let url = HTTPAddress.optional(candidate) { base = url.absoluteString }
            origin = try HTTPAddress.parse(base)
        }
    }

    public var headers: [String: String] { ["User-Agent": Self.userAgent, "Referer": origin.absoluteString + "/"] }

    public func page(category: String?, search: String?, page: Int) async throws -> VideoPage {
        let requested = max(1, page)
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: true)!
        let query = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !query.isEmpty {
            components.path = adapter == .dm84 ? "/s----------.html" : "/index.php/ajax/suggest"
            components.queryItems = [URLQueryItem(name: "wd", value: query)]
            if adapter == .libvio { components.queryItems! += [URLQueryItem(name: "mid", value: "1"), URLQueryItem(name: "limit", value: "50")] }
        } else if let category, !category.isEmpty {
            guard category.allSatisfy(\.isNumber), category.count < 6 else { throw ViewerError.message("分类编号无效。") }
            components.path = adapter == .dm84 ? "/show-\(category)--time----\(requested).html" : "/show/\(category)--time------\(requested)---.html"
        } else if requested > 1 {
            components.path = adapter == .dm84 ? "/show-1--time----\(requested).html" : "/show/1--time------\(requested)---.html"
        }
        let (data, finalURL) = try await http.data(from: components.url!, headers: headers)
        if adapter == .libvio && !query.isEmpty {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ViewerError.message("搜索接口没有返回 JSON。") }
            let list = (root["list"] as? [[String: Any]] ?? []).map { row in
                ["vod_id": JSONValue.text(row["id"]), "vod_name": JSONValue.text(row["name"]), "vod_pic": JSONValue.text(row["pic"])]
            }
            return TVAPIClient.decodePage(["list": list], baseURL: finalURL)
        }
        return try Self.decodePage(data, adapter: adapter, baseURL: finalURL, page: requested, allowPagination: query.isEmpty)
    }

    public func detail(id: String) async throws -> Video {
        let clean = id.replacingOccurrences(of: ".html", with: "")
        guard !clean.isEmpty, clean.allSatisfy(\.isNumber), clean.count < 16 else { throw ViewerError.message("内容编号无效。") }
        let path = adapter == .dm84 ? "/v/\(clean).html" : "/detail/\(clean).html"
        let url = origin.appendingPathComponent(path)
        let (data, finalURL) = try await http.data(from: url, headers: headers)
        return try Self.decodeDetail(data, adapter: adapter, baseURL: finalURL, id: id)
    }

    public func resolve(episode: Episode, title: String, group: String) async throws -> MediaLink {
        let url = try HTTPAddress.parse(episode.value, relativeTo: origin)
        guard url.host == origin.host else { throw ViewerError.message("选集地址与来源不匹配。") }
        let (data, finalURL) = try await http.data(from: url, headers: headers)
        let doc = try document(data, baseURL: finalURL)
        if let video = try doc.select("video[src], video source[src]").first(), let direct = HTTPAddress.optional(try video.attr("src"), relativeTo: finalURL), HTTPAddress.isMedia(direct.absoluteString) {
            return MediaLink(title: title, url: direct.absoluteString, headers: headers, group: group)
        }
        // 页面中的脚本/播放器交给本机 WebKit，保留网页原有访问流程。
        return MediaLink(title: title, url: finalURL.absoluteString, headers: headers, group: group, kind: .web)
    }

    static func decodePage(_ data: Data, adapter: NativeSourceAdapter, baseURL: URL, page: Int, allowPagination: Bool = true) throws -> VideoPage {
        let doc = try document(data, baseURL: baseURL)
        let nodes = try doc.select(adapter == .dm84 ? "div.item" : "ul.stui-vodlist > li")
        let nav = try doc.select(adapter == .dm84 ? "ul.nav_row a[href^=/list-]" : "ul.stui-header__menu a[href*=/type/]")
        var categories: [VideoCategory] = []
        for node in nav.array() {
            if let id = firstCapture(#"(?:list-|/type/)(\d+)"#, in: try node.attr("href")) {
                categories.append(VideoCategory(id: id, name: try node.text()))
            }
        }
        if categories.isEmpty {
            categories = adapter == .dm84 ? [VideoCategory(id: "1", name: "国漫"), VideoCategory(id: "2", name: "日漫"), VideoCategory(id: "3", name: "欧美动漫"), VideoCategory(id: "4", name: "电影")] : [VideoCategory(id: "1", name: "电影"), VideoCategory(id: "2", name: "剧集")]
        }
        var seen = Set<String>()
        var videos: [Video] = []
        for item in nodes.array() {
            guard let link = try item.select(adapter == .dm84 ? "a.title" : "a[href*=/detail/]").first(),
                  let id = firstCapture(adapter == .dm84 ? #"/v/(\d+\.html)"# : #"/detail/(\d+)\.html"#, in: try link.attr("href")), seen.insert(id).inserted else { continue }
            let cover = try item.select(adapter == .dm84 ? "a.cover" : "a[data-original],img").first()
            let image = try cover?.attr(adapter == .dm84 ? "data-bg" : "data-original") ?? ""
            let label = try link.text()
            let name = label.isEmpty ? try link.attr("title") : label
            videos.append(Video(id: id, title: name, poster: HTTPAddress.optional(image, relativeTo: baseURL)?.absoluteString ?? "", note: try item.select(adapter == .dm84 ? "span.desc" : "span.pic-text").text(), summary: "", playFrom: "", playURL: ""))
        }
        let pageText = try doc.text()
        if videos.isEmpty && (pageText.contains("验证") || pageText.contains("Access denied") || pageText.contains("Just a moment")) {
            throw ViewerError.message("网站要求在浏览器中验证，暂时无法自动读取。")
        }
        let hasMore = try doc.select("a").array().contains { node in
            let label = try node.text()
            let href = try node.attr("href")
            return label.contains("下一页") && href != "javascript:;"
        }
        return VideoPage(categories: categories, videos: videos, page: page, pageCount: allowPagination && hasMore ? page + 1 : page)
    }

    static func decodeDetail(_ data: Data, adapter: NativeSourceAdapter, baseURL: URL, id: String) throws -> Video {
        let doc = try document(data, baseURL: baseURL)
        let title = try doc.select(adapter == .dm84 ? "h1.v_title" : "h1").first()?.text() ?? ""
        guard !title.isEmpty else { throw ViewerError.message("详情页面没有返回标题，可能需要在浏览器中验证。") }
        let metadataPoster = try doc.select("meta[property=og:image]").attr("content")
        let poster = metadataPoster.isEmpty ? try doc.select(".stui-content__thumb img[data-original]").attr("data-original") : metadataPoster
        let summary = try doc.select(adapter == .dm84 ? "meta[property=og:description]" : ".detail-content").first()
        let summaryText = adapter == .dm84 ? (try summary?.attr("content") ?? "") : (try summary?.text() ?? "")
        let tabs = try doc.select(adapter == .dm84 ? "ul.tab_control li" : "div.stui-pannel__head h3")
        let lists = try doc.select(adapter == .dm84 ? "ul.play_list" : "ul.stui-content__playlist")
        var names: [String] = [], values: [String] = []
        for (index, list) in lists.array().enumerated() {
            var episodes: [String] = []
            for link in try list.select("a[href]").array() {
                let target = try HTTPAddress.parse(link.attr("href"), relativeTo: baseURL)
                guard target.host == baseURL.host else { continue }
                let name = try link.text().replacingOccurrences(of: "$", with: " ").replacingOccurrences(of: "#", with: " ")
                episodes.append((name.isEmpty ? "播放" : name) + "$" + target.absoluteString)
            }
            if !episodes.isEmpty {
                names.append(index < tabs.size() ? try tabs.get(index).text() : "线路 \(index + 1)")
                values.append(episodes.joined(separator: "#"))
            }
        }
        return Video(id: id, title: title, poster: HTTPAddress.optional(poster, relativeTo: baseURL)?.absoluteString ?? "", note: "", summary: summaryText, playFrom: names.joined(separator: "$$$"), playURL: values.joined(separator: "$$$"))
    }

    private static func document(_ data: Data, baseURL: URL) throws -> Document {
        guard let html = String(data: data, encoding: .utf8) else { throw ViewerError.message("网页编码不受支持。") }
        return try SwiftSoup.parse(html, baseURL.absoluteString)
    }

    private func document(_ data: Data, baseURL: URL) throws -> Document { try Self.document(data, baseURL: baseURL) }

    private static func firstCapture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}

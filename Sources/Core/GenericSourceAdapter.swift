import Foundation
import SwiftSoup

/// 数据驱动的采集规则。规则来源只有两个：
/// 1. 配置条目自带的 ios / iMovie 规则；
/// 2. 现场从配置指定的 spider 插件里静态解出来的规则。
/// 代码里不保存任何站点域名或站点专用路径。
public struct GenericSourceRule: Codable, Hashable {
    public var baseURL: String
    public var mode: String? = nil // auto / html / json
    public var searchURL: String? = nil
    public var categoryURL: String? = nil
    public var detailURL: String? = nil
    public var playerURL: String? = nil
    public var listSelector: String? = nil
    public var titleSelector: String? = nil
    public var linkSelector: String? = nil
    public var posterSelector: String? = nil
    public var noteSelector: String? = nil
    public var categorySelector: String? = nil
    public var detailTitleSelector: String? = nil
    public var summarySelector: String? = nil
    public var lineSelector: String? = nil
    public var episodeSelector: String? = nil
    public var headers: [String: String]? = nil
    public init(baseURL: String) { self.baseURL = baseURL }
}

public struct GenericSourceAdapter {
    public let site: SourceSite
    private let http = HTTPClient()
    public init(site: SourceSite) { self.site = site }

    /// 插件里的选择器常写成 TVBox 风格：`h2 a@href`、`a.pic img@src`。
    /// SwiftSoup 只认纯 CSS，把 `@属性` 拆出来单独取，避免整条规则失效。
    struct SelectorSpec {
        var css: String
        var attribute: String?

        static func parse(_ raw: String?) -> SelectorSpec? {
            guard let raw else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let at = text.lastIndex(of: "@"), at > text.startIndex {
                let css = String(text[text.startIndex..<at]).trimmingCharacters(in: .whitespaces)
                let attribute = String(text[text.index(after: at)...]).trimmingCharacters(in: .whitespaces)
                if !css.isEmpty, !attribute.isEmpty, !attribute.contains(" "), !attribute.contains("[") {
                    return SelectorSpec(css: css, attribute: attribute)
                }
            }
            return SelectorSpec(css: text, attribute: nil)
        }
    }

    static let defaultLinkSelectors = "h2 a[href], h3 a[href], h4 a[href], a.title[href], a.module-poster-item[href], a[href]"
    static let defaultEpisodeContainers = "ul.episode-list,ul.play_list,ul.stui-content__playlist,ul.myui-content__playlist,.module-play-list,.play-list,.anthology-list-play,.playlist"

    public static func embeddedRule(_ value: Any?) -> GenericSourceRule? {
        guard let value else { return nil }
        let object: Any
        if let text = value as? String, let data = text.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data) { object = decoded }
        else { object = value }
        guard var root = object as? [String: Any] else { return nil }
        if let nested = root["ios"] as? [String: Any] ?? root["iMovie"] as? [String: Any] { root = nested }
        if root["baseURL"] == nil { root["baseURL"] = root["siteUrl"] ?? root["homeUrl"] ?? root["host"] }
        guard let base = root["baseURL"] as? String, HTTPAddress.optional(base) != nil,
              let data = try? JSONSerialization.data(withJSONObject: root) else { return nil }
        return try? JSONDecoder().decode(GenericSourceRule.self, from: data)
    }

    /// 规则解析顺序：配置自带 → JSON 接口 → 从插件静态解出。
    public func rule() async throws -> GenericSourceRule {
        if let rule = site.genericRule, HTTPAddress.optional(rule.baseURL) != nil { return rule }
        if let ext = site.extensionValue {
            if let rule = Self.embeddedRule(ext) { return rule }
            if let data = Data(base64Encoded: ext), let text = String(data: data, encoding: .utf8),
               let rule = Self.embeddedRule(text) { return rule }
        }
        switch site.runtime {
        case .jsonAPI:
            if let url = HTTPAddress.optional(site.api) { return GenericSourceRule(baseURL: url.absoluteString) }
            throw ViewerError.message("这个来源的接口地址无效。")
        case .javascript:
            throw ViewerError.message("这是 drpy 等脚本源，当前版本没有脚本运行时，无法直接采集。")
        case .unsupported:
            throw ViewerError.message("配置条目里没有可识别为采集器或接口的地址。")
        case .plugin:
            return try await GuardRuleCatalog.shared.rule(api: site.api, ext: site.extensionValue,
                                                          spider: SpiderSource.shared.url)
        }
    }

    private func headers(_ rule: GenericSourceRule) -> [String: String] {
        var headers = ["User-Agent": BrowserProfile.userAgent, "Referer": rule.baseURL]
        rule.headers?.forEach { headers[$0.key] = $0.value }
        return headers
    }

    public func page(category: String?, search: String?, page: Int) async throws -> VideoPage {
        let rule = try await rule(), origin = try HTTPAddress.parse(rule.baseURL)
        let term = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isJSON = rule.mode == "json" || (rule.mode != "html" && (origin.path.contains("/api") || origin.pathExtension == "php"))
        var urls: [URL] = []
        let explicitTemplate = !term.isEmpty ? rule.searchURL : (category?.isEmpty == false ? rule.categoryURL : nil)
        if let template = explicitTemplate {
            urls = [try Self.expand(template, base: origin, query: term, page: page, category: category ?? "")]
        } else if isJSON {
            var query = ["ac": "detail", "pg": String(max(1, page))]
            if !term.isEmpty { query["wd"] = term }
            if let category, !category.isEmpty { query["t"] = category }
            urls = [try Self.queryURL(origin, values: query)]
        } else if !term.isEmpty {
            throw ViewerError.message("这个来源没有解出搜索地址。可在“来源规则”里补一条带 {query} 的搜索模板。")
        } else if let category, !category.isEmpty {
            let template = rule.categoryURL ?? "{category}"
            urls = [try Self.expand(template, base: origin, page: page, category: category)]
        } else { urls = [origin] }

        var lastError: Error?
        for url in urls {
            try Task.checkCancellation()
            do {
                var (data, final) = try await http.data(from: url, headers: headers(rule), cacheLifetime: term.isEmpty ? 180 : 0)
                if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["list"] != nil {
                    return TVAPIClient.decodePage(root, baseURL: final)
                }
                // 规则没有页码占位时，按站点自己的“下一页”链接翻页。
                if page > 1 && !(explicitTemplate?.contains("{page}") ?? false) {
                    var visited = Set([final.absoluteString])
                    guard page <= 50 else { throw ViewerError.message("通用分页超过 50 页，请设置含 {page} 的地址模板。") }
                    for _ in 1..<page {
                        try Task.checkCancellation()
                        guard let next = try Self.nextPageURL(data, baseURL: final), visited.insert(next.absoluteString).inserted else {
                            throw ViewerError.message("来源没有提供下一页地址，请设置含 {page} 的分类 / 搜索模板。")
                        }
                        (data, final) = try await http.data(from: next, headers: headers(rule), cacheLifetime: term.isEmpty ? 180 : 0)
                    }
                }
                let result = try Self.decodePage(data, baseURL: final, rule: rule, page: page)
                if !result.videos.isEmpty || urls.count == 1 { return result }
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        if let lastError { throw lastError }
        throw ViewerError.message("已按解出的规则请求来源，没有读到匹配内容。可在来源规则里调整选择器。")
    }

    public func detail(id: String) async throws -> Video {
        let rule = try await rule(), base = try HTTPAddress.parse(rule.baseURL)
        let url: URL
        if let template = rule.detailURL { url = try Self.expand(template, base: base, id: id) }
        else if rule.mode == "json" || (rule.mode != "html" && (base.path.contains("/api") || base.pathExtension == "php")) {
            url = try Self.queryURL(base, values: ["ac": "detail", "ids": id])
        } else { url = try HTTPAddress.parse(id, relativeTo: base) }
        let (data, final) = try await http.data(from: url, headers: headers(rule))
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["list"] != nil,
           let video = TVAPIClient.decodePage(root, baseURL: final).videos.first { return video }
        return try Self.decodeDetail(data, baseURL: final, rule: rule, id: id)
    }

    public func resolve(episode: Episode, title: String, group: String) async throws -> MediaLink {
        let rule = try await rule(), base = try HTTPAddress.parse(rule.baseURL)
        let url = try rule.playerURL.map { try Self.expand($0, base: base, id: episode.value) } ?? HTTPAddress.parse(episode.value, relativeTo: base)
        return MediaLink(title: title, url: url.absoluteString, headers: headers(rule), group: group, kind: HTTPAddress.isMedia(url.absoluteString) ? .direct : .web)
    }

    static func decodePage(_ data: Data, baseURL: URL, rule: GenericSourceRule, page: Int) throws -> VideoPage {
        let doc = try document(data, base: baseURL)
        let selector = rule.listSelector ?? "li[data-href], .carousel-item, .stui-vodlist > li, .myui-vodlist > li, .module-items .module-item, .public-list-box, .hl-vod-list > li, .vodlist > li, .fed-list-item, .module-search-item, div.item"
        var seen = Set<String>(), videos: [Video] = []
        let linkSpec = selectorSpec(rule.linkSelector, fallback: defaultLinkSelectors, attribute: "href")
        let posterSpec = selectorSpec(rule.posterSelector, fallback: "img", attribute: nil)
        for item in try doc.select(selector).array() {
            guard let link = try item.select(linkSpec.css).first() else { continue }
            let href = try link.attr(linkSpec.attribute ?? "href")
            guard let url = HTTPAddress.optional(href, relativeTo: baseURL), sameSite(url, baseURL), seen.insert(url.absoluteString).inserted else { continue }
            let image = try item.select(posterSpec.css).first()
            var title = try text(rule.titleSelector, in: item, fallback: "h2,h3,h4,.title,.module-poster-item-title,.public-list-title")
            if title.isEmpty { title = try link.attr("title") }
            if title.isEmpty { title = try image?.attr("alt") ?? "" }
            if title.isEmpty { title = try link.text() }
            guard !title.isEmpty else { continue }
            let poster = try imageURL(image, fallback: item, base: baseURL)
            let note = try text(rule.noteSelector, in: item, fallback: ".hdtag,.pic-text,.module-item-note,.public-list-prb,.desc")
            videos.append(Video(id: url.absoluteString, title: title, poster: poster, note: note, summary: "", playFrom: "", playURL: ""))
        }
        var categoryIDs = Set<String>(), categories: [VideoCategory] = []
        for link in try doc.select(rule.categorySelector ?? "nav a[href], .nav a[href], .navbar a[href], .stui-header__menu a[href], .myui-header__menu a[href], .nav_row a[href]").array() {
            guard let url = HTTPAddress.optional(try link.attr("href"), relativeTo: baseURL), sameSite(url, baseURL), url.path != "/",
                  categoryIDs.insert(url.absoluteString).inserted else { continue }
            let name = try link.text()
            if !name.isEmpty && name.count < 15 { categories.append(VideoCategory(id: url.absoluteString, name: name)) }
        }
        let next = try nextPageURL(data, baseURL: baseURL) != nil
        if videos.isEmpty && categories.isEmpty { throw ViewerError.message("已连接来源，但规则没有识别出影片。可修改列表 / 标题选择器，或检查站点验证提示。") }
        return VideoPage(categories: categories, videos: videos, page: max(1, page), pageCount: next ? max(1, page) + 1 : max(1, page))
    }

    static func decodeDetail(_ data: Data, baseURL: URL, rule: GenericSourceRule, id: String) throws -> Video {
        let doc = try document(data, base: baseURL)
        let title = try text(rule.detailTitleSelector, in: doc, fallback: "h1.detail-title,h1.v_title,.stui-content__detail h1,.myui-content__detail h1,.module-info-heading h1,h1")
        guard !title.isEmpty else { throw ViewerError.message("规则未识别到影片标题，请设置详情标题选择器。") }
        var lists = try doc.select(rule.lineSelector ?? defaultEpisodeContainers).array()
        // 插件里的“线路”字符串有时是线路标题（如 div.card-header span b）而不是选集容器，
        // 这种元素里没有 <a>，此时退回标准选集容器，避免整页选集被判为空。
        let usable = lists.contains { element in
            guard let links = try? element.select("a[href]") else { return false }
            return !links.isEmpty
        }
        if !usable { lists = try doc.select(defaultEpisodeContainers).array() }
        var names: [String] = [], blocks: [String] = []
        let containers = lists.isEmpty ? [doc.body()].compactMap { $0 } : lists
        for (index, list) in containers.enumerated() {
            var seen = Set<String>(), episodes: [String] = []
            var links = try list.select(rule.episodeSelector ?? "a[href]").array()
            // episodeSelector 自带容器前缀（如 ul.episode-list li > a），在容器内部再选必然为空。
            if links.isEmpty { links = try list.select("a[href]").array() }
            for link in links {
                guard let url = HTTPAddress.optional(try link.attr("href"), relativeTo: baseURL), (sameSite(url, baseURL) || HTTPAddress.isMedia(url.absoluteString)), seen.insert(url.absoluteString).inserted else { continue }
                let label = try link.text().replacingOccurrences(of: "$", with: " ").replacingOccurrences(of: "#", with: " ")
                episodes.append((label.isEmpty ? "播放" : label) + "$" + url.absoluteString)
            }
            if !episodes.isEmpty { names.append("线路 \(index + 1)"); blocks.append(episodes.joined(separator: "#")) }
        }
        guard !blocks.isEmpty else { throw ViewerError.message("已读取详情，但没有找到选集。可设置选集 / 线路选择器；网盘、登录或磁力线路需要相应规则。") }
        let image = try doc.select(rule.posterSelector ?? ".detail-poster img,.stui-content__thumb img,.myui-content__thumb img,.module-info-poster img,meta[property=og:image]").first()
        let summary = try doc.select(rule.summarySelector ?? ".detail-info-body,.detail-content,.module-info-introduction,.vod_content,.content_desc,[property=og:description]").text()
        return Video(id: id, title: title, poster: try imageURL(image, fallback: nil, base: baseURL), note: "", summary: summary, playFrom: names.joined(separator: "$$$"), playURL: blocks.joined(separator: "$$$"))
    }

    static func selectorSpec(_ raw: String?, fallback: String, attribute: String?) -> SelectorSpec {
        if let spec = SelectorSpec.parse(raw) { return spec }
        return SelectorSpec(css: fallback, attribute: attribute)
    }

    /// 读取选择器命中的值：带 `@属性` 时取属性，取不到再退回文本。
    static func text(_ raw: String?, in scope: Element, fallback: String) throws -> String {
        let spec = selectorSpec(raw, fallback: fallback, attribute: nil)
        guard let element = try scope.select(spec.css).first() else { return "" }
        if let attribute = spec.attribute {
            let value = try element.attr(attribute)
            if !value.isEmpty { return value }
        }
        return try element.text()
    }

    private static func imageURL(_ element: Element?, fallback: Element?, base: URL) throws -> String {
        for node in [element, fallback].compactMap({ $0 }) {
            for key in ["data-original", "data-src", "data-bg", "src", "content"] {
                let value = try node.attr(key)
                if !value.isEmpty, let url = HTTPAddress.optional(value, relativeTo: base) { return url.absoluteString }
            }
        }
        return ""
    }
    static func nextPageURL(_ data: Data, baseURL: URL) throws -> URL? {
        let doc = try document(data, base: baseURL)
        for link in try doc.select("a[href], link[rel=next][href]").array() {
            let text = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let rel = try link.attr("rel").lowercased().split(separator: " ")
            let disabled = try link.attr("class").lowercased().contains("disabled") || link.attr("aria-disabled") == "true"
            let href = try link.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !disabled, rel.contains("next") || text.contains("下一页") || text == "下页" || text.lowercased() == "next",
                  !href.isEmpty, !href.hasPrefix("#"), let url = HTTPAddress.optional(href, relativeTo: baseURL), sameSite(url, baseURL),
                  url.absoluteString != baseURL.absoluteString, !url.path.isEmpty else { continue }
            return url
        }
        return nil
    }
    private static func sameSite(_ url: URL, _ base: URL) -> Bool {
        url.host?.lowercased().replacingOccurrences(of: "www.", with: "") == base.host?.lowercased().replacingOccurrences(of: "www.", with: "")
    }
    private static func document(_ data: Data, base: URL) throws -> Document {
        let text = String(decoding: data, as: UTF8.self)
        let doc = try SwiftSoup.parse(text, base.absoluteString)
        let label = try doc.text()
        if label.contains("验证码") || label.contains("Just a moment") || label.contains("Access denied") { throw ViewerError.message("来源要求网站验证或拒绝访问，请完成验证后重试。") }
        return doc
    }
    static func expand(_ template: String, base: URL, query: String = "", page: Int = 1, category: String = "", id: String = "") throws -> URL {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+#=?"))) ?? query
        let value = template.replacingOccurrences(of: "{query}", with: encodedQuery).replacingOccurrences(of: "{page}", with: String(max(1, page)))
            .replacingOccurrences(of: "{wd}", with: encodedQuery)
            .replacingOccurrences(of: "{category}", with: category).replacingOccurrences(of: "{id}", with: id)
            .replacingOccurrences(of: "{url}", with: id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+#=?"))) ?? id)
        return try HTTPAddress.parse(value, relativeTo: base)
    }
    private static func queryURL(_ url: URL, values: [String: String]) throws -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []).filter { values[$0.name] == nil } + values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let result = components.url else { throw ViewerError.message("来源接口地址无效。") }
        return result
    }
}

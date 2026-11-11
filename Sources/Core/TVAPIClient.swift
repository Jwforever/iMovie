import Foundation

public struct TVAPIClient {
    private let http = HTTPClient()
    public init() {}

    public func page(site: SourceSite, category: String? = nil, search: String? = nil, page: Int = 1) async throws -> VideoPage {
        if category?.isEmpty != false, search?.isEmpty != false, page == 1 {
            return try await home(site: site)
        }
        return try await loadPage(site: site, category: category, search: search, page: page)
    }

    /// TVBox home separates the categories document from optional home videos.
    public func home(site: SourceSite) async throws -> VideoPage {
        if site.nativeAdapter != nil { return try await loadPage(site: site, category: nil, search: nil, page: 1) }
        let root = try await object(site: site, query: site.type == 4 ? ["filter": "true"] : [:])
        let home = Self.decodePage(root, baseURL: try HTTPAddress.parse(site.api))
        if !home.videos.isEmpty { return home }
        let content = try await loadPage(site: site, category: home.categories.first?.id, search: nil, page: 1)
        return VideoPage(categories: home.categories.isEmpty ? content.categories : home.categories,
                         videos: content.videos, page: content.page, pageCount: content.pageCount)
    }

    private func loadPage(site: SourceSite, category: String?, search: String?, page: Int) async throws -> VideoPage {
        if site.nativeAdapter == .auete { return try await AueteAdapter().page(category: category, search: search, page: page) }
        if site.nativeAdapter == .tuxiaobei {
            return try await TuxiaobeiAdapter().page(category: category, search: search, page: page)
        }
        if site.nativeAdapter == .bilibili { return try await BilibiliAdapter(site: site).page(category: category, search: search, page: page) }
        if site.nativeAdapter == .dm84 || site.nativeAdapter == .libvio { return try await HTMLSourceAdapter(site: site).page(category: category, search: search, page: page) }
        var values = ["pg": String(page)]
        if site.type == 1 { values["ac"] = "detail" }
        if let category, !category.isEmpty { values["t"] = category; values["ac"] = "detail" }
        if let search, !search.isEmpty { values["wd"] = search; values["ac"] = "detail" }
        let root = try await object(site: site, query: values)
        return Self.decodePage(root, baseURL: try HTTPAddress.parse(site.api))
    }

    public func detail(site: SourceSite, id: String) async throws -> Video {
        if site.nativeAdapter == .auete { return try await AueteAdapter().detail(id: id) }
        if site.nativeAdapter == .tuxiaobei { return try await TuxiaobeiAdapter().detail(id: id) }
        if site.nativeAdapter == .bilibili { return try await BilibiliAdapter(site: site).detail(id: id) }
        if site.nativeAdapter == .dm84 || site.nativeAdapter == .libvio { return try await HTMLSourceAdapter(site: site).detail(id: id) }
        let root = try await object(site: site, query: ["ac": "detail", "ids": id])
        let page = Self.decodePage(root, baseURL: try HTTPAddress.parse(site.api))
        guard let video = page.videos.first else { throw ViewerError.message("接口没有返回影片详情。") }
        return video
    }

    public func resolve(site: SourceSite, episode: Episode, flag: String, title: String) async throws -> MediaLink {
        let candidate = try await resolveLink(site: site, episode: episode, flag: flag, title: title)
        var media = try await MediaResolver().resolve(candidate)
        media.reference = PlaybackReference(site: site, episode: episode, flag: flag)
        return media
    }

    private func resolveLink(site: SourceSite, episode: Episode, flag: String, title: String) async throws -> MediaLink {
        if site.nativeAdapter == .auete { return try await AueteAdapter().resolve(episode: episode, title: title, group: site.name) }
        if site.nativeAdapter == .bilibili { return try await BilibiliAdapter(site: site).resolve(episode: episode, title: title) }
        if site.nativeAdapter == .dm84 || site.nativeAdapter == .libvio { return try await HTMLSourceAdapter(site: site).resolve(episode: episode, title: title, group: site.name) }
        if site.nativeAdapter == .tuxiaobei {
            guard HTTPAddress.isMedia(episode.value) else { throw ViewerError.message("这个来源没有返回可直接播放的媒体地址。") }
            return MediaLink(title: title, url: episode.value, headers: TuxiaobeiAdapter.headers, group: site.name)
        }
        if HTTPAddress.isMedia(episode.value) {
            return MediaLink(title: title, url: episode.value, group: site.name)
        }
        guard site.type == 4 else {
            let url = try HTTPAddress.parse(episode.value)
            return MediaLink(title: title, url: url.absoluteString, group: site.name, kind: .web)
        }
        let root = try await object(site: site, query: ["play": episode.value, "flag": flag])
        let url = try HTTPAddress.parse(JSONValue.text(root["url"]))
        var headers = root["header"] as? [String: String] ?? [:]
        if let string = root["header"] as? String, let data = string.data(using: .utf8),
           let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            headers = dictionary
        }
        let needsResolution = JSONValue.integer(root["parse"]) != 0 || JSONValue.integer(root["jx"]) != 0
        return MediaLink(title: title, url: url.absoluteString, headers: headers, group: site.name, kind: needsResolution ? .web : .direct)
    }

    private func object(site: SourceSite, query: [String: String]) async throws -> [String: Any] {
        guard site.isNative else { throw ViewerError.message(site.runtime.explanation) }
        guard var components = URLComponents(url: try HTTPAddress.parse(site.api), resolvingAgainstBaseURL: true) else {
            throw ViewerError.message("接口地址无效。")
        }
        var items = components.queryItems ?? []
        items.removeAll { query.keys.contains($0.name) }
        items += query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        guard let url = components.url else { throw ViewerError.message("无法构造接口请求。") }
        let (data, _) = try await http.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ViewerError.message("接口没有返回 JSON 对象。")
        }
        return root
    }

    static func decodePage(_ root: [String: Any], baseURL: URL) -> VideoPage {
        let categories = (root["class"] as? [[String: Any]] ?? []).compactMap { item -> VideoCategory? in
            let id = JSONValue.text(item["type_id"])
            guard !id.isEmpty else { return nil }
            return VideoCategory(id: id, name: JSONValue.text(item["type_name"]))
        }
        var seen = Set<String>()
        let videos = (root["list"] as? [[String: Any]] ?? []).compactMap { item -> Video? in
            let id = JSONValue.text(item["vod_id"])
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let poster = JSONValue.text(item["vod_pic"])
            return Video(id: id, title: Self.clean(JSONValue.text(item["vod_name"])),
                         poster: poster.isEmpty ? "" : HTTPAddress.optional(poster, relativeTo: baseURL)?.absoluteString ?? "",
                         note: Self.clean(JSONValue.text(item["vod_remarks"])),
                         summary: Self.clean(JSONValue.text(item["vod_content"])),
                         playFrom: JSONValue.text(item["vod_play_from"]), playURL: JSONValue.text(item["vod_play_url"]))
        }
        return VideoPage(categories: categories, videos: videos,
                         page: max(1, JSONValue.integer(root["page"], default: 1)),
                         pageCount: max(1, JSONValue.integer(root["pagecount"], default: 1)))
    }

    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

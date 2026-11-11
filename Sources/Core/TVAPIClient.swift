import Foundation

public struct TVAPIClient {
    private let http = HTTPClient()
    public init() {}

    public func search(site: SourceSite, query: String) async throws -> [Video] {
        var videos: [Video] = [], seen = Set<String>()
        var failure: Error?
        for keyword in SearchRanking.queries(query) {
            try Task.checkCancellation()
            do {
                let result = try await page(site: site, search: keyword)
                videos += result.videos.filter { seen.insert($0.id).inserted }
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        if videos.isEmpty, let failure { throw failure }
        return videos.sorted { SearchRanking.score(title: $0.title, query: query) > SearchRanking.score(title: $1.title, query: query) }
    }

    public func page(site: SourceSite, category: String? = nil, search: String? = nil, page: Int = 1) async throws -> VideoPage {
        if category?.isEmpty != false, search?.isEmpty != false, page == 1 {
            return try await home(site: site)
        }
        return try await loadPage(site: site, category: category, search: search, page: page)
    }

    /// TVBox home 把分类文档和首页内容分开发，插件源直接读首页。
    public func home(site: SourceSite) async throws -> VideoPage {
        if site.isPlugin { return try await loadPage(site: site, category: nil, search: nil, page: 1) }
        let root = try await object(site: site, query: [:])
        let home = Self.decodePage(root, baseURL: try HTTPAddress.parse(site.api))
        if !home.videos.isEmpty { return home }
        let content = try await loadPage(site: site, category: home.categories.first?.id, search: nil, page: 1)
        return VideoPage(categories: home.categories.isEmpty ? content.categories : home.categories,
                         videos: content.videos, page: content.page, pageCount: content.pageCount)
    }

    private func loadPage(site: SourceSite, category: String?, search: String?, page: Int) async throws -> VideoPage {
        if site.isPlugin { return try await pluginPage(site: site, category: category, search: search, page: page) }
        var values = ["pg": String(page)]
        if let category, !category.isEmpty { values["t"] = category; values["ac"] = "detail" }
        if let search, !search.isEmpty { values["wd"] = search; values["ac"] = "detail" }
        let root = try await object(site: site, query: values)
        return Self.decodePage(root, baseURL: try HTTPAddress.parse(site.api))
    }

    public func detail(site: SourceSite, id: String) async throws -> Video {
        if site.isPlugin {
            // 插件自己解析（和 OK影视 同一份逻辑），规则只是兜底。
            do {
                let video = try await DalvikSourceAdapter(site: site).detail(id: id)
                if video.lines.isEmpty, let fallback = try? await GenericSourceAdapter(site: site).detail(id: id), !fallback.lines.isEmpty { return fallback }
                return video
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                let pluginError = error
                do { return try await GenericSourceAdapter(site: site).detail(id: id) }
                catch is CancellationError { throw CancellationError() }
                catch { throw Self.pluginFailure(pluginError, fallback: error) }
            }
        }
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
        if site.isPlugin {
            do { return try await DalvikSourceAdapter(site: site).resolve(episode: episode, flag: flag, title: title) }
            catch is CancellationError { throw CancellationError() }
            catch {
                let pluginError = error
                do { return try await GenericSourceAdapter(site: site).resolve(episode: episode, title: title, group: site.name) }
                catch is CancellationError { throw CancellationError() }
                catch { throw Self.pluginFailure(pluginError, fallback: error) }
            }
        }
        if HTTPAddress.isMedia(episode.value) {
            return MediaLink(title: title, url: episode.value, group: site.name)
        }
        guard site.runtime == .jsonAPI else {
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

    /// 插件源：先让插件自己跑（解释器），失败再退回静态规则。
    private func pluginPage(site: SourceSite, category: String?, search: String?,
                            page: Int) async throws -> VideoPage {
        do {
            return try await DalvikSourceAdapter(site: site)
                .page(category: category, search: search, page: page)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let pluginError = error
            NSLog("iMovie 插件解释器失败 %@: %@", site.name, error.localizedDescription)
            do {
                return try await GenericSourceAdapter(site: site)
                    .page(category: category, search: search, page: page)
            } catch is CancellationError { throw CancellationError() }
            catch { throw Self.pluginFailure(pluginError, fallback: error) }
        }
    }

    private static func pluginFailure(_ plugin: Error, fallback: Error) -> Error {
        ViewerError.message("插件执行失败：\(plugin.localizedDescription)\n网页兜底失败：\(fallback.localizedDescription)")
    }
}

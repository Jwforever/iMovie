import Foundation

/// 把插件自己产出的 JSON 翻成 iMovie 的模型。
///
/// 字段名就是 CatVod 的约定（vod_id / vod_name / vod_play_from / vod_play_url…），
/// 所以这里不做任何站点相关的猜测，插件给什么就用什么。
enum CatVodPayload {
    private static func text(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case .some(let other): return String(describing: other)
        case .none: return ""
        }
    }

    private static func dictionary(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func videos(_ list: Any?) -> [Video] {
        guard let items = list as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let id = text(item["vod_id"])
            let name = text(item["vod_name"])
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return Video(id: id, title: name,
                         poster: text(item["vod_pic"]),
                         note: text(item["vod_remarks"]),
                         summary: "",
                         playFrom: "", playURL: "")
        }
    }

    /// 首页 / 分类 / 搜索返回的列表结构。
    static func page(_ raw: String) -> VideoPage? {
        guard let root = dictionary(raw) else { return nil }
        var categories: [VideoCategory] = []
        if let classes = root["class"] as? [[String: Any]] {
            for item in classes {
                let id = text(item["type_id"])
                let name = text(item["type_name"])
                if !id.isEmpty, !name.isEmpty { categories.append(VideoCategory(id: id, name: name)) }
            }
        }
        let page = Int(text(root["page"])) ?? 1
        let pageCount = max(1, Int(text(root["pagecount"])) ?? 1)
        return VideoPage(categories: categories, videos: videos(root["list"]),
                         page: max(1, page), pageCount: pageCount)
    }

    /// 少数采集器把每集写成 `名称${playUrl=..., play_id=...}`（Java Map 的 toString），
    /// 需要在交给播放器前取出真正的地址。
    static func normalizePlayURL(_ raw: String) -> String {
        guard raw.contains("playUrl=") else { return raw }
        return raw.components(separatedBy: "#").map { entry -> String in
            let parts = entry.components(separatedBy: "$")
            guard parts.count >= 2, parts[1].hasPrefix("{") else { return entry }
            let body = parts[1]
            guard let range = body.range(of: "playUrl=") else { return entry }
            let rest = body[range.upperBound...]
            let value = rest.prefix { $0 != "," && $0 != "}" }.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return entry }
            return parts[0] + "$" + value
        }.joined(separator: "#")
    }

    /// 详情：插件把整条记录放在 list[0] 里。
    static func detail(_ raw: String) -> Video? {
        guard let root = dictionary(raw), let items = root["list"] as? [[String: Any]],
              let item = items.first else { return nil }
        let id = text(item["vod_id"])
        var name = text(item["vod_name"])
        // 有些采集器的详情只有选集、没有名称，不能因为缺标题就整条丢掉。
        if name.isEmpty { name = text(item["vod_play_from"]) }
        if name.isEmpty { name = id }
        guard !name.isEmpty else { return nil }
        let playFrom = text(item["vod_play_from"])
        var playURL = normalizePlayURL(text(item["vod_play_url"]))
        // 有些插件用 vod_play_list / vod_play_url_list 这种成对数组。
        if playURL.isEmpty, let list = item["vod_play_url_list"] as? [Any] {
            playURL = list.map { text($0) }.joined(separator: "$$$")
        }
        if playFrom.isEmpty, let list = item["vod_play_list"] as? [Any] {
            let names = list.map { entry -> String in
                if let dict = entry as? [String: Any] { return text(dict["name"]) }
                return text(entry)
            }
            return Video(id: id, title: name, poster: text(item["vod_pic"]),
                         note: text(item["vod_remarks"]), summary: text(item["vod_content"]),
                         playFrom: names.joined(separator: "$$$"), playURL: playURL)
        }
        return Video(id: id, title: name, poster: text(item["vod_pic"]),
                     note: text(item["vod_remarks"]), summary: text(item["vod_content"]),
                     playFrom: playFrom, playURL: playURL)
    }

    static func keys(in raw: String) -> [String] {
        dictionary(raw).map { $0.keys.sorted() } ?? []
    }

    /// 播放：`parse != 0` 表示给的是网页，需要再解析。
    static func playback(_ raw: String) -> (url: String, headers: [String: String], needsParsing: Bool)? {
        guard let root = dictionary(raw) else { return nil }
        // 不同插件对播放地址的键名不一致，按常见顺序找。
        var url = ""
        for key in ["url", "playUrl", "play_url", "vurl", "m3u8", "data", "src"] {
            if let value = root[key] as? String, !value.isEmpty { url = value; break }
            if let nested = root[key] as? [String: Any], let value = nested["url"] as? String, !value.isEmpty {
                url = value; break
            }
        }
        guard !url.isEmpty else { return nil }
        var headers: [String: String] = [:]
        if let map = root["header"] as? [String: String] {
            headers = map
        } else if let string = root["header"] as? String, let nested = dictionary(string) {
            for (key, value) in nested { headers[key] = text(value) }
        }
        let parse = Int(text(root["parse"])) ?? 0
        let jx = Int(text(root["jx"])) ?? 0
        return (url, headers, parse != 0 || jx != 0)
    }
}

/// 用解释器执行插件采集器，产出与 OK影视 相同的结果。
struct DalvikSourceAdapter {
    let site: SourceSite
    let spider: String?

    init(site: SourceSite, spider: String? = nil) {
        self.site = site
        self.spider = spider ?? SpiderSource.shared.url
    }

    func page(category: String?, search: String?, page: Int) async throws -> VideoPage {
        let term = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let result: DalvikRunResult
        if !term.isEmpty {
            result = try await DalvikSpider.run(spider: spider, api: site.api,
                                                action: .search(keyword: term),
                                                ext: site.extensionValue)
        } else if let category, !category.isEmpty {
            result = try await DalvikSpider.run(spider: spider, api: site.api,
                                                action: .category(id: category, page: String(page)),
                                                ext: site.extensionValue)
        } else {
            result = try await DalvikSpider.run(spider: spider, api: site.api,
                                                action: .home, ext: site.extensionValue)
        }
        guard let decoded = CatVodPayload.page(result.json) else {
            throw ViewerError.message("\(site.name)：插件返回的内容不是列表 JSON。")
        }
        if term.isEmpty, category?.isEmpty != false, decoded.videos.isEmpty, let first = decoded.categories.first {
            let content = try await DalvikSpider.run(spider: spider, api: site.api,
                action: .category(id: first.id, page: String(page)), ext: site.extensionValue)
            if let videos = CatVodPayload.page(content.json) {
                return VideoPage(categories: decoded.categories, videos: videos.videos, page: videos.page, pageCount: videos.pageCount)
            }
        }
        return decoded
    }

    func detail(id: String) async throws -> Video {
        let result = try await DalvikSpider.run(spider: spider, api: site.api,
                                                action: .detail(id: id),
                                                ext: site.extensionValue)
        guard let video = CatVodPayload.detail(result.json) else {
            throw ViewerError.message("\(site.name)：插件没有返回详情。")
        }
        return video
    }

    func resolve(episode: Episode, flag: String, title: String) async throws -> MediaLink {
        let result = try await DalvikSpider.run(spider: spider, api: site.api,
                                                action: .player(flag: flag, id: episode.value),
                                                ext: site.extensionValue)
        guard let playback = CatVodPayload.playback(result.json) else {
            let keys = CatVodPayload.keys(in: result.json).joined(separator: ",")
            throw ViewerError.message("\(site.name)：插件没有解出播放地址（返回字段：\(keys.isEmpty ? "空" : keys)）")
        }
        return MediaLink(title: title, url: playback.url, headers: playback.headers,
                         group: site.name, kind: playback.needsParsing ? .web : .direct)
    }
}

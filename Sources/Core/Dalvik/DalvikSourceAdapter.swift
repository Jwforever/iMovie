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

    /// 详情：插件把整条记录放在 list[0] 里。
    /// 标题/海报可能缺失（有些采集器只回选集），界面层会用列表页已知信息兜底；
    /// 这里绝不能拿 vod_play_from（线路名，常是"自动"）冒充片名。
    static func detail(_ raw: String) -> Video? {
        guard let root = dictionary(raw), let items = root["list"] as? [[String: Any]],
              let item = items.first else { return nil }
        let id = text(item["vod_id"])
        guard !id.isEmpty else { return nil }
        let name = text(item["vod_name"])
        let playFrom = text(item["vod_play_from"])
        // `vod_play_url` 必须原样交给插件。不少采集器故意把每集写成
        // `名称${key=value,...}`（Java Map 的 toString），`playerContent` 会自己
        // 把它反解回 Map；这里一旦"帮忙"提取成裸 URL，插件就取不到 play_id、
        // userlink 等签名参数，只能发出 p=null&v= 被站点拒绝。
        var playURL = text(item["vod_play_url"])
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
        // CatVod 生态里 `playerContent` 的 id 有两种约定：只给 `$` 后面的值，
        // 或给整条 `名称$值`。两种都是协议内形态，谁解出地址就用谁；不做站点判断。
        let candidates = [episode.value, "\(episode.title)$\(episode.value)"]
        var lastOutput = ""
        var lastError: Error?
        for identifier in candidates {
            let result: DalvikRunResult
            do {
                result = try await DalvikSpider.run(spider: spider, api: site.api,
                                                    action: .player(flag: flag, id: identifier),
                                                    ext: site.extensionValue)
            } catch {
                lastError = error
                continue
            }
            lastOutput = result.json
            if let playback = CatVodPayload.playback(result.json) {
                return MediaLink(title: title, url: playback.url, headers: playback.headers,
                                 group: site.name, kind: playback.needsParsing ? .web : .direct)
            }
        }
        let keys = CatVodPayload.keys(in: lastOutput).joined(separator: ",")
        let suffix = keys.isEmpty ? "空" : keys
        if let lastError { throw ViewerError.message("\(site.name)：插件调用失败（\(lastError.localizedDescription)）") }
        throw ViewerError.message("\(site.name)：插件没有解出播放地址（返回字段：\(suffix)）")
    }
}

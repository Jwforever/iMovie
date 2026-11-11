import Foundation
import SwiftSoup

/// Independent local implementation of the public Youlai first-aid video catalog.
public struct FirstAidAdapter {
    public static let origin = URL(string: "https://m.youlai.cn")!
    public static let categories = ["心肺复苏", "家庭急救", "急危重症", "意外伤害", "动物伤害", "户外急救", "中毒急救", "灾难事故"]
        .enumerated().map { VideoCategory(id: String($0.offset), name: $0.element) }
    private let http = HTTPClient()
    public init() {}
    private var headers: [String: String] { ["User-Agent": HTMLSourceAdapter.userAgent, "Referer": Self.origin.absoluteString + "/"] }

    public func page(category: String?, search: String?, page: Int) async throws -> VideoPage {
        // The current search endpoint returns no video catalog. Filter the public index locally.
        let (data, _) = try await http.data(from: Self.origin.appendingPathComponent("jijiu/"), headers: headers)
        return try Self.decodePage(data, category: category, search: search)
    }

    static func decodePage(_ data: Data, category: String?, search: String?) throws -> VideoPage {
        let doc = try SwiftSoup.parse(String(decoding: data, as: UTF8.self), origin.absoluteString)
        let blocks = try doc.select(".jj-title-li").array()
        guard !blocks.isEmpty else { throw ViewerError.message("急救视频目录暂时无法读取。") }
        var videos: [Video] = [], seen = Set<String>()
        for (index, block) in blocks.enumerated() {
            if let category, !category.isEmpty, category != String(index) { continue }
            for anchor in try block.select(".list-br3 a[href]").array() {
                guard let url = HTTPAddress.optional(try anchor.attr("href"), relativeTo: origin), url.host == origin.host,
                      url.path.hasPrefix("/jijiu/article/"), seen.insert(url.path).inserted else { continue }
                let title = try anchor.text()
                if let search, !search.isEmpty, !title.localizedCaseInsensitiveContains(search) { continue }
                videos.append(Video(id: url.path, title: title, poster: "", note: categories.indices.contains(index) ? categories[index].name : "急救教学",
                                    summary: "", playFrom: "", playURL: ""))
            }
        }
        return VideoPage(categories: categories, videos: videos, page: 1, pageCount: 1)
    }

    public func detail(id: String) async throws -> Video {
        let url = try HTTPAddress.parse(id, relativeTo: Self.origin)
        guard url.host == Self.origin.host, url.path.hasPrefix("/jijiu/article/"), url.query == nil else { throw ViewerError.message("影片地址与来源不匹配。") }
        let (data, _) = try await http.data(from: url, headers: headers)
        return try Self.decodeDetail(data, id: id)
    }

    static func decodeDetail(_ data: Data, id: String) throws -> Video {
        let doc = try SwiftSoup.parse(String(decoding: data, as: UTF8.self), origin.absoluteString)
        let title = try doc.select(".video-title.h1-title").text()
        guard !title.isEmpty else { throw ViewerError.message("来源没有返回视频详情。") }
        let picture = try doc.select(".video-cover.list-flex-in img").attr("src")
        let media = try doc.select("#video source[src], #video[src]").first()?.attr("src") ?? ""
        guard let url = HTTPAddress.optional(media, relativeTo: origin), HTTPAddress.isMedia(url.absoluteString) else { throw ViewerError.message("该教学条目没有返回公开视频链接。") }
        return Video(id: id, title: title, poster: HTTPAddress.optional(picture, relativeTo: origin)?.absoluteString ?? "", note: "急救教学",
                     summary: try doc.select(".img-text-con").text(), playFrom: "公开教学", playURL: "播放$" + url.absoluteString)
    }

    public func resolve(episode: Episode, title: String, group: String) throws -> MediaLink {
        guard HTTPAddress.isMedia(episode.value) else { throw ViewerError.message("没有公开视频链接。") }
        return MediaLink(title: title, url: episode.value, headers: headers, group: group, kind: .direct)
    }
}

import Foundation

public enum ViewerError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

public enum SourceRuntime: String, Codable {
    case jsonAPI, nativePort, android, javascript, unsupported

    public var title: String {
        switch self {
        case .jsonAPI: return "JSON 接口"
        case .nativePort: return "本机适配·实验"
        case .android: return "通用试配"
        case .javascript: return "脚本待适配"
        case .unsupported: return "暂未适配"
        }
    }

    public var explanation: String {
        switch self {
        case .jsonAPI: return "可尝试在本机浏览。播放仍取决于接口是否返回 iOS 支持的媒体地址。"
        case .nativePort: return "已为这个来源编写独立的 iOS 适配。应用直接请求对应网站，不执行 Android 爬虫；当前适配仍需要真机验证。"
        case .android: return "使用通用网页 / JSON 规则尝试采集。可补充来源地址和规则；运行时会显示具体错误，不执行 Android 插件。"
        case .javascript: return "这个源依赖 drpy 等宿主环境。当前版本尚未提供兼容的脚本引擎，无法直接搜索或解析。"
        case .unsupported: return "当前版本尚未实现这个接口格式。"
        }
    }
}

public struct SourceSite: Codable, Identifiable, Hashable {
    public var key: String
    public var name: String
    public var type: Int
    public var api: String
    public var searchable: Bool
    public var extensionValue: String? = nil
    public var genericRule: GenericSourceRule? = nil
    public var id: String { key }

    public var runtime: SourceRuntime {
        if genericRule != nil { return .android }
        if nativeAdapter != nil { return .nativePort }
        if api.lowercased().hasPrefix("csp_") { return .android }
        if let url = HTTPAddress.optional(api), url.path.lowercased().hasSuffix(".js") { return .javascript }
        if (type == 1 || type == 4), HTTPAddress.optional(api) != nil { return .jsonAPI }
        return .unsupported
    }

    public var isNative: Bool { runtime == .jsonAPI || runtime == .nativePort || usesGenericAdapter }
    public var usesGenericAdapter: Bool { genericRule != nil || (nativeAdapter == nil && api.lowercased().hasPrefix("csp_")) }

    public var nativeAdapter: NativeSourceAdapter? {
        NativeSourceAdapter.identify(type: type, api: api, extensionValue: extensionValue)
    }
}

public enum NativeSourceAdapter: String, Codable {
    case tuxiaobei, dm84, bilibili, libvio, auete, firstAid

    static func identify(type: Int, api: String, extensionValue: String?) -> NativeSourceAdapter? {
        if type == 3 {
            switch api {
            case "csp_Dm84Guard", "csp_Dm84": return .dm84
            case "csp_BiliGuard", "csp_Bili": return .bilibili
            case "csp_LibvioGuard", "csp_Libvio": return .libvio
            case "csp_AueteGuard", "csp_Auete": return .auete
            case "csp_FirstAidGuard", "csp_FirstAid": return .firstAid
            default: break
            }
        }
        guard type == 3, let apiURL = HTTPAddress.optional(api),
              apiURL.path.lowercased().hasSuffix(".js"),
              let extensionValue, let url = HTTPAddress.optional(extensionValue) else { return nil }
        let path = url.path.removingPercentEncoding ?? url.path
        let knownPaths = ["/fantaiying7/EXT/refs/heads/main/兔小贝.js", "/fantaiying7/EXT/main/兔小贝.js"]
        if url.host?.lowercased() == "raw.githubusercontent.com", knownPaths.contains(path) { return .tuxiaobei }
        if url.host?.lowercased() == "ghproxy.net", knownPaths.contains(where: { path == "/https://raw.githubusercontent.com" + $0 }) { return .tuxiaobei }
        return nil
    }
}

public struct LiveSource: Codable, Identifiable, Hashable {
    public var name: String
    public var url: String
    public var headers: [String: String]
    public var id: String { name + "|" + url }

    public var needsAndroidProxy: Bool {
        guard let host = HTTPAddress.optional(url)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
}

public struct SourceConfig: Codable {
    public var sites: [SourceSite]
    public var lives: [LiveSource]
    public var spider: String?
    public var importedAt: Date
    public var sourceURL: String
    public var nativeSites: [SourceSite] { sites.filter(\.isNative) }

    /// A site's keyword search is shared by its category-specific Bili entries.
    public var searchTargets: [SourceSearchTarget] {
        var groups: [SourceSearchTarget] = []
        var indexes: [String: Int] = [:]
        for site in nativeSites where site.searchable {
            let key = site.usesGenericAdapter ? "generic:" + site.key : site.nativeAdapter.map {
                "native:" + $0.rawValue + ($0 == .bilibili ? "" : "|" + (site.extensionValue ?? ""))
            } ?? "api:\(site.type):\(site.api)"
            if let index = indexes[key] { groups[index].aliases.append(site) }
            else {
                indexes[key] = groups.count
                groups.append(SourceSearchTarget(site: site, aliases: []))
            }
        }
        return groups
    }
}

public struct SourceSearchTarget: Identifiable, Hashable {
    public var site: SourceSite
    public var aliases: [SourceSite]
    public var id: String { site.id }
}

public struct MediaLink: Codable, Identifiable, Hashable {
    public var title: String
    public var url: String
    public var headers: [String: String]
    public var group: String
    public var kind: PlaybackKind? = nil
    public var reference: PlaybackReference? = nil
    public var id: String {
        if let reference { return reference.site.key + "|" + reference.episode.value + "|" + title }
        return url + "|" + title
    }

    public init(title: String, url: String, headers: [String: String] = [:], group: String = "", kind: PlaybackKind? = nil) {
        self.title = title
        self.url = url
        self.headers = headers
        self.group = group
        self.kind = kind
    }
}

public enum PlaybackKind: String, Codable {
    case direct, web
}

/// 保存来源和选集，重新打开收藏时刷新有时效的播放地址。
public struct PlaybackReference: Codable, Hashable {
    public var site: SourceSite
    public var episode: Episode
    public var flag: String
}

public struct VideoCategory: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
}

public struct Video: Codable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var poster: String
    public var note: String
    public var summary: String
    public var playFrom: String
    public var playURL: String
}

public struct VideoPage {
    public var categories: [VideoCategory]
    public var videos: [Video]
    public var page: Int
    public var pageCount: Int
}

public struct Episode: Codable, Identifiable, Hashable {
    public var title: String
    public var value: String
    public var id: String { title + "|" + value }
}

public struct EpisodeLine: Identifiable, Hashable {
    public var name: String
    public var episodes: [Episode]
    public var id: String { name + "|" + (episodes.first?.id ?? "") }
}

public extension Video {
    var lines: [EpisodeLine] {
        let names = playFrom.components(separatedBy: "$$$")
        return playURL.components(separatedBy: "$$$").enumerated().compactMap { index, block in
            let episodes = block.components(separatedBy: "#").enumerated().compactMap { offset, item -> Episode? in
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let fields = trimmed.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
                let title = fields.count == 2 ? String(fields[0]) : "第 \(offset + 1) 集"
                let value = String(fields.last ?? "")
                guard !value.isEmpty else { return nil }
                return Episode(title: title.isEmpty ? "第 \(offset + 1) 集" : title, value: value)
            }
            guard !episodes.isEmpty else { return nil }
            let name = index < names.count && !names[index].isEmpty ? names[index] : "线路 \(index + 1)"
            return EpisodeLine(name: name, episodes: episodes)
        }
    }
}

public enum HTTPAddress {
    public static func parse(_ value: String, relativeTo base: URL? = nil) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw ViewerError.message("请输入完整的 HTTP 或 HTTPS 地址。")
        }
        return url
    }

    public static func optional(_ value: String, relativeTo base: URL? = nil) -> URL? {
        try? parse(value, relativeTo: base)
    }

    public static func isMedia(_ value: String) -> Bool {
        guard let url = optional(value) else { return false }
        return ["m3u8", "mp4", "m4v", "mov", "m4a", "mp3", "aac"].contains(url.pathExtension.lowercased())
    }
}

enum JSONValue {
    static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    static func integer(_ value: Any?, default fallback: Int = 0) -> Int {
        Int(text(value)) ?? fallback
    }

    static func flag(_ value: Any?, default fallback: Bool = false) -> Bool {
        guard let value else { return fallback }
        if let bool = value as? Bool { return bool }
        return ["1", "2", "true"].contains(text(value).lowercased())
    }
}

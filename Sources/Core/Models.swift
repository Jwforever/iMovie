import Foundation

public enum ViewerError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

public enum SourceRuntime: String, Codable {
    case plugin, jsonAPI, javascript, unsupported

    public var title: String {
        switch self {
        case .plugin: return "本机插件解析"
        case .jsonAPI: return "JSON 接口"
        case .javascript: return "脚本待支持"
        case .unsupported: return "无法识别"
        }
    }

    public var explanation: String {
        switch self {
        case .plugin: return "在设备内解开配置指定的 spider 插件，优先解释执行采集器，失败时使用插件中提取的网页规则。"
        case .jsonAPI: return "直接读取配置里的 JSON 采集接口。"
        case .javascript: return "这个来源是 drpy 等脚本源，当前版本没有脚本运行时。"
        case .unsupported: return "配置条目里没有可识别为采集器或接口的地址。"
        }
    }
}

public struct SourceSite: Codable, Identifiable, Hashable {
    public var key: String
    public var name: String
    public var api: String
    public var searchable: Bool
    public var extensionValue: String? = nil
    public var genericRule: GenericSourceRule? = nil
    public var id: String { key }

    public var runtime: SourceRuntime {
        if api.lowercased().hasPrefix("csp_") { return .plugin }
        if let url = HTTPAddress.optional(api), url.path.lowercased().hasSuffix(".js") { return .javascript }
        if HTTPAddress.optional(api) != nil { return .jsonAPI }
        return .unsupported
    }

    /// csp_AueteGuard → Auete
    public var pluginClassName: String? {
        let value = api.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("csp_") else { return nil }
        var name = String(value.dropFirst(4))
        if name.hasSuffix("Guard") { name = String(name.dropLast(5)) }
        return name.isEmpty ? nil : name
    }

    public var isNative: Bool { runtime == .plugin || runtime == .jsonAPI }
    public var isPlugin: Bool { runtime == .plugin }
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

    /// A site's keyword search is shared by duplicate entries pointing at the same collector.
    public var searchTargets: [SourceSearchTarget] {
        var groups: [SourceSearchTarget] = []
        var indexes: [String: Int] = [:]
        for site in nativeSites where site.searchable {
            let key = site.pluginClassName.map { "plugin:" + $0 } ?? "api:\(site.api)"
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
    public var poster: String? = nil
    public var allowsInvalidCertificate: Bool? = nil
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

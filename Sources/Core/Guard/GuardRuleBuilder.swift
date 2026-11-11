import Foundation

/// 一个采集器类（站点）的静态情报。
struct GuardSiteProfile {
    var className: String
    var strings: [String]
    var methods: [String: [String]]
    var hosts: [String]
    var hasDomain: Bool { !hosts.isEmpty }
}

/// 把 DEX 里解出的字符串按方法归属拼成 iMovie 的采集规则。
/// 站点 key / 域名 / 选择器全部来自插件自身，代码里没有任何站点常量。
enum GuardRuleBuilder {
    private static let tldList = "com|cn|net|org|cc|tv|xyz|vip|top|me|io|app|co|site|club|fun|pro|info|"
        + "biz|pw|link|live|one|art|dev|shop|icu|cyou|ltd|wang|ren|la|hk|tw|in|su|us|"
        + "uk|life|eu|sbs|cfd|monster|online|store|tech|space|website|host|press|wiki|"
        + "to|ws|de|fr|jp|kr|ru|nl|se|pl"

    private static let hostPattern = regex("\\b((?:[a-z0-9][a-z0-9-]{0,30}\\.)+(?:" + tldList + "))\\b")
    private static let absoluteHostPattern = regex("^https?://[A-Za-z0-9.\\-]+(?::\\d+)?/?$")
    private static let regexMetaPattern = regex("\\\\[dswDSW()]|\\$\\d|\\[\\^")
    private static let selectorPattern = regex("^(?:[a-zA-Z][\\w-]*)?(?:[.#][\\w\\-]+)*(?:\\[[^\\]]+\\])?(?:\\s*>\\s*[\\w.#\\-\\[\\]=\\\"']+)*$")
    private static let titleHintPattern = regex("^(h\\d(\\s+a)?|a\\.title|\\.title|a)$", caseInsensitive: true)
    private static let listHintPattern = regex("(threadlist|item|list|vodlist|module-item|stui-vodlist|play_list|episode)", caseInsensitive: true)
    private static let pictureHintPattern = regex("img", caseInsensitive: true)
    private static let noteHintPattern = regex("(tag|note|remark|desc|hdtag|badge)", caseInsensitive: true)
    private static let detailTitlePattern = regex("(detail-title|v_title|title)", caseInsensitive: true)
    private static let summaryPattern = regex("(detail-des|desc|content|intro|summary)", caseInsensitive: true)
    private static let episodePattern = regex("(episode|play_list|playlist)", caseInsensitive: true)
    private static let linePattern = regex("(tab_control|card-header|play-from)", caseInsensitive: true)
    private static let trailingPagePattern = regex("(page|pg|p)=$")

    private static let noise = [
        "aliyun", "alipan", "github", "githubusercontent", "bilibili", "biliimg",
        "qq.com", "baidu", "douban", "weibo", "google", "gstatic", "googlesyndication",
        "apache", "java.", "android.", "androidx", "w3.org", "json.org", "sogoucdn",
        "imagehub", "servicewechat", "frodo.douban", "163.com", "snssdk", "cctv",
        "bdstatic", "cloudflare", "example", "apple.com", "schemas", "xml.org",
        "kotlin", "jetbrains", "okhttp", "squareup", "glide", "exoplayer",
        "material.io", "zhihu", "weixin", "tencent", "alicdn", "taobao", "jd.com",
        "kuaishou", "douyin", "bytedance", "umeng", "bugly", "crashlytics",
        "firebase", "facebook", "twitter", "telegram", "youtube", "w3schools",
        "mozilla", "jquery", "bootstrapcdn", "jsdelivr", "unpkg", "cdnjs",
        "moji.com", "huya.com", "douyu.com", "youlai.cn", "fqnovel", "rmb.bdstatic",
        "alidns", "nn.ci", "did", "oeqvv", "apple"
    ]

    static let tags: Set<String> = [
        "a", "img", "div", "ul", "ol", "li", "span", "p", "h1", "h2", "h3", "h4", "h5", "h6",
        "table", "tr", "td", "th", "dl", "dt", "dd", "form", "input", "button", "select",
        "option", "section", "article", "header", "footer", "nav", "em", "b", "i", "strong",
        "small", "label", "video", "iframe", "script", "body", "html", "main", "aside", "figure"
    ]

    // MARK: - 域名

    static func hosts(in strings: [String]) -> [String] {
        var found = Set<String>()
        for text in strings {
            let lower = text.lowercased()
            for host in matches(hostPattern, in: lower) where !isNoise(host) {
                found.insert(host)
            }
        }
        return found.sorted()
    }

    private static func isNoise(_ host: String) -> Bool {
        noise.contains { host.contains($0) }
    }

    // MARK: - 规则

    static func rule(for profile: GuardSiteProfile) -> GenericSourceRule? {
        let methods = profile.methods
        let home = methods["homeContent"] ?? []
        let category = methods["categoryContent"] ?? []
        let detail = methods["detailContent"] ?? []
        let search = methods["searchContent"] ?? []
        let initial = methods["<init>"] ?? []

        guard let base = pickHost(initial) ?? pickHost(home) else { return nil }
        var rule = GenericSourceRule(baseURL: base)
        rule.mode = "html"

        let listPool = category.isEmpty ? (home.isEmpty ? search : home) : category
        let selectors = listPool.filter(isSelector)
        var listSelector = selectors.first { matches(listHintPattern, $0) && !matches(pictureHintPattern, $0) }
        if listSelector == nil { listSelector = selectors.first { matches(listHintPattern, $0) } }
        if let listSelector { rule.listSelector = listSelector }

        let rest = selectors.filter { $0 != listSelector }
        if let title = rest.first(where: { matches(titleHintPattern, $0) }) {
            rule.titleSelector = title.lowercased().hasPrefix("h") ? title + "@title" : title
        }
        let picture = rest.first { matches(pictureHintPattern, $0) }
        if let picture {
            let attribute = rest.joined(separator: " ").contains("data-") ? "data-original" : "src"
            rule.posterSelector = picture + "@" + attribute
        }
        if let note = rest.first(where: { matches(noteHintPattern, $0) && !matches(pictureHintPattern, $0) }) {
            rule.noteSelector = note
        }
        let link = rest.first { ["a", "a.title", "h2 a", "h3 a"].contains($0) } ?? "a"
        rule.linkSelector = link + "@href"

        if let template = category.first(where: { text in
            (text.contains("%s") || text.contains("{")) && (text.contains("/list") || text.contains("-%s") || text.contains("index"))
        }) {
            rule.categoryURL = template
        }

        if let path = search.first(where: { text in
            (text.contains("searchword") || text.lowercased().contains("search") || text.contains("wd=")) && !isSelector(text)
        }) {
            let tail = search.first { ["&page=", "&pg=", "/page/", "&p="].contains($0) } ?? ""
            var template = path + tail
            template = template.replacingOccurrences(of: "searchword=", with: "searchword={wd}")
            template = template.replacingOccurrences(of: "wd=", with: "wd={wd}")
            if template.contains("{wd}") && (template.contains("page") || template.contains("pg=") || template.contains("p=")) {
                template = replace(trailingPagePattern, in: template, with: "$1={pg}")
            } else if template.contains("{wd}") {
                template += "{pg}"
            }
            rule.searchURL = template
        }

        let detailSelectors = detail.filter(isSelector)
        if let value = detailSelectors.first(where: { matches(detailTitlePattern, $0) && !matches(pictureHintPattern, $0) }) {
            rule.detailTitleSelector = value
        }
        if rule.posterSelector == nil, let value = detailSelectors.first(where: { matches(pictureHintPattern, $0) }) {
            rule.posterSelector = value + "@src"
        }
        if let value = detailSelectors.first(where: { matches(summaryPattern, $0) }) {
            rule.summarySelector = value
        }
        if let value = detailSelectors.first(where: { matches(episodePattern, $0) }) {
            rule.episodeSelector = value
        }
        if let value = detailSelectors.first(where: { matches(linePattern, $0) }) {
            rule.lineSelector = value
        }
        return rule
    }

    static func pickHost(_ strings: [String]) -> String? {
        for text in strings where matches(absoluteHostPattern, text) {
            var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            while value.hasSuffix("/") { value.removeLast() }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - 选择器判定

    static func isSelector(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 120 else { return false }
        if matches(absoluteHostPattern, text) || text.hasPrefix("http") { return false }
        if matches(regexMetaPattern, text) { return false }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == ">" }).map { String($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return false }
        for part in parts {
            if !matches(selectorPattern, part) { return false }
            let decorated = part.contains(".") || part.contains("#") || part.contains("[")
            if !decorated && !tags.contains(part.lowercased()) { return false }
        }
        if parts.count > 1 { return true }
        if text.contains(".") || text.contains("#") || text.contains("[") || text.contains(">") { return true }
        return tags.contains(text.lowercased())
    }

    // MARK: - 正则工具

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static func matches(_ expression: NSRegularExpression?, _ text: String) -> Bool {
        guard let expression, !text.isEmpty else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func matches(_ expression: NSRegularExpression?, in text: String) -> [String] {
        guard let expression else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }

    private static func replace(_ expression: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let expression else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

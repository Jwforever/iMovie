import Foundation

/// 一个插件包解析出来的全部站点情报。
final class GuardIndex {
    let source: String
    let profiles: [String: GuardSiteProfile]

    init(source: String, profiles: [String: GuardSiteProfile]) {
        self.source = source
        self.profiles = profiles
    }

    var siteCount: Int { profiles.values.filter(\.hasDomain).count }
}

/// 插件 → DEX → 站点规则的运行时目录。
///
/// 域名、搜索模板、选择器全部现场从配置指定的 spider 包里解出来，
/// 换域名只需要重新导入配置，不需要重新编译 App。
public actor GuardRuleCatalog {
    public static let shared = GuardRuleCatalog()

    private var cachedSource: String?
    private var cachedIndex: GuardIndex?
    private var inFlight: Task<GuardIndex, Error>?

    public init() {}

    /// 从配置的 spider 字段里取出插件地址（去掉 ;md5; 校验段）。
    static func jarURL(from spider: String?) -> String? {
        guard let raw = spider?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let line = raw.components(separatedBy: .newlines).first ?? raw
        let address = line.components(separatedBy: ";md5;").first ?? line
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HTTPAddress.optional(trimmed) != nil else { return nil }
        return trimmed
    }

    /// 预热：导入配置后调用，解码失败不影响其他功能。
    public func prepare(spider: String?) async {
        _ = try? await index(spider: spider)
    }

    public func loadedProfileCount() -> Int { cachedIndex?.profiles.count ?? 0 }

    func index(spider: String?) async throws -> GuardIndex {
        guard let address = Self.jarURL(from: spider) else {
            throw ViewerError.message("配置里没有可用的插件地址（spider），无法在本机解析来源规则。")
        }
        if cachedSource == address, let cachedIndex { return cachedIndex }
        if let inFlight { return try await inFlight.value }

        let task = Task<GuardIndex, Error> { [address] in
            try await Self.build(address: address)
        }
        inFlight = task
        defer { inFlight = nil }
        let result = try await task.value
        cachedSource = address
        cachedIndex = result
        return result
    }

    /// 取某个来源的规则；`ext` / 配置自带 ios 规则由调用方优先处理。
    func rule(api: String, ext: String?, spider: String?) async throws -> GenericSourceRule {
        let index = try await index(spider: spider)
        guard let name = Self.className(fromAPI: api) else {
            throw ViewerError.message("\(api) 不是插件里的采集器条目。")
        }
        guard let profile = index.profiles[name] else {
            throw ViewerError.message("插件里没有找到采集器 \(name)。可以在“来源规则”里手动填写网站地址。")
        }
        guard let rule = GuardRuleBuilder.rule(for: profile) else {
            let hint = profile.strings.isEmpty
                ? "这个采集器的字符串一条也没解出来。"
                : "插件里这个采集器只带接口片段（\(profile.strings.count) 条字符串），没有写死网站域名——域名由插件在安卓端运行时才生成。"
            throw ViewerError.message("\(name)：\(hint)可以在“来源规则”里补一个可访问的网站地址，之后按通用网页规则采集。")
        }
        return rule
    }

    /// csp_AueteGuard → Auete；csp_SixV → SixV
    static func className(fromAPI api: String) -> String? {
        let value = api.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("csp_") else { return nil }
        var name = String(value.dropFirst(4))
        if name.hasSuffix("Guard") { name = String(name.dropLast(5)) }
        guard !name.isEmpty else { return nil }
        return name
    }

    // MARK: - 构建

    private static func build(address: String) async throws -> GuardIndex {
        let url = try HTTPAddress.parse(address)
        let dex = try await loadDex(url: url)
        let file = try DexFile(data: dex)
        return decode(file: file, source: address)
    }

    private static func loadDex(url: URL) async throws -> Data {
        let cached = cacheFile(for: url)
        if let data = try? Data(contentsOf: cached), GuardContainer.isDex([UInt8](data.prefix(4))) {
            return data
        }
        let (archive, _) = try await HTTPClient().data(from: url, headers: ["Accept": "*/*"])
        let dex = try GuardContainer.innerDex(from: archive)
        try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? dex.write(to: cached, options: .atomic)
        return dex
    }

    private static func cacheFile(for url: URL) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let name = url.lastPathComponent.isEmpty ? "spider.jar" : url.lastPathComponent
        return base.appendingPathComponent("GuardPlugins", isDirectory: true).appendingPathComponent(name + ".dex")
    }

    static func decode(file: DexFile, source: String) -> GuardIndex {
        let decoder = GuardStringDecoder(dex: file)
        decoder.collectTables()
        decoder.collectGetters()
        decoder.buildMethodIndex()

        var profiles: [String: GuardSiteProfile] = [:]
        for definition in file.classDefs() {
            guard definition.name.hasPrefix("Lcom/github/catvod/spider/"), definition.classDataOffset > 0 else { continue }
            let short = shortName(definition.name)
            guard !short.isEmpty else { continue }

            var methods: [String: [String]] = [:]
            var all: [String] = []
            var seen = Set<String>()
            for hit in decoder.decode(className: definition.name, classDataOffset: definition.classDataOffset) {
                if !(methods[hit.method]?.contains(hit.text) ?? false) {
                    methods[hit.method, default: []].append(hit.text)
                }
                if seen.insert(hit.text).inserted { all.append(hit.text) }
            }
            let own = decoder.ownArrays(definition.name)
            for method in file.classMethods(definition.classDataOffset) where method.codeOffset > 0 {
                let name = file.method(method.index).name
                var visited: Set<Int> = [method.index]
                let extra = decoder.reachableStrings(codeOffset: method.codeOffset, ownArrays: own, depth: 3, seen: &visited)
                for text in extra {
                    if !(methods[name]?.contains(text) ?? false) { methods[name, default: []].append(text) }
                    if seen.insert(text).inserted { all.append(text) }
                }
            }
            profiles[short] = GuardSiteProfile(className: short, strings: all, methods: methods,
                                               hosts: GuardRuleBuilder.hosts(in: all))
        }
        return GuardIndex(source: source, profiles: profiles)
    }

    private static func shortName(_ descriptor: String) -> String {
        var value = descriptor
        if value.hasPrefix("L") { value.removeFirst() }
        if value.hasSuffix(";") { value.removeLast() }
        if let slash = value.lastIndex(of: "/") { value = String(value[value.index(after: slash)...]) }
        return value
    }
}

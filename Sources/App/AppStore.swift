import Foundation
import SwiftUI

struct WatchRecord: Codable, Identifiable {
    var media: MediaLink
    var position: Double
    var updatedAt: Date
    var id: String { media.id }
}

struct PlaybackRequest: Identifiable {
    var id = UUID()
    var media: MediaLink
}

/// 一个来源最近一次实际拉取的结果。用来把真正能出内容的源排在前面，
/// 而不是让所有源按配置顺序平铺。
struct SourceHealth: Codable, Hashable {
    var ok: Bool
    var items: Int
    var at: Date

    /// 有内容 3，空列表 1，失败 0
    var rank: Int { ok ? (items > 0 ? 3 : 1) : 0 }
}

@MainActor
final class AppStore: ObservableObject {
    static let defaultConfigURL = "http://www.饭太硬.cc/tv"
    private let defaults: UserDefaults
    private let client = HTTPClient()
    @Published private(set) var config: SourceConfig?
    @Published private(set) var favorites: [MediaLink] = []
    @Published private(set) var history: [WatchRecord] = []
    @Published var configURL: String
    @Published var importing = false
    @Published private(set) var resolvingPlayback = false
    @Published var error: String?
    @Published var playback: PlaybackRequest?
    @Published private(set) var homeSourceKey: String
    @Published private(set) var health: [String: SourceHealth] = [:]
    /// 导入配置时定下来的固定顺序；界面只按它渲染，不随后台探测跳动。
    @Published private(set) var sourceOrder: [String] = []
    /// 导入后后台探测来源可用性，探测失败的源从列表里隐藏。
    @Published private(set) var probingSources = false
    @Published private(set) var hideFailedSources: Bool
    private var sourceRules: [String: GenericSourceRule]

    var homeSource: SourceSite? {
        guard let config else { return nil }
        return config.sites.first { $0.key == homeSourceKey }
            ?? config.nativeSites.first
            ?? config.sites.first
    }

    func selectHomeSource(_ site: SourceSite) {
        homeSourceKey = site.key
        defaults.set(site.key, forKey: "homeSourceKey")
        rebuildSourceOrder()
    }

    init(defaults: UserDefaults = .standard) {
        let storage: UserDefaults
        let initialConfigURL: String
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        storage = environment["IMOVIE_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? defaults
        initialConfigURL = environment["IMOVIE_CONFIG_URL"] ?? storage.string(forKey: "configURL") ?? Self.defaultConfigURL
        #else
        storage = defaults
        initialConfigURL = storage.string(forKey: "configURL") ?? Self.defaultConfigURL
        #endif
        self.defaults = storage
        configURL = initialConfigURL
        homeSourceKey = storage.string(forKey: "homeSourceKey") ?? ""
        config = Self.load(SourceConfig.self, key: "config", defaults: storage)
        favorites = Self.load([MediaLink].self, key: "favorites", defaults: storage) ?? []
        history = Self.load([WatchRecord].self, key: "history", defaults: storage) ?? []
        health = Self.load([String: SourceHealth].self, key: "sourceHealth", defaults: storage) ?? [:]
        sourceRules = Self.load([String: GenericSourceRule].self, key: "sourceRules", defaults: storage) ?? [:]
        sourceOrder = Self.load([String].self, key: "sourceOrder", defaults: storage) ?? []
        hideFailedSources = storage.object(forKey: "hideFailedSources") == nil ? true : storage.bool(forKey: "hideFailedSources")
        SpiderSource.shared.update(config?.spider)
        // 覆盖安装等场景配置是存量加载的，启动就把全部来源探一遍，
        // 让"只保留可用"尽快生效（12 小时内测成功的不重复测）。
        if config != nil {
            Task { await probeAllSources() }
        }
    }

    /// 记录来源最近一次真实拉取的结果，用来把能出内容的源排到前面。
    func recordHealth(_ key: String, ok: Bool, items: Int) {
        if let previous = health[key], previous.ok == ok, previous.items == items, Date().timeIntervalSince(previous.at) < 30 { return }
        health[key] = SourceHealth(ok: ok, items: items, at: Date())
        persist(health, key: "sourceHealth")
    }

    /// 3 有内容，2 未测过，1 拉到空列表，0 请求失败
    func rank(of site: SourceSite) -> Int { health[site.key]?.rank ?? 2 }

    func setHideFailedSources(_ value: Bool) {
        hideFailedSources = value
        defaults.set(value, forKey: "hideFailedSources")
    }

    /// 固定顺序下的来源列表，界面只读这个。
    /// 打开"只保留可用"时：探测失败的、探测成功但首页拉空的源都被隐藏
    /// （未测过的保留），默认源始终显示。
    var orderedSites: [SourceSite] {
        let sites = SourceOrdering.apply(order: sourceOrder, to: config?.sites ?? [])
        guard hideFailedSources else { return sites }
        let usable = sites.filter { site in
            if site.key == homeSourceKey { return true }
            guard let record = health[site.key] else { return true }
            return record.rank > 0 && record.items > 0
        }
        return usable.isEmpty ? sites : usable
    }

    /// 重算并保存顺序。只在导入配置、探测整批结束、切换默认源时调用，
    /// 保证列表不会在浏览过程中自己重排。
    func rebuildSourceOrder() {
        guard let config else { return }
        let ranks = config.sites.reduce(into: [String: Int]()) { result, site in
            result[site.key] = rank(of: site)
        }
        let ordered = SourceOrdering.arrange(config.sites, ranks: ranks, preferred: homeSource?.key)
        sourceOrder = ordered.map(\.key)
        persist(sourceOrder, key: "sourceOrder")
    }

    /// 试拉一个来源的首屏，结果写进 health，让列表能自己把可用的排上去。
    /// 原生接口与插件源都测：插件源走设备内解释器。
    func probe(_ site: SourceSite) async {
        do {
            let page = try await withTimeout(seconds: 40) { try await TVAPIClient().page(site: site, page: 1) }
            recordHealth(site.key, ok: true, items: page.videos.count)
        } catch is CancellationError {
        } catch {
            recordHealth(site.key, ok: false, items: 0)
        }
    }

    /// 导入后把全部来源探一遍；失败的记 0 分，配合"只保留可用"过滤掉。
    func probeAllSources() async {
        guard let config, !probingSources else { return }
        probingSources = true
        defer { probingSources = false }
        // 12 小时内刚测成功的不重复测，失败的和没测过的每次都测。
        let pending = config.sites.filter { site in
            guard let record = health[site.key], record.ok,
                  Date().timeIntervalSince(record.at) < 12 * 3600 else { return true }
            return false
        }
        let limit = 4
        var index = pending.startIndex
        while index < pending.endIndex {
            let chunk = pending[index..<min(index + limit, pending.endIndex)]
            await withTaskGroup(of: Void.self) { group in
                for site in chunk {
                    group.addTask { [weak self] in await self?.probe(site) }
                }
            }
            index += limit
        }
        rebuildSourceOrder()
    }

    /// 插件源探测没有内部超时，外面统一兜底，避免个别站点拖死整批。
    private func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ViewerError.message("来源探测超时")
            }
            guard let first = try await group.next() else {
                throw ViewerError.message("来源探测失败")
            }
            group.cancelAll()
            return first
        }
    }

    func importConfig() async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        do {
            var result = try await client.config(at: configURL)
            await GuardRuleCatalog.shared.refresh(spider: result.spider)
            DalvikSpider.resetFailures()
            persist(result, key: "importedConfig")
            for index in result.sites.indices {
                if let rule = sourceRules[result.sites[index].key] { result.sites[index].genericRule = rule }
            }
            config = result
            persist(result, key: "config")
            defaults.set(configURL, forKey: "configURL")
            // 顺序在导入时一次定好，之后不再随探测结果变化。
            rebuildSourceOrder()
            SpiderSource.shared.update(result.spider)
            // 后台把全部来源探一遍：失败的记 0 分，"只保留可用"会把它们隐藏。
            Task { await probeAllSources() }
            // 插件解析在后台预热：首屏按需触发，失败只影响单个来源。
            Task.detached { await GuardRuleCatalog.shared.prepare(spider: result.spider) }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    func saveRule(_ rule: GenericSourceRule?, for site: SourceSite) {
        sourceRules[site.key] = rule
        persist(sourceRules, key: "sourceRules")
        if var config, let index = config.sites.firstIndex(where: { $0.key == site.key }) {
            let imported = Self.load(SourceConfig.self, key: "importedConfig", defaults: defaults)
            config.sites[index].genericRule = rule ?? imported?.sites.first { $0.key == site.key }?.genericRule
            self.config = config
            persist(config, key: "config")
        }
    }

    func play(_ media: MediaLink, refresh: Bool = true) {
        if refresh, let reference = media.reference {
            guard !resolvingPlayback else { return }
            resolvingPlayback = true
            Task {
                defer { resolvingPlayback = false }
                do {
                    let site = config?.sites.first { $0.key == reference.site.key } ?? reference.site
                    var updated = try await TVAPIClient().resolve(site: site, episode: reference.episode, flag: reference.flag, title: media.title)
                    updated.poster = media.poster
                    play(updated, refresh: false)
                } catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
            return
        }
        do {
            _ = try HTTPAddress.parse(media.url)
            playback = PlaybackRequest(media: media)
        } catch { self.error = error.localizedDescription }
    }

    func isFavorite(_ media: MediaLink) -> Bool { favorites.contains { $0.id == media.id } }

    func toggleFavorite(_ media: MediaLink) {
        if isFavorite(media) { favorites.removeAll { $0.id == media.id } }
        else { favorites.insert(media, at: 0) }
        persist(favorites, key: "favorites")
    }

    func position(for media: MediaLink) -> Double { history.first { $0.id == media.id }?.position ?? 0 }

    func record(_ media: MediaLink, position: Double) {
        let safe = position.isFinite && position > 0 ? position : 0
        history.removeAll { $0.id == media.id }
        history.insert(WatchRecord(media: media, position: safe, updatedAt: Date()), at: 0)
        history = Array(history.prefix(100))
        persist(history, key: "history")
    }

    func clearHistory() { history = []; defaults.removeObject(forKey: "history") }

    func deleteHistory(_ offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persist(history, key: "history")
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

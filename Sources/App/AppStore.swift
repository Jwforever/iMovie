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
        SpiderSource.shared.update(config?.spider)
    }

    /// 记录来源最近一次真实拉取的结果，用来把能出内容的源排到前面。
    func recordHealth(_ key: String, ok: Bool, items: Int) {
        if let previous = health[key], previous.ok == ok, previous.items == items, Date().timeIntervalSince(previous.at) < 30 { return }
        health[key] = SourceHealth(ok: ok, items: items, at: Date())
        persist(health, key: "sourceHealth")
    }

    /// 3 有内容，2 未测过，1 拉到空列表，0 请求失败
    func rank(of site: SourceSite) -> Int { health[site.key]?.rank ?? 2 }

    func importConfig() async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        do {
            var result = try await client.config(at: configURL)
            persist(result, key: "importedConfig")
            for index in result.sites.indices {
                if let rule = sourceRules[result.sites[index].key] { result.sites[index].genericRule = rule }
            }
            config = result
            persist(result, key: "config")
            defaults.set(configURL, forKey: "configURL")
            SpiderSource.shared.update(result.spider)
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

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

    var homeSource: SourceSite? {
        guard let config else { return nil }
        return config.sites.first { $0.key == homeSourceKey }
            ?? config.nativeSites.first { $0.nativeAdapter == .dm84 }
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
    }

    func importConfig() async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        do {
            let result = try await client.config(at: configURL)
            config = result
            persist(result, key: "config")
            defaults.set(configURL, forKey: "configURL")
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    func play(_ media: MediaLink, refresh: Bool = true) {
        if refresh, let reference = media.reference {
            guard !resolvingPlayback else { return }
            resolvingPlayback = true
            Task {
                defer { resolvingPlayback = false }
                do {
                    let updated = try await TVAPIClient().resolve(site: reference.site, episode: reference.episode, flag: reference.flag, title: media.title)
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

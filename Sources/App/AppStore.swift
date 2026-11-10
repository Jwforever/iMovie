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
    @Published var error: String?
    @Published var playback: PlaybackRequest?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configURL = defaults.string(forKey: "configURL") ?? Self.defaultConfigURL
        config = Self.load(SourceConfig.self, key: "config", defaults: defaults)
        favorites = Self.load([MediaLink].self, key: "favorites", defaults: defaults) ?? []
        history = Self.load([WatchRecord].self, key: "history", defaults: defaults) ?? []
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

    func play(_ media: MediaLink) {
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

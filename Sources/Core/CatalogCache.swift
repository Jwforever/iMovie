import Foundation
import CryptoKit

/// Short-lived catalog/rating responses only; player and configuration requests bypass it.
public actor CatalogCache {
    public static let shared = CatalogCache()
    private struct Entry: Codable { let expires: Date; let url: URL; let data: Data }
    private let folder: URL
    private var memory: [String: Entry] = [:]
    private let limit = 16 * 1024 * 1024
    private var generation = 0
    private var pending: [String: Task<(Data, URL), Error>] = [:]

    public init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iMovie-catalog-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    public func data(key: String, lifetime: TimeInterval, load: @escaping () async throws -> (Data, URL)) async throws -> (Data, URL) {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = folder.appendingPathComponent(digest)
        if let entry = memory[digest], entry.expires > Date() { return (entry.data, entry.url) }
        if let bytes = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: bytes), entry.expires > Date() {
            memory[digest] = entry
            return (entry.data, entry.url)
        }
        if let task = pending[digest] { return try await task.value }
        let token = generation
        let task = Task { try await load() }
        pending[digest] = task
        do {
            let (data, url) = try await task.value
            guard token == generation else { throw CancellationError() }
            pending[digest] = nil
            let entry = Entry(expires: Date().addingTimeInterval(lifetime), url: url, data: data)
            if data.count < 2 * 1024 * 1024 {
                if memory.values.reduce(0, { $0 + $1.data.count }) + data.count > 4 * 1024 * 1024 { memory.removeAll() }
                memory[digest] = entry
                if let bytes = try? JSONEncoder().encode(entry) { try? bytes.write(to: file, options: .atomic) }
                prune()
            }
            return (data, url)
        } catch { if generation == token { pending[digest] = nil }; throw error }
    }

    public func diskBytes() -> Int { files().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }
    public func clear() {
        generation += 1
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        memory.removeAll()
        files().forEach { try? FileManager.default.removeItem(at: $0) }
    }
    private func files() -> [URL] { (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [] }
    private func prune() {
        let entries = files().sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var bytes = diskBytes()
        for file in entries where bytes > limit {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: file)
            bytes -= size
        }
    }
}

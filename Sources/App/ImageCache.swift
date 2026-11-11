import SwiftUI
import CryptoKit

/// Shared across grids, recommendations and details. In-flight requests are coalesced.
actor ImageCache {
    static let shared = ImageCache()
    private let memory = NSCache<NSURL, NSData>()
    private let folder: URL
    private var pending: [URL: Task<Data, Error>] = [:]
    private var generation = 0
    private let maximumDiskBytes = 120 * 1024 * 1024
    private let lifetime: TimeInterval = 14 * 24 * 60 * 60

    init() {
        memory.totalCostLimit = 32 * 1024 * 1024
        memory.countLimit = 180
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iMovie-posters-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func imageData(for url: URL) async throws -> Data {
        if let cached = memory.object(forKey: url as NSURL) { return cached as Data }
        let file = cacheFile(url)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < lifetime,
           let data = try? Data(contentsOf: file), !data.isEmpty {
            memory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            return data
        }
        if let task = pending[url] { return try await task.value }
        let token = generation
        let task = Task<Data, Error> {
            var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 25)
            request.setValue(HTMLSourceAdapter.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  !data.isEmpty, data.count <= 12 * 1024 * 1024, UIImage(data: data) != nil else {
                throw ViewerError.message("图片暂时无法加载。")
            }
            return data
        }
        pending[url] = task
        do {
            let data = try await task.value
            guard token == generation else { throw CancellationError() }
            pending[url] = nil
            memory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            try? data.write(to: file, options: .atomic)
            prune()
            return data
        } catch {
            if token == generation { pending[url] = nil }
            throw error
        }
    }

    func diskBytes() -> Int {
        files().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear() {
        generation += 1
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        memory.removeAllObjects()
        for file in files() { try? FileManager.default.removeItem(at: file) }
    }

    private func cacheFile(_ url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(digest + ".image")
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
    }

    private func prune() {
        let entries = files().compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var size = entries.reduce(0) { $0 + $1.1 }
        for (file, bytes, modified) in entries where size > maximumDiskBytes || Date().timeIntervalSince(modified) >= lifetime {
            try? FileManager.default.removeItem(at: file)
            size -= bytes
        }
    }
}

@MainActor struct CachedPosterImage: View {
    let url: URL?
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { ZStack { Theme.panel; Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary) } }
        }
        .task(id: url) {
            image = nil
            guard let url, let data = try? await ImageCache.shared.imageData(for: url), !Task.isCancelled else { return }
            image = UIImage(data: data)
        }
    }
}

import SwiftUI
import CryptoKit
import ImageIO

/// Shared across grids, recommendations and details. In-flight requests are coalesced.
actor ImageCache {
    static let shared = ImageCache()
    private let memory = NSCache<NSURL, NSData>()
    private let decoded = NSCache<NSURL, UIImage>()
    private var lastPrune = Date.distantPast
    private let folder: URL
    private var pending: [URL: Task<Data, Error>] = [:]
    private var generation = 0
    private let maximumDiskBytes = 120 * 1024 * 1024
    private let lifetime: TimeInterval = 14 * 24 * 60 * 60

    init() {
        memory.totalCostLimit = 32 * 1024 * 1024
        memory.countLimit = 180
        decoded.totalCostLimit = 32 * 1024 * 1024
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iMovie-posters-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func image(for url: URL) async throws -> UIImage {
        if let image = decoded.object(forKey: url as NSURL) { return image }
        let token = generation
        let data = try await imageData(for: url)
        let image = try await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw ViewerError.message("图片无法解码。") }
            return UIImage(cgImage: cgImage)
        }.value
        guard token == generation else { throw CancellationError() }
        decoded.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4))
        return image
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
            request.setValue(BrowserProfile.userAgent, forHTTPHeaderField: "User-Agent")
            if let host = url.host { request.setValue("\(url.scheme ?? "https")://\(host)/", forHTTPHeaderField: "Referer") }
            let host = url.host?.lowercased() ?? ""
            if host == "doubanio.com" || host.hasSuffix(".doubanio.com") {
                request.setValue("https://m.douban.com/", forHTTPHeaderField: "Referer")
            }
            let (data, response) = try await LiveNetwork.shared.session.data(for: request)
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
            if Date().timeIntervalSince(lastPrune) > 60 { lastPrune = Date(); prune() }
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
        decoded.removeAllObjects()
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
            guard let url, let loaded = try? await ImageCache.shared.image(for: url), !Task.isCancelled else { return }
            image = loaded
        }
    }
}

import Foundation
import CryptoKit

/// 规则提取和解释器共用同一份 DEX。身份包含完整 URL 与配置里的 MD5。
actor SpiderPluginCache {
    static let shared = SpiderPluginCache()
    private struct Pending { let id: UUID; let task: Task<Data, Error> }
    private let folder: URL
    private let load: @Sendable (URL) async throws -> Data
    private var pending: [String: Pending] = [:]
    private var memory: [String: Data] = [:]
    private let lifetime: TimeInterval = 6 * 60 * 60

    init(folder: URL? = nil, load: @escaping @Sendable (URL) async throws -> Data = { url in
        try await HTTPClient().data(from: url, headers: ["Accept": "*/*"]).0
    }) {
        self.folder = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMovie-spider-v2", isDirectory: true)
        self.load = load
    }

    static func identity(_ spider: String?) throws -> (url: URL, checksum: String?, key: String) {
        guard let address = GuardRuleCatalog.jarURL(from: spider) else {
            throw ViewerError.message("配置里没有可用的插件地址（spider），无法在本机解析来源。")
        }
        let line = spider?.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
        let parts = line.components(separatedBy: ";md5;")
        let checksum = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil
        if let checksum, checksum.count != 32 || !checksum.allSatisfy({ $0.isHexDigit && $0.isASCII }) {
            throw ViewerError.message("配置里的插件 MD5 格式无效。")
        }
        let key = SHA256.hash(data: Data((address + ";md5;" + (checksum ?? "")).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return (try HTTPAddress.parse(address), checksum, key)
    }

    func invalidate(spider: String?) {
        guard let identity = try? Self.identity(spider) else { return }
        pending.removeValue(forKey: identity.key)?.task.cancel()
        memory.removeValue(forKey: identity.key)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(identity.key + ".dex"))
    }

    func dex(spider: String?) async throws -> Data {
        try Task.checkCancellation()
        let identity = try Self.identity(spider)
        let file = folder.appendingPathComponent(identity.key + ".dex")
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, Date().timeIntervalSince(modified) < lifetime {
            if let bytes = memory[identity.key] { return bytes }
            if let bytes = try? Data(contentsOf: file), GuardContainer.isDex([UInt8](bytes.prefix(4))) {
                memory[identity.key] = bytes
                return bytes
            }
        }
        if let request = pending[identity.key] {
            let bytes = try await request.task.value
            try Task.checkCancellation()
            return bytes
        }
        let id = UUID(), loader = load
        let task = Task.detached(priority: .userInitiated) {
            let archive = try await loader(identity.url)
            try Task.checkCancellation()
            if let checksum = identity.checksum {
                let actual = Insecure.MD5.hash(data: archive).map { String(format: "%02x", $0) }.joined()
                guard actual == checksum else { throw ViewerError.message("插件包 MD5 校验失败，请更新配置后重试。") }
            }
            let bytes = try GuardContainer.innerDex(from: archive)
            try Task.checkCancellation()
            return bytes
        }
        pending[identity.key] = Pending(id: id, task: task)
        do {
            let bytes = try await task.value
            guard pending[identity.key]?.id == id else { throw CancellationError() }
            pending[identity.key] = nil
            // 只保留最近一个包的内存，磁盘按完整身份隔离。
            memory = [identity.key: bytes]
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? bytes.write(to: file, options: .atomic)
            try Task.checkCancellation()
            return bytes
        } catch {
            if pending[identity.key]?.id == id { pending[identity.key] = nil }
            throw error
        }
    }
}

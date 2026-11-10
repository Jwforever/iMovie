import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPClient {
    public init() {}

    public func data(from url: URL, headers: [String: String] = [:]) async throws -> (Data, URL) {
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue("okhttp/4.12.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ViewerError.message("接口返回 HTTP \(status)。请稍后重试或检查地址。")
        }
        guard data.count <= ConfigDecoder.maximumBytes else { throw ViewerError.message("接口响应超过 8 MB。") }
        return (data, response.url ?? url)
    }

    public func config(at value: String) async throws -> SourceConfig {
        let url = try HTTPAddress.parse(value)
        let (data, resolved) = try await data(from: url)
        return try ConfigDecoder.decode(data, sourceURL: resolved)
    }

    public func playlist(_ source: LiveSource) async throws -> [MediaLink] {
        guard !source.needsAndroidProxy else {
            throw ViewerError.message("这个直播源指向 Android 应用内的本地代理，在 iPhone 上不可直接访问。")
        }
        let (data, url) = try await data(from: HTTPAddress.parse(source.url), headers: source.headers)
        return try PlaylistDecoder.decode(data, baseURL: url, defaultHeaders: source.headers)
    }
}

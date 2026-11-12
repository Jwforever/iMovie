import Foundation
import Network

/// 本地回环流代理：把 https 媒体地址改写成 http://127.0.0.1:<port>/p/<token>，
/// 由这里转发真实请求（用信任所有证书的会话），解决采集源自签/过期证书问题。
///
/// 之所以不用 AVAssetResourceLoader：它对 HLS（m3u8）不生效，自定义 scheme 会直接
/// 报"不支持的 URL"。真实端口 + m3u8 内容重写是标准做法：
/// - m3u8 逐行把分片/密钥 URI 解析成绝对地址再包成代理地址（相对路径才能被正确解析）
/// - Range 请求透传，mp4 等直连格式按字节回传
final class LocalStreamProxy {
    static let shared = LocalStreamProxy()
    private let queue = DispatchQueue(label: "imovie.streamproxy")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    private var session: URLSession { LiveNetwork.shared.session }

    /// 尽早启动监听，播放前端口就已就绪。
    func prepare() {
        queue.sync { self.startLocked() }
    }

    /// 把目标地址包成本地代理地址；代理未就绪返回 nil（调用方退回原生直连）。
    func mediaURL(for url: URL, headers: [String: String]) -> URL? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        return queue.sync { () -> URL? in
            startLocked()
            guard port != 0 else { return nil }
            return wrap(url, headers: headers)
        }
    }

    // MARK: - 地址包装

    private func wrap(_ target: URL, headers: [String: String]) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/p/" + Self.encode(target.absoluteString)
        if !headers.isEmpty, let payload = try? JSONSerialization.data(withJSONObject: headers) {
            components.queryItems = [URLQueryItem(name: "h", value: Self.encode(String(decoding: payload, as: UTF8.self)))]
        }
        return components.url ?? target
    }

    static func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> String? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 监听

    private func startLocked() {
        guard port == 0, listener == nil else { return }
        do {
            let listener = try NWListener(using: NWParameters.tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                if case .ready = state {
                    self.port = listener?.port?.rawValue ?? 0
                }
                if case .failed = state {
                    self.listener = nil
                    self.port = 0
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            listener = nil
            port = 0
        }
    }

    // MARK: - 连接处理

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection, Data())
    }

    private func receiveHeader(_ connection: NWConnection, _ buffer: Data) {
        if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
            processRequest(connection, buffer[..<range.lowerBound])
            return
        }
        guard buffer.count < 64 * 1024 else {
            connection.cancel()
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard error == nil, let data, !complete else {
                connection.cancel()
                return
            }
            var next = buffer
            next.append(data)
            self?.receiveHeader(connection, next)
        }
    }

    private func processRequest(_ connection: NWConnection, _ head: Data) {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            respond(connection, status: 400, headers: [:], body: Data())
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respond(connection, status: 400, headers: [:], body: Data())
            return
        }
        var requestHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            requestHeaders[name] = value
        }

        var target = String(parts[1])
        var query = ""
        if let question = target.firstIndex(of: "?") {
            query = String(target[target.index(after: question)...])
            target = String(target[..<question])
        }
        guard target.hasPrefix("/p/") else {
            respond(connection, status: 404, headers: [:], body: Data())
            return
        }
        guard let original = Self.decode(String(target.dropFirst(3))), let url = URL(string: original) else {
            respond(connection, status: 400, headers: [:], body: Data())
            return
        }

        var headers: [String: String] = [:]
        for pair in query.split(separator: "&") where pair.hasPrefix("h=") {
            if let json = Self.decode(String(pair.dropFirst(2))),
               let payload = json.data(using: .utf8),
               let values = try? JSONSerialization.jsonObject(with: payload) as? [String: String] {
                headers = values
            }
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let range = requestHeaders["range"] { request.setValue(range, forHTTPHeaderField: "Range") }

        session.dataTask(with: request) { [weak self] data, response, error in
            self?.deliver(connection, target: url, headers: headers, data: data,
                          response: response, error: error)
        }.resume()
    }

    private func deliver(_ connection: NWConnection, target: URL, headers: [String: String],
                         data: Data?, response: URLResponse?, error: Error?) {
        guard error == nil, let http = response as? HTTPURLResponse, let data else {
            respond(connection, status: 502, headers: [:], body: Data())
            return
        }
        var body = data
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let looksLikePlaylist = contentType.lowercased().contains("mpegurl")
            || target.path.lowercased().hasSuffix(".m3u8")
        if looksLikePlaylist, let text = String(data: body, encoding: .utf8) {
            body = Data(rewritePlaylist(text, baseURL: target, headers: headers).utf8)
        }
        var outHeaders = ["Content-Type": contentType.isEmpty ? "application/octet-stream" : contentType]
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
            outHeaders["Content-Range"] = contentRange
        }
        outHeaders["Accept-Ranges"] = "bytes"
        respond(connection, status: http.statusCode, headers: outHeaders, body: body)
    }

    // MARK: - m3u8 重写

    private func rewritePlaylist(_ text: String, baseURL: URL, headers: [String: String]) -> String {
        text.components(separatedBy: "\n").map { rawLine in
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                return replaceURIs(in: rawLine, baseURL: baseURL, headers: headers)
            }
            guard !trimmed.isEmpty else { return rawLine }
            guard let absolute = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
                  let proxied = mediaURLForTarget(absolute, headers: headers) else { return rawLine }
            return proxied.absoluteString
        }.joined(separator: "\n")
    }

    private func replaceURIs(in line: String, baseURL: URL, headers: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: "URI=\"([^\"]+)\"") else { return line }
        let range = NSRange(line.startIndex..., in: line)
        var result = line
        for match in regex.matches(in: line, range: range).reversed() {
            guard let sub = Range(match.range(at: 1), in: line) else { continue }
            let raw = String(line[sub])
            guard let absolute = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
                  let proxied = mediaURLForTarget(absolute, headers: headers) else { continue }
            result.replaceSubrange(sub, with: proxied.absoluteString)
        }
        return result
    }

    /// 分片/密钥地址：不带查询串的纯代理地址（头信息原样继承）。
    private func mediaURLForTarget(_ target: URL, headers: [String: String]) -> URL? {
        guard port != 0 else { return nil }
        return wrap(target, headers: headers)
    }

    // MARK: - 回包

    private func respond(_ connection: NWConnection, status: Int, headers: [String: String], body: Data) {
        var text = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        var out = headers
        out["Content-Length"] = String(body.count)
        out["Connection"] = "close"
        for (key, value) in out { text += "\(key): \(value)\r\n" }
        text += "\r\n"
        var payload = Data(text.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        default: return "Status \(status)"
        }
    }
}

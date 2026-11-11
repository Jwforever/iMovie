import Foundation
import SwiftSoup

/// Reads public player responses over HTTP. It never creates or displays a webpage.
public struct MediaResolver {
    private let http = HTTPClient()
    public init() {}

    public func resolve(_ source: MediaLink) async throws -> MediaLink {
        if source.kind != .web && HTTPAddress.isMedia(source.url) { return source }
        var pending: [(URL, Int, String?)] = [(try HTTPAddress.parse(source.url), 0, source.headers["Referer"])]
        var seen = Set<String>()
        var lastError: Error?
        while !pending.isEmpty && seen.count < 8 {
            try Task.checkCancellation()
            let (url, depth, referer) = pending.removeFirst()
            guard depth < 4, seen.insert(url.absoluteString).inserted else { continue }
            var headers = source.headers
            headers["User-Agent"] = headers["User-Agent"] ?? HTMLSourceAdapter.userAgent
            if let referer { headers["Referer"] = referer }
            do {
                let (data, final) = try await http.data(from: url, headers: headers)
                if HTTPAddress.isMedia(final.absoluteString) || data.starts(with: Data("#EXTM3U".utf8)) || (data.count > 12 && String(data: data[4..<8], encoding: .ascii) == "ftyp") {
                    return direct(final, source: source, headers: headers)
                }
                if let media = Self.publicMedia(in: data, baseURL: final).first {
                    return direct(media, source: source, headers: headers)
                }
                if ["hhjx.hhplayer.com", "hhplayer.com"].contains(final.host?.lowercased() ?? ""),
                   let bootstrap = Self.object(named: "__HHJX_BOOTSTRAP__", in: data),
                   let value = bootstrap["url"], let stamp = bootstrap["t"], let key = bootstrap["key"] {
                    var payload: [String: Any] = ["url": value, "t": stamp, "key": key, "client_fallback": false]
                    if let act = bootstrap["act"] { payload["act"] = act }
                    headers["Referer"] = final.absoluteString
                    let endpoint = URL(string: "/api/parse", relativeTo: final)!.absoluteURL
                    let response = try await http.post(to: endpoint, json: payload, headers: headers)
                    if let root = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                       JSONValue.integer(root["code"]) == 200,
                       let media = HTTPAddress.optional(JSONValue.text(root["url"])), HTTPAddress.isMedia(media.absoluteString) {
                        return direct(media, source: source, headers: headers)
                    }
                }
                let doc = try SwiftSoup.parse(String(data: data, encoding: .utf8) ?? "", final.absoluteString)
                for frame in try doc.select("iframe[src]").array() {
                    if let child = HTTPAddress.optional(try frame.attr("src"), relativeTo: final) {
                        pending.append((child, depth + 1, final.absoluteString))
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        if let lastError { throw lastError }
        throw ViewerError.message("没有提取到系统播放器可用的视频链接。此线路可能需要登录、网站验证或尚未支持的解析规则，请切换线路。")
    }

    private func direct(_ url: URL, source: MediaLink, headers: [String: String]) -> MediaLink {
        var result = MediaLink(title: source.title, url: url.absoluteString, headers: headers, group: source.group, kind: .direct)
        result.reference = source.reference
        return result
    }

    static func publicMedia(in data: Data, baseURL: URL) -> [URL] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        var values: [String] = []
        if let url = AueteAdapter.decodePlayer(data) { values.append(url.absoluteString) }
        if let doc = try? SwiftSoup.parse(html, baseURL.absoluteString) {
            for item in (try? doc.select("video[src], audio[src], source[src], [video-src]").array()) ?? [] {
                if let value = try? item.attr(item.hasAttr("video-src") ? "video-src" : "src") { values.append(value) }
            }
        }
        for name in ["player_aaaa", "player_data", "player", "config"] {
            if let root = object(named: name, in: data), let raw = root["url"] as? String {
                switch JSONValue.integer(root["encrypt"]) {
                case 1: values.append(raw.removingPercentEncoding ?? raw)
                case 2:
                    if let bytes = Data(base64Encoded: raw), let text = String(data: bytes, encoding: .utf8) {
                        values.append(text.removingPercentEncoding ?? text)
                    }
                default: values.append(raw)
                }
            }
        }
        // Only named player assignments, never arbitrary advertising links or image URLs.
        if let regex = try? NSRegularExpression(pattern: #"(?:\burl|\bfile|\bsource|\bsrc)\s*[:=]\s*["']([^"'\r\n]+)["']"#) {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                if let range = Range(match.range(at: 1), in: html) {
                    values.append(String(html[range]).replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\u0026", with: "&"))
                }
            }
        }
        var seen = Set<String>()
        return values.compactMap { value in
            guard let url = HTTPAddress.optional(value, relativeTo: baseURL), HTTPAddress.isMedia(url.absoluteString), seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    static func object(named name: String, in data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(\{)"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        var depth = 0, quoted = false, escaped = false
        for index in text[range.lowerBound...].indices {
            let char = text[index]
            if quoted {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { quoted = false }
            } else if char == "\"" { quoted = true }
            else if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return (try? JSONSerialization.jsonObject(with: Data(text[range.lowerBound...index].utf8))) as? [String: Any]
                }
            }
        }
        return nil
    }
}

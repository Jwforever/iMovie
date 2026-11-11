import Foundation

public enum PlaylistDecoder {
    public static func decode(_ data: Data, baseURL: URL, defaultHeaders: [String: String] = [:]) throws -> [MediaLink] {
        guard data.count <= ConfigDecoder.maximumBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw ViewerError.message("直播列表超过 8 MB，或不是 UTF-8 文本。")
        }
        if text.contains("#EXT-X-TARGETDURATION") || text.contains("#EXT-X-STREAM-INF") || text.contains("#EXT-X-MEDIA-SEQUENCE") {
            return [MediaLink(title: baseURL.lastPathComponent, url: baseURL.absoluteString, headers: defaultHeaders)]
        }
        let isM3U = text.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("#EXTM3U") || trimmed.hasPrefix("#EXTINF:")
        }
        var channels: [MediaLink] = []
        var title = ""
        var group = ""
        var poster: String?
        var headers = defaultHeaders
        var seen = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTINF:") {
                title = textAfterUnquotedComma(line) ?? "频道 \(channels.count + 1)"
                group = attribute("group-title", in: line) ?? ""
                poster = attribute("tvg-logo", in: line).flatMap { HTTPAddress.optional($0, relativeTo: baseURL)?.absoluteString }
                headers = defaultHeaders
                if let value = attribute("http-user-agent", in: line) { headers["User-Agent"] = value }
                if let value = attribute("http-referrer", in: line) { headers["Referer"] = value }
                continue
            }
            if line.lowercased().hasPrefix("#extvlcopt:") {
                let option = String(line.dropFirst(11))
                let fields = option.split(separator: "=", maxSplits: 1)
                if fields.count == 2 {
                    let key = String(fields[0]).lowercased()
                    if key == "http-user-agent" { headers["User-Agent"] = String(fields[1]) }
                    if key == "http-referrer" || key == "http-referer" { headers["Referer"] = String(fields[1]) }
                }
                continue
            }
            guard !line.hasPrefix("#") else { continue }
            var address = line
            var itemTitle = title
            if let comma = line.firstIndex(of: ","), !line.lowercased().hasPrefix("http") {
                let left = String(line[..<comma])
                let right = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                if right == "#genre#" {
                    group = left
                    title = ""
                    headers = defaultHeaders
                    continue
                }
                itemTitle = left
                address = right
            }
            let fields = address.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let rawURL = String(fields.first ?? "")
            var itemHeaders = headers
            if fields.count == 2 {
                for pair in fields[1].split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                    let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                    if ["user-agent", "referer", "origin"].contains(key.lowercased()) { itemHeaders[key] = value }
                }
            }
            // 忽略 UDP、RTSP、P2P 等 AVPlayer 无法直接处理的地址。
            let isAbsoluteHTTP = rawURL.lowercased().hasPrefix("http://") || rawURL.lowercased().hasPrefix("https://")
            guard isAbsoluteHTTP || (isM3U && !rawURL.contains("://")),
                  let url = HTTPAddress.optional(rawURL, relativeTo: baseURL) else {
                title = ""
                headers = defaultHeaders
                continue
            }
            let name = itemTitle.isEmpty ? (url.lastPathComponent.isEmpty ? "频道 \(channels.count + 1)" : url.lastPathComponent) : itemTitle
            var media = MediaLink(title: name, url: url.absoluteString, headers: itemHeaders, group: group)
            media.poster = poster
            if seen.insert(media.id).inserted { channels.append(media) }
            title = ""
            poster = nil
            headers = defaultHeaders
        }
        guard !channels.isEmpty else {
            throw ViewerError.message("没有找到 HTTP/HTTPS 频道。当前支持 M3U 和「频道名,地址」格式。")
        }
        return channels
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: name) + "=\"([^\"]*)\""
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private static func textAfterUnquotedComma(_ value: String) -> String? {
        var quoted = false
        for index in value.indices {
            if value[index] == "\"" { quoted.toggle() }
            if value[index] == ",", !quoted { return String(value[value.index(after: index)...]) }
        }
        return nil
    }
}

import Foundation

public enum ConfigDecoder {
    public static let maximumBytes = 8 * 1024 * 1024

    public static func decode(_ data: Data, sourceURL: URL) throws -> SourceConfig {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ViewerError.message("配置为空或超过 8 MB。")
        }
        let payload = try unwrap(data)
        guard var text = String(data: payload, encoding: .utf8) else {
            throw ViewerError.message("配置不是 UTF-8 文本，也不是受支持的图片封装配置。")
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let cleaned = removeTrailingCommas(stripComments(text))
        guard let encoded = cleaned.data(using: .utf8) else {
            throw ViewerError.message("无法读取配置文本。")
        }
        let root: [String: Any]
        do {
            guard let dictionary = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                throw ViewerError.message("配置最外层必须是 JSON 对象。")
            }
            root = dictionary
        } catch let error as ViewerError {
            throw error
        } catch {
            throw ViewerError.message("配置 JSON 格式不正确：\(error.localizedDescription)")
        }
        var seenKeys = Set<String>()
        let sites: [SourceSite] = (root["sites"] as? [[String: Any]] ?? []).compactMap { item in
            let key = JSONValue.text(item["key"])
            let api = JSONValue.text(item["api"])
            guard !key.isEmpty, !api.isEmpty, seenKeys.insert(key).inserted else { return nil }
            let resolved = api.lowercased().hasPrefix("csp_") ? api : HTTPAddress.optional(api, relativeTo: sourceURL)?.absoluteString ?? api
            let extensionValue: String?
            if let value = item["ext"] as? String {
                extensionValue = value
            } else if let value = item["ext"], JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) {
                extensionValue = String(data: data, encoding: .utf8)
            } else { extensionValue = nil }
            return SourceSite(
                key: key, name: JSONValue.text(item["name"]).isEmpty ? key : JSONValue.text(item["name"]),
                type: JSONValue.integer(item["type"], default: -1), api: resolved,
                searchable: JSONValue.flag(item["searchable"], default: true), extensionValue: extensionValue
            )
        }
        let lives: [LiveSource] = (root["lives"] as? [[String: Any]] ?? []).compactMap { item in
            let value = JSONValue.text(item["url"])
            guard let url = HTTPAddress.optional(value, relativeTo: sourceURL) else { return nil }
            var headers = item["header"] as? [String: String] ?? [:]
            let ua = JSONValue.text(item["ua"])
            if !ua.isEmpty { headers["User-Agent"] = ua }
            let name = JSONValue.text(item["name"])
            return LiveSource(name: name.isEmpty ? "直播列表" : name, url: url.absoluteString, headers: headers)
        }
        guard !sites.isEmpty || !lives.isEmpty else {
            throw ViewerError.message("没有找到有效的 sites 或 lives。多仓入口、AES 加密和嵌套直播配置尚未适配。")
        }
        let spider = JSONValue.text(root["spider"])
        return SourceConfig(sites: sites, lives: lives, spider: spider.isEmpty ? nil : spider,
                            importedAt: Date(), sourceURL: sourceURL.absoluteString)
    }

    static func unwrap(_ data: Data) throws -> Data {
        let bytes = Array(data)
        if let first = bytes.first(where: { ![0xEF, 0xBB, 0xBF, 0x20, 0x09, 0x0A, 0x0D].contains($0) }), first == 0x7B {
            return data
        }
        // 饭太硬当前格式：图片字节 + 任意标识 + ** + Base64(JSONC)。
        let marker = Data([0x2A, 0x2A])
        var searchStart = data.startIndex
        var attempts = 0
        while searchStart < data.endIndex, attempts < 64,
              let range = data.range(of: marker, in: searchStart..<data.endIndex) {
            attempts += 1
            let suffix = data[range.upperBound...]
            if let candidate = String(data: suffix, encoding: .utf8),
               let decoded = decodeBase64(candidate), isJSONObject(decoded) {
                return decoded
            }
            searchStart = range.upperBound
        }
        if let text = String(data: data, encoding: .utf8) {
            let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let decoded = decodeBase64(candidate), isJSONObject(decoded) { return decoded }
            // JSONC 可以以注释开头。
            if candidate.hasPrefix("//") || candidate.hasPrefix("/*") { return data }
        }
        throw ViewerError.message("无法识别配置封装。支持 JSON/JSONC、Base64 和图片 ** Base64；暂不支持 AES 或带密码的配置。")
    }

    private static func decodeBase64(_ value: String) -> Data? {
        var cleaned = value.filter { !$0.isWhitespace }
        let remainder = cleaned.utf8.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 { cleaned += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: cleaned)
    }

    private static func isJSONObject(_ data: Data) -> Bool {
        guard var text = String(data: data, encoding: .utf8) else { return false }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        return stripComments(text).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }

    static func stripComments(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        var quoted = false
        var escaped = false
        while index < characters.count {
            let current = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if quoted {
                result.append(current)
                if escaped { escaped = false }
                else if current == "\\" { escaped = true }
                else if current == "\"" { quoted = false }
                index += 1
            } else if current == "\"" {
                quoted = true
                result.append(current)
                index += 1
            } else if current == "/", next == "/" {
                index += 2
                while index < characters.count && characters[index] != "\n" && characters[index] != "\r" { index += 1 }
                result.append(" ")
            } else if current == "/", next == "*" {
                index += 2
                while index + 1 < characters.count && !(characters[index] == "*" && characters[index + 1] == "/") {
                    if characters[index] == "\n" || characters[index] == "\r" { result.append(characters[index]) }
                    index += 1
                }
                index = min(characters.count, index + 2)
                result.append(" ")
            } else {
                result.append(current)
                index += 1
            }
        }
        return result
    }

    static func removeTrailingCommas(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var quoted = false
        var escaped = false
        for (index, current) in characters.enumerated() {
            if quoted {
                result.append(current)
                if escaped { escaped = false }
                else if current == "\\" { escaped = true }
                else if current == "\"" { quoted = false }
            } else if current == "\"" {
                quoted = true
                result.append(current)
            } else if current == "," {
                var next = index + 1
                while next < characters.count && characters[next].isWhitespace { next += 1 }
                if next >= characters.count || ![Character("}"), Character("]")].contains(characters[next]) {
                    result.append(current)
                }
            } else { result.append(current) }
        }
        return result
    }
}

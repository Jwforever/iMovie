import Foundation

extension DalvikNatives {
    /// Java 里对象拼接 / `String.valueOf` / `%s` 都走 `toString()`。
    /// 直接输出类名会让插件拼出 `1$<Ljava/util/HashMap;>` 这种废字符串，
    /// 选集就整段作废了。
    static func javaText(_ vm: DalvikVM, _ value: DalvikValue?) -> String {
        guard let value else { return "null" }
        switch value {
        case .ref(let object):
            guard let object else { return "null" }
            if let string = object.stringPayload { return string }
            // JSON 对象必须输出 JSON，而不是 Java Map 的 {k=v} 形式，
            // 否则插件自己回头解析时会对不上。
            if object.className.hasSuffix("JSONObject;") || object.className.hasSuffix("JsonObject;") {
                if let map = object.payload as? [String: DalvikValue] {
                    return encode(map)
                }
            }
            if object.className.hasSuffix("JSONArray;") || object.className.hasSuffix("JsonArray;") {
                if let items = object.items {
                    let plainItems = items.map { plain($0) }
                    if let data = try? JSONSerialization.data(withJSONObject: plainItems, options: [.fragmentsAllowed]),
                       let text = String(data: data, encoding: .utf8) {
                        return text
                    }
                }
            }
            if let map = object.payload as? [String: DalvikValue] {
                let body = map.keys.sorted().map { "\($0)=\(javaText(vm, map[$0]))" }.joined(separator: ", ")
                return "{" + body + "}"
            }
            if let items = object.items {
                return "[" + items.map { javaText(vm, $0) }.joined(separator: ", ") + "]"
            }
            if let method = vm.findMethod(object.className, "toString", []) {
                if let result = try? vm.invoke(method, [], object),
                   case .ref(let target) = result, let string = target?.stringPayload {
                    return string
                }
            }
            return object.className
        default:
            return text(value)
        }
    }
}

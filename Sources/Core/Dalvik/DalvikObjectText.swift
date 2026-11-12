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
            if let map = object.payload as? [String: DalvikValue] {
                let body = map.keys.sorted().map { "\($0)=\(javaText(vm, map[$0]))" }.joined(separator: ", ")
                return "{" + body + "}"
            }
            if let items = object.items {
                return "[" + items.map { javaText(vm, $0) }.joined(separator: ", ") + "]"
            }
            if let method = vm.findMethod(object.className, "toString", []) {
                if let result = try? vm.invoke(method, [], object),
                   case .ref(let text)? = result, let string = text?.stringPayload {
                    return string
                }
            }
            return object.className
        default:
            return text(value)
        }
    }
}

import Foundation

/// Dalvik 寄存器里的值。宽类型（long/double）占两个寄存器，第二个位置留空。
enum DalvikValue {
    case int(Int32)
    case long(Int64)
    case float(Float)
    case double(Double)
    case ref(DalvikObject?)

    static func defaultValue(_ type: String) -> DalvikValue {
        switch type {
        case "J": return .long(0)
        case "I", "S", "B", "C", "Z": return .int(0)
        case "F": return .float(0)
        case "D": return .double(0)
        default: return .ref(nil)
        }
    }

    var isNull: Bool {
        if case .ref(let object) = self { return object == nil }
        return false
    }

    var asObject: DalvikObject? {
        if case .ref(let object) = self { return object }
        return nil
    }

    /// DEX 的零值既可以是整数 0，也可以是 null；非空引用不能转成整数比较。
    var isZero: Bool {
        if case .ref(let object) = self { return object == nil }
        return intValue == 0
    }

    func equalsRegister(_ other: DalvikValue) -> Bool {
        switch (self, other) {
        case (.ref(let left), .ref(let right)): return left === right
        case (.ref(let object), .int(let value)), (.int(let value), .ref(let object)):
            return object == nil && value == 0
        case (.long(let left), .long(let right)): return left == right
        default: return equalsValue(other)
        }
    }

    var intValue: Int32 {
        switch self {
        case .int(let v): return v
        case .long(let v): return Int32(truncatingIfNeeded: v)
        case .float(let v): return Int32(v)
        case .double(let v): return Int32(v)
        case .ref: return 0
        }
    }

    var longValue: Int64 {
        switch self {
        case .int(let v): return Int64(v)
        case .long(let v): return v
        case .float(let v): return Int64(v)
        case .double(let v): return Int64(v)
        case .ref: return 0
        }
    }

    var doubleValue: Double {
        switch self {
        case .int(let v): return Double(v)
        case .long(let v): return Double(v)
        case .float(let v): return Double(v)
        case .double(let v): return v
        case .ref: return 0
        }
    }

    /// 条件分支用：数值按大小，引用按字符串内容或同一性。
    func equalsValue(_ other: DalvikValue) -> Bool {
        switch (self, other) {
        case (.ref(let a), .ref(let b)):
            if a == nil && b == nil { return true }
            guard let a, let b else { return false }
            if let x = a.stringPayload, let y = b.stringPayload { return x == y }
            return a === b
        case (.ref, _), (_, .ref):
            return false
        default:
            return doubleValue == other.doubleValue
        }
    }

    var display: String {
        switch self {
        case .int(let v): return String(v)
        case .long(let v): return String(v)
        case .float(let v): return String(v)
        case .double(let v): return String(v)
        case .ref(let object): return object?.stringPayload ?? (object == nil ? "null" : "<\(object!.className)>")
        }
    }
}

final class DalvikObject {
    let className: String
    var fields: [String: DalvikValue] = [:]
    /// 宿主侧对象：String 的内容、容器、JSON、HTTP 响应等。
    var payload: Any?

    init(className: String) {
        self.className = className
    }

    static func string(_ value: String) -> DalvikObject {
        let object = DalvikObject(className: "Ljava/lang/String;")
        object.payload = value
        return object
    }

    var stringPayload: String? { payload as? String }

    var items: [DalvikValue]? {
        get { payload as? [DalvikValue] }
        set { payload = newValue }
    }

    func field(_ owner: String, _ name: String) -> DalvikValue? {
        fields[owner + "|" + name]
    }

    func setField(_ owner: String, _ name: String, _ value: DalvikValue) {
        fields[owner + "|" + name] = value
    }
}

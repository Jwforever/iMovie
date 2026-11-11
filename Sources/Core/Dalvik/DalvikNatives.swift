import Foundation

/// 解释器需要的外部类：java.*、org.json、java.util.regex、okhttp3。
///
/// jar 里的 1000 多个类（含它自带的 HTML 引擎）都按字节码执行，这里只补
/// jar 之外的那一层，语义尽量贴近安卓上的实际行为。
enum DalvikNatives {
    static func install(_ vm: DalvikVM) {
        objects(vm)
        strings(vm)
        builders(vm)
        numbers(vm)
        collections(vm)
        regex(vm)
        json(vm)
        io(vm)
        network(vm)
        android(vm)
        aliases(vm)
        javaSupport(vm)
        reflectionSupport(vm)
        gsonSupport(vm)
        cryptoSupport(vm)
    }

    // MARK: - 取值助手

    static func text(_ value: DalvikValue?) -> String {
        guard let value else { return "null" }
        switch value {
        case .ref(let object):
            guard let object else { return "null" }
            if let value = object.payload as? DalvikValue { return text(value) }
            if let string = object.stringPayload { return string }
            if let items = object.items { return items.map { text($0) }.joined(separator: ",") }
            return "<\(object.className)>"
        case .int(let v): return String(v)
        case .long(let v): return String(v)
        case .float(let v): return v == v.rounded() ? String(Int(v)) : String(v)
        case .double(let v): return v == v.rounded() ? String(Int64(v)) : String(v)
        }
    }

    static func string(_ value: DalvikValue?) -> String? {
        guard case .ref(let object)? = value else { return nil }
        return object?.stringPayload
    }

    static func list(_ object: DalvikObject?) -> [DalvikValue] {
        object?.items ?? []
    }

    static func store(_ object: DalvikObject?, _ items: [DalvikValue]) {
        object?.items = items
    }

    static func map(_ object: DalvikObject?) -> [String: DalvikValue] {
        (object?.payload as? [String: DalvikValue]) ?? [:]
    }

    static func storeMap(_ object: DalvikObject?, _ value: [String: DalvikValue]) {
        object?.payload = value
    }

    static func boxed(_ value: DalvikValue) -> DalvikValue { value }

    // MARK: - Object

    private static func objects(_ vm: DalvikVM) {
        vm.register("Ljava/lang/Object;", "<init>") { _, _, _ in .ref(nil) }
        vm.register("Ljava/lang/Object;", "toString") { _, this, _ in
            .ref(DalvikObject.string(this?.stringPayload ?? this?.className ?? "null"))
        }
        vm.register("Ljava/lang/Object;", "hashCode") { _, this, _ in .int(Int32(truncatingIfNeeded: ObjectIdentifier(this ?? DalvikObject(className: "Lx;")).hashValue)) }
        vm.register("Ljava/lang/Object;", "equals") { _, this, args in
            if let a = this?.stringPayload, let b = string(args.first ?? .ref(nil)) {
                return .int(a == b ? 1 : 0)
            }
            return .int(this === args.first?.asObject ? 1 : 0)
        }
        vm.register("Ljava/lang/Object;", "getClass") { _, this, _ in
            .ref(DalvikObject(className: "Ljava/lang/Class;"))
        }
    }

    // MARK: - String

    private static func strings(_ vm: DalvikVM) {
        vm.register("Ljava/lang/String;", "<init>") { _, this, args in
            if let array = args.first?.asObject?.items {
                let start = args.count > 1 ? max(0, Int(args[1].intValue)) : 0
                let count = args.count > 2 ? max(0, Int(args[2].intValue)) : array.count
                let values = Array(array.dropFirst(start).prefix(count))
                if args.first?.asObject?.className == "[B" {
                    this?.payload = decode(Data(values.map { UInt8(truncatingIfNeeded: $0.intValue) }))
                } else {
                    this?.payload = String(decoding: values.map { UInt16(truncatingIfNeeded: $0.intValue) }, as: UTF16.self)
                }
            } else { this?.payload = string(args.first ?? .ref(nil)) ?? "" }
            return .ref(nil)
        }
        vm.register("Ljava/lang/String;", "length") { _, this, _ in
            .int(Int32(this?.stringPayload?.utf16.count ?? 0))
        }
        vm.register("Ljava/lang/String;", "isEmpty") { _, this, _ in
            .int((this?.stringPayload ?? "").isEmpty ? 1 : 0)
        }
        vm.register("Ljava/lang/String;", "trim") { _, this, _ in
            .ref(DalvikObject.string((this?.stringPayload ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        vm.register("Ljava/lang/String;", "toString") { _, this, _ in
            .ref(DalvikObject.string(this?.stringPayload ?? ""))
        }
        vm.register("Ljava/lang/String;", "intern") { _, this, _ in .ref(this) }
        vm.register("Ljava/lang/String;", "toLowerCase") { _, this, _ in
            .ref(DalvikObject.string((this?.stringPayload ?? "").lowercased()))
        }
        vm.register("Ljava/lang/String;", "toUpperCase") { _, this, _ in
            .ref(DalvikObject.string((this?.stringPayload ?? "").uppercased()))
        }
        vm.register("Ljava/lang/String;", "toCharArray") { _, this, _ in
            let chars = (this?.stringPayload ?? "").utf16.map { DalvikValue.int(Int32($0)) }
            let object = DalvikObject(className: "[C")
            object.items = chars
            return .ref(object)
        }
        vm.register("Ljava/lang/String;", "getBytes") { _, this, _ in
            let data = Data((this?.stringPayload ?? "").utf8)
            let object = DalvikObject(className: "[B")
            object.items = data.map { DalvikValue.int(Int32($0)) }
            return .ref(object)
        }
        vm.register("Ljava/lang/String;", "charAt") { _, this, args in
            let value = Array((this?.stringPayload ?? "").utf16)
            let index = Int(args.first?.intValue ?? 0)
            guard index >= 0, index < value.count else { return .int(0) }
            return .int(Int32(value[index]))
        }
        vm.register("Ljava/lang/String;", "indexOf") { vm, this, args in
            let value = this?.stringPayload ?? ""
            let needle = vm.invocationParameters.first == "I" ? String(decoding: [UInt16(truncatingIfNeeded: args.first?.intValue ?? 0)], as: UTF16.self) : string(args.first ?? .ref(nil)) ?? ""
            let start = args.count > 1 ? Int(args[1].intValue) : 0
            guard let range = value.range(of: needle, options: [], range: (value.index(value.startIndex, offsetBy: min(max(0, start), value.count))..<value.endIndex)) else {
                return .int(-1)
            }
            return .int(Int32(value.distance(from: value.startIndex, to: range.lowerBound)))
        }
        vm.register("Ljava/lang/String;", "lastIndexOf") { _, this, args in
            let value = this?.stringPayload ?? ""
            let needle = string(args.first ?? .ref(nil)) ?? ""
            guard let range = value.range(of: needle, options: .backwards) else { return .int(-1) }
            return .int(Int32(value.distance(from: value.startIndex, to: range.lowerBound)))
        }
        vm.register("Ljava/lang/String;", "substring") { _, this, args in
            let value = this?.stringPayload ?? ""
            let lower = Int(args.first?.intValue ?? 0)
            let upper = args.count > 1 ? Int(args[1].intValue) : value.count
            guard lower >= 0, upper <= value.count, lower <= upper else { return .ref(DalvikObject.string("")) }
            let start = value.index(value.startIndex, offsetBy: lower)
            let end = value.index(value.startIndex, offsetBy: upper)
            return .ref(DalvikObject.string(String(value[start..<end])))
        }
        vm.register("Ljava/lang/String;", "contains") { _, this, args in
            let value = this?.stringPayload ?? ""
            return .int(value.contains(string(args.first ?? .ref(nil)) ?? "") ? 1 : 0)
        }
        vm.register("Ljava/lang/String;", "startsWith") { _, this, args in
            .int((this?.stringPayload ?? "").hasPrefix(string(args.first ?? .ref(nil)) ?? "") ? 1 : 0)
        }
        vm.register("Ljava/lang/String;", "endsWith") { _, this, args in
            .int((this?.stringPayload ?? "").hasSuffix(string(args.first ?? .ref(nil)) ?? "") ? 1 : 0)
        }
        vm.register("Ljava/lang/String;", "equals") { _, this, args in
            .int((this?.stringPayload ?? "") == (string(args.first ?? .ref(nil)) ?? "\u{0}") ? 1 : 0)
        }
        vm.register("Ljava/lang/String;", "equalsIgnoreCase") { _, this, args in
            let left = (this?.stringPayload ?? "").lowercased()
            let right = (string(args.first ?? .ref(nil)) ?? "").lowercased()
            return .int(left == right ? 1 : 0)
        }
        vm.register("Ljava/lang/String;", "replace") { _, this, args in
            let value = this?.stringPayload ?? ""
            let from = string(args.first ?? .ref(nil)) ?? ""
            let to = args.count > 1 ? (string(args[1]) ?? "") : ""
            return .ref(DalvikObject.string(value.replacingOccurrences(of: from, with: to)))
        }
        vm.register("Ljava/lang/String;", "replaceAll") { _, this, args in
            let value = this?.stringPayload ?? ""
            let pattern = string(args.first ?? .ref(nil)) ?? ""
            let template = args.count > 1 ? (string(args[1]) ?? "") : ""
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return .ref(DalvikObject.string(value))
            }
            let range = NSRange(value.startIndex..., in: value)
            return .ref(DalvikObject.string(regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)))
        }
        vm.register("Ljava/lang/String;", "split") { _, this, args in
            let value = this?.stringPayload ?? ""
            let pattern = string(args.first ?? .ref(nil)) ?? ""
            let limit = args.count > 1 ? Int(args[1].intValue) : 0
            var parts: [String] = []
            if let regex = try? NSRegularExpression(pattern: pattern), !value.isEmpty {
                let subject = value as NSString
                var start = 0
                for match in regex.matches(in: value, range: NSRange(location: 0, length: subject.length)) {
                    if match.range.length == 0 && match.range.location == 0 { continue }
                    if limit > 0 && parts.count >= limit - 1 { break }
                    parts.append(subject.substring(with: NSRange(location: start, length: match.range.location - start)))
                    start = match.range.location + match.range.length
                }
                parts.append(subject.substring(from: start))
                if limit == 0 { while parts.last == "" { parts.removeLast() } }
            } else { parts = [value] }
            let object = DalvikObject(className: "[Ljava/lang/String;")
            object.items = parts.map { DalvikValue.ref(DalvikObject.string($0)) }
            return .ref(object)
        }
        vm.register("Ljava/lang/String;", "regionMatches") { _, this, args in
            let ignoreCase = args.count == 5
            let offset = ignoreCase ? 1 : 0
            guard args.count >= offset + 4 else { return .int(0) }
            let left = Array((this?.stringPayload ?? "").utf16), right = Array(text(args[offset + 1]).utf16)
            let start = Int(args[offset].intValue), other = Int(args[offset + 2].intValue), count = Int(args[offset + 3].intValue)
            guard start >= 0, other >= 0, count >= 0, start + count <= left.count, other + count <= right.count else { return .int(0) }
            let a = String(decoding: left[start..<(start + count)], as: UTF16.self), b = String(decoding: right[other..<(other + count)], as: UTF16.self)
            return .int(ignoreCase && args[0].intValue != 0 ? (a.lowercased() == b.lowercased() ? 1 : 0) : (a == b ? 1 : 0))
        }
        vm.register("Ljava/lang/String;", "matches") { _, this, args in
            let value = this?.stringPayload ?? ""
            guard let pattern = string(args.first ?? .ref(nil)) else { return .int(0) }
            return .int(value.range(of: pattern, options: .regularExpression) != nil ? 1 : 0)
        }
        vm.register("Ljava/lang/String;", "compareTo") { _, this, args in
            let left = this?.stringPayload ?? ""
            let right = string(args.first ?? .ref(nil)) ?? ""
            if left == right { return .int(0) }
            return .int(left < right ? -1 : 1)
        }
        vm.register("Ljava/lang/String;", "valueOf") { _, _, args in
            .ref(DalvikObject.string(text(args.first)))
        }
        vm.register("Ljava/lang/String;", "format") { _, _, args in
            let format = string(args.first ?? .ref(nil)) ?? ""
            var rest = Array(args.dropFirst())
            if rest.count == 1, let values = rest.first?.asObject?.items { rest = values }
            var result = ""
            var index = format.startIndex
            while index < format.endIndex {
                let char = format[index]
                if char == "%" {
                    let nextIndex = format.index(after: index)
                    guard nextIndex < format.endIndex else { result.append(char); break }
                    let spec = format[nextIndex]
                    if spec == "%" { result.append("%"); index = format.index(after: nextIndex); continue }
                    if spec == "n" { result.append("\n"); index = format.index(after: nextIndex); continue }
                    let value = rest.isEmpty ? .ref(nil) : rest.removeFirst()
                    if spec == "d" { result += String(value.intValue) }
                    else { result += text(value) }
                    index = format.index(after: nextIndex)
                    continue
                }
                result.append(char)
                index = format.index(after: index)
            }
            return .ref(DalvikObject.string(result))
        }
        vm.register("Ljava/lang/String;", "join") { _, _, args in
            let separator = string(args.first ?? .ref(nil)) ?? ""
            let values: [String]
            if args.count > 1, let items = args[1].asObject?.items {
                values = items.map { text($0) }
            } else {
                values = args.dropFirst().map { text($0) }
            }
            return .ref(DalvikObject.string(values.joined(separator: separator)))
        }
    }

    // MARK: - StringBuilder

    private static func builders(_ vm: DalvikVM) {
        let bufferKey = "StringBuilder|buf"
        for className in ["Ljava/lang/StringBuilder;", "Ljava/lang/StringBuffer;"] {
            vm.register(className, "<init>") { _, this, args in
                this?.fields[bufferKey] = .ref(DalvikObject.string(string(args.first ?? .ref(nil)) ?? ""))
                return .ref(nil)
            }
            vm.register(className, "append") { vm, this, args in
                let current = this?.fields[bufferKey]?.asObject?.stringPayload ?? ""
                let character = vm.invocationParameters.last == "C"
                let suffix = character ? String(decoding: [UInt16(truncatingIfNeeded: args.first?.intValue ?? 0)], as: UTF16.self) : text(args.first)
                this?.fields[bufferKey] = .ref(DalvikObject.string(current + suffix))
                return .ref(this)
            }
            vm.register(className, "toString") { _, this, _ in
                .ref(DalvikObject.string(this?.fields[bufferKey]?.asObject?.stringPayload ?? ""))
            }
            vm.register(className, "length") { _, this, _ in
                .int(Int32(this?.fields[bufferKey]?.asObject?.stringPayload?.count ?? 0))
            }
            vm.register(className, "insert") { _, this, args in
                let current = this?.fields[bufferKey]?.asObject?.stringPayload ?? ""
                let position = min(max(0, Int(args.first?.intValue ?? 0)), current.count)
                let index = current.index(current.startIndex, offsetBy: position)
                let head = String(current[current.startIndex..<index])
                let tail = String(current[index...])
                this?.fields[bufferKey] = .ref(DalvikObject.string(head + text(args.count > 1 ? args[1] : nil) + tail))
                return .ref(this)
            }
            vm.register(className, "reverse") { _, this, _ in
                let current = this?.fields[bufferKey]?.asObject?.stringPayload ?? ""
                this?.fields[bufferKey] = .ref(DalvikObject.string(String(current.reversed())))
                return .ref(this)
            }
            vm.register(className, "setLength") { _, this, args in
                let current = this?.fields[bufferKey]?.asObject?.stringPayload ?? ""
                let length = max(0, Int(args.first?.intValue ?? 0))
                let value = current.count >= length
                    ? String(current.prefix(length))
                    : current + String(repeating: "\u{0}", count: length - current.count)
                this?.fields[bufferKey] = .ref(DalvikObject.string(value))
                return .ref(nil)
            }
            vm.register(className, "charAt") { _, this, args in
                let current = this?.fields[bufferKey]?.asObject?.stringPayload ?? ""
                let index = Int(args.first?.intValue ?? 0)
                guard index >= 0, index < current.count else { return .int(0) }
                let char = current[current.index(current.startIndex, offsetBy: index)]
                return .int(Int32(char.unicodeScalars.first?.value ?? 0))
            }
        }
    }

    // MARK: - 数字与系统

    private static func numbers(_ vm: DalvikVM) {
        let wrappers = ["Ljava/lang/Integer;", "Ljava/lang/Long;", "Ljava/lang/Short;",
                        "Ljava/lang/Byte;", "Ljava/lang/Double;", "Ljava/lang/Float;"]
        for className in wrappers {
            vm.register(className, "parseInt") { _, _, args in .int(Int32(truncatingIfNeeded: parseLong(text(args.first), radix: args.count > 1 ? Int(args[1].intValue) : 10))) }
            vm.register(className, "parseLong") { _, _, args in .long(parseLong(text(args.first), radix: args.count > 1 ? Int(args[1].intValue) : 10)) }
            vm.register(className, "parseDouble") { _, _, args in .double(Double(text(args.first)) ?? 0) }
            vm.register(className, "parseFloat") { _, _, args in .float(Float(text(args.first)) ?? 0) }
            vm.register(className, "valueOf") { _, _, args in
                let value: DalvikValue
                if args.first?.asObject?.stringPayload != nil {
                    let raw = text(args.first)
                    if className == "Ljava/lang/Double;" { value = .double(Double(raw) ?? 0) }
                    else if className == "Ljava/lang/Float;" { value = .float(Float(raw) ?? 0) }
                    else { value = .long(parseLong(raw, radix: args.count > 1 ? Int(args[1].intValue) : 10)) }
                } else { value = args.first ?? .int(0) }
                let object = DalvikObject(className: className); object.payload = value; return .ref(object)
            }
            vm.register(className, "decode") { _, _, args in .long(parseLong(text(args.first), radix: 0)) }
            vm.register(className, "toHexString") { _, _, args in
                .ref(DalvikObject.string(className == "Ljava/lang/Long;" ? String(UInt64(bitPattern: args.first?.longValue ?? 0), radix: 16) : String(UInt32(bitPattern: args.first?.intValue ?? 0), radix: 16)))
            }
            vm.register(className, "intValue") { _, this, _ in .int((this?.payload as? DalvikValue)?.intValue ?? 0) }
            vm.register(className, "longValue") { _, this, _ in .long((this?.payload as? DalvikValue)?.longValue ?? 0) }
            vm.register(className, "doubleValue") { _, this, _ in .double((this?.payload as? DalvikValue)?.doubleValue ?? 0) }
            vm.register(className, "toString") { _, this, args in .ref(DalvikObject.string(text(args.first ?? this.map { .ref($0) }))) }
            vm.register(className, "compare") { _, _, args in
                let left = args.first?.doubleValue ?? 0
                let right = args.count > 1 ? args[1].doubleValue : 0
                return .int(left < right ? -1 : (left > right ? 1 : 0))
            }
        }
        vm.register("Ljava/lang/Boolean;", "valueOf") { _, _, args in .int(args.first?.intValue ?? 0) }
        vm.register("Ljava/lang/Boolean;", "parseBoolean") { _, _, args in
            .int((string(args.first ?? .ref(nil)) ?? "").lowercased() == "true" ? 1 : 0)
        }
        vm.register("Ljava/lang/Boolean;", "booleanValue") { _, this, _ in .int(this?.payload as? Int32 ?? 0) }
        vm.register("Ljava/lang/Character;", "isDigit") { _, _, args in
            .int((string(args.first ?? .ref(nil)) ?? "").first?.isNumber == true ? 1 : 0)
        }
        vm.register("Ljava/lang/Math;", "max") { _, _, args in
            .int(max(args.first?.intValue ?? 0, args.count > 1 ? args[1].intValue : 0))
        }
        vm.register("Ljava/lang/Math;", "min") { _, _, args in
            .int(min(args.first?.intValue ?? 0, args.count > 1 ? args[1].intValue : 0))
        }
        vm.register("Ljava/lang/Math;", "abs") { _, _, args in .int(abs(args.first?.intValue ?? 0)) }
        vm.register("Ljava/lang/Math;", "floor") { _, _, args in .double((args.first?.doubleValue ?? 0).rounded(.down)) }
        vm.register("Ljava/lang/Math;", "ceil") { _, _, args in .double((args.first?.doubleValue ?? 0).rounded(.up)) }
        vm.register("Ljava/lang/Math;", "round") { _, _, args in .int(Int32((args.first?.doubleValue ?? 0).rounded())) }
        vm.register("Ljava/lang/Math;", "pow") { _, _, args in
            .double(pow(args.first?.doubleValue ?? 0, args.count > 1 ? args[1].doubleValue : 0))
        }
        vm.register("Ljava/lang/Math;", "random") { _, _, _ in .double(0.42) }
        vm.register("Ljava/lang/System;", "currentTimeMillis") { _, _, _ in
            .long(Int64(Date().timeIntervalSince1970 * 1000))
        }
        vm.register("Ljava/lang/System;", "nanoTime") { _, _, _ in
            .long(Int64(Date().timeIntervalSince1970 * 1_000_000_000))
        }
        vm.register("Ljava/lang/System;", "getProperty") { _, _, _ in .ref(DalvikObject.string("")) }
        vm.register("Ljava/lang/System;", "lineSeparator") { _, _, _ in .ref(DalvikObject.string("\n")) }
        vm.register("Ljava/lang/System;", "arraycopy") { _, _, args in
            guard args.count >= 5,
                  let source = args[0].asObject?.items,
                  let target = args[2].asObject else { return .ref(nil) }
            var items = target.items ?? []
            let sourcePos = Int(args[1].intValue)
            let targetPos = Int(args[3].intValue)
            let count = Int(args[4].intValue)
            for i in 0..<count where sourcePos + i < source.count && targetPos + i < items.count {
                items[targetPos + i] = source[sourcePos + i]
            }
            target.items = items
            return .ref(nil)
        }
        vm.register("Ljava/lang/Thread;", "sleep") { _, _, _ in .ref(nil) }
    }

    private static func parseInt(_ value: String) -> Int32 {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") {
            return Int32(trimmed.dropFirst(2), radix: 16) ?? 0
        }
        if let integer = Int32(trimmed) { return integer }
        return Int32(Double(trimmed) ?? 0)
    }

    private static func parseLong(_ value: String, radix: Int) -> Int64 {
        var text = GuardStringDecoder.arabicDigits(value).trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = text.hasPrefix("-")
        if negative || text.hasPrefix("+") { text.removeFirst() }
        var base = radix
        if base == 0 {
            if text.lowercased().hasPrefix("0x") { text = String(text.dropFirst(2)); base = 16 }
            else if text.hasPrefix("#") { text.removeFirst(); base = 16 }
            else if text.hasPrefix("0"), text.count > 1 { base = 8 }
            else { base = 10 }
        }
        guard (2...36).contains(base), let number = UInt64(text, radix: base) else { return 0 }
        return negative ? 0 &- Int64(bitPattern: number) : Int64(bitPattern: number)
    }

    // MARK: - 集合

    private static func collections(_ vm: DalvikVM) {
        let listClasses = ["Ljava/util/ArrayList;", "Ljava/util/Vector;", "Ljava/util/LinkedList;",
                           "Ljava/util/AbstractList;", "Ljava/util/AbstractCollection;"]
        for className in listClasses {
            vm.register(className, "<init>") { _, this, _ in
                this?.items = []
                return .ref(nil)
            }
            vm.register(className, "add") { _, this, args in
                var items = list(this)
                if args.count > 1 { items.insert(args[1], at: min(Int(args[0].intValue), items.count)) }
                else { items.append(args.first ?? .ref(nil)) }
                store(this, items)
                return .int(1)
            }
            vm.register(className, "addAll") { _, this, args in
                var items = list(this)
                let values = args.last?.asObject?.items ?? []
                let offset = args.count > 1 ? min(max(0, Int(args[0].intValue)), items.count) : items.count
                items.insert(contentsOf: values, at: offset); store(this, items); return .int(values.isEmpty ? 0 : 1)
            }
            vm.register(className, "get") { _, this, args in
                let items = list(this)
                let index = Int(args.first?.intValue ?? 0)
                return index >= 0 && index < items.count ? items[index] : .ref(nil)
            }
            vm.register(className, "size") { _, this, _ in .int(Int32(list(this).count)) }
            vm.register(className, "isEmpty") { _, this, _ in .int(list(this).isEmpty ? 1 : 0) }
            vm.register(className, "clear") { _, this, _ in store(this, []); return .ref(nil) }
            vm.register(className, "contains") { _, this, args in
                let target = args.first ?? .ref(nil)
                return .int(list(this).contains(where: { $0.equalsValue(target) }) ? 1 : 0)
            }
            vm.register(className, "indexOf") { _, this, args in
                let target = args.first ?? .ref(nil)
                let index = list(this).firstIndex(where: { $0.equalsValue(target) }) ?? -1
                return .int(Int32(index))
            }
            vm.register(className, "remove") { _, this, args in
                var items = list(this)
                guard !items.isEmpty else { return .ref(nil) }
                let index = Int(args.first?.intValue ?? -1)
                if index >= 0 && index < items.count {
                    let removed = items.remove(at: index)
                    store(this, items)
                    return removed
                }
                if let position = items.firstIndex(where: { $0.equalsValue(args.first ?? .ref(nil)) }) {
                    items.remove(at: position)
                    store(this, items)
                }
                return .int(1)
            }
            vm.register(className, "set") { _, this, args in
                var items = list(this)
                let index = Int(args.first?.intValue ?? 0)
                guard index >= 0, index < items.count else { return .ref(nil) }
                let old = items[index]
                items[index] = args.count > 1 ? args[1] : .ref(nil)
                store(this, items)
                return old
            }
            vm.register(className, "iterator") { _, this, _ in
                let object = DalvikObject(className: "Ljava/util/Iterator;")
                object.payload = IteratorBox(items: list(this), index: 0)
                return .ref(object)
            }
            vm.register(className, "toArray") { _, this, _ in
                let object = DalvikObject(className: "[Ljava/lang/Object;")
                object.items = list(this)
                return .ref(object)
            }
        }
        vm.register("Ljava/util/Iterator;", "hasNext") { _, this, _ in
            guard let box = this?.payload as? IteratorBox else { return .int(0) }
            return .int(box.index < box.items.count ? 1 : 0)
        }
        vm.register("Ljava/util/Iterator;", "next") { _, this, _ in
            guard let box = this?.payload as? IteratorBox else { return .ref(nil) }
            guard box.index < box.items.count else { return .ref(nil) }
            let value = box.items[box.index]
            box.index += 1
            return value
        }
        vm.register("Ljava/util/Iterator;", "remove") { _, _, _ in .ref(nil) }

        let mapClasses = ["Ljava/util/HashMap;", "Ljava/util/LinkedHashMap;", "Ljava/util/TreeMap;",
                          "Ljava/util/AbstractMap;"]
        for className in mapClasses {
            vm.register(className, "<init>") { _, this, _ in
                this?.payload = [String: DalvikValue]()
                return .ref(nil)
            }
            vm.register(className, "put") { _, this, args in
                var current = map(this)
                let key = text(args.first)
                let old = current[key] ?? .ref(nil)
                current[key] = args.count > 1 ? args[1] : .ref(nil)
                storeMap(this, current)
                return old
            }
            vm.register(className, "get") { _, this, args in
                map(this)[text(args.first)] ?? .ref(nil)
            }
            vm.register(className, "getOrDefault") { _, this, args in
                map(this)[text(args.first)] ?? (args.count > 1 ? args[1] : .ref(nil))
            }
            vm.register(className, "containsKey") { _, this, args in
                .int(map(this)[text(args.first)] != nil ? 1 : 0)
            }
            vm.register(className, "remove") { _, this, args in
                var current = map(this)
                let old = current.removeValue(forKey: text(args.first)) ?? .ref(nil)
                storeMap(this, current)
                return old
            }
            vm.register(className, "size") { _, this, _ in .int(Int32(map(this).count)) }
            vm.register(className, "isEmpty") { _, this, _ in .int(map(this).isEmpty ? 1 : 0) }
            vm.register(className, "clear") { _, this, _ in storeMap(this, [:]); return .ref(nil) }
            vm.register(className, "keySet") { _, this, _ in
                let object = DalvikObject(className: "Ljava/util/Set;")
                object.payload = IteratorBox(items: map(this).keys.sorted().map { .ref(DalvikObject.string($0)) }, index: 0)
                return .ref(object)
            }
            vm.register(className, "values") { _, this, _ in
                let object = DalvikObject(className: "[Ljava/lang/Object;")
                object.items = map(this).values.sorted { text($0) < text($1) }
                return .ref(object)
            }
        }
        vm.register("Ljava/util/Set;", "iterator") { _, this, _ in
            let object = DalvikObject(className: "Ljava/util/Iterator;")
            object.payload = this?.payload as? IteratorBox ?? IteratorBox(items: [], index: 0)
            return .ref(object)
        }
        vm.register("Ljava/util/Set;", "size") { _, this, _ in
            .int(Int32((this?.payload as? IteratorBox)?.items.count ?? 0))
        }
    }

    final class IteratorBox {
        let items: [DalvikValue]
        var index: Int
        init(items: [DalvikValue], index: Int) {
            self.items = items
            self.index = index
        }
    }

    // MARK: - 正则

    private static func regex(_ vm: DalvikVM) {
        vm.register("Ljava/util/regex/Pattern;", "compile") { _, _, args in
            let object = DalvikObject(className: "Ljava/util/regex/Pattern;")
            object.payload = string(args.first ?? .ref(nil)) ?? ""
            return .ref(object)
        }
        vm.register("Ljava/util/regex/Pattern;", "matcher") { _, this, args in
            let object = DalvikObject(className: "Ljava/util/regex/Matcher;")
            let pattern = this?.payload as? String ?? ""
            let subject = string(args.first ?? .ref(nil)) ?? ""
            object.payload = MatcherBox(pattern: pattern, subject: subject)
            return .ref(object)
        }
        vm.register("Ljava/util/regex/Matcher;", "find") { _, this, args in
            guard let box = this?.payload as? MatcherBox else { return .int(0) }
            if args.count > 1 {
                box.match = box.regex?.firstMatch(in: box.subject,
                                                  range: NSRange(box.subject.startIndex..., in: box.subject))
            } else if box.match == nil {
                box.match = box.regex?.firstMatch(in: box.subject,
                                                  range: NSRange(box.subject.startIndex..., in: box.subject))
            } else if let previous = box.match {
                let start = previous.range.location + max(previous.range.length, 1)
                if start <= box.subject.count {
                    let range = NSRange(location: start, length: box.subject.count - start)
                    box.match = box.regex?.firstMatch(in: box.subject, range: range)
                } else {
                    box.match = nil
                }
            }
            return .int(box.match == nil ? 0 : 1)
        }
        vm.register("Ljava/util/regex/Matcher;", "group") { _, this, args in
            guard let box = this?.payload as? MatcherBox, let match = box.match else { return .ref(nil) }
            let index = args.isEmpty ? 0 : Int(args[0].intValue)
            guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: box.subject) else {
                return .ref(nil)
            }
            return .ref(DalvikObject.string(String(box.subject[range])))
        }
        vm.register("Ljava/util/regex/Matcher;", "matches") { _, this, _ in
            guard let box = this?.payload as? MatcherBox else { return .int(0) }
            let range = NSRange(box.subject.startIndex..., in: box.subject)
            box.match = box.regex?.firstMatch(in: box.subject, range: range)
            return .int(box.match != nil && box.match?.range == range ? 1 : 0)
        }
        vm.register("Ljava/util/regex/Matcher;", "replaceAll") { _, this, args in
            guard let box = this?.payload as? MatcherBox, let regex = box.regex else { return .ref(nil) }
            let template = string(args.first ?? .ref(nil)) ?? ""
            let range = NSRange(box.subject.startIndex..., in: box.subject)
            return .ref(DalvikObject.string(regex.stringByReplacingMatches(in: box.subject, range: range, withTemplate: template)))
        }
    }

    final class MatcherBox {
        let pattern: String
        let subject: String
        let regex: NSRegularExpression?
        var match: NSTextCheckingResult?
        init(pattern: String, subject: String) {
            self.pattern = pattern
            self.subject = subject
            self.regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        }
    }
}

import Foundation

extension DalvikNatives {
    /// 插件内置 HTML 引擎依赖的 JDK 基础容器与字符操作。
    static func javaSupport(_ vm: DalvikVM) {
        func array(_ values: [DalvikValue], type: String = "Ljava/util/ArrayList;") -> DalvikValue {
            let object = DalvikObject(className: type); object.items = values; return .ref(object)
        }
        for owner in ["Ljava/util/Random;", "Ljava/security/SecureRandom;"] {
            vm.register(owner, "<init>") { _, _, _ in .ref(nil) }
            vm.register(owner, "nextInt") { _, _, args in
                if let bound = args.first?.intValue, bound > 0 { return .int(Int32.random(in: 0..<bound)) }
                return .int(Int32.random(in: Int32.min...Int32.max))
            }
            vm.register(owner, "nextDouble") { _, _, _ in .double(Double.random(in: 0..<1)) }
            vm.register(owner, "nextBytes") { _, _, args in
                if let object = args.first?.asObject, let values = object.items { object.items = values.map { _ in .int(Int32.random(in: -128...127)) } }
                return .ref(nil)
            }
        }
        vm.register("Ljava/util/UUID;", "randomUUID") { _, _, _ in
            let object = DalvikObject(className: "Ljava/util/UUID;"); object.payload = UUID().uuidString.lowercased(); return .ref(object)
        }
        vm.register("Ljava/util/UUID;", "fromString") { _, _, args in
            let object = DalvikObject(className: "Ljava/util/UUID;"); object.payload = text(args.first).lowercased(); return .ref(object)
        }
        vm.register("Ljava/util/UUID;", "toString") { _, this, _ in .ref(DalvikObject.string(this?.stringPayload ?? "")) }
        vm.register("Ljava/lang/Character;", "digit") { _, _, args in
            let code = UInt32(truncatingIfNeeded: args.first?.intValue ?? 0)
            let radix = Int(args.count > 1 ? args[1].intValue : 10)
            guard (2...36).contains(radix), let scalar = Unicode.Scalar(code) else { return .int(-1) }
            let character = Character(String(scalar))
            let number = character.wholeNumberValue ?? (code >= 65 && code <= 90 ? Int(code - 65 + 10) : code >= 97 && code <= 122 ? Int(code - 97 + 10) : -1)
            return .int(number >= 0 && number < radix ? Int32(number) : -1)
        }
        vm.register("Ljava/util/Collections;", "emptyList") { _, _, _ in array([]) }
        vm.register("Ljava/util/Collections;", "singletonList") { _, _, args in array([args.first ?? .ref(nil)]) }
        vm.register("Ljava/util/Collections;", "unmodifiableList") { _, _, args in args.first ?? array([]) }
        vm.register("Ljava/util/Collections;", "synchronizedList") { _, _, args in args.first ?? array([]) }
        vm.register("Ljava/util/Collections;", "unmodifiableMap") { _, _, args in args.first ?? .ref(nil) }
        vm.register("Ljava/util/Collections;", "nCopies") { _, _, args in
            array(Array(repeating: args.count > 1 ? args[1] : .ref(nil), count: max(0, Int(args.first?.intValue ?? 0))))
        }
        vm.register("Ljava/util/Collections;", "addAll") { _, _, args in
            let object = args.first?.asObject
            var values = object?.items ?? []
            values += args.count > 1 ? args[1].asObject?.items ?? [] : []
            object?.items = values
            return .int(1)
        }
        vm.register("Ljava/util/Collections;", "reverse") { _, _, args in
            args.first?.asObject?.items = Array((args.first?.asObject?.items ?? []).reversed()); return .ref(nil)
        }
        for name in ["sort", "max", "min"] {
            vm.register("Ljava/util/Collections;", name) { _, _, args in
                let values = (args.first?.asObject?.items ?? []).sorted { text($0) < text($1) }
                if name == "max" { return values.last ?? .ref(nil) }
                if name == "min" { return values.first ?? .ref(nil) }
                args.first?.asObject?.items = values; return .ref(nil)
            }
        }
        vm.register("Ljava/util/Arrays;", "asList") { _, _, args in array(args.first?.asObject?.items ?? []) }
        for name in ["copyOf", "copyOfRange"] {
            vm.register("Ljava/util/Arrays;", name) { _, _, args in
                let source = args.first?.asObject
                let values = source?.items ?? []
                let start = name == "copyOfRange" ? max(0, Int(args.count > 1 ? args[1].intValue : 0)) : 0
                let endIndex = name == "copyOfRange" ? 2 : 1
                let end = args.count > endIndex ? Int(args[endIndex].intValue) : values.count
                let count = max(0, end - start)
                var result = Array(values.dropFirst(start).prefix(count))
                let type = source?.className ?? "[Ljava/lang/Object;"
                if result.count < count { result += Array(repeating: DalvikValue.defaultValue(String(type.dropFirst())), count: count - result.count) }
                return array(result, type: type)
            }
        }
        vm.register("Ljava/util/Arrays;", "fill") { _, _, args in
            guard let object = args.first?.asObject, var values = object.items else { return .ref(nil) }
            let start = args.count > 2 ? max(0, Int(args[1].intValue)) : 0
            let end = args.count > 2 ? min(values.count, Int(args[2].intValue)) : values.count
            if start < end { for index in start..<end { values[index] = args.last ?? .ref(nil) } }
            object.items = values; return .ref(nil)
        }
        vm.register("Ljava/util/Arrays;", "equals") { _, _, args in
            let left = args.first?.asObject?.items ?? [], right = args.count > 1 ? args[1].asObject?.items ?? [] : []
            return .int(left.count == right.count && zip(left, right).allSatisfy { $0.equalsValue($1) } ? 1 : 0)
        }
        vm.register("Ljava/util/Objects;", "requireNonNull") { _, _, args in
            guard let value = args.first, !value.isZero else {
                let object = DalvikObject(className: "Ljava/lang/NullPointerException;")
                object.payload = args.count > 1 ? text(args[1]) : "null"
                throw DalvikThrown(object: object)
            }
            return value
        }
        vm.register("Ljava/util/Objects;", "equals") { _, _, args in
            .int((args.first ?? .ref(nil)).equalsValue(args.count > 1 ? args[1] : .ref(nil)) ? 1 : 0)
        }
        for className in ["Ljava/util/HashSet;", "Ljava/util/LinkedHashSet;"] {
            vm.register(className, "<init>") { _, this, args in this?.items = args.first?.asObject?.items ?? []; return .ref(nil) }
            vm.register(className, "add") { _, this, args in
                var values = this?.items ?? []; let value = args.first ?? .ref(nil)
                if values.contains(where: { $0.equalsValue(value) }) { return .int(0) }
                values.append(value); this?.items = values; return .int(1)
            }
            for name in ["contains", "isEmpty", "size", "iterator"] {
                vm.register(className, name) { _, this, args in
                    let values = this?.items ?? []
                    if name == "contains" { return .int(values.contains { $0.equalsValue(args.first ?? .ref(nil)) } ? 1 : 0) }
                    if name == "isEmpty" { return .int(values.isEmpty ? 1 : 0) }
                    if name == "size" { return .int(Int32(values.count)) }
                    let object = DalvikObject(className: "Ljava/util/Iterator;")
                    object.payload = IteratorBox(items: values, index: 0); return .ref(object)
                }
            }
        }
        vm.register("Ljava/lang/String;", "hashCode") { _, this, _ in
            .int((this?.stringPayload ?? "").utf16.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1) })
        }
        vm.register("Ljava/lang/String;", "concat") { _, this, args in .ref(DalvikObject.string((this?.stringPayload ?? "") + text(args.first))) }
        for name in ["isWhitespace", "isLetter", "isLetterOrDigit", "isDigit", "isHighSurrogate", "isLowSurrogate"] {
            vm.register("Ljava/lang/Character;", name) { _, _, args in
                let value = args.first?.intValue ?? 0
                if name == "isHighSurrogate" { return .int((0xD800...0xDBFF).contains(value) ? 1 : 0) }
                if name == "isLowSurrogate" { return .int((0xDC00...0xDFFF).contains(value) ? 1 : 0) }
                guard value >= 0, let scalar = Unicode.Scalar(UInt32(value)) else { return .int(0) }
                let set: CharacterSet = name == "isWhitespace" ? .whitespacesAndNewlines : name == "isDigit" ? .decimalDigits : name == "isLetter" ? .letters : .alphanumerics
                return .int(set.contains(scalar) ? 1 : 0)
            }
        }
        for name in ["toLowerCase", "toUpperCase", "charValue", "valueOf", "charCount"] {
            vm.register("Ljava/lang/Character;", name) { _, _, args in
                let value = args.first?.intValue ?? 0
                if name == "charCount" { return .int(value >= 0x10000 ? 2 : 1) }
                guard name != "charValue", name != "valueOf", value >= 0, let scalar = Unicode.Scalar(UInt32(value)) else { return .int(value) }
                let text = String(scalar)
                return .int(Int32((name == "toLowerCase" ? text.lowercased() : text.uppercased()).utf16.first ?? 0))
            }
        }
        vm.register("Ljava/lang/Enum;", "<init>") { _, this, args in
            this?.fields["name"] = args.first ?? .ref(nil)
            this?.fields["ordinal"] = args.count > 1 ? args[1] : .int(0); return .ref(nil)
        }
        vm.register("Ljava/lang/Enum;", "name") { _, this, _ in this?.fields["name"] ?? .ref(nil) }
        vm.register("Ljava/lang/Enum;", "ordinal") { _, this, _ in this?.fields["ordinal"] ?? .int(0) }
        vm.register("Ljava/lang/Float;", "intBitsToFloat") { _, _, args in .float(Float(bitPattern: UInt32(bitPattern: args.first?.intValue ?? 0))) }
        vm.register("Ljava/lang/Float;", "floatToIntBits") { _, _, args in .int(Int32(bitPattern: Float(args.first?.doubleValue ?? 0).bitPattern)) }
        vm.register("Ljava/lang/Double;", "longBitsToDouble") { _, _, args in .double(Double(bitPattern: UInt64(bitPattern: args.first?.longValue ?? 0))) }
        vm.register("Ljava/lang/Double;", "doubleToLongBits") { _, _, args in .long(Int64(bitPattern: (args.first?.doubleValue ?? 0).bitPattern)) }
        for name in ["arraycopy"] {
            vm.register("Ljava/lang/System;", name) { _, _, args in
                guard args.count >= 5, let source = args[0].asObject?.items, let target = args[2].asObject else { return .ref(nil) }
                var values = target.items ?? []
                let from = Int(args[1].intValue), to = Int(args[3].intValue), count = Int(args[4].intValue)
                if from >= 0, to >= 0, count >= 0, from + count <= source.count, to + count <= values.count {
                    values.replaceSubrange(to..<(to + count), with: source[from..<(from + count)])
                    target.items = values
                }
                return .ref(nil)
            }
        }
    }
}

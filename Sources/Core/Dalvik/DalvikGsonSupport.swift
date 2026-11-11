import Foundation

extension DalvikNatives {
    static func gsonSupport(_ vm: DalvikVM) {
        func wrap(_ value: Any) -> DalvikValue {
            let object: DalvikObject
            if let values = value as? [String: Any] {
                object = DalvikObject(className: "Lcom/google/gson/JsonObject;")
                object.payload = values.mapValues(wrap)
            } else if let values = value as? [Any] {
                object = DalvikObject(className: "Lcom/google/gson/JsonArray;"); object.items = values.map(wrap)
            } else {
                object = DalvikObject(className: value is NSNull ? "Lcom/google/gson/JsonNull;" : "Lcom/google/gson/JsonPrimitive;")
                object.fields["value"] = box(value)
            }
            return .ref(object)
        }
        func raw(_ value: DalvikValue) -> Any {
            guard let object = value.asObject else { return plain(value) }
            if let primitive = object.fields["value"] { return plain(primitive) }
            if let items = object.items { return items.map(raw) }
            if let values = object.payload as? [String: DalvikValue] { return values.mapValues(raw) }
            if let string = object.stringPayload { return string }
            var values: [String: Any] = [:], owner: String? = object.className, seen = Set<String>()
            while let name = owner, seen.insert(name).inserted, let info = vm.classInfo(name) {
                for key in info.fieldTypes.keys {
                    if let value = object.fields[key], !value.isNull {
                        values[info.jsonNames[key] ?? key.components(separatedBy: "|").last ?? key] = raw(value)
                    }
                }
                owner = info.superName
            }
            return values
        }
        func decoded(_ value: Any, type: String) -> DalvikValue {
            if type.hasPrefix("["), let values = value as? [Any] {
                let array = DalvikObject(className: type); array.items = values.map { decoded($0, type: String(type.dropFirst())) }; return .ref(array)
            }
            guard let info = vm.classInfo(type), let values = value as? [String: Any] else {
                let boxed = box(value)
                if let object = boxed.asObject, object.className == "Lorg/json/JSONObject;" {
                    let map = DalvikObject(className: "Ljava/util/LinkedHashMap;"); map.payload = object.payload; return .ref(map)
                }
                if let object = boxed.asObject, object.items != nil {
                    let list = DalvikObject(className: "Ljava/util/ArrayList;"); list.items = object.items; return .ref(list)
                }
                return boxed
            }
            let object = DalvikObject(className: type)
            for (key, fieldType) in info.fieldTypes {
                let name = info.jsonNames[key] ?? key.components(separatedBy: "|").last ?? key
                if let value = values[name] { object.fields[key] = decoded(value, type: fieldType) }
            }
            return .ref(object)
        }
        vm.register("Lcom/google/gson/Gson;", "<init>") { _, _, _ in .ref(nil) }
        vm.register("Lcom/google/gson/Gson;", "newBuilder") { _, _, _ in .ref(DalvikObject(className: "Lcom/google/gson/GsonBuilder;")) }
        vm.register("Lcom/google/gson/GsonBuilder;", "disableHtmlEscaping") { _, this, _ in .ref(this) }
        vm.register("Lcom/google/gson/GsonBuilder;", "create") { _, _, _ in .ref(DalvikObject(className: "Lcom/google/gson/Gson;")) }
        vm.register("Lcom/google/gson/reflect/TypeToken;", "<init>") { vm, this, _ in
            this?.fields["signature"] = .ref(DalvikObject.string(vm.classInfo(this?.className ?? "")?.genericSignature ?? "")); return .ref(nil)
        }
        vm.register("Lcom/google/gson/reflect/TypeToken;", "getType") { _, this, _ in .ref(this) }
        vm.register("Lcom/google/gson/Gson;", "fromJson") { _, _, args in
            let value: Any
            if let string = args.first?.asObject?.stringPayload {
                if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .ref(nil) }
                value = try JSONSerialization.jsonObject(with: Data(string.utf8), options: [.fragmentsAllowed])
            } else { value = raw(args.first ?? .ref(nil)) }
            let target = args.count > 1 ? args[1].asObject : nil
            let type = text(target?.fields["descriptor"])
            let signature = text(target?.fields["signature"])
            if let values = value as? [Any], signature.contains("Ljava/util/List<") || signature.contains("Ljava/util/ArrayList<") {
                let pattern = try NSRegularExpression(pattern: "Lcom/github/catvod/[^;<>]+;")
                let range = NSRange(signature.startIndex..., in: signature)
                let itemType = pattern.matches(in: signature, range: range).last.flatMap { Range($0.range, in: signature).map { String(signature[$0]) } } ?? "Ljava/lang/Object;"
                let list = DalvikObject(className: "Ljava/util/ArrayList;"); list.items = values.map { decoded($0, type: itemType) }; return .ref(list)
            }
            return decoded(value, type: type)
        }
        vm.register("Lcom/google/gson/Gson;", "toJson") { _, _, args in
            let bytes = try JSONSerialization.data(withJSONObject: raw(args.first ?? .ref(nil)), options: [.fragmentsAllowed, .sortedKeys])
            return .ref(DalvikObject.string(String(decoding: bytes, as: UTF8.self)))
        }
        for name in ["parse", "parseString"] {
            vm.register("Lcom/google/gson/JsonParser;", name) { _, _, args in
                wrap(try JSONSerialization.jsonObject(with: Data(text(args.first).utf8), options: [.fragmentsAllowed]))
            }
        }
        vm.register("Lcom/google/gson/JsonParser;", "<init>") { _, _, _ in .ref(nil) }
        for owner in ["Lcom/google/gson/JsonObject;", "Lcom/google/gson/JsonArray;", "Lcom/google/gson/JsonElement;", "Lcom/google/gson/JsonPrimitive;", "Lcom/google/gson/JsonNull;"] {
            vm.register(owner, "getAsJsonObject") { _, this, args in args.isEmpty ? .ref(this) : map(this)[text(args.first)] ?? .ref(nil) }
            vm.register(owner, "getAsJsonArray") { _, this, args in args.isEmpty ? .ref(this) : map(this)[text(args.first)] ?? .ref(nil) }
            vm.register(owner, "getAsString") { _, this, _ in .ref(DalvikObject.string(text(this?.fields["value"]))) }
            vm.register(owner, "getAsInt") { _, this, _ in .int(Int32(text(this?.fields["value"])) ?? this?.fields["value"]?.intValue ?? 0) }
            vm.register(owner, "getAsBoolean") { _, this, _ in .int(text(this?.fields["value"]) == "true" || this?.fields["value"]?.intValue == 1 ? 1 : 0) }
            vm.register(owner, "has") { _, this, args in .int(map(this)[text(args.first)] != nil ? 1 : 0) }
            vm.register(owner, "get") { _, this, args in
                if let values = this?.items {
                    let index = Int(args.first?.intValue ?? -1); return values.indices.contains(index) ? values[index] : .ref(nil)
                }
                return map(this)[text(args.first)] ?? .ref(nil)
            }
            vm.register(owner, "size") { _, this, _ in .int(Int32(this?.items?.count ?? map(this).count)) }
            vm.register(owner, "iterator") { _, this, _ in
                let iterator = DalvikObject(className: "Ljava/util/Iterator;"); iterator.payload = IteratorBox(items: this?.items ?? [], index: 0); return .ref(iterator)
            }
        }
        vm.register("Lcom/google/gson/JsonObject;", "<init>") { _, this, _ in this?.payload = [String: DalvikValue](); return .ref(nil) }
    }
}

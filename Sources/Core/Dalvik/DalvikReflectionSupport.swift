import Foundation

extension DalvikNatives {
    static func reflectionSupport(_ vm: DalvikVM) {
        func descriptor(_ object: DalvikObject?) -> String { text(object?.fields["descriptor"]) }
        func classObject(_ name: String) -> DalvikValue { .ref(DalvikObject.javaClass(name)) }
        func typeName(_ name: String) -> String {
            if name.hasPrefix("L"), name.hasSuffix(";") { return String(name.dropFirst().dropLast()).replacingOccurrences(of: "/", with: ".") }
            return name.replacingOccurrences(of: "/", with: ".")
        }
        func failure(_ type: String, _ message: String) throws -> DalvikValue {
            let object = DalvikObject(className: "Ljava/lang/\(type);"); object.payload = message
            throw DalvikThrown(object: object)
        }
        vm.register("Ljava/lang/Object;", "getClass") { _, this, _ in classObject(this?.className ?? "Ljava/lang/Object;") }
        vm.register("Ljava/lang/Class;", "forName") { vm, _, args in
            let name = text(args.first)
            let value = name.hasPrefix("[") ? name.replacingOccurrences(of: ".", with: "/") : "L" + name.replacingOccurrences(of: ".", with: "/") + ";"
            guard vm.classInfo(value) != nil || value.hasPrefix("Ljava/") || value.hasPrefix("Landroid/") else {
                return try failure("ClassNotFoundException", name)
            }
            try vm.ensureInitialized(value)
            return classObject(value)
        }
        vm.register("Ljava/lang/Class;", "getName") { _, this, _ in .ref(DalvikObject.string(typeName(descriptor(this)))) }
        vm.register("Ljava/lang/Class;", "getSimpleName") { _, this, _ in .ref(DalvikObject.string(typeName(descriptor(this)).components(separatedBy: ".").last ?? "")) }
        vm.register("Ljava/lang/Class;", "getSuperclass") { vm, this, _ in
            vm.classInfo(descriptor(this))?.superName.map(classObject) ?? .ref(nil)
        }
        vm.register("Ljava/lang/Class;", "getClassLoader") { _, _, _ in .ref(DalvikObject(className: "Ljava/lang/ClassLoader;")) }
        vm.register("Ljava/lang/Class;", "isArray") { _, this, _ in .int(descriptor(this).hasPrefix("[") ? 1 : 0) }
        vm.register("Ljava/lang/Class;", "getComponentType") { _, this, _ in
            let name = descriptor(this); return name.hasPrefix("[") ? classObject(String(name.dropFirst())) : .ref(nil)
        }
        for name in ["cast", "isInstance", "isAssignableFrom"] {
            vm.register("Ljava/lang/Class;", name) { vm, this, args in
                if name == "cast" { return args.first ?? .ref(nil) }
                let child = name == "isAssignableFrom" ? descriptor(args.first?.asObject) : args.first?.asObject?.className ?? ""
                return .int(vm.isSubclass(child, descriptor(this)) ? 1 : 0)
            }
        }
        vm.register("Ljava/lang/Class;", "newInstance") { vm, this, _ in
            let name = descriptor(this), object = DalvikObject(className: descriptor(this))
            try vm.ensureInitialized(name)
            if let method = vm.findMethod(name, "<init>", []) { _ = try vm.invoke(method, [], object) }
            return .ref(object)
        }
        for name in ["getMethod", "getDeclaredMethod"] {
            vm.register("Ljava/lang/Class;", name) { vm, this, args in
                let owner = descriptor(this), methodName = text(args.first)
                let params = args.count > 1 ? (args[1].asObject?.items ?? []).map { descriptor($0.asObject) } : []
                guard let method = vm.findMethod(owner, methodName, params) else { return try failure("NoSuchMethodException", owner + "->" + methodName) }
                let object = DalvikObject(className: "Ljava/lang/reflect/Method;"); object.payload = method; return .ref(object)
            }
        }
        for name in ["getDeclaredFields", "getFields"] {
            vm.register("Ljava/lang/Class;", name) { vm, this, _ in
                let owner = descriptor(this), info = vm.classInfo(descriptor(this))
                let keys = Set((info?.fieldTypes.keys.map { $0 } ?? []) + (info?.staticValues.keys.map { $0 } ?? []))
                let array = DalvikObject(className: "[Ljava/lang/reflect/Field;")
                array.items = keys.sorted().map { key in
                    let field = DalvikObject(className: "Ljava/lang/reflect/Field;")
                    field.fields["owner"] = .ref(DalvikObject.string(owner)); field.fields["key"] = .ref(DalvikObject.string(key))
                    return .ref(field)
                }
                return .ref(array)
            }
        }
        vm.register("Ljava/lang/Class;", "getDeclaredField") { vm, this, args in
            let owner = descriptor(this), key = owner + "|" + text(args.first)
            guard let info = vm.classInfo(owner), info.fieldTypes[key] != nil || info.staticValues[key] != nil else { return try failure("NoSuchFieldException", key) }
            let object = DalvikObject(className: "Ljava/lang/reflect/Field;")
            object.fields["owner"] = .ref(DalvikObject.string(owner)); object.fields["key"] = .ref(DalvikObject.string(key)); return .ref(object)
        }
        vm.register("Ljava/lang/reflect/Method;", "invoke") { vm, this, args in
            guard let method = this?.payload as? DalvikMethod else { return .ref(nil) }
            return try vm.invoke(method, args.count > 1 ? args[1].asObject?.items ?? [] : [], args.first?.asObject) ?? .ref(nil)
        }
        vm.register("Ljava/lang/reflect/Method;", "getName") { _, this, _ in .ref(DalvikObject.string((this?.payload as? DalvikMethod)?.name ?? "")) }
        for name in ["get", "getBoolean", "set"] {
            vm.register("Ljava/lang/reflect/Field;", name) { vm, this, args in
                let owner = text(this?.fields["owner"]), key = text(this?.fields["key"])
                if name == "set" {
                    let value = args.count > 1 ? args[1] : .ref(nil)
                    if let object = args.first?.asObject { object.fields[key] = value }
                    else { vm.setStatic(owner, key.components(separatedBy: "|").last ?? "", value) }
                    return .ref(nil)
                }
                if let object = args.first?.asObject { return object.fields[key] ?? .ref(nil) }
                return try vm.staticValue(owner, key.components(separatedBy: "|").last ?? "", vm.classInfo(owner)?.fieldTypes[key] ?? "Ljava/lang/Object;")
            }
        }
        vm.register("Ljava/lang/reflect/AccessibleObject;", "setAccessible") { _, _, _ in .ref(nil) }
        vm.register("Ljava/lang/reflect/AccessibleObject;", "isAccessible") { _, _, _ in .int(1) }
        for owner in ["Ljava/lang/reflect/Method;", "Ljava/lang/reflect/Field;"] {
            vm.register(owner, "setAccessible") { _, _, _ in .ref(nil) }
        }
        vm.register("Ljava/lang/reflect/Array;", "getLength") { _, _, args in .int(Int32(args.first?.asObject?.items?.count ?? 0)) }
        vm.register("Ljava/lang/reflect/Array;", "newInstance") { _, _, args in
            let type = descriptor(args.first?.asObject), array = DalvikObject(className: "[" + descriptor(args.first?.asObject))
            array.items = Array(repeating: DalvikValue.defaultValue(type), count: max(0, Int(args.count > 1 ? args[1].intValue : 0)))
            return .ref(array)
        }
        for name in ["<init>", "getMessage", "toString", "printStackTrace"] {
            vm.register("Ljava/lang/Exception;", name) { _, this, args in
                if name == "<init>" { this?.payload = text(args.first); return .ref(nil) }
                return .ref(DalvikObject.string(this?.stringPayload ?? ""))
            }
            if let body = vm.nativeBody("Ljava/lang/Exception;", name) {
                for owner in ["Ljava/lang/Throwable;", "Ljava/lang/RuntimeException;", "Ljava/lang/ClassNotFoundException;", "Ljava/lang/NoSuchMethodException;", "Ljava/lang/NoSuchFieldException;"] { vm.register(owner, name, body) }
            }
        }
    }
}

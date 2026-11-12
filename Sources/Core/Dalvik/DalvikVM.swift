import Foundation

/// 一个够用的 Dalvik 解释器：执行 CatVod 插件里的采集器字节码。
///
/// 设计取向是"能让插件跑完"，不是完整 JVM：
/// * 覆盖插件的全部常用指令（invoke/分支/数组/宽类型/类型转换/switch）
/// * 外部类走 `DalvikNatives` 垫片，jar 自带的 1000 多个类原样解释执行
/// * 任何未实现的东西都抛出带位置的错误，绝不静默算错
final class DalvikVM {
    let image: DalvikImage
    private(set) var callCount = 0
    private(set) var stepCount = 0
    var traceEnabled = false
    private var statics: [String: DalvikValue] = [:]
    private var natives: [String: (DalvikVM, DalvikObject?, [DalvikValue]) throws -> DalvikValue] = [:]
    private var overrides: [String: (DalvikVM, DalvikObject?, [DalvikValue]) throws -> DalvikValue] = [:]
    private var stackNames: [String] = []
    private var caught: DalvikValue = .ref(nil)
    private(set) var invocationParameters: [String] = []
    let control: DalvikExecutionControl
    let httpSession: URLSession
    private let maximumSteps: Int
    private let deadline: TimeInterval

    /// 服务端请求记录，方便排查"为什么没内容"。
    private(set) var httpLog: [(url: String, code: Int)] = []
    /// 最近一次成功请求的地址；插件拼出 `?filter=true` 这类相对地址时用它补全。
    var baseURL: URL?

    init(image: DalvikImage, control: DalvikExecutionControl = DalvikExecutionControl(),
         maximumSteps: Int = 20_000_000, timeout: TimeInterval = 45,
         httpSession: URLSession = .shared) {
        self.image = image
        self.control = control
        self.maximumSteps = maximumSteps
        self.deadline = ProcessInfo.processInfo.systemUptime + timeout
        self.httpSession = httpSession
        DalvikNatives.install(self)
        DalvikHTMLSupport.install(self)
    }

    func registerOverride(_ owner: String, _ name: String,
                          _ body: @escaping (DalvikVM, DalvikObject?, [DalvikValue]) throws -> DalvikValue) {
        overrides[owner + "->" + name] = body
    }

    func checkExecution() throws {
        try control.checkCancellation()
        let location = stackNames.suffix(4).joined(separator: " ← ")
        guard stepCount < maximumSteps else { throw DalvikError.runtime("插件执行超过指令上限：" + location) }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw DalvikError.runtime("插件执行超时：" + location) }
    }

    func register(_ className: String, _ name: String,
                  _ body: @escaping (DalvikVM, DalvikObject?, [DalvikValue]) throws -> DalvikValue) {
        natives[className + "->" + name] = body
    }

    func nativeBody(_ className: String, _ name: String)
        -> ((DalvikVM, DalvikObject?, [DalvikValue]) throws -> DalvikValue)? {
        natives[className + "->" + name]
    }

    func registerAlias(_ className: String, _ name: String,
                       _ body: @escaping (DalvikVM, DalvikObject?, [DalvikValue]) throws -> DalvikValue) {
        let key = className + "->" + name
        if natives[key] == nil { natives[key] = body }
    }

    func log(_ url: String, _ code: Int) {
        httpLog.append((url, code))
        if httpLog.count > 40 { httpLog.removeFirst() }
    }

    // MARK: - 类与派发

    func classInfo(_ name: String) -> DalvikClassInfo? { image.classes[name] }

    func isSubclass(_ child: String, _ parent: String) -> Bool {
        if child == parent { return true }
        if parent == "Ljava/lang/Object;", !child.isEmpty { return true }
        if child.hasSuffix("Exception;") {
            if parent == "Ljava/lang/Throwable;" || parent == "Ljava/lang/Exception;" { return true }
            if parent == "Ljava/lang/RuntimeException;", ["NullPointerException;", "NumberFormatException;", "IllegalArgumentException;", "IndexOutOfBoundsException;"].contains(where: child.hasSuffix) { return true }
        }
        guard var info = classInfo(child) else { return false }
        var seen = Set<String>()
        while !seen.contains(info.name) {
            seen.insert(info.name)
            if info.name == parent || info.interfaces.contains(parent) { return true }
            for iface in info.interfaces where isSubclass(iface, parent) { return true }
            guard let superName = info.superName, let next = classInfo(superName) else { return false }
            info = next
        }
        return false
    }

    func findMethod(_ owner: String, _ name: String, _ params: [String]?) -> DalvikMethod? {
        guard var info = classInfo(owner) else { return nil }
        var seen = Set<String>()
        while !seen.contains(info.name) {
            seen.insert(info.name)
            if let list = info.methods[name] {
                for method in list where params == nil || method.params == params {
                    return method
                }
            }
            for iface in info.interfaces {
                if let found = findMethod(iface, name, params) { return found }
            }
            guard let superName = info.superName, let next = classInfo(superName) else { return nil }
            info = next
        }
        return nil
    }

    func ensureInitialized(_ className: String) throws {
        guard let info = classInfo(className), !info.initialized, !info.initializing else { return }
        info.initializing = true
        defer { info.initializing = false }
        for (key, value) in info.staticValues where statics[key] == nil { statics[key] = value }
        if let clinit = info.methods["<clinit>"]?.first {
            _ = try invoke(clinit, [], nil)
        }
        info.initialized = true
    }

    func staticValue(_ owner: String, _ name: String, _ type: String) throws -> DalvikValue {
        let key = owner + "|" + name
        if let value = statics[key] { return value }
        try ensureInitialized(owner)
        if let value = statics[key] { return value }
        let fallback = DalvikValue.defaultValue(type)
        statics[key] = fallback
        return fallback
    }

    func setStatic(_ owner: String, _ name: String, _ value: DalvikValue) {
        statics[owner + "|" + name] = value
    }

    // MARK: - 调用

    @discardableResult
    func invoke(_ method: DalvikMethod, _ args: [DalvikValue], _ this: DalvikObject?) throws -> DalvikValue? {
        try checkExecution()
        if let body = overrides[method.owner + "->" + method.name] { return try body(self, this, args) }
        if method.isStatic { try ensureInitialized(method.owner) }
        callCount += 1
        guard method.codeOffset > 0 else {
            return try callNative(method, args, this)
        }
        return try execute(method, args, this)
    }

    private func callNative(_ method: DalvikMethod, _ args: [DalvikValue],
                            _ this: DalvikObject?) throws -> DalvikValue? {
        let previous = invocationParameters
        invocationParameters = method.params
        defer { invocationParameters = previous }
        var owner: String? = method.owner
        var seen = Set<String>()
        while let current = owner, !seen.contains(current) {
            seen.insert(current)
            if let body = natives[current + "->" + method.name] {
                return try body(self, this, args)
            }
            owner = classInfo(current)?.superName
        }
        // 框架内部对象（okhttp 连接池、并发工具、安卓宿主）对采集结果没有影响。
        let allowed = ["Lokhttp3/", "Landroid/", "Ljavax/", "Ljava/util/concurrent/",
                       "Lkotlin", "Ljava/io/"]
        if allowed.contains(where: { method.owner.hasPrefix($0) }) {
            return .ref(nil)
        }
        throw DalvikError.java("缺少实现 \(method.owner)->\(method.name)(\(method.params.joined())) ← " + stackNames.suffix(3).joined(separator: " ← "))
    }

    func resolve(_ owner: String, _ name: String, _ params: [String], kind: String,
                 this: DalvikObject?) throws -> DalvikMethod {
        if kind == "virtual" || kind == "interface" {
            if let this, let found = findMethod(this.className, name, params) {
                return found
            }
            // 宿主对象也要按实际类型派发；混淆 switch 把 String 当 Object 调用 hashCode。
            var current = this?.className
            var seen = Set<String>()
            while let type = current, seen.insert(type).inserted {
                if nativeBody(type, name) != nil {
                    return DalvikMethod(owner: type, name: name, params: params,
                                        ret: "Ljava/lang/Object;", access: 0, codeOffset: 0)
                }
                current = classInfo(type)?.superName
            }
        }
        if let found = findMethod(owner, name, params) { return found }
        let allowed = ["Ljava/", "Ljavax/", "Landroid/", "Lokhttp3/", "Lorg/json/",
                       "Lcom/github/catvod/crawler/", "Lkotlin"]
        if allowed.contains(where: { owner.hasPrefix($0) }) || nativeBody(owner, name) != nil {
            return DalvikMethod(owner: owner, name: name, params: params,
                                ret: "Ljava/lang/Object;", access: 0, codeOffset: 0)
        }
        throw DalvikError.java("找不到方法 \(owner)->\(name)")
    }

    // MARK: - 执行

    private func execute(_ method: DalvikMethod, _ args: [DalvikValue],
                         _ this: DalvikObject?) throws -> DalvikValue? {
        guard let code = image.code(method.codeOffset) else {
            throw DalvikError.format("方法 \(method.name) 没有代码")
        }
        stackNames.append(method.owner + "->" + method.name)
        defer { stackNames.removeLast() }
        if stackNames.count > 400 {
            throw DalvikError.runtime("调用过深: " + stackNames.suffix(6).joined(separator: " < "))
        }

        let regs = code.registers
        var registers = [DalvikValue](repeating: .int(0), count: max(regs, 1))
        var slots: [DalvikValue] = []
        if let this { slots.append(.ref(this)) }
        for (index, param) in method.params.enumerated() {
            slots.append(index < args.count ? args[index] : DalvikValue.defaultValue(param))
            if param == "J" || param == "D" { slots.append(.int(0)) }
        }
        let start = regs - slots.count
        for (index, value) in slots.enumerated() where start + index >= 0 {
            registers[start + index] = value
        }

        let bytes = image.bytes
        let base = code.base
        var pc = 0
        var pending: DalvikValue = .int(0)

        func u(_ i: Int) -> Int { DalvikImage.u16(bytes, base + (pc + i) * 2) }
        func s16(_ i: Int) -> Int { DalvikImage.s16(bytes, base + (pc + i) * 2) }
        func s32(_ i: Int) -> Int { DalvikImage.s32(bytes, base + (pc + i) * 2) }

        while pc >= 0 && pc < code.size {
            if stepCount % 1024 == 0 { try checkExecution() }
            stepCount += 1
            let w = u(0)
            let op = w & 0xFF
            let a8 = (w >> 8) & 0xFF
            let a4 = (w >> 8) & 0xF
            let b4 = (w >> 12) & 0xF
            var next = pc + DalvikVM.sizes[op]

            do {
                switch op {
                case 0x00:
                    break

                // ---- 常量 ----
                case 0x12:
                    let literal = (w >> 12) & 0xF
                    registers[a4] = .int(Int32(literal >= 8 ? literal - 16 : literal))
                case 0x13:
                    registers[a8] = .int(Int32(s16(1)))
                case 0x14:
                    registers[a8] = .int(Int32(truncatingIfNeeded: s32(1)))
                case 0x15:
                    registers[a8] = .int(Int32(truncatingIfNeeded: s16(1) << 16))
                case 0x16:
                    registers[a8] = .long(Int64(s16(1)))
                    if a8 + 1 < registers.count { registers[a8 + 1] = .int(0) }
                case 0x17:
                    registers[a8] = .long(Int64(s32(1)))
                    if a8 + 1 < registers.count { registers[a8 + 1] = .int(0) }
                case 0x18:
                    let raw = UInt64(u(1)) | (UInt64(u(2)) << 16) | (UInt64(u(3)) << 32) | (UInt64(u(4)) << 48)
                    registers[a8] = .long(Int64(bitPattern: raw))
                    if a8 + 1 < registers.count { registers[a8 + 1] = .int(0) }
                case 0x19:
                    registers[a8] = .long(Int64(s16(1)) << 48)
                    if a8 + 1 < registers.count { registers[a8 + 1] = .int(0) }
                case 0x1A:
                    registers[a8] = .ref(DalvikObject.string(image.string(u(1))))
                case 0x1B:
                    registers[a8] = .ref(DalvikObject.string(image.string(s32(1))))
                case 0x1C:
                    registers[a8] = .ref(DalvikObject.javaClass(image.typeName(u(1))))

                // ---- 移动 ----
                case 0x01:
                    registers[a4] = registers[b4]
                case 0x02:
                    let source = u(1)
                    if source < registers.count { registers[a8] = registers[source] }
                case 0x04:
                    registers[a4] = registers[b4]
                    if a4 + 1 < registers.count { registers[a4 + 1] = .int(0) }
                case 0x05:
                    let source = u(1)
                    if source < registers.count { registers[a8] = registers[source] }
                    if a8 + 1 < registers.count { registers[a8 + 1] = .int(0) }
                case 0x07:
                    registers[a4] = registers[b4]
                case 0x08:
                    let source = u(1)
                    if source < registers.count { registers[a8] = registers[source] }
                case 0x03, 0x06, 0x09:
                    let destination = u(1), source = u(2)
                    guard destination < registers.count, source < registers.count else {
                        throw DalvikError.format("move/16 寄存器越界")
                    }
                    registers[destination] = registers[source]
                    if op == 0x06, destination + 1 < registers.count { registers[destination + 1] = .int(0) }

                // ---- 返回 ----
                case 0x0E:
                    return nil
                case 0x0F, 0x10, 0x11:
                    return registers[a8]

                // ---- move-result ----
                case 0x0A:
                    registers[a8] = pending
                case 0x0B:
                    registers[a8] = pending
                    if a8 + 1 < registers.count { registers[a8 + 1] = .int(0) }
                case 0x0C:
                    registers[a8] = pending

                // ---- 异常 / 同步 ----
                case 0x0D:
                    registers[a8] = caught
                case 0x1D, 0x1E:
                    break
                case 0x27:
                    if let object = registers[a8].asObject { throw DalvikThrown(object: object) }

                // ---- 类型 ----
                case 0x1F:
                    break
                case 0x20:
                    let target = image.typeName(u(1))
                    let value = registers[b4]
                    var matches = false
                    if let object = value.asObject {
                        matches = object.className == target || isSubclass(object.className, target)
                    }
                    registers[a4] = .int(matches ? 1 : 0)
                case 0x21:
                    let items = registers[b4].asObject?.items ?? []
                    registers[a4] = .int(Int32(items.count))
                case 0x22:
                    let name = image.typeName(u(1))
                    try ensureInitialized(name)
                    registers[a8] = .ref(DalvikObject(className: name))
                case 0x23:
                    let type = image.typeName(u(1))
                    let count = Int(registers[b4].intValue)
                    let object = DalvikObject(className: type)
                    object.payload = [DalvikValue](repeating: DalvikValue.defaultValue(String(type.dropFirst())),
                                                   count: max(0, count))
                    registers[a4] = .ref(object)
                case 0x24, 0x25:
                    let type = image.typeName(u(1))
                    var values: [DalvikValue] = []
                    if op == 0x24 {
                        let count = (w >> 12) & 0xF
                        let unit = u(2)
                        let order = [unit & 0xF, (unit >> 4) & 0xF, (unit >> 8) & 0xF, (unit >> 12) & 0xF, a4]
                        for i in 0..<count where i < order.count {
                            let index = order[i]
                            values.append(index < registers.count ? registers[index] : .int(0))
                        }
                    } else {
                        let count = a8
                        let first = u(2)
                        for i in 0..<count {
                            let index = first + i
                            values.append(index < registers.count ? registers[index] : .int(0))
                        }
                    }
                    let object = DalvikObject(className: type)
                    object.payload = values
                    pending = .ref(object)
                case 0x26:
                    let payload = pc + s32(1)
                    fillArray(registers[a8].asObject, payload: payload, base: base)
                    _ = payload

                // ---- 跳转 ----
                case 0x28:
                    let offset = a8 >= 128 ? a8 - 256 : a8
                    next = pc + offset
                case 0x29:
                    next = pc + s16(1)
                case 0x2A:
                    next = pc + s32(1)
                case 0x2B:
                    let payload = pc + s32(1)
                    let size = DalvikImage.u16(bytes, base + payload * 2 + 2)
                    let first = DalvikImage.s32(bytes, base + payload * 2 + 4)
                    let value = Int(registers[a8].intValue)
                    for i in 0..<size where first + i == value {
                        next = pc + DalvikImage.s32(bytes, base + payload * 2 + 8 + i * 4)
                        break
                    }
                case 0x2C:
                    let payload = pc + s32(1)
                    let size = DalvikImage.u16(bytes, base + payload * 2 + 2)
                    let value = Int(registers[a8].intValue)
                    for i in 0..<size {
                        let key = DalvikImage.s32(bytes, base + payload * 2 + 4 + i * 4)
                        if key == value {
                            next = pc + DalvikImage.s32(bytes, base + payload * 2 + 4 + size * 4 + i * 4)
                            break
                        }
                    }

                // ---- 比较 / 条件 ----
                case 0x2D, 0x2E, 0x2F, 0x30, 0x31:
                    let x = registers[u(1) & 0xFF].doubleValue
                    let y = registers[(u(1) >> 8) & 0xFF].doubleValue
                    let nan = x.isNaN || y.isNaN
                    let result: Int32
                    if nan {
                        result = (op == 0x2E || op == 0x30) ? 1 : -1
                    } else {
                        result = x < y ? -1 : (x > y ? 1 : 0)
                    }
                    registers[a8] = .int(result)
                case 0x32...0x37:
                    let x = registers[a4]
                    let y = registers[b4]
                    let eq = x.equalsRegister(y)
                    let lt = x.doubleValue < y.doubleValue
                    let gt = x.doubleValue > y.doubleValue
                    let ok: Bool
                    switch op {
                    case 0x32: ok = eq
                    case 0x33: ok = !eq
                    case 0x34: ok = lt
                    case 0x35: ok = !lt
                    case 0x36: ok = gt
                    default: ok = !gt
                    }
                    if ok { next = pc + s16(1) }
                case 0x38...0x3D:
                    let register = registers[a8]
                    let value = register.intValue
                    let ok: Bool
                    switch op {
                    case 0x38: ok = register.isZero
                    case 0x39: ok = !register.isZero
                    case 0x3A: ok = value < 0
                    case 0x3B: ok = value >= 0
                    case 0x3C: ok = value > 0
                    default: ok = value <= 0
                    }
                    if ok { next = pc + s16(1) }

                // ---- 数组 ----
                case 0x44...0x51:
                    let packed = u(1)
                    let array = registers[packed & 0xFF].asObject
                    let index = Int(registers[(packed >> 8) & 0xFF].intValue)
                    var list = array?.items ?? []
                    if op <= 0x4A {
                        let value = index >= 0 && index < list.count ? list[index] : .int(0)
                        registers[a8] = value
                        if op == 0x45, a8 + 1 < registers.count { registers[a8 + 1] = .int(0) }
                    } else if index >= 0 && index < list.count {
                        list[index] = registers[a8]
                        array?.items = list
                    }

                // ---- 字段 ----
                case 0x52...0x5F:
                    let ref = image.fieldRef(u(1))
                    let key = ref.owner + "|" + ref.name
                    if op <= 0x58 {
                        let object = registers[b4].asObject
                        registers[a4] = object?.fields[key] ?? DalvikValue.defaultValue(ref.type)
                        if op == 0x53, a4 + 1 < registers.count { registers[a4 + 1] = .int(0) }
                    } else {
                        registers[b4].asObject?.fields[key] = registers[a4]
                    }
                case 0x60...0x6D:
                    let ref = image.fieldRef(u(1))
                    if op <= 0x66 {
                        registers[a8] = try staticValue(ref.owner, ref.name, ref.type)
                        if op == 0x61, a8 + 1 < registers.count { registers[a8 + 1] = .int(0) }
                    } else {
                        setStatic(ref.owner, ref.name, registers[a8])
                    }

                // ---- 调用 ----
                case 0x6E...0x72, 0x74...0x78:
                    let ref = image.methodRef(u(1))
                    var registerIndexes: [Int] = []
                    var count = 0
                    let kind: String
                    if op <= 0x72 {
                        count = (w >> 12) & 0xF
                        let unit = u(2)
                        registerIndexes = [unit & 0xF, (unit >> 4) & 0xF,
                                           (unit >> 8) & 0xF, (unit >> 12) & 0xF, a4]
                        kind = ["virtual", "super", "direct", "static", "interface"][op - 0x6E]
                    } else {
                        count = a8
                        let first = u(2)
                        registerIndexes = (0..<max(count, 1)).map { first + $0 }
                        kind = ["virtual", "super", "direct", "static", "interface"][op - 0x74]
                    }
                    var words: [DalvikValue] = []
                    for i in 0..<count {
                        let index = i < registerIndexes.count ? registerIndexes[i] : 0
                        words.append(index < registers.count ? registers[index] : .int(0))
                    }
                    var target: DalvikObject?
                    var argumentStart = 0
                    if kind != "static" {
                        target = words.first?.asObject
                        argumentStart = 1
                    }
                    var arguments: [DalvikValue] = []
                    var cursor = argumentStart
                    for param in ref.params {
                        arguments.append(cursor < words.count ? words[cursor] : DalvikValue.defaultValue(param))
                        cursor += (param == "J" || param == "D") ? 2 : 1
                    }
                    let method = try resolve(ref.owner, ref.name, ref.params, kind: kind, this: target)
                    if traceEnabled {
                        DalvikVM.trace(ref.owner + "->" + ref.name)
                    }
                    if let result = try invoke(method, arguments, target) {
                        pending = result
                    } else {
                        pending = .int(0)
                    }

                // ---- 运算 ----
                case 0x7B...0x8F:
                    let value = registers[b4]
                    registers[a4] = unary(op, value)
                    if [0x7D, 0x7E, 0x81, 0x83, 0x85, 0x86, 0x88, 0x89, 0x8B, 0x8C].contains(op),
                       a4 + 1 < registers.count {
                        registers[a4 + 1] = .int(0)
                    }
                case 0x90...0xAF:
                    let packed = u(1)
                    let left = registers[packed & 0xFF]
                    let right = registers[(packed >> 8) & 0xFF]
                    registers[a8] = binary(op, left, right)
                    if [0x9B, 0x9C, 0x9D, 0x9E, 0x9F, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4,
                        0xA5, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF].contains(op),
                       a8 + 1 < registers.count {
                        registers[a8 + 1] = .int(0)
                    }
                case 0xB0...0xCF:
                    registers[a4] = binary(op - 0xB0 + 0x90, registers[a4], registers[b4])
                case 0xD0...0xD7:
                    let left = registers[b4]
                    let right = DalvikValue.int(Int32(s16(1)))
                    registers[a4] = op == 0xD1 ? binary(0x91, right, left) : binary(op - 0xD0 + 0x90, left, right)
                case 0xD8...0xE2:
                    let packed = u(1)
                    let left = registers[packed & 0xFF]
                    let right = DalvikValue.int(Int32(Int8(bitPattern: UInt8(packed >> 8))))
                    registers[a8] = op == 0xD9 ? binary(0x91, right, left) : binary(op - 0xD8 + 0x90, left, right)

                default:
                    throw DalvikError.runtime(String(format: "未实现指令 0x%02X @%d in %@->%@",
                                                     op, pc, method.owner, method.name))
                }
            } catch let thrown as DalvikThrown {
                let table = image.handlers(code, pc: pc)
                var handler: Int?
                for (type, address) in table {
                    if type == nil || isSubclass(thrown.object.className, type!) {
                        handler = address
                        break
                    }
                }
                guard let handler else { throw thrown }
                caught = .ref(thrown.object)
                next = handler
            }
            pc = next
        }
        guard pc == code.size else { throw DalvikError.format("跳转超出方法指令范围") }
        return nil
    }

    private func fillArray(_ object: DalvikObject?, payload: Int, base: Int) {
        guard let object, var items = object.items else { return }
        let bytes = image.bytes
        let width = DalvikImage.u16(bytes, base + payload * 2 + 2)
        let size = DalvikImage.u32(bytes, base + payload * 2 + 4)
        let dataOffset = base + (payload + 4) * 2
        for i in 0..<min(size, items.count) {
            let start = dataOffset + i * width
            var raw: UInt64 = 0
            for k in 0..<width where start + k < bytes.count {
                raw |= UInt64(bytes[start + k]) << (8 * k)
            }
            switch width {
            case 1: items[i] = .int(Int32(raw))
            case 2: items[i] = .int(Int32(Int16(bitPattern: UInt16(raw))))
            case 4: items[i] = .int(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
            default: items[i] = .long(Int64(bitPattern: raw))
            }
        }
        object.items = items
    }

    private func unary(_ op: Int, _ value: DalvikValue) -> DalvikValue {
        switch op {
        case 0x7B: return .int(0 &- value.intValue)
        case 0x7C: return .int(~value.intValue)
        case 0x7D: return .long(0 &- value.longValue)
        case 0x7E: return .long(~value.longValue)
        case 0x7F: return .float(-Float(value.doubleValue))
        case 0x80: return .double(-value.doubleValue)
        case 0x81: return .long(value.longValue)
        case 0x82: return .float(Float(value.intValue))
        case 0x83: return .double(Double(value.intValue))
        case 0x84: return .int(Int32(truncatingIfNeeded: value.longValue))
        case 0x85: return .float(Float(value.longValue))
        case 0x86: return .double(Double(value.longValue))
        case 0x87: return .int(Int32(value.doubleValue))
        case 0x88: return .long(Int64(value.doubleValue))
        case 0x89: return .double(value.doubleValue)
        case 0x8A: return .int(Int32(value.doubleValue))
        case 0x8B: return .long(Int64(value.doubleValue))
        case 0x8C: return .float(Float(value.doubleValue))
        case 0x8D: return .int(Int32(Int8(truncatingIfNeeded: value.intValue)))
        case 0x8E: return .int(Int32(UInt16(truncatingIfNeeded: value.intValue)))
        case 0x8F: return .int(Int32(Int16(truncatingIfNeeded: value.intValue)))
        default: return value
        }
    }

    private func binary(_ op: Int, _ left: DalvikValue, _ right: DalvikValue) -> DalvikValue {
        switch op {
        case 0x90: return .int(left.intValue &+ right.intValue)
        case 0x91: return .int(left.intValue &- right.intValue)
        case 0x92: return .int(left.intValue &* right.intValue)
        case 0x93:
            let divisor = right.intValue
            return .int(divisor == 0 ? 0 : (divisor == -1 ? (left.intValue == Int32.min ? Int32.min : 0 &- left.intValue) : left.intValue / divisor))
        case 0x94:
            let divisor = right.intValue
            return .int(divisor == 0 || divisor == -1 ? 0 : left.intValue % divisor)
        case 0x95: return .int(left.intValue & right.intValue)
        case 0x96: return .int(left.intValue | right.intValue)
        case 0x97: return .int(left.intValue ^ right.intValue)
        case 0x98: return .int(left.intValue << (right.intValue & 31))
        case 0x99: return .int(left.intValue >> (right.intValue & 31))
        case 0x9A: return .int(Int32(bitPattern: UInt32(bitPattern: left.intValue) >> (UInt32(bitPattern: right.intValue) & 31)))
        case 0x9B: return .long(left.longValue &+ right.longValue)
        case 0x9C: return .long(left.longValue &- right.longValue)
        case 0x9D: return .long(left.longValue &* right.longValue)
        case 0x9E:
            let divisor = right.longValue
            return .long(divisor == 0 ? 0 : (divisor == -1 ? 0 &- left.longValue : left.longValue / divisor))
        case 0x9F:
            let divisor = right.longValue
            return .long(divisor == 0 || divisor == -1 ? 0 : left.longValue % divisor)
        case 0xA0: return .long(left.longValue & right.longValue)
        case 0xA1: return .long(left.longValue | right.longValue)
        case 0xA2: return .long(left.longValue ^ right.longValue)
        case 0xA3: return .long(left.longValue << (right.longValue & 63))
        case 0xA4: return .long(left.longValue >> (right.longValue & 63))
        case 0xA5: return .long(Int64(bitPattern: UInt64(bitPattern: left.longValue) >> (UInt64(bitPattern: right.longValue) & 63)))
        case 0xA6: return .float(Float(left.doubleValue + right.doubleValue))
        case 0xA7: return .float(Float(left.doubleValue - right.doubleValue))
        case 0xA8: return .float(Float(left.doubleValue * right.doubleValue))
        case 0xA9: return .float(Float(left.doubleValue / right.doubleValue))
        case 0xAA: return .float(Float(left.doubleValue.truncatingRemainder(dividingBy: right.doubleValue)))
        case 0xAB: return .double(left.doubleValue + right.doubleValue)
        case 0xAC: return .double(left.doubleValue - right.doubleValue)
        case 0xAD: return .double(left.doubleValue * right.doubleValue)
        case 0xAE: return .double(left.doubleValue / right.doubleValue)
        case 0xAF: return .double(left.doubleValue.truncatingRemainder(dividingBy: right.doubleValue))
        default: return left
        }
    }

    // MARK: - 指令长度

    static let sizes = DexInstruction.sizes

    static var traceHandler: ((String) -> Void)?
    private static func trace(_ text: String) {
        if let handler = traceHandler { handler(text) }
    }
}

struct DalvikThrown: LocalizedError {
    let object: DalvikObject
    var errorDescription: String? { "插件异常：\(object.className) \(object.stringPayload ?? "")" }
}

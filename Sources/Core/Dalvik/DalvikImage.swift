import Foundation

/// 解释执行 CatVod 插件所需的最小 DEX 镜像：类、方法、静态初值、code_item。
///
/// 为什么不用现成的 `DexFile`：那个只够静态读字符串常量，没有 proto / 访问标志 /
/// 静态初值 / try-catch，跑不了字节码。这里单独解析一份，避免把两边搅在一起。
final class DalvikImage {
    let bytes: [UInt8]

    private var stringCache: [Int: String] = [:]
    private let stringCount: Int
    private let stringOffset: Int
    private let typeOffset: Int
    private let protoOffset: Int
    private let fieldOffset: Int
    private let methodOffset: Int
    private let classCount: Int
    private let classOffset: Int

    var classes: [String: DalvikClassInfo] = [:]

    init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count > 112 else { throw DalvikError.format("DEX 太短") }
        stringCount = DalvikImage.u32(bytes, 56)
        stringOffset = DalvikImage.u32(bytes, 60)
        typeOffset = DalvikImage.u32(bytes, 68)
        protoOffset = DalvikImage.u32(bytes, 76)
        fieldOffset = DalvikImage.u32(bytes, 84)
        methodOffset = DalvikImage.u32(bytes, 92)
        classCount = DalvikImage.u32(bytes, 96)
        classOffset = DalvikImage.u32(bytes, 100)
        try load()
    }

    // MARK: - 基础读取

    static func u16(_ b: [UInt8], _ o: Int) -> Int {
        guard o >= 0, o + 1 < b.count else { return 0 }
        return Int(b[o]) | (Int(b[o + 1]) << 8)
    }

    static func s16(_ b: [UInt8], _ o: Int) -> Int {
        let v = u16(b, o)
        return v >= 0x8000 ? v - 0x10000 : v
    }

    static func u32(_ b: [UInt8], _ o: Int) -> Int {
        guard o >= 0, o + 3 < b.count else { return 0 }
        return Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16) | (Int(b[o + 3]) << 24)
    }

    static func s32(_ b: [UInt8], _ o: Int) -> Int {
        Int(Int32(bitPattern: UInt32(truncatingIfNeeded: u32(b, o))))
    }

    func uleb(_ offset: Int) -> (value: Int, next: Int) {
        var result = 0, shift = 0, p = offset
        while p < bytes.count {
            let byte = Int(bytes[p]); p += 1
            result |= (byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, p) }
            shift += 7
            if shift > 35 { break }
        }
        return (result, p)
    }

    func sleb(_ offset: Int) -> (value: Int, next: Int) {
        var result = 0, shift = 0, p = offset
        var byte = 0
        while p < bytes.count {
            byte = Int(bytes[p]); p += 1
            result |= (byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 { break }
        }
        if shift < 64, byte & 0x40 != 0 { result |= -(1 << shift) }
        return (result, p)
    }

    func string(_ index: Int) -> String {
        if let cached = stringCache[index] { return cached }
        guard index >= 0, index < stringCount else { return "" }
        let dataOffset = DalvikImage.u32(bytes, stringOffset + index * 4)
        let (_, start) = uleb(dataOffset)
        var end = start
        while end < bytes.count, bytes[end] != 0 { end += 1 }
        let raw = Data(bytes[start..<end])
        let value = String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self)
        stringCache[index] = value
        return value
    }

    func typeName(_ index: Int) -> String {
        string(DalvikImage.u32(bytes, typeOffset + index * 4))
    }

    func proto(_ index: Int) -> (ret: String, params: [String]) {
        let off = protoOffset + index * 12
        let retIdx = DalvikImage.u32(bytes, off + 4)
        let paramsOff = DalvikImage.u32(bytes, off + 8)
        var params: [String] = []
        if paramsOff > 0 {
            let n = DalvikImage.u32(bytes, paramsOff)
            for i in 0..<n {
                params.append(typeName(DalvikImage.u16(bytes, paramsOff + 4 + i * 2)))
            }
        }
        return (typeName(retIdx), params)
    }

    func fieldRef(_ index: Int) -> (owner: String, name: String, type: String) {
        let off = fieldOffset + index * 8
        return (typeName(DalvikImage.u16(bytes, off)),
                string(DalvikImage.u32(bytes, off + 4)),
                typeName(DalvikImage.u16(bytes, off + 2)))
    }

    func methodRef(_ index: Int) -> (owner: String, name: String, params: [String], ret: String) {
        let off = methodOffset + index * 8
        let owner = typeName(DalvikImage.u16(bytes, off))
        let protoIdx = DalvikImage.u16(bytes, off + 2)
        let name = string(DalvikImage.u32(bytes, off + 4))
        let sig = proto(protoIdx)
        return (owner, name, sig.params, sig.ret)
    }

    // MARK: - 类

    private func load() throws {
        for i in 0..<classCount {
            let off = classOffset + i * 32
            let name = typeName(DalvikImage.u32(bytes, off))
            let info = DalvikClassInfo(name: name)
            let superIdx = DalvikImage.u32(bytes, off + 8)
            if superIdx != 0xFFFF_FFFF { info.superName = typeName(superIdx) }
            let ifacesOff = DalvikImage.u32(bytes, off + 12)
            if ifacesOff > 0 {
                let n = DalvikImage.u32(bytes, ifacesOff)
                for k in 0..<n {
                    info.interfaces.append(typeName(DalvikImage.u16(bytes, ifacesOff + 4 + k * 2)))
                }
            }
            let classData = DalvikImage.u32(bytes, off + 24)
            let staticValues = DalvikImage.u32(bytes, off + 28)
            if classData > 0 { parseClassData(info, classData, staticValues) }
            classes[name] = info
        }
    }

    private func parseClassData(_ info: DalvikClassInfo, _ offset: Int, _ staticValues: Int) {
        var p = offset
        let staticFields = uleb(p).value; p = uleb(p).next
        let instanceFields = uleb(p).value; p = uleb(p).next
        let directMethods = uleb(p).value; p = uleb(p).next
        let virtualMethods = uleb(p).value; p = uleb(p).next

        let values = staticValues > 0 ? encodedArray(staticValues) : []
        var index = 0
        for i in 0..<staticFields {
            let step = uleb(p); p = step.next
            let access = uleb(p); p = access.next
            _ = access.value
            index += step.value
            let ref = fieldRef(index)
            let value = i < values.count ? values[i] : DalvikValue.defaultValue(ref.type)
            info.staticValues[ref.owner + "|" + ref.name] = value
        }
        index = 0
        for _ in 0..<instanceFields {
            let step = uleb(p); p = step.next
            let access = uleb(p); p = access.next
            _ = access.value
            index += step.value
            let ref = fieldRef(index)
            info.fieldTypes[ref.owner + "|" + ref.name] = ref.type
        }
        for count in [directMethods, virtualMethods] {
            index = 0
            for _ in 0..<count {
                let step = uleb(p); p = step.next
                let access = uleb(p); p = access.next
                let code = uleb(p); p = code.next
                index += step.value
                let ref = methodRef(index)
                let m = DalvikMethod(owner: info.name, name: ref.name, params: ref.params,
                                     ret: ref.ret, access: UInt32(access.value),
                                     codeOffset: code.value)
                info.methods[ref.name, default: []].append(m)
            }
        }
    }

    private func encodedArray(_ offset: Int) -> [DalvikValue] {
        var (size, p) = uleb(offset)
        var out: [DalvikValue] = []
        for _ in 0..<size {
            let (value, next) = encodedValue(p)
            p = next
            out.append(value)
        }
        return out
    }

    private func encodedValue(_ offset: Int) -> (DalvikValue, Int) {
        var p = offset
        guard p < bytes.count else { return (.int(0), p) }
        let header = Int(bytes[p]); p += 1
        let type = header & 0x1F
        let arg = header >> 5
        switch type {
        case 0x00:
            return (.ref(nil), p)
        case 0x02, 0x03, 0x04, 0x06, 0x18:
            let n = arg + 1
            var raw: UInt64 = 0
            for i in 0..<n where p + i < bytes.count {
                raw |= UInt64(bytes[p + i]) << (8 * i)
            }
            p += n
            // 按字节数做符号扩展
            if n < 8 {
                let signBit: UInt64 = UInt64(1) << UInt64(n * 8 - 1)
                if raw & signBit != 0 { raw |= ~UInt64(0) << UInt64(n * 8) }
            }
            if type == 0x06 || type == 0x18 { return (.long(Int64(bitPattern: raw)), p) }
            return (.int(Int32(bitPattern: UInt32(truncatingIfNeeded: raw))), p)
        case 0x17:
            let n = arg + 1
            var raw = 0
            for i in 0..<n where p + i < bytes.count { raw |= Int(bytes[p + i]) << (8 * i) }
            p += n
            return (.ref(DalvikObject.string(string(raw))), p)
        case 0x1C:
            var (count, next) = uleb(p)
            for _ in 0..<count {
                let skipped = skipValue(next)
                next = skipped
            }
            count = 0
            return (.ref(nil), next)
        case 0x1E:                      // null
            return (.ref(nil), p)
        case 0x1F:                      // boolean
            return (.int(arg == 0 ? 0 : 1), p)
        default:
            return (.int(0), skipValue(offset))
        }
    }

    /// 只求跳过，不构造值。
    private func skipValue(_ offset: Int) -> Int {
        var p = offset
        guard p < bytes.count else { return p }
        let header = Int(bytes[p]); p += 1
        let type = header & 0x1F
        let arg = header >> 5
        switch type {
        case 0x00, 0x1E:
            return p
        case 0x02, 0x03, 0x04, 0x06, 0x18, 0x17:
            return p + arg + 1
        case 0x1F:
            return p
        case 0x1C:
            var (count, next) = uleb(p)
            for _ in 0..<count { next = skipValue(next) }
            return next
        case 0x1D:
            var (count, next) = uleb(p)
            for _ in 0..<count {
                next = skipValue(uleb(next).next)
                next = skipValue(next)
            }
            return next
        default:
            return p
        }
    }

    // MARK: - 代码

    func code(_ offset: Int) -> DalvikCode? {
        guard offset > 0, offset + 16 <= bytes.count else { return nil }
        let registers = DalvikImage.u16(bytes, offset)
        let ins = DalvikImage.u16(bytes, offset + 2)
        let tries = DalvikImage.u16(bytes, offset + 6)
        let size = DalvikImage.u32(bytes, offset + 12)
        guard size <= (bytes.count - offset - 16) / 2 else { return nil }
        return DalvikCode(registers: registers, ins: ins, size: size,
                          base: offset + 16, tries: tries,
                          triesOffset: offset + 16 + size * 2 + (tries > 0 && size % 2 != 0 ? 2 : 0))
    }

    /// 命中的 try 区块，返回 [(捕获类型或 nil, handler 地址)]。
    func handlers(_ code: DalvikCode, pc: Int) -> [(String?, Int)] {
        guard code.tries > 0 else { return [] }
        let handlersOffset = code.triesOffset + code.tries * 8
        for i in 0..<code.tries {
            let base = code.triesOffset + i * 8
            let start = DalvikImage.u32(bytes, base)
            let count = DalvikImage.u16(bytes, base + 4)
            let handler = DalvikImage.u16(bytes, base + 6)
            guard pc >= start, pc < start + count else { continue }
            var out: [(String?, Int)] = []
            var p = handlersOffset + handler
            let size = sleb(p).value
            p = sleb(p).next
            for _ in 0..<abs(size) {
                let typeIdx = uleb(p).value; p = uleb(p).next
                let addr = uleb(p).value; p = uleb(p).next
                out.append((typeName(typeIdx), addr))
            }
            if size <= 0 {
                let addr = uleb(p).value
                out.append((nil, addr))
            }
            return out
        }
        return []
    }
}

struct DalvikCode {
    let registers: Int
    let ins: Int
    let size: Int
    let base: Int
    let tries: Int
    let triesOffset: Int
}

struct DalvikMethod {
    let owner: String
    let name: String
    let params: [String]
    let ret: String
    let access: UInt32
    let codeOffset: Int

    var isStatic: Bool { access & 0x0008 != 0 }
}

final class DalvikClassInfo {
    let name: String
    var superName: String?
    var interfaces: [String] = []
    var methods: [String: [DalvikMethod]] = [:]
    var staticValues: [String: DalvikValue] = [:]
    var fieldTypes: [String: String] = [:]
    var initialized = false
    var initializing = false

    init(name: String) { self.name = name }
}

enum DalvikError: LocalizedError {
    case format(String)
    case runtime(String)
    case java(String)

    var errorDescription: String? {
        switch self {
        case .format(let m): return "插件格式: " + m
        case .runtime(let m): return "解释器: " + m
        case .java(let m): return "插件异常: " + m
        }
    }
}

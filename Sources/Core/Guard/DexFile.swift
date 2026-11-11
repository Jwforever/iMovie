import Foundation

/// 最小 DEX 读取器：只解析规则提取需要的索引表、class_data 与 code_item。
/// 不执行指令，只做字节级读取。
final class DexFile {
    let bytes: [UInt8]

    let stringIDsSize: Int
    let stringIDsOffset: Int
    let typeIDsSize: Int
    let typeIDsOffset: Int
    let protoIDsSize: Int
    let protoIDsOffset: Int
    let fieldIDsSize: Int
    let fieldIDsOffset: Int
    let methodIDsSize: Int
    let methodIDsOffset: Int
    let classDefsSize: Int
    let classDefsOffset: Int

    private var stringCache: [Int: String] = [:]

    init(data: Data) throws {
        let raw = [UInt8](data)
        guard raw.count >= 0x70 else { throw GuardContainerError.invalid("DEX 头部不完整。") }
        guard raw[0] == 0x64, raw[1] == 0x65, raw[2] == 0x78 else {
            throw GuardContainerError.invalid("不是有效的 DEX 文件。")
        }
        bytes = raw
        stringIDsSize = DexFile.uint32(raw, 56)
        stringIDsOffset = DexFile.uint32(raw, 60)
        typeIDsSize = DexFile.uint32(raw, 64)
        typeIDsOffset = DexFile.uint32(raw, 68)
        protoIDsSize = DexFile.uint32(raw, 72)
        protoIDsOffset = DexFile.uint32(raw, 76)
        fieldIDsSize = DexFile.uint32(raw, 80)
        fieldIDsOffset = DexFile.uint32(raw, 84)
        methodIDsSize = DexFile.uint32(raw, 88)
        methodIDsOffset = DexFile.uint32(raw, 92)
        classDefsSize = DexFile.uint32(raw, 96)
        classDefsOffset = DexFile.uint32(raw, 100)
    }

    // MARK: - 基础读取

    static func uint16(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }

    static func int16(_ bytes: [UInt8], _ offset: Int) -> Int {
        let raw = uint16(bytes, offset)
        return raw >= 0x8000 ? raw - 0x10000 : raw
    }

    static func uint32(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            | (Int(bytes[offset + 2]) << 16) | (Int(bytes[offset + 3]) << 24)
    }

    static func int32(_ bytes: [UInt8], _ offset: Int) -> Int {
        let raw = uint32(bytes, offset)
        return raw >= 0x8000_0000 ? raw - 0x1_0000_0000 : raw
    }

    func uleb128(_ offset: Int) -> (value: Int, next: Int) {
        var result = 0
        var shift = 0
        var position = offset
        while position < bytes.count {
            let byte = Int(bytes[position])
            position += 1
            result |= (byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 28 { break }
        }
        return (result, position)
    }

    // MARK: - 索引表

    func string(_ index: Int) -> String {
        if let cached = stringCache[index] { return cached }
        guard index >= 0, index < stringIDsSize else { return "" }
        let offset = DexFile.uint32(bytes, stringIDsOffset + index * 4)
        let (_, start) = uleb128(offset)
        var end = start
        while end < bytes.count, bytes[end] != 0 { end += 1 }
        guard start <= end, end <= bytes.count else { return "" }
        let value = String(decoding: bytes[start..<end], as: UTF8.self)
        stringCache[index] = value
        return value
    }

    func typeName(_ index: Int) -> String {
        guard index >= 0, index < typeIDsSize else { return "" }
        return string(DexFile.uint32(bytes, typeIDsOffset + index * 4))
    }

    /// (类名, 字段名, 类型名)
    func field(_ index: Int) -> (owner: String, name: String, type: String) {
        guard index >= 0, index < fieldIDsSize else { return ("", "", "") }
        let offset = fieldIDsOffset + index * 8
        let owner = typeName(DexFile.uint16(bytes, offset))
        let type = typeName(DexFile.uint16(bytes, offset + 2))
        let name = string(DexFile.uint32(bytes, offset + 4))
        return (owner, name, type)
    }

    /// (类名, 方法名, proto 索引)
    func method(_ index: Int) -> (owner: String, name: String, proto: Int) {
        guard index >= 0, index < methodIDsSize else { return ("", "", 0) }
        let offset = methodIDsOffset + index * 8
        let owner = typeName(DexFile.uint16(bytes, offset))
        let proto = DexFile.uint16(bytes, offset + 2)
        let name = string(DexFile.uint32(bytes, offset + 4))
        return (owner, name, proto)
    }

    /// (返回类型, 参数类型数组)
    func protoSignature(_ index: Int) -> (returns: String, arguments: [String]) {
        guard index >= 0, index < protoIDsSize else { return ("", []) }
        let offset = protoIDsOffset + index * 12
        let returns = typeName(DexFile.uint32(bytes, offset + 4))
        let parameters = DexFile.uint32(bytes, offset + 8)
        guard parameters > 0, parameters < bytes.count else { return (returns, []) }
        let count = DexFile.uint32(bytes, parameters)
        guard count >= 0, count < 4096 else { return (returns, []) }
        var arguments: [String] = []
        for position in 0..<count {
            arguments.append(typeName(DexFile.uint16(bytes, parameters + 4 + position * 2)))
        }
        return (returns, arguments)
    }

    // MARK: - 类与方法

    func classDefs() -> [(name: String, classDataOffset: Int)] {
        guard classDefsSize > 0, classDefsSize < 200_000 else { return [] }
        var result: [(name: String, classDataOffset: Int)] = []
        for index in 0..<classDefsSize {
            let offset = classDefsOffset + index * 32
            guard offset + 32 <= bytes.count else { break }
            let name = typeName(DexFile.uint32(bytes, offset))
            let classData = DexFile.uint32(bytes, offset + 24)
            result.append((name, classData))
        }
        return result
    }

    func classMethods(_ classDataOffset: Int) -> [(index: Int, codeOffset: Int)] {
        guard classDataOffset > 0, classDataOffset < bytes.count else { return [] }
        var position = classDataOffset
        var counts: [Int] = []
        for _ in 0..<4 {
            let (value, next) = uleb128(position)
            counts.append(value)
            position = next
        }
        let staticFields = counts[0], instanceFields = counts[1]
        let directMethods = counts[2], virtualMethods = counts[3]
        for _ in 0..<(staticFields + instanceFields) {
            let (_, afterIndex) = uleb128(position)
            let (_, afterAccess) = uleb128(afterIndex)
            position = afterAccess
        }
        var result: [(index: Int, codeOffset: Int)] = []
        for count in [directMethods, virtualMethods] {
            var methodIndex = 0
            for _ in 0..<count {
                let (difference, afterIndex) = uleb128(position)
                let (_, afterAccess) = uleb128(afterIndex)
                let (codeOffset, afterCode) = uleb128(afterAccess)
                position = afterCode
                methodIndex += difference
                result.append((methodIndex, codeOffset))
            }
        }
        return result
    }

    /// code_item 的指令区起点与指令个数（code unit 数）。
    func codeItem(_ codeOffset: Int) -> (size: Int, base: Int)? {
        guard codeOffset > 0, codeOffset + 16 <= bytes.count else { return nil }
        let size = DexFile.uint32(bytes, codeOffset + 12)
        let base = codeOffset + 16
        guard size >= 0, base + size * 2 <= bytes.count else { return nil }
        return (size, base)
    }
}

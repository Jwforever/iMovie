import Foundation

/// 静态把插件里被异或编码的字符串还原成明文。
///
/// 每个采集器类在 `<clinit>` 里用 fill-array-data 填一张 short[] 表，
/// 站点代码再调用 `D(table, start, len, key)` 取字符串：
///
///     char[i] = (char)(table[start + i] ^ key)
///
/// 所以只要把 fill-array-data 的表和调用点的三个整数参数折叠出来，
/// 域名、搜索模板、CSS 选择器、请求头就都是明文，不需要执行 Dalvik。
final class GuardStringDecoder {
    struct MemberKey: Hashable {
        var owner: String
        var name: String
    }

    struct Hit {
        var method: String
        var text: String
    }

    let dex: DexFile
    private(set) var tables: [MemberKey: [Int]] = [:]
    private(set) var getters: [MemberKey: [Int]] = [:]
    private var tablesByOwner: [String: [[Int]]] = [:]
    private var gettersByOwner: [String: [[Int]]] = [:]
    private(set) var methodIndex: [Int: (owner: String, name: String, codeOffset: Int)] = [:]

    init(dex: DexFile) {
        self.dex = dex
    }

    // MARK: - 常量表

    func collectTables() {
        for definition in dex.classDefs() {
            for method in dex.classMethods(definition.classDataOffset) {
                let signature = dex.method(method.index)
                guard signature.name == "<clinit>", method.codeOffset > 0 else { continue }
                var arrays: [[Int]] = []
                DexInstruction.walk(dex, codeOffset: method.codeOffset) { index, opcode, _, base in
                    if opcode == 0x26 {
                        if let array = DexInstruction.arrayData(dex, base: base, instruction: index) {
                            arrays.append(array)
                        }
                    } else if opcode == 0x69, let array = arrays.last {
                        let fieldIndex = DexFile.uint16(dex.bytes, base + (index + 1) * 2)
                        let field = dex.field(fieldIndex)
                        guard !field.name.isEmpty else { return }
                        let key = MemberKey(owner: definition.name, name: field.name)
                        tables[key] = array
                    }
                }
            }
        }
        for (key, value) in tables {
            tablesByOwner[key.owner, default: []].append(value)
        }
    }

    /// 很多类不直接 sget 表字段，而是用无参静态方法把表返回出来，
    /// 调用点写成 `invoke-static {}, 类.m:()[S` + `move-result-object`。
    func collectGetters() {
        for definition in dex.classDefs() {
            for method in dex.classMethods(definition.classDataOffset) {
                guard method.codeOffset > 0 else { continue }
                let signature = dex.method(method.index)
                let proto = dex.protoSignature(signature.proto)
                guard proto.returns == "[S", proto.arguments.isEmpty else { continue }
                var found: [Int]?
                DexInstruction.walk(dex, codeOffset: method.codeOffset) { index, opcode, _, base in
                    guard opcode == 0x62, found == nil else { return }
                    let fieldIndex = DexFile.uint16(dex.bytes, base + (index + 1) * 2)
                    let field = dex.field(fieldIndex)
                    guard field.type == "[S" else { return }
                    found = tables[MemberKey(owner: field.owner, name: field.name)]
                }
                if let found {
                    getters[MemberKey(owner: definition.name, name: signature.name)] = found
                }
            }
        }
        for (key, value) in getters {
            gettersByOwner[key.owner, default: []].append(value)
        }
    }

    func buildMethodIndex() {
        var index: [Int: (owner: String, name: String, codeOffset: Int)] = [:]
        for definition in dex.classDefs() {
            for method in dex.classMethods(definition.classDataOffset) {
                let signature = dex.method(method.index)
                index[method.index] = (definition.name, signature.name, method.codeOffset)
            }
        }
        methodIndex = index
    }

    func ownArrays(_ className: String) -> [[Int]] {
        tablesByOwner[className] ?? []
    }

    // MARK: - 解码

    func decode(className: String, classDataOffset: Int) -> [Hit] {
        let own = tablesByOwner[className] ?? []
        let ownGetters = gettersByOwner[className] ?? []
        var hits: [Hit] = []
        for method in dex.classMethods(classDataOffset) {
            guard method.codeOffset > 0 else { continue }
            let name = dex.method(method.index).name
            var registers: [Int: Int] = [:]
            var arrays: [Int: [Int]] = [:]
            var strings: [Int: String] = [:]
            var pending: Int?
            var pendingArray: [Int]?
            DexInstruction.walk(dex, codeOffset: method.codeOffset) { index, opcode, word, base in
                switch opcode {
                case 0x12:
                    let destination = (word >> 8) & 0xF
                    registers[destination] = Self.signExtend(word >> 12, bits: 4)
                    arrays.removeValue(forKey: destination)
                    strings.removeValue(forKey: destination)
                case 0x13:
                    let destination = (word >> 8) & 0xFF
                    registers[destination] = DexFile.int16(dex.bytes, base + (index + 1) * 2)
                    arrays.removeValue(forKey: destination)
                    strings.removeValue(forKey: destination)
                case 0x14:
                    let destination = (word >> 8) & 0xFF
                    registers[destination] = DexFile.int32(dex.bytes, base + (index + 1) * 2)
                    arrays.removeValue(forKey: destination)
                    strings.removeValue(forKey: destination)
                case 0x15:
                    let destination = (word >> 8) & 0xFF
                    registers[destination] = DexFile.int16(dex.bytes, base + (index + 1) * 2) << 16
                    arrays.removeValue(forKey: destination)
                    strings.removeValue(forKey: destination)
                case 0xD7:
                    let destination = (word >> 8) & 0xFF
                    let literal = DexFile.int16(dex.bytes, base + (index + 1) * 2)
                    if let value = registers[destination] {
                        registers[destination] = Self.signed32((value ^ literal) & 0xFFFF_FFFF)
                    }
                case 0x97:
                    let destination = (word >> 8) & 0xFF
                    let left = (word >> 12) & 0xF
                    let right = DexFile.uint16(dex.bytes, base + (index + 1) * 2) & 0xFF
                    if let a = registers[left], let b = registers[right] {
                        registers[destination] = Self.signed32((a ^ b) & 0xFFFF_FFFF)
                    }
                case 0x0A:
                    let destination = (word >> 8) & 0xFF
                    if let value = pending {
                        registers[destination] = value
                        pending = nil
                    }
                    if let value = pendingArray {
                        arrays[destination] = value
                        pendingArray = nil
                    }
                case 0x0C:
                    let destination = (word >> 8) & 0xFF
                    if let value = pendingArray {
                        arrays[destination] = value
                        pendingArray = nil
                    } else {
                        arrays.removeValue(forKey: destination)
                    }
                    registers.removeValue(forKey: destination)
                case 0x1A:
                    let stringIndex = DexFile.uint16(dex.bytes, base + (index + 1) * 2)
                    let destination = (word >> 8) & 0xFF
                    strings[destination] = dex.string(stringIndex)
                    registers.removeValue(forKey: destination)
                    arrays.removeValue(forKey: destination)
                case 0x62:
                    let fieldIndex = DexFile.uint16(dex.bytes, base + (index + 1) * 2)
                    let field = dex.field(fieldIndex)
                    let destination = (word >> 8) & 0xFF
                    if field.type == "[S", let array = tables[MemberKey(owner: field.owner, name: field.name)] {
                        arrays[destination] = array
                    } else {
                        arrays.removeValue(forKey: destination)
                    }
                    registers.removeValue(forKey: destination)
                case 0x01, 0x04, 0x07:
                    let destination = (word >> 8) & 0xF
                    let source = (word >> 12) & 0xF
                    Self.copy(from: source, to: destination, registers: &registers, arrays: &arrays, strings: &strings)
                case 0x02, 0x05, 0x08:
                    let destination = (word >> 8) & 0xFF
                    let source = DexFile.uint16(dex.bytes, base + (index + 1) * 2)
                    Self.copy(from: source, to: destination, registers: &registers, arrays: &arrays, strings: &strings)
                case 0x6E...0x78:
                    let targetIndex = DexFile.uint16(dex.bytes, base + (index + 1) * 2)
                    let registerWord = DexFile.uint16(dex.bytes, base + (index + 2) * 2)
                    var arguments: [Int] = []
                    if opcode >= 0x74 {
                        let first = registerWord & 0xFFFF
                        let count = (word >> 8) & 0xFF
                        arguments = (0..<count).map { first + $0 }
                    } else {
                        arguments = [registerWord & 0xF, (registerWord >> 4) & 0xF,
                                     (registerWord >> 8) & 0xF, (registerWord >> 12) & 0xF]
                    }
                    let target = dex.method(targetIndex)
                    guard !target.name.isEmpty else { return }
                    let proto = dex.protoSignature(target.proto)
                    if proto.returns == "[S", proto.arguments.isEmpty {
                        pendingArray = getters[MemberKey(owner: target.owner, name: target.name)]
                        return
                    }
                    if proto.returns == "Ljava/lang/String;",
                       proto.arguments == ["[S", "I", "I", "I"], arguments.count >= 4 {
                        let arrayRegister = arguments[0]
                        let startRegister = arguments[1]
                        let lengthRegister = arguments[2]
                        let keyRegister = arguments[3]
                        var array = arrays[arrayRegister]
                        if array == nil, own.count == 1 { array = own[0] }
                        if array == nil, ownGetters.count == 1 { array = ownGetters[0] }
                        guard let array,
                              let start = registers[startRegister],
                              let length = registers[lengthRegister],
                              let key = registers[keyRegister] else { return }
                        guard start >= 0, length > 0, length <= 8192, start + length <= array.count else { return }
                        var values: [UInt16] = []
                        values.reserveCapacity(length)
                        for offset in 0..<length {
                            values.append(UInt16((array[start + offset] ^ key) & 0xFFFF))
                        }
                        guard Self.plausible(values) else { return }
                        hits.append(Hit(method: name, text: String(decoding: values, as: UTF16.self)))
                    } else if target.owner == "Ljava/lang/Integer;",
                              target.name == "parseInt" || target.name == "valueOf",
                              let first = arguments.first, let text = strings[first] {
                        pending = Int(Self.arabicDigits(text).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                default:
                    break
                }
            }
        }
        return hits
    }

    /// 把方法体内可拿到的字符串聚合起来，递归展开无参 String getter。
    func reachableStrings(codeOffset: Int, ownArrays: [[Int]], depth: Int, seen: inout Set<Int>) -> Set<String> {
        var result = Set<String>()
        guard codeOffset > 0 else { return result }
        let targets = DexInstruction.branchTargets(dex, codeOffset: codeOffset)
        var registers: [Int: Int] = [:]
        var arrays: [Int: [Int]] = [:]
        DexInstruction.walk(dex, codeOffset: codeOffset) { index, opcode, word, base in
            if targets.contains(index) {
                registers.removeAll()
                arrays.removeAll()
            }
            switch opcode {
            case 0x1A:
                let stringIndex = DexFile.uint16(dex.bytes, base + (index + 1) * 2)
                let text = dex.string(stringIndex)
                if !text.isEmpty { result.insert(text) }
                registers.removeValue(forKey: (word >> 8) & 0xFF)
            case 0x12:
                registers[(word >> 8) & 0xF] = Self.signExtend(word >> 12, bits: 4)
            case 0x13:
                registers[(word >> 8) & 0xFF] = DexFile.int16(dex.bytes, base + (index + 1) * 2)
            case 0x14:
                registers[(word >> 8) & 0xFF] = DexFile.int32(dex.bytes, base + (index + 1) * 2)
            case 0x15:
                registers[(word >> 8) & 0xFF] = DexFile.int16(dex.bytes, base + (index + 1) * 2) << 16
            case 0x62:
                let fieldIndex = DexFile.uint16(dex.bytes, base + (index + 1) * 2)
                let field = dex.field(fieldIndex)
                let destination = (word >> 8) & 0xFF
                if field.type == "[S", let array = tables[MemberKey(owner: field.owner, name: field.name)] {
                    arrays[destination] = array
                }
            case 0x6E...0x78:
                let targetIndex = DexFile.uint16(dex.bytes, base + (index + 1) * 2)
                let registerWord = DexFile.uint16(dex.bytes, base + (index + 2) * 2)
                var arguments: [Int] = []
                if opcode >= 0x74 {
                    let first = registerWord & 0xFFFF
                    let count = (word >> 8) & 0xFF
                    arguments = (0..<count).map { first + $0 }
                } else {
                    arguments = [registerWord & 0xF, (registerWord >> 4) & 0xF,
                                 (registerWord >> 8) & 0xF, (registerWord >> 12) & 0xF]
                }
                let target = dex.method(targetIndex)
                guard !target.name.isEmpty else { return }
                let proto = dex.protoSignature(target.proto)
                if proto.returns == "Ljava/lang/String;",
                   proto.arguments == ["[S", "I", "I", "I"], arguments.count >= 4 {
                    let startRegister = arguments[1]
                    let lengthRegister = arguments[2]
                    let keyRegister = arguments[3]
                    var array = arrays[arguments[0]]
                    if array == nil, ownArrays.count == 1 { array = ownArrays[0] }
                    guard let array,
                          let start = registers[startRegister],
                          let length = registers[lengthRegister],
                          let key = registers[keyRegister] else { return }
                    guard start >= 0, length > 0, length <= 8192, start + length <= array.count else { return }
                    var values: [UInt16] = []
                    values.reserveCapacity(length)
                    for offset in 0..<length {
                        values.append(UInt16((array[start + offset] ^ key) & 0xFFFF))
                    }
                    if Self.plausible(values) {
                        result.insert(String(decoding: values, as: UTF16.self))
                    }
                } else if proto.returns == "Ljava/lang/String;", proto.arguments.isEmpty, opcode == 0x71,
                          depth > 0, !seen.contains(targetIndex) {
                    seen.insert(targetIndex)
                    if let nested = methodIndex[targetIndex], nested.codeOffset > 0 {
                        result.formUnion(reachableStrings(codeOffset: nested.codeOffset, ownArrays: [],
                                                          depth: depth - 1, seen: &seen))
                    }
                }
            case 0x28, 0x29, 0x2A, 0x2B, 0x2C:
                registers.removeAll()
                arrays.removeAll()
            default:
                break
            }
        }
        return result
    }

    // MARK: - 工具

    private static func copy(from source: Int, to destination: Int, registers: inout [Int: Int],
                             arrays: inout [Int: [Int]], strings: inout [Int: String]) {
        if let value = registers[source] { registers[destination] = value } else { registers.removeValue(forKey: destination) }
        if let value = arrays[source] { arrays[destination] = value } else { arrays.removeValue(forKey: destination) }
        if let value = strings[source] { strings[destination] = value } else { strings.removeValue(forKey: destination) }
    }

    static func signExtend(_ value: Int, bits: Int) -> Int {
        let mask = 1 << (bits - 1)
        return (value & (mask - 1)) - (value & mask)
    }

    static func signed32(_ value: Int) -> Int {
        let masked = value & 0xFFFF_FFFF
        return masked >= 0x8000_0000 ? masked - 0x1_0000_0000 : masked
    }

    /// 解码结果像不像正常字符串；乱码说明参数取错了。
    static func plausible(_ values: [UInt16]) -> Bool {
        for value in values {
            if value < 0x20 { return false }
            if value >= 0x0590 && value <= 0x06FF { return false }
            if value >= 0x0750 && value <= 0x0FFF { return false }
            if value >= 0xD800 && value <= 0xDFFF { return false }
            if value >= 0xE000 && value <= 0xF8FF { return false }
        }
        return true
    }

    /// 混淆器把 0-9 映射到 U+06DF..U+06E8（parseInt 前需要还原）。
    static func arabicDigits(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let code = Int(scalar.value)
            if code >= 0x06DF && code <= 0x06E8 {
                result.append(Character(UnicodeScalar(UInt8(48 + code - 0x06DF))))
            } else if code >= 0x0660 && code <= 0x0669 {
                result.append(Character(UnicodeScalar(UInt8(48 + code - 0x0660))))
            } else {
                result.append(Character(scalar))
            }
        }
        return result
    }
}

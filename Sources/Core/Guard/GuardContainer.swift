import Foundation
import Compression

/// 静态解开 CatVod 加固插件（jar → *.guard → 明文 classes.dex）。
///
/// 全部是本机字节运算，不执行 Dalvik、不执行 ARM、不加载任何安卓组件。
enum GuardContainerError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

enum GuardContainer {
    struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var dataOffset: Int
    }

    /// jar / apk / 裸 guard → 内层明文 DEX。
    static func innerDex(from archive: Data) throws -> Data {
        let bytes = [UInt8](archive)
        if isDex(bytes) { return archive }
        guard let payload = try dig(bytes: bytes, depth: 0) else {
            throw GuardContainerError.invalid("插件包里没有找到 .guard 或 classes.dex 条目。")
        }
        if isDex(payload) { return Data(payload) }
        if let dex = restore(payload) { return dex }
        throw GuardContainerError.invalid("插件包解开了，但内层 DEX 无法还原（格式不在已知范围内）。")
    }

    /// 逐层剥离容器：jar 里的 assets/xxx.guard 再套一层 zip。
    private static func dig(bytes: [UInt8], depth: Int) throws -> [UInt8]? {
        guard depth <= 4 else { return nil }
        if isDex(bytes) { return bytes }
        guard isZip(bytes) else { return bytes }
        let list = entries(in: bytes)
        for suffix in [".guard", "classes.dex"] {
            for entry in list where entry.name.hasSuffix(suffix) && entry.compressedSize > 0 {
                let start = entry.dataOffset
                let end = min(bytes.count, start + entry.compressedSize)
                guard start >= 0, end > start else { continue }
                let raw = Array(bytes[start..<end])
                // 最内层的 classes.dex 数据本身可能被扰动，交给 restore() 处理。
                if suffix == "classes.dex" { return raw }
                let inflated: [UInt8]
                if entry.method == 0 {
                    inflated = raw
                } else if let output = inflate(raw, expected: entry.uncompressedSize) {
                    inflated = [UInt8](output)
                } else {
                    throw GuardContainerError.invalid("插件里的 \(entry.name) 解压失败。")
                }
                return try dig(bytes: inflated, depth: depth + 1)
            }
        }
        return nil
    }

    /// guard 数据段：先做 {1,2,5,6} 反扰，再 raw inflate。
    private static func restore(_ payload: [UInt8]) -> Data? {
        let candidates = [unscramble(payload), payload]
        for candidate in candidates {
            if let output = inflate(candidate, expected: 0), output.count > 0x70, isDex([UInt8](output.prefix(4))) {
                return output
            }
        }
        return nil
    }

    /// deflate 流里凡值 ∈ {1,2,5,6} 的字节被 XOR 0x07 过（1↔6、2↔5）。该变换自逆。
    static func unscramble(_ payload: [UInt8]) -> [UInt8] {
        var result = payload
        for index in result.indices {
            let value = result[index]
            if value == 1 || value == 2 || value == 5 || value == 6 { result[index] = value ^ 0x07 }
        }
        return result
    }

    static func isDex(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        return bytes[0] == 0x64 && bytes[1] == 0x65 && bytes[2] == 0x78 && bytes[3] == 0x0A
    }

    private static func isZip(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        return bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04
    }

    // MARK: - inflate

    /// 解 DEFLATE。iOS 的 COMPRESSION_ZLIB 是裸 deflate，个别实现要求 zlib 头，
    /// 所以三种输入都试一遍，取第一个能解出内容的结果。
    static func inflate(_ input: [UInt8], expected: Int) -> Data? {
        guard !input.isEmpty else { return nil }
        var seeds: [[UInt8]] = [input]
        seeds.append([0x78, 0x9C] + input)
        seeds.append([0x78, 0x01] + input)
        for seed in seeds {
            let data = Data(seed)
            if expected > 0 {
                if let output = decode(data, capacity: expected), output.count == expected { return output }
                continue
            }
            var capacity = max(1 << 20, data.count * 6)
            while capacity <= 96 << 20 {
                if let output = decode(data, capacity: capacity), !output.isEmpty, output.count < capacity { return output }
                capacity <<= 1
            }
        }
        return nil
    }

    private static func decode(_ input: Data, capacity: Int) -> Data? {
        guard capacity > 0 else { return nil }
        var output = [UInt8](repeating: 0, count: capacity)
        let written = output.withUnsafeMutableBufferPointer { destination -> Int in
            input.withUnsafeBytes { source -> Int in
                guard let dst = destination.baseAddress, let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, capacity, src, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Data(output[0..<written])
    }

    // MARK: - ZIP

    static func entries(in bytes: [UInt8]) -> [Entry] {
        let central = centralEntries(bytes)
        return central.isEmpty ? localEntries(bytes) : central
    }

    /// 新版 jar 的 local header 带 data descriptor（长度写 0），只能读中央目录。
    private static func centralEntries(_ bytes: [UInt8]) -> [Entry] {
        guard let eocd = findEndOfCentralDirectory(bytes), eocd + 22 <= bytes.count else { return [] }
        let total = uint16(bytes, eocd + 10)
        let offset = uint32(bytes, eocd + 16)
        guard total > 0, offset > 0, offset < bytes.count else { return [] }
        var position = offset
        var result: [Entry] = []
        for _ in 0..<total {
            guard position + 46 <= bytes.count, bytes[position] == 0x50, bytes[position + 1] == 0x4B,
                  bytes[position + 2] == 0x01, bytes[position + 3] == 0x02 else { break }
            let method = UInt16(uint16(bytes, position + 10))
            let compressed = uint32(bytes, position + 20)
            let uncompressed = uint32(bytes, position + 24)
            let nameLength = uint16(bytes, position + 28)
            let extraLength = uint16(bytes, position + 30)
            let commentLength = uint16(bytes, position + 32)
            let localOffset = uint32(bytes, position + 42)
            let nameStart = position + 46
            let nameEnd = min(bytes.count, nameStart + nameLength)
            let name = nameStart < nameEnd ? String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self) : ""
            let dataOffset = localOffset + 30 + nameLength + extraLength
            result.append(Entry(name: name, method: method, compressedSize: compressed,
                                uncompressedSize: uncompressed, dataOffset: dataOffset))
            position = nameStart + nameLength + extraLength + commentLength
        }
        return result
    }

    /// 被抹掉中央目录的容器（.guard 本体）只剩下 local header。
    private static func localEntries(_ bytes: [UInt8]) -> [Entry] {
        var result: [Entry] = []
        var position = 0
        while true {
            let index = find([0x50, 0x4B, 0x03, 0x04], in: bytes, from: position)
            guard index >= 0, index + 30 <= bytes.count else { break }
            let method = UInt16(uint16(bytes, index + 8))
            let compressed = uint32(bytes, index + 18)
            let uncompressed = uint32(bytes, index + 22)
            let nameLength = uint16(bytes, index + 26)
            let extraLength = uint16(bytes, index + 28)
            let nameStart = index + 30
            let nameEnd = min(bytes.count, nameStart + nameLength)
            let name = nameStart < nameEnd ? String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self) : ""
            let dataOffset = nameStart + nameLength + extraLength
            result.append(Entry(name: name, method: method, compressedSize: compressed,
                                uncompressedSize: uncompressed, dataOffset: dataOffset))
            let next = dataOffset + max(compressed, 0)
            position = next > index ? next : index + 4
        }
        return result
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let limit = max(0, bytes.count - 66_000)
        var index = bytes.count - 22
        while index >= limit {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int {
        guard !pattern.isEmpty, start >= 0, start < bytes.count else { return -1 }
        var index = start
        while index + pattern.count <= bytes.count {
            var matched = true
            for offset in 0..<pattern.count where bytes[index + offset] != pattern[offset] {
                matched = false
                break
            }
            if matched { return index }
            index += 1
        }
        return -1
    }

    static func uint16(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }

    static func uint32(_ bytes: [UInt8], _ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            | (Int(bytes[offset + 2]) << 16) | (Int(bytes[offset + 3]) << 24)
    }
}

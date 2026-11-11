import Foundation

/// Dalvik 指令长度表 + 线性遍历。
/// 表错一项就会导致后续所有指令错位、操作数变成乱码，所以这里与
/// tools/dexrules/decode_strings.py 的 SIZE 表逐项对齐。
enum DexInstruction {
    static let sizes: [Int] = buildSizes()

    private static func buildSizes() -> [Int] {
        var table = [Int](repeating: 1, count: 256)
        func set(_ range: ClosedRange<Int>, _ value: Int) {
            for index in range { table[index] = value }
        }
        set(0x02...0x02, 2)
        set(0x03...0x03, 3)
        set(0x05...0x05, 2)
        set(0x06...0x06, 3)
        set(0x08...0x08, 2)
        set(0x09...0x09, 3)
        // const/4 占 1 个 code unit，const/16 占 2 个，const/high16 占 2 个。
        set(0x12...0x12, 1)
        set(0x13...0x13, 2)
        set(0x14...0x14, 3)
        set(0x15...0x15, 2)
        set(0x16...0x16, 2)
        set(0x17...0x17, 3)
        set(0x18...0x18, 5)
        set(0x19...0x19, 2)
        set(0x1A...0x1A, 2)
        set(0x1B...0x1B, 3)
        set(0x1C...0x1C, 2)
        set(0x1F...0x20, 2)
        set(0x22...0x23, 2)
        set(0x24...0x26, 3)
        set(0x29...0x29, 2)
        set(0x2A...0x2A, 3)
        set(0x2B...0x2C, 3)
        set(0x2D...0x3D, 2)
        set(0x44...0x6D, 2)
        set(0x6E...0x72, 3)
        set(0x74...0x78, 3)
        set(0x90...0xAF, 2)
        set(0xD0...0xE2, 2)
        set(0xFA...0xFB, 4)
        set(0xFC...0xFD, 3)
        set(0xFE...0xFF, 2)
        return table
    }

    /// 逐条产出 (pc(code unit 下标), opcode, 整个首字, 指令区起点)，自动跳过 payload。
    static func walk(_ dex: DexFile, codeOffset: Int, _ body: (Int, Int, Int, Int) -> Void) {
        guard let item = dex.codeItem(codeOffset) else { return }
        let bytes = dex.bytes
        let base = item.base
        var index = 0
        while index < item.size {
            let word = DexFile.uint16(bytes, base + index * 2)
            if word == 0x0100 {
                let count = DexFile.uint16(bytes, base + (index + 1) * 2)
                index += 4 + count * 2
                continue
            }
            if word == 0x0200 {
                let count = DexFile.uint16(bytes, base + (index + 1) * 2)
                index += 2 + count * 4
                continue
            }
            if word == 0x0300 {
                let width = DexFile.uint16(bytes, base + (index + 1) * 2)
                let count = DexFile.uint32(bytes, base + (index + 2) * 2)
                index += 4 + (width * count + 1) / 2
                continue
            }
            body(index, word & 0xFF, word, base)
            index += sizes[word & 0xFF]
        }
    }

    /// 分支目标（用于判断基本块入口）。
    static func branchTargets(_ dex: DexFile, codeOffset: Int) -> Set<Int> {
        var targets = Set<Int>()
        let bytes = dex.bytes
        walk(dex, codeOffset: codeOffset) { index, opcode, word, base in
            switch opcode {
            case 0x28:
                let delta = (word >> 8) & 0xFF
                targets.insert(index + (delta >= 0x80 ? delta - 0x100 : delta))
            case 0x29:
                targets.insert(index + DexFile.int16(bytes, base + (index + 1) * 2))
            case 0x2A:
                targets.insert(index + DexFile.int32(bytes, base + (index + 1) * 2))
            case 0x2B, 0x2C:
                targets.insert(index)
            case 0x32...0x3D:
                targets.insert(index + DexFile.int16(bytes, base + (index + 1) * 2))
            default:
                break
            }
        }
        return targets
    }

    /// fill-array-data 的数组内容（宽 1/2/4 字节，按有符号读）。
    static func arrayData(_ dex: DexFile, base: Int, instruction: Int) -> [Int]? {
        let bytes = dex.bytes
        let offset = DexFile.int32(bytes, base + (instruction + 1) * 2)
        let position = instruction + offset
        guard position >= 0 else { return nil }
        let start = base + position * 2
        guard DexFile.uint16(bytes, start) == 0x0300 else { return nil }
        let width = DexFile.uint16(bytes, start + 2)
        let count = DexFile.uint32(bytes, start + 4)
        guard count >= 0, count <= 200_000 else { return nil }
        let dataStart = start + 8
        guard dataStart + width * count <= bytes.count else { return nil }
        var result: [Int] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let position = dataStart + index * width
            switch width {
            case 1:
                let raw = Int(bytes[position])
                result.append(raw >= 0x80 ? raw - 0x100 : raw)
            case 2:
                result.append(DexFile.int16(bytes, position))
            case 4:
                result.append(DexFile.int32(bytes, position))
            default:
                return nil
            }
        }
        return result
    }
}

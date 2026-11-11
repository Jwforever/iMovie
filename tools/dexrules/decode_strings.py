#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""静态解出饭太硬 guard DEX 里被混淆的字符串。

算法（dexdump 反汇编实证，整个 DEX 里 40+ 份完全相同的克隆）：

    static String D(short[] t, int start, int len, int key) {
        char[] c = new char[len];
        for (int i = 0; i < len; i++) c[i] = (char) (t[start + i] ^ key);
        return new String(c);
    }

每个类的 <clinit> 用 fill-array-data 填一张 short[] 常量表，站点代码在
<init> / categoryContent / detailContent / searchContent 里调用 D() 取真实
字符串——域名、搜索路径模板、CSS 选择器、请求头全在里面。

用法：
    python decode_strings.py inner-plaintext.dex decoded_strings.json
"""
import json
import struct
import sys

sys.stdout.reconfigure(encoding='utf-8')
sys.path.insert(0, '.')

from dexstr import Dex

# ---------------------------------------------------------------- 指令长度表
SIZE = [1] * 256


def _set(a, b, v):
    for i in range(a, b + 1):
        SIZE[i] = v


_set(0x02, 0x02, 2); _set(0x03, 0x03, 3); _set(0x05, 0x05, 2); _set(0x06, 0x06, 3)
_set(0x08, 0x08, 2); _set(0x09, 0x09, 3)
# const/4 = 1 单元；const/16 = 2；const = 3；const/high16 = 2（这是上一版最大的坑）
_set(0x12, 0x12, 1); _set(0x13, 0x13, 2); _set(0x14, 0x14, 3); _set(0x15, 0x15, 2)
_set(0x16, 0x16, 2); _set(0x17, 0x17, 3); _set(0x18, 0x18, 5); _set(0x19, 0x19, 2)
_set(0x1a, 0x1a, 2); _set(0x1b, 0x1b, 3); _set(0x1c, 0x1c, 2)
_set(0x1f, 0x20, 2); _set(0x22, 0x23, 2); _set(0x24, 0x26, 3)
_set(0x29, 0x29, 2); _set(0x2a, 0x2a, 3); _set(0x2b, 0x2c, 3); _set(0x2d, 0x3d, 2)
_set(0x44, 0x6d, 2)
_set(0x6e, 0x72, 3); _set(0x74, 0x78, 3)
_set(0x90, 0xaf, 2)
_set(0xd0, 0xe2, 2)
_set(0xfa, 0xfb, 4); _set(0xfc, 0xfd, 3); _set(0xfe, 0xff, 2)


def _s(v, bits):
    m = 1 << (bits - 1)
    return (v & (m - 1)) - (v & m)


def _to_s32(v):
    """把 32 位无符号值看成有符号 int。"""
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v & 0x80000000 else v


def walk(d, code_off):
    """逐条走 code_item，产出 (pc_units, opcode, word, base)。跳过 payload。"""
    size = struct.unpack_from('<I', d.d, code_off + 12)[0]
    base = code_off + 16
    i = 0
    while i < size:
        w = struct.unpack_from('<H', d.d, base + i * 2)[0]
        if w == 0x0100:
            n = struct.unpack_from('<H', d.d, base + (i + 1) * 2)[0]
            i += 4 + n * 2
            continue
        if w == 0x0200:
            n = struct.unpack_from('<H', d.d, base + (i + 1) * 2)[0]
            i += 2 + n * 4
            continue
        if w == 0x0300:
            width = struct.unpack_from('<H', d.d, base + (i + 1) * 2)[0]
            n = struct.unpack_from('<I', d.d, base + (i + 2) * 2)[0]
            i += 4 + (width * n + 1) // 2
            continue
        op = w & 0xFF
        yield i, op, w, base
        i += SIZE[op]


def branch_targets(d, co):
    tgt = set()
    for i, op, w, base in walk(d, co):
        if op == 0x28:
            tgt.add(i + _s((w >> 8) & 0xFF, 8))
        elif op == 0x29:
            tgt.add(i + struct.unpack_from('<h', d.d, base + (i + 1) * 2)[0])
        elif op == 0x2a:
            tgt.add(i + struct.unpack_from('<i', d.d, base + (i + 1) * 2)[0])
        elif 0x32 <= op <= 0x37 or 0x38 <= op <= 0x3D:
            tgt.add(i + struct.unpack_from('<h', d.d, base + (i + 1) * 2)[0])
        elif op in (0x2b, 0x2c):
            tgt.add(i)
    return tgt


def array_data(d, base, insn_idx):
    off = struct.unpack_from('<i', d.d, base + (insn_idx + 1) * 2)[0]
    pos = insn_idx + off
    ident, width, size = struct.unpack_from('<HHI', d.d, base + pos * 2)
    if ident != 0x0300:
        return None
    data_off = base + (pos + 4) * 2
    if width == 2:
        return list(struct.unpack_from('<%dh' % size, d.d, data_off))
    if width == 1:
        return list(struct.unpack_from('<%db' % size, d.d, data_off))
    if width == 4:
        return list(struct.unpack_from('<%di' % size, d.d, data_off))
    return None


def collect_tables(d):
    """全局收集静态 [S 常量表：{(类名, 字段名): short[]}。"""
    out = {}
    for cd in d.class_defs():
        for midx, co in d.class_methods(cd['class_data_off']):
            _, m, _ = d.method(midx)
            if m != '<clinit>' or not co:
                continue
            arrays = []
            for i, op, w, base in walk(d, co):
                if op == 0x26:                       # fill-array-data
                    arr = array_data(d, base, i)
                    if arr is not None:
                        arrays.append(arr)
                elif op == 0x69 and arrays:          # sput-object
                    fidx = struct.unpack_from('<H', d.d, base + (i + 1) * 2)[0]
                    _, fname, ftype = d.field(fidx)
                    out[(cd['name'], fname)] = arrays[-1]
    return out


def collect_getters(d, arrays):
    """收集"返回 short[] 的无参 getter"：{(类名, 方法名): short[]}。

    很多类不直接 sget 表字段，而是通过一个静态无参方法把表返回出来，例如
    `DouDou.ﺏﺎﺵف()` 的方法体就是 `return DouDou.short;`。调用点写成
    `invoke-static {}, L...;->xxx:()[S` + `move-result-object`。
    """
    out = {}
    for cd in d.class_defs():
        for midx, co in d.class_methods(cd['class_data_off']):
            cls, name, pidx = d.method(midx)
            if not co:
                continue
            ret, args = proto_args(d, pidx)
            if ret != '[S' or args:
                continue
            for i, op, w, base in walk(d, co):
                if op != 0x62:                       # sget-object
                    continue
                fidx = struct.unpack_from('<H', d.d, base + (i + 1) * 2)[0]
                fcls, fname, ftype = d.field(fidx)
                if ftype == '[S' and (fcls, fname) in arrays:
                    out[(cls, name)] = arrays[(fcls, fname)]
                    break
    return out


def proto_args(d, proto_idx):
    off = d.proto_ids_off + proto_idx * 12
    _, ret, params = struct.unpack_from('<III', d.d, off)
    args = []
    if params:
        n = struct.unpack_from('<I', d.d, params)[0]
        args = [d.type_name(struct.unpack_from('<H', d.d, params + 4 + k * 2)[0])
                for k in range(n)]
    return d.type_name(ret), args


def plausible(s):
    """解码结果是否像正常字符串；乱码说明参数取错了。"""
    for ch in s:
        o = ord(ch)
        if o < 0x20:
            return False
        if 0x0590 <= o <= 0x06FF or 0x0750 <= o <= 0x0FFF or 0xE000 <= o <= 0xF8FF:
            return False
        if 0xD800 <= o <= 0xDFFF:
            return False
    return True


def _ara_digits(s):
    """把阿拉伯数字（U+06DF..U+06E8 / U+0660..U+0669）还原成 ASCII 数字。"""
    out = []
    for ch in s:
        o = ord(ch)
        if 0x06DF <= o <= 0x06E8:
            out.append(chr(ord('0') + o - 0x06DF))
        elif 0x0660 <= o <= 0x0669:
            out.append(chr(ord('0') + o - 0x0660))
        else:
            out.append(ch)
    return ''.join(out)


def decode_class(d, cd, arrays, getters=None):
    getters = getters or {}
    hits = []
    own = [a for (c, f), a in arrays.items() if c == cd['name']]
    own_getters = [a for (c, m), a in getters.items() if c == cd['name']]
    for midx, co in d.class_methods(cd['class_data_off']):
        _, mname, pidx = d.method(midx)
        if not co:
            continue
        # OLLVM 把方法压平成一串 if-eq 分派，常量往往在前面的块里设好、
        # 到后面的块才被用。所以这里不按块清空，只做"最后一次写入"追踪，
        # 再用 plausible() 把取错的组合滤掉。
        starts = branch_targets(d, co)
        regs = {}
        tabs = {}
        sregs = {}          # 寄存器 -> 字符串常量（供 parseInt 折叠）
        pending = None      # parseInt 结果，等 move-result 落位
        pending_tab = None  # 返回 [S 的 getter 结果，等 move-result-object 落位
        for i, op, w, base in walk(d, co):
            if op == 0x12:
                dst = (w >> 8) & 0xF
                regs[dst] = _s(w >> 12, 4)
                tabs.pop(dst, None)
                sregs.pop(dst, None)
            elif op == 0x13:
                dst = (w >> 8) & 0xFF
                regs[dst] = struct.unpack_from('<h', d.d, base + (i + 1) * 2)[0]
                tabs.pop(dst, None)
                sregs.pop(dst, None)
            elif op == 0x14:
                dst = (w >> 8) & 0xFF
                regs[dst] = struct.unpack_from('<i', d.d, base + (i + 1) * 2)[0]
                tabs.pop(dst, None)
                sregs.pop(dst, None)
            elif op == 0x15:
                dst = (w >> 8) & 0xFF
                regs[dst] = (w >> 8) << 16
                tabs.pop(dst, None)
                sregs.pop(dst, None)
            elif op == 0xD7:                              # xor-int/lit16
                dst = (w >> 8) & 0xFF
                lit = struct.unpack_from('<h', d.d, base + (i + 1) * 2)[0]
                if dst in regs:
                    regs[dst] = _to_s32((regs[dst] ^ lit) & 0xFFFFFFFF)
            elif op == 0x97:                              # xor-int vAA, vBB, vCC
                dst = (w >> 8) & 0xFF
                a = (w >> 12) & 0xF
                b = struct.unpack_from('<H', d.d, base + (i + 1) * 2)[0] & 0xFF
                if a in regs and b in regs:
                    regs[dst] = _to_s32((regs[a] ^ regs[b]) & 0xFFFFFFFF)
            elif op == 0x0A:                              # move-result
                dst = (w >> 8) & 0xFF
                if pending is not None:
                    regs[dst] = pending
                    pending = None
                if pending_tab is not None:
                    tabs[dst] = pending_tab
                    pending_tab = None
            elif op == 0x0C:                              # move-result-object
                dst = (w >> 8) & 0xFF
                if pending_tab is not None:
                    tabs[dst] = pending_tab
                    pending_tab = None
                else:
                    tabs.pop(dst, None)
                regs.pop(dst, None)
            elif op == 0x1a:
                sidx = struct.unpack_from('<H', d.d, base + (i + 1) * 2)[0]
                dst = (w >> 8) & 0xFF
                sregs[dst] = d.string(sidx)
                regs.pop(dst, None)
                tabs.pop(dst, None)
            elif op == 0x62:                              # sget-object
                fidx = struct.unpack_from('<H', d.d, base + (i + 1) * 2)[0]
                fcls, fname, ftype = d.field(fidx)
                dst = (w >> 8) & 0xFF
                if ftype == '[S' and (fcls, fname) in arrays:
                    tabs[dst] = arrays[(fcls, fname)]
                else:
                    tabs.pop(dst, None)
                regs.pop(dst, None)
            elif op in (0x01, 0x04, 0x07):
                dst, src = (w >> 8) & 0xF, (w >> 12) & 0xF
                if src in regs:
                    regs[dst] = regs[src]
                else:
                    regs.pop(dst, None)
                if src in tabs:
                    tabs[dst] = tabs[src]
                else:
                    tabs.pop(dst, None)
                if src in sregs:
                    sregs[dst] = sregs[src]
            elif op in (0x02, 0x05, 0x08):
                dst = (w >> 8) & 0xFF
                src = struct.unpack_from('<H', d.d, base + (i + 1) * 2)[0]
                if src in regs:
                    regs[dst] = regs[src]
                else:
                    regs.pop(dst, None)
                if src in tabs:
                    tabs[dst] = tabs[src]
                else:
                    tabs.pop(dst, None)
                if src in sregs:
                    sregs[dst] = sregs[src]
            elif 0x6E <= op <= 0x78:
                midx2 = struct.unpack_from('<H', d.d, base + (i + 1) * 2)[0]
                rw = struct.unpack_from('<H', d.d, base + (i + 2) * 2)[0]
                if op >= 0x74:                            # /range
                    first = rw & 0xFFFF
                    arg = list(range(first, first + ((rw >> 8) & 0xFF)))
                else:
                    arg = [rw & 0xF, (rw >> 4) & 0xF, (rw >> 8) & 0xF, (rw >> 12) & 0xF]
                try:
                    tcls, tm, tpidx = d.method(midx2)
                except Exception:
                    continue
                tret, targs = proto_args(d, tpidx)
                if tret == '[S' and not targs:
                    pending_tab = getters.get((tcls, tm))
                    continue
                if tret == 'Ljava/lang/String;' and targs == ['[S', 'I', 'I', 'I'] and len(arg) >= 4:
                    b, c, e = arg[1], arg[2], arg[3]
                    arr = tabs.get(arg[0])
                    if arr is None and len(own) == 1:
                        arr = own[0]
                    if arr is None and len(own_getters) == 1:
                        arr = own_getters[0]
                    if arr and b in regs and c in regs and e in regs:
                        start, ln, key = regs[b], regs[c], regs[e]
                        if 0 <= start and 0 < ln <= 8192 and start + ln <= len(arr):
                            s = ''.join(chr((arr[start + k] ^ key) & 0xFFFF) for k in range(ln))
                            if plausible(s):
                                hits.append({'method': mname, 'pc': i * 2,
                                             'callee': '%s.%s' % (tcls, tm),
                                             'start': start, 'len': ln, 'key': key,
                                             'text': s})
                elif tcls == 'Ljava/lang/Integer;' and tm in ('parseInt', 'valueOf') and arg:
                    sv = sregs.get(arg[0])
                    if sv is not None:
                        try:
                            pending = int(_ara_digits(sv).strip())
                        except ValueError:
                            pending = None
            elif op in (0x28, 0x29, 0x2A, 0x2B, 0x2C):
                pass
    return hits


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'inner-plaintext.dex'
    out = sys.argv[2] if len(sys.argv) > 2 else 'decoded_strings.json'
    d = Dex(open(path, 'rb').read())

    arrays = collect_tables(d)
    getters = collect_getters(d, arrays)
    print('常量表 %d 张，表 getter %d 个' % (len(arrays), len(getters)))

    result = {}
    for cd in d.class_defs():
        hits = decode_class(d, cd, arrays, getters)
        if hits:
            result[cd['name']] = {'strings': hits}

    json.dump(result, open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print('类数 %d，解出字符串 %d 条 -> %s' % (
        len(result), sum(len(v['strings']) for v in result.values()), out))


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把每个站点类能拿到的字符串聚合起来（含它调用的无参 getter）。

很多站点的 baseURL 不在站点类自己的常量表里，而是走
`parser.طﺙغﻡ.ثدظي()` 这类无参静态方法层层转发。本脚本递归展开这些
getter，把 const-string 与 D(table,start,len,key) 的结果并起来，
最后按类输出一份「站点 → 字符串集合」，域名就在里面。

用法：
    python resolve_sites.py inner-plaintext.dex sites_strings.json
"""
import json
import struct
import sys

sys.stdout.reconfigure(encoding='utf-8')
sys.path.insert(0, '.')

from dexstr import Dex
from decode_strings import (decode_class, collect_tables, walk, proto_args,
                            branch_targets, plausible)


def method_index(d):
    """midx -> (class, name, proto_idx, code_off)"""
    idx = {}
    for cd in d.class_defs():
        for midx, co in d.class_methods(cd['class_data_off']):
            c, m, p = d.method(midx)
            idx[midx] = (c, m, p, co)
    return idx


def scan(d, co, arrays, own, midx_map, depth, seen):
    """返回该方法里能拿到的字符串集合（递归展开无参 String getter）。"""
    out = set()
    if not co:
        return out
    starts = branch_targets(d, co)
    regs, tabs = {}, {}
    for i, op, w, base in walk(d, co):
        if i in starts:
            regs.clear()
            tabs.clear()
        if op == 0x1A:                                   # const-string
            sidx = struct.unpack_from('<H', d.d, base + (i + 1) * 2)[0]
            s = d.string(sidx)
            if s:
                out.add(s)
            regs.pop((w >> 8) & 0xFF, None)
        elif op == 0x12:                                 # const/4
            from decode_strings import _s
            regs[(w >> 8) & 0xF] = _s(w >> 12, 4)
        elif op == 0x13:
            regs[(w >> 8) & 0xFF] = struct.unpack_from('<h', d.d, base + (i + 1) * 2)[0]
        elif op == 0x14:
            regs[(w >> 8) & 0xFF] = struct.unpack_from('<i', d.d, base + (i + 1) * 2)[0]
        elif op == 0x15:
            regs[(w >> 8) & 0xFF] = (w >> 8) << 16
        elif op == 0x62:                                 # sget-object
            fidx = struct.unpack_from('<H', d.d, base + (i + 1) * 2)[0]
            fcls, fname, ftype = d.field(fidx)
            dst = (w >> 8) & 0xFF
            if ftype == '[S' and (fcls, fname) in arrays:
                tabs[dst] = arrays[(fcls, fname)]
        elif 0x6E <= op <= 0x78:
            midx2 = struct.unpack_from('<H', d.d, base + (i + 1) * 2)[0]
            rw = struct.unpack_from('<H', d.d, base + (i + 2) * 2)[0]
            if op >= 0x74:
                first = rw & 0xFFFF
                arg = list(range(first, first + ((rw >> 8) & 0xFF)))
            else:
                arg = [rw & 0xF, (rw >> 4) & 0xF, (rw >> 8) & 0xF, (rw >> 12) & 0xF]
            try:
                tcls, tm, tpidx = d.method(midx2)
            except Exception:
                continue
            tret, targs = proto_args(d, tpidx)
            if tret == 'Ljava/lang/String;' and targs == ['[S', 'I', 'I', 'I'] and len(arg) >= 4:
                b, c, e = arg[1], arg[2], arg[3]
                arr = tabs.get(arg[0]) or (own[0] if len(own) == 1 else None)
                if arr and b in regs and c in regs and e in regs:
                    start, ln, key = regs[b], regs[c], regs[e]
                    if isinstance(start, int) and isinstance(ln, int) and isinstance(key, int):
                        if 0 <= start and 0 < ln <= 8192 and start + ln <= len(arr):
                            s = ''.join(chr((arr[start + k] ^ key) & 0xFFFF) for k in range(ln))
                            if plausible(s):
                                out.add(s)
            elif tret == 'Ljava/lang/String;' and not targs and op == 0x71:
                if depth > 0 and midx2 not in seen:
                    seen.add(midx2)
                    tgt = midx_map.get(midx2)
                    if tgt and tgt[3]:
                        ts = scan(d, tgt[3], arrays, [], midx_map, depth - 1, seen)
                        out |= ts
        elif op in (0x28, 0x29, 0x2A, 0x2B, 0x2C):
            regs.clear()
            tabs.clear()
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'inner-plaintext.dex'
    out_path = sys.argv[2] if len(sys.argv) > 2 else 'sites_strings.json'
    d = Dex(open(path, 'rb').read())
    arrays = collect_tables(d)
    midx_map = method_index(d)

    result = {}
    for cd in d.class_defs():
        own = [a for (c, f), a in arrays.items() if c == cd['name']]
        allstr = set()
        for midx, co in d.class_methods(cd['class_data_off']):
            allstr |= scan(d, co, arrays, own, midx_map, 3, {midx})
        if allstr:
            result[cd['name']] = sorted(allstr)

    json.dump(result, open(out_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print('类数 %d -> %s' % (len(result), out_path))


if __name__ == '__main__':
    main()

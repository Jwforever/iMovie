#!/usr/bin/env python3
"""按类提取 DEX 里的 const-string 常量。

目的：把 CatVod spider 插件里每个 csp_Xxx 类的 URL 模板、CSS/XPath 选择器、
正则等字符串常量抽出来，用于生成跨平台规则，而不需要执行 Dalvik。
"""
import struct
import sys
import json
import re


def uleb128(buf, off):
    result = 0
    shift = 0
    while True:
        b = buf[off]
        off += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, off
        shift += 7


class Dex:
    def __init__(self, data):
        self.d = data
        (self.string_ids_size, self.string_ids_off,
         self.type_ids_size, self.type_ids_off,
         self.proto_ids_size, self.proto_ids_off,
         self.field_ids_size, self.field_ids_off,
         self.method_ids_size, self.method_ids_off,
         self.class_defs_size, self.class_defs_off) = struct.unpack_from("<12I", data, 56)
        self._strings = {}

    def string(self, idx):
        s = self._strings.get(idx)
        if s is not None:
            return s
        off = struct.unpack_from("<I", self.d, self.string_ids_off + idx * 4)[0]
        _, p = uleb128(self.d, off)
        end = self.d.index(b"\x00", p)
        raw = self.d[p:end]
        # MUTF-8：先按 utf-8 宽松解，再补 surrogate
        try:
            s = raw.decode("utf-8", "replace")
        except Exception:
            s = raw.decode("latin-1")
        self._strings[idx] = s
        return s

    def type_name(self, idx):
        return self.string(struct.unpack_from("<I", self.d, self.type_ids_off + idx * 4)[0])

    def method(self, idx):
        """返回 (class_name, method_name, proto_shorty)"""
        off = self.method_ids_off + idx * 8
        class_idx, proto_idx, name_idx = struct.unpack_from("<HHI", self.d, off)
        return self.type_name(class_idx), self.string(name_idx), proto_idx

    def field(self, idx):
        """返回 (class_name, field_name, type_name)"""
        off = self.field_ids_off + idx * 8
        class_idx, type_idx, name_idx = struct.unpack_from("<HHI", self.d, off)
        return self.type_name(class_idx), self.string(name_idx), self.type_name(type_idx)

    def class_defs(self):
        for i in range(self.class_defs_size):
            off = self.class_defs_off + i * 32
            (class_idx, access, super_idx, ifaces, src_idx,
             anno, class_data_off, static_vals) = struct.unpack_from("<8I", self.d, off)
            yield {
                "name": self.type_name(class_idx),
                "super": self.type_name(super_idx) if super_idx != 0xFFFFFFFF else "",
                "class_data_off": class_data_off,
            }

    def class_methods(self, class_data_off):
        """解析 class_data，返回方法索引列表"""
        if not class_data_off:
            return []
        p = class_data_off
        sf, p = uleb128(self.d, p)
        inf, p = uleb128(self.d, p)
        dm, p = uleb128(self.d, p)
        vm, p = uleb128(self.d, p)
        for _ in range(sf + inf):
            _, p = uleb128(self.d, p)
            _, p = uleb128(self.d, p)
        out = []
        for count in (dm, vm):
            idx = 0
            for _ in range(count):
                diff, p = uleb128(self.d, p)
                _, p = uleb128(self.d, p)  # access_flags
                code_off, p = uleb128(self.d, p)
                idx += diff
                out.append((idx, code_off))
        return out

    def code_strings(self, code_off):
        """扫 code_item 的 const-string / const-string/jumbo 指令"""
        if not code_off:
            return []
        insns_size = struct.unpack_from("<I", self.d, code_off + 12)[0]
        base = code_off + 16
        out = []
        i = 0
        while i < insns_size:
            w = struct.unpack_from("<H", self.d, base + i * 2)[0]
            op = w & 0xFF
            if op == 0x1A:  # const-string
                sidx = struct.unpack_from("<H", self.d, base + (i + 1) * 2)[0]
                out.append(sidx)
                i += 2
                continue
            if op == 0x1B:  # const-string/jumbo
                sidx = struct.unpack_from("<I", self.d, base + (i + 1) * 2)[0]
                out.append(sidx)
                i += 3
                continue
            i += 1
        return out


def main(dex_path, out_path=None):
    d = Dex(open(dex_path, "rb").read())
    print(f"strings={d.string_ids_size} classes={d.class_defs_size} methods={d.method_ids_size}")

    result = {}
    for cd in d.class_defs():
        name = cd["name"]
        if not name.startswith("L"):
            continue
        cls = name[1:-1].replace("/", ".")
        methods = d.class_methods(cd["class_data_off"])
        per_method = {}
        allstr = []
        for midx, code_off in methods:
            try:
                cname, mname, _ = d.method(midx)
            except Exception:
                continue
            sidx = d.code_strings(code_off)
            if not sidx:
                continue
            vals = []
            for s in sidx:
                try:
                    vals.append(d.string(s))
                except Exception:
                    pass
            if vals:
                per_method.setdefault(mname, [])
                for v in vals:
                    if v not in per_method[mname]:
                        per_method[mname].append(v)
                    if v not in allstr:
                        allstr.append(v)
        if allstr:
            result[cls] = {"super": cd["super"], "strings": allstr, "methods": per_method}

    print(f"有字符串的类：{len(result)}")
    if out_path:
        json.dump(result, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print("已写出", out_path)
    return result


if __name__ == "__main__":
    p = sys.argv[1] if len(sys.argv) > 1 else "inner-plaintext.dex"
    o = sys.argv[2] if len(sys.argv) > 2 else "dex-classes.json"
    r = main(p, o)

    # 概览：哪些类像采集器
    print("\n=== 含 http / 选择器特征的类 ===")
    n = 0
    for cls, info in r.items():
        s = " ".join(info["strings"])
        if re.search(r"https?://|\.php|\.html|#[A-Za-z]", s):
            n += 1
            print(f"  {cls}  ({len(info['strings'])} strings)")
    print(f"合计 {n}")

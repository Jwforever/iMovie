#!/usr/bin/env python3
"""最小可用的 Dalvik 解释器，用来原样执行 CatVod spider 包里的采集器。

为什么需要它
------------
配置里的 `csp_XxxGuard` 只是类名，真正的解析逻辑（拼 URL、选元素、取属性、
正则截取）全在各站自己的字节码里。OK影视 之所以能跑任意源，是因为它让安卓
执行这段字节码。本文件在 Python 侧复刻同一件事：解释执行，而不是猜规则。

    python dvm.py inner.dex com.github.catvod.spider.Auete homeContent
"""
import base64
import gzip
import hashlib
import json
import math
import re
import struct
import sys
import time
import urllib.parse
import urllib.request
import zlib

sys.stdout.reconfigure(encoding='utf-8')


# --------------------------------------------------------------------------
# DEX 解析
# --------------------------------------------------------------------------

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


def sleb128(buf, off):
    result = 0
    shift = 0
    while True:
        b = buf[off]
        off += 1
        result |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            if b & 0x40:
                result |= -(1 << shift)
            return result, off


def to_s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def to_s32(v):
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v & 0x80000000 else v


def to_s64(v):
    v &= 0xFFFFFFFFFFFFFFFF
    return v - 0x10000000000000000 if v & 0x8000000000000000 else v


def is_wide(t):
    return t in ('J', 'D')


def default_value(t):
    if t in ('J', 'I', 'S', 'B', 'C', 'Z'):
        return 0
    if t in ('F', 'D'):
        return 0.0
    return None


class ClassInfo:
    __slots__ = ('name', 'super', 'interfaces', 'access', 'methods', 'fields',
                 'static_fields', 'initialized', 'initializing')

    def __init__(self, name):
        self.name = name
        self.super = None
        self.interfaces = []
        self.access = 0
        self.methods = {}
        self.fields = {}
        self.static_fields = {}
        self.initialized = False
        self.initializing = False


class Method:
    __slots__ = ('cls', 'name', 'params', 'ret', 'access', 'code_off', 'idx')

    def __init__(self):
        self.code_off = 0

    @property
    def is_static(self):
        return bool(self.access & 0x0008)

    @property
    def is_abstract(self):
        return bool(self.access & 0x0400)

    def __repr__(self):
        return '%s->%s(%s)' % (self.cls.name.split('/')[-1], self.name, ''.join(self.params))


class Dex:
    def __init__(self, data):
        self.d = data
        (self.string_ids_size, self.string_ids_off,
         self.type_ids_size, self.type_ids_off,
         self.proto_ids_size, self.proto_ids_off,
         self.field_ids_size, self.field_ids_off,
         self.method_ids_size, self.method_ids_off,
         self.class_defs_size, self.class_defs_off) = struct.unpack_from('<12I', data, 56)
        self.strings = {}
        self.classes = {}
        self.load()

    def string(self, idx):
        s = self.strings.get(idx)
        if s is not None:
            return s
        off = struct.unpack_from('<I', self.d, self.string_ids_off + idx * 4)[0]
        _, p = uleb128(self.d, off)
        end = self.d.index(b'\x00', p)
        s = self.d[p:end].decode('utf-8', 'replace')
        self.strings[idx] = s
        return s

    def type_name(self, idx):
        return self.string(struct.unpack_from('<I', self.d, self.type_ids_off + idx * 4)[0])

    def proto(self, idx):
        off = self.proto_ids_off + idx * 12
        shorty_idx, ret_idx, params_off = struct.unpack_from('<III', self.d, off)
        params = []
        if params_off:
            size = struct.unpack_from('<I', self.d, params_off)[0]
            for i in range(size):
                params.append(self.type_name(struct.unpack_from('<H', self.d, params_off + 4 + i * 2)[0]))
        return self.type_name(ret_idx), params

    def field(self, idx):
        off = self.field_ids_off + idx * 8
        c, t, n = struct.unpack_from('<HHI', self.d, off)
        return self.type_name(c), self.string(n), self.type_name(t)

    def method_ref(self, idx):
        off = self.method_ids_off + idx * 8
        c, p, n = struct.unpack_from('<HHI', self.d, off)
        ret, params = self.proto(p)
        return self.type_name(c), self.string(n), params, ret

    def load(self):
        for i in range(self.class_defs_size):
            off = self.class_defs_off + i * 32
            (class_idx, access, super_idx, ifaces_off, src_idx,
             anno, class_data_off, static_values) = struct.unpack_from('<8I', self.d, off)
            ci = ClassInfo(self.type_name(class_idx))
            ci.access = access
            ci.super = self.type_name(super_idx) if super_idx != 0xFFFFFFFF else None
            if ifaces_off:
                n = struct.unpack_from('<I', self.d, ifaces_off)[0]
                for k in range(n):
                    ci.interfaces.append(
                        self.type_name(struct.unpack_from('<H', self.d, ifaces_off + 4 + k * 2)[0]))
            if class_data_off:
                self._class_data(ci, class_data_off, static_values)
            self.classes[ci.name] = ci
        return self

    def _class_data(self, ci, off, static_values):
        p = off
        sf, p = uleb128(self.d, p)
        inf, p = uleb128(self.d, p)
        dm, p = uleb128(self.d, p)
        vm, p = uleb128(self.d, p)
        values = self._encoded_array(static_values) if static_values else []
        idx = 0
        for i in range(sf):
            diff, p = uleb128(self.d, p)
            access, p = uleb128(self.d, p)
            idx += diff
            c, n, t = self.field(idx)
            ci.static_fields[(c, n)] = values[i] if i < len(values) else default_value(t)
        idx = 0
        for i in range(inf):
            diff, p = uleb128(self.d, p)
            access, p = uleb128(self.d, p)
            idx += diff
            c, n, t = self.field(idx)
            ci.fields[(c, n)] = t
        for count, virtual in ((dm, False), (vm, True)):
            idx = 0
            for _ in range(count):
                diff, p = uleb128(self.d, p)
                access, p = uleb128(self.d, p)
                code, p = uleb128(self.d, p)
                idx += diff
                c, name, params, ret = self.method_ref(idx)
                m = Method()
                m.cls = ci
                m.name = name
                m.params = params
                m.ret = ret
                m.access = access
                m.code_off = code
                m.idx = idx
                ci.methods.setdefault(name, []).append(m)

    def _encoded_array(self, off):
        size, p = uleb128(self.d, off)
        out = []
        for _ in range(size):
            v, p = self._encoded_value(p)
            out.append(v)
        return out

    def _encoded_value(self, p):
        b = self.d[p]
        p += 1
        vtype = b & 0x1F
        varg = b >> 5
        if vtype == 0x00:
            return None, p
        if vtype in (0x02, 0x03, 0x04, 0x06):
            n = varg + 1
            val = int.from_bytes(self.d[p:p + n], 'little')
            p += n
            if vtype == 0x02:
                val = to_s16(val)
            elif vtype == 0x03:
                val = to_s32(val)
            elif vtype == 0x04:
                val = to_s64(val)
            return val, p
        if vtype == 0x17:
            n = varg + 1
            val = self.string(int.from_bytes(self.d[p:p + n], 'little'))
            p += n
            return val, p
        if vtype == 0x18:
            return int.from_bytes(self.d[p:p + (varg + 1) * 4 if False else (varg + 1) * 4], 'little'), p
        if vtype == 0x1c:
            return self._encoded_array(p)
        p += {0x1e: 4, 0x1f: 8}.get(vtype, 4)
        return None, p

    def code_item(self, off):
        registers, ins, outs, tries, debug, insns_size = struct.unpack_from('<HHHHII', self.d, off)
        return {
            'registers': registers,
            'ins': ins,
            'insns_size': insns_size,
            'base': off + 16,
            'tries': tries,
            'tries_off': off + 16 + insns_size * 4,
        }

    def handlers_at(self, code, pc):
        if not code['tries']:
            return []
        tries_off = code['tries_off']
        handlers_off = tries_off + code['tries'] * 8
        for i in range(code['tries']):
            start, count, handler = struct.unpack_from('<IHH', self.d, tries_off + i * 8)
            if start <= pc < start + count:
                out = []
                pos = handlers_off + handler * 2
                size, pos = sleb128(self.d, pos)
                for _ in range(abs(size)):
                    tidx, pos = uleb128(self.d, pos)
                    addr, pos = uleb128(self.d, pos)
                    out.append((self.type_name(tidx), addr))
                if size <= 0:
                    addr, pos = uleb128(self.d, pos)
                    out.append((None, addr))
                return out
        return []


# --------------------------------------------------------------------------
# 运行时值
# --------------------------------------------------------------------------

class JObject:
    __slots__ = ('cls', 'fields')

    def __init__(self, cls):
        self.cls = cls
        self.fields = {}

    def __repr__(self):
        return '<%s>' % (self.cls.name.split('/')[-1] if self.cls else '?')


class JArray:
    __slots__ = ('cls', 'items')

    def __init__(self, cls, items):
        self.cls = cls
        self.items = items

    def __repr__(self):
        return '<array %s>' % self.cls


class JThrow(Exception):
    def __init__(self, obj):
        self.obj = obj

    def __str__(self):
        return describe(self.obj)


def describe(v):
    if isinstance(v, str):
        return v
    if isinstance(v, JObject):
        msg = None
        if v.cls:
            msg = v.fields.get((v.cls.name, 'detailMessage'))
        return ('%s: %s' % (v.cls.name, msg)) if msg else (v.cls.name if v.cls else repr(v))
    return repr(v)


RETURN_VOID = object()


# --------------------------------------------------------------------------
# 解释器
# --------------------------------------------------------------------------

SIZE = [1] * 256
for op in ([0x02, 0x05, 0x08, 0x13, 0x15, 0x16, 0x19, 0x1a, 0x1c, 0x1f, 0x20, 0x21,
            0x22, 0x23, 0x29] + list(range(0x2d, 0x3e)) + list(range(0x44, 0x6e)) +
           list(range(0x90, 0xb0)) + list(range(0xd0, 0xe3))):
    SIZE[op] = 2
for op in ([0x03, 0x06, 0x09, 0x14, 0x17, 0x1b, 0x24, 0x25, 0x26, 0x2a, 0x2b, 0x2c] +
           list(range(0x6e, 0x79))):
    SIZE[op] = 3
SIZE[0x18] = 5
SIZE[0xfa] = SIZE[0xfb] = 4


def _if_ok(op, a, b):
    if op == 0x32:
        return a == b
    if op == 0x33:
        return a != b
    if op == 0x34:
        return a < b
    if op == 0x35:
        return a >= b
    if op == 0x36:
        return a > b
    if op == 0x37:
        return a <= b
    return False


class VM:
    def __init__(self, dex_path, verbose=False):
        self.dex = Dex(open(dex_path, 'rb').read())
        self.statics = {}
        self.verbose = verbose
        self.http_log = []
        self.calls = 0
        self.trace = False
        self.stack = []
        self.steps = 0
        self.per_method = {}
        self.install_natives()

    # ---------------- 类与方法 ----------------
    def cls(self, name):
        return self.dex.classes.get(name)

    def is_subclass(self, child, parent):
        if child == parent:
            return True
        ci = self.cls(child)
        seen = set()
        while ci and ci.name not in seen:
            seen.add(ci.name)
            if ci.name == parent or parent in ci.interfaces:
                return True
            for i in ci.interfaces:
                if self.is_subclass(i, parent):
                    return True
            ci = self.cls(ci.super) if ci.super else None
        return False

    def find_method(self, cname, name, params):
        ci = self.cls(cname)
        seen = set()
        while ci and ci.name not in seen:
            seen.add(ci.name)
            for m in ci.methods.get(name, []):
                if params is None or m.params == params:
                    return m
            for i in ci.interfaces:
                m = self.find_method(i, name, params)
                if m:
                    return m
            ci = self.cls(ci.super) if ci.super else None
        return None

    def ensure_init(self, cname):
        ci = self.cls(cname)
        if not ci or ci.initialized or ci.initializing:
            return
        ci.initializing = True
        for m in ci.methods.get('<clinit>', []):
            self.invoke(m, [], None)
        ci.initialized = True
        ci.initializing = False

    # ---------------- 字段 ----------------
    def get_static(self, cname, fname, ftype):
        key = (cname, fname)
        if key not in self.statics:
            self.ensure_init(cname)
            if key not in self.statics:
                self.statics[key] = default_value(ftype)
        return self.statics[key]

    def set_static(self, cname, fname, ftype, value):
        self.statics[(cname, fname)] = value

    # ---------------- 调用 ----------------
    def invoke(self, method, args, this):
        self.calls += 1
        if not method.code_off:
            return self.call_native(method, args, this)
        return self.execute(method, args, this)

    def resolve(self, mcls, mname, mparams, kind, this):
        if kind in ('virtual', 'interface') and this is not None:
            if isinstance(this, (JObject, JArray)):
                cname = this.cls.name
            elif isinstance(this, str):
                cname = 'Ljava/lang/String;'
            else:
                cname = mcls
            m = self.find_method(cname, mname, mparams)
            if m:
                return m
        # direct / static / super 一律按声明的类找，避免把父类构造器
        # 误派发回当前类（会造成无限递归）。
        m = self.find_method(mcls, mname, mparams)
        if m:
            return m
        if mcls.startswith(('Ljava/', 'Ljavax/', 'Landroid/', 'Lokhttp3/', 'Lorg/json/',
                            'Lcom/github/catvod/crawler/', 'Lkotlin')):
            return self.stub_method(mcls, mname, mparams)
        raise JThrow(self.exception('Ljava/lang/NoSuchMethodError;',
                                    '%s->%s%s' % (mcls, mname, ''.join(mparams))))

    def stub_method(self, cname, name, params):
        """jar 之外（java/android/okhttp/catvod 宿主）的方法：交给垫片。"""
        ci = self.cls(cname) or ClassInfo(cname)
        m = Method()
        m.cls = ci
        m.name = name
        m.params = params
        m.ret = 'Ljava/lang/Object;'
        m.access = 0
        m.code_off = 0
        m.idx = 0
        return m

    def exception(self, cls, message):
        obj = JObject(self.cls(cls) or ClassInfo(cls))
        obj.fields[(cls, 'detailMessage')] = str(message)
        return obj

    # ---------------- 执行 ----------------
    def execute(self, method, args, this):
        self.stack.append('%s.%s' % (method.cls.name.split('/')[-1], method.name))
        if len(self.stack) > 1500:
            raise RuntimeError('调用过深: ' + ' <- '.join(self.stack[-15:]))
        try:
            return self._execute(method, args, this)
        finally:
            self.stack.pop()

    def _execute(self, method, args, this):
        code = self.dex.code_item(method.code_off)
        regs = [None] * code['registers']
        d = self.dex.d
        base = code['base']

        slots = []
        if this is not None:
            slots.append(this)
        for t, v in zip(method.params, args):
            if t == 'Z':
                v = 1 if v else 0
            slots.append(v)
            if is_wide(t):
                slots.append(None)
        start = code['registers'] - len(slots)
        for i, v in enumerate(slots):
            regs[start + i] = v

        pc = 0
        pending = None
        while True:
            w = struct.unpack_from('<H', d, base + pc * 2)[0]
            op = w & 0xFF
            A = (w >> 8) & 0xFF
            B = (w >> 8) & 0xF
            C = (w >> 12) & 0xF
            nxt = pc + SIZE[op]

            def u16(i):
                return struct.unpack_from('<H', d, base + (pc + i) * 2)[0]

            def s16(i):
                return struct.unpack_from('<h', d, base + (pc + i) * 2)[0]

            def s32(i):
                return struct.unpack_from('<i', d, base + (pc + i) * 2)[0]

            self.steps += 1
            key = method.cls.name.split('/')[-1] + '.' + method.name
            self.per_method[key] = self.per_method.get(key, 0) + 1
            if self.steps % 3000000 == 0 and self.steps <= 9000000:
                print('  ... %d 步' % self.steps)
            try:
                # ---- 常量 ----
                if op == 0x00:
                    pass
                elif op == 0x12:                                  # const/4
                    regs[(w >> 8) & 0xF] = ((w >> 12) & 0xF) << 28 >> 28
                elif op == 0x13:                                  # const/16
                    regs[A] = s16(1)
                elif op == 0x14:                                  # const
                    regs[A] = s32(1)
                elif op == 0x15:                                  # const/high16
                    regs[A] = to_s32(s16(1) << 16)
                elif op == 0x16:                                  # const-wide/16
                    regs[A] = s16(1)
                    regs[A + 1] = None
                elif op == 0x17:                                  # const-wide/32
                    regs[A] = s32(1)
                    regs[A + 1] = None
                elif op == 0x18:                                  # const-wide
                    regs[A] = to_s64((u16(2) << 32) | u16(1))
                    regs[A + 1] = None
                elif op == 0x19:                                  # const-wide/high16
                    regs[A] = to_s64(s16(1) << 48)
                    regs[A + 1] = None
                elif op == 0x1a:
                    regs[A] = self.dex.string(u16(1))
                elif op == 0x1b:
                    regs[A] = self.dex.string(s32(1) & 0xFFFFFFFF)
                elif op == 0x1c:
                    regs[A] = ('class', self.dex.type_name(u16(1)))

                # ---- 移动 ----
                elif op == 0x01:
                    regs[B] = regs[C]
                elif op == 0x02 or op == 0x03:
                    regs[A] = regs[u16(1)]
                elif op == 0x04:
                    regs[B] = regs[C]
                    regs[B + 1] = None
                elif op == 0x05 or op == 0x06:
                    v = u16(1)
                    regs[A] = regs[v]
                    regs[A + 1] = None
                elif op == 0x07:
                    regs[B] = regs[C]
                elif op == 0x08 or op == 0x09:
                    regs[A] = regs[u16(1)]

                # ---- 返回 ----
                elif op == 0x0e:
                    return RETURN_VOID
                elif op == 0x0f or op == 0x10 or op == 0x11:
                    return regs[A]

                # ---- move-result ----
                elif op == 0x0a:
                    regs[A] = pending if pending is not None else 0
                    pending = None
                elif op == 0x0b:
                    regs[A] = pending if pending is not None else 0
                    regs[A + 1] = None
                    pending = None
                elif op == 0x0c:
                    regs[A] = pending
                    pending = None

                # ---- 异常 / 同步 ----
                elif op == 0x0d:
                    regs[A] = self._caught
                    self._caught = None
                elif op in (0x1d, 0x1e):
                    pass
                elif op == 0x27:
                    raise JThrow(regs[A])

                # ---- 类型 ----
                elif op == 0x1f:
                    pass
                elif op == 0x20:
                    t = self.dex.type_name(u16(1))
                    v = regs[(w >> 12) & 0xF]
                    if isinstance(v, JObject):
                        ok = self.is_subclass(v.cls.name, t)
                    elif isinstance(v, JArray):
                        ok = v.cls == t
                    elif isinstance(v, str):
                        ok = t == 'Ljava/lang/String;'
                    else:
                        ok = False
                    regs[(w >> 8) & 0xF] = 1 if ok else 0
                elif op == 0x21:
                    v = regs[(w >> 12) & 0xF]
                    regs[(w >> 8) & 0xF] = len(v.items) if isinstance(v, JArray) else 0
                elif op == 0x22:
                    name = self.dex.type_name(u16(1))
                    self.ensure_init(name)
                    regs[A] = JObject(self.cls(name) or ClassInfo(name))
                elif op == 0x23:
                    t = self.dex.type_name(u16(1))
                    n = int(regs[(w >> 12) & 0xF] or 0)
                    regs[(w >> 8) & 0xF] = JArray(
                        t, [default_value(t[1:]) for _ in range(max(0, n))])
                elif op in (0x24, 0x25):
                    t = self.dex.type_name(u16(1))
                    if op == 0x24:
                        unit = u16(2)
                        A = (w >> 12) & 0xF
                        rlist = [unit & 0xF, (unit >> 4) & 0xF, (unit >> 8) & 0xF, (unit >> 12) & 0xF]
                        pending = JArray(t, [regs[r] for r in rlist[:A]])
                    else:
                        first = u16(2)
                        pending = JArray(t, [regs[first + i] for i in range(A)])
                elif op == 0x26:
                    self._fill_array(regs[A], pc + s32(1), d, base)

                # ---- 跳转 / 分支 ----
                elif op == 0x28:
                    nxt = pc + to_s16(A | 0xFF00) if A & 0x80 else pc + A
                elif op == 0x29:
                    nxt = pc + s16(1)
                elif op == 0x2a:
                    nxt = pc + s32(1)
                elif 0x2d <= op <= 0x31:
                    x, y = regs[u16(1) & 0xFF], regs[(u16(1) >> 8) & 0xFF]
                    if op in (0x2d, 0x2e):
                        x, y = float(x), float(y)
                    if op == 0x2e and (math.isnan(x) or math.isnan(y)):
                        regs[A] = 1
                    elif op == 0x2d and (math.isnan(x) or math.isnan(y)):
                        regs[A] = -1
                    else:
                        regs[A] = -1 if x < y else (1 if x > y else 0)
                elif 0x32 <= op <= 0x37:
                    a, b = regs[(w >> 8) & 0xF] or 0, regs[(w >> 12) & 0xF] or 0
                    if _if_ok(op, a, b):
                        nxt = pc + s16(1)
                elif 0x38 <= op <= 0x3d:
                    a = regs[A] or 0
                    if _if_ok(op - 6, a, 0):
                        nxt = pc + s16(1)
                elif op == 0x2b:
                    payload = pc + s32(1)
                    size = struct.unpack_from('<H', d, base + payload * 2 + 2)[0]
                    first = struct.unpack_from('<i', d, base + payload * 2 + 4)[0]
                    for i in range(size):
                        if first + i == regs[A]:
                            nxt = pc + struct.unpack_from('<i', d, base + payload * 2 + 8 + i * 4)[0]
                            break
                elif op == 0x2c:
                    payload = pc + s32(1)
                    size = struct.unpack_from('<H', d, base + payload * 2 + 2)[0]
                    for i in range(size):
                        if struct.unpack_from('<i', d, base + payload * 2 + 4 + i * 8)[0] == regs[A]:
                            nxt = pc + struct.unpack_from('<i', d, base + payload * 2 + 8 + i * 8)[0]
                            break

                # ---- 数组 ----
                elif 0x44 <= op <= 0x51:
                    u = u16(1)
                    arr, idx = regs[u & 0xFF], regs[(u >> 8) & 0xFF]
                    items = arr.items if isinstance(arr, JArray) else arr
                    if op <= 0x4a:
                        regs[A] = items[idx]
                        if op == 0x45:
                            regs[A + 1] = None
                    else:
                        items[idx] = regs[A]
                # ---- 实例字段 ----
                elif 0x52 <= op <= 0x5f:
                    fcls, fname, ftype = self.dex.field(u16(1))
                    a4, b4 = (w >> 8) & 0xF, (w >> 12) & 0xF
                    obj = regs[b4]
                    if op <= 0x58:
                        regs[a4] = self._field(obj, fcls, fname, ftype)
                        if op == 0x53:
                            regs[a4 + 1] = None
                    else:
                        obj.fields[(fcls, fname)] = regs[a4]
                # ---- 静态字段 ----
                elif 0x60 <= op <= 0x6d:
                    fcls, fname, ftype = self.dex.field(u16(1))
                    if op <= 0x66:
                        regs[A] = self.get_static(fcls, fname, ftype)
                        if op == 0x61:
                            regs[A + 1] = None
                    else:
                        self.set_static(fcls, fname, ftype, regs[A])

                # ---- 调用 ----
                elif 0x6e <= op <= 0x78:
                    mcls, mname, mparams, mret = self.dex.method_ref(u16(1))
                    if op <= 0x72:
                        count = (w >> 12) & 0xF
                        unit = u16(2)
                        rlist = [unit & 0xF, (unit >> 4) & 0xF,
                                 (unit >> 8) & 0xF, (unit >> 12) & 0xF]
                        kind = ('virtual', 'super', 'direct', 'static', 'interface')[op - 0x6e]
                    else:
                        count = A
                        first = u16(2)
                        rlist = list(range(first, first + count))
                        kind = ('virtual', 'super', 'direct', 'static', 'interface')[op - 0x74]
                    vals, this_obj = self._collect([regs[r] for r in rlist], count, mparams,
                                                   kind == 'static')
                    target = self.resolve(mcls, mname, mparams, kind, this_obj)
                    if self.trace:
                        print('CALL %s->%s count=%d rlist=%s vals=%s this=%r' % (
                            mcls.split('/')[-1], mname, count, rlist, vals,
                            type(this_obj).__name__))
                    if self.verbose:
                        print('  call %s->%s' % (mcls.split('/')[-1], mname))
                    pending = self.invoke(target, vals, this_obj)

                # ---- 一元 / 二元 ----
                elif 0x7b <= op <= 0x8f:
                    regs[A] = self._unop(op, regs[B])
                    if op in (0x7d, 0x7e, 0x81, 0x83, 0x85, 0x86, 0x88, 0x89, 0x8b, 0x8c):
                        regs[A + 1] = None
                elif 0x90 <= op <= 0xaf:
                    u = u16(1)
                    regs[A] = self._binop(op, regs[u & 0xFF], regs[(u >> 8) & 0xFF])
                    if op in (0x9b, 0x9c, 0x9d, 0x9e, 0x9f, 0xa0, 0xa1, 0xa2, 0xa3, 0xa4,
                              0xa5, 0xab, 0xac, 0xad, 0xae, 0xaf):
                        regs[A + 1] = None
                elif 0xb0 <= op <= 0xcf:
                    a4 = (w >> 8) & 0xF
                    regs[a4] = self._binop(op - 0xb0 + 0x90, regs[a4], regs[B])
                elif 0xd0 <= op <= 0xd7:
                    x, y = regs[(w >> 12) & 0xF], s16(1)
                    val = {0xd0: x + y, 0xd1: y - x, 0xd2: x * y,
                           0xd3: int(x / y) if y else 0, 0xd4: x - int(x / y) * y if y else 0,
                           0xd5: x & y, 0xd6: x | y, 0xd7: x ^ y}[op]
                    regs[(w >> 8) & 0xF] = to_s32(val)
                elif 0xd8 <= op <= 0xe2:
                    a, b = regs[A], regs[B]
                    regs[A] = self._binop(op - 0xd8 + 0x90, a, b)
                    regs[A] = to_s32(regs[A])
                else:
                    raise RuntimeError('未实现指令 0x%02x @%d in %r' % (op, pc, method))
            except JThrow as exc:
                handler = None
                for tname, addr in self.dex.handlers_at(code, pc):
                    if tname is None or (isinstance(exc.obj, JObject) and self.is_subclass(exc.obj.cls.name, tname)):
                        handler = addr
                        break
                if handler is None:
                    raise
                regs[A] = None
                self._caught = exc.obj
                nxt = handler
            pc = nxt

    # ---------------- 指令辅助 ----------------
    def _fill_array(self, arr, payload, d, base):
        ident = struct.unpack_from('<H', d, base + payload * 2)[0]
        width = struct.unpack_from('<H', d, base + payload * 2 + 2)[0]
        size = struct.unpack_from('<I', d, base + payload * 2 + 4)[0]
        data_off = (payload + 4) * 2
        raw = d[base + data_off: base + data_off + size * width]
        if not isinstance(arr, JArray):
            return
        for i in range(min(size, len(arr.items))):
            chunk = raw[i * width:(i + 1) * width]
            if width == 1:
                arr.items[i] = chunk[0]
            elif width == 2:
                arr.items[i] = to_s16(int.from_bytes(chunk, 'little'))
            elif width == 4:
                arr.items[i] = to_s32(int.from_bytes(chunk, 'little'))
            else:
                arr.items[i] = to_s64(int.from_bytes(chunk, 'little'))

    def _field(self, obj, fcls, fname, ftype):
        if isinstance(obj, JObject):
            key = (fcls, fname)
            if key in obj.fields:
                return obj.fields[key]
            if fname in obj.fields:
                return obj.fields[fname]
            return default_value(ftype)
        if isinstance(obj, JArray) and fname in ('length',):
            return len(obj.items)
        return default_value(ftype)

    def _collect(self, rlist, count, params, static):
        words = [rlist[i] for i in range(min(count, len(rlist)))]
        pos = 0
        this_obj = None
        if not static:
            this_obj = words[0] if words else None
            pos = 1
        args = []
        for t in params:
            if pos >= len(words):
                args.append(default_value(t))
            else:
                args.append(words[pos])
            pos += 2 if is_wide(t) else 1
        return args, this_obj

    def _unop(self, op, v):
        if op == 0x7b:
            return to_s32(-v)
        if op == 0x7c:
            return to_s32(~v)
        if op == 0x7d:
            return to_s64(-v)
        if op == 0x7e:
            return to_s64(~v)
        if op == 0x7f:
            return -float(v)
        if op == 0x80:
            return -float(v)
        if op == 0x81:
            return to_s64(v)
        if op == 0x82:
            return float(v)
        if op == 0x83:
            return float(v)
        if op == 0x84:
            return to_s32(v)
        if op == 0x85:
            return float(v)
        if op == 0x86:
            return float(v)
        if op == 0x87:
            return to_s32(int(v))
        if op == 0x88:
            return to_s64(int(v))
        if op == 0x89:
            return float(v)
        if op == 0x8a:
            return to_s32(int(v))
        if op == 0x8b:
            return to_s64(int(v))
        if op == 0x8c:
            return float(v)
        if op == 0x8d:
            return to_s32(v & 0xFF if v & 0x80 == 0 else v | ~0xFF)
        if op == 0x8e:
            return v & 0xFFFF
        if op == 0x8f:
            return to_s16(v & 0xFFFF)
        raise RuntimeError('unop 0x%02x' % op)

    def _binop(self, op, a, b):
        if op == 0x90:
            return to_s32(a + b)
        if op == 0x91:
            return to_s32(a - b)
        if op == 0x92:
            return to_s32(a * b)
        if op == 0x93:
            return to_s32(int(a / b)) if b else 0
        if op == 0x94:
            return to_s32(a - int(a / b) * b) if b else 0
        if op == 0x95:
            return to_s32(a & b)
        if op == 0x96:
            return to_s32(a | b)
        if op == 0x97:
            return to_s32(a ^ b)
        if op == 0x98:
            return to_s32(a << (b & 31))
        if op == 0x99:
            return to_s32(a >> (b & 31))
        if op == 0x9a:
            return to_s32((a & 0xFFFFFFFF) >> (b & 31))
        if op == 0x9b:
            return to_s64(a + b)
        if op == 0x9c:
            return to_s64(a - b)
        if op == 0x9d:
            return to_s64(a * b)
        if op == 0x9e:
            return to_s64(int(a / b)) if b else 0
        if op == 0x9f:
            return to_s64(a - int(a / b) * b) if b else 0
        if op == 0xa0:
            return to_s64(a & b)
        if op == 0xa1:
            return to_s64(a | b)
        if op == 0xa2:
            return to_s64(a ^ b)
        if op == 0xa3:
            return to_s64(a << (b & 63))
        if op == 0xa4:
            return to_s64(a >> (b & 63))
        if op == 0xa5:
            return to_s64((a & 0xFFFFFFFFFFFFFFFF) >> (b & 63))
        if op == 0xa6:
            return float(a) + float(b)
        if op == 0xa7:
            return float(a) - float(b)
        if op == 0xa8:
            return float(a) * float(b)
        if op == 0xa9:
            return float(a) / float(b) if b else math.inf
        if op == 0xaa:
            return math.fmod(float(a), float(b)) if b else math.nan
        if op == 0xab:
            return float(a) + float(b)
        if op == 0xac:
            return float(a) - float(b)
        if op == 0xad:
            return float(a) * float(b)
        if op == 0xae:
            return float(a) / float(b) if b else math.inf
        if op == 0xaf:
            return math.fmod(float(a), float(b)) if b else math.nan
        raise RuntimeError('binop 0x%02x' % op)

    # ---------------- 垫片 ----------------
    def install_natives(self):
        self.natives = {}

        def reg(cls, name, fn):
            self.natives[(cls, name)] = fn

        import runtime_shims
        runtime_shims.install(self, reg)
        runtime_shims._apply_aliases(self)

    def call_native(self, method, args, this):
        cls = method.cls.name
        fn = self.natives.get((cls, method.name))
        if fn is None:
            # 沿父类找
            ci = self.cls(method.cls.super) if method.cls.super else None
            while ci:
                fn = self.natives.get((ci.name, method.name))
                if fn:
                    break
                ci = self.cls(ci.super) if ci.super else None
        if fn is None:
            # 框架内部对象（okhttp 的 Dispatcher/ConnectionPool、并发工具等）
            # 对采集结果没有影响，统一给空值，避免每遇到一个就停下。
            if cls.startswith(('Lokhttp3/', 'Landroid/', 'Ljavax/', 'Ljava/util/concurrent/',
                               'Lkotlin', 'Ljava/io/')):
                return None
            raise JThrow(self.exception('Ljava/lang/UnsatisfiedLinkError;',
                                        '%s->%s' % (cls, method.name)))
        return fn(self, this, args)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'inner.dex'
    cname = sys.argv[2] if len(sys.argv) > 2 else 'com.github.catvod.spider.Auete'
    mname = sys.argv[3] if len(sys.argv) > 3 else 'homeContent'
    vm = VM(path)
    m = vm.find_method('L' + cname.replace('.', '/') + ';', mname, [])
    if not m:
        print('找不到方法', cname, mname)
        return 1
    t0 = time.time()
    try:
        out = vm.invoke(m, [], None)
    except JThrow as exc:
        print('异常:', describe(exc.obj))
        return 2
    print('耗时 %.2fs，调用 %d 次' % (time.time() - t0, vm.calls))
    print(out if isinstance(out, str) else json.dumps(out, ensure_ascii=False)[:2000])
    return 0


if __name__ == '__main__':
    sys.exit(main())

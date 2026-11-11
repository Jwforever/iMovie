#!/usr/bin/env python3
"""Dalvik 解释器需要的外部运行时（java.* / org.json / okhttp3 等）。

jar 里 1052 个类是它自带的 HTML 引擎，会原样作为字节码执行；
这里只补 jar 之外的东西：字符串、容器、JSON、正则、HTTP。
"""
import base64
import gzip
import io
import json
import math
import re
import urllib.error
import urllib.parse
import urllib.request
import zlib

from dvm import JArray, JObject, JThrow, ClassInfo, describe, default_value, to_s32, to_s64


def slot(obj, key, default=None):
    return obj.fields.get(key, default)


def set_slot(obj, key, value):
    obj.fields[key] = value
    return value


def text(v):
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, str):
        return v
    if isinstance(v, float):
        return str(v)
    if isinstance(v, JObject):
        if v.cls and v.cls.name == 'Ljava/lang/String;':
            return slot(v, 'value') or ''
        return str(v.fields.get(('Ljava/lang/StringBuilder;', 'buf'), ''))
    return str(v)


def java_string(v):
    """把 Python 值变成 java.lang.String 的表示（解释器里字符串就是 str）。"""
    if v is None:
        return None
    if isinstance(v, str):
        return v
    if isinstance(v, JObject):
        buf = v.fields.get(('Ljava/lang/StringBuilder;', 'buf'))
        if buf is not None:
            return buf
        if v.cls and v.cls.name == 'Ljava/lang/String;':
            return v.fields.get('value', '')
    if isinstance(v, JArray):
        return '[' + ', '.join(java_string(x) for x in v.items) + ']'
    return str(v)


def truthy(v):
    if isinstance(v, str):
        return bool(v)
    return bool(v)


def install(vm, reg):
    def always(ret):
        return lambda vm, this, args: ret

    # ------------------------------------------------------------------
    # Object / Class
    # ------------------------------------------------------------------
    def obj_init(vm, this, args):
        return None

    def obj_hash(vm, this, args):
        return id(this) & 0x7FFFFFFF

    def obj_equals(vm, this, args):
        other = args[0]
        if isinstance(this, str):
            return 1 if this == java_string(other) else 0
        return 1 if this is other else 0

    def obj_tostring(vm, this, args):
        return java_string(this)

    reg('Ljava/lang/Object;', '<init>', obj_init)
    reg('Ljava/lang/Object;', 'hashCode', obj_hash)
    reg('Ljava/lang/Object;', 'equals', obj_equals)
    reg('Ljava/lang/Object;', 'toString', obj_tostring)
    reg('Ljava/lang/Object;', 'getClass', lambda vm, this, args: JObject(ClassInfo('Ljava/lang/Class;')))

    # ------------------------------------------------------------------
    # String
    # ------------------------------------------------------------------
    def s_init(vm, this, args):
        return None

    def arg(args, i, default=''):
        return java_string(args[i]) if i < len(args) and args[i] is not None else default

    reg('Ljava/lang/String;', '<init>', s_init)
    reg('Ljava/lang/String;', 'length', lambda vm, this, args: len(this))
    reg('Ljava/lang/String;', 'isEmpty', lambda vm, this, args: 1 if this == '' else 0)
    reg('Ljava/lang/String;', 'trim', lambda vm, this, args: this.strip())
    reg('Ljava/lang/String;', 'toString', lambda vm, this, args: this)
    reg('Ljava/lang/String;', 'hashCode', lambda vm, this, args: hash(this) & 0x7FFFFFFF)
    reg('Ljava/lang/String;', 'intern', lambda vm, this, args: this)
    reg('Ljava/lang/String;', 'toLowerCase', lambda vm, this, args: this.lower())
    reg('Ljava/lang/String;', 'toUpperCase', lambda vm, this, args: this.upper())
    reg('Ljava/lang/String;', 'chars', lambda vm, this, args: JArray('[C', list(this)))
    reg('Ljava/lang/String;', 'toCharArray', lambda vm, this, args: JArray('[C', list(this)))
    reg('Ljava/lang/String;', 'getBytes',
        lambda vm, this, args: JArray('[B', list(this.encode(arg(args, 0, 'utf-8') if args else 'utf-8'))))

    def s_charat(vm, this, args):
        i = int(args[0])
        return this[i] if 0 <= i < len(this) else '\u0000'

    def s_indexof(vm, this, args):
        sub = arg(args, 0)
        start = int(args[1]) if len(args) > 1 else 0
        return this.find(sub, start)

    def s_lastindexof(vm, this, args):
        sub = arg(args, 0)
        return this.rfind(sub)

    def s_substring(vm, this, args):
        a = int(args[0])
        b = int(args[1]) if len(args) > 1 else len(this)
        return this[a:b]

    def s_contains(vm, this, args):
        return 1 if arg(args, 0) in this else 0

    def s_startswith(vm, this, args):
        return 1 if this.startswith(arg(args, 0), int(args[1]) if len(args) > 1 else 0) else 0

    def s_endswith(vm, this, args):
        return 1 if this.endswith(arg(args, 0)) else 0

    def s_equals(vm, this, args):
        return 1 if this == java_string(args[0]) else 0

    def s_equalsignore(vm, this, args):
        return 1 if this.lower() == arg(args, 0).lower() else 0

    def s_replace(vm, this, args):
        return this.replace(arg(args, 0), arg(args, 1))

    def s_replaceall(vm, this, args):
        return re.sub(arg(args, 0), re.sub(r'\$(\d)', r'\\\1', arg(args, 1)), this)

    def s_repfirst(vm, this, args):
        return re.sub(arg(args, 0), arg(args, 1), this, count=1)

    def s_split(vm, this, args):
        pattern = arg(args, 0)
        parts = re.split(pattern, this)
        if len(args) > 1:
            parts = parts[:int(args[1])]
        return JArray('[Ljava/lang/String;', parts)

    def s_matches(vm, this, args):
        return 1 if re.fullmatch(arg(args, 0), this) else 0

    def s_compareto(vm, this, args):
        other = arg(args, 0)
        return -1 if this < other else (1 if this > other else 0)

    def s_valueof(vm, this, args):
        if not args or args[0] is None:
            return 'null'
        v = args[0]
        if isinstance(v, bool):
            return 'true' if v else 'false'
        if isinstance(v, float):
            return ('%d' % v) if v == int(v) else repr(v)
        if isinstance(v, JArray) and v.cls == '[C':
            return ''.join(v.items)
        return java_string(v)

    def s_format(vm, this, args):
        fmt = arg(args, 0)
        rest = args[1:]
        fmt = re.sub(r'%(\d+\$)?([sdfxX])', lambda m: '%' + m.group(2), fmt)
        try:
            return fmt % tuple(java_string(a) if not isinstance(a, (int, float)) else a for a in rest)
        except Exception:
            return fmt

    for name, fn in [('charAt', s_charat), ('indexOf', s_indexof), ('lastIndexOf', s_lastindexof),
                     ('substring', s_substring), ('contains', s_contains), ('startsWith', s_startswith),
                     ('endsWith', s_endswith), ('equals', s_equals), ('equalsIgnoreCase', s_equalsignore),
                     ('replace', s_replace), ('replaceAll', s_replaceall),
                     ('replaceFirst', s_repfirst), ('split', s_split), ('matches', s_matches),
                     ('compareTo', s_compareto)]:
        reg('Ljava/lang/String;', name, fn)
    reg('Ljava/lang/String;', 'valueOf', s_valueof)
    reg('Ljava/lang/String;', 'format', s_format)
    reg('Ljava/lang/String;', 'join', lambda vm, this, args: arg(args, 0).join(
        java_string(x) for x in (args[1].items if len(args) > 1 and isinstance(args[1], JArray) else args[1:])))

    # ------------------------------------------------------------------
    # StringBuilder / StringBuffer
    # ------------------------------------------------------------------
    def sb_init(vm, this, args):
        this.fields[('Ljava/lang/StringBuilder;', 'buf')] = arg(args, 0) if args else ''
        return None

    def sb_append(vm, this, args):
        buf = this.fields.get(('Ljava/lang/StringBuilder;', 'buf'), '')
        if args:
            v = args[0]
            if isinstance(v, JArray) and v.cls == '[C':
                buf += ''.join(v.items)
            elif isinstance(v, float):
                buf += ('%d' % v) if v == int(v) else repr(v)
            elif isinstance(v, JObject) and v.cls and v.cls.name == 'Ljava/lang/StringBuilder;':
                buf += v.fields.get(('Ljava/lang/StringBuilder;', 'buf'), '')
            else:
                buf += java_string(v)
        this.fields[('Ljava/lang/StringBuilder;', 'buf')] = buf
        return this

    def sb_tostring(vm, this, args):
        return java_string(this)

    def sb_insert(vm, this, args):
        buf = this.fields.get(('Ljava/lang/StringBuilder;', 'buf'), '')
        pos = int(args[0])
        this.fields[('Ljava/lang/StringBuilder;', 'buf')] = buf[:pos] + java_string(args[1]) + buf[pos:]
        return this

    def sb_setlength(vm, this, args):
        buf = this.fields.get(('Ljava/lang/StringBuilder;', 'buf'), '')
        n = int(args[0])
        this.fields[('Ljava/lang/StringBuilder;', 'buf')] = buf[:n].ljust(n, '\u0000')
        return None

    for cls in ('Ljava/lang/StringBuilder;', 'Ljava/lang/StringBuffer;'):
        reg(cls, '<init>', sb_init)
        reg(cls, 'append', sb_append)
        reg(cls, 'toString', sb_tostring)
        reg(cls, 'insert', sb_insert)
        reg(cls, 'setLength', sb_setlength)
        reg(cls, 'length', lambda vm, this, args: len(
            this.fields.get(('Ljava/lang/StringBuilder;', 'buf'), '')))
        reg(cls, 'reverse', lambda vm, this, args: set_slot(
            this, ('Ljava/lang/StringBuilder;', 'buf'),
            this.fields.get(('Ljava/lang/StringBuilder;', 'buf'), '')[::-1]) and this)
        reg(cls, 'charAt', lambda vm, this, args: this.fields.get(
            ('Ljava/lang/StringBuilder;', 'buf'), '')[int(args[0])])
        reg(cls, 'deleteCharAt', lambda vm, this, args: _sb_delete(this, int(args[0]), int(args[0]) + 1))
        reg(cls, 'delete', lambda vm, this, args: _sb_delete(this, int(args[0]), int(args[1])))
        reg(cls, 'substring', lambda vm, this, args: this.fields.get(
            ('Ljava/lang/StringBuilder;', 'buf'), '')[int(args[0]):int(args[1]) if len(args) > 1 else None])

    def _sb_delete(obj, a, b):
        buf = obj.fields.get(('Ljava/lang/StringBuilder;', 'buf'), '')
        obj.fields[('Ljava/lang/StringBuilder;', 'buf')] = buf[:a] + buf[b:]
        return obj

    # ------------------------------------------------------------------
    # 包装类型 / Math / System
    # ------------------------------------------------------------------
    def to_int(v):
        if isinstance(v, str):
            t = v.strip()
            return int(t, 16) if t.lower().startswith('0x') else int(float(t)) if t else 0
        if v is None:
            return 0
        return int(v)

    for cls in ('Ljava/lang/Integer;', 'Ljava/lang/Long;', 'Ljava/lang/Short;',
                'Ljava/lang/Byte;', 'Ljava/lang/Double;', 'Ljava/lang/Float;'):
        reg(cls, 'parseInt', lambda vm, this, args: to_int(args[0]))
        reg(cls, 'parseLong', lambda vm, this, args: to_int(args[0]))
        reg(cls, 'parseDouble', lambda vm, this, args: float(args[0]))
        reg(cls, 'parseFloat', lambda vm, this, args: float(args[0]))
        reg(cls, 'valueOf', lambda vm, this, args: args[0] if args else 0)
        reg(cls, 'intValue', lambda vm, this, args: to_int(this if not isinstance(this, JObject) else 0))
        reg(cls, 'longValue', lambda vm, this, args: to_int(this if not isinstance(this, JObject) else 0))
        reg(cls, 'doubleValue', lambda vm, this, args: float(this))
        reg(cls, 'toString', lambda vm, this, args: str(to_int(args[0])))
        reg(cls, 'equals', lambda vm, this, args: 1 if this == args[0] else 0)
        reg(cls, 'compare', lambda vm, this, args: -1 if args[0] < args[1] else (1 if args[0] > args[1] else 0))

    reg('Ljava/lang/Boolean;', 'valueOf', lambda vm, this, args: 1 if truthy(args[0]) else 0)
    reg('Ljava/lang/Boolean;', 'parseBoolean', lambda vm, this, args: 1 if arg(args, 0).lower() == 'true' else 0)
    reg('Ljava/lang/Boolean;', 'booleanValue', lambda vm, this, args: 1 if truthy(this) else 0)
    reg('Ljava/lang/Character;', 'isDigit', lambda vm, this, args: 1 if str(args[0])[:1].isdigit() else 0)
    reg('Ljava/lang/Character;', 'isLetter', lambda vm, this, args: 1 if str(args[0])[:1].isalpha() else 0)
    reg('Ljava/lang/Character;', 'toString', lambda vm, this, args: str(args[0]))

    reg('Ljava/lang/Math;', 'max', lambda vm, this, args: max(args[0], args[1]))
    reg('Ljava/lang/Math;', 'min', lambda vm, this, args: min(args[0], args[1]))
    reg('Ljava/lang/Math;', 'abs', lambda vm, this, args: abs(args[0]))
    reg('Ljava/lang/Math;', 'floor', lambda vm, this, args: math.floor(float(args[0])))
    reg('Ljava/lang/Math;', 'ceil', lambda vm, this, args: math.ceil(float(args[0])))
    reg('Ljava/lang/Math;', 'round', lambda vm, this, args: int(round(float(args[0]))))
    reg('Ljava/lang/Math;', 'pow', lambda vm, this, args: float(args[0]) ** float(args[1]))
    reg('Ljava/lang/Math;', 'sqrt', lambda vm, this, args: math.sqrt(float(args[0])))
    reg('Ljava/lang/Math;', 'random', lambda vm, this, args: 0.42)

    reg('Ljava/lang/System;', 'currentTimeMillis', lambda vm, this, args: int(__import__('time').time() * 1000))
    reg('Ljava/lang/System;', 'nanoTime', lambda vm, this, args: int(__import__('time').time() * 1e9))
    reg('Ljava/lang/System;', 'getProperty', lambda vm, this, args: '')
    reg('Ljava/lang/System;', 'lineSeparator', lambda vm, this, args: '\n')
    reg('Ljava/lang/System;', 'arraycopy', lambda vm, this, args: _arraycopy(args))

    def _arraycopy(args):
        src, sp, dst, dp, n = args[0], int(args[1]), args[2], int(args[3]), int(args[4])
        for i in range(n):
            dst.items[dp + i] = src.items[sp + i]
        return None

    reg('Ljava/lang/Thread;', 'sleep', lambda vm, this, args: None)
    reg('Ljava/lang/Thread;', 'currentThread', lambda vm, this, args: JObject(ClassInfo('Ljava/lang/Thread;')))

    # ------------------------------------------------------------------
    # 集合
    # ------------------------------------------------------------------
    KEYS = (('Ljava/lang/StringBuilder;', 'buf'),)

    def list_of(obj):
        return obj.fields.setdefault(('Ljava/util/ArrayList;', 'items'), [])

    def map_of(obj):
        return obj.fields.setdefault(('Ljava/util/HashMap;', 'items'), {})

    def arraylist_init(vm, this, args):
        list_of(this).clear()
        return None

    def arraylist_add(vm, this, args):
        if len(args) == 1:
            list_of(this).append(args[0])
        else:
            list_of(this).insert(int(args[0]), args[1])
        return 1

    def arraylist_get(vm, this, args):
        items = list_of(this)
        i = int(args[0])
        return items[i] if 0 <= i < len(items) else None

    def arraylist_size(vm, this, args):
        return len(list_of(this))

    def arraylist_remove(vm, this, args):
        items = list_of(this)
        if not items:
            return None
        if isinstance(args[0], int) and 0 <= args[0] < len(items):
            return items.pop(int(args[0]))
        try:
            items.remove(args[0])
        except ValueError:
            pass
        return 1

    for cls in ('Ljava/util/ArrayList;', 'Ljava/util/Vector;', 'Ljava/util/LinkedList;',
                'Ljava/util/AbstractList;', 'Ljava/util/AbstractCollection;'):
        reg(cls, '<init>', arraylist_init)
        reg(cls, 'add', arraylist_add)
        reg(cls, 'get', arraylist_get)
        reg(cls, 'size', arraylist_size)
        reg(cls, 'remove', arraylist_remove)
        reg(cls, 'isEmpty', lambda vm, this, args: 1 if not list_of(this) else 0)
        reg(cls, 'clear', lambda vm, this, args: list_of(this).clear())
        reg(cls, 'contains', lambda vm, this, args: 1 if args[0] in list_of(this) else 0)
        reg(cls, 'indexOf', lambda vm, this, args: (list_of(this).index(args[0])
                                                   if args[0] in list_of(this) else -1))
        reg(cls, 'set', lambda vm, this, args: _list_set(this, args))
        reg(cls, 'addAll', lambda vm, this, args: _list_addall(this, args))
        reg(cls, 'iterator', lambda vm, this, args: _iterator(list_of(this)))
        reg(cls, 'toArray', lambda vm, this, args: JArray('[Ljava/lang/Object;', list(list_of(this))))
        reg(cls, 'subList', lambda vm, this, args: JArray(
            '[Ljava/lang/Object;', list_of(this)[int(args[0]):int(args[1])]))

    def _list_set(obj, args):
        items = list_of(obj)
        i = int(args[0])
        old = items[i] if i < len(items) else None
        if i < len(items):
            items[i] = args[1]
        return old

    def _list_addall(obj, args):
        src = args[0]
        items = list_of(obj)
        if isinstance(src, JArray):
            items.extend(src.items)
        elif isinstance(src, JObject):
            items.extend(list_of(src))
        return 1

    def _iterator(items):
        obj = JObject(ClassInfo('Ljava/util/Iterator;'))
        state = {'i': 0, 'items': items}
        obj.fields[('Ljava/util/Iterator;', 'state')] = state
        return obj

    def it_hasnext(vm, this, args):
        st = this.fields[('Ljava/util/Iterator;', 'state')]
        return 1 if st['i'] < len(st['items']) else 0

    def it_next(vm, this, args):
        st = this.fields[('Ljava/util/Iterator;', 'state')]
        v = st['items'][st['i']] if st['i'] < len(st['items']) else None
        st['i'] += 1
        return v

    reg('Ljava/util/Iterator;', 'hasNext', it_hasnext)
    reg('Ljava/util/Iterator;', 'next', it_next)
    reg('Ljava/util/Iterator;', 'remove', lambda vm, this, args: None)

    def hashmap_init(vm, this, args):
        map_of(this).clear()
        return None

    def hashmap_put(vm, this, args):
        m = map_of(this)
        old = m.get(args[0])
        m[args[0]] = args[1]
        return old

    def hashmap_get(vm, this, args):
        return map_of(this).get(args[0])

    def hashmap_keyset(vm, this, args):
        obj = JObject(ClassInfo('Ljava/util/Set;'))
        obj.fields[('Ljava/util/HashMap;', 'items')] = map_of(this)
        obj.fields[('Ljava/util/HashMap;', 'asKeys')] = True
        return obj

    for cls in ('Ljava/util/HashMap;', 'Ljava/util/LinkedHashMap;', 'Ljava/util/TreeMap;',
                'Ljava/util/AbstractMap;', 'Ljava/util/concurrent/ConcurrentHashMap;'):
        reg(cls, '<init>', hashmap_init)
        reg(cls, 'put', hashmap_put)
        reg(cls, 'get', hashmap_get)
        reg(cls, 'getOrDefault', lambda vm, this, args: map_of(this).get(args[0], args[1]))
        reg(cls, 'containsKey', lambda vm, this, args: 1 if args[0] in map_of(this) else 0)
        reg(cls, 'containsValue', lambda vm, this, args: 1 if args[0] in map_of(this).values() else 0)
        reg(cls, 'remove', lambda vm, this, args: map_of(this).pop(args[0], None))
        reg(cls, 'size', lambda vm, this, args: len(map_of(this)))
        reg(cls, 'isEmpty', lambda vm, this, args: 1 if not map_of(this) else 0)
        reg(cls, 'clear', lambda vm, this, args: map_of(this).clear())
        reg(cls, 'keySet', hashmap_keyset)
        reg(cls, 'values', lambda vm, this, args: JArray('[Ljava/lang/Object;', list(map_of(this).values())))
        reg(cls, 'entrySet', lambda vm, this, args: JArray(
            '[Ljava/lang/Object;', list(map_of(this).items())))

    reg('Ljava/util/Set;', 'iterator', lambda vm, this, args: _iterator(
        list(map_of(this).keys())))
    reg('Ljava/util/Set;', 'size', lambda vm, this, args: len(map_of(this)))

    # ------------------------------------------------------------------
    # 正则
    # ------------------------------------------------------------------
    def pattern_compile(vm, this, args):
        obj = JObject(ClassInfo('Ljava/util/regex/Pattern;'))
        obj.fields[('Ljava/util/regex/Pattern;', 'rx')] = re.compile(arg(args, 0))
        return obj

    def pattern_matcher(vm, this, args):
        obj = JObject(ClassInfo('Ljava/util/regex/Matcher;'))
        rx = this.fields[('Ljava/util/regex/Pattern;', 'rx')]
        obj.fields[('Ljava/util/regex/Matcher;', 'rx')] = rx
        obj.fields[('Ljava/util/regex/Matcher;', 'subject')] = arg(args, 0)
        obj.fields[('Ljava/util/regex/Matcher;', 'match')] = None
        return obj

    def matcher_find(vm, this, args):
        rx = this.fields[('Ljava/util/regex/Matcher;', 'rx')]
        subject = this.fields[('Ljava/util/regex/Matcher;', 'subject')]
        m = rx.search(subject)
        this.fields[('Ljava/util/regex/Matcher;', 'match')] = m
        return 1 if m else 0

    def matcher_group(vm, this, args):
        m = this.fields.get(('Ljava/util/regex/Matcher;', 'match'))
        if not m:
            return None
        i = int(args[0]) if args else 0
        try:
            return m.group(i)
        except Exception:
            return None

    def matcher_matches(vm, this, args):
        rx = this.fields[('Ljava/util/regex/Matcher;', 'rx')]
        subject = this.fields[('Ljava/util/regex/Matcher;', 'subject')]
        m = rx.fullmatch(subject)
        this.fields[('Ljava/util/regex/Matcher;', 'match')] = m
        return 1 if m else 0

    def matcher_replaceall(vm, this, args):
        rx = this.fields[('Ljava/util/regex/Matcher;', 'rx')]
        subject = this.fields[('Ljava/util/regex/Matcher;', 'subject')]
        return rx.sub(re.sub(r'\$(\d)', r'\\\1', arg(args, 0)), subject)

    reg('Ljava/util/regex/Pattern;', 'compile', pattern_compile)
    reg('Ljava/util/regex/Pattern;', 'matcher', pattern_matcher)
    reg('Ljava/util/regex/Pattern;', 'pattern', lambda vm, this, args: this.fields[
        ('Ljava/util/regex/Pattern;', 'rx')].pattern)
    reg('Ljava/util/regex/Matcher;', 'find', matcher_find)
    reg('Ljava/util/regex/Matcher;', 'matches', matcher_matches)
    reg('Ljava/util/regex/Matcher;', 'group', matcher_group)
    reg('Ljava/util/regex/Matcher;', 'groupCount', lambda vm, this, args: 0)
    reg('Ljava/util/regex/Matcher;', 'replaceAll', matcher_replaceall)
    reg('Ljava/util/regex/Matcher;', 'reset', lambda vm, this, args: this)

    # ------------------------------------------------------------------
    # IO
    # ------------------------------------------------------------------
    def baos_init(vm, this, args):
        this.fields[('Ljava/io/ByteArrayOutputStream;', 'buf')] = bytearray()
        return None

    def baos_write(vm, this, args):
        buf = this.fields[('Ljava/io/ByteArrayOutputStream;', 'buf')]
        v = args[0]
        if isinstance(v, JArray):
            buf.extend(bytes(x & 0xFF for x in v.items))
        else:
            buf.append(int(v) & 0xFF)
        return None

    def baos_bytes(vm, this, args):
        buf = this.fields[('Ljava/io/ByteArrayOutputStream;', 'buf')]
        return JArray('[B', list(bytes(buf)))

    reg('Ljava/io/ByteArrayOutputStream;', '<init>', baos_init)
    reg('Ljava/io/ByteArrayOutputStream;', 'write', baos_write)
    reg('Ljava/io/ByteArrayOutputStream;', 'toByteArray', baos_bytes)
    reg('Ljava/io/ByteArrayOutputStream;', 'size', lambda vm, this, args: len(
        this.fields[('Ljava/io/ByteArrayOutputStream;', 'buf')]))
    reg('Ljava/io/ByteArrayOutputStream;', 'toString', lambda vm, this, args: bytes(
        this.fields[('Ljava/io/ByteArrayOutputStream;', 'buf')]).decode('utf-8', 'replace'))
    reg('Ljava/io/ByteArrayOutputStream;', 'close', lambda vm, this, args: None)
    reg('Ljava/io/ByteArrayOutputStream;', 'flush', lambda vm, this, args: None)

    reg('Ljava/io/PrintStream;', 'println', lambda vm, this, args: print(arg(args, 0)) or None)
    reg('Ljava/io/PrintStream;', 'print', lambda vm, this, args: print(arg(args, 0), end='') or None)
    reg('Ljava/io/PrintStream;', 'flush', lambda vm, this, args: None)

    # ------------------------------------------------------------------
    # JSON
    # ------------------------------------------------------------------
    def json_container(obj, key, factory):
        return obj.fields.setdefault(key, factory())

    def jso_init(vm, this, args):
        data = json_container(this, ('Lorg/json/JSONObject;', 'map'), dict)
        if args and isinstance(args[0], str):
            try:
                data.update(json.loads(args[0]))
            except Exception:
                pass
        return None

    def jso_put(vm, this, args):
        m = json_container(this, ('Lorg/json/JSONObject;', 'map'), dict)
        key = java_string(args[0])
        val = args[1]
        if isinstance(val, JObject):
            inner = val.fields.get(('Lorg/json/JSONObject;', 'map'))
            val = inner if inner is not None else val.fields.get(('Lorg/json/JSONArray;', 'list'), val)
        elif isinstance(val, JArray):
            val = list(val.items)
        m[key] = val
        return this

    def jso_get(vm, this, args):
        return _json_get(this, java_string(args[0]))

    def _json_get(obj, key):
        m = obj.fields.get(('Lorg/json/JSONObject;', 'map'), {})
        if key not in m:
            raise JThrow(JObject(ClassInfo('Lorg/json/JSONException;')))
        v = m[key]
        return _wrap(v)

    def _wrap(v):
        if isinstance(v, dict):
            obj = JObject(ClassInfo('Lorg/json/JSONObject;'))
            obj.fields[('Lorg/json/JSONObject;', 'map')] = v
            return obj
        if isinstance(v, list):
            obj = JObject(ClassInfo('Lorg/json/JSONArray;'))
            obj.fields[('Lorg/json/JSONArray;', 'list')] = v
            return obj
        return v

    def jso_optstring(vm, this, args):
        m = this.fields.get(('Lorg/json/JSONObject;', 'map'), {})
        v = m.get(java_string(args[0]))
        if v is None:
            return java_string(args[1]) if len(args) > 1 and args[1] is not None else ''
        return java_string(_wrap(v))

    def jso_tostring(vm, this, args):
        return json.dumps(this.fields.get(('Lorg/json/JSONObject;', 'map'), {}),
                          ensure_ascii=False, separators=(',', ':'))

    def jso_keys(vm, this, args):
        obj = JObject(ClassInfo('Ljava/util/Iterator;'))
        obj.fields[('Ljava/util/Iterator;', 'state')] = {
            'i': 0, 'items': list(this.fields.get(('Lorg/json/JSONObject;', 'map'), {}).keys())}
        return obj

    for name, fn in [('<init>', jso_init), ('put', jso_put), ('get', jso_get),
                     ('optString', jso_optstring), ('getString', lambda vm, this, args: java_string(
                         this.fields.get(('Lorg/json/JSONObject;', 'map'), {}).get(java_string(args[0]), ''))),
                     ('optInt', lambda vm, this, args: int(this.fields.get(
                         ('Lorg/json/JSONObject;', 'map'), {}).get(java_string(args[0]),
                                                                  args[1] if len(args) > 1 else 0) or 0)),
                     ('optBoolean', lambda vm, this, args: 1 if this.fields.get(
                         ('Lorg/json/JSONObject;', 'map'), {}).get(java_string(args[0])) else 0),
                     ('has', lambda vm, this, args: 1 if java_string(args[0]) in this.fields.get(
                         ('Lorg/json/JSONObject;', 'map'), {}) else 0),
                     ('isNull', lambda vm, this, args: 1 if this.fields.get(
                         ('Lorg/json/JSONObject;', 'map'), {}).get(java_string(args[0])) is None else 0),
                     ('remove', lambda vm, this, args: this.fields.get(
                         ('Lorg/json/JSONObject;', 'map'), {}).pop(java_string(args[0]), None)),
                     ('length', lambda vm, this, args: len(this.fields.get(
                         ('Lorg/json/JSONObject;', 'map'), {}))),
                     ('toString', jso_tostring), ('keys', jso_keys),
                     ('optJSONObject', lambda vm, this, args: _opt_json(this, args, dict)),
                     ('optJSONArray', lambda vm, this, args: _opt_json(this, args, list)),
                     ('getJSONObject', lambda vm, this, args: _opt_json(this, args, dict, True)),
                     ('getJSONArray', lambda vm, this, args: _opt_json(this, args, list, True)),
                     ('names', lambda vm, this, args: JArray(
                         '[Ljava/lang/String;', list(this.fields.get(('Lorg/json/JSONObject;', 'map'), {}).keys())))]:
        reg('Lorg/json/JSONObject;', name, fn)

    def _opt_json(obj, args, want, strict=False):
        m = obj.fields.get(('Lorg/json/JSONObject;', 'map'), {})
        v = m.get(java_string(args[0]))
        if isinstance(v, want):
            return _wrap(v)
        if strict:
            raise JThrow(JObject(ClassInfo('Lorg/json/JSONException;')))
        return None

    def jsa_init(vm, this, args):
        lst = json_container(this, ('Lorg/json/JSONArray;', 'list'), list)
        if args:
            v = args[0]
            if isinstance(v, str):
                try:
                    parsed = json.loads(v)
                    if isinstance(parsed, list):
                        lst.extend(parsed)
                except Exception:
                    pass
            elif isinstance(v, JObject):
                inner = v.fields.get(('Ljava/util/ArrayList;', 'items'))
                if inner is not None:
                    lst.extend(inner)
            elif isinstance(v, JArray):
                lst.extend(v.items)
        return None

    def jsa_put(vm, this, args):
        lst = json_container(this, ('Lorg/json/JSONArray;', 'list'), list)
        v = args[0]
        if isinstance(v, JObject):
            v = v.fields.get(('Lorg/json/JSONObject;', 'map'), v)
        elif isinstance(v, JArray):
            v = list(v.items)
        lst.append(v)
        return this

    for name, fn in [('<init>', jsa_init), ('put', jsa_put),
                     ('length', lambda vm, this, args: len(this.fields.get(('Lorg/json/JSONArray;', 'list'), []))),
                     ('size', lambda vm, this, args: len(this.fields.get(('Lorg/json/JSONArray;', 'list'), []))),
                     ('get', lambda vm, this, args: _wrap(list(this.fields.get(
                         ('Lorg/json/JSONArray;', 'list'), []))[int(args[0])])),
                     ('optJSONObject', lambda vm, this, args: _jsa_opt(this, args, dict)),
                     ('optJSONArray', lambda vm, this, args: _jsa_opt(this, args, list)),
                     ('optString', lambda vm, this, args: java_string(_jsa_opt(this, args, str) or '')),
                     ('getString', lambda vm, this, args: java_string(_jsa_opt(this, args, str, True))),
                     ('getJSONObject', lambda vm, this, args: _jsa_opt(this, args, dict, True)),
                     ('getJSONArray', lambda vm, this, args: _jsa_opt(this, args, list, True)),
                     ('isNull', lambda vm, this, args: 1 if _jsa_opt(this, args, object) is None else 0),
                     ('toString', lambda vm, this, args: json.dumps(
                         this.fields.get(('Lorg/json/JSONArray;', 'list'), []), ensure_ascii=False,
                         separators=(',', ':')))]:
        reg('Lorg/json/JSONArray;', name, fn)

    def _jsa_opt(obj, args, want, strict=False):
        lst = obj.fields.get(('Lorg/json/JSONArray;', 'list'), [])
        i = int(args[0])
        v = lst[i] if 0 <= i < len(lst) else None
        if isinstance(v, want):
            return _wrap(v)
        if v is None and not strict:
            return None
        if want is str:
            return java_string(v)
        if strict:
            raise JThrow(JObject(ClassInfo('Lorg/json/JSONException;')))
        return None

    # ------------------------------------------------------------------
    # 编码
    # ------------------------------------------------------------------
    reg('Ljava/net/URLEncoder;', 'encode', lambda vm, this, args: urllib.parse.quote(
        java_string(args[0]), safe='').replace('%20', '+'))
    reg('Ljava/net/URLDecoder;', 'decode', lambda vm, this, args: urllib.parse.unquote(
        java_string(args[0])))

    reg('Landroid/text/TextUtils;', 'isEmpty', lambda vm, this, args: 1 if not java_string(
        args[0]) else 0)

    # Base64（安卓自带）
    def b64_encode(vm, this, args):
        raw = bytes(x & 0xFF for x in args[0].items)
        enc = base64.b64encode(raw).decode()
        flags = int(args[1]) if len(args) > 1 else 0
        if flags & 8:
            enc = enc.replace('+', '-').replace('/', '_')
        if not flags & 2:
            enc = enc.rstrip('=')
        return enc

    def b64_decode(vm, this, args):
        s = java_string(args[0]) if args else ''
        s = s.replace('-', '+').replace('_', '/')
        s += '=' * (-len(s) % 4)
        try:
            raw = base64.b64decode(s)
        except Exception:
            raw = b''
        return JArray('[B', list(raw))

    for cls in ('Landroid/util/Base64;',):
        reg(cls, 'encodeToString', b64_encode)
        reg(cls, 'decode', b64_decode)

    for cls in ('Ljava/util/Base64;',):
        reg(cls, 'getEncoder', always(JObject(ClassInfo('Ljava/util/Base64$Encoder;'))))
        reg(cls, 'getUrlEncoder', always(JObject(ClassInfo('Ljava/util/Base64$Encoder;'))))
        reg(cls, 'getDecoder', always(JObject(ClassInfo('Ljava/util/Base64$Decoder;'))))
    reg('Ljava/util/Base64$Encoder;', 'encodeToString', b64_encode)
    reg('Ljava/util/Base64$Decoder;', 'decode', b64_decode)

    # ------------------------------------------------------------------
    # okhttp3 → urllib
    # ------------------------------------------------------------------
    def http_client_init(vm, this, args):
        return None

    def http_new_call(vm, this, args):
        call = JObject(ClassInfo('Lokhttp3/Call;'))
        call.fields[('Lokhttp3/Call;', 'request')] = args[0]
        return call

    def request_builder_init(vm, this, args):
        this.fields[('Lokhttp3/Request$Builder;', 'url')] = ''
        this.fields[('Lokhttp3/Request$Builder;', 'headers')] = {}
        this.fields[('Lokhttp3/Request$Builder;', 'method')] = 'GET'
        this.fields[('Lokhttp3/Request$Builder;', 'body')] = None
        return None

    def request_url(vm, this, args):
        this.fields[('Lokhttp3/Request$Builder;', 'url')] = java_string(args[0])
        return this

    def request_add_header(vm, this, args):
        h = this.fields[('Lokhttp3/Request$Builder;', 'headers')]
        h[java_string(args[0])] = java_string(args[1])
        return this

    def request_method(vm, this, args):
        this.fields[('Lokhttp3/Request$Builder;', 'method')] = java_string(args[0])
        if len(args) > 1:
            this.fields[('Lokhttp3/Request$Builder;', 'body')] = args[1]
        return this

    def request_build(vm, this, args):
        req = JObject(ClassInfo('Lokhttp3/Request;'))
        for k in ('url', 'headers', 'method', 'body'):
            req.fields[('Lokhttp3/Request;', k)] = this.fields.get(('Lokhttp3/Request$Builder;', k))
        return req

    reg('Lokhttp3/OkHttpClient;', '<init>', http_client_init)
    reg('Lokhttp3/OkHttpClient;', 'newCall', http_new_call)
    reg('Lokhttp3/OkHttpClient$Builder;', '<init>', lambda vm, this, args: None)
    reg('Lokhttp3/OkHttpClient$Builder;', 'build', lambda vm, this, args: JObject(
        ClassInfo('Lokhttp3/OkHttpClient;')))
    for name in ('connectTimeout', 'readTimeout', 'writeTimeout', 'followRedirects',
                 'followSslRedirects', 'retryOnConnectionFailure', 'sslSocketFactory',
                 'addInterceptor', 'cookieJar', 'hostnameVerifier', 'proxy'):
        reg('Lokhttp3/OkHttpClient$Builder;', name, lambda vm, this, args: this)
    reg('Lokhttp3/Request$Builder;', '<init>', request_builder_init)
    reg('Lokhttp3/Request$Builder;', 'url', request_url)
    reg('Lokhttp3/Request$Builder;', 'addHeader', request_add_header)
    reg('Lokhttp3/Request$Builder;', 'header', lambda vm, this, args: _req_set_header(this, args))
    reg('Lokhttp3/Request$Builder;', 'removeHeader', lambda vm, this, args: this)
    reg('Lokhttp3/Request$Builder;', 'method', request_method)
    reg('Lokhttp3/Request$Builder;', 'get', lambda vm, this, args: request_method(vm, this, ['GET']))
    reg('Lokhttp3/Request$Builder;', 'post', lambda vm, this, args: request_method(vm, this, ['POST', args[0]]))
    reg('Lokhttp3/Request$Builder;', 'build', request_build)

    def _req_set_header(builder, args):
        builder.fields[('Lokhttp3/Request$Builder;', 'headers')][java_string(args[0])] = java_string(args[1])
        return builder

    def call_execute(vm, this, args):
        req = this.fields[('Lokhttp3/Call;', 'request')]
        url = req.fields.get(('Lokhttp3/Request;', 'url'), '')
        headers = dict(req.fields.get(('Lokhttp3/Request;', 'headers')) or {})
        method = req.fields.get(('Lokhttp3/Request;', 'method'), 'GET')
        body = req.fields.get(('Lokhttp3/Request;', 'body'))
        data = None
        if body is not None:
            if isinstance(body, JArray):
                data = bytes(x & 0xFF for x in body.items)
            elif isinstance(body, str):
                data = body.encode('utf-8')
            else:
                raw = body.fields.get(('Lokhttp3/RequestBody;', 'bytes'))
                data = raw if isinstance(raw, bytes) else None
        resp = JObject(ClassInfo('Lokhttp3/Response;'))
        try:
            request = urllib.request.Request(url, data=data, method=method, headers=headers)
            with urllib.request.urlopen(request, timeout=20) as r:
                raw = r.read()
                encoding = r.headers.get('Content-Encoding', '')
                if encoding == 'gzip':
                    raw = gzip.decompress(raw)
                elif encoding == 'deflate':
                    raw = zlib.decompress(raw, -zlib.MAX_WBITS)
                resp.fields[('Lokhttp3/Response;', 'code')] = r.status
                resp.fields[('Lokhttp3/Response;', 'bytes')] = raw
                resp.fields[('Lokhttp3/Response;', 'headers')] = dict(r.headers)
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            resp.fields[('Lokhttp3/Response;', 'code')] = exc.code
            resp.fields[('Lokhttp3/Response;', 'bytes')] = raw
            resp.fields[('Lokhttp3/Response;', 'headers')] = dict(exc.headers)
        except Exception as exc:
            vm.http_log.append((url, str(exc)))
            resp.fields[('Lokhttp3/Response;', 'code')] = 0
            resp.fields[('Lokhttp3/Response;', 'bytes')] = b''
            resp.fields[('Lokhttp3/Response;', 'headers')] = {}
        vm.http_log.append((url, resp.fields.get(('Lokhttp3/Response;', 'code'))))
        return resp

    reg('Lokhttp3/Call;', 'execute', call_execute)
    reg('Lokhttp3/Call;', 'enqueue', lambda vm, this, args: None)
    reg('Lokhttp3/Call;', 'cancel', lambda vm, this, args: None)
    reg('Lokhttp3/Response;', 'code', lambda vm, this, args: this.fields.get(('Lokhttp3/Response;', 'code'), 0))
    reg('Lokhttp3/Response;', 'isSuccessful', lambda vm, this, args: 1 if 200 <= this.fields.get(
        ('Lokhttp3/Response;', 'code'), 0) < 400 else 0)
    reg('Lokhttp3/Response;', 'close', lambda vm, this, args: None)
    reg('Lokhttp3/Response;', 'headers', lambda vm, this, args: _headers(this))
    reg('Lokhttp3/Response;', 'message', lambda vm, this, args: '')

    def _headers(resp):
        obj = JObject(ClassInfo('Lokhttp3/Headers;'))
        obj.fields[('Lokhttp3/Headers;', 'map')] = resp.fields.get(('Lokhttp3/Response;', 'headers'), {})
        return obj

    reg('Lokhttp3/Headers;', 'get', lambda vm, this, args: this.fields.get(
        ('Lokhttp3/Headers;', 'map'), {}).get(java_string(args[0])))
    reg('Lokhttp3/Headers;', 'toMultimap', lambda vm, this, args: _wrap(
        this.fields.get(('Lokhttp3/Headers;', 'map'), {})))

    def resp_body(vm, this, args):
        obj = JObject(ClassInfo('Lokhttp3/ResponseBody;'))
        obj.fields[('Lokhttp3/ResponseBody;', 'bytes')] = this.fields.get(('Lokhttp3/Response;', 'bytes'), b'')
        obj.fields[('Lokhttp3/ResponseBody;', 'headers')] = _headers(this)
        return obj

    reg('Lokhttp3/Response;', 'body', resp_body)
    reg('Lokhttp3/ResponseBody;', 'string', lambda vm, this, args: _decode_body(
        this.fields.get(('Lokhttp3/ResponseBody;', 'bytes'), b'')))
    reg('Lokhttp3/ResponseBody;', 'bytes', lambda vm, this, args: JArray(
        '[B', list(this.fields.get(('Lokhttp3/ResponseBody;', 'bytes'), b''))))
    reg('Lokhttp3/ResponseBody;', 'byteStream', lambda vm, this, args: _stream(
        this.fields.get(('Lokhttp3/ResponseBody;', 'bytes'), b'')))
    reg('Lokhttp3/ResponseBody;', 'close', lambda vm, this, args: None)
    reg('Lokhttp3/ResponseBody;', 'contentLength', lambda vm, this, args: len(
        this.fields.get(('Lokhttp3/ResponseBody;', 'bytes'), b'')))
    reg('Lokhttp3/ResponseBody;', 'contentType', lambda vm, this, args: None)

    def _decode_body(raw):
        for enc in ('utf-8', 'gbk', 'gb18030'):
            try:
                return raw.decode(enc)
            except Exception:
                continue
        return raw.decode('utf-8', 'replace')

    def _stream(raw):
        obj = JObject(ClassInfo('Ljava/io/InputStream;'))
        obj.fields[('Ljava/io/InputStream;', 'bytes')] = raw
        obj.fields[('Ljava/io/InputStream;', 'pos')] = 0
        return obj

    def stream_read(vm, this, args):
        raw = this.fields.get(('Ljava/io/InputStream;', 'bytes'), b'')
        pos = this.fields.get(('Ljava/io/InputStream;', 'pos'), 0)
        buf = args[0]
        if pos >= len(raw):
            return -1
        n = min(len(buf.items), len(raw) - pos)
        for i in range(n):
            buf.items[i] = raw[pos + i]
        this.fields[('Ljava/io/InputStream;', 'pos')] = pos + n
        return n

    reg('Ljava/io/InputStream;', 'read', stream_read)
    reg('Ljava/io/InputStream;', 'close', lambda vm, this, args: None)
    reg('Ljava/io/InputStream;', 'available', lambda vm, this, args: 0)

    reg('Lokhttp3/RequestBody;', 'create',
        lambda vm, this, args: _body(java_string(args[-1]) if args else ''))

    def _body(text_value):
        obj = JObject(ClassInfo('Lokhttp3/RequestBody;'))
        obj.fields[('Lokhttp3/RequestBody;', 'bytes')] = text_value.encode('utf-8')
        return obj

    def form_init(vm, this, args):
        this.fields[('Lokhttp3/FormBody$Builder;', 'pairs')] = []
        return None

    def form_add(vm, this, args):
        this.fields[('Lokhttp3/FormBody$Builder;', 'pairs')].append(
            (java_string(args[0]), java_string(args[1])))
        return this

    def form_build(vm, this, args):
        pairs = this.fields.get(('Lokhttp3/FormBody$Builder;', 'pairs'), [])
        body = '&'.join('%s=%s' % (urllib.parse.quote(k, safe=''), urllib.parse.quote(v, safe=''))
                        for k, v in pairs)
        return _body(body)

    reg('Lokhttp3/FormBody$Builder;', '<init>', form_init)
    reg('Lokhttp3/FormBody$Builder;', 'add', form_add)
    reg('Lokhttp3/FormBody$Builder;', 'addEncoded', form_add)
    reg('Lokhttp3/FormBody$Builder;', 'build', form_build)
    reg('Lokhttp3/MediaType;', 'parse', lambda vm, this, args: java_string(args[0]))

    # ------------------------------------------------------------------
    # CatVod 宿主 API
    # ------------------------------------------------------------------
    reg('Lcom/github/catvod/crawler/SpiderDebug;', 'log', lambda vm, this, args: None)
    reg('Lcom/github/catvod/crawler/Spider;', 'init', lambda vm, this, args: None)
    reg('Lcom/github/catvod/crawler/Spider;', '<init>', lambda vm, this, args: None)
    reg('Lcom/github/catvod/crawler/Spider;', 'homeVideoContent', lambda vm, this, args: '{}')
    reg('Lcom/github/catvod/crawler/Spider;', 'manualVideoCheck', lambda vm, this, args: 0)
    reg('Lcom/github/catvod/crawler/Spider;', 'destroy', lambda vm, this, args: None)
    reg('Lcom/github/catvod/crawler/Spider;', 'getName', lambda vm, this, args: '')
    reg('Lcom/github/catvod/crawler/Spider;', 'getConfig', lambda vm, this, args: '')

    # ------------------------------------------------------------------
    # Android 宿主（只补采集器会碰到的那几个）
    # ------------------------------------------------------------------
    reg('Landroid/content/Context;', 'getApplicationContext', lambda vm, this, args: this)
    reg('Landroid/content/Context;', 'getPackageName', lambda vm, this, args: 'com.github.catvod')
    reg('Landroid/content/Context;', 'getFilesDir', lambda vm, this, args: JObject(
        ClassInfo('Ljava/io/File;')))
    reg('Landroid/content/Context;', 'getCacheDir', lambda vm, this, args: JObject(
        ClassInfo('Ljava/io/File;')))
    reg('Landroid/content/Context;', 'getExternalFilesDir', lambda vm, this, args: JObject(
        ClassInfo('Ljava/io/File;')))
    reg('Ljava/io/File;', 'getAbsolutePath', lambda vm, this, args: '/tmp')


def _apply_aliases(vm):
    """接口名也要能派发：字节码里 Map/List/Set 是独立类型。"""
    alias = {
        'Ljava/util/Map;': 'Ljava/util/HashMap;',
        'Ljava/util/List;': 'Ljava/util/ArrayList;',
        'Ljava/util/Set;': 'Ljava/util/HashMap;',
        'Ljava/util/Collection;': 'Ljava/util/ArrayList;',
        'Ljava/lang/CharSequence;': 'Ljava/lang/String;',
        'Ljava/util/Map$Entry;': 'Ljava/util/HashMap;',
    }
    for (cls, name), fn in list(vm.natives.items()):
        for iface, impl in alias.items():
            if cls == impl:
                vm.natives.setdefault((iface, name), fn)

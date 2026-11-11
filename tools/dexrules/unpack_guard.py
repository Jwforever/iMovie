#!/usr/bin/env python3
"""解出饭太硬 jar 里 guard 容器中的内层 DEX（纯静态，不需要安卓）。

背景
----
jar 内的 `ftyshinidie.guard` 是一个"中央目录被抹掉"的 ZIP：每个 entry 的
local header 仍然完整，所以能读到文件名 / 压缩长度 / 原始长度，但标准解压
工具会因为字符集被扰动而失败。

扰动规则（已用一组 1287881 字节的密文 ↔ 2728036 字节明文 DEX 验证，
还原后 zlib 解压结果与安卓内存 dump 逐字节一致）：

    deflate 流中，凡字节值 ∈ {1, 2, 5, 6} 的，写入前被 XOR 0x07 过。
    即 1→6, 2→5, 5→2, 6→1（对低 3 位做补码取反）。
    该变换自逆，用同样规则再过一遍即可还原。

还原后再做 raw inflate（wbits=-15）即得内层 classes.dex。

用法
----
    python unpack_guard.py <jar 或 .guard 文件> [-o out.dex] [--list]

若不给 -o，默认写到内层 DEX 的原始文件名（classes.dex）。
"""
import argparse
import os
import struct
import sys
import zlib

sys.stdout.reconfigure(encoding='utf-8')

ZIP_LOCAL = b'PK\x03\x04'
ZIP_CENTRAL = b'PK\x01\x02'
ZIP_EOCD = b'PK\x05\x06'


def unscramble(data):
    """对 {1,2,5,6} 做 XOR 0x07。自逆。"""
    table = bytes(b ^ 7 if b in (1, 2, 5, 6) else b for b in range(256))
    return data.translate(table)


def parse_central_entries(blob):
    """按中央目录解析。返回 [(offset, name, method, csize, usize, data_off, flag)] 或 []。

    新版 jar 的 local header 带 data descriptor（flag & 8），csize/usize 写 0，
    只能从中央目录取真实长度。
    """
    eocd = blob.rfind(ZIP_EOCD)
    if eocd < 0 or eocd + 22 > len(blob):
        return []
    (_, _disk, _cd_disk, _n_disk, total, cd_size, cd_off, _clen) = struct.unpack_from(
        '<IHHHHIIH', blob, eocd)
    out = []
    pos = cd_off
    for _ in range(total):
        if pos + 46 > len(blob) or blob[pos:pos + 4] != ZIP_CENTRAL:
            break
        (_, _vmade, _vneed, flag, method, _t, _d, _crc, csize, usize,
         nlen, elen, clen, _dstart, _iattr, _eattr, lho) = struct.unpack_from(
            '<IHHHHHHIIIHHHHHII', blob, pos)
        name = blob[pos + 46:pos + 46 + nlen]
        data_off = lho + 30 + nlen + elen
        out.append((lho, name, method, csize, usize, data_off, flag))
        pos += 46 + nlen + elen + clen
    return out


def parse_local_entries(blob):
    """扫描所有 local file header。返回 [(offset, name, method, csize, usize, data_off)]。

    仅在没有中央目录（例如被抹掉目录的 .guard）时使用；带 data descriptor 的
    条目在这里读到的长度是 0，需要调用方自行跳过。
    """
    out = []
    pos = 0
    while True:
        i = blob.find(ZIP_LOCAL, pos)
        if i < 0:
            break
        if i + 30 > len(blob):
            break
        (_sig, _ver, flag, method, _t, _d, _crc,
         csize, usize, nlen, elen) = struct.unpack_from('<IHHHHHIIIHH', blob, i)
        name = blob[i + 30:i + 30 + nlen]
        data_off = i + 30 + nlen + elen
        out.append((i, name, method, csize, usize, data_off, flag))
        pos = data_off + max(csize, 0)
        if pos <= i:
            pos = i + 4
    return out


def parse_entries(blob):
    """优先中央目录，退回 local header 扫描。"""
    entries = parse_central_entries(blob)
    if entries:
        return entries
    return parse_local_entries(blob)


def try_inflate(data):
    """依次尝试几种还原方式，返回 (payload, label) 或 (None, 原因)。"""
    # 已经是明文 DEX（普通插件的 classes.dex），不用解
    if data[:4] == b'dex\n':
        return data, 'already plain dex'
    # 候选 1：先做 {1,2,5,6} 反扰，再 raw inflate
    cands = [
        ('guard-unscramble+deflate', unscramble(data)),
        ('plain deflate', data),
    ]
    for label, buf in cands:
        for wbits in (-15, 15, 47):
            try:
                d = zlib.decompressobj(wbits)
                out = d.decompress(buf)
                out += d.flush()
            except Exception:
                continue
            if len(out) >= 4 and out[:3] == b'dex':
                return out, label
    return None, 'no candidate inflate succeeded'


def inflate_entry(data, method, usize=0):
    """按 entry 的压缩方法还原字节流。method=0 原样返回。"""
    if method == 0:
        return data
    d = zlib.decompressobj(-15)
    out = d.decompress(data)
    out += d.flush()
    if usize and len(out) != usize:
        raise ValueError('usize mismatch: %d != %d' % (len(out), usize))
    return out


def load_container(path, _depth=0):
    """接受 jar / apk / 裸 guard 文件，返回 (待还原字节流, 描述)。

    容器可以嵌套：jar 里有 assets/xxx.guard，.guard 里又有 classes.dex。
    每一层都可能是 stored(0) 或 deflate(8)，带 data descriptor 时长度只在
    中央目录里，所以优先用中央目录。
    """
    with open(path, 'rb') as f:
        blob = f.read()
    base = os.path.basename(path)
    return _dig(blob, base, _depth)


def _dig(blob, label, depth):
    if depth > 4:
        return None, 'nesting too deep in %s' % label
    if blob[:4] == b'dex\n':
        return blob, 'plain dex in %s' % label
    if blob[:4] != ZIP_LOCAL:
        # 裸的混淆 deflate 流（或被抹掉头的 guard 数据）
        return blob, label
    entries = parse_entries(blob)
    for name in (b'.guard', b'classes.dex'):
        for off, ename, method, csize, usize, doff, _flag in entries:
            if not ename.endswith(name) or csize <= 0:
                continue
            data = blob[doff:doff + csize]
            # 最内层 classes.dex 的字节流可能是被扰动的，交给 try_inflate 处理
            if name == b'classes.dex':
                return data, 'entry %s (raw) in %s' % (ename.decode('utf-8', 'replace'), label)
            try:
                raw = inflate_entry(data, method, usize)
            except Exception as exc:
                return None, 'entry %s corrupted: %s' % (ename.decode('utf-8', 'replace'), exc)
            return _dig(raw, '%s!%s' % (label, ename.decode('utf-8', 'replace')), depth + 1)
    return None, 'no .guard or classes.dex entry in %s' % label


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('input', help='jar / apk / 裸 .guard 文件')
    ap.add_argument('-o', '--output', default=None)
    ap.add_argument('--list', action='store_true', help='只列出容器里的条目')
    args = ap.parse_args()

    if args.list:
        with open(args.input, 'rb') as f:
            blob = f.read()
        for off, name, method, csize, usize, doff, flag in parse_local_entries(blob):
            print('%-32s @0x%-8x method=%d csize=%-9d usize=%-9d' %
                  (name.decode('utf-8', 'replace'), off, method, csize, usize))
        return 0

    payload, desc = load_container(args.input)
    if payload is None:
        print('ERROR:', desc, file=sys.stderr)
        return 2

    out, label = try_inflate(payload)
    if out is None:
        print('ERROR: %s (输入 %s, %d 字节)' % (label, desc, len(payload)), file=sys.stderr)
        return 3

    dst = args.output or 'classes.inner.dex'
    with open(dst, 'wb') as f:
        f.write(out)
    print('来源      : %s' % desc)
    print('容器长度  : %d' % len(payload))
    print('解出 DEX  : %d 字节 -> %s' % (len(out), dst))
    print('方式      : %s' % label)
    if len(out) >= 0x70:
        file_size = struct.unpack_from('<I', out, 0x20)[0]
        print('DEX 声明长度: %d （%s）' % (file_size, '一致' if file_size == len(out) else '不一致'))
        print('DEX 版本    : %s' % out[4:8].decode('ascii', 'replace').strip('\x00'))
    return 0


if __name__ == '__main__':
    sys.exit(main())

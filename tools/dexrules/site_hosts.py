#!/usr/bin/env python3
"""从内层 DEX 里解出每个站点的域名，输出 站点 -> 域名 对照表。

输入
----
1. 内层 DEX（由 unpack_guard.py 从 jar 里解出）
2. 配置里的站点列表 JSON（形如 {"sites":[{"key","name","api","ext"},...]}）

处理链
------
DEX 里每个采集器类的字符串都被 `<clinit>` 用 fill-array-data 建的 short[] + key
异或编码过。本脚本：
  1. 扫描所有类，收集 short[] 常量表
  2. 找出所有 D(table,start,len,key) 调用，折叠参数并解出明文
  3. 递归展开无参 getter，把转发到别的类的字符串也追回来
  4. 按 `csp_XxxGuard` -> `com.github.catvod.spider.Xxx` 的命名规则归属到站点
  5. 过滤掉 SDK / 云盘 / 公共 CDN 域名，留下候选站点域名

用法
----
    python site_hosts.py inner.dex sites.json [-o site_hosts.json]
"""
import argparse
import json
import re
import sys

sys.stdout.reconfigure(encoding='utf-8')

from dexstr import Dex
from decode_strings import collect_tables, collect_getters, decode_class
from resolve_sites import method_index, scan

TLD = (r'(?:com|cn|net|org|cc|tv|xyz|vip|top|me|io|app|co|site|club|fun|pro|info|'
       r'biz|pw|link|live|one|art|dev|shop|icu|cyou|ltd|wang|ren|la|hk|tw|in|su|us|'
       r'uk|life|eu|sbs|cfd|monster|online|store|tech|space|website|host|press|wiki|'
       r'to|ws|de|fr|jp|kr|ru|nl|se|pl|cc)')
HOST_RE = re.compile(r'\b((?:[a-z0-9][a-z0-9-]{0,30}\.)+' + TLD + r')\b', re.I)

# 不属于"站点自身"的域名：SDK、云盘、公共 CDN、统计、广告
NOISE = (
    'aliyun', 'alipan', 'github', 'githubusercontent', 'bilibili', 'biliimg',
    'qq.com', 'baidu', 'douban', 'weibo', 'google', 'gstatic', 'googlesyndication',
    'apache', 'java.', 'android.', 'androidx', 'w3.org', 'json.org', 'sogoucdn',
    'imagehub', 'servicewechat', 'frodo.douban', '163.com', 'snssdk', 'cctv',
    'bdstatic', 'cloudflare', 'example', 'apple.com', 'schemas', 'xml.org',
    'kotlin', 'jetbrains', 'okhttp', 'squareup', 'glide', 'exoplayer',
    'material.io', 'zhihu', 'weixin', 'tencent', 'alicdn', 'taobao', 'jd.com',
    'kuaishou', 'douyin', 'bytedance', 'umeng', 'bugly', 'crashlytics',
    'firebase', 'facebook', 'twitter', 'telegram', 'youtube', 'w3schools',
    'mozilla', 'jquery', 'bootstrapcdn', 'jsdelivr', 'unpkg', 'cdnjs',
    'moji.com', 'huya.com', 'douyu.com', 'youlai.cn', 'fqnovel', 'rmb.bdstatic',
    'alidns', 'nn.ci', 'did', 'oeqvv', 'apple', 'gslock',
)

# 明确不是"视频站点"的类（云盘/推送/直播聚合），域名仅供参考
NON_SITE_CLASSES = {'MDrive', 'push_agent', 'Bili', 'Biliych', 'alllive'}


def guest_class_for(api):
    """csp_AueteGuard -> Auete；不是 Guard 形式则返回 None。"""
    if not api:
        return None
    m = re.match(r'csp_(\w+?)Guard$', api.strip())
    return m.group(1) if m else None


def hosts_in(strings, extra_pool=None):
    pool = set(strings)
    if extra_pool:
        pool |= set(extra_pool)
    found = set()
    for s in pool:
        if not isinstance(s, str):
            continue
        for h in HOST_RE.findall(s.lower()):
            if any(n in h for n in NOISE):
                continue
            found.add(h)
    return sorted(found)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dex')
    ap.add_argument('sites')
    ap.add_argument('-o', '--output', default='site_hosts.json')
    ap.add_argument('--quiet', action='store_true')
    args = ap.parse_args()

    dex = Dex(open(args.dex, 'rb').read())
    tables = collect_tables(dex)
    getters = collect_getters(dex, tables)

    by_class = {}
    for cd in dex.class_defs():
        hits = decode_class(dex, cd, tables, getters)
        if hits:
            by_class[cd['name']] = hits

    # 递归展开无参 getter，把转发出去的字符串补回来
    midx_map = method_index(dex)
    for cd in dex.class_defs():
        own = [a for (c, f), a in tables.items() if c == cd['name']]
        extra = set()
        for midx, co in dex.class_methods(cd['class_data_off']):
            if not co:
                continue
            extra |= scan(dex, co, tables, own, midx_map, 3, {midx})
        if extra:
            seen = {h['text'] for h in by_class.get(cd['name'], [])}
            by_class.setdefault(cd['name'], []).extend(
                {'text': s} for s in extra if s not in seen)

    sites = json.load(open(args.sites, encoding='utf-8'))
    sites = sites.get('sites', sites) if isinstance(sites, dict) else sites

    result = []
    covered = 0
    for site in sites:
        api = site.get('api') or ''
        cls_name = guest_class_for(api)
        if not cls_name:
            continue
        cls = 'Lcom/github/catvod/spider/%s;' % cls_name
        hits = by_class.get(cls, [])
        hosts = hosts_in([h['text'] for h in hits])
        if hosts:
            covered += 1
        result.append({
            'key': site.get('key'),
            'name': site.get('name'),
            'api': api,
            'class': cls_name,
            'isSite': cls_name not in NON_SITE_CLASSES,
            'hosts': hosts,
            'strings': len(hits),
        })

    result.sort(key=lambda x: (not x['isSite'], -len(x['hosts'])))
    json.dump(result, open(args.output, 'w', encoding='utf-8'),
              ensure_ascii=False, indent=1)

    if not args.quiet:
        print('%-8s %-18s %-14s %s' % ('key', 'name', 'class', 'hosts'))
        for r in result:
            mark = '' if r['isSite'] else ' [非站点]'
            print('%-8s %-18s %-14s %s%s' % (
                (r['key'] or '')[:8], (r['name'] or '')[:18],
                r['class'], ', '.join(r['hosts'])[:70] or '—', mark))
    site_count = sum(1 for r in result if r['isSite'])
    site_ok = sum(1 for r in result if r['isSite'] and r['hosts'])
    print('\n采集器类 %d 个，其中有域名 %d 个' % (len(result), covered))
    print('影视/点播类 %d 个，其中有域名 %d 个' % (site_count, site_ok))
    print('输出 ->', args.output)
    return 0


if __name__ == '__main__':
    sys.exit(main())

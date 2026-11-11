#!/usr/bin/env python3
"""用生成的 GenericSourceRule 实抓一次，验证规则是否真的能出数据。

选择器语法与 iMovie 一致：`css` 取文本，`css@attr` 取属性。
"""
import json
import sys
import urllib.parse
import urllib.request
from bs4 import BeautifulSoup

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36")


def fetch(url, timeout=25):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


def split_spec(spec):
    if spec is None:
        return None, None
    at = spec.rfind("@")
    if at < 0:
        return spec, None
    return spec[:at], spec[at + 1:]


def pick(node, spec):
    if not node or not spec:
        return ""
    sel, attr = split_spec(spec)
    try:
        el = node.select_one(sel)
    except Exception:
        return ""
    if el is None:
        return ""
    if attr:
        return (el.get(attr) or "").strip()
    return el.get_text(" ", strip=True)


def absolutize(base, href):
    if not href:
        return ""
    return urllib.parse.urljoin(base, href)


def run_list(rule, page_url):
    html = fetch(page_url)
    soup = BeautifulSoup(html, "lxml")
    items = soup.select(rule["listSelector"])
    rows = []
    for it in items:
        title = pick(it, rule.get("titleSelector"))
        if not title:
            a = it.select_one("a[title]")
            title = (a.get("title") or "").strip() if a else it.get_text(" ", strip=True)[:40]
        href = pick(it, rule.get("linkSelector"))
        if not href:
            a = it.select_one("a[href]")
            href = a.get("href") if a else ""
        rows.append({
            "title": title,
            "url": absolutize(page_url, href),
            "pic": absolutize(page_url, pick(it, rule.get("posterSelector"))),
            "note": pick(it, rule.get("noteSelector")),
        })
    return len(html), rows


def main():
    rules = {r["key"]: r for r in json.load(open("rules.json", encoding="utf-8"))}
    key = sys.argv[1] if len(sys.argv) > 1 else "Auete"
    rule = rules[key]
    print("规则：", json.dumps(rule, ensure_ascii=False))

    # 分类页：Auete 用 /Movie/index.html，Dm84 用 /list/1-1.html
    guess = {
        "Auete": "/Movie/index.html",
        "Dm84": "/list/1-1.html",
        "FirstAid": "/",
    }.get(key, "/")
    url = rule["baseURL"].rstrip("/") + guess
    print("抓取：", url)
    size, rows = run_list(rule, url)
    print(f"页面 {size} 字节，条目 {len(rows)}")
    for r in rows[:6]:
        print("  -", r["title"][:28], "|", r["note"][:12], "|", r["url"][:70])
        print("     pic:", r["pic"][:80])


if __name__ == "__main__":
    main()

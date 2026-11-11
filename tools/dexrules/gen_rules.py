#!/usr/bin/env python3
"""从 CatVod spider DEX 自动生成 iMovie 可用的 GenericSourceRule 规则包。

输入：dex-classes.json（dexstr.py 产出）
输出：rules.json

不做任何站点硬编码：站点 key 来自 Guard 类名去掉 Guard 后缀，
baseURL / 选择器 / 搜索路径全部从 DEX 的 const-string 按方法归属推断。
"""
import json
import re
import sys

HOST_RE = re.compile(r"^https?://[A-Za-z0-9.\-]+(?::\d+)?/?$")
# HTML 标签白名单：只有纯单词落在这里，才可能是选择器
TAGS = set("""a img div ul ol li span p h1 h2 h3 h4 h5 h6 table tr td th
dl dt dd form input button select option section article header footer nav
em b i strong small label video iframe script body html main aside figure""".split())
SEL_RE = re.compile(
    r"^(?:[a-zA-Z][\w-]*)?(?:[.#][\w\-]+)*(?:\[[^\]]+\])?(?:\s*>\s*[\w.#\-\[\]=\"']+)*$"
)
REGEX_RE = re.compile(r"\\[dswDSW()]|\$\d|\[\^")

# 常见列表容器 / 条目选择器特征
LIST_HINT = re.compile(r"(threadlist|item|list|vodlist|module-item|stui-vodlist|play_list|episode)", re.I)
TITLE_HINT = re.compile(r"^(h\d(\s+a)?|a\.title|\.title|a)$", re.I)
PIC_HINT = re.compile(r"img", re.I)
NOTE_HINT = re.compile(r"(tag|note|remark|desc|hdtag|badge)", re.I)


def is_selector(s):
    if not s or len(s) < 2 or len(s) > 120:
        return False
    s = s.strip()
    if HOST_RE.match(s) or REGEX_RE.search(s) or s.startswith("http"):
        return False
    # 允许后代选择器（空格分隔），但每段都必须是合法简单选择器
    parts = re.split(r"\s*>\s*|\s+", s)
    if len(parts) > 3 or any(not p for p in parts):
        return False
    for p in parts:
        if not SEL_RE.match(p):
            return False
        if not re.search(r"[.#\[]", p) and p.lower() not in TAGS:
            return False
    if len(parts) > 1:
        return True
    if re.search(r"[.#\[>]", s):
        return True
    return s.lower() in TAGS


def pick_host(strings):
    for s in strings:
        if HOST_RE.match(s):
            return s.rstrip("/")
    return ""


def pick(strings, predicate):
    for s in strings:
        if predicate(s):
            return s
    return ""


def to_selector(spec, attr=None):
    return f"{spec}@{attr}" if attr else spec


def build_site(name, info):
    methods = info.get("methods") or {}
    init = methods.get("<init>", [])
    home = methods.get("homeContent", [])
    cat = methods.get("categoryContent", [])
    det = methods.get("detailContent", [])
    sea = methods.get("searchContent", [])
    play = methods.get("playerContent", [])

    base = pick_host(init) or pick_host(home)
    if not base:
        return None

    rule = {"key": name, "name": name, "baseURL": base, "mode": "html"}

    # ---- 列表：优先 categoryContent，其次 homeContent / searchContent
    list_src = cat or home or sea
    sels = [s for s in list_src if is_selector(s)]
    list_sel = pick(sels, lambda s: bool(LIST_HINT.search(s)) and not PIC_HINT.search(s))
    if not list_sel:
        list_sel = pick(sels, lambda s: bool(LIST_HINT.search(s)))
    if list_sel:
        rule["listSelector"] = list_sel

    rest = [s for s in sels if s != list_sel]
    title = pick(rest, lambda s: bool(TITLE_HINT.match(s)))
    if title:
        rule["titleSelector"] = to_selector(title, "title" if title.lower().startswith("h") else None)
    pic = pick(rest, lambda s: bool(PIC_HINT.search(s)))
    if pic:
        rule["posterSelector"] = to_selector(pic, "data-original" if "data-" in " ".join(rest) else "src")
    note = pick(rest, lambda s: bool(NOTE_HINT.search(s)) and not PIC_HINT.search(s))
    if note:
        rule["noteSelector"] = note
    link = pick(rest, lambda s: s in ("a", "a.title", "h2 a", "h3 a"))
    rule["linkSelector"] = to_selector(link or "a", "href")

    # ---- 分类 URL 模板：categoryContent 里的 .html / 路径拼接片段
    cat_tpl = pick(cat, lambda s: ("%s" in s or "{" in s) and ("/list" in s or "-%s" in s or "index" in s))
    if cat_tpl:
        rule["categoryURL"] = cat_tpl

    # ---- 搜索
    search_path = pick(sea, lambda s: ("searchword" in s or "search" in s.lower() or "wd=" in s) and not is_selector(s))
    if search_path:
        tail = pick(sea, lambda s: s in ("&page=", "&pg=", "/page/", "&p="))
        tpl = search_path + (tail or "")
        tpl = tpl.replace("searchword=", "searchword={wd}").replace("wd=", "wd={wd}")
        if "{wd}" in tpl and ("page" in tpl or "pg=" in tpl or "p=" in tpl):
            tpl = re.sub(r"(page|pg|p)=$", r"\1={pg}", tpl)
        elif "{wd}" in tpl:
            tpl = tpl + "{pg}"
        rule["searchURL"] = tpl

    # ---- 详情
    dsels = [s for s in det if is_selector(s)]
    dtitle = pick(dsels, lambda s: bool(re.search(r"(detail-title|v_title|title)", s, re.I)) and not PIC_HINT.search(s))
    if dtitle:
        rule["detailTitleSelector"] = dtitle
    dpic = pick(dsels, lambda s: bool(PIC_HINT.search(s)))
    if dpic:
        rule["posterSelector"] = rule.get("posterSelector") or to_selector(dpic, "src")
    summary = pick(dsels, lambda s: bool(re.search(r"(detail-des|desc|content|intro|summary)", s, re.I)))
    if summary:
        rule["summarySelector"] = summary
    ep = pick(dsels, lambda s: bool(re.search(r"(episode|play_list|playlist)", s, re.I)))
    if ep:
        rule["episodeSelector"] = ep
    line = pick(dsels, lambda s: bool(re.search(r"(tab_control|card-header|play-from)", s, re.I)))
    if line:
        rule["lineSelector"] = line

    # ---- 播放页脚本特征（给 resolver 用）
    if play:
        rule["playerURL"] = ""

    return rule


def guard_names(outer_dex):
    """外层壳 DEX 的 class_defs 里就是 Guard 名单。"""
    sys.path.insert(0, ".")
    from dexstr import Dex

    d = Dex(open(outer_dex, "rb").read())
    out = []
    for cd in d.class_defs():
        n = cd["name"]
        if not n.startswith("L") or not n.endswith(";"):
            continue
        cls = n[1:-1].replace("/", ".")
        if cls.startswith("com.github.catvod.spider.") and cls.endswith("Guard"):
            short = cls[len("com.github.catvod.spider."):]
            if "." not in short and short != "BaseSpiderGuard":
                out.append(short[:-5])
    return sorted(set(out))


def main(dex_json, out, outer_dex="outer.dex"):
    data = json.load(open(dex_json, encoding="utf-8"))
    guards = guard_names(outer_dex)
    print("Guard：", len(guards), guards)

    rules, skipped = [], []
    for g in guards:
        info = data.get(f"com.github.catvod.spider.{g}")
        if not info:
            skipped.append(g)
            continue
        r = build_site(g, info)
        if r:
            rules.append(r)
        else:
            skipped.append(g)

    json.dump(rules, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"生成规则 {len(rules)} 条 -> {out}")
    ok = [r for r in rules if r.get("listSelector")]
    print(f"其中列表可用的 {len(ok)} 条：{', '.join(r['key'] for r in ok)}")
    print(f"缺 baseURL 跳过 {len(skipped)}：{skipped}")
    return rules


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "dex-classes.json",
         sys.argv[2] if len(sys.argv) > 2 else "rules.json")

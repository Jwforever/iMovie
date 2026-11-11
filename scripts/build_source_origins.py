#!/usr/bin/env python3
"""Build source-origins.json from a TVBox config plus public rule subscriptions.

The generated file contains NO compiled-in site domains: it records where each
entry URL came from, so the app can refresh it at runtime. Run this on any
machine with ordinary internet access and commit / host the output.

Usage:
  python scripts/build_source_origins.py
  python scripts/build_source_origins.py --config-file config.json --discover
  python scripts/build_source_origins.py --rule https://example/rules.json --out Resources/source-origins.json

--discover visits each entry URL, follows redirects and votes on the hostname
used by the page's absolute links. It is optional because some networks block
video sites; when it fails the entry is kept with an empty discoveredHost.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from collections import Counter
from datetime import datetime, timezone
from urllib.parse import urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from inspect_config import decode, fetch  # noqa: E402

DEFAULT_CONFIG = "http://www.饭太硬.cc/tv"
DEFAULT_RULES = [
    "https://raw.githubusercontent.com/dlgt7/TVbox-interface/main/xbiu/auete.json",
]
DEFAULT_OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Resources", "source-origins.json",
)
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"
URL_RE = re.compile(r"https?://[^\s\"'<>|,;)\]]+")
DATA_SUFFIX = (".txt", ".json", ".js", ".jar", ".m3u8", ".php", ".xml", ".yaml", ".yml")

# Lookup hint only: maps a CSP class name from the config to the entry host of
# a public rule. No site domain is baked into the app binary.
RULE_ALIASES = {
    "csp_aueteguard": "auete.com",
    "csp_auete": "auete.com",
}


def get_bytes(url: str, timeout: int = 20) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def read_json(url: str) -> dict:
    text = get_bytes(url).decode("utf-8", "replace")
    # Public TVBox rule files are sometimes JSONC.
    text = re.sub(r"^\s*//.*$", "", text, flags=re.M)
    text = re.sub(r",(\s*[}\]])", r"\1", text)
    return json.loads(text)


def ext_to_text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def first_url(text: str) -> str | None:
    for candidate in URL_RE.findall(text or ""):
        candidate = candidate.rstrip(".,;)\\")
        if urlparse(candidate).netloc:
            return candidate
    return None


def is_data_url(url: str) -> bool:
    path = urlparse(url).path.lower()
    return path.endswith(DATA_SUFFIX) or "/api/" in path or path.endswith("/api")


def host_of(url: str) -> str:
    return urlparse(url).netloc.lower()


def template_base(template: str) -> str | None:
    """Strip {placeholders} from a URL template, keeping scheme + host."""
    match = re.match(r"https?://[^/{]+", template)
    return match.group(0) + "/" if match else None


def classify(url: str) -> str:
    return "data" if is_data_url(url) else "entry"


def parse_rule(document: dict, source_url: str) -> dict:
    """Convert a public xbiu/XPath style rule into a compact app-facing shape."""
    def pick(section: str, key: str = "url") -> str | None:
        part = document.get(section)
        if isinstance(part, dict):
            value = part.get(key)
            return value if isinstance(value, str) else None
        return None

    home = document.get("homeUrl")
    entry = template_base(home) if isinstance(home, str) else None
    return {
        "ruleSource": source_url,
        "entryUrl": entry,
        "homeUrl": document.get("homeUrl"),
        "cateManual": document.get("cateManual") if isinstance(document.get("cateManual"), dict) else {},
        "listUrl": pick("list"),
        "detailUrl": pick("detail"),
        "searchUrl": pick("search"),
        "playlistUrl": pick("playlist"),
    }


def discover_host(entry: str, timeout: int = 15) -> dict:
    """Follow redirects and let the page itself report its current main host."""
    result = {"finalUrl": None, "votedHost": None, "error": None}
    try:
        request = urllib.request.Request(entry, headers={"User-Agent": UA})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            final = response.geturl()
            html = response.read(2_000_000).decode("utf-8", "replace")
        result["finalUrl"] = final
        hosts = [h.lower() for h in re.findall(r"https?://([A-Za-z0-9.-]+)", html)]
        internal = [h for h in hosts if not h.startswith(("cdn.", "img.", "static.", "statics."))]
        if internal:
            result["votedHost"] = Counter(internal).most_common(1)[0][0]
    except Exception as error:  # network policy / TLS / WAF are expected on some hosts
        result["error"] = f"{type(error).__name__}: {error}"[:200]
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="TVBox config URL")
    parser.add_argument("--config-file", help="Use an already downloaded config JSON instead")
    parser.add_argument("--rule", action="append", default=None, help="Public rule JSON URL (repeatable)")
    parser.add_argument("--out", default=DEFAULT_OUT, help="Output path")
    parser.add_argument("--discover", action="store_true", help="Visit entry URLs to find the live host")
    args = parser.parse_args()

    if args.config_file:
        with open(args.config_file, encoding="utf-8") as handle:
            config = json.load(handle)
        config_from = "file:" + os.path.basename(args.config_file)
    else:
        body, _meta = fetch(args.config)
        config, _encoding = decode(body)
        config_from = args.config

    rules = []
    for url in (args.rule or DEFAULT_RULES):
        try:
            rules.append(parse_rule(read_json(url), url))
        except Exception as error:
            print(f"  ! rule failed {url}: {type(error).__name__}: {error}", file=sys.stderr)

    # Index rules by entry host so a config entry can be enriched later.
    by_host = {}
    for rule in rules:
        if rule.get("entryUrl"):
            by_host[host_of(rule["entryUrl"])] = rule

    sources = []
    for site in config.get("sites", []):
        api = str(site.get("api", ""))
        ext = ext_to_text(site.get("ext"))
        url = first_url(ext) or (first_url(api) if api.startswith("http") else None)
        item = {
            "key": site.get("key"),
            "name": site.get("name"),
            "api": api,
            "kind": classify(url) if url else "unknown",
            "configUrl": url,
            "origin": "config.ext" if first_url(ext) else ("config.api" if url else None),
            "rule": None,
            "discoveredHost": None,
        }
        if url and host_of(url) in by_host:
            item["rule"] = by_host[host_of(url)]
        alias_host = RULE_ALIASES.get(api.lower())
        if not item["rule"] and alias_host:
            for host, rule in by_host.items():
                if host == alias_host or host.endswith("." + alias_host):
                    item["rule"] = rule
                    item["configUrl"] = rule.get("entryUrl")
                    item["kind"] = "entry"
                    item["origin"] = "subscription"
                    break
        sources.append(item)

    # Attach rule-only entries (e.g. Auete discovered from a public rule repo).
    attached = {host_of(s["configUrl"]) for s in sources if s.get("configUrl")}
    for rule in rules:
        if not rule.get("entryUrl") or host_of(rule["entryUrl"]) in attached:
            continue
        sources.append({
            "key": "rule:" + host_of(rule["entryUrl"]),
            "name": host_of(rule["entryUrl"]),
            "api": None,
            "kind": "entry",
            "configUrl": rule["entryUrl"],
            "origin": "subscription",
            "rule": rule,
            "discoveredHost": None,
        })

    if args.discover:
        for item in sources:
            if item["kind"] != "entry" or not item.get("configUrl"):
                continue
            outcome = discover_host(item["configUrl"])
            item["discoveredHost"] = outcome["votedHost"] or (host_of(outcome["finalUrl"]) if outcome["finalUrl"] else None)
            item["discovery"] = outcome
            print(f"  {item['key']}: {item['discoveredHost'] or outcome['error']}")

    document = {
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "configFrom": config_from,
        "subscriptions": [rule["ruleSource"] for rule in rules],
        "note": "Site addresses are data, not code. Refresh this file or let the app fetch subscriptions at runtime; no IPA rebuild is needed when a site changes host.",
        "sources": sources,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(document, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    counts = Counter(s["kind"] for s in sources)
    print(f"wrote {args.out}: {len(sources)} sources "
          f"(entry={counts['entry']}, data={counts['data']}, unknown={counts['unknown']}), "
          f"{len(rules)} rules")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

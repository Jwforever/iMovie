"""Reproduce a public source's category/search/media probe without Android or a custom server."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path

from inspect_config import decode, fetch as fetch_config

ORIGIN = "https://www.tuxiaobei.com"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 Version/16.0 Mobile/15E148 Safari/604.1",
    "Referer": ORIGIN + "/",
}


def fetch(url: str, *, limit: int = 2 * 1024 * 1024, media_range: bool = False) -> tuple[bytes, dict]:
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ValueError("Expected an HTTP/HTTPS URL.")
    headers = dict(HEADERS)
    if media_range:
        headers["Range"] = f"bytes=0-{limit - 1}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=20) as response:
        data = response.read(limit if media_range else limit + 1)
        if not media_range and len(data) > limit:
            raise ValueError("Source response exceeded the size limit.")
        return data, {
            "status": response.status,
            "content_type": response.headers.get("Content-Type"),
            "content_range": response.headers.get("Content-Range"),
            "bytes_read": len(data),
        }


def jsonp_object(data: bytes) -> dict:
    text = data.decode("utf-8-sig").strip()
    if text.startswith("{"):
        result = json.loads(text)
    else:
        first, last = text.find("{"), text.rfind("}")
        if first < 0 or last <= first:
            raise ValueError("Expected JSON or JSONP.")
        if not re.fullmatch(r"\s*(?:[$A-Za-z_][$\w.]*)?\s*\(\s*", text[:first]) or not re.fullmatch(r"\s*\)\s*;?\s*", text[last + 1 :]):
            raise ValueError("Unknown JSONP envelope.")
        result = json.loads(text[first : last + 1])
    if not isinstance(result, dict):
        raise ValueError("Expected a JSON object.")
    return result


class PublicPageParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.media_url: str | None = None
        self.play_ids: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "mip-search-video":
            self.media_url = attributes.get("video-src")
        if tag == "a":
            match = re.fullmatch(r"/play/(\d+)", attributes.get("href") or "")
            if match and match[1] not in self.play_ids:
                self.play_ids.append(match[1])


def probe(config_url: str) -> dict:
    raw, config_metadata = fetch_config(config_url)
    config, _ = decode(raw)
    source = next((site for site in config.get("sites", []) if "兔小贝.js" in urllib.parse.unquote(str(site.get("ext", "")))), None)
    if not source:
        raise ValueError("The supplied config no longer contains the expected public source.")
    body, category_metadata = fetch(ORIGIN + "/list/mip-data?typeId=2&page=1&callback=")
    content = jsonp_object(body)
    if content.get("status") != 0:
        raise ValueError("The category API did not report success.")
    items = content.get("data", {}).get("items", [])
    if not items:
        raise ValueError("The category API returned no items.")
    item = items[0]
    video_id = str(item["video_id"])
    if not video_id.isdecimal():
        raise ValueError("Invalid public source ID.")
    search_body, search_metadata = fetch(ORIGIN + "/search/index?" + urllib.parse.urlencode({"key": "小星星"}))
    search_parser = PublicPageParser()
    search_parser.feed(search_body.decode("utf-8-sig"))
    page_body, page_metadata = fetch(ORIGIN + "/play/" + video_id)
    detail = PublicPageParser()
    detail.feed(page_body.decode("utf-8-sig"))
    if not detail.media_url:
        raise ValueError("The page did not expose a public media URL.")
    sample, media_metadata = fetch(detail.media_url, limit=1024, media_range=True)
    valid_media = len(sample) >= 12 and sample[4:8] == b"ftyp"
    if not valid_media:
        raise ValueError("The public media URL did not return an ISO BMFF signature.")
    return {
        "checked_at": datetime.now(timezone(timedelta(hours=8))).isoformat(timespec="seconds"),
        "config": {"url": config_url, "status": config_metadata["status"]},
        "source": {"key": source.get("key"), "name": source.get("name"), "adapter": "tuxiaobei", "website": ORIGIN},
        "environment": {"used_android": False, "used_custom_server": False, "ran_ios_app": False, "ran_original_drpy": False},
        "category": {**category_metadata, "items": len(items), "sample_id": video_id, "sample_title": item.get("name")},
        "search": {**search_metadata, "query": "小星星", "unique_result_count": len(search_parser.play_ids)},
        "detail": {**page_metadata, "public_media_extracted": True},
        "media_probe": {**media_metadata, "host": urllib.parse.urlsplit(detail.media_url).hostname, "iso_bmff_ftyp": valid_media, "first_1k_sha256": hashlib.sha256(sample).hexdigest(), "full_video_downloaded": False},
        "limits": ["This probes the public site's HTTP path using an iPhone User-Agent; it does not run Swift or iOS.", "A readable MP4 prefix does not verify full video playback, seeking, audio or codec compatibility.", "The source is a feasibility sample; it does not demonstrate the 45 Android spiders or a complete drpy engine."],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="http://www.饭太硬.cc/tv")
    parser.add_argument("--output", type=Path, default=Path("docs/native-source-probe.json"))
    args = parser.parse_args()
    result = probe(args.config)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=True, indent=2))


if __name__ == "__main__":
    main()

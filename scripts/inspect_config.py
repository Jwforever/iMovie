"""Read-only inspection for TVBox JSONC / image**base64 configurations. No spider execution."""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import struct
import urllib.parse
import urllib.request
import zipfile
from collections import Counter
from datetime import datetime, timezone, timedelta
from pathlib import Path

MAX_BYTES = 12 * 1024 * 1024
DEFAULT_URL = "http://www.饭太硬.cc/tv"


def ascii_url(value: str) -> str:
    parts = urllib.parse.urlsplit(value)
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.username or parts.password:
        raise ValueError("Expected an HTTP/HTTPS URL without credentials.")
    host = parts.hostname.encode("idna").decode("ascii")
    if ":" in host:
        host = "[" + host + "]"
    if parts.port:
        host += ":" + str(parts.port)
    path = urllib.parse.quote(parts.path, safe="/%:@-._~!$&'()*+,;=")
    query = urllib.parse.quote(parts.query, safe="%=&+/:?@-._~!$'()*,;")
    return urllib.parse.urlunsplit((parts.scheme, host, path, query, ""))


def fetch(value: str) -> tuple[bytes, dict]:
    request = urllib.request.Request(ascii_url(value), headers={"User-Agent": "okhttp/4.12.0", "Accept": "*/*"})
    with urllib.request.urlopen(request, timeout=25) as response:
        body = response.read(MAX_BYTES + 1)
        if len(body) > MAX_BYTES:
            raise ValueError("Response exceeded 12 MB.")
        return body, {"url": response.url, "status": response.status, "content_type": response.headers.get("Content-Type"), "bytes": len(body)}


def strip_comments(text: str) -> str:
    text = text.lstrip("\ufeff")
    output: list[str] = []
    index, quoted, escaped = 0, False, False
    while index < len(text):
        char = text[index]
        pair = text[index : index + 2]
        if quoted:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
            index += 1
        elif char == '"':
            output.append(char)
            quoted = True
            index += 1
        elif pair == "//":
            index += 2
            while index < len(text) and text[index] not in "\r\n":
                index += 1
            output.append(" ")
        elif pair == "/*":
            index += 2
            while index + 1 < len(text) and text[index : index + 2] != "*/":
                if text[index] in "\r\n":
                    output.append(text[index])
                index += 1
            index = min(index + 2, len(text))
            output.append(" ")
        else:
            output.append(char)
            index += 1
    return "".join(output)


def strip_trailing_commas(text: str) -> str:
    output: list[str] = []
    quoted, escaped = False, False
    for index, char in enumerate(text):
        if quoted:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
            output.append(char)
        elif char == ",":
            cursor = index + 1
            while cursor < len(text) and text[cursor].isspace():
                cursor += 1
            if cursor >= len(text) or text[cursor] not in "]}":
                output.append(char)
        else:
            output.append(char)
    return "".join(output)


def decode(body: bytes) -> tuple[dict, str]:
    def jsonc(payload: bytes) -> dict:
        root = json.loads(strip_trailing_commas(strip_comments(payload.decode("utf-8-sig"))))
        if not isinstance(root, dict):
            raise ValueError("The root must be a JSON object.")
        return root

    try:
        return jsonc(body), "JSON/JSONC"
    except (ValueError, UnicodeError):
        pass
    candidates = [(body, "Base64")]
    offset = 0
    for _ in range(64):
        index = body.find(b"**", offset)
        if index < 0:
            break
        candidates.append((body[index + 2 :], "image**Base64"))
        offset = index + 2
    for candidate, encoding in candidates:
        try:
            compact = b"".join(candidate.split())
            decoded = base64.b64decode(compact + b"=" * (-len(compact) % 4), validate=True)
            return jsonc(decoded), encoding
        except (ValueError, UnicodeError):
            continue
    raise ValueError("Unsupported configuration envelope.")


def runtime(site: dict) -> str:
    api = str(site.get("api", ""))
    if api.lower().startswith("csp_"):
        return "android"
    if urllib.parse.urlsplit(api).path.lower().endswith(".js"):
        return "javascript"
    if str(site.get("type")) in ("1", "4") and urllib.parse.urlsplit(api).scheme in ("http", "https"):
        return "json_api"
    return "unsupported"


def inspect_spider(spec: str) -> dict:
    parts = spec.split(";")
    body, metadata = fetch(parts[0])
    digest = hashlib.md5(body).hexdigest()
    metadata["md5"] = digest
    if len(parts) >= 3 and parts[1].lower() == "md5":
        metadata["expected_md5"] = parts[2].lower()
        metadata["md5_matches"] = digest == parts[2].lower()
    with zipfile.ZipFile(io.BytesIO(body)) as archive:
        metadata["entries"] = archive.namelist()
        metadata["has_dex"] = any(name.endswith(".dex") for name in archive.namelist())
        if "classes.dex" in archive.namelist() and archive.getinfo("classes.dex").file_size <= MAX_BYTES:
            dex = archive.read("classes.dex")
            references = []
            if dex.startswith(b"dex\n") and len(dex) >= 112:
                count, string_table = struct.unpack_from("<II", dex, 56)
                if count <= 100000 and string_table + count * 4 <= len(dex):
                    for index in range(count):
                        offset = struct.unpack_from("<I", dex, string_table + index * 4)[0]
                        steps = 0
                        while offset < len(dex) and dex[offset] >= 128 and steps < 5:
                            offset += 1
                            steps += 1
                        if offset >= len(dex):
                            continue
                        offset += 1
                        end = dex.find(b"\0", offset)
                        if end < 0 or end - offset > 2048:
                            continue
                        value = dex[offset:end].decode("utf-8", errors="replace")
                        if value.startswith(("Landroid/", "Ldalvik/")):
                            references.append(value)
            metadata["android_runtime_references"] = sorted(set(references))[:80]
        libraries = []
        for entry in archive.infolist():
            if entry.filename.endswith(".so") and entry.file_size <= MAX_BYTES:
                with archive.open(entry) as stream:
                    header = stream.read(24)
                if header.startswith(b"\x7fELF"):
                    endian = "<" if header[5] == 1 else ">"
                    machine = struct.unpack(endian + "H", header[18:20])[0]
                    libraries.append({"entry": entry.filename, "format": "ELF", "bits": {1: 32, 2: 64}.get(header[4]), "architecture": {40: "ARM", 183: "AArch64"}.get(machine, str(machine))})
        metadata["native_libraries"] = libraries
    return metadata


def inspect(url: str, include_spider: bool = False) -> dict:
    body, metadata = fetch(url)
    config, encoding = decode(body)
    sites = config.get("sites", [])
    lives = config.get("lives", [])
    result = {
        "checked_at": datetime.now(timezone(timedelta(hours=8))).isoformat(timespec="seconds"),
        "source": url,
        "response": metadata,
        "encoding": encoding,
        "site_count": len(sites),
        "runtime_counts": dict(Counter(runtime(site) for site in sites)),
        "live_source_count": len(lives),
        "sites": [{"key": site.get("key"), "name": site.get("name"), "type": site.get("type"), "api": site.get("api"), "runtime": runtime(site)} for site in sites],
        "lives": [{"name": live.get("name"), "url": live.get("url"), "android_loopback_proxy": urllib.parse.urlsplit(str(live.get("url", ""))).hostname in ("127.0.0.1", "localhost", "::1")} for live in lives],
        "limits": ["Configuration decoding does not execute spiders or verify media playback.", "DEX/JAR and Android ELF libraries do not run directly on iOS.", "drpy scripts require a compatible host engine, not just a JavaScript evaluator."],
    }
    if include_spider and config.get("spider"):
        try:
            result["spider"] = inspect_spider(config["spider"])
        except Exception as exc:
            result["spider"] = {"error": str(exc)}
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", nargs="?", default=DEFAULT_URL)
    parser.add_argument("--spider", action="store_true", help="Inspect archive headers only; never execute the spider.")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = inspect(args.url, args.spider)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key not in ("sites", "lives")}, ensure_ascii=True, indent=2))


if __name__ == "__main__":
    main()

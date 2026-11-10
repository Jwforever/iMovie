"""Read-only HTTPS diagnostics on the macOS build host; never bypasses TLS validation."""
import concurrent.futures
import json
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

addresses = ["https://www.libvio.pw/", "https://libvio.app/", "https://www.4kcz.com/", "https://www.auete.com/"]


def probe(address):
    try:
        request = urllib.request.Request(address, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(request, timeout=12) as response:
            data = response.read(1024 * 1024)
            return {"address": address, "status": response.status, "final": response.url, "bytesRead": len(data), "hasHTML": b"<html" in data.lower()}
    except Exception as error:
        return {"address": address, "error": str(error)}


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    report = {"checkedAt": datetime.now(timezone.utc).isoformat(), "host": "macOS CI", "sources": list(pool.map(probe, addresses))}
path = Path("dist/additional-source-probe.json")
path.parent.mkdir(exist_ok=True)
path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(report, ensure_ascii=True))

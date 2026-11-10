"""Local deterministic media fixture for iOS Simulator smoke tests."""
from __future__ import annotations

import argparse
import base64
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def handler(media: bytes):
    class FixtureHandler(BaseHTTPRequestHandler):
        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            parsed = urlparse(self.path)
            query = parse_qs(parsed.query)
            origin = "http://" + self.headers.get("Host", "127.0.0.1:8765")
            if parsed.path == "/sample.mp4":
                start, end = 0, len(media) - 1
                match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
                if match:
                    start = int(match[1])
                    end = min(int(match[2]) if match[2] else end, end)
                if start > end:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{len(media)}")
                    self.end_headers()
                    return
                self.send_response(206 if match else 200)
                self.send_header("Accept-Ranges", "bytes")
                if match:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{len(media)}")
                body = media[start:end + 1]
                content_type = "video/mp4"
            elif parsed.path == "/tv":
                config = {"sites": [{"key": "fixture", "name": "演示片库", "type": 1, "api": origin + "/api"}],
                          "lives": [{"name": "演示直播", "url": origin + "/live.m3u"}]}
                body = b"\xff\xd8\xffimovie**" + base64.b64encode(json.dumps(config, ensure_ascii=False).encode("utf-8"))
                content_type = "application/octet-stream"
                self.send_response(200)
            elif parsed.path == "/api":
                video = {"vod_id": "1", "vod_name": "播放验证样片", "vod_pic": "", "vod_remarks": "本地生成 · 测试视频",
                         "vod_content": "这是自动化测试生成的色彩动画，用于验证选集、播放器、收藏和记录。",
                         "vod_play_from": "本机播放", "vod_play_url": "第 1 集$" + origin + "/sample.mp4#第 2 集$" + origin + "/sample.mp4?episode=2"}
                payload = {"class": [{"type_id": "1", "type_name": "测试分类"}], "list": [video], "page": 1, "pagecount": 1}
                body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
                content_type = "application/json; charset=utf-8"
                self.send_response(200)
            elif parsed.path == "/live.m3u":
                body = ("#EXTM3U\n#EXTINF:-1 group-title=\"演示\",测试频道\n" + origin + "/sample.mp4\n").encode("utf-8")
                content_type = "application/vnd.apple.mpegurl"
                self.send_response(200)
            elif parsed.path == "/web":
                body = ("<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>"
                        "<title>网页播放验证</title></head><body style='background:#071210;color:#cff5df;font:18px system-ui;padding:20px'>"
                        "<h2>网页播放验证</h2><p>本地测试视频</p><video controls playsinline preload='metadata' style='width:100%' src='/sample.mp4'></video>"
                        "</body></html>").encode("utf-8")
                content_type = "text/html; charset=utf-8"
                self.send_response(200)
            else:
                self.send_error(404)
                return
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def log_message(self, format, *args):
            pass

    return FixtureHandler


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("media", type=Path)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), handler(args.media.read_bytes())).serve_forever()

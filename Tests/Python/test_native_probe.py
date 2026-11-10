import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("probe_native_source", ROOT / "scripts/probe_native_source.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class NativeProbeTests(unittest.TestCase):
    def test_accepts_plain_and_jsonp_but_not_appended_code(self):
        for body in (b'{"status":0}', b'({"status":0});', b'callback_1({"status":0})'):
            self.assertEqual(probe.jsonp_object(body), {"status": 0})
        for body in (b'<html>{"status":0}</html>', b'callback({"status":0}); alert(1);', b'[]'):
            with self.subTest(body=body), self.assertRaises(ValueError):
                probe.jsonp_object(body)

    def test_page_parser_decodes_entities_and_deduplicates_search_links(self):
        parser = probe.PublicPageParser()
        parser.feed('<a href="/play/123">picture</a><a href="/play/123">title</a><a href="/play/456">next</a><mip-search-video id="videoWrap" video-src="https://example.test/a.mp4?x=1&amp;y=2">')
        self.assertEqual(parser.play_ids, ["123", "456"])
        self.assertEqual(parser.media_url, "https://example.test/a.mp4?x=1&y=2")


if __name__ == "__main__":
    unittest.main()

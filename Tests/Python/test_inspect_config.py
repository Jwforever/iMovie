import base64
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("inspect_config", ROOT / "scripts" / "inspect_config.py")
inspector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspector)


class ConfigInspectionTests(unittest.TestCase):
    def test_real_format_and_runtime_classification(self):
        payload = r'''{
            // a comment
            "sites":[
              {"key":"a","api":"csp_Guard","type":3},
              {"key":"b","api":"https://example.test/a.js","type":3},
              {"key":"c","api":"https://example.test/api?url=a//b","type":"4"},
            ],
            "note":"escaped \" // not a comment /* either */",
        }'''
        body = b"\xff\xd8\x00\xffJPEG**" + base64.b64encode(payload.encode())
        result, encoding = inspector.decode(body)
        self.assertEqual(encoding, "image**Base64")
        self.assertEqual(result["sites"][2]["api"], "https://example.test/api?url=a//b")
        self.assertEqual([inspector.runtime(site) for site in result["sites"]], ["android", "javascript", "json_api"])
        self.assertIn('// not a comment', result["note"])

    def test_bom_plain_and_unpadded_base64(self):
        text = json.dumps({"sites": [], "name": "饭太硬"}, ensure_ascii=False).encode()
        result, encoding = inspector.decode(b"\xef\xbb\xbf" + text)
        self.assertEqual(encoding, "JSON/JSONC")
        self.assertEqual(result["name"], "饭太硬")
        self.assertEqual(inspector.decode(base64.b64encode(text).rstrip(b"="))[0], result)

    def test_rejects_unknown_envelope(self):
        for body in (b"", b"<html>error</html>", b"\xff\xd8\x00\xff**this is not json"):
            with self.subTest(body=body), self.assertRaises(ValueError):
                inspector.decode(body)

    def test_domain_normalization_and_credentials(self):
        self.assertEqual(inspector.ascii_url("http://www.饭太硬.cc/tv"), "http://www.xn--sss604efuw.cc/tv")
        self.assertEqual(inspector.ascii_url("https://example.test/直播?a=中文"), "https://example.test/%E7%9B%B4%E6%92%AD?a=%E4%B8%AD%E6%96%87")
        for value in ("file:///etc/passwd", "https://user:pass@example.test/", "javascript:alert(1)"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                inspector.ascii_url(value)


if __name__ == "__main__":
    unittest.main()

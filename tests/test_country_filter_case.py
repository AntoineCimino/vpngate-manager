import base64
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT_ROOT / "vpngate-manager.sh"

CONFIG = base64.b64encode(b"client\nremote vpn.example 1194\n").decode("ascii")
ROWS = [
    ("jp-host", "1.1.1.1", "Japan", "JP"),
    ("kr-host", "2.2.2.2", "Korea Republic of", "KR"),
]


def run_exec(filter_country):
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        home = root / "home"
        home.mkdir()
        body = "".join(
            f"{n},{ip},100,10,1000000,{cl},{cs},2,x,{CONFIG}\\n" for n, ip, cl, cs in ROWS
        )
        curl = fake_bin / "curl"
        curl.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\nfrom pathlib import Path\n"
            "a = sys.argv[1:]\n"
            "out = Path(a[a.index('-o') + 1])\n"
            f"out.write_text('header one\\nheader two\\n' + '{body}')\n",
            encoding="utf-8",
        )
        curl.chmod(0o755)
        for name, content in (
            ("vopono", "#!/bin/sh\nexit 0\n"),
            ("sudo", "#!/bin/sh\nexit 0\n"),
        ):
            f = fake_bin / name
            f.write_text(content, encoding="utf-8")
            f.chmod(0o755)
        env = os.environ.copy()
        env.update(
            HOME=str(home),
            XDG_DATA_HOME=str(root / "data"),
            PATH=f"{fake_bin}:{env['PATH']}",
        )
        return subprocess.run(
            ["bash", str(SCRIPT), "exec", filter_country, "--", "true"],
            check=False, capture_output=True, text=True, env=env,
        )


class CountryFilterCaseTests(unittest.TestCase):
    def assert_match(self, flt, prefix):
        r = run_exec(flt)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"Using: {prefix}-vpngate_", r.stdout)

    def test_japan_variants(self):
        for flt in ("japan", "Japan", "JAPAN", "JP", "jp"):
            with self.subTest(flt=flt):
                self.assert_match(flt, "JP")

    def test_korea_lowercase(self):
        self.assert_match("korea", "KR")

    def test_no_match(self):
        r = run_exec("narnia")
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("Using:", r.stdout)


if __name__ == "__main__":
    unittest.main()

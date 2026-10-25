import base64
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT_ROOT / "vpngate-manager.sh"
CONFIG = base64.b64encode(b"client\nremote vpn.example 1194\n").decode("ascii")


def csv(ip):
    return f"*vpn_servers\n#HostName\nh,{ip},100,10,1000000,Japan,JP,2,x,{CONFIG}\n"


OLD = csv("1.1.1.1")
NEW = csv("9.9.9.9")
STALE = 7 * 24 * 3600


def run_case(mode, cache, age=0):
    """Run get_vpn_list with a fake curl (modes: ok/fail/empty/garbage)."""
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        data = root / "data" / "vpngate-manager"
        data.mkdir(parents=True)
        cache_file = data / ".vpngate_cache.csv"
        if cache is not None:
            cache_file.write_text(cache)
            t = time.time() - age
            os.utime(cache_file, (t, t))
        fake_bin = root / "bin"
        fake_bin.mkdir()
        curl = fake_bin / "curl"
        curl.write_text(
            "#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\n"
            "a = sys.argv[1:]\nout = Path(a[a.index('-o') + 1])\n"
            f"mode = {mode!r}\n"
            "if mode == 'fail':\n    sys.exit(28)\n"
            "if mode == 'empty':\n    out.write_text('')\n    sys.exit(0)\n"
            "if mode == 'garbage':\n    out.write_text('<html>\\nbusy\\nretry\\n')\n    sys.exit(0)\n"
            f"out.write_text({NEW!r})\n",
            encoding="utf-8",
        )
        curl.chmod(0o755)
        env = os.environ.copy()
        env.update(HOME=str(root), XDG_DATA_HOME=str(root / "data"),
                   PATH=f"{fake_bin}:{env['PATH']}")
        # Load the functions only: drop the trailing `case "${1:-help}"` dispatch.
        cmd = f'eval "$(sed \'/^case "\\${{1:-help}}" in/,$d\' "{SCRIPT}")"; get_vpn_list'
        r = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, env=env)
        content = cache_file.read_text() if cache_file.exists() else None
        leftovers = [p.name for p in data.iterdir()
                     if p.name.startswith(".vpngate_cache.") and p.name != ".vpngate_cache.csv"]
        return r, content, leftovers


class DownloadFallbackTests(unittest.TestCase):
    def test_failure_with_stale_cache_uses_it_with_warning(self):
        r, content, left = run_case("fail", OLD, STALE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("WARNING", r.stderr)
        self.assertIn("stale cache", r.stderr)
        self.assertEqual(content, OLD)
        self.assertEqual(left, [])

    def test_failure_without_cache_errors(self):
        r, content, left = run_case("fail", None)
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(content)
        self.assertEqual(left, [])

    def test_empty_download_preserves_cache(self):
        r, content, left = run_case("empty", OLD, STALE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(content, OLD)
        self.assertEqual(left, [])

    def test_garbage_download_preserves_cache(self):
        r, content, _ = run_case("garbage", OLD, STALE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(content, OLD)

    def test_garbage_without_cache_errors(self):
        r, content, _ = run_case("garbage", None)
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(content)

    def test_success_replaces_cache(self):
        r, content, left = run_case("ok", OLD, STALE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(content, NEW)
        self.assertEqual(left, [])

    def test_fresh_cache_skips_download(self):
        r, content, _ = run_case("fail", OLD, 10)
        self.assertEqual(r.returncode, 0)
        self.assertNotIn("WARNING", r.stderr)
        self.assertEqual(content, OLD)


if __name__ == "__main__":
    unittest.main()

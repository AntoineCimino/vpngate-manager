import base64
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT_ROOT / "vpngate-manager.sh"


class ResolveVpnConfigStdoutTests(unittest.TestCase):
    def test_forced_refresh_keeps_diagnostics_off_resolved_path_stdout(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            home = root / "home"
            home.mkdir()
            capture_path = root / "sudo-args.json"
            config = base64.b64encode(b"client\nremote vpn.example 1194\n").decode("ascii")

            curl = fake_bin / "curl"
            curl.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "from pathlib import Path\n"
                "args = sys.argv[1:]\n"
                "output = Path(args[args.index('-o') + 1])\n"
                f"encoded = {config!r}\n"
                "output.write_text('header one\\nheader two\\nhost,1.2.3.4,100,10,1000000,Japan,JP,2,x,' + encoded + '\\n')\n",
                encoding="utf-8",
            )
            curl.chmod(0o755)

            vopono = fake_bin / "vopono"
            vopono.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            vopono.chmod(0o755)

            sudo = fake_bin / "sudo"
            sudo.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "with open(os.environ['SUDO_CAPTURE_FILE'], 'w', encoding='utf-8') as f:\n"
                "    json.dump(sys.argv[1:], f)\n",
                encoding="utf-8",
            )
            sudo.chmod(0o755)

            env = os.environ.copy()
            env.update(
                HOME=str(home),
                XDG_DATA_HOME=str(root / "data"),
                PATH=f"{fake_bin}:{env['PATH']}",
                SUDO_CAPTURE_FILE=str(capture_path),
            )
            result = subprocess.run(
                ["bash", str(SCRIPT), "exec", "Japan", "--", "true"],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            expected_config = root / "data" / "vpngate-manager" / "JP-vpngate_1.2.3.4_udp.ovpn"
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Downloading the list", result.stderr)
            self.assertIn("VPN list downloaded successfully", result.stderr)
            self.assertNotIn("Downloading the list", result.stdout)
            self.assertNotIn("VPN list downloaded successfully", result.stdout)
            self.assertIn(f"Using: {expected_config.name}", result.stdout)

            sudo_args = json.loads(capture_path.read_text(encoding="utf-8"))
            custom_index = sudo_args.index("--custom")
            self.assertEqual(sudo_args[custom_index + 1], str(expected_config))
            self.assertTrue(expected_config.is_file())


if __name__ == "__main__":
    unittest.main()

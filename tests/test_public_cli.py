"""CLI contracts without changing host connectivity or contacting VPNGate."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'vpngate-manager.sh'


class PublicCLITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name) / 'custom-data'
        self.env = dict(os.environ, VPNGATE_DATA_DIR=str(self.data))

    def run_cli(self, *args):
        return subprocess.run(['bash', str(SCRIPT), *args], env=self.env,
                              input='', text=True, capture_output=True, timeout=5)

    def functions(self, command):
        # Same function-loading contract as the existing regression suite.
        source = SCRIPT.read_text().split('case "${1:-help}" in')[0]
        return subprocess.run(['bash', '-c', source + '\n' + command],
                              env=self.env, input='', text=True,
                              capture_output=True, timeout=5)

    def test_data_directory_override(self):
        result = self.functions('printf "%s" "$DATA_DIR"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(self.data))

    def test_relative_data_directory_rejected(self):
        self.env['VPNGATE_DATA_DIR'] = 'relative'
        self.assertNotEqual(self.run_cli('help').returncode, 0)

    def test_auto_start_resolves_without_prompt(self):
        result = self.functions('''
resolve_ovpn_for_exec() { printf '%s\\n' /tmp/test.ovpn; }
start_vpn() { printf 'START:%s:%s\\n' "$1" "$2"; }
start_command --auto japan
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('START:/tmp/test.ovpn:daemon', result.stdout)

    def test_local_file_option_without_prompt(self):
        config = Path(self.tmp.name) / 'local config.ovpn'
        config.write_text('client\n')
        result = self.functions(f'''
start_vpn() {{ printf 'START:%s:%s\\n' "$1" "$2"; }}
local_command --file '{config}' -f
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'START:{config}:foreground', result.stdout)

    def test_unknown_start_option_fails(self):
        self.assertNotEqual(self.run_cli('start', '--typo').returncode, 0)

    def test_purge_removes_artifacts_preserves_unrelated_files(self):
        self.data.mkdir()
        for name in ('.vpngate_cache.csv', 'vpn.log', 'JP-vpngate_1.2.3.4_udp.ovpn'):
            (self.data / name).write_text('fixture')
        (self.data / 'personal.txt').write_text('keep')
        result = self.run_cli('purge')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([p.name for p in self.data.iterdir()], ['personal.txt'])

    def test_purge_refuses_pending_state(self):
        self.data.mkdir()
        (self.data / '.active_mode').write_text('tor')
        (self.data / 'vpn.log').write_text('keep')
        result = self.run_cli('purge')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.data / 'vpn.log').exists())

    def test_purge_refuses_namespace_state(self):
        (self.data / 'netns' / 'test').mkdir(parents=True)
        result = self.run_cli('purge')
        self.assertNotEqual(result.returncode, 0)

    def test_purge_refuses_dns_restore_state(self):
        self.data.mkdir()
        (self.data / 'cloudflare-dns.json').write_text('{}')
        self.assertNotEqual(self.run_cli('purge').returncode, 0)


if __name__ == '__main__':
    unittest.main()

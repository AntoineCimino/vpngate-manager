"""Tor lifecycle rollback contracts, with no host settings changes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'vpngate-manager.sh').read_text().split('case "${1:-help}" in')[0]


class TorLifecycleTests(unittest.TestCase):
    def run_shell(self, body):
        with tempfile.TemporaryDirectory() as temp:
            env = dict(os.environ, VPNGATE_DATA_DIR=temp)
            return subprocess.run(['bash', '-c', SOURCE + '\n' + body], env=env,
                                  text=True, capture_output=True, timeout=8)

    def test_ipv6_exact_restore(self):
        result = self.run_shell(r'''
sysctl() {
 key="${2//\//_}"
 if [ -f "$DATA_DIR/$key" ]; then cat "$DATA_DIR/$key";
 else case "$2" in *all*) echo 1;; *default*) echo 0;; *lo*) echo 1;; *) echo 0;; esac; fi
}
sudo() {
 echo "$*" >> "$DATA_DIR/operations"
 key="${3%=*}"; key="${key//\//_}"
 printf '%s' "${3#*=}" > "$DATA_DIR/$key"
}
tor_save_ipv6 || exit 1
tor_restore_ipv6 || exit 2
grep -q 'all/disable_ipv6=1' "$DATA_DIR/operations"
grep -q 'default/disable_ipv6=0' "$DATA_DIR/operations"
grep -q 'lo/disable_ipv6=1' "$DATA_DIR/operations"
test ! -e "$DATA_DIR/tor-ipv6.state"
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_success_exit_with_unchanged_sysctl_fails_closed(self):
        result = self.run_shell(r'''
sysctl() { echo 0; }
sudo() { return 0; }
if tor_save_ipv6; then exit 2; fi
test -s "$DATA_DIR/tor-ipv6.state"
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failed_restore_retains_recovery(self):
        result = self.run_shell(r'''
printf 'all 0\ndefault 1\nlo 0\n' > "$DATA_DIR/tor-ipv6.state"
sudo() { return 1; }
if tor_restore_ipv6; then exit 2; fi
test -s "$DATA_DIR/tor-ipv6.state"
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_transparent_verification_requires_actual_tor_response(self):
        for response, code in [('{"IsTor": true,"IP":"192.0.2.1"}', 0),
                               ('{"IsTor": false}', 1), ('bad json', 1)]:
            with self.subTest(response=response):
                result = self.run_shell(f"curl() {{ printf '%s' '{response}'; }}\nverify_tor_transparent")
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)

    def test_partial_iptables_failure_reported(self):
        result = self.run_shell(r'''
ps() { echo debian-tor; }
id() { if [ "$2" = debian-tor ]; then echo 123; else echo 1000; fi; }
sudo() {
 case "$*" in *' -L '*) return 1;; *' -A '*) return 1;; *) return 0;; esac
}
if apply_tor_iptables 123 9040 5353; then exit 2; fi
test -e "$IPTABLES_RULES_FILE"
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_host_vpn_refuses_pending_tor_recovery(self):
        result = self.run_shell(r'''
touch "$DATA_DIR/client.ovpn" "$DATA_DIR/tor-dns.json"
is_our_tor_running() { return 1; }
sudo() { echo 'unexpected mutation' >&2; return 97; }
start_vpn "$DATA_DIR/client.ovpn"
''')
        self.assertEqual(result.returncode, 1)
        self.assertIn('Tor recovery is pending', result.stderr)
        self.assertNotIn('unexpected mutation', result.stderr)

    def test_switch_to_host_vpn_aborts_if_tor_restore_fails(self):
        result = self.run_shell(r'''
touch "$DATA_DIR/client.ovpn"
is_our_tor_running() { return 0; }
read() { response=y; }
cleanup() { echo 'fixture restore failed' >&2; return 1; }
sudo() { echo 'unexpected mutation' >&2; return 97; }
start_vpn "$DATA_DIR/client.ovpn"
''')
        self.assertEqual(result.returncode, 1)
        self.assertIn('fixture restore failed', result.stderr)
        self.assertNotIn('unexpected mutation', result.stderr)

    def test_unrelated_process_named_tor_does_not_match(self):
        with tempfile.TemporaryDirectory() as temp:
            executable = Path(temp) / 'tor'
            executable.symlink_to('/bin/sleep')
            process = subprocess.Popen([str(executable), '30'])
            try:
                result = self.run_shell(f'tor_pid_matches {process.pid}')
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(process.poll())
            finally:
                process.terminate()
                process.wait()

    def test_root_tor_exemption_refused(self):
        result = self.run_shell(r'''
ps() { echo root; }
id() { echo 0; }
apply_tor_iptables 123 9040 5353
''')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()

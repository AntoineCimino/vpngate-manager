"""Tor/Tailscale DNS lifecycle regressions using a fake external daemon."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "tor-dns.py"


class TorDNSTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / "tor-dns.json"
        self.prefs = self.root / "prefs.json"
        self.log = self.root / "calls"
        self.prefs.write_text(json.dumps({"CorpDNS": True, "WantRunning": True}))
        command = self.root / "tailscale"
        command.write_text(f'''#!{sys.executable}
import json, os, sys
from pathlib import Path
prefs = Path(os.environ['FAKE_PREFS'])
args = sys.argv[1:]
with open(os.environ['FAKE_CALLS'], 'a') as f:
    f.write(' '.join(args) + '\\n')
if args == ['debug', 'prefs']:
    if os.environ.get('FAIL_PREFS'):
        sys.exit(1)
    if os.environ.get('BAD_PREFS'):
        print('{{"CorpDNS":"true"}}')
    else:
        print(prefs.read_text())
    sys.exit(0)
if args[0] == 'set':
    desired = args[1].endswith('=true')
    if os.environ.get('FAIL_RESTORE') and desired:
        sys.exit(1)
    if not os.environ.get('IGNORE_SET'):
        p = json.loads(prefs.read_text())
        p['CorpDNS'] = desired
        prefs.write_text(json.dumps(p))
    if os.environ.get('FAIL_DISABLE') and not desired:
        sys.exit(1)
    sys.exit(0)
sys.exit(1)
''')
        command.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root), FAKE_PREFS=str(self.prefs), FAKE_CALLS=str(self.log))

    def run_action(self, action, **env):
        return subprocess.run([sys.executable, str(SCRIPT), action, str(self.state)],
                              env=dict(self.env, **env), text=True, capture_output=True)

    def current(self):
        return json.loads(self.prefs.read_text())["CorpDNS"]

    def test_prepare_restore_and_repeat(self):
        for attempt in range(2):
            result = self.run_action("prepare")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(self.current())
            self.assertTrue(self.state.exists())
            self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
            if attempt == 0:
                self.assertIn("MagicDNS/private DNS", result.stderr)

    def test_restore_original_enabled_then_repeat(self):
        self.assertEqual(self.run_action("prepare").returncode, 0)
        for _ in range(2):
            result = self.run_action("restore")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(self.current())
            self.assertFalse(self.state.exists())

    def test_original_disabled_is_not_enabled_on_restore(self):
        self.prefs.write_text(json.dumps({"CorpDNS": False, "WantRunning": True}))
        self.assertEqual(self.run_action("prepare").returncode, 0)
        self.assertEqual(self.run_action("restore").returncode, 0)
        self.assertFalse(self.current())
        self.assertNotIn("set", self.log.read_text())

    def test_inactive_tailscale_is_noop(self):
        self.prefs.write_text(json.dumps({"CorpDNS": True, "WantRunning": False}))
        self.assertEqual(self.run_action("prepare").returncode, 0)
        self.assertFalse(self.state.exists())
        self.assertTrue(self.current())

    def test_missing_tailscale_is_noop_without_recovery_state(self):
        (self.root / "tailscale").unlink()
        self.assertEqual(self.run_action("prepare").returncode, 0)
        self.assertFalse(self.state.exists())

    def test_invalid_preferences_fail_before_change(self):
        self.assertNotEqual(self.run_action("prepare", BAD_PREFS="1").returncode, 0)
        self.assertTrue(self.current())
        self.assertFalse(self.state.exists())
        self.assertNotIn("set", self.log.read_text())

    def test_unavailable_daemon_fails_before_change(self):
        self.assertNotEqual(self.run_action("prepare", FAIL_PREFS="1").returncode, 0)
        self.assertTrue(self.current())
        self.assertFalse(self.state.exists())
        self.assertNotIn("set", self.log.read_text())

    def test_numeric_recovery_flag_is_rejected(self):
        self.state.write_text('{"version":1,"accept_dns":1}')
        self.assertNotEqual(self.run_action("prepare").returncode, 0)
        self.assertTrue(self.current())

    def test_failed_disable_restores_even_if_change_was_applied(self):
        result = self.run_action("prepare", FAIL_DISABLE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.current())
        self.assertFalse(self.state.exists())

    def test_unconfirmed_disable_fails_closed(self):
        result = self.run_action("prepare", IGNORE_SET="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.current())
        self.assertFalse(self.state.exists())

    def test_failed_restore_keeps_state_and_can_be_retried(self):
        self.assertEqual(self.run_action("prepare").returncode, 0)
        self.assertNotEqual(self.run_action("restore", FAIL_RESTORE="1").returncode, 0)
        self.assertTrue(self.state.exists())
        self.assertFalse(self.current())
        self.assertEqual(self.run_action("restore").returncode, 0)
        self.assertTrue(self.current())
        self.assertFalse(self.state.exists())

    def test_failed_disable_and_rollback_preserves_recovery(self):
        result = self.run_action("prepare", FAIL_DISABLE="1", FAIL_RESTORE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.current())
        self.assertTrue(self.state.exists())
        self.assertEqual(self.run_action("restore").returncode, 0)
        self.assertTrue(self.current())

    def test_malformed_state_is_not_overwritten(self):
        self.state.write_text("broken")
        self.assertNotEqual(self.run_action("prepare").returncode, 0)
        self.assertEqual(self.state.read_text(), "broken")
        self.assertTrue(self.current())

    def test_missing_tailscale_keeps_recovery_state(self):
        self.assertEqual(self.run_action("prepare").returncode, 0)
        (self.root / "tailscale").unlink()
        self.assertNotEqual(self.run_action("restore").returncode, 0)
        self.assertNotEqual(self.run_action("prepare").returncode, 0)
        self.assertTrue(self.state.exists())

    def test_concurrent_operation_refused_before_change(self):
        with open(str(self.state) + ".lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_action("prepare")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.current())
        self.assertFalse(self.state.exists())

    def test_symlink_state_refused(self):
        other = self.root / "other"
        other.write_text("keep")
        self.state.symlink_to(other)
        self.assertNotEqual(self.run_action("prepare").returncode, 0)
        self.assertEqual(other.read_text(), "keep")
        self.assertTrue(self.current())


if __name__ == "__main__":
    unittest.main()

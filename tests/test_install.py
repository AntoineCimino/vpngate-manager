"""Installer regression tests with all privileged writes redirected to fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPERS = ('netns-socks5.py', 'tor-dns.py', 'cloudflare-dns.py')


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.project = self.work / 'checkout'
        self.project.mkdir()
        self.home = self.work / 'home'
        self.home.mkdir()
        self.system = self.work / 'system-bin'
        self.system.mkdir()
        self.sudoers = self.work / 'sudoers'
        self.commands = self.work / 'commands.jsonl'
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        for name in ('vpngate-manager.sh', *HELPERS):
            shutil.copyfile(ROOT / name, self.project / name)
        # Only relocate the optional sudoers file check; the real install paths
        # remain unchanged and are redirected by the privileged-command fixture.
        installer = (ROOT / 'install.sh').read_text().replace(
            'SUDOERS_FILE="/etc/sudoers.d/vpngate-manager"',
            f'SUDOERS_FILE="{self.sudoers}"')
        (self.project / 'install.sh').write_text(installer)
        (self.bin / 'dnf').write_text('#!/bin/sh\nexit 0\n')
        (self.bin / 'dnf').chmod(0o755)
        sudo = self.bin / 'sudo'
        sudo.write_text(f'#!{sys.executable}\n' + r'''
import json, os, shutil, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['INSTALL_COMMANDS'], 'a') as log:
    log.write(json.dumps(args) + '\n')
command = args.pop(0)
if command == 'dnf':
    sys.exit(0)
if command not in ('rm', 'cp', 'chmod', 'install', 'tee'):
    raise SystemExit('Unexpected privileged command: ' + command)
mapped = []
for arg in args:
    if arg.startswith('/usr/local/bin/'):
        arg = str(Path(os.environ['INSTALL_SYSTEM_BIN']) / Path(arg).name)
    elif arg.startswith('/') and not arg.startswith(os.environ['INSTALL_WORK'] + '/'):
        raise SystemExit('Privileged path escaped fixture: ' + arg)
    mapped.append(arg)
raise SystemExit(subprocess.call([shutil.which(command), *mapped]))
''')
        sudo.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=f"{self.bin}:{os.environ['PATH']}",
                        INSTALL_COMMANDS=str(self.commands),
                        INSTALL_SYSTEM_BIN=str(self.system), INSTALL_WORK=str(self.work))

    def run_installer(self, answer='n\n'):
        return subprocess.run(['bash', 'install.sh'], cwd=self.project, env=self.env,
                              input=answer, capture_output=True, text=True, timeout=10)

    def logged_commands(self):
        if not self.commands.exists():
            return []
        return [json.loads(line) for line in self.commands.read_text().splitlines()]

    def test_system_install_includes_all_helpers(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for source, destination in [('vpngate-manager.sh', 'vpn'), *((h, h) for h in HELPERS)]:
            installed = self.system / destination
            self.assertEqual(installed.read_bytes(), (ROOT / source).read_bytes())
            self.assertTrue(installed.stat().st_mode & 0o111)
        self.assertFalse((self.home / '.local/bin/vpngate').exists())
        dependencies = next(c for c in self.logged_commands() if c[0] == 'dnf')
        self.assertIn('util-linux', dependencies)
        self.assertIn('python3', dependencies)
        self.assertFalse(self.sudoers.exists())
        self.assertFalse(any(c[0] == 'tee' for c in self.logged_commands()))

    def test_existing_user_copy_is_synchronized(self):
        user_copy = self.home / '.local/bin/vpngate'
        user_copy.mkdir(parents=True)
        for name in ('vpngate-manager.sh', *HELPERS):
            (user_copy / name).write_text('old version')
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ('vpngate-manager.sh', *HELPERS):
            self.assertEqual((user_copy / name).read_bytes(), (ROOT / name).read_bytes())
        self.assertTrue((user_copy / 'vpngate-manager.sh').stat().st_mode & 0o111)

    def test_missing_helper_fails_before_any_mutation(self):
        for helper in HELPERS:
            with self.subTest(helper=helper):
                path = self.project / helper
                content = path.read_bytes()
                path.unlink()
                result = self.run_installer()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.logged_commands(), [])
                self.assertEqual(list(self.system.iterdir()), [])
                self.assertFalse(self.sudoers.exists())
                path.write_bytes(content)

    def test_sudoers_is_written_only_on_explicit_opt_in(self):
        result = self.run_installer('y\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('NOPASSWD:', self.sudoers.read_text())
        self.assertEqual(self.sudoers.stat().st_mode & 0o777, 0o440)
        self.assertEqual(sum(c[0] == 'tee' for c in self.logged_commands()), 1)

    def test_existing_sudoers_is_preserved(self):
        self.sudoers.write_text('existing administrator policy\n')
        result = self.run_installer('y\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sudoers.read_text(), 'existing administrator policy\n')
        self.assertFalse(any(c[0] == 'tee' for c in self.logged_commands()))


if __name__ == '__main__':
    unittest.main()

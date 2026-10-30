"""DNS transactions use fake commands; no test changes host DNS or routes."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('cloudflare_dns', ROOT / 'cloudflare-dns.py')
dns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dns)
UUID = '72d48cde-d4a1-35a8-b4f5-4fabd6424a9f'
ORIGINAL = dict(zip(dns.SETTINGS, ('9.9.9.9', 'no', '', 'no')))


class FakeCommands:
    def __init__(self):
        self.settings = ORIGINAL.copy()
        self.calls = []
        self.rows = f'{UUID}:802-3-ethernet:eth0'
        self.search = ''
        self.links = []
        self.fail_apply = 0
        self.fail_restore = False
        self.route_generation = 0
        self.change_routes = False
        self.ipv6_method = 'auto'
        self.resolved_domains = 'Global:\nLink 2 (eth0):'
        self.resolved_dns = None
        self.profile_settings = ORIGINAL.copy()
        self.active_search = []

    def __call__(self, args):
        self.calls.append(args)
        if args[0] == 'ip':
            if 'link' in args:
                return json.dumps(self.links)
            routes = [{'dev': 'eth0', 'gateway': '192.0.2.1'}]
            if self.change_routes and self.settings == dns.CLOUDFLARE:
                routes[0]['dev'] = 'tun0'
            return json.dumps(routes)
        if args[0] == 'resolvectl':
            if args[1] == 'domain':
                return self.resolved_domains
            return self.resolved_dns or 'Global:\nLink 2 (eth0): ' + ' '.join(
                a for family in ('ipv4', 'ipv6') for a in self.settings[family + '.dns'].split(',') if a)
        if args[0] == 'busctl' and 'Reapply' in args:
            self.assert_reapply_args(args)
            if self.settings == ORIGINAL and self.fail_restore:
                raise dns.DNSError('restore failure')
            if self.fail_apply:
                self.fail_apply -= 1
                raise dns.DNSError('reapply failure')
            return ''
        if args[0] == 'busctl':
            applied = {'connection': {'uuid': {'type': 's', 'data': UUID}}}
            for family in ('ipv4', 'ipv6'):
                applied[family] = {
                    'dns-data': {'type': 'as', 'data': [a for a in self.settings[family + '.dns'].split(',') if a]},
                    'dns-search': {'type': 'as', 'data': self.active_search},
                    'ignore-auto-dns': {'type': 'b', 'data': self.settings[family + '.ignore-auto-dns'] == 'yes'},
                    'method': {'type': 's', 'data': self.ipv6_method if family == 'ipv6' else 'auto'}}
            return json.dumps({'type': 'a{sa{sv}}t', 'data': [applied, 3]})
        assert args[:3] == ['nmcli', '--escape', 'no'], args
        args = args[3:]
        if args[0] == '--terse':
            return self.rows
        if args[0] == '--get-values':
            field = args[1]
            if field == 'GENERAL.DBUS-PATH':
                return '/org/freedesktop/NetworkManager/Devices/2'
            if field == 'IP4.DNS,IP6.DNS':
                return '\n'.join(self.settings[k].replace(',', ' | ') for k in ('ipv4.dns', 'ipv6.dns'))
            if field == 'ipv6.method':
                return self.ipv6_method
            if field.endswith('dns-search'):
                return self.search
            return self.profile_settings[field]
        raise AssertionError(args)


    def assert_reapply_args(self, args):
        assert args[-2:] == ['3', '1'], args  # optimistic version + preserve external IP/routes
        tokens = iter(args[args.index('a{sa{sv}}tu') + 1:-2])
        applied = {}
        for _ in range(int(next(tokens))):
            section = next(tokens)
            values = {}
            for _ in range(int(next(tokens))):
                name, signature = next(tokens), next(tokens)
                if signature == 'as':
                    values[name] = [next(tokens) for _ in range(int(next(tokens)))]
                elif signature == 'b':
                    values[name] = next(tokens) == 'true'
                elif signature == 's':
                    values[name] = next(tokens)
                else:
                    raise AssertionError(signature)
            applied[section] = values
        assert list(tokens) == []
        assert applied['connection']['uuid'] == UUID
        assert applied['ipv4']['method'] == 'auto'
        assert applied['ipv6']['method'] == self.ipv6_method
        for family in ('ipv4', 'ipv6'):
            self.settings[family + '.dns'] = ','.join(applied[family]['dns-data'])
            self.settings[family + '.ignore-auto-dns'] = 'yes' if applied[family]['ignore-auto-dns'] else 'no'

class Transactions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.conf = self.root / 'resolv.conf'
        self.conf.write_text('# Generated by NetworkManager\nnameserver 9.9.9.9\n')
        self.fake = FakeCommands()
        self.manager = dns.Manager(self.fake, self.root, self.conf, tunnels=lambda: [])

    def test_enable_repeat_status_restore_repeat(self):
        self.assertIn('enabled', self.manager.enable())
        self.assertEqual(self.fake.settings, dns.CLOUDFLARE)
        self.assertEqual(self.manager.load()['original'], ORIGINAL)
        self.assertTrue(self.manager.status()['enabled'])
        self.assertIn('already', self.manager.enable())
        self.assertEqual(self.manager.load()['original'], ORIGINAL)
        self.assertIn('restored', self.manager.restore())
        self.assertEqual(self.fake.settings, ORIGINAL)
        self.assertFalse(self.manager.state.exists())
        self.assertIn('No saved', self.manager.restore())
        self.assertFalse(self.manager.status()['enabled'])
        mutations = [c for c in self.fake.calls if 'Reapply' in c]
        self.assertEqual(len(mutations), 2)
        self.assertTrue(all(c[0] == 'busctl' and c[-1] == '1' for c in mutations))
        self.assertEqual(self.fake.profile_settings, ORIGINAL)
        self.assertTrue(all(c[0] == 'busctl' for c in mutations))

    def test_failed_apply_rolls_back(self):
        self.fake.fail_apply = 1
        with self.assertRaisesRegex(dns.DNSError, 'original DNS settings restored'):
            self.manager.enable()
        self.assertEqual(self.fake.settings, ORIGINAL)
        self.assertFalse(self.manager.state.exists())

    def test_failed_rollback_keeps_snapshot_for_recovery(self):
        self.fake.fail_apply = 1
        self.fake.fail_restore = True
        with self.assertRaisesRegex(dns.DNSError, 'Saved state retained'):
            self.manager.enable()
        self.assertEqual(self.manager.load()['original'], ORIGINAL)
        self.fake.fail_restore = False
        self.manager.restore()
        self.assertFalse(self.manager.state.exists())

    def test_snapshot_exists_before_first_modification(self):
        original_runner = self.manager.run
        def check(args):
            if 'Reapply' in args:
                self.assertEqual(self.manager.load()['original'], ORIGINAL)
            return original_runner(args)
        self.manager.run = check
        self.manager.enable()

    def test_detects_routes_changed_and_rolls_back(self):
        self.fake.change_routes = True
        with self.assertRaisesRegex(dns.DNSError, 'Routes changed'):
            self.manager.enable()
        self.assertEqual(self.fake.settings, ORIGINAL)
        self.assertFalse(self.manager.state.exists())

    def test_rejects_magicdns_without_mutation(self):
        self.conf.write_text('# generated by tailscale\nnameserver 100.100.100.100\n')
        with self.assertRaisesRegex(dns.DNSError, 'Tailscale'):
            self.manager.enable()
        self.assertEqual(self.fake.calls, [])
        self.assertFalse(self.manager.state.exists())

    def test_rejects_private_search_domains(self):
        self.fake.search = '~corp.example'
        with self.assertRaisesRegex(dns.DNSError, 'Split DNS'):
            self.manager.enable()
        self.assertEqual(self.fake.settings, ORIGINAL)
        self.assertFalse(self.manager.state.exists())

    def test_rejects_active_tunnel_from_other_manager(self):
        self.fake.links = [{'flags': ['UP'], 'linkinfo': {'info_kind': 'wireguard'}}]
        with self.assertRaisesRegex(dns.DNSError, 'active tunnel'):
            self.manager.enable()
        self.assertEqual(self.fake.settings, ORIGINAL)

    def test_rejects_nm_vpn(self):
        self.fake.rows += f'\n{UUID}:vpn:tun0'
        with self.assertRaisesRegex(dns.DNSError, 'active VPN'):
            self.manager.enable()
        self.assertEqual(self.fake.settings, ORIGINAL)

    def test_rejects_unsupported_dns_manager(self):
        self.conf.write_text('nameserver 9.9.9.9\n')
        with self.assertRaisesRegex(dns.DNSError, 'ownership'):
            self.manager.enable()
        self.assertEqual(self.fake.settings, ORIGINAL)

    def test_refuses_to_overwrite_external_changes(self):
        self.manager.enable()
        self.fake.settings['ipv4.dns'] = '8.8.8.8'
        with self.assertRaisesRegex(dns.DNSError, 'outside this tool'):
            self.manager.restore()
        self.assertEqual(self.fake.settings['ipv4.dns'], '8.8.8.8')
        self.assertTrue(self.manager.state.exists())

    def test_restore_does_not_reapply_a_different_connection(self):
        self.manager.enable()
        self.fake.rows = ''
        with self.assertRaisesRegex(dns.DNSError, 'inactive'):
            self.manager.restore()
        self.assertTrue(self.manager.state.exists())

    def test_invalid_saved_state_is_not_executed(self):
        self.manager.state.write_text('{"version":1,"original":{}}')
        with self.assertRaisesRegex(dns.DNSError, 'Invalid saved'):
            self.manager.restore()
        self.assertEqual(self.fake.calls, [])

    def test_ipv4_only_profile_keeps_disabled_ipv6_settings(self):
        self.fake.ipv6_method = 'disabled'
        self.manager.enable()
        self.assertEqual(self.fake.settings['ipv6.dns'], ORIGINAL['ipv6.dns'])
        self.assertEqual(self.fake.settings['ipv4.dns'], dns.CLOUDFLARE['ipv4.dns'])
        self.assertTrue(self.manager.status()['enabled'])
        self.manager.restore()
        self.assertEqual(self.fake.settings, ORIGINAL)

    def test_refuses_independently_managed_tor(self):
        self.manager.tunnels = lambda: ['tor']
        with self.assertRaisesRegex(dns.DNSError, 'Tor/OpenVPN'):
            self.manager.enable()
        self.assertEqual(self.fake.calls, [])

    def test_resolved_backend_refuses_external_split_domains(self):
        self.conf.write_text('# managed by systemd-resolved\nnameserver 127.0.0.53\n')
        self.fake.resolved_domains += '\nLink 3 (corp0): ~corp.example'
        with self.assertRaisesRegex(dns.DNSError, 'routing/search domains'):
            self.manager.enable()
        self.assertEqual(self.fake.settings, ORIGINAL)

    def test_resolved_backend_refuses_external_dns(self):
        self.conf.write_text('# managed by systemd-resolved\nnameserver 127.0.0.53\n')
        self.fake.resolved_dns = 'Global: 8.8.8.8\nLink 2 (eth0): 9.9.9.9'
        with self.assertRaisesRegex(dns.DNSError, 'outside the selected uplink'):
            self.manager.enable()
        self.assertEqual(self.fake.settings, ORIGINAL)

    def test_resolved_backend_accepts_nm_owned_uplink_only(self):
        self.conf.write_text('# managed by systemd-resolved\nnameserver 127.0.0.53\n')
        self.manager.enable()
        self.manager.restore()
        self.assertEqual(self.fake.settings, ORIGINAL)

    def test_new_dns_conflict_blocks_restore_without_overwriting(self):
        self.manager.enable()
        self.conf.write_text('# generated by tailscale\nnameserver 100.100.100.100\n')
        self.assertFalse(self.manager.status()['enabled'])
        self.assertIn('Tailscale', self.manager.status()['conflict'])
        with self.assertRaisesRegex(dns.DNSError, 'Tailscale'):
            self.manager.restore()
        self.assertEqual(self.fake.settings, dns.CLOUDFLARE)
        self.assertTrue(self.manager.state.exists())

    def test_pending_persistent_profile_changes_are_never_applied(self):
        self.fake.profile_settings['ipv4.dns'] = '8.8.8.8'
        self.manager.enable()
        self.assertEqual(self.manager.load()['original'], ORIGINAL)
        self.manager.restore()
        self.assertEqual(self.fake.settings, ORIGINAL)
        self.assertEqual(self.fake.profile_settings['ipv4.dns'], '8.8.8.8')
        self.assertFalse(any('reapply' in c or 'modify' in c and 'connection' in c for c in self.fake.calls))

    def test_active_search_domains_are_preserved_by_refusal(self):
        self.fake.active_search = ['corp.example']
        with self.assertRaisesRegex(dns.DNSError, 'Active DNS search domains'):
            self.manager.enable()
        self.assertEqual(self.fake.settings, ORIGINAL)

    def test_resolved_runtime_override_on_same_link_is_preserved(self):
        self.conf.write_text('# managed by systemd-resolved\nnameserver 127.0.0.53\n')
        self.fake.resolved_dns = 'Global:\nLink 2 (eth0): 8.8.8.8'
        with self.assertRaisesRegex(dns.DNSError, 'differs from NetworkManager runtime'):
            self.manager.enable()
        self.assertEqual(self.fake.settings, ORIGINAL)

    def test_disk_failure_saving_active_phase_rolls_back(self):
        save = self.manager.save
        def fail_active(data):
            if data['phase'] == 'active':
                raise OSError('disk full')
            save(data)
        self.manager.save = fail_active
        with self.assertRaisesRegex(dns.DNSError, 'original DNS settings restored'):
            self.manager.enable()
        self.assertEqual(self.fake.settings, ORIGINAL)
        self.assertFalse(self.manager.state.exists())

    def test_dbus_encoder_preserves_nested_nm_variants(self):
        data = {'ipv4': {'route-data': {'type': 'aa{sv}', 'data': [
            {'dest': {'type': 's', 'data': '198.51.100.0'}, 'prefix': {'type': 'u', 'data': 24}}]}}}
        self.assertEqual(dns.dbus_tokens('a{sa{sv}}', data),
                         ['1', 'ipv4', '1', 'route-data', 'aa{sv}', '1', '2',
                          'dest', 's', '198.51.100.0', 'prefix', 'u', '24'])
        self.assertEqual(dns.dbus_tokens('a(ayuay)', [([1, 2], 24, [3, 4])]),
                         ['1', '2', '1', '2', '24', '2', '3', '4'])

    def test_cli_validation(self):
        result = subprocess.run(['python3', str(ROOT / 'cloudflare-dns.py'), 'benchmark', '--samples', '0'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('between 1 and 20', result.stderr)

    def test_benchmark_counts_failures_and_successes_without_commands(self):
        calls = []
        def query(server, domain):
            calls.append((server, domain))
            if server == '1.1.1.1':
                raise OSError('blocked')
            return 12.5
        result = dns.benchmark(3, self.conf, query)
        self.assertEqual(result['dns']['current']['median_ms'], 12.5)
        self.assertEqual(result['dns']['cloudflare']['failures'], 3)
        self.assertIsNone(result['dns']['cloudflare']['median_ms'])
        self.assertEqual(len(calls), 6)
        self.assertIn('No DNS or route settings changed', result['note'])


if __name__ == '__main__':
    unittest.main()

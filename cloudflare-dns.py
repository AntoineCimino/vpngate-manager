#!/usr/bin/env python3
"""Optional, reversible Cloudflare DNS on a single NetworkManager uplink."""
import argparse
import contextlib
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import statistics
import struct
import subprocess
import sys
import time

STATE_DIR = Path('/var/lib/vpngate-manager/cloudflare-dns')
SETTINGS = ('ipv4.dns', 'ipv4.ignore-auto-dns', 'ipv6.dns', 'ipv6.ignore-auto-dns')
CLOUDFLARE = dict(zip(SETTINGS, ('1.1.1.1,1.0.0.1', 'yes',
                                '2606:4700:4700::1111,2606:4700:4700::1001', 'yes')))


class DNSError(Exception):
    pass


def run(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise DNSError(f'Cannot run {args[0]}: {exc}') from exc
    if result.returncode:
        raise DNSError(f'{args[0]} failed: {result.stderr.strip()}')
    return result.stdout.strip()


def nameservers(path=Path('/etc/resolv.conf')):
    addresses = []
    for line in path.read_text().splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0] == 'nameserver':
            try:
                addresses.append(str(ipaddress.ip_address(fields[1])))
            except ValueError:
                pass
    return addresses


def running_tunnels():
    """Refuse even independently managed Tor/OpenVPN processes."""
    found = []
    for entry in Path('/proc').iterdir():
        if entry.name.isdecimal():
            try:
                name = (entry / 'comm').read_text().strip()
            except (OSError, UnicodeError):
                continue
            if name in ('tor', 'openvpn', 'wireguard-go'):
                found.append(name)
    return found


def dbus_tokens(signature, value):
    """Encode busctl arguments without a shell, including nested NM variants."""
    def parse(index):
        char = signature[index]
        if char == 'a':
            child, end = parse(index + 1)
            return ('a', child), end
        if char in '({':
            children = []
            end = index + 1
            closing = ')' if char == '(' else '}'
            while signature[end] != closing:
                child, end = parse(end)
                children.append(child)
            return ('group', children), end + 1
        if char not in 'ybnqiuxtdhsogv':
            raise DNSError('Unsupported D-Bus value type; no DNS mutation attempted.')
        return char, index + 1

    def encode(node, data):
        if isinstance(node, tuple):
            if node[0] == 'a':
                entries = list(data.items()) if isinstance(data, dict) else data
                return [str(len(entries))] + [token for entry in entries for token in encode(node[1], entry)]
            if len(node[1]) != len(data):
                raise DNSError('Invalid D-Bus structure.')
            return [token for child, item in zip(node[1], data) for token in encode(child, item)]
        if node == 'v':
            return [data['type'], *dbus_tokens(data['type'], data['data'])]
        if node == 'b':
            return ['true' if data else 'false']
        return [str(data)]

    try:
        node, end = parse(0)
        if end != len(signature):
            raise DNSError('Expected one D-Bus argument type.')
        return encode(node, value)
    except (KeyError, TypeError, IndexError, ValueError) as exc:
        raise DNSError('Cannot encode applied connection safely; no DNS mutation attempted.') from exc


class Manager:
    def __init__(self, runner=run, state_dir=STATE_DIR, resolv_conf=Path('/etc/resolv.conf'),
                 tunnels=running_tunnels):
        self.run = runner
        self.directory = state_dir
        self.state = state_dir / 'state.json'
        self.resolv_conf = resolv_conf
        self.tunnels = tunnels

    def nm(self, *args):
        return self.run(['nmcli', '--escape', 'no', *args])

    def field(self, uuid, name):
        return self.nm('--get-values', name, 'connection', 'show', 'uuid', uuid)

    def applied_details(self, device):
        path = self.nm('--get-values', 'GENERAL.DBUS-PATH', 'device', 'show', device)
        if not re.fullmatch(r'/org/freedesktop/NetworkManager/Devices/\d+', path):
            raise DNSError('Cannot identify the NetworkManager device D-Bus path.')
        try:
            reply = json.loads(self.run(['busctl', '--json=short', 'call', 'org.freedesktop.NetworkManager',
                path, 'org.freedesktop.NetworkManager.Device', 'GetAppliedConnection', 'u', '0']))
            if reply['type'] != 'a{sa{sv}}t':
                raise ValueError('unexpected D-Bus result type')
            return reply['data'][0], reply['data'][1], path
        except (ValueError, KeyError, TypeError, IndexError) as exc:
            raise DNSError('Cannot read the active DNS settings; no persistent profile will be reapplied.') from exc

    def applied(self, device):
        return self.applied_details(device)[0]

    def snapshot(self, uuid, device):
        applied = self.applied(device)
        if applied.get('connection', {}).get('uuid', {}).get('data') != uuid:
            raise DNSError('The active connection changed during the DNS operation.')
        values = {}
        for family in ('ipv4', 'ipv6'):
            section = applied.get(family, {})
            addresses = section.get('dns-data', {}).get('data')
            if addresses is None:
                raw = section.get('dns', {}).get('data', [])
                try:
                    addresses = ([socket.inet_ntoa(struct.pack('=I', a)) for a in raw] if family == 'ipv4'
                                 else [socket.inet_ntop(socket.AF_INET6, bytes(a)) for a in raw])
                except (ValueError, TypeError, OSError, struct.error) as exc:
                    raise DNSError('Cannot decode active DNS settings.') from exc
            if not isinstance(addresses, list) or any(not isinstance(a, str) for a in addresses):
                raise DNSError('Cannot decode active DNS addresses.')
            # DNS names with ports/TLS server names are not silently normalized.
            values[family + '.dns'] = ','.join(addresses)
            ignore_auto = section.get('ignore-auto-dns', {}).get('data', False)
            if not isinstance(ignore_auto, bool):
                raise DNSError('Cannot decode active automatic DNS policy.')
            values[family + '.ignore-auto-dns'] = 'yes' if ignore_auto else 'no'
        return values

    def routes(self):
        return [[{k: v for k, v in route.items() if k not in ('expires', 'cache')}
                 for route in json.loads(self.run(['ip', '-j', *family, 'route', 'show', 'table', 'all']))]
                for family in ([], ['-6'])]

    def active(self):
        rows = self.nm('--terse', '--fields', 'UUID,TYPE,DEVICE', 'connection', 'show', '--active')
        result = []
        for row in rows.splitlines():
            fields = row.split(':')
            if len(fields) != 3:
                raise DNSError('Cannot parse NetworkManager active connections.')
            result.append(fields)
        return result

    def eligible(self):
        if self.tunnels():
            raise DNSError('Tor/OpenVPN is running; direct DNS mode refuses to change its DNS policy. Stop it explicitly first.')
        text = self.resolv_conf.read_text()
        if 'tailscale' in text.lower() or any(a in nameservers(self.resolv_conf) for a in
                ('100.100.100.100', 'fd7a:115c:a1e0::53')):
            raise DNSError('Tailscale manages DNS; Cloudflare mode would disrupt MagicDNS. No settings changed.')
        if any(line.split('#', 1)[0].strip().startswith(('search ', 'domain '))
               for line in text.splitlines()):
            raise DNSError('DNS search domains are configured; preserve private-name resolution by leaving DNS unchanged.')
        active = self.active()
        for uuid, kind, device in active:
            if kind in ('vpn', 'tun', 'wireguard', 'ip-tunnel') or device.startswith(('tun', 'tap', 'tailscale', 'wg')):
                raise DNSError('An active VPN/Tailscale connection conflicts with direct DNS mode; stop it explicitly first.')
            for field in ('ipv4.dns-search', 'ipv6.dns-search'):
                if self.field(uuid, field):
                    raise DNSError('Split DNS/search domains are configured; no settings changed.')
        links = json.loads(self.run(['ip', '-j', 'link', 'show']))
        if any(link.get('linkinfo', {}).get('info_kind') in ('tun', 'wireguard', 'ipip', 'sit')
               and 'UP' in link.get('flags', []) for link in links):
            raise DNSError('An active tunnel conflicts with direct DNS mode; no settings changed.')
        # IPv4 and IPv6 may share an uplink, but choosing between multiple
        # physical uplinks or policy routes would require changing DNS policy.
        defaults = []
        for family in ([], ['-6']):
            defaults += json.loads(self.run(['ip', '-j', *family, 'route', 'show', 'default']))
        devices = {row.get('dev') for row in defaults}
        if len(devices) != 1 or None in devices:
            raise DNSError('Requires exactly one default-route uplink managed by NetworkManager.')
        device = devices.pop()
        matches = [(u, d) for u, kind, d in active if d == device and kind in
                   ('802-3-ethernet', '802-11-wireless', 'ethernet', 'wifi')]
        if len(matches) != 1:
            raise DNSError('This DNS manager/uplink is unsupported. Use its native DNS settings; resolv.conf was not edited.')
        uuid, device = matches[0]
        if not re.fullmatch(r'[0-9a-fA-F-]{36}', uuid) or not re.fullmatch(r'[A-Za-z0-9_.-]+', device):
            raise DNSError('Unexpected uplink identifier.')
        # Refuse static/third-party resolv.conf files that NM does not control.
        # systemd-resolved is supported only when fed by NetworkManager.
        target = str(self.resolv_conf.resolve())
        managed = 'NetworkManager' in text or 'systemd-resolved' in text or target in (
            '/run/NetworkManager/resolv.conf', '/run/systemd/resolve/stub-resolv.conf',
            '/run/systemd/resolve/resolv.conf')
        if not managed:
            raise DNSError('Cannot establish NetworkManager ownership of DNS; use your DNS manager directly.')
        if 'systemd-resolved' in text or '/systemd/resolve/' in target:
            self.check_resolved(device)
        applied = self.applied(device)
        if any(applied.get(family, {}).get('dns-search', {}).get('data')
               for family in ('ipv4', 'ipv6')):
            raise DNSError('Active DNS search domains are configured; no settings changed.')
        return uuid, device

    def check_resolved(self, device):
        # NM profile fields cannot reveal domains or DNS installed directly by
        # another service into resolved. Refuse those instead of stealing them.
        for command in ('domain', 'dns'):
            output = self.run(['resolvectl', command])
            rows = [row.strip() for row in output.splitlines() if row.strip()]
            if not rows:
                raise DNSError('Cannot inspect systemd-resolved DNS policy; no settings changed.')
            for row in rows:
                match = re.fullmatch(r'(Global|Link \d+ \(([^)]+)\)):\s*(.*)', row)
                if not match:
                    raise DNSError('Cannot parse systemd-resolved DNS policy; no settings changed.')
                if command == 'domain' and match[3]:
                    raise DNSError('systemd-resolved has routing/search domains; no settings changed.')
                if command == 'dns' and match[3]:
                    if match[2] != device:
                        raise DNSError('systemd-resolved has DNS outside the selected uplink; no settings changed.')
                    runtime = self.nm('--get-values', 'IP4.DNS,IP6.DNS', 'device', 'show', device)
                    expected = {a.strip() for a in re.split(r'[|\n]', runtime) if a.strip()}
                    if set(match[3].split()) != expected:
                        raise DNSError('systemd-resolved DNS differs from NetworkManager runtime DNS; no settings changed.')

    def save(self, data):
        temp = self.directory / 'state.tmp'
        with open(temp, 'w', encoding='utf-8') as stream:
            os.chmod(temp, 0o644)
            json.dump(data, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        temp.replace(self.state)
        descriptor = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def load(self):
        try:
            data = json.loads(self.state.read_text())
            if (data.get('version') != 2 or set(data['original']) != set(SETTINGS)
                    or set(data['desired']) != set(SETTINGS)):
                raise ValueError('unexpected snapshot format')
            if not re.fullmatch(r'[0-9a-fA-F-]{36}', data['uuid']):
                raise ValueError('invalid connection UUID')
            if not re.fullmatch(r'[A-Za-z0-9_.-]+', data['device']):
                raise ValueError('invalid device')
            if any(not isinstance(v, str) for key in ('original', 'desired') for v in data[key].values()):
                raise ValueError('invalid DNS values')
            return data
        except (ValueError, KeyError, TypeError) as exc:
            raise DNSError(f'Invalid saved DNS state: {exc}; preserve it for manual recovery.') from exc

    def apply(self, uuid, device, values):
        applied, version, path = self.applied_details(device)
        if applied.get('connection', {}).get('uuid', {}).get('data') != uuid:
            raise DNSError('The active connection changed during the DNS operation.')
        for family in ('ipv4', 'ipv6'):
            section = applied.setdefault(family, {})
            section.pop('dns', None)  # Modern dns-data takes precedence over deprecated numeric DNS.
            section['dns-data'] = {'type': 'as', 'data': [a for a in values[family + '.dns'].split(',') if a]}
            section['ignore-auto-dns'] = {'type': 'b', 'data': values[family + '.ignore-auto-dns'] == 'yes'}
        self.run(['busctl', '--json=short', 'call', 'org.freedesktop.NetworkManager', path,
            'org.freedesktop.NetworkManager.Device', 'Reapply', 'a{sa{sv}}tu',
            *dbus_tokens('a{sa{sv}}', applied), str(version), '1'])
        # flag 1 preserves externally installed IPs/routes; unsupported old NM
        # versions refuse this request instead of falling back to unsafe behavior.
        if self.snapshot(uuid, device) != values:
            raise DNSError('NetworkManager did not retain the requested active DNS configuration.')

    def enable(self):
        if self.state.exists():
            data = self.load()
            if data.get('phase') == 'active' and self.snapshot(data['uuid'], data['device']) == data['desired']:
                if self.eligible() != (data['uuid'], data['device']):
                    raise DNSError('The active uplink changed; restore the original connection before enabling again.')
                return 'Cloudflare DNS is already enabled. Original settings remain saved.'
            raise DNSError('A saved DNS transaction exists. Run dns restore before enabling again.')
        uuid, device = self.eligible()
        before = self.routes()
        original = self.snapshot(uuid, device)
        desired = CLOUDFLARE.copy()
        if self.applied(device).get('ipv6', {}).get('method', {}).get('data') in ('disabled', 'ignore'):
            desired.update({k: original[k] for k in SETTINGS if k.startswith('ipv6.')})
        data = dict(version=2, uuid=uuid, device=device, original=original, desired=desired, phase='applying')
        self.save(data)  # Persist recovery information before the first mutation.
        try:
            self.apply(uuid, device, desired)
            if self.routes() != before:
                raise DNSError('Routes changed while applying DNS; restoring DNS settings.')
            data['phase'] = 'active'
            self.save(data)
        except (DNSError, OSError, KeyboardInterrupt) as exc:
            try:
                self.apply(uuid, device, data['original'])
                self.state.unlink()
            except (DNSError, OSError) as recovery:
                raise DNSError(f'{exc}; automatic restore failed: {recovery}. Saved state retained; run dns restore.') from exc
            raise DNSError(f'{exc}; original DNS settings restored.') from exc
        return 'Cloudflare DNS enabled on the current connection. Traffic uses your normal route and public IP.'

    def restore(self):
        if not self.state.exists():
            return 'No saved Cloudflare DNS settings to restore.'
        data = self.load()
        # Do not reapply an unrelated/new connection occupying the old device.
        active = self.active()
        if not any(u == data['uuid'] and d == data['device'] for u, _, d in active):
            raise DNSError('Original connection is inactive. Reconnect it, then run dns restore; saved state retained.')
        if self.eligible() != (data['uuid'], data['device']):
            raise DNSError('The active uplink changed; saved state retained.')
        current = self.snapshot(data['uuid'], data['device'])
        if current not in (data['desired'], data['original']) and data.get('phase') == 'active':
            raise DNSError('DNS settings changed outside this tool. Refusing to overwrite them; saved state retained.')
        before = self.routes()
        self.apply(data['uuid'], data['device'], data['original'])
        if self.routes() != before:
            raise DNSError('Routes changed during DNS restore; DNS restored but saved state retained for inspection.')
        self.state.unlink()
        return 'Original DNS settings restored.'

    def status(self):
        if not self.state.exists():
            return {'enabled': False, 'saved_settings': False, 'resolvers': nameservers(self.resolv_conf)}
        data = self.load()
        active = any(u == data['uuid'] and d == data['device'] for u, _, d in self.active())
        conflict = None
        try:
            compatible = self.eligible() == (data['uuid'], data['device'])
        except DNSError as exc:
            compatible = False
            conflict = str(exc)
        return {'enabled': data.get('phase') == 'active' and active and compatible
                and self.snapshot(data['uuid'], data['device']) == data['desired'],
                'conflict': conflict,
                'saved_settings': True, 'phase': data.get('phase'), 'connection': data['uuid'],
                'device': data['device'], 'resolvers': nameservers(self.resolv_conf)}


@contextlib.contextmanager
def mutation_lock(directory):
    directory.mkdir(parents=True, mode=0o755, exist_ok=True)
    if (directory.is_symlink() or directory.stat().st_uid != os.geteuid()
            or directory.stat().st_mode & 0o022):
        raise DNSError('DNS state directory must be owned by the current privileged user and not a symlink.')
    with open(directory / 'lock', 'a', encoding='utf-8') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise DNSError('Another DNS operation is running.') from exc
        yield


def query_dns(server, domain, timeout=2):
    """Measure a normal UDP A query, validating transaction and response code."""
    transaction = secrets.randbits(16)
    question = b''.join(bytes([len(part)]) + part.encode('ascii') for part in domain.split('.')) + b'\0\0\1\0\1'
    packet = struct.pack('!6H', transaction, 0x0100, 1, 0, 0, 0) + question
    family = socket.AF_INET6 if ':' in server else socket.AF_INET
    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        sock.connect((server, 53))
        started = time.perf_counter()
        sock.send(packet)
        response = sock.recv(4096)
        elapsed = (time.perf_counter() - started) * 1000
    if len(response) < 12:
        raise DNSError('Truncated DNS response')
    reply_id, flags, _, answers, _, _ = struct.unpack('!6H', response[:12])
    if reply_id != transaction or not flags & 0x8000 or flags & 0x020f or not answers:
        raise DNSError('Invalid, truncated, failed, or empty DNS response')
    return elapsed


def benchmark(samples=5, resolv_conf=Path('/etc/resolv.conf'), query=query_dns):
    current = nameservers(resolv_conf)
    if not current:
        raise DNSError('No current nameserver found in /etc/resolv.conf.')
    servers = [('current', current[0]), ('cloudflare', '1.1.1.1')]
    results = {name: {'server': server, 'samples_ms': [], 'failures': 0} for name, server in servers}
    domains = ('example.com', 'cloudflare.com', 'github.com')
    for i in range(samples):
        for name, server in servers[::1 if i % 2 == 0 else -1]:
            try:
                results[name]['samples_ms'].append(round(query(server, domains[i % len(domains)]), 3))
            except (OSError, DNSError):
                results[name]['failures'] += 1
    for row in results.values():
        row['median_ms'] = statistics.median(row['samples_ms']) if row['samples_ms'] else None
    return {'dns': results, 'samples_per_resolver': samples,
            'note': 'Read-only UDP DNS lookup measurements; cache, location and network load affect results. '
                    'This does not measure bandwidth or predict VPN throughput. No DNS or route settings changed.'}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('benchmark', 'status', 'enable', 'restore'))
    parser.add_argument('--samples', type=int, default=5, help='DNS samples per resolver (1-20, benchmark only)')
    args = parser.parse_args(argv)
    if not 1 <= args.samples <= 20:
        parser.error('--samples must be between 1 and 20')
    try:
        manager = Manager()
        if args.action == 'benchmark':
            print(json.dumps(benchmark(args.samples), indent=2))
        elif args.action == 'status':
            print(json.dumps(manager.status(), indent=2))
        else:
            if os.geteuid() != 0:
                raise DNSError('DNS changes require root. Run this command with sudo; benchmark/status do not require it.')
            with mutation_lock(STATE_DIR):
                print(getattr(manager, args.action)())
    except (DNSError, OSError, KeyboardInterrupt) as exc:
        print(f'DNS: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

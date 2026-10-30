#!/bin/bash
# Run only inside a fresh --network none disposable Docker container.
# See docs/cloudflare-dns.md for the complete invocation.
set -euo pipefail
if [ "${VPNGATE_DISPOSABLE_DNS_TEST:-}" != 1 ] || [ ! -f /.dockerenv ] || [ "$(id -u)" != 0 ]; then
    echo 'Requires an explicitly opted-in disposable root Docker container.' >&2
    exit 1
fi
python3 - <<'PY'
import json, subprocess
links = json.loads(subprocess.check_output(['ip', '-j', 'link', 'show']))
assert {link['ifname'] for link in links} == {'lo'}, 'Requires --network none and no pre-existing uplinks'
PY
REPO=$(cd "$(dirname "$0")/.." && pwd)
export REPO
mkdir -p /run/dbus /etc/NetworkManager/conf.d
# Docker mounts a private resolver file; unmount it only in this disposable mount namespace.
umount /etc/resolv.conf
cat >/etc/NetworkManager/conf.d/99-vpngate-fixture.conf <<'EOF'
[main]
dns=default
rc-manager=file
[keyfile]
unmanaged-devices=none
[device-fixture]
match-device=interface-name:uplink
managed=1
[device-peer]
match-device=interface-name:peer
managed=0
EOF
dbus-daemon --system --fork
NetworkManager --no-daemon >/tmp/vpngate-nm.log 2>&1 &
for attempt in $(seq 1 30); do
    if nmcli general status >/dev/null 2>&1; then break; fi
    sleep .2
done
nmcli general status >/dev/null
ip link add uplink type veth peer name peer
ip addr add 192.0.2.1/24 dev peer
ip link set peer up
nmcli device set uplink managed yes
nmcli connection add type ethernet ifname uplink con-name fixture \
    ipv4.method manual ipv4.addresses 192.0.2.2/24 ipv4.gateway 192.0.2.1 \
    ipv4.dns 9.9.9.9 ipv6.method disabled connection.autoconnect no
nmcli connection up fixture
# Let the peer's unrelated IPv6 duplicate-address detection settle before snapshots.
for attempt in $(seq 1 30); do
    if ! ip -6 addr show dev peer | grep -q tentative; then break; fi
    sleep .1
done
if ip -6 addr show dev peer | grep -q tentative; then exit 1; fi
# External state and unapplied profile edits must survive both operations.
ip addr add 198.51.100.2/32 dev uplink
ip route add 203.0.113.0/24 dev uplink
nmcli connection modify fixture ipv4.addresses 192.0.2.222/24 \
    ipv4.gateway 192.0.2.99 ipv4.dns 8.8.8.8
python3 - <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import subprocess

root = Path(os.environ['REPO'])
spec = importlib.util.spec_from_file_location('dns', root / 'cloudflare-dns.py')
dns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dns)
manager = dns.Manager()
uuid = dns.run(['nmcli', '-g', 'connection.uuid', 'connection', 'show', 'fixture'])
original = manager.snapshot(uuid, 'uplink')
assert original['ipv4.dns'] == '9.9.9.9'
before = manager.routes()
addresses = dns.run(['ip', '-j', 'addr', 'show'])
profile = dns.run(['nmcli', '-g', 'ipv4.addresses,ipv4.gateway,ipv4.dns', 'connection', 'show', 'fixture'])
assert '192.0.2.222' in profile and '192.0.2.99' in profile and '8.8.8.8' in profile

def cli(action):
    return subprocess.check_output(['python3', str(root / 'cloudflare-dns.py'), action], text=True)

assert not json.loads(cli('status'))['enabled']
assert 'enabled' in cli('enable')
assert 'already enabled' in cli('enable')
assert json.loads(cli('status'))['enabled']
assert dns.nameservers() == ['1.1.1.1', '1.0.0.1']
assert manager.snapshot(uuid, 'uplink')['ipv4.ignore-auto-dns'] == 'yes'
assert manager.routes() == before, {'before': before, 'after': manager.routes()}
assert dns.run(['ip', '-j', 'addr', 'show']) == addresses
assert dns.run(['nmcli', '-g', 'ipv4.addresses,ipv4.gateway,ipv4.dns', 'connection', 'show', 'fixture']) == profile
assert 'restored' in cli('restore')
assert 'No saved' in cli('restore')
assert not json.loads(cli('status'))['enabled']
assert not manager.state.exists()
assert manager.snapshot(uuid, 'uplink') == original
assert dns.nameservers() == ['9.9.9.9']
assert manager.routes() == before, {'before': before, 'after': manager.routes()}
assert dns.run(['ip', '-j', 'addr', 'show']) == addresses
assert dns.run(['nmcli', '-g', 'ipv4.addresses,ipv4.gateway,ipv4.dns', 'connection', 'show', 'fixture']) == profile
print('PASS: actual NM D-Bus enable/status/restore; original active DNS restored; repeated calls safe; '
      'pending profile edits and external IP/routes untouched; saved state removed.')
PY

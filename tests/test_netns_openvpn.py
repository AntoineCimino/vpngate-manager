"""Real OpenVPN TLS + SOCKS5 integration in disposable kernel namespaces.

The VPN server and HTTP endpoint are local fixtures. The user's host network,
external VPN services, and public internet are never involved.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class OpenVPNIntegrationTests(unittest.TestCase):
    def test_real_tls_tunnel_proxy_and_fail_closed_cleanup(self):
        for command in ('unshare', 'ip', 'iptables', 'openvpn', 'openssl', 'curl'):
            if not shutil.which(command):
                self.skipTest(f'{command} is unavailable')
        if not Path('/dev/net/tun').exists():
            self.skipTest('/dev/net/tun is unavailable')
        if not all(Path(p).is_dir() for p in ('/etc/netns', '/run/netns')):
            self.skipTest('Create /etc/netns and /run/netns before running kernel tests')
        probe = subprocess.run(['unshare', '-Urnm', 'true'], capture_output=True)
        if probe.returncode:
            self.skipTest('unprivileged user/network/mount namespaces unavailable')
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            # sudo CI maps host UID 0 into the user namespace; the original
            # checkout may belong to an unmapped runner UID with private paths.
            # Copy inputs while still privileged into this caller-owned fixture.
            checkout = work / 'checkout'
            checkout.mkdir()
            for source in ('vpngate-manager.sh', 'netns-socks5.py'):
                shutil.copyfile(ROOT / source, checkout / source)
            bindir = work / 'bin'
            bindir.mkdir()
            (bindir / 'sudo').write_text('#!/bin/sh\nexec "$@"\n')
            (bindir / 'sudo').chmod(0o755)
            (work / 'peer-http.py').write_text('''import http.server
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.client_address[0].encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
http.server.HTTPServer(('198.51.100.9', 18080), Handler).serve_forever()
''')
            script = r'''
set -e
mount --make-rprivate /
mount -t tmpfs tmpfs /run/netns
mount -t tmpfs tmpfs /etc/netns
ip link set lo up
ip netns add peer
ip link add uplink type veth peer name server0 netns peer
ip addr add 192.0.2.2/24 dev uplink
ip link set uplink up
ip netns exec peer ip addr add 192.0.2.1/24 dev server0
ip netns exec peer ip link set server0 up
ip netns exec peer ip link set lo up
ip netns exec peer ip link add endpoint type dummy
ip netns exec peer ip addr add 198.51.100.9/32 dev endpoint
ip netns exec peer ip link set endpoint up
ip route add default via 192.0.2.1
ip -6 addr add fd00:1234::2/64 dev uplink
# Self-signed, disposable test CA/certificate used only by this local fixture.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj /CN=vpngate-local-test -days 1 > "$WORK/cert.log" 2>&1
chmod 600 "$WORK/key.pem"
cleanup_fixture() {
 for ns in smoke peer; do
  for pid in $(ip netns pids "$ns" 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
 done
}
trap cleanup_fixture EXIT
ip netns exec peer openvpn --dev tun0 --proto udp --port 1194 --tls-server \
    --ifconfig 10.8.0.1 10.8.0.2 --ca "$WORK/cert.pem" --cert "$WORK/cert.pem" --key "$WORK/key.pem" \
    --dh none --data-ciphers AES-256-GCM --daemon --log "$WORK/server.log" --writepid "$WORK/server.pid"
ip netns exec peer python3 "$WORK/peer-http.py" > "$WORK/http.log" 2>&1 &
cat > "$WORK/vpn.ovpn" <<EOF
remote 192.0.2.1 1194
proto udp
nobind
tls-client
ifconfig 10.8.0.2 10.8.0.1
ca $WORK/cert.pem
cert $WORK/cert.pem
key $WORK/key.pem
EOF
source <(sed '/^case "${1:-help}" in/,$d' "$REPO/vpngate-manager.sh")
SCRIPT_DIR="$REPO"
resolve_ovpn_for_exec() { echo "$WORK/vpn.ovpn"; }
before=$(ip route)
before6=$(ip -6 route)
default_before=$(ip route show default)
forward_before=$(sysctl -n net.ipv4.ip_forward)
firewall_before=$(iptables -S; iptables -t nat -S)
netns_start '' smoke
# All pre-existing host routes stay present, including both address families.
while IFS= read -r route; do ip route | grep -Fx -- "$route" >/dev/null; done <<< "$before"
while IFS= read -r route; do ip -6 route | grep -Fx -- "$route" >/dev/null; done <<< "$before6"
test "$(ip route show default)" = "$default_before"
# Observed peer IP proves HTTP traversed the actual encrypted tun device.
peer_ip=$(curl --fail --silent --show-error --max-time 5 --noproxy '' \
    --socks5-hostname 10.200.200.2:1080 http://198.51.100.9:18080/)
test "$peer_ip" = 10.8.0.2
grep -q 'Initialization Sequence Completed' "$DATA_DIR/netns/smoke/openvpn.log"
grep -q 'Peer Connection Initiated' "$WORK/server.log"
# Kill the real VPN and wait for its real tun interface to disappear.
kill "$(cat "$DATA_DIR/netns/smoke/openvpn.pid")"
for attempt in 1 2 3 4 5; do
 if ! ip netns exec smoke ip link show tun0 >/dev/null 2>&1; then break; fi
 sleep 0.2
done
if ip netns exec smoke ip link show tun0 >/dev/null 2>&1; then exit 20; fi
# The endpoint remains directly reachable, but proxy egress must now fail closed.
test "$(curl --fail --silent --max-time 3 --noproxy '*' http://198.51.100.9:18080/)" = 192.0.2.2
if curl --fail --silent --max-time 2 --noproxy '' \
    --socks5-hostname 10.200.200.2:1080 http://198.51.100.9:18080/; then exit 21; fi
netns_stop smoke
netns_stop smoke
test "$(ip route)" = "$before"
test "$(ip -6 route)" = "$before6"
test "$(sysctl -n net.ipv4.ip_forward)" = "$forward_before"
test "$(iptables -S; iptables -t nat -S)" = "$firewall_before"
test ! -d /etc/netns/smoke
test ! -d "$DATA_DIR/netns/smoke"
test "$(ip netns list | cut -d' ' -f1)" = peer
'''
            env = os.environ.copy()
            env.update(PATH=f'{bindir}:{env["PATH"]}', WORK=temp, REPO=str(checkout),
                       XDG_DATA_HOME=str(work / 'data'))
            result = subprocess.run(['unshare', '-Urnm', 'bash', '-c', script],
                                    env=env, capture_output=True, text=True, timeout=45)
            logs = '\n'.join(f'{path.name}:\n{path.read_text(errors="replace")}'
                             for path in work.rglob('*.log'))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr + logs)


if __name__ == '__main__':
    unittest.main()

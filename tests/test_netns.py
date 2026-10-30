"""Kernel lifecycle tests in disposable user/network/mount namespaces.

No host network changes or real VPN servers are used. The OpenVPN fixture
creates a dummy tun0; transport encryption/exit IP need a real VPN smoke test.
"""
import importlib.util
import os
from pathlib import Path
import socket
import shutil
import shutil
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("socks", ROOT / "netns-socks5.py")
socks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(socks)


class SocksTests(unittest.TestCase):
    def test_rejects_unsupported_auth(self):
        client, server = socket.socketpair()
        worker = threading.Thread(target=socks.handle_client, args=(server,))
        worker.start()
        client.sendall(b"\x05\x01\x02")
        self.assertEqual(client.recv(2), b"\x05\xff")
        client.close()
        worker.join(2)
        self.assertFalse(worker.is_alive())

    def test_fragmented_handshake_and_relay(self):
        echo = socket.socket()
        echo.bind(("127.0.0.1", 0))
        echo.listen()
        port = echo.getsockname()[1]

        def respond():
            conn, _ = echo.accept()
            with conn:
                conn.sendall(conn.recv(20))
            echo.close()

        responder = threading.Thread(target=respond)
        responder.start()
        client, server = socket.socketpair()
        worker = threading.Thread(target=socks.handle_client, args=(server,))
        worker.start()
        for byte in b"\x05\x01\x00":
            client.sendall(bytes([byte]))
        self.assertEqual(socks.recv_exact(client, 2), b"\x05\x00")
        request = b"\x05\x01\x00\x01\x7f\x00\x00\x01" + port.to_bytes(2, "big")
        for byte in request:
            client.sendall(bytes([byte]))
        self.assertEqual(socks.recv_exact(client, 10)[:2], b"\x05\x00")
        client.sendall(b"hello")
        self.assertEqual(socks.recv_exact(client, 5), b"hello")
        client.close()
        worker.join(2)
        responder.join(2)
        self.assertFalse(worker.is_alive())


class NetnsKernelTests(unittest.TestCase):
    def test_lifecycle_and_fail_closed_egress(self):
        if not shutil.which("unshare"):
            self.skipTest("unshare unavailable")
        for command in ('unshare', 'ip', 'iptables', 'openvpn', 'curl', 'flock'):
            if not shutil.which(command):
                self.skipTest(f'{command} is unavailable')
        if not all(Path(p).is_dir() for p in ('/etc/netns', '/run/netns')):
            self.skipTest('Create /etc/netns and /run/netns before running kernel tests')
        probe = subprocess.run(["unshare", "-Urnm", "true"], capture_output=True)
        if probe.returncode:
            self.skipTest("unprivileged user/network/mount namespaces unavailable")
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            # sudo CI maps host UID 0 into the user namespace; the original
            # checkout may belong to an unmapped runner UID with private paths.
            # Copy inputs while still privileged into this caller-owned fixture.
            checkout = work / 'checkout'
            checkout.mkdir()
            for source in ('vpngate-manager.sh', 'netns-socks5.py'):
                shutil.copyfile(ROOT / source, checkout / source)
            bindir = work / "bin"
            bindir.mkdir()
            (bindir / "sudo").write_text('''#!/bin/sh
if [ "${FIXTURE_SETUP_FAIL:-}" = 1 ] && [ "$1 $2 $3 $4" = 'iptables -t nat -N' ]; then exit 1; fi
if [ "${FIXTURE_NAMESPACE_RACE:-}" = 1 ] && [ "$1 $2 $3" = 'ip netns add' ]; then
 "$@"
 exit 1
fi
if [ "${FIXTURE_QUERY_FAIL:-}" = 1 ] && [ "$1 $2 $3 $4" = 'iptables -t nat -S' ]; then exit 1; fi
if [ "${FIXTURE_SYSCTL_FAIL:-}" = 1 ] && [ "$1 $2" = 'sysctl -n' ]; then exit 1; fi
exec "$@"
''')
            (bindir / "openvpn").write_text('''#!/bin/bash
while [ "$#" -gt 0 ]; do
 case "$1" in
 --log) log="$2"; shift;;
 --writepid) pid="$2"; shift;;
 esac
 shift
done
if [ "${FIXTURE_AUTH_FAIL:-}" = 1 ]; then
 echo AUTH_FAILED > "$log"
 exit 0
fi
ip link add tun0 type dummy
ip link set tun0 up
ip route add 0.0.0.0/1 dev tun0
ip route add 128.0.0.0/1 dev tun0
sleep 120 >/dev/null 2>&1 &
echo $! > "$pid"
echo 'Initialization Sequence Completed' > "$log"
''')
            for executable in bindir.iterdir():
                executable.chmod(0o755)
            (work / "vpn.ovpn").write_text("client\nremote 198.51.100.1 1194\n")
            (work / 'http-fixture.py').write_text('''import http.server
import socket
socket.getfqdn = lambda name: 'fixture'
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'fixture ready'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
http.server.HTTPServer(('0.0.0.0', 18080), Handler).serve_forever()
''')
            script = r'''
set -e
mount --make-rprivate /
mount -t tmpfs tmpfs /run/netns
mount -t tmpfs tmpfs /etc/netns
ip link set lo up
ip link add uplink type dummy
ip addr add 192.0.2.2/24 dev uplink
ip link set uplink up
ip route add default via 192.0.2.1
source <(sed '/^case "${1:-help}" in/,$d' "$REPO/vpngate-manager.sh")
SCRIPT_DIR="$REPO"
resolve_ovpn_for_exec() { echo "$WORK/vpn.ovpn"; }
before=$(ip route)
before6=$(ip -6 route)
forward=$(sysctl -n net.ipv4.ip_forward)
sleep 120 &
unrelated=$!
trap 'kill "$unrelated" 2>/dev/null || true' EXIT
netns_start '' smoke
ip netns exec smoke iptables -C OUTPUT -o tun0 -j ACCEPT
ip netns exec smoke iptables -S OUTPUT | grep -- '-P OUTPUT DROP'
# Return a literal response without resolving names or reading the original
# working directory, which may be inaccessible after user-namespace UID mapping.
python3 -u "$WORK/http-fixture.py" > "$WORK/http.log" 2>&1 &
server=$!
trap 'kill "$unrelated" "$server" 2>/dev/null || true' EXIT
# Wait for the HTTP listener rather than assuming a fixed startup duration.
ready=0
for attempt in $(seq 1 20); do
 if curl --fail --silent --max-time 1 --noproxy '*' http://10.200.200.1:18080/ >/dev/null; then ready=1; break; fi
 if ! kill -0 "$server" 2>/dev/null; then cat "$WORK/http.log"; exit 22; fi
 sleep 0.1
done
if [ "$ready" != 1 ]; then cat "$WORK/http.log"; exit 23; fi
# The same reachable server must be inaccessible through the proxy, even while tun0 exists.
if curl --silent --max-time 2 --noproxy '' --socks5-hostname 10.200.200.2:1080 http://10.200.200.1:18080/; then exit 9; fi
ip netns exec smoke ip link del tun0
# A lost tunnel must not allow proxy connections to the host's normal route.
if curl --silent --max-time 2 --noproxy '' --socks5-hostname 10.200.200.2:1080 http://10.200.200.1:18080/; then exit 10; fi
# A query/backend failure is not absence; retain recoverable state and resources.
if FIXTURE_QUERY_FAIL=1 netns_stop smoke; then exit 18; fi
test -f "$(netns_dir smoke)/owned"
ip netns list | grep '^smoke'
if FIXTURE_SYSCTL_FAIL=1 netns_stop smoke; then exit 19; fi
test -f "$(netns_dir smoke)/owned"
ip netns list | grep '^smoke'
netns_stop smoke
netns_stop smoke
kill -0 "$unrelated"
test "$(ip route)" = "$before"
test "$(ip -6 route)" = "$before6"
test "$(sysctl -n net.ipv4.ip_forward)" = "$forward"
test -z "$(ip netns list)"
test ! -d /etc/netns/smoke
# Authentication rejection rolls back immediately (the old loop waited 60s).
start=$SECONDS
if FIXTURE_AUTH_FAIL=1 netns_start '' rejected; then exit 11; fi
test $((SECONDS-start)) -le 10
test "$(ip route)" = "$before"
test -z "$(ip netns list)"
# A mid-setup firewall failure also removes every resource already created.
if FIXTURE_SETUP_FAIL=1 netns_start '' failed; then exit 12; fi
test "$(ip route)" = "$before"
test -z "$(ip netns list)"
test ! -d /etc/netns/failed
# Broad and narrow overlaps must be rejected without mutating the route table.
for collision in 10.200.0.0/16 10.200.200.2/32 0.0.0.0/1; do
 ip route add "$collision" dev uplink
 if netns_start '' overlap; then exit 13; fi
 test -z "$(ip netns list)"
 ip route del "$collision" dev uplink
done
# Failure to create a namespace must not make rollback delete a foreign one.
if FIXTURE_NAMESPACE_RACE=1 netns_start '' raced; then exit 14; fi
ip netns list | grep '^raced'
ip netns del raced
# Existing interface and chain collisions survive failed startup unchanged.
read -r foreign_veth unused <<< "$(netns_iface_names linkcollision)"
ip link add "$foreign_veth" type dummy
if netns_start '' linkcollision; then exit 15; fi
ip link show "$foreign_veth"
ip link del "$foreign_veth"
foreign_chain=$(netns_chain_name chaincollision)
ip netns list
iptables -t nat -N "$foreign_chain"
iptables -t nat -A "$foreign_chain" -j RETURN
if netns_start '' chaincollision; then exit 16; fi
iptables -t nat -C "$foreign_chain" -j RETURN
iptables -t nat -F "$foreign_chain"
iptables -t nat -X "$foreign_chain"
for malformed in ../smoke /smoke 'bad name' ''; do
 if [ -n "$malformed" ] && netns_stop "$malformed"; then exit 17; fi
done
test "$(ip route)" = "$before"
# A foreign namespace cannot be removed by this application's stop command.
ip netns add foreign
netns_stop foreign
ip netns list | grep '^foreign'
ip netns del foreign
'''
            env = os.environ.copy()
            env.update(PATH=f"{bindir}:{env['PATH']}", WORK=temp, REPO=str(checkout),
                       XDG_DATA_HOME=str(work / "data"))
            result = subprocess.run(["unshare", "-Urnm", "bash", "-c", script],
                                    env=env, capture_output=True, text=True, timeout=35)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

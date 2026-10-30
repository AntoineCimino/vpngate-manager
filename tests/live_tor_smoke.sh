#!/bin/bash
set -e
# This opt-in test modifies only a disposable container's networking/DNS.
# Tailscale itself is represented by a deterministic CLI/DNS fixture.
if [ ! -f /.dockerenv ] || [ "${VPNGATE_LIVE_TEST:-}" != 1 ]; then
    echo 'Run only in the documented disposable Docker test container.' >&2
    exit 1
fi
before=$(ip route)
before6=$(ip -6 route)
firewall=$(iptables -t nat -S)
cp /etc/resolv.conf /tmp/original-resolv
ip addr add 100.100.100.100/32 dev lo
cat > /usr/local/bin/tailscale <<'PY'
#!/usr/bin/python3
import json, pathlib, sys
state = pathlib.Path('/tmp/tailscale-prefs')
args = sys.argv[1:]
if args == ['debug', 'prefs']:
 print(json.dumps({'CorpDNS': not state.exists(), 'WantRunning': True}))
elif args == ['set', '--accept-dns=false']:
 state.touch()
 pathlib.Path('/etc/resolv.conf').write_bytes(pathlib.Path('/tmp/original-resolv').read_bytes())
elif args == ['set', '--accept-dns=true']:
 state.unlink(missing_ok=True)
 pathlib.Path('/etc/resolv.conf').write_text('# fixture Tailscale DNS\nnameserver 100.100.100.100\n')
else:
 sys.exit(2)
PY
chmod 755 /usr/local/bin/tailscale
python3 - <<'PY' >/tmp/dns-fixture.log 2>&1 &
import socket
upstream = next(l.split()[1] for l in open('/tmp/original-resolv') if l.startswith('nameserver'))
server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
server.bind(('100.100.100.100', 53))
while True:
 data, addr = server.recvfrom(4096)
 try:
  with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
   s.settimeout(3)
   s.sendto(data, (upstream, 53))
   response, _ = s.recvfrom(4096)
  server.sendto(response, addr)
 except OSError:
  pass
PY
dns_pid=$!
trap 'bash /repo/vpngate-manager.sh stop; kill "$dns_pid" 2>/dev/null || true' EXIT
printf '# fixture Tailscale DNS\nnameserver 100.100.100.100\n' >/etc/resolv.conf
bash /repo/vpngate-manager.sh tor US -f >/tmp/tor-session.log 2>&1 &
manager=$!
for attempt in $(seq 1 60); do
 if grep -q 'Transparent DNS/TCP path verified' /tmp/tor-session.log; then break; fi
 if ! kill -0 "$manager" 2>/dev/null; then cat /tmp/tor-session.log; exit 1; fi
 sleep 1
done
grep -q 'Transparent DNS/TCP path verified' /tmp/tor-session.log
python3 - <<'PY'
import json, subprocess
prefs=json.loads(subprocess.check_output(['tailscale','debug','prefs']))
assert prefs['CorpDNS'] is False
PY
curl --fail --silent --show-error --max-time 20 --noproxy '*' https://check.torproject.org/api/ip
# A different invocation must be able to stop foreground mode.
bash /repo/vpngate-manager.sh stop
for attempt in $(seq 1 10); do
 kill -0 "$manager" 2>/dev/null || break
 sleep 1
done
if kill -0 "$manager" 2>/dev/null; then echo 'Foreground manager did not exit' >&2; exit 1; fi
wait "$manager"
python3 - <<'PY'
import json, subprocess
prefs=json.loads(subprocess.check_output(['tailscale','debug','prefs']))
assert prefs['CorpDNS'] is True
PY
grep -q '100.100.100.100' /etc/resolv.conf
test "$(ip route)" = "$before"
test "$(ip -6 route)" = "$before6"
test "$(iptables -t nat -S)" = "$firewall"
test ! -e /tmp/vpngate-state/.active_mode
test ! -e /tmp/vpngate-state/tor-dns.json
echo LIVE_TOR_DNS_FIXTURE_AND_FOREGROUND_STOP_PASSED

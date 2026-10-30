# Optional Cloudflare DNS

Use `vpn dns benchmark` before choosing a resolver. DNS can improve the time
needed to find a site's IP address; it does not increase the bandwidth of a
VPN tunnel or your ISP connection. This mode creates no tunnel and leaves your
normal routes and public IP in place. Existing VPNs must be stopped explicitly.

```bash
vpn dns benchmark --samples 9  # read-only, no sudo
vpn dns status                 # read-only
vpn dns enable                 # requests sudo for DNS changes
vpn dns restore                # restores the saved DNS configuration
```

The helper is also usable directly:

```bash
python3 cloudflare-dns.py benchmark --samples 9
sudo python3 cloudflare-dns.py enable
sudo python3 cloudflare-dns.py restore
```

## Supported systems and restoration

Automatic changes support a single Ethernet/Wi-Fi default-route uplink managed
by NetworkManager 1.42 or newer (`nmcli` and `busctl` are required). Plain NetworkManager DNS and NetworkManager using
systemd-resolved are supported when no conflicting private DNS configuration is
present. Standalone systemd-resolved, other DNS managers, multiple uplinks,
active Tor/OpenVPN/tunnel connections, Tailscale-managed DNS, and DNS search or
split DNS domains are refused with an explanation. Configure unsupported DNS
managers through their native tools. The helper never overwrites
`/etc/resolv.conf` or disables Tailscale.

On a supported connection, `enable` saves the exact original IPv4/IPv6 DNS
addresses and automatic-DNS flags from the applied connection through NetworkManager's D-Bus API in
`/var/lib/vpngate-manager/cloudflare-dns/state.json`, then changes only the active device's DNS fields through the NetworkManager
applied-connection API. The request uses a version guard against concurrent
changes and the `preserve-external-ip` flag to retain independently added
addresses and routes. It never modifies or reapplies the persisted connection
profile, so unrelated pending profile changes remain unapplied. It selects `1.1.1.1` and `1.0.0.1`,
and, when IPv6 is enabled, `2606:4700:4700::1111` and
`2606:4700:4700::1001`. It leaves disabled IPv6 settings unchanged.
The saved configuration is root-managed; concurrent mutations are locked.
The override is temporary: reconnecting or rebooting ends it. Run `restore`
to restore the saved active DNS settings and clear recovery state before
enabling again. Persistent connection profiles are unchanged.

Repeated enable/restore calls are safe. Failed enable attempts try to restore
the original settings immediately. If recovery fails, the snapshot remains
available: reconnect the original uplink and run `vpn dns restore`. Restoration
refuses to overwrite a later external DNS configuration change. If that happens,
review the saved snapshot and the connection's current applied settings manually. A newly started VPN/Tor/Tailscale session
or private DNS policy must be resolved explicitly before restoration can proceed.
Do not delete the snapshot until the desired original DNS configuration has
been restored.

The helper checks routes before and after applying DNS; it never issues route
mutation commands or disconnects/reconnects an interface. Independent network
changes during the operation can cause the check to fail; DNS recovery retains
its snapshot when the result needs inspection.

## Feasibility measurement (2026-10-30)

A read-only run of `python3 cloudflare-dns.py benchmark --samples 9` alternated
nine UDP DNS queries per resolver across `example.com`, `cloudflare.com`, and
`github.com` on the development machine:

| Resolver | Median lookup time | Successful samples |
|---|---:|---:|
| Existing Tailscale MagicDNS resolver | 1.902 ms | 9/9 |
| Cloudflare `1.1.1.1` directly | 5.140 ms | 9/9 |

Cloudflare was reachable but slower in this small local sample. Keeping the
current resolver is the recommendation for this machine, especially because
replacing MagicDNS would disrupt private names. No resolver, route, VPN, Tor,
or Tailscale setting was changed for the measurement. Cached queries, resolver
location, and load influence these timings; repeat the benchmark on your own
network. This is not a bandwidth benchmark, and no throughput increase is
claimed. A live direct-versus-VPN throughput comparison was not run because
starting a host-wide tunnel would affect the user's connectivity.

## DNS, encryption, and WARP

This helper configures ordinary resolver addresses. It does not automatically
enable DNS-over-HTTPS or DNS-over-TLS, does not hide your public IP, and does not
provide anonymity, country selection, or a way around ISP bandwidth limits.
Applications using their own DNS settings may ignore the system resolver.

Cloudflare's WARP client is a separate product with DNS-only and traffic-tunnel
modes; it is not installed or enabled by this feature. If you need a tunnel,
evaluate WARP separately rather than assuming a DNS change provides one.

Official references checked for this implementation:

- [Cloudflare's Linux DNS setup and resolver addresses](https://developers.cloudflare.com/1.1.1.1/setup/linux/)
- [Cloudflare WARP modes and their limits](https://developers.cloudflare.com/warp-client/warp-modes/)

- [NetworkManager nmcli device modify](https://networkmanager.dev/docs/api/latest/nmcli.html)
- [NetworkManager applied device connection API](https://networkmanager.dev/docs/api/latest/gdbus-org.freedesktop.NetworkManager.Device.html)

## Disposable NetworkManager integration test

The unit suite uses fake commands. A separate integration fixture exercises the
actual NetworkManager D-Bus serializer, enable/status/restore, repeated calls,
preservation of independently added IP addresses/routes, and preservation of
unapplied persistent profile edits. It requires Docker and runs with no external
network and a read-only repository mount. Its guard refuses the host and
containers with pre-existing interfaces besides loopback.

Build an image containing the test dependencies, then run the fixture:

```bash
docker build -t vpngate-dns-test - <<'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends network-manager dbus systemd iproute2 python3 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
docker run --rm --network none --cap-add NET_ADMIN --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined -e VPNGATE_DISPOSABLE_DNS_TEST=1 \
  --mount "type=bind,src=$PWD,dst=/repo,readonly" \
  vpngate-dns-test bash /repo/tests/integration_cloudflare_dns.sh
```

# VPNGate Manager

A lightweight Bash CLI to browse, download, and connect to VPNGate OpenVPN servers from the terminal.

- Interactive VPN server selection
- Local `.ovpn` file support
- Background and foreground modes
- Tor exit node mode for country-specific anonymization
- Cache, logs, and PID management
- Bash CLI with small Python standard-library helpers

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Bash](https://img.shields.io/badge/bash-5%2B-green.svg)
![Contributions Welcome](https://img.shields.io/badge/contributions-welcome-brightgreen.svg)

## Features

- Browse public VPNGate servers from the terminal
- Filter servers by country
- Download and reuse OpenVPN configs locally
- Run VPN in background or foreground
- Route traffic through a country-specific Tor exit node when VPNGate has no server there
- Check status, logs, and active connection info
- Configurable data directory for cache, configs, logs, and recovery state
- Isolated VPN namespaces, reversible DNS settings, and automated regression tests

## Installation

```bash
git clone https://github.com/AntoineCimino/vpngate-manager.git
cd vpngate-manager
bash install.sh
```

The installer detects your package manager and installs the required dependencies, then copies the script to `/usr/local/bin/vpn`.

Supported package managers: `dnf` (Fedora, RHEL), `apt` (Debian, Ubuntu, LMDE), `pacman` (Arch).

Then just run:

```bash
vpn start
```

Cache, logs, and downloaded configs are stored in `~/.local/share/vpngate-manager/`.

### Manual install

```bash
git clone https://github.com/AntoineCimino/vpngate-manager.git
cd vpngate-manager
sudo install -m 755 vpngate-manager.sh /usr/local/bin/vpn
sudo install -m 755 netns-socks5.py tor-dns.py cloudflare-dns.py /usr/local/bin/
```

### Optional: passwordless sudo

OpenVPN requires root. To avoid typing your password every time:

```bash
sudo visudo
```

Add this line (replace `YOUR_USERNAME`):

```text
YOUR_USERNAME ALL=(root) NOPASSWD: /usr/sbin/openvpn, /usr/bin/sysctl
```

If you also plan to use Tor mode, extend the line to include `tor` and `iptables`:

```text
YOUR_USERNAME ALL=(root) NOPASSWD: /usr/sbin/openvpn, /usr/bin/sysctl, /usr/bin/tor, /usr/sbin/iptables
```

## Requirements

- bash
- curl
- openvpn
- sudo
- iproute2
- base64
- python3 (standard library only)
- util-linux (`flock`, for serialized lifecycle operations)

Optional, only required for Tor mode:

- tor
- iptables

Optional, only required for `exec` (per-command VPN, see below):

- [vopono](https://github.com/jamesmcm/vopono)

## Usage

```bash
./vpngate-manager.sh start
./vpngate-manager.sh start japan
./vpngate-manager.sh start -f
./vpngate-manager.sh local
./vpngate-manager.sh tor US
./vpngate-manager.sh exec -- curl ifconfig.me
./vpngate-manager.sh status
./vpngate-manager.sh logs
./vpngate-manager.sh stop
```

### Per-command VPN (`exec`)

`start`/`local`/`tor` route the whole system's traffic. `exec` instead runs a single
command through the VPN in an isolated network namespace, via
[vopono](https://github.com/jamesmcm/vopono) — the rest of the system is unaffected.
A matching server is picked automatically (non-interactive), so it's safe to call
from another script or program:

```bash
./vpngate-manager.sh exec -- curl ifconfig.me   # any VPNGate server
./vpngate-manager.sh exec japan -- firefox      # forced through a Japanese server
```

### Persistent isolated VPN (`netns-start`)

Use namespace mode for automation that needs a persistent SOCKS5 endpoint:

```bash
sudo vpn netns-start japan scraper-vpn 1
curl --socks5-hostname 10.200.200.2:1080 https://api.ipify.org
sudo vpn netns-status scraper-vpn
sudo vpn netns-stop scraper-vpn
```

Requires Linux, iproute2, iptables, OpenVPN, Python 3, and util-linux (`flock`).
The installer installs the proxy helper alongside `vpn`; for a manual install,
copy `netns-socks5.py` to `/usr/local/bin/` too. Use the same user and data
directory for start/status/stop. Only one managed namespace is supported at a
time. The dedicated `10.200.200.0/30` link adds a connected host route while
active; existing routes and the host default route remain unchanged. Stop
removes the link and scoped firewall rules and restores IP forwarding.

Use `--socks5-hostname` (or `socks5h://`) so DNS also travels through the VPN.
The proxy accepts only connections from the host link and has no authentication;
do not forward its port to other machines. Namespace egress is blocked unless
it uses the VPN tunnel, including after tunnel failure. OpenVPN's marked control
traffic is the only exception. Startup waits for OpenVPN initialization and a
working SOCKS handshake; failures roll back setup. Namespace mode requires
numeric IPv4 server addresses in the VPNGate profile. `stop` affects the host
VPN/Tor session; use `netns-stop` to stop the isolated session.

### Explicit server selection for scripts

`start --auto [country]` selects the first matching server without prompting;
`local --file PATH [-f]` uses an explicit local profile. They retain the
host-wide behavior of `start`/`local`. Existing-session replacement still
requires explicit confirmation; unattended callers fail rather than replace it.
Use `netns-start` or `exec` for jobs that must preserve the host's connectivity.

### Optional Cloudflare DNS

```bash
vpn dns benchmark --samples 9
vpn dns status
vpn dns enable
vpn dns restore
```

This is a direct-connection DNS option, with no VPN tunnel or country change.
Benchmark first: DNS lookup speed and connection bandwidth are different.
Supported NetworkManager connections get a reversible, temporary DNS override;
Tailscale/private-DNS/tunnel conflicts are refused. See
[compatibility, measurements, and recovery](docs/cloudflare-dns.md).

## Tor Mode

When VPNGate has no server in the region you need, `tor <country_code>` routes your traffic
through a Tor exit node in that country instead:

```bash
./vpngate-manager.sh tor US
./vpngate-manager.sh tor DE -f   # foreground mode, tails the tor log
```

Before launching anything, the script validates the environment: it checks that `tor` and
`iptables` are installed, that `iptables` is actually functional (not an nftables-only system
without legacy compatibility), and queries the public Tor relay directory to warn you if no exit
relay is currently known for the requested country.

Traffic is redirected through an isolated `VPNGATE_TOR` iptables chain - your existing iptables
rules are never modified. `stop` (or Ctrl+C in foreground mode) removes the chain and stops the
Tor daemon cleanly. Tor uses a dedicated non-root service account so the
firewall's Tor-process exemption cannot exempt all root traffic. Startup
verifies the ordinary DNS/TCP path with the Tor Project API and rolls back on
failure. Original per-interface IPv6 values are saved and restored.

When Tailscale manages DNS, Tor mode temporarily releases that DNS setting and
restores it on stop or failed startup. MagicDNS/private names can be unavailable
until stop; namespace mode preserves host DNS. See [Tor DNS and recovery](docs/tor-dns.md).

OpenVPN and Tor mode are mutually exclusive: starting one while the other is active will prompt
you to stop it first.

**Requirements:** `tor`, `iptables`.

**Limitations:**

- Only TCP and DNS (UDP/53) traffic is routed through Tor; other UDP traffic is **not** transparently
  proxied and leaks outside the Tor tunnel (a known Tor limitation, not specific to this tool).
- Forcing a specific exit country (`StrictNodes 1`) reduces anonymity compared to letting Tor pick
  exit nodes freely - use it only when you specifically need a given country's exit IP.
- This is a transparent SOCKS/DNS proxy setup, not a hardened anonymity solution (no Tails-level
  isolation). Use Tor Browser instead if strong anonymity is the goal.

## Maintenance

Cache, PID, logs, and downloaded `.ovpn` files are stored in `~/.local/share/vpngate-manager/`.
Override the directory with an absolute `VPNGATE_DATA_DIR` (or set `XDG_DATA_HOME`):

```bash
VPNGATE_DATA_DIR="$HOME/vpn-configs" vpn refresh
vpn purge
```

Use the same directory for start, status and stop. `purge` removes cached lists,
downloaded/local `.ovpn` files and inactive logs, while preserving unrelated
files. It refuses to run while session or DNS/IPv6/namespace recovery state
exists. Stop/restore first; never delete recovery records to force a purge.

## Windows compatibility

This project requires Linux networking (`ip netns`, TUN, iptables and sysctl).
WSL2 can work with a kernel that exposes those features and the required
privileges; install Linux dependencies inside the distribution. Verify
`test -c /dev/net/tun`, `ip netns list`, and `sudo iptables -t nat -S` before use.
NetworkManager DNS controls are available only when NetworkManager manages the
WSL connection. Tor/VPN routing inside WSL2 does not route Windows applications
through the tunnel; use the explicit SOCKS proxy from Windows if appropriate.
WSL1 and native Git Bash lack the required Linux network namespaces and are
unsupported. WSL2 has not been validated in CI.

## Demo

Preview:

![Demo](./docs/demo.gif)

There is also an asciinema recording in `docs/demo.cast`:

```bash
asciinema play docs/demo.cast
```

## Why this project?

VPNGate Manager is designed to stay simple:

- a Bash entry point and small Python standard-library helpers
- no heavy framework
- easy to inspect and modify
- portable across Linux systems
- practical for power users and homelab environments

## Security Notice

This tool downloads public VPN server data from VPNGate and uses OpenVPN configs provided by that network.

Please note:

- VPNGate is a public volunteer-driven network
- server trust varies
- this tool does not audit or verify the trustworthiness of individual VPN nodes
- use it with caution for sensitive traffic

## License

MIT. See `LICENSE`.
## Development and backlog

```bash
bash -n vpngate-manager.sh install.sh
python3 -m unittest discover -s tests -v
```

Kernel integration tests use disposable user/network/mount namespaces and local
fixtures, including a real OpenVPN TLS server. They skip where the kernel or
required tools (`unshare`, `ip`, `iptables`, OpenVPN, OpenSSL, curl, TUN) are
unavailable. They never change the host's routes or use public VPN servers.
See [ROADMAP.md](ROADMAP.md) for delivery status and remaining validation.

Optional public-network Tor smoke test (Docker required):

```bash
docker build -t vpngate-integration -f tests/Dockerfile.integration .
docker run --rm --cap-add NET_ADMIN --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  --sysctl net.ipv6.conf.all.disable_ipv6=1 \
  --sysctl net.ipv6.conf.default.disable_ipv6=1 \
  -v "$PWD:/repo:ro" -e VPNGATE_DATA_DIR=/tmp/vpngate-state \
  -e VPNGATE_LIVE_TEST=1 vpngate-integration bash /repo/tests/live_tor_smoke.sh
```

This test starts real Tor in the container, verifies ordinary DNS/TCP reaches a
Tor exit, checks foreground stop from a second invocation, and verifies route,
firewall and DNS restoration. Tailscale preference changes and MagicDNS are
represented by a local fixture; it does not log in to a real tailnet or prove
the original host-specific resolver diagnosis. No host networking is mounted
or modified. Do not use host networking for this test.

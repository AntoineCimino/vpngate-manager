# VPNGate Manager

A lightweight Bash CLI to browse, download, and connect to VPNGate OpenVPN servers from the terminal.

- Interactive VPN server selection
- Local `.ovpn` file support
- Background and foreground modes
- Tor exit node mode for country-specific anonymization
- Cache, logs, and PID management
- Simple, single-file Bash script

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
- Store everything next to the script for portability
- Single-file Bash implementation

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
sudo cp vpngate-manager.sh /usr/local/bin/vpn
sudo chmod +x /usr/local/bin/vpn
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

Optional, only required for Tor mode:

- tor
- iptables

## Usage

```bash
./vpngate-manager.sh start
./vpngate-manager.sh start japan
./vpngate-manager.sh start -f
./vpngate-manager.sh local
./vpngate-manager.sh tor US
./vpngate-manager.sh status
./vpngate-manager.sh logs
./vpngate-manager.sh stop
```

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
Tor daemon cleanly.

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

## Windows compatibility

This project is designed for Linux.

## Demo

Preview:

![Demo](./docs/demo.gif)

There is also an asciinema recording in `docs/demo.cast`:

```bash
asciinema play docs/demo.cast
```

## Why this project?

VPNGate Manager is designed to stay simple:

- one Bash file
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
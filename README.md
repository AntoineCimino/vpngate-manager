# VPNGate Manager

A lightweight Bash CLI to browse, download, and connect to VPNGate OpenVPN servers from the terminal.

- Interactive VPN server selection
- Local `.ovpn` file support
- Background and foreground modes
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

## Requirements

- bash
- curl
- openvpn
- sudo
- iproute2
- base64

## Usage

```bash
./vpngate-manager.sh start
./vpngate-manager.sh start japan
./vpngate-manager.sh start -f
./vpngate-manager.sh local
./vpngate-manager.sh status
./vpngate-manager.sh logs
./vpngate-manager.sh stop
```

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
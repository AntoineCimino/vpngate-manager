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
chmod +x vpngate-manager.sh
```

### Manual install (copy the script somewhere in your PATH)

If you want a manual install (no clone), you can copy the script to a user bin directory, make it executable, then call it via an alias.

- Copy the script:

```bash
mkdir -p "$HOME/.local/bin/vpngate"
cp vpngate-manager.sh "$HOME/.local/bin/vpngate/vpngate-manager.sh"
```

- Make it executable:

```bash
chmod +x "$HOME/.local/bin/vpngate/vpngate-manager.sh"
```

### Alias (bash / zsh)

Add an alias so you can run `vpn start` / `vpn stop` instead of typing the full path.

- **bash**: add this to `~/.bashrc`
- **zsh**: add this to `~/.zshrc`

```bash
alias vpn='sudo $HOME/.local/bin/vpngate/vpngate-manager.sh'
```

Example with an absolute path (as-is):

```bash
alias vpn='sudo /home/[USERNAME]/.local/bin/vpngate/vpngate-manager.sh'
```

Reload your shell config:

```bash
source ~/.bashrc  # or: source ~/.zshrc
```

Then you can use:

```bash
vpn start
vpn stop
vpn status
```

### Optional: bypass sudo password (sudoers / NOPASSWD)

If you don’t want to type your sudo password every time, you can allow passwordless sudo **only for this script**.

Edit sudoers safely with:

```bash
sudo visudo
```

Then add a line like (adapt the path and your username):

```text
[USERNAME] ALL=(root) NOPASSWD: /home/[USERNAME]/.local/bin/vpngate/vpngate-manager.sh
```

After that, `alias vpn='sudo ...'` will not prompt for a password (for this command only).

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

The script stores its cache, PID, logs, and downloaded `.ovpn` files next to `vpngate-manager.sh`.

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
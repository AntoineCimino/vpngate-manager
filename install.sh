#!/bin/bash
# vpngate-manager installer
# Supports: Fedora/RHEL (dnf), Debian/Ubuntu (apt), Arch (pacman)

set -e

INSTALL_PATH="/usr/local/bin/vpn"
SCRIPT="vpngate-manager.sh"
SOCKS_SCRIPT="netns-socks5.py"
# Some setups also keep a plain user-owned copy here (e.g. invoked directly by
# other projects via `sudo -n ~/.local/bin/vpngate/vpngate-manager.sh`,
# instead of through the /usr/local/bin/vpn wrapper installed below).
USER_INSTALL_DIR="$HOME/.local/bin/vpngate"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ ! -f "$SCRIPT" ]; then
    echo -e "${RED}❌ Run this script from inside the vpngate-manager directory${NC}"
    echo "   cd vpngate-manager && bash install.sh"
    exit 1
fi

echo -e "${CYAN}📦 Installing dependencies...${NC}"

if command -v dnf &>/dev/null; then
    sudo dnf install -y openvpn curl iproute iptables python3
elif command -v apt-get &>/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y openvpn curl iproute2 iptables python3
elif command -v pacman &>/dev/null; then
    sudo pacman -Sy --noconfirm openvpn curl iproute2 iptables python3
else
    echo -e "${RED}❌ Unsupported package manager. Install openvpn, curl, iproute, iptables, and python3 manually.${NC}"
    exit 1
fi

echo -e "${CYAN}📋 Installing vpn command to $INSTALL_PATH...${NC}"
sudo rm -f "$INSTALL_PATH"
sudo cp "$SCRIPT" "$INSTALL_PATH"
sudo chmod +x "$INSTALL_PATH"

if [ -d "$USER_INSTALL_DIR" ]; then
    echo -e "${CYAN}📋 Re-syncing existing plain copy at $USER_INSTALL_DIR...${NC}"
    cp "$SCRIPT" "$USER_INSTALL_DIR/$SCRIPT"
    cp "$SOCKS_SCRIPT" "$USER_INSTALL_DIR/$SOCKS_SCRIPT"
    chmod +x "$USER_INSTALL_DIR/$SCRIPT"
fi

echo -e "${GREEN}✅ Done!${NC}"
echo ""

SUDOERS_FILE="/etc/sudoers.d/vpngate-manager"
if [ ! -f "$SUDOERS_FILE" ]; then
    echo -e "${YELLOW}Optional: allow 'vpn start/stop' without typing your sudo password each time?${NC}"
    read -r -p "Configure passwordless sudo for vpn? [y/N] " answer
    if [[ "$answer" =~ ^[yY]$ ]]; then
        CURRENT_USER=$(whoami)
        SUDOERS_LINE="$CURRENT_USER ALL=(root) NOPASSWD: /usr/sbin/openvpn, /usr/bin/sysctl, /usr/bin/pkill, /bin/kill"
        echo "$SUDOERS_LINE" | sudo tee "$SUDOERS_FILE" > /dev/null
        sudo chmod 440 "$SUDOERS_FILE"
        echo -e "${GREEN}✅ Passwordless sudo configured${NC}"
    fi
fi

echo ""
echo "   vpn start          # browse and connect (host-wide, manual/interactive only)"
echo "   vpn start japan    # filter by country"
echo "   vpn status         # check connection"
echo "   vpn stop           # disconnect"
echo "   vpn netns-start japan   # isolated VPN in a netns (safe for scripts/agents), SOCKS5 proxy"
echo "   vpn netns-status        # check the netns VPN + proxy exit IP"
echo "   vpn netns-stop          # tear down the netns VPN"

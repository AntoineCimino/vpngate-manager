#!/bin/bash
# vpngate-manager.sh - Version 3.0 (Optimized Daemon)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/vpngate-manager"

CACHE_FILE="$DATA_DIR/.vpngate_cache.csv"
CACHE_MAX_AGE=3600  # 1 hour
LOG_FILE="$DATA_DIR/vpn.log"
PID_FILE="$DATA_DIR/vpn.pid"

# Tor mode files
TORRC_FILE="$DATA_DIR/torrc.tmp"
TOR_PID_FILE="$DATA_DIR/tor.pid"
TOR_LOG_FILE="$DATA_DIR/tor.log"
ACTIVE_MODE_FILE="$DATA_DIR/.active_mode"
IPTABLES_RULES_FILE="$DATA_DIR/.iptables_rules"
TOR_SOCKS_PORT=9050
TOR_TRANS_PORT=9040
TOR_DNS_PORT=5353
TOR_CHAIN="VPNGATE_TOR"

mkdir -p "$DATA_DIR"

# Display colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

function download_vpn_list() {
    echo -e "${CYAN}📥 Downloading the list of available VPN servers...${NC}"
    
    curl -s "http://www.vpngate.net/api/iphone/" -o "$CACHE_FILE"
    
    if [ $? -ne 0 ] || [ ! -s "$CACHE_FILE" ]; then
        echo -e "${RED}❌ Failed to download the VPN list${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ VPN list downloaded successfully${NC}"
    return 0
}

function get_vpn_list() {
    # Check whether the cache exists, is recent, and has real server entries
    if [ -f "$CACHE_FILE" ]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null)))
        if [ $cache_age -lt $CACHE_MAX_AGE ] && [ $(wc -l < "$CACHE_FILE") -gt 2 ]; then
            return 0
        fi
    fi

    download_vpn_list
}

function select_vpn() {
    local filter_country="$1"
    local mode="${2:-daemon}"  # daemon or foreground
    
    get_vpn_list || return 1
    
    # Create a temporary file to store VPN selection data
    local temp_data="$DATA_DIR/.vpn_selection_data"
    > "$temp_data"
    
    echo -e "${CYAN}🌍 Available VPN servers:${NC}\n"
    
    # Header
    printf "${BLUE}%-4s %-25s %-15s %-10s %-10s %-8s${NC}\n" \
        "No." "Country" "IP" "Speed" "Ping" "Sessions"
    echo "──────────────────────────────────────────────────────────────────────────────"
    
    local counter=1
    local line_num=0
    
    # Read and display VPN entries
    while IFS= read -r line; do
        ((line_num++))
        
        # Skip the first 2 header lines
        if [ $line_num -le 2 ]; then
            continue
        fi
        
        # Parse the first fields
        local ip=$(echo "$line" | cut -d',' -f2)
        local score=$(echo "$line" | cut -d',' -f3)
        local ping=$(echo "$line" | cut -d',' -f4)
        local speed=$(echo "$line" | cut -d',' -f5)
        local country_long=$(echo "$line" | cut -d',' -f6)
        local country_short=$(echo "$line" | cut -d',' -f7)
        local num_sessions=$(echo "$line" | cut -d',' -f8)
        
        # Ignore invalid lines
        if [ -z "$ip" ] || [ "$ip" = "IP" ]; then
            continue
        fi
        
        # Filter by country if specified
        if [ -n "$filter_country" ]; then
            local filter_upper=$(echo "$filter_country" | tr '[:lower:]' '[:upper:]')
            if [[ ! "$country_long" =~ $filter_country ]] && \
               [[ ! "$country_short" =~ $filter_upper ]]; then
                continue
            fi
        fi
        
        # Format speed
        local speed_mbps=0
        if [[ "$speed" =~ ^[0-9]+$ ]] && [ "$speed" -gt 0 ]; then
            speed_mbps=$((speed / 1000000))
        fi
        
        # Clean country name
        country_long=$(echo "$country_long" | sed 's/[^[:alnum:] ]//g')
        
        # Store: selection number, country, IP, line number in CSV
        echo "$counter|$country_short|$ip|$line_num" >> "$temp_data"
        
        # Display
        printf "%-4s %-25s %-15s %-10s %-10s %-8s\n" \
            "$counter" \
            "${country_long:0:25}" \
            "$ip" \
            "${speed_mbps} Mbps" \
            "${ping} ms" \
            "$num_sessions"
        
        ((counter++))
        
        if [ $counter -gt 100 ]; then
            break
        fi
        
    done < "$CACHE_FILE"
    
    if [ $counter -eq 1 ]; then
        echo -e "${YELLOW}No VPN servers found${NC}"
        rm -f "$temp_data"
        return 1
    fi
    
    echo ""
    echo -e "${YELLOW}Enter the number of the VPN you want to use (or 'q' to quit):${NC} "
    read -r selection
    
    if [ "$selection" = "q" ]; then
        rm -f "$temp_data"
        echo "Cancelled."
        return 1
    fi
    
    # Retrieve the data from the temporary file
    local vpn_line=$(grep "^$selection|" "$temp_data")
    
    if [ -z "$vpn_line" ]; then
        echo -e "${RED}❌ Invalid selection${NC}"
        rm -f "$temp_data"
        return 1
    fi
    
    IFS='|' read -r num country ip csv_line_num <<< "$vpn_line"
    
    echo -e "${CYAN}📥 Extracting configuration...${NC}"
    
    # Extract the full CSV line
    local full_line=$(sed -n "${csv_line_num}p" "$CACHE_FILE")
    
    # The last field is the base64 OpenVPN config
    local base64_data=$(echo "$full_line" | awk -F',' '{print $NF}')
    
    # Clean: remove spaces, tabs, line breaks
    base64_data=$(echo "$base64_data" | tr -d '[:space:]')
    
    # Decode and save
    local ovpn_file="$DATA_DIR/${country}-vpngate_${ip}_udp.ovpn"
    
    echo "$base64_data" | base64 -d 2>/dev/null | grep -v "^persist-key" > "$ovpn_file"

    if [ ! -s "$ovpn_file" ]; then
        echo -e "${RED}❌ Error while decoding the configuration${NC}"

        # Retry with --ignore-garbage
        echo "$base64_data" | base64 -d --ignore-garbage 2>/dev/null | grep -v "^persist-key" > "$ovpn_file"

        if [ ! -s "$ovpn_file" ]; then
            echo -e "${RED}❌ Decoding failed${NC}"
            rm -f "$temp_data" "$ovpn_file"
            return 1
        fi
    fi
    
    # Verify that the file looks like a valid OpenVPN configuration
    if ! grep -q "client" "$ovpn_file" 2>/dev/null; then
        echo -e "${RED}❌ The decoded file does not appear to be a valid OpenVPN configuration${NC}"
        rm -f "$temp_data" "$ovpn_file"
        return 1
    fi
    
    rm -f "$temp_data"
    echo -e "${GREEN}✅ Configuration downloaded: $ovpn_file${NC}"
    
    # Start the connection
    start_vpn "$ovpn_file" "$mode"
}

function list_local_vpns() {
    local mode="${1:-daemon}"
    
    echo -e "${CYAN}📁 Local VPN files:${NC}\n"
    
    local counter=1
    local temp_local="$DATA_DIR/.local_vpn_list"
    > "$temp_local"
    
    while IFS= read -r file; do
        local basename=$(basename "$file")
        
        echo "$counter|$file" >> "$temp_local"
        
        # Extract country and IP from filename
        if [[ $basename =~ ^([A-Z]+)-vpngate_([0-9.]+) ]]; then
            local country="${BASH_REMATCH[1]}"
            local ip="${BASH_REMATCH[2]}"
            printf "${GREEN}%-4s${NC} %-15s %-20s %s\n" "$counter" "$country" "$ip" "$basename"
        else
            printf "${GREEN}%-4s${NC} %s\n" "$counter" "$basename"
        fi
        
        ((counter++))
    done < <(find "$DATA_DIR" -name "*.ovpn" -type f 2>/dev/null | sort)
    
    if [ $counter -eq 1 ]; then
        echo -e "${YELLOW}No .ovpn file found${NC}"
        rm -f "$temp_local"
        return 1
    fi
    
    echo ""
    echo -e "${YELLOW}Enter the number of the VPN you want to use (or 'q' to quit):${NC} "
    read -r selection
    
    if [ "$selection" = "q" ]; then
        rm -f "$temp_local"
        return 1
    fi
    
    local selected_file=$(grep "^$selection|" "$temp_local" | cut -d'|' -f2)
    
    if [ -z "$selected_file" ]; then
        echo -e "${RED}❌ Invalid selection${NC}"
        rm -f "$temp_local"
        return 1
    fi
    
    rm -f "$temp_local"
    start_vpn "$selected_file" "$mode"
}

function start_vpn() {
    local ovpn_file="$1"
    local mode="${2:-daemon}"  # daemon by default
    
    if [ -z "$ovpn_file" ]; then
        echo -e "${RED}❌ No file specified${NC}"
        return 1
    fi
    
    if [ ! -f "$ovpn_file" ]; then
        echo -e "${RED}❌ File not found: $ovpn_file${NC}"
        return 1
    fi
    
    # Tor mode and OpenVPN are mutually exclusive
    if is_our_tor_running; then
        echo -e "${YELLOW}⚠️  Tor mode is currently active${NC}"
        echo -e "${YELLOW}Do you want to stop it and start OpenVPN instead? (y/N)${NC} "
        read -r response
        if [[ "$response" =~ ^[yY]$ ]]; then
            cleanup
            sleep 2
        else
            echo "Cancelled."
            return 1
        fi
    fi

    # Check whether a VPN is already running
    if pgrep -x openvpn > /dev/null; then
        echo -e "${YELLOW}⚠️  A VPN is already active${NC}"
        echo -e "${YELLOW}Do you want to stop it and start a new one? (y/N)${NC} "
        read -r response
        if [[ "$response" =~ ^[yY]$ ]]; then
            cleanup
            sleep 2
        else
            echo "Cancelled."
            return 1
        fi
    fi

    echo -e "${BLUE}📁 Using: $(basename "$ovpn_file")${NC}"

    # Mark openvpn as the active mode so stop/status/cleanup know what to clean up
    echo "openvpn" > "$ACTIVE_MODE_FILE"

    # Temporarily disable IPv6
    echo -e "${CYAN}🔧 Temporarily disabling IPv6...${NC}"
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
    sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
    sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null

    if [ "$mode" = "daemon" ]; then
        # Daemon mode (background)
        echo -e "${GREEN}🚀 Starting VPN in background...${NC}"
        
        # Clean up old files
        rm -f "$LOG_FILE" "$PID_FILE"
        
        # Start OpenVPN as daemon
        sudo openvpn --config "$ovpn_file" \
                     --data-ciphers AES-128-CBC:AES-256-CBC:AES-128-GCM:AES-256-GCM \
                     --daemon \
                     --log "$LOG_FILE" \
                     --writepid "$PID_FILE"
        
        # Wait for VPN connection
        echo -e "${CYAN}⏳ Connecting...${NC}"
        local max_wait=15
        local waited=0
        
        while [ $waited -lt $max_wait ]; do
            sleep 1
            ((waited++))
            
            # Check if tun0 exists
            if ip a | grep -q "tun0"; then
                echo -e "${GREEN}✅ VPN started successfully!${NC}\n"
                
                # Display information
                if [ -f "$PID_FILE" ]; then
                    echo -e "${CYAN}   📋 PID        : $(cat "$PID_FILE")${NC}"
                fi
                
                local vpn_ip=$(ip -4 addr show tun0 2>/dev/null | grep inet | awk '{print $2}')
                echo -e "${CYAN}   🌐 VPN IP     : $vpn_ip${NC}"
                
                local public_ip=$(timeout 5 curl -s --interface tun0 https://ifconfig.me 2>/dev/null)
                if [ -n "$public_ip" ]; then
                    echo -e "${CYAN}   🌍 Public IP  : $public_ip${NC}"
                fi
                
                echo -e "${CYAN}   📄 Logs       : $LOG_FILE${NC}"
                echo ""
                echo -e "${YELLOW}Useful commands:${NC}"
                echo -e "   ${GREEN}$0 status${NC}  - Show current status"
                echo -e "   ${GREEN}$0 logs${NC}    - Follow logs in real time"
                echo -e "   ${GREEN}$0 stop${NC}    - Stop the VPN"
                
                return 0
            fi
            
            # Check if the process crashed
            if [ -f "$PID_FILE" ]; then
                local vpn_pid=$(cat "$PID_FILE")
                if ! ps -p "$vpn_pid" > /dev/null 2>&1; then
                    echo -e "${RED}❌ VPN failed to start${NC}"
                    echo -e "${YELLOW}Last log lines:${NC}"
                    tail -n 10 "$LOG_FILE" 2>/dev/null | sed 's/^/   /'
                    cleanup
                    return 1
                fi
            fi
            
            printf "."
        done
        
        echo ""
        echo -e "${YELLOW}⚠️  The VPN is taking longer than expected to connect${NC}"
        echo -e "${YELLOW}Check the logs with: tail -f $LOG_FILE${NC}"
        
    else
        # Foreground mode (shows logs)
        echo -e "${GREEN}🚀 Starting VPN (foreground mode)...${NC}"
        echo -e "${YELLOW}   Press Ctrl+C to stop${NC}\n"
        
        # Trap to clean up on exit
        trap cleanup EXIT INT TERM
        
        sudo openvpn --config "$ovpn_file" \
                     --data-ciphers AES-128-CBC:AES-256-CBC:AES-128-GCM:AES-256-GCM
    fi
}

function cleanup_openvpn() {
    echo ""
    echo -e "${YELLOW}🛑 Stopping VPN...${NC}"

    # Read PID from file
    if [ -f "$PID_FILE" ]; then
        local vpn_pid=$(cat "$PID_FILE")
        if [ -n "$vpn_pid" ]; then
            sudo kill -TERM "$vpn_pid" 2>/dev/null
            sleep 2
            sudo kill -9 "$vpn_pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
    fi

    # Kill all openvpn processes just in case
    sudo pkill -TERM openvpn 2>/dev/null
    sleep 1
    sudo pkill -9 openvpn 2>/dev/null

    echo -e "${CYAN}🔧 Re-enabling IPv6...${NC}"
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
    sudo sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
    sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null

    rm -f "$ACTIVE_MODE_FILE"
    echo -e "${GREEN}✅ VPN stopped cleanly${NC}"
}

function cleanup() {
    # Route to the right cleanup logic depending on the currently active mode.
    # If no mode marker is present, do nothing silently (nothing to clean up).
    local active_mode=""
    if [ -f "$ACTIVE_MODE_FILE" ]; then
        active_mode=$(cat "$ACTIVE_MODE_FILE" 2>/dev/null)
    fi

    case "$active_mode" in
        tor)
            stop_tor
            ;;
        openvpn)
            cleanup_openvpn
            ;;
        *)
            # No active mode marker: fall back to checking for a leftover
            # process started by this script (own openvpn PID file, or own
            # tor PID file) so a previous crash still gets cleaned up. Never
            # target a system-wide tor/openvpn instance we did not start.
            if pgrep -x openvpn > /dev/null; then
                cleanup_openvpn
            elif is_our_tor_running; then
                stop_tor
            fi
            ;;
    esac
}

function status() {
    echo -e "${CYAN}📊 VPN status:${NC}\n"

    local active_mode="none"
    if [ -f "$ACTIVE_MODE_FILE" ]; then
        active_mode=$(cat "$ACTIVE_MODE_FILE" 2>/dev/null)
    fi
    echo -e "   ${BLUE}🔀 Active mode: ${active_mode}${NC}"

    if pgrep -x openvpn > /dev/null; then
        echo -e "   ${GREEN}✅ OpenVPN is running${NC}"

        if [ -f "$PID_FILE" ]; then
            local pid=$(cat "$PID_FILE")
            echo -e "   ${BLUE}📋 PID: $pid${NC}"
        fi

        if ip a | grep -q "tun0"; then
            local IP=$(ip -4 addr show tun0 2>/dev/null | grep inet | awk '{print $2}')
            echo -e "   ${BLUE}🌐 tun0 interface: $IP${NC}"

            echo -e "   ${CYAN}🔍 Checking public IP...${NC}"
            local PUBLIC_IP=$(timeout 5 curl -s --interface tun0 https://ifconfig.me 2>/dev/null)
            if [ -n "$PUBLIC_IP" ]; then
                echo -e "   ${GREEN}🌍 Public IP: $PUBLIC_IP${NC}"
            else
                echo -e "   ${YELLOW}⚠️  Unable to retrieve public IP${NC}"
            fi
        else
            echo -e "   ${YELLOW}⚠️  No tun0 interface detected${NC}"
        fi

        # Show the last log lines if available
        if [ -f "$LOG_FILE" ]; then
            echo ""
            echo -e "   ${CYAN}📄 Last log lines:${NC}"
            tail -n 5 "$LOG_FILE" 2>/dev/null | sed 's/^/      /'
        fi
    elif is_our_tor_running; then
        echo -e "   ${GREEN}✅ Tor is running${NC}"

        if [ -f "$TOR_PID_FILE" ]; then
            echo -e "   ${BLUE}📋 PID: $(cat "$TOR_PID_FILE")${NC}"
        fi

        local requested_country=""
        if [ -f "$TORRC_FILE" ]; then
            requested_country=$(grep -m1 "^ExitNodes" "$TORRC_FILE" | sed -E 's/^ExitNodes \{(.*)\}$/\1/')
        fi
        [ -n "$requested_country" ] && echo -e "   ${BLUE}🌐 Requested exit country: $requested_country${NC}"

        if [ -f "$TOR_LOG_FILE" ]; then
            if grep -q "Bootstrapped 100%" "$TOR_LOG_FILE" 2>/dev/null; then
                echo -e "   ${GREEN}🟢 Bootstrap: 100% (ready)${NC}"
            else
                echo -e "   ${YELLOW}🟡 Bootstrap: in progress${NC}"
            fi
        fi

        echo -e "   ${CYAN}🔍 Checking Tor exit IP...${NC}"
        verify_tor_exit_ip "$TOR_SOCKS_PORT"

        if [ -f "$TOR_LOG_FILE" ]; then
            echo ""
            echo -e "   ${CYAN}📄 Last log lines:${NC}"
            tail -n 5 "$TOR_LOG_FILE" 2>/dev/null | sed 's/^/      /'
        fi
    else
        echo -e "   ${RED}❌ No VPN or Tor mode is running${NC}"
    fi

    local IPV6_STATUS=$(sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | awk '{print $3}')
    if [ "$IPV6_STATUS" = "1" ]; then
        echo -e "   ${YELLOW}🔧 IPv6: disabled${NC}"
    else
        echo -e "   ${GREEN}🔧 IPv6: enabled${NC}"
    fi
}

function show_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${YELLOW}No log file found${NC}"
        echo -e "${YELLOW}The VPN may not have been started yet${NC}"
        return 1
    fi

    echo -e "${CYAN}📄 VPN logs (Ctrl+C to quit):${NC}\n"
    tail -f "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Tor mode
# ---------------------------------------------------------------------------

function check_command_exists() {
    local cmd="$1"
    command -v "$cmd" > /dev/null 2>&1
}

function is_our_tor_running() {
    # `pgrep -x tor` alone is not safe: many distros run a system-wide Tor
    # service (e.g. /etc/tor/torrc, user debian-tor) independently of this
    # script. We must only consider the instance we launched ourselves,
    # identified by our own pidfile, to avoid ever touching a Tor service
    # the user did not start through vpngate-manager.
    if [ ! -f "$TOR_PID_FILE" ]; then
        return 1
    fi
    local pid
    pid=$(cat "$TOR_PID_FILE" 2>/dev/null)
    [ -n "$pid" ] && ps -p "$pid" > /dev/null 2>&1
}

function check_iptables_compatibility() {
    if ! sudo iptables --version > /dev/null 2>&1; then
        echo -e "${RED}❌ iptables is not usable on this system${NC}"
        return 1
    fi

    # Try creating a temporary chain to detect nftables-only systems
    # where the legacy iptables binary is present but non-functional.
    # The test must target the `nat` table specifically: that's the table
    # actually used by apply_tor_iptables (REDIRECT only exists there), and
    # some nftables-only systems are functional in `filter` but not in `nat`.
    local test_chain="VPNGATE_TEST_$$"
    local create_error
    create_error=$(sudo iptables -t nat -N "$test_chain" 2>&1)

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ iptables is not functional on this system (nat table)${NC}"
        if echo "$create_error" | grep -qi "nft\|incompatible\|does not exist"; then
            echo -e "${YELLOW}   This looks like an nftables-only system without iptables-legacy compatibility${NC}"
        fi
        echo -e "${YELLOW}   Details: $create_error${NC}"
        return 1
    fi

    # Clean up the test chain
    sudo iptables -t nat -F "$test_chain" > /dev/null 2>&1
    sudo iptables -t nat -X "$test_chain" > /dev/null 2>&1

    return 0
}

function check_tor_relays() {
    local country_code="$1"
    local cc_lower
    cc_lower=$(echo "$country_code" | tr '[:upper:]' '[:lower:]')

    echo -e "${CYAN}🔍 Checking Tor exit relay availability for '${country_code}'...${NC}"

    local response
    response=$(curl -s --max-time 10 "https://onionoo.torproject.org/details?type=relay&running=true&flag=Exit&fields=country")

    if [ $? -ne 0 ] || [ -z "$response" ]; then
        echo -e "${YELLOW}⚠️  Unable to query onionoo.torproject.org (no network or service down)${NC}"
        echo -e "${YELLOW}   This check is informational only, continuing...${NC}"
        return 0
    fi

    local relay_count
    relay_count=$(echo "$response" | grep -o "\"country\":\"${cc_lower}\"" | wc -l)

    if [ "$relay_count" -gt 0 ]; then
        echo -e "${GREEN}✅ Found ${relay_count} Tor exit relay(s) for '${country_code}'${NC}"
        return 0
    fi

    echo -e "${YELLOW}⚠️  No Tor exit relay currently reported for '${country_code}'${NC}"
    echo -e "${YELLOW}   Tor may fail to find a usable circuit (StrictNodes 1).${NC}"
    echo -e "${YELLOW}Continue anyway? (y/N)${NC} "
    read -r response_confirm
    if [[ "$response_confirm" =~ ^[yY]$ ]]; then
        return 0
    fi
    return 1
}

function check_tor_ports_free() {
    # `tor --runasdaemon 1` can return 0 even if it later fails to bind a
    # port (e.g. a system-wide Tor service already listening on 9050/9040),
    # because the failure happens after the fork. The only existing
    # safety net for that case is the 30s bootstrap timeout below, which is
    # slow and indirect. If `ss` is available (no new dependency: it ships
    # with iproute2, already required by `ip a` elsewhere in this script),
    # do a quick best-effort check first to fail fast with a clear message.
    if ! check_command_exists ss; then
        return 0
    fi

    local port
    for port in "$@"; do
        if ss -ltn 2>/dev/null | grep -q ":${port} "; then
            echo -e "${RED}❌ Port ${port} is already in use (likely a system-wide tor service)${NC}"
            echo -e "${YELLOW}   Stop it (e.g. 'sudo systemctl stop tor') or free the port, then retry${NC}"
            return 1
        fi
    done
    return 0
}

function generate_torrc() {
    # Note: ControlPort is intentionally omitted in this V1. It is only
    # needed to change the exit country dynamically without restarting the
    # daemon, but `tor <country_code>` always regenerates torrc and restarts
    # tor, so the control port would be dead code for now.
    local country_code="$1"
    local socks_port="$2"

    cat > "$TORRC_FILE" <<EOF
ExitNodes {${country_code}}
StrictNodes 1
SocksPort ${socks_port}
TransPort 127.0.0.1:${TOR_TRANS_PORT}
DNSPort 127.0.0.1:${TOR_DNS_PORT}
AutomapHostsOnResolve 1
VirtualAddrNetworkIPv4 10.192.0.0/10
Log notice file ${TOR_LOG_FILE}
EOF
}

function apply_tor_iptables() {
    # Note: SocksPort is not referenced here on purpose - it is only used
    # locally by tor itself and by curl/clients, it is never redirected via
    # iptables (only TCP SYN and DNS traffic are).
    local tor_pid="$1"
    local trans_port="$2"
    local dns_port="$3"

    # Determine the tor process UID dynamically (varies by distro: debian-tor,
    # _tor, toranon, etc.) instead of assuming a fixed user name.
    local tor_user
    tor_user=$(ps -o user= -p "$tor_pid" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$tor_user" ]; then
        echo -e "${RED}❌ Unable to determine the tor process owner (PID $tor_pid)${NC}"
        return 1
    fi

    local tor_uid
    tor_uid=$(id -u "$tor_user" 2>/dev/null)
    if [ -z "$tor_uid" ]; then
        echo -e "${RED}❌ Unable to resolve UID for user '$tor_user'${NC}"
        return 1
    fi

    echo -e "${CYAN}🔧 Applying transparent proxy iptables rules (chain ${TOR_CHAIN})...${NC}"

    # NOTE: -j REDIRECT only exists in the `nat` table, so every command
    # touching VPNGATE_TOR or its OUTPUT jump must use `-t nat`. Using the
    # default `filter` table here would silently fail to redirect anything.

    # Create the isolated chain if missing, flush it if it already exists.
    # We never touch any other chain or rule owned by the user.
    if sudo iptables -t nat -L "$TOR_CHAIN" > /dev/null 2>&1; then
        sudo iptables -t nat -F "$TOR_CHAIN"
    else
        sudo iptables -t nat -N "$TOR_CHAIN"
    fi

    # Traffic generated by the tor process itself must bypass the redirect.
    # Must stay the first rule in the chain, evaluated before the REDIRECTs.
    sudo iptables -t nat -A "$TOR_CHAIN" -m owner --uid-owner "$tor_uid" -j RETURN

    # Redirect TCP SYN traffic to Tor's TransPort
    sudo iptables -t nat -A "$TOR_CHAIN" -p tcp --syn -j REDIRECT --to-ports "$trans_port"

    # Redirect DNS (UDP/53) to Tor's DNSPort
    # NOTE: other UDP traffic (not DNS) is NOT routed through Tor and leaks
    # outside the tunnel. This is a known Tor limitation (no UDP transparent
    # proxying support beyond DNS) - documented in README/help as well.
    sudo iptables -t nat -A "$TOR_CHAIN" -p udp --dport 53 -j REDIRECT --to-ports "$dns_port"

    # Jump from OUTPUT into our isolated chain, inserted first so it is
    # evaluated before the user's own OUTPUT rules but contained entirely
    # within VPNGATE_TOR. Drain any leftover jump first to avoid duplicate
    # inserts if a previous teardown was incomplete (M1).
    while sudo iptables -t nat -D OUTPUT -j "$TOR_CHAIN" 2>/dev/null; do :; done
    sudo iptables -t nat -I OUTPUT 1 -j "$TOR_CHAIN"

    # Save what we need for a clean teardown later
    cat > "$IPTABLES_RULES_FILE" <<EOF
TOR_UID=${tor_uid}
TOR_CHAIN=${TOR_CHAIN}
EOF

    echo -e "${GREEN}✅ iptables rules applied (chain ${TOR_CHAIN})${NC}"
    return 0
}

function verify_tor_exit_ip() {
    # NOTE: this checks the exit IP via the SocksPort only. It confirms the
    # Tor circuit itself works, but does NOT prove that the transparent
    # proxy path (iptables REDIRECT -> TransPort/DNSPort) is actually
    # routing system traffic through Tor. A SocksPort success does not
    # guarantee the iptables rules are in effect.
    local socks_port="$1"

    local response
    response=$(curl -s --max-time 10 --socks5-hostname "127.0.0.1:${socks_port}" "https://check.torproject.org/api/ip" 2>/dev/null)

    if [ -z "$response" ]; then
        echo -e "${YELLOW}⚠️  Unable to verify the Tor exit IP (non-fatal)${NC}"
        return 1
    fi

    local exit_ip
    exit_ip=$(echo "$response" | grep -o '"IP":"[^"]*"' | sed -E 's/"IP":"([^"]*)"/\1/')
    local is_tor
    is_tor=$(echo "$response" | grep -o '"IsTor":[a-z]*' | sed -E 's/"IsTor":([a-z]*)/\1/')

    if [ -z "$exit_ip" ]; then
        echo -e "${YELLOW}⚠️  Unable to parse the Tor exit IP response (non-fatal)${NC}"
        return 1
    fi

    if [ "$is_tor" = "true" ]; then
        echo -e "${GREEN}🌍 Tor exit IP: ${exit_ip}${NC}"
    else
        echo -e "${YELLOW}🌍 Exit IP: ${exit_ip} (could not confirm Tor circuit)${NC}"
    fi
    return 0
}

function stop_tor() {
    echo ""
    echo -e "${YELLOW}🛑 Stopping Tor mode...${NC}"

    # Remove the OUTPUT jump and flush/delete the isolated chain.
    # Never touch any other iptables rule. All operations target the `nat`
    # table (see apply_tor_iptables) and run in teardown order: jump first,
    # then flush, then delete the chain. The jump is removed in a loop to
    # drain any duplicate inserts left over from an incomplete prior run (M1).
    if [ -f "$IPTABLES_RULES_FILE" ]; then
        while sudo iptables -t nat -D OUTPUT -j "$TOR_CHAIN" 2>/dev/null; do :; done
        sudo iptables -t nat -F "$TOR_CHAIN" > /dev/null 2>&1
        sudo iptables -t nat -X "$TOR_CHAIN" > /dev/null 2>&1
    fi

    # Kill the tor daemon via its own PID file ONLY. Unlike OpenVPN, we
    # deliberately do NOT fall back to a generic `pkill tor`: many distros
    # run a system-wide Tor service (e.g. /etc/tor/torrc, user debian-tor)
    # independently of this script, and a blind pkill would kill it too.
    if [ -f "$TOR_PID_FILE" ]; then
        local tor_pid=$(cat "$TOR_PID_FILE")
        if [ -n "$tor_pid" ] && ps -p "$tor_pid" > /dev/null 2>&1; then
            sudo kill -TERM "$tor_pid" 2>/dev/null
            sleep 2
            sudo kill -9 "$tor_pid" 2>/dev/null
        fi
    fi

    echo -e "${CYAN}🔧 Re-enabling IPv6...${NC}"
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
    sudo sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
    sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null

    rm -f "$TORRC_FILE" "$TOR_PID_FILE" "$TOR_LOG_FILE" "$IPTABLES_RULES_FILE" "$ACTIVE_MODE_FILE"

    echo -e "${GREEN}✅ Tor mode stopped cleanly${NC}"
}

function start_tor() {
    local country_code="$1"
    local mode="${2:-daemon}"

    if [ -z "$country_code" ]; then
        echo -e "${RED}❌ No country code specified${NC}"
        echo -e "${YELLOW}Usage: $0 tor <country_code>   (e.g. $0 tor US)${NC}"
        return 1
    fi

    # Strict validation BEFORE any other processing: country_code is later
    # injected verbatim (uppercased) into the generated torrc (ExitNodes
    # {...}) and into a grep pattern. Without this check, a value containing
    # newlines or shell/torrc-special characters could inject arbitrary
    # torrc directives or corrupt the grep pattern.
    if [[ ! "$country_code" =~ ^[A-Za-z]{2}$ ]]; then
        echo -e "${RED}❌ Invalid country code: expected a 2-letter ISO code (e.g. US, FR, JP)${NC}"
        return 1
    fi

    # --- Environment validation (must run before any system action) ---

    if ! check_command_exists tor; then
        echo -e "${RED}❌ tor is not installed${NC}"
        echo -e "${YELLOW}Install it with:${NC}"
        echo -e "   sudo apt install tor      (Debian/Ubuntu)"
        echo -e "   sudo dnf install tor      (Fedora)"
        echo -e "   sudo pacman -S tor        (Arch)"
        return 1
    fi

    if ! check_command_exists iptables; then
        echo -e "${RED}❌ iptables is not installed${NC}"
        echo -e "${YELLOW}Install it with:${NC}"
        echo -e "   sudo apt install iptables      (Debian/Ubuntu)"
        echo -e "   sudo dnf install iptables      (Fedora)"
        echo -e "   sudo pacman -S iptables        (Arch)"
        return 1
    fi

    if ! check_iptables_compatibility; then
        echo -e "${RED}❌ iptables compatibility check failed, aborting${NC}"
        return 1
    fi

    local country_upper
    country_upper=$(echo "$country_code" | tr '[:lower:]' '[:upper:]')

    if ! check_tor_relays "$country_upper"; then
        echo "Cancelled."
        return 1
    fi

    # OpenVPN and Tor mode are mutually exclusive
    if pgrep -x openvpn > /dev/null; then
        echo -e "${YELLOW}⚠️  OpenVPN is currently active${NC}"
        echo -e "${YELLOW}Do you want to stop it and start Tor mode instead? (y/N)${NC} "
        read -r response
        if [[ "$response" =~ ^[yY]$ ]]; then
            cleanup
            sleep 2
        else
            echo "Cancelled."
            return 1
        fi
    fi

    if is_our_tor_running; then
        echo -e "${YELLOW}⚠️  Tor mode is already active${NC}"
        echo -e "${YELLOW}Do you want to restart it with the new country? (y/N)${NC} "
        read -r response
        if [[ "$response" =~ ^[yY]$ ]]; then
            stop_tor
            sleep 1
        else
            echo "Cancelled."
            return 1
        fi
    fi

    # --- Config + daemon startup ---

    # Disable IPv6 before any tor/network activity starts. The transparent
    # proxy rules in apply_tor_iptables() only cover the IPv4 `nat` table, so
    # any IPv6 traffic would bypass Tor entirely and leak the real address.
    # Done here (after the confirmation prompts) so an aborted start never
    # toggles IPv6; re-enabled in stop_tor().
    echo -e "${CYAN}🔧 Temporarily disabling IPv6...${NC}"
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
    sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
    sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null

    echo -e "${CYAN}🔧 Generating Tor configuration for exit country '${country_upper}'...${NC}"
    generate_torrc "$country_upper" "$TOR_SOCKS_PORT"

    rm -f "$TOR_LOG_FILE" "$TOR_PID_FILE"

    if ! check_tor_ports_free "$TOR_SOCKS_PORT" "$TOR_TRANS_PORT" "$TOR_DNS_PORT"; then
        return 1
    fi

    echo -e "${GREEN}🚀 Starting Tor daemon...${NC}"
    sudo tor -f "$TORRC_FILE" --pidfile "$TOR_PID_FILE" --runasdaemon 1

    if [ $? -ne 0 ] || [ ! -f "$TOR_PID_FILE" ]; then
        echo -e "${RED}❌ Tor failed to launch${NC}"
        rm -f "$TORRC_FILE" "$TOR_PID_FILE"
        return 1
    fi

    # Mark tor as the active mode right now, as soon as the daemon is
    # confirmed launched (pidfile present), NOT after bootstrap completes.
    # Bootstrap can take up to ${max_wait}s below; a Ctrl+C during that
    # window must be routed to stop_tor() by the trap/cleanup() instead of
    # leaving an orphaned tor process with no marker to clean it up.
    echo "tor" > "$ACTIVE_MODE_FILE"

    echo -e "${CYAN}⏳ Waiting for Tor to bootstrap...${NC}"
    local max_wait=30
    local waited=0
    local spin='|/-\'
    local bootstrapped=0

    while [ $waited -lt $max_wait ]; do
        if [ -f "$TOR_LOG_FILE" ] && grep -q "Bootstrapped 100%" "$TOR_LOG_FILE" 2>/dev/null; then
            bootstrapped=1
            break
        fi
        printf "\r${CYAN}⏳ Bootstrapping... %s${NC}" "${spin:$((waited % 4)):1}"
        sleep 1
        ((waited++))
    done
    printf "\r"

    if [ "$bootstrapped" -ne 1 ]; then
        echo -e "${RED}❌ Tor did not bootstrap within ${max_wait}s${NC}"
        echo -e "${YELLOW}Last log lines:${NC}"
        tail -n 10 "$TOR_LOG_FILE" 2>/dev/null | sed 's/^/   /'
        # The marker was already written when the daemon was launched, and
        # no iptables rules have been applied yet, so route through
        # stop_tor() (kills the daemon, removes the marker + all tor files)
        # instead of a partial manual rm -f.
        stop_tor
        return 1
    fi

    echo -e "${GREEN}✅ Tor bootstrapped successfully (100%)${NC}"

    # --- Transparent proxy iptables rules ---

    local tor_pid
    tor_pid=$(cat "$TOR_PID_FILE")

    if ! apply_tor_iptables "$tor_pid" "$TOR_TRANS_PORT" "$TOR_DNS_PORT"; then
        echo -e "${RED}❌ Failed to apply iptables rules, rolling back${NC}"
        stop_tor
        return 1
    fi

    # --- Exit IP verification (non-fatal) ---

    verify_tor_exit_ip "$TOR_SOCKS_PORT"

    echo ""
    echo -e "${YELLOW}⚠️  Only TCP and DNS traffic are routed through Tor. Other UDP traffic leaks outside the tunnel.${NC}"
    echo -e "${YELLOW}Useful commands:${NC}"
    echo -e "   ${GREEN}$0 status${NC}  - Show current status"
    echo -e "   ${GREEN}$0 stop${NC}    - Stop Tor mode"

    if [ "$mode" = "foreground" ]; then
        trap cleanup EXIT INT TERM
        echo -e "${YELLOW}   Press Ctrl+C to stop${NC}"
        tail -f "$TOR_LOG_FILE"
    fi

    return 0
}

function stop_vpn() {
    if ! pgrep -x openvpn > /dev/null && ! is_our_tor_running; then
        echo -e "${YELLOW}No active VPN${NC}"
        return 0
    fi
    cleanup
}

function show_help() {
    echo -e "${CYAN}VPNGate Manager - VPN Manager${NC}\n"
    echo -e "${YELLOW}Usage:${NC}"
    echo "  $0 [command] [options]"
    echo ""
    echo -e "${YELLOW}Commands:${NC}"
    echo -e "  ${GREEN}start [country] [-f]${NC}  Connect to a VPN"
    echo "                        - Without argument: show all available VPN servers"
    echo "                        - With country: filter by country (e.g. japan, france, US)"
    echo -e "                        - ${CYAN}-f${NC} : foreground mode (shows logs)"
    echo ""
    echo -e "  ${GREEN}local [-f]${NC}            Use a local .ovpn file"
    echo -e "                        - ${CYAN}-f${NC} : foreground mode"
    echo ""
    echo -e "  ${GREEN}tor <country_code> [-f]${NC}  Route traffic through a Tor exit node in <country_code>"
    echo "                        - Use this when VPNGate has no server in the desired region"
    echo "                        - Requires: tor, iptables (see Requirements)"
    echo "                        - Only TCP and DNS traffic are routed through Tor;"
    echo "                          other UDP traffic leaks outside the tunnel"
    echo -e "                        - ${YELLOW}Anonymity is reduced when forcing a specific exit country${NC}"
    echo -e "                        - ${CYAN}-f${NC} : foreground mode (tails the tor log)"
    echo ""
    echo -e "  ${GREEN}stop${NC}                  Stop the VPN/Tor mode and clean up"
    echo ""
    echo -e "  ${GREEN}status${NC}                Show connection status (OpenVPN or Tor)"
    echo ""
    echo -e "  ${GREEN}logs${NC}                  Show logs in real time"
    echo ""
    echo -e "  ${GREEN}refresh${NC}               Force refresh of the VPN list"
    echo ""
    echo -e "  ${GREEN}help${NC}                  Show this help"
    echo ""
    echo -e "${YELLOW}Operating modes:${NC}"
    echo -e "  ${CYAN}Daemon (default)${NC}      : VPN runs in the background, terminal stays free"
    echo -e "  ${CYAN}Foreground (-f)${NC}       : VPN runs in the foreground, logs are visible"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  $0 start              # Start in daemon mode (background)"
    echo "  $0 start -f           # Start in foreground mode (logs visible)"
    echo "  $0 start japan        # Japanese VPN in daemon mode"
    echo "  $0 start japan -f     # Japanese VPN in foreground mode"
    echo "  $0 local              # Local file in daemon mode"
    echo "  $0 local -f           # Local file in foreground mode"
    echo "  $0 tor US             # Route traffic through a US Tor exit node"
    echo "  $0 tor DE -f          # Same, in foreground mode"
    echo "  $0 status             # Check whether the VPN/Tor mode is active"
    echo "  $0 logs               # Follow logs in real time"
    echo "  $0 stop               # Stop the VPN or Tor mode"
    echo ""
}

# Main menu
case "${1:-help}" in
    start)
        # Check whether -f is provided
        if [ "$2" = "-f" ] || [ "$3" = "-f" ]; then
            mode="foreground"
            country="${2}"
            [ "$country" = "-f" ] && country=""
        else
            mode="daemon"
            country="${2}"
        fi
        select_vpn "$country" "$mode"
        ;;
    local)
        # Check whether -f is provided
        if [ "$2" = "-f" ]; then
            mode="foreground"
        else
            mode="daemon"
        fi
        list_local_vpns "$mode"
        ;;
    tor)
        # Check whether -f is provided
        if [ "$3" = "-f" ]; then
            mode="foreground"
        else
            mode="daemon"
        fi
        country="$2"
        start_tor "$country" "$mode"
        ;;
    stop)
        stop_vpn
        ;;
    status)
        status
        ;;
    logs)
        show_logs
        ;;
    refresh)
        download_vpn_list
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo -e "${RED}❌ Unknown command: $1${NC}\n"
        show_help
        exit 1
        ;;
esac
#!/bin/bash
# vpngate-manager.sh - Version 3.0 (Optimized Daemon)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${VPNGATE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/vpngate-manager}"
if [[ "$DATA_DIR" != /* ]] || [ "$DATA_DIR" = / ]; then
    echo 'VPNGATE_DATA_DIR must be an absolute directory other than /.' >&2
    exit 1
fi

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

mkdir -p "$DATA_DIR" || exit 1

# Display colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

VPNGATE_API_URL="${VPNGATE_API_URL:-https://www.vpngate.net/api/iphone/}"
VPNGATE_DOWNLOAD_MAX_TIME="${VPNGATE_DOWNLOAD_MAX_TIME:-30}"

# A list is valid when it has > 2 lines and at least one real server row
# (IPv4 in field 2, numeric score in field 3).
function is_valid_vpn_list() {
    local f="$1"
    [ -s "$f" ] || return 1
    [ "$(wc -l < "$f")" -gt 2 ] || return 1
    tail -n +3 "$f" | awk -F, '$2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $3 ~ /^[0-9]+$/ {found=1; exit} END {exit !found}'
}

function download_vpn_list() {
    echo -e "${CYAN}📥 Downloading the list of available VPN servers...${NC}" >&2

    # Download to a temp file in the same dir; only a valid result replaces the cache.
    local tmp_file
    tmp_file=$(mktemp "$DATA_DIR/.vpngate_cache.XXXXXX") || {
        echo -e "${RED}❌ Failed to download the VPN list (cannot create temp file)${NC}" >&2
        return 1
    }

    if curl -s --fail --max-time "$VPNGATE_DOWNLOAD_MAX_TIME" "$VPNGATE_API_URL" -o "$tmp_file" \
        && is_valid_vpn_list "$tmp_file"; then
        chmod 664 "$tmp_file"
        mv -f "$tmp_file" "$CACHE_FILE"
        echo -e "${GREEN}✅ VPN list downloaded successfully${NC}" >&2
        return 0
    fi

    rm -f "$tmp_file"
    echo -e "${RED}❌ Failed to download the VPN list${NC}" >&2
    return 1
}

function get_vpn_list() {
    local cache_valid=0 cache_age=0
    if [ -f "$CACHE_FILE" ] && is_valid_vpn_list "$CACHE_FILE"; then
        cache_valid=1
        cache_age=$(($(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null)))
        if [ $cache_age -lt $CACHE_MAX_AGE ]; then
            return 0
        fi
    fi

    download_vpn_list && return 0

    if [ $cache_valid -eq 1 ]; then
        echo -e "${YELLOW}⚠️  WARNING: VPNGate download failed; using stale cache (age: $((cache_age / 60)) min)${NC}" >&2
        return 0
    fi
    echo -e "${RED}❌ No valid VPN list available (download failed and no usable cache)${NC}" >&2
    return 1
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
            if [[ ! "${country_long,,}" =~ ${filter_country,,} ]] && \
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

    # ponytail: stale root-owned .ovpn files (leftover from a past sudo run) block the
    # write since we're not root here; directory is user-owned so we can always remove them.
    [ -e "$ovpn_file" ] && ! [ -w "$ovpn_file" ] && rm -f "$ovpn_file"

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

function is_our_openvpn_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid=$(cat "$PID_FILE")
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -r "/proc/$pid/comm" ] && [ "$(cat "/proc/$pid/comm")" = openvpn ]
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
    
    # Recover a failed Tor session before starting another host-wide mode.
    if ! is_our_tor_running && { [ -e "$DATA_DIR/tor-runtime" ] || [ -e "$DATA_DIR/tor-ipv6.state" ] || [ -e "$DATA_DIR/tor-dns.json" ]; }; then
        echo 'Tor recovery is pending; run stop before starting OpenVPN.' >&2
        return 1
    fi
    # Tor mode and OpenVPN are mutually exclusive
    if is_our_tor_running; then
        echo -e "${YELLOW}⚠️  Tor mode is currently active${NC}"
        echo -e "${YELLOW}Do you want to stop it and start OpenVPN instead? (y/N)${NC} "
        read -r response
        if [[ "$response" =~ ^[yY]$ ]]; then
            cleanup || return 1
            sleep 2
        else
            echo "Cancelled."
            return 1
        fi
    fi

    # Check whether a VPN is already running
    if is_our_openvpn_running; then
        echo -e "${YELLOW}⚠️  A VPN is already active${NC}"
        echo -e "${YELLOW}Do you want to stop it and start a new one? (y/N)${NC} "
        read -r response
        if [[ "$response" =~ ^[yY]$ ]]; then
            cleanup || return 1
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

function resolve_ovpn_for_exec() {
    # Non-interactive counterpart to select_vpn: picks the first matching
    # server automatically instead of prompting, so `exec` stays scriptable
    # when called by another program. Prints the resolved .ovpn path on stdout.
    local filter_country="$1"
    local skip=$(( ${2:-1} - 1 ))  # pick the Nth matching server (1-based)

    get_vpn_list || return 1

    local line_num=0
    while IFS= read -r line; do
        ((line_num++))
        [ $line_num -le 2 ] && continue

        local ip=$(echo "$line" | cut -d',' -f2)
        local country_long=$(echo "$line" | cut -d',' -f6)
        local country_short=$(echo "$line" | cut -d',' -f7)

        [ -z "$ip" ] || [ "$ip" = "IP" ] && continue

        if [ -n "$filter_country" ]; then
            local filter_upper=$(echo "$filter_country" | tr '[:lower:]' '[:upper:]')
            if [[ ! "${country_long,,}" =~ ${filter_country,,} ]] && \
               [[ ! "$country_short" =~ $filter_upper ]]; then
                continue
            fi
        fi

        if [ "$skip" -gt 0 ]; then
            skip=$((skip - 1))
            continue
        fi

        country_long=$(echo "$country_long" | sed 's/[^[:alnum:] ]//g')

        local full_line=$(sed -n "${line_num}p" "$CACHE_FILE")
        local base64_data=$(echo "$full_line" | awk -F',' '{print $NF}' | tr -d '[:space:]')
        local ovpn_file="$DATA_DIR/${country_short}-vpngate_${ip}_udp.ovpn"

        [ -e "$ovpn_file" ] && ! [ -w "$ovpn_file" ] && rm -f "$ovpn_file"

        echo "$base64_data" | base64 -d --ignore-garbage 2>/dev/null | grep -v "^persist-key" > "$ovpn_file"

        if [ -s "$ovpn_file" ] && grep -q "client" "$ovpn_file" 2>/dev/null; then
            echo "$ovpn_file"
            return 0
        fi
        rm -f "$ovpn_file"
    done < "$CACHE_FILE"

    return 1
}

function exec_vpn() {
    local filter_country="$1"
    shift
    local cmd=("$@")

    if [ ${#cmd[@]} -eq 0 ]; then
        echo -e "${RED}❌ No command specified${NC}"
        echo -e "${YELLOW}Usage: $0 exec [country] -- <command...>${NC}"
        return 1
    fi

    if ! check_command_exists vopono; then
        echo -e "${RED}❌ vopono is not installed${NC}"
        echo -e "${YELLOW}vopono runs a single command in an isolated network namespace${NC}"
        echo -e "${YELLOW}so only that command goes through the VPN — the rest of the system is untouched.${NC}"
        echo ""
        echo -e "  Install: ${CYAN}cargo install vopono${NC}  (or grab a release binary: https://github.com/jamesmcm/vopono)"
        return 1
    fi

    echo -e "${CYAN}🔎 Resolving VPN config for isolated exec...${NC}"
    local ovpn_file
    ovpn_file=$(resolve_ovpn_for_exec "$filter_country")

    if [ -z "$ovpn_file" ]; then
        echo -e "${RED}❌ No matching VPN server found${NC}"
        return 1
    fi

    echo -e "${BLUE}📁 Using: $(basename "$ovpn_file")${NC}"
    echo -e "${GREEN}🚀 Running in isolated netns via vopono: ${cmd[*]}${NC}"

    # ponytail: vopono's exact custom-provider flags (--custom / --protocol openvpn)
    # are best-effort against the documented CLI and unverified here (vopono isn't
    # installed in this environment) — double-check against `vopono exec --help`
    # if this errors on a newer/older vopono release.
    sudo vopono exec --custom "$ovpn_file" --protocol openvpn -- "${cmd[@]}"
}

function cleanup_openvpn() {
    echo ""
    echo -e "${YELLOW}🛑 Stopping VPN...${NC}"

    # Read PID from file
    if [ -f "$PID_FILE" ]; then
        local vpn_pid=$(cat "$PID_FILE")
        if is_our_openvpn_running; then
            sudo kill -TERM "$vpn_pid" 2>/dev/null
            sleep 2
            sudo kill -9 "$vpn_pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
    fi

    # Only the recorded host VPN PID belongs to this session. Namespace and
    # independently managed OpenVPN processes must remain untouched.

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
            if [ -f "$PID_FILE" ]; then
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

    if is_our_openvpn_running; then
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

function tor_pid_matches() {
    local pid="$1"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    python3 - "$pid" "$TORRC_FILE" <<'CHECK_TOR_PID'
import pathlib, sys
try:
    proc = pathlib.Path('/proc') / sys.argv[1]
    args = (proc / 'cmdline').read_bytes().split(b'\0')
    valid = (proc / 'comm').read_text().strip() == 'tor' and sys.argv[2].encode() in args
except OSError:
    valid = False
sys.exit(0 if valid else 1)
CHECK_TOR_PID
}

function is_our_tor_running() {
    tor_runtime_paths || return 1
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
    tor_pid_matches "$pid"
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
        if { ss -ltn; ss -lun; } 2>/dev/null | grep -q ":${port} "; then
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

    cat <<EOF | sudo tee "$TORRC_FILE" >/dev/null
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
    if [ -z "$tor_uid" ] || [ "$tor_uid" = 0 ] || [ "$tor_uid" = "$(id -u)" ]; then
        echo -e "${RED}❌ Unable to resolve UID for user '$tor_user'${NC}"
        return 1
    fi

    echo -e "${CYAN}🔧 Applying transparent proxy iptables rules (chain ${TOR_CHAIN})...${NC}"

    # NOTE: -j REDIRECT only exists in the `nat` table, so every command
    # touching VPNGATE_TOR or its OUTPUT jump must use `-t nat`. Using the
    # default `filter` table here would silently fail to redirect anything.

    local rules
    rules=$(sudo iptables -t nat -S) || return 1
    if grep -q -- "^-N $TOR_CHAIN$" <<< "$rules"; then
        echo 'Existing Tor chain has no managed session; refusing to overwrite it.' >&2
        return 1
    fi
    sudo iptables -t nat -N "$TOR_CHAIN" || return 1
    if ! (umask 077; : > "$IPTABLES_RULES_FILE"); then
        sudo iptables -t nat -X "$TOR_CHAIN"
        return 1
    fi

    # Traffic generated by the tor process itself must bypass the redirect.
    # Must stay the first rule in the chain, evaluated before the REDIRECTs.
    sudo iptables -t nat -A "$TOR_CHAIN" -m owner --uid-owner "$tor_uid" -j RETURN || return 1

    # Redirect TCP SYN traffic to Tor's TransPort
    sudo iptables -t nat -A "$TOR_CHAIN" -p tcp --syn -j REDIRECT --to-ports "$trans_port" || return 1

    # Redirect DNS (UDP/53) to Tor's DNSPort
    # NOTE: other UDP traffic (not DNS) is NOT routed through Tor and leaks
    # outside the tunnel. This is a known Tor limitation (no UDP transparent
    # proxying support beyond DNS) - documented in README/help as well.
    sudo iptables -t nat -A "$TOR_CHAIN" -p udp --dport 53 -j REDIRECT --to-ports "$dns_port" || return 1

    sudo iptables -t nat -I OUTPUT 1 -j "$TOR_CHAIN" || return 1

    echo -e "${GREEN}✅ iptables rules applied (chain ${TOR_CHAIN})${NC}"
    return 0
}


function verify_tor_transparent() {
    local response
    response=$(curl --fail --silent --show-error --max-time 15 --noproxy '*' https://check.torproject.org/api/ip) || return 1
    printf '%s' "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("IsTor") is True else 1)' || return 1
    echo 'Transparent DNS/TCP path verified by Tor Project (IsTor: true).'
}

function verify_tor_exit_ip() {
    # NOTE: this checks the exit IP via the SocksPort only. It confirms the
    # Tor circuit itself works, but does NOT prove that the transparent
    # proxy path (iptables REDIRECT -> TransPort/DNSPort) is actually
    # routing system traffic through Tor. A SocksPort success does not
    # guarantee the iptables rules are in effect.
    local socks_port="$1"

    local response
    response=$(curl -s --max-time 10 --noproxy '' --socks5-hostname "127.0.0.1:${socks_port}" "https://check.torproject.org/api/ip" 2>/dev/null)

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

# IPv6 and DNS settings are recovery records, not disposable cache files.
function tor_save_ipv6() {
    local iface value
    [ ! -e "$DATA_DIR/tor-ipv6.state" ] || { echo 'Unrestored Tor IPv6 state; run stop first.' >&2; return 1; }
    local snapshot=''
    local path
    for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        iface="${path%/disable_ipv6}"
        iface="${iface##*/}"
        value=$(sysctl -n "net/ipv6/conf/$iface/disable_ipv6") || return 1
        [[ "$value" =~ ^[01]$ ]] || return 1
        snapshot+="$iface $value"$'\n'
    done
    (umask 077; printf '%s' "$snapshot" > "$DATA_DIR/tor-ipv6.state") || return 1
    for iface in all default lo; do
        sudo sysctl -w "net/ipv6/conf/$iface/disable_ipv6=1" >/dev/null || return 1
        [ "$(sysctl -n "net/ipv6/conf/$iface/disable_ipv6")" = 1 ] || { echo 'Could not disable IPv6; refusing Tor startup.' >&2; return 1; }
    done
}

function tor_restore_ipv6() {
    [ -f "$DATA_DIR/tor-ipv6.state" ] || return 0
    local iface value failed=0
    while read -r iface value; do
        if [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] && [[ "$value" =~ ^[01]$ ]]; then
            if [ -e "/proc/sys/net/ipv6/conf/$iface/disable_ipv6" ]; then
                sudo sysctl -w "net/ipv6/conf/$iface/disable_ipv6=$value" >/dev/null || failed=1
                [ "$(sysctl -n "net/ipv6/conf/$iface/disable_ipv6")" = "$value" ] || failed=1
            fi
        else
            failed=1
        fi
    done < "$DATA_DIR/tor-ipv6.state"
    [ "$failed" = 0 ] || return 1
    rm -f "$DATA_DIR/tor-ipv6.state"
}

function tor_runtime_paths() {
    [ -f "$DATA_DIR/tor-runtime" ] || return 0
    local runtime
    runtime=$(cat "$DATA_DIR/tor-runtime")
    [[ "$runtime" =~ ^/tmp/vpngate-tor\.[A-Za-z0-9]{6}$ ]] && [ -d "$runtime" ] && [ ! -L "$runtime" ] || {
        echo 'Invalid Tor runtime recovery path; inspect tor-runtime before retrying.' >&2; return 1;
    }
    TORRC_FILE="$runtime/torrc"
    TOR_PID_FILE="$runtime/tor.pid"
    TOR_LOG_FILE="$runtime/tor.log"
}

function tor_create_runtime() {
    # The owner exemption in the firewall must never exempt root or the login
    # user's traffic. Use the distribution's dedicated Tor account instead.
    local account uid runtime
    for account in debian-tor toranon _tor tor; do
        uid=$(id -u "$account" 2>/dev/null) || continue
        [ "$uid" != 0 ] && [ "$uid" != "$(id -u)" ] && break
        uid=''
    done
    [ -n "$uid" ] || { echo 'A dedicated non-root Tor service account is required; install your distribution Tor package.' >&2; return 1; }
    runtime=$(mktemp -d /tmp/vpngate-tor.XXXXXX) || return 1
    # Config and log paths remain outside a potentially private home directory.
    chmod 755 "$runtime" || return 1
    sudo chown "$account" "$runtime" || { rmdir "$runtime"; return 1; }
    printf '%s\n' "$runtime" > "$DATA_DIR/tor-runtime" || return 1
    TOR_DAEMON_USER="$account"
    tor_runtime_paths
}

function stop_tor() {
    local failed=0
    tor_runtime_paths || return 1
    if [ -e "$IPTABLES_RULES_FILE" ]; then
        local rules
        if rules=$(sudo iptables -t nat -S); then
            if grep -q -- "^-N $TOR_CHAIN$" <<< "$rules"; then
                while grep -q -- "^-A OUTPUT -j $TOR_CHAIN$" <<< "$rules"; do
                    sudo iptables -t nat -D OUTPUT -j "$TOR_CHAIN" || { failed=1; break; }
                    rules=$(sudo iptables -t nat -S) || { failed=1; break; }
                done
                sudo iptables -t nat -F "$TOR_CHAIN" || failed=1
                sudo iptables -t nat -X "$TOR_CHAIN" || failed=1
            fi
        else
            failed=1
        fi
    fi
    [ "$failed" = 0 ] || { echo 'Firewall cleanup failed; Tor and recovery settings retained. Retry stop.' >&2; return 1; }
    if [ -f "$TOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$TOR_PID_FILE")
        if tor_pid_matches "$pid"; then
            sudo kill -TERM "$pid" || failed=1
            local waited
            for waited in 1 2 3 4 5; do
                sudo kill -0 "$pid" 2>/dev/null || break
                sleep 1
            done
            # Recheck process identity before escalation (PID reuse).
            if tor_pid_matches "$pid"; then sudo kill -KILL "$pid" || failed=1; fi
        fi
    fi
    sudo python3 "$SCRIPT_DIR/tor-dns.py" restore "$DATA_DIR/tor-dns.json" || failed=1
    tor_restore_ipv6 || failed=1
    [ "$failed" = 0 ] || { echo "Tor cleanup incomplete; run '$0 stop' to retry. Recovery state retained." >&2; return 1; }
    if [ -f "$DATA_DIR/tor-runtime" ]; then
        local runtime
        runtime=$(cat "$DATA_DIR/tor-runtime")
        sudo rm -rf -- "$runtime" || return 1
    fi
    rm -f "$DATA_DIR/tor-runtime" "$DATA_DIR/tor.pid" "$IPTABLES_RULES_FILE" "$ACTIVE_MODE_FILE"
    echo 'Tor stopped; previous DNS and IPv6 settings restored.'
}

function start_tor() (
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

    exec 8>"$DATA_DIR/tor.lock"
    flock -n 8 || { echo 'Another Tor operation is running.' >&2; return 1; }

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
    if is_our_openvpn_running; then
        echo -e "${YELLOW}⚠️  OpenVPN is currently active${NC}"
        echo -e "${YELLOW}Do you want to stop it and start Tor mode instead? (y/N)${NC} "
        read -r response
        if [[ "$response" =~ ^[yY]$ ]]; then
            cleanup || return 1
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
            stop_tor || return 1
            sleep 1
        else
            echo "Cancelled."
            return 1
        fi
    fi

    # --- Config + daemon startup ---

    [ -f "$SCRIPT_DIR/tor-dns.py" ] || { echo 'Missing tor-dns.py; reinstall VPNGate Manager.' >&2; return 1; }
    if [ -e "$DATA_DIR/tor-runtime" ] || [ -e "$DATA_DIR/tor-ipv6.state" ] || [ -e "$DATA_DIR/tor-dns.json" ]; then
        echo 'Tor recovery state exists; run stop before starting again.' >&2; return 1
    fi
    check_tor_ports_free "$TOR_SOCKS_PORT" "$TOR_TRANS_PORT" "$TOR_DNS_PORT" || return 1
    echo tor > "$ACTIVE_MODE_FILE"
    trap 'stop_tor' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    tor_create_runtime || return 1
    tor_save_ipv6 || return 1

    echo -e "${CYAN}🔧 Generating Tor configuration for exit country '${country_upper}'...${NC}"
    generate_torrc "$country_upper" "$TOR_SOCKS_PORT" || return 1

    rm -f "$TOR_LOG_FILE" "$TOR_PID_FILE"

    echo -e "${GREEN}🚀 Starting Tor daemon...${NC}"
    sudo tor -f "$TORRC_FILE" --User "$TOR_DAEMON_USER" --DataDirectory "$(dirname "$TORRC_FILE")/data" --pidfile "$TOR_PID_FILE" --runasdaemon 1 8>&-

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

    sudo python3 "$SCRIPT_DIR/tor-dns.py" prepare "$DATA_DIR/tor-dns.json" || return 1

    local tor_pid
    tor_pid=$(cat "$TOR_PID_FILE")

    if ! apply_tor_iptables "$tor_pid" "$TOR_TRANS_PORT" "$TOR_DNS_PORT"; then
        echo -e "${RED}❌ Failed to apply iptables rules, rolling back${NC}"
        stop_tor
        return 1
    fi

    # --- Exit IP verification (non-fatal) ---

    if ! verify_tor_transparent; then
        echo 'Transparent Tor DNS/TCP verification failed; rolling back.' >&2
        return 1
    fi

    echo ""
    echo -e "${YELLOW}⚠️  Only TCP and DNS traffic are routed through Tor. Other UDP traffic leaks outside the tunnel.${NC}"
    echo -e "${YELLOW}Useful commands:${NC}"
    echo -e "   ${GREEN}$0 status${NC}  - Show current status"
    echo -e "   ${GREEN}$0 stop${NC}    - Stop Tor mode"

    if [ "$mode" = "foreground" ]; then
        exec 8>&-
        echo -e "${YELLOW}   Press Ctrl+C to stop${NC}"
        tail -f "$TOR_LOG_FILE" &
        local tail_pid=$!
        trap 'kill "$tail_pid" 2>/dev/null || :; stop_vpn' EXIT
        while tor_pid_matches "$tor_pid"; do sleep 1; done
        kill "$tail_pid" 2>/dev/null || :
        wait "$tail_pid" 2>/dev/null || :
    else
        trap - EXIT INT TERM
    fi

    return 0
)

# ---------------------------------------------------------------------------
# Netns-isolated VPN mode (host routing table is never touched)
# ---------------------------------------------------------------------------
# One namespace at a time: the dedicated /30 adds only a connected host route.
NETNS_SUBNET_HOST="10.200.200.1"
NETNS_SUBNET_NS="10.200.200.2"
NETNS_SOCKS_PORT=1080

function netns_valid_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,48}$ ]]; }
function netns_iface_names() {
    local h
    h=$(printf '%s' "$1" | md5sum | cut -c1-6)
    echo "vgh-${h}" "vgc-${h}"
}
function netns_chain_name() { printf 'VPNGATE_NETNS_%s\n' "$(printf '%s' "$1" | md5sum | cut -c1-8)"; }
function netns_dir() { printf '%s/netns/%s\n' "$DATA_DIR" "$1"; }
function netns_exists() { sudo ip netns list | awk -v ns="$1" '$1 == ns {found=1} END {exit !found}'; }
function netns_uplink_iface() {
    ip -4 route show default | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}
function netns_subnet_available() {
    local routes
    routes=$(ip -j -4 route show table all) || return 1
    python3 -c 'import ipaddress, json, sys
subnet = ipaddress.ip_network("10.200.200.0/30")
for route in json.load(sys.stdin):
    destination = route.get("dst", "default")
    if destination == "default":
        continue
    network = ipaddress.ip_network(destination, strict=False)
    if network.prefixlen and network.overlaps(subnet):
        sys.exit(1)
' <<< "$routes"
}
function netns_start() (
    local filter="$1" ns="${2:-tennis-vpn}" index="${3:-1}"
    netns_valid_name "$ns" && [[ "$index" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid namespace name or server index' >&2; return 1; }
    local tool
    for tool in ip iptables openvpn python3 flock; do
        command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; return 1; }
    done
    [ -f "$SCRIPT_DIR/netns-socks5.py" ] || { echo 'Missing installed netns-socks5.py helper' >&2; return 1; }
    mkdir -p "$DATA_DIR/netns"
    exec 9>"$DATA_DIR/netns/.lock"
    flock -n 9 || { echo 'Another namespace operation is running' >&2; return 1; }
    # Fixed addressing intentionally supports a single managed namespace.
    if compgen -G "$DATA_DIR/netns/*/owned" >/dev/null || netns_exists "$ns" || [ -e "/etc/netns/$ns" ]; then
        echo 'Namespace or managed session already exists; stop it first' >&2; return 1
    fi
    if ! netns_subnet_available; then
        echo 'Dedicated subnet 10.200.200.0/30 conflicts with an existing host route' >&2; return 1
    fi
    local ovpn_file uplink veth_h veth_c chain nsdir
    ovpn_file=$(resolve_ovpn_for_exec "$filter" "$index") || return 1
    [ -f "$ovpn_file" ] || return 1
    uplink=$(netns_uplink_iface)
    [ -n "$uplink" ] || { echo 'No host default uplink' >&2; return 1; }
    read -r veth_h veth_c <<< "$(netns_iface_names "$ns")"
    chain=$(netns_chain_name "$ns")
    nsdir=$(netns_dir "$ns")
    mkdir -p "$nsdir" || return 1
    # Save state before the first mutation; failed and interrupted starts roll back.
    sudo sysctl -n net.ipv4.ip_forward > "$nsdir/ip_forward" || return 1
    printf '%s\n' "$uplink" > "$nsdir/uplink"
    touch "$nsdir/owned"
    trap 'netns_stop "$ns" unlocked' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    sudo ip netns add "$ns" || return 1
    touch "$nsdir/namespace"
    sudo ip link add "$veth_h" type veth peer name "$veth_c" netns "$ns" || return 1
    touch "$nsdir/veth"
    sudo ip addr add "${NETNS_SUBNET_HOST}/30" dev "$veth_h" || return 1
    sudo ip link set "$veth_h" up || return 1
    sudo ip netns exec "$ns" ip addr add "${NETNS_SUBNET_NS}/30" dev "$veth_c" || return 1
    sudo ip netns exec "$ns" ip link set "$veth_c" up || return 1
    sudo ip netns exec "$ns" ip link set lo up || return 1
    sudo ip netns exec "$ns" ip route add default via "$NETNS_SUBNET_HOST" || return 1
    sudo ip netns exec "$ns" sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null || return 1
    # Fail closed: only OpenVPN's marked control socket can leave through veth.
    # Proxy traffic and remote DNS must use tun0, even after the tunnel disappears.
    sudo ip netns exec "$ns" iptables -P INPUT DROP || return 1
    sudo ip netns exec "$ns" iptables -A INPUT -i lo -j ACCEPT || return 1
    sudo ip netns exec "$ns" iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
    sudo ip netns exec "$ns" iptables -A INPUT -i "$veth_c" -s "$NETNS_SUBNET_HOST" -p tcp --dport "$NETNS_SOCKS_PORT" -j ACCEPT || return 1
    sudo ip netns exec "$ns" iptables -P OUTPUT DROP || return 1
    sudo ip netns exec "$ns" iptables -A OUTPUT -o lo -j ACCEPT || return 1
    sudo ip netns exec "$ns" iptables -A OUTPUT -o tun0 -j ACCEPT || return 1
    sudo ip netns exec "$ns" iptables -A OUTPUT -o "$veth_c" -m mark --mark 51820 -j ACCEPT || return 1
    sudo ip netns exec "$ns" iptables -A OUTPUT -o "$veth_c" -d "$NETNS_SUBNET_HOST" -p tcp --sport "$NETNS_SOCKS_PORT" -m conntrack --ctstate ESTABLISHED -j ACCEPT || return 1
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null || return 1
    touch "$nsdir/forwarding"
    sudo iptables -t nat -N "$chain" || return 1
    touch "$nsdir/chain"
    sudo iptables -t nat -A "$chain" -s "${NETNS_SUBNET_NS}/32" -o "$uplink" -j MASQUERADE || return 1
    sudo iptables -t nat -A POSTROUTING -j "$chain" || return 1
    sudo iptables -I FORWARD -i "$veth_h" -o "$uplink" -s "${NETNS_SUBNET_NS}/32" -m comment --comment "$chain" -j ACCEPT || return 1
    touch "$nsdir/outgoing"
    sudo iptables -I FORWARD -i "$uplink" -o "$veth_h" -d "${NETNS_SUBNET_NS}/32" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$chain" -j ACCEPT || return 1
    touch "$nsdir/incoming"
    sudo mkdir "/etc/netns/$ns" || return 1
    touch "$nsdir/dns"
    printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' | sudo tee "/etc/netns/$ns/resolv.conf" >/dev/null || return 1
    # VPNGate profiles use numeric remotes. Refuse hostnames rather than opening
    # a DNS bypass before the VPN has connected.
    if ! awk '$1 == "remote" {if ($2 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) bad=1; count++} END {exit bad || !count}' "$ovpn_file"; then
        echo 'Namespace mode requires numeric IPv4 OpenVPN remote addresses' >&2; return 1
    fi
    local vpn_log="$nsdir/openvpn.log"
    sudo ip netns exec "$ns" openvpn --config "$ovpn_file" --dev tun0 --redirect-gateway def1 --mark 51820 \
        --data-ciphers AES-128-CBC:AES-256-CBC:AES-128-GCM:AES-256-GCM \
        --script-security 1 --auth-retry none --daemon --log "$vpn_log" --writepid "$nsdir/openvpn.pid" 9>&- || return 1
    local waited=0
    while [ "$waited" -lt 60 ]; do
        if grep -q 'AUTH_FAILED\|Exiting due to fatal error' "$vpn_log" 2>/dev/null; then
            echo 'OpenVPN rejected the connection' >&2; return 1
        fi
        if grep -q 'Initialization Sequence Completed' "$vpn_log" 2>/dev/null && sudo ip netns exec "$ns" ip link show tun0 >/dev/null 2>&1; then break; fi
        sleep 1; waited=$((waited + 1))
    done
    [ "$waited" -lt 60 ] || { echo 'OpenVPN connection timed out' >&2; return 1; }
    sudo ip netns exec "$ns" python3 "$SCRIPT_DIR/netns-socks5.py" "$NETNS_SUBNET_NS" "$NETNS_SOCKS_PORT" > "$nsdir/socks5.log" 2>&1 9>&- &
    local proxy_launcher=$!
    # Verify an actual SOCKS5 greeting, not a process name shared by other namespaces.
    local ready=0
    for waited in 1 2 3 4 5; do
        if python3 - "$NETNS_SUBNET_NS" "$NETNS_SOCKS_PORT" <<'PY'
import socket, sys
try:
    with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=1) as s:
        s.sendall(b'\x05\x01\x00')
        if s.recv(2) != b'\x05\x00': raise OSError('Bad SOCKS greeting')
except OSError:
    sys.exit(1)
PY
        then ready=1; break; fi
        kill -0 "$proxy_launcher" 2>/dev/null || break
        sleep 1
    done
    [ "$ready" = 1 ] || { echo 'SOCKS5 proxy failed to become ready' >&2; return 1; }
    trap - EXIT INT TERM
    echo "Namespace '$ns' ready: socks5h://${NETNS_SUBNET_NS}:${NETNS_SOCKS_PORT}"
)
function netns_status() {
    local ns="${1:-tennis-vpn}"
    netns_valid_name "$ns" || return 1
    [ -f "$(netns_dir "$ns")/owned" ] && netns_exists "$ns" || { echo 'No managed namespace session'; return 1; }
    echo "SOCKS5 proxy: socks5h://${NETNS_SUBNET_NS}:${NETNS_SOCKS_PORT}"
    sudo ip netns exec "$ns" ip link show tun0 >/dev/null 2>&1 || { echo 'VPN tunnel unavailable (proxy egress blocked)'; return 1; }
    curl --fail --silent --show-error --max-time 10 --noproxy '' --socks5-hostname "${NETNS_SUBNET_NS}:${NETNS_SOCKS_PORT}" https://api.ipify.org
}
function netns_stop() (
    local ns="${1:-tennis-vpn}" nsdir veth_h veth_c chain uplink pid failed=0
    netns_valid_name "$ns" || { echo 'Invalid namespace name' >&2; return 1; }
    nsdir=$(netns_dir "$ns")
    [ -f "$nsdir/owned" ] || { echo "No managed namespace '$ns' to stop"; return 0; }
    if [ "${2:-}" != unlocked ]; then
        exec 9>"$DATA_DIR/netns/.lock"
        flock -n 9 || { echo 'Another namespace operation is running' >&2; return 1; }
    fi
    read -r veth_h veth_c <<< "$(netns_iface_names "$ns")"
    chain=$(netns_chain_name "$ns")
    uplink=$(cat "$nsdir/uplink") || return 1
    # Query failures are not evidence of absence: retain recovery state on error.
    local namespaces links nat_rules='' forward_rules='' current_forward='' pids
    namespaces=$(sudo ip netns list) || return 1
    links=$(ip -o link show) || return 1
    if [ -f "$nsdir/chain" ]; then nat_rules=$(sudo iptables -t nat -S) || return 1; fi
    if [ -f "$nsdir/outgoing" ] || [ -f "$nsdir/incoming" ]; then
        forward_rules=$(sudo iptables -S FORWARD) || return 1
    fi
    if [ -f "$nsdir/forwarding" ]; then current_forward=$(sudo sysctl -n net.ipv4.ip_forward) || return 1; fi
    if [ -f "$nsdir/namespace" ] && awk -v ns="$ns" '$1 == ns {found=1} END {exit !found}' <<< "$namespaces"; then
        # ip netns exec does not isolate the PID namespace. Never use pkill here.
        pids=$(sudo ip netns pids "$ns") || return 1
        for pid in $pids; do sudo kill -TERM "$pid" 2>/dev/null || :; done
        sleep 1
        pids=$(sudo ip netns pids "$ns") || return 1
        for pid in $pids; do sudo kill -KILL "$pid" 2>/dev/null || :; done
        sudo ip netns del "$ns" || failed=1
    fi
    links=$(ip -o link show) || return 1
    if [ -f "$nsdir/veth" ] && grep -q ": ${veth_h}[:@]" <<< "$links"; then sudo ip link del "$veth_h" || failed=1; fi
    if [ -f "$nsdir/chain" ] && grep -Fxq -- "-N $chain" <<< "$nat_rules"; then
        if grep -Fxq -- "-A POSTROUTING -j $chain" <<< "$nat_rules"; then sudo iptables -t nat -D POSTROUTING -j "$chain" || failed=1; fi
        sudo iptables -t nat -F "$chain" || failed=1
        sudo iptables -t nat -X "$chain" || failed=1
    fi
    local rule
    for rule in outgoing incoming; do
        [ -f "$nsdir/$rule" ] || continue
        local args
        if [ "$rule" = outgoing ]; then
            args=(-i "$veth_h" -o "$uplink" -s "${NETNS_SUBNET_NS}/32" -m comment --comment "$chain" -j ACCEPT)
        else
            args=(-i "$uplink" -o "$veth_h" -d "${NETNS_SUBNET_NS}/32" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$chain" -j ACCEPT)
        fi
        local direction="-i $veth_h"
        [ "$rule" = incoming ] && direction="-o $veth_h"
        if grep -F -- "--comment $chain " <<< "$forward_rules" | grep -Fq -- "$direction "; then
            sudo iptables -D FORWARD "${args[@]}" || failed=1
        fi
    done
    # Restore the saved forwarding value if the session-enabled value remains.
    if [ -f "$nsdir/forwarding" ] && [ "$current_forward" = 1 ]; then
        sudo sysctl -w "net.ipv4.ip_forward=$(cat "$nsdir/ip_forward")" >/dev/null || failed=1
    fi
    if [ -f "$nsdir/dns" ]; then
        sudo rm -f "/etc/netns/$ns/resolv.conf" || failed=1
        if [ -d "/etc/netns/$ns" ]; then sudo rmdir "/etc/netns/$ns" || failed=1; fi
    fi
    [ "$failed" = 0 ] || { echo 'Cleanup incomplete; state retained for retry' >&2; return 1; }
    rm -rf -- "$nsdir"
    echo "Namespace '$ns' stopped"
)

function stop_vpn() (
    exec 8>"$DATA_DIR/tor.lock"
    flock -n 8 || { echo 'Another Tor operation is running.' >&2; return 1; }
    if [ "$(cat "$ACTIVE_MODE_FILE" 2>/dev/null)" = tor ] || [ -e "$DATA_DIR/tor-runtime" ] || [ -e "$DATA_DIR/tor-ipv6.state" ] || [ -e "$DATA_DIR/tor-dns.json" ]; then
        stop_tor
    else
        cleanup
    fi
)

function show_help() {
    echo -e "${CYAN}VPNGate Manager - VPN Manager${NC}\n"
    echo -e "${YELLOW}Usage:${NC}"
    echo "  $0 [command] [options]"
    echo ""
    echo -e "${YELLOW}Commands:${NC}"
    echo -e "  ${GREEN}start [country] [--auto] [-f]${NC}  Connect to a VPN"
    echo "                        - Without argument: show all available VPN servers"
    echo "                        - With country: filter by country (e.g. japan, france, US)"
    echo -e "                        - ${CYAN}-f${NC} : foreground mode (shows logs)"
    echo ""
    echo -e "  ${GREEN}local [--file PATH] [-f]${NC}            Use a local .ovpn file"
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
    echo -e "  ${GREEN}netns-start [country] [ns=tennis-vpn] [n=1]${NC}"
    echo "                        Start a VPN fully isolated in a network namespace"
    echo "                        - Existing host routes/default IP are preserved; adds a temporary /30 link"
    echo "                        - Exposes a SOCKS5 proxy reachable from the host"
    echo "                        - For scripts/agents/timers; never changes the user's own connectivity"
    echo -e "  ${GREEN}netns-status [ns=tennis-vpn]${NC}  Show proxy URL + exit IP"
    echo -e "  ${GREEN}netns-stop [ns=tennis-vpn]${NC}    Tear down namespace, veth, iptables chain, proxy"
    echo ""
    echo -e "  ${GREEN}status${NC}                Show connection status (OpenVPN or Tor)"
    echo ""
    echo -e "  ${GREEN}logs${NC}                  Show logs in real time"
    echo ""
    echo -e "  ${GREEN}refresh${NC}               Force refresh of the VPN list"
    echo ""
    echo -e "  ${GREEN}exec [country] -- <cmd...>${NC}  Run <cmd> through the VPN only,"
    echo "                        via vopono, in an isolated network namespace"
    echo "                        - The rest of the system's traffic is unaffected"
    echo "                        - Server is picked automatically (non-interactive)"
    echo -e "                        - Requires: ${CYAN}vopono${NC} (https://github.com/jamesmcm/vopono)"
    echo ""
    echo '  dns benchmark|status|enable|restore  Optional Cloudflare DNS (no tunnel)'
    echo '  purge                 Remove inactive cache/config/log artifacts'
    echo '  VPNGATE_DATA_DIR=/absolute/path  Override the data/config directory'
    echo ''
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
    echo "  $0 exec -- curl ifconfig.me         # Just this command through the VPN"
    echo "  $0 exec japan -- firefox            # Same, forced through a Japanese server"
    echo ""
}

# Explicit non-interactive selection; automated jobs should prefer netns-start.
function start_command() {
    local auto=0 country='' mode=daemon arg
    for arg in "$@"; do
        case "$arg" in
            --auto) auto=1 ;;
            -f) mode=foreground ;;
            -*) echo "Unknown start option: $arg" >&2; return 1 ;;
            *) [ -z "$country" ] || { echo 'Only one country is allowed' >&2; return 1; }; country="$arg" ;;
        esac
    done
    if [ "$auto" = 1 ]; then
        local config
        config=$(resolve_ovpn_for_exec "$country") || return 1
        [ -n "$config" ] || return 1
        start_vpn "$config" "$mode"
    else
        [ -t 0 ] || { echo 'Interactive selection needs a terminal; use start --auto or netns-start.' >&2; return 1; }
        select_vpn "$country" "$mode"
    fi
}

function local_command() {
    local file='' mode=daemon
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --file) [ "$#" -ge 2 ] || { echo '--file requires a path' >&2; return 1; }; file="$2"; shift ;;
            -f) mode=foreground ;;
            *) echo "Unknown local option: $1" >&2; return 1 ;;
        esac
        shift
    done
    if [ -n "$file" ]; then
        start_vpn "$file" "$mode"
    else
        [ -t 0 ] || { echo 'Interactive selection needs a terminal; use local --file PATH.' >&2; return 1; }
        list_local_vpns "$mode"
    fi
}

function purge_artifacts() {
    # Restoration records are deliberately never purged: losing them can leave
    # DNS, forwarding or IPv6 settings modified after a crashed session.
    local state
    for state in "$ACTIVE_MODE_FILE" "$PID_FILE" "$TOR_PID_FILE" \
        "$DATA_DIR/tor-ipv6.state" "$DATA_DIR/tor-dns.json" \
        "$DATA_DIR/tor-runtime" "$DATA_DIR/cloudflare-dns.json" \
        /var/lib/vpngate-manager/cloudflare-dns/state.json; do
        if [ -e "$state" ] || [ -L "$state" ]; then
            echo "Refusing purge: session/recovery state exists ($state). Run stop/dns restore first." >&2
            return 1
        fi
    done
    if [ -d "$DATA_DIR/netns" ] && [ -n "$(find "$DATA_DIR/netns" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]; then
        echo 'Refusing purge: namespace recovery state exists; run netns-stop first.' >&2
        return 1
    fi
    find "$DATA_DIR" -maxdepth 1 -type f \( -name '*.ovpn' -o -name 'vpn.log' \
        -o -name 'tor.log' -o -name 'torrc.tmp' -o -name '.vpngate_cache.csv' \
        -o -name '.vpngate_cache.??????' -o -name '.vpn_selection_data' \
        -o -name '.local_vpn_list' \) -delete || return 1
    echo 'Cached lists, downloaded configs and inactive logs removed.'
}

function dns_command() {
    local action="${1:-status}"
    [ "$#" -eq 0 ] || shift
    case "$action" in
        benchmark|status) python3 "$SCRIPT_DIR/cloudflare-dns.py" "$action" "$@" ;;
        enable|restore)
            if [ "$action" = enable ] && { [ -e "$ACTIVE_MODE_FILE" ] || [ -e "$TOR_PID_FILE" ] || [ -e "$PID_FILE" ]; }; then
                echo 'Stop the host VPN/Tor session explicitly before enabling direct DNS.' >&2
                return 1
            fi
            sudo python3 "$SCRIPT_DIR/cloudflare-dns.py" "$action" "$@" ;;
        *) echo 'Usage: vpn dns benchmark|status|enable|restore [--samples N]' >&2; return 1 ;;
    esac
}


# Main menu
case "${1:-help}" in
    start)
        shift
        start_command "$@"
        ;;
    local)
        shift
        local_command "$@"
        ;;
    dns)
        shift
        dns_command "$@"
        ;;
    purge)
        purge_artifacts
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
    netns-start)
        netns_start "$2" "$3" "$4"
        ;;
    netns-status)
        netns_status "$2"
        ;;
    netns-stop)
        netns_stop "$2"
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
    exec)
        shift
        country=""
        if [ -n "$1" ] && [ "$1" != "--" ]; then
            country="$1"
            shift
        fi
        [ "$1" = "--" ] && shift
        exec_vpn "$country" "$@"
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

#!/bin/bash
# vpngate-manager.sh - Version 3.0 (Optimized Daemon)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VPN_DIR="$SCRIPT_DIR"

CACHE_FILE="$VPN_DIR/.vpngate_cache.csv"
CACHE_MAX_AGE=3600  # 1 hour
LOG_FILE="$VPN_DIR/vpn.log"
PID_FILE="$VPN_DIR/vpn.pid"

mkdir -p "$VPN_DIR"

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
    # Check whether the cache exists and is still recent
    if [ -f "$CACHE_FILE" ]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null)))
        if [ $cache_age -lt $CACHE_MAX_AGE ]; then
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
    local temp_data="$VPN_DIR/.vpn_selection_data"
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
    local ovpn_file="$VPN_DIR/${country}-vpngate_${ip}_udp.ovpn"
    
    echo "$base64_data" | base64 -d > "$ovpn_file" 2>/dev/null
    
    if [ $? -ne 0 ] || [ ! -s "$ovpn_file" ]; then
        echo -e "${RED}❌ Error while decoding the configuration${NC}"
        
        # Retry with --ignore-garbage
        echo "$base64_data" | base64 -d --ignore-garbage > "$ovpn_file" 2>/dev/null
        
        if [ $? -ne 0 ] || [ ! -s "$ovpn_file" ]; then
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
    local temp_local="$VPN_DIR/.local_vpn_list"
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
    done < <(find "$VPN_DIR" -name "*.ovpn" -type f 2>/dev/null | sort)
    
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
                
                local public_ip=$(timeout 5 curl -s ifconfig.me 2>/dev/null)
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

function cleanup() {
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
    
    echo -e "${GREEN}✅ VPN stopped cleanly${NC}"
}

function status() {
    echo -e "${CYAN}📊 VPN status:${NC}\n"
    
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
            local PUBLIC_IP=$(timeout 5 curl -s ifconfig.me 2>/dev/null)
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
    else
        echo -e "   ${RED}❌ OpenVPN is not running${NC}"
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

function stop_vpn() {
    if ! pgrep -x openvpn > /dev/null; then
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
    echo "                        - ${CYAN}-f${NC} : foreground mode (shows logs)"
    echo ""
    echo -e "  ${GREEN}local [-f]${NC}            Use a local .ovpn file"
    echo "                        - ${CYAN}-f${NC} : foreground mode"
    echo ""
    echo -e "  ${GREEN}stop${NC}                  Stop the VPN and clean up"
    echo ""
    echo -e "  ${GREEN}status${NC}                Show connection status"
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
    echo "  $0 status             # Check whether the VPN is active"
    echo "  $0 logs               # Follow logs in real time"
    echo "  $0 stop               # Stop the VPN"
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
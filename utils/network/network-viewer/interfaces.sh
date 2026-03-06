#!/bin/bash
# interfaces.sh — Network interface listing with IP, state, MAC, speed, type

# Detect interface type from sysfs
_iface_type() {
    local iface="$1"
    local sys="/sys/class/net/${iface}"

    if [[ "$iface" == "lo" ]]; then echo "loopback"; return; fi

    local type_id=""
    [[ -f "${sys}/type" ]] && type_id="$(cat "${sys}/type" 2>/dev/null)"

    if [[ -d "${sys}/wireless" ]] || [[ -d "${sys}/phy80211" ]]; then
        echo "wifi"
    elif [[ -f "${sys}/bridge" ]] || [[ -d "${sys}/bridge" ]]; then
        echo "bridge"
    elif [[ "$iface" == veth* ]]; then
        echo "veth"
    elif [[ "$iface" == tun* ]] || [[ "$iface" == tap* ]] || [[ "$type_id" == "65534" ]]; then
        echo "tun/tap"
    else
        echo "ethernet"
    fi
}

# Read interface speed from sysfs
_iface_speed() {
    local iface="$1"
    local speed_file="/sys/class/net/${iface}/speed"
    if [[ -r "$speed_file" ]]; then
        local spd
        spd=$(cat "$speed_file" 2>/dev/null)
        if [[ "$spd" =~ ^[0-9]+$ ]] && [[ "$spd" -gt 0 ]]; then
            echo "${spd}Mb/s"
            return
        fi
    fi
    echo "-"
}

# Column widths: iface=16, state=7, addr=30, mac=17, speed=9, type=free
# Total row width ≈ 97 chars
_IF_FMT="%-16s  %-7s  %-30s  %-17s  %-9s  %s\n"
_IF_SEP=97

# Show network interfaces table
show_interfaces() {
    print_header "Network Interfaces" $_IF_SEP

    printf "$_IF_FMT" "Interface" "State" "Address" "MAC" "Speed" "Type"
    print_separator "─" $_IF_SEP

    # Parse ip -o addr show
    while IFS= read -r line; do
        local iface state addr mac speed itype

        iface=$(echo "$line" | awk '{print $2}')
        addr=$(echo "$line"  | awk '{print $4}')
        [[ -z "$addr" ]] && addr="-"

        # Get state and MAC from ip link
        local link_info
        link_info=$(run_cmd ip link show "$iface" 2>/dev/null)
        state=$(echo "$link_info" | grep -oP '(?<=state )\S+' | head -1 || true)
        mac=$(echo "$link_info"   | awk '/ether/{print $2}' | head -1 || true)
        [[ -z "$state" ]] && state="UNKNOWN"
        [[ -z "$mac"   ]] && mac="00:00:00:00:00:00"

        speed=$(_iface_speed "$iface")
        itype=$(_iface_type  "$iface")

        # Truncate values that exceed their column width
        [[ ${#iface} -gt 16 ]] && iface="${iface:0:13}..."
        [[ ${#addr}  -gt 30 ]] && addr="${addr:0:27}..."

        local state_color="$NC"
        [[ "$state" == "UP"   ]] && state_color="$GREEN"
        [[ "$state" == "DOWN" ]] && state_color="$RED"

        printf "%-16s  ${state_color}%-7s${NC}  %-30s  %-17s  %-9s  %s\n" \
            "$iface" "$state" "$addr" "$mac" "$speed" "$itype"

    done < <(run_cmd ip -o addr show | awk -v ipv6="$SHOW_IPV6" '($3=="inet" || ipv6=="true") && !seen[$2$4]++')
}

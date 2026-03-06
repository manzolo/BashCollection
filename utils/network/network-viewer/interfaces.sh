#!/bin/bash
# interfaces.sh — Network interface listing with IP, state, MAC, speed, type

# Detect interface type from sysfs flags and naming conventions
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
    elif [[ "$iface" == wg* ]]; then
        echo "wireguard"
    elif [[ "$iface" == veth* ]]; then
        echo "veth"
    elif [[ "$iface" == ppp* ]]; then
        echo "ppp"
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

# Print one interface row (called once per address, or once with "-" if no address)
_print_iface_row() {
    local iface="$1" state="$2" addr="$3" mac="$4" speed="$5" itype="$6"

    [[ ${#iface} -gt 16 ]] && iface="${iface:0:13}..."
    [[ ${#addr}  -gt 30 ]] && addr="${addr:0:27}..."

    local state_color="$NC"
    [[ "$state" == "UP"      ]] && state_color="$GREEN"
    [[ "$state" == "DOWN"    ]] && state_color="$RED"

    printf "%-16s  ${state_color}%-7s${NC}  %-30s  %-17s  %-9s  %s\n" \
        "$iface" "$state" "$addr" "$mac" "$speed" "$itype"
}

# Show network interfaces table
# Enumerates ALL interfaces via "ip -br link show" (includes VPN, no-IP ifaces),
# then looks up addresses per interface so nothing is missed.
show_interfaces() {
    print_header "Network Interfaces" $_IF_SEP

    printf "$_IF_FMT" "Interface" "State" "Address" "MAC" "Speed" "Type"
    print_separator "─" $_IF_SEP

    # ip -br link show columns: IFACE  STATE  MAC  [flags...]
    while IFS= read -r linkline; do
        local iface state mac speed itype

        iface=$(echo "$linkline" | awk '{gsub(/@[^@]*$/, "", $1); print $1}')
        state=$(echo "$linkline" | awk '{print $2}')
        mac=$(echo "$linkline"   | awk '{print $3}')

        [[ -z "$state" ]] && state="UNKNOWN"
        # Virtual/tunnel interfaces report "(none)" as MAC
        [[ "$mac" == "(none)" || -z "$mac" ]] && mac="-"

        speed=$(_iface_speed "$iface")
        itype=$(_iface_type  "$iface")

        # Collect addresses for this interface (respecting the IPv6 filter)
        local -a addrs=()
        while IFS= read -r aline; do
            local addr
            addr=$(echo "$aline" | awk '{print $4}')
            [[ -n "$addr" ]] && addrs+=("$addr")
        done < <(run_cmd ip -o addr show dev "$iface" 2>/dev/null \
                 | awk -v ipv6="$SHOW_IPV6" '($3=="inet" || ipv6=="true")')

        if [[ ${#addrs[@]} -eq 0 ]]; then
            # Interface exists but has no addresses matching the current filter
            _print_iface_row "$iface" "$state" "-" "$mac" "$speed" "$itype"
        else
            for addr in "${addrs[@]}"; do
                _print_iface_row "$iface" "$state" "$addr" "$mac" "$speed" "$itype"
            done
        fi

    done < <(run_cmd ip -br link show)
}

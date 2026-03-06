#!/bin/bash
# routing.sh — IPv4 and IPv6 routing table with annotations

# Translate proto/scope fields to human-readable notes
_route_note() {
    local proto="$1" scope="$2" dest="$3"
    if [[ "$dest" == "default" ]]; then
        echo "Default gateway"
    elif [[ "$proto" == "kernel" ]]; then
        echo "Local network"
    elif [[ "$proto" == "dhcp"   ]]; then
        echo "DHCP assigned"
    elif [[ "$proto" == "static" ]]; then
        echo "Static route"
    elif [[ "$proto" == "boot"   ]]; then
        echo "Boot-time route"
    elif [[ "$scope" == "host"   ]]; then
        echo "Host route"
    elif [[ "$scope" == "link"   ]]; then
        echo "Link-local"
    else
        echo "-"
    fi
}

# Column widths: dest=26, gw=18, iface=16, proto=8, note=free
# Total row width ≈ 91 chars
_RT_FMT="%-26s  %-18s  %-16s  %-8s  %s\n"
_RT_SEP=91

# Print one routing table (IPv4 or IPv6)
_print_route_table() {
    local family="$1"   # "inet" or "inet6"
    local label="$2"

    echo -e "\n${BLUE}${BOLD}${label}${NC}"

    printf "$_RT_FMT" "Destination" "Gateway" "Interface" "Proto" "Note"
    print_separator "─" $_RT_SEP

    local ip_args=("route" "show")
    [[ "$family" == "inet6" ]] && ip_args=("-6" "route" "show")

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local dest gw iface proto scope note

        dest=$(echo "$line"  | awk '{print $1}')
        iface=$(echo "$line" | grep -oP '(?<=dev )\S+' | head -1 || true)
        proto=$(echo "$line" | grep -oP '(?<=proto )\S+' | head -1 || true)
        scope=$(echo "$line" | grep -oP '(?<=scope )\S+' | head -1 || true)
        gw=$(echo "$line"    | grep -oP '(?<=via )\S+' | head -1 || true)

        [[ -z "$iface" ]] && iface="-"
        [[ -z "$proto" ]] && proto="-"
        [[ -z "$scope" ]] && scope="-"
        [[ -z "$gw"    ]] && gw="-"

        note=$(_route_note "$proto" "$scope" "$dest")

        # Truncate values that exceed their column width
        [[ ${#dest}  -gt 26 ]] && dest="${dest:0:23}..."
        [[ ${#gw}    -gt 18 ]] && gw="${gw:0:15}..."
        [[ ${#iface} -gt 16 ]] && iface="${iface:0:13}..."

        if [[ "$dest" == "default" ]]; then
            printf "${YELLOW}${BOLD}%-26s  %-18s  %-16s  %-8s  %s${NC}\n" \
                "$dest" "$gw" "$iface" "$proto" "$note"
        else
            printf "$_RT_FMT" "$dest" "$gw" "$iface" "$proto" "$note"
        fi

    done < <(run_cmd ip "${ip_args[@]}" 2>/dev/null)
}

# Show full routing table (IPv4 + IPv6)
show_routing() {
    print_header "Routing Table" $_RT_SEP
    _print_route_table "inet"  "IPv4 Routes"
    [[ "$SHOW_IPV6" == "true" ]] && _print_route_table "inet6" "IPv6 Routes" || true
}

# Column widths: network=26, iface=16, proto=8 → total 54
_NET_FMT="%-26s  %-16s  %-8s\n"
_NET_SEP=54

# Show only kernel (directly connected) networks
show_networks() {
    print_header "Networks and Subnets (directly connected)" $_NET_SEP

    printf "$_NET_FMT" "Network" "Interface" "Proto"
    print_separator "─" $_NET_SEP

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local dest iface proto

        dest=$(echo "$line"  | awk '{print $1}')
        iface=$(echo "$line" | grep -oP '(?<=dev )\S+' | head -1 || true)
        proto=$(echo "$line" | grep -oP '(?<=proto )\S+' | head -1 || true)

        [[ "$dest" == "default" ]] && continue
        [[ "$proto" != "kernel" ]] && continue

        [[ -z "$iface" ]] && iface="-"
        [[ -z "$proto" ]] && proto="-"

        [[ ${#iface} -gt 16 ]] && iface="${iface:0:13}..."

        printf "$_NET_FMT" "$dest" "$iface" "$proto"
    done < <(run_cmd ip route show 2>/dev/null)
}

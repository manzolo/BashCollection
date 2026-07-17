#!/bin/bash
# map.sh — Full network map: all sections in sequence

show_full_map() {
    local hostname
    hostname=$(hostname 2>/dev/null || echo "unknown")

    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    printf "  ║  %-52s║\n" "Network Map: ${hostname}"
    printf "  ║  %-52s║\n" "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # 1. Interfaces
    show_interfaces
    echo ""

    # 2. Directly connected networks
    show_networks
    echo ""

    # 3. Full routing table
    show_routing
    echo ""

    # 4. ARP neighbors
    print_header "ARP Neighbors (known local hosts)" 68

    # Column widths: ip=20, mac=17, iface=16, state=free → total 68
    local arp_fmt="%-20s  %-17s  %-16s  %s\n"
    printf "$arp_fmt" "IP Address" "MAC" "Interface" "State"
    print_separator "─" 68

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local ip mac iface state
        ip=$(echo "$line"    | awk '{print $1}')
        iface=$(echo "$line" | grep -oP '(?<=dev )\S+' | head -1 || true)
        mac=$(echo "$line"   | grep -oP '(?<=lladdr )[\da-f:]+' | head -1 || true)
        state=$(echo "$line" | awk '{print $NF}')

        [[ -z "$mac"   ]] && mac="(incomplete)"
        [[ -z "$iface" ]] && iface="-"

        [[ ${#ip}    -gt 20 ]] && ip="${ip:0:17}..."
        [[ ${#iface} -gt 16 ]] && iface="${iface:0:13}..."

        local st_color="$NC"
        [[ "$state" == "REACHABLE" ]] && st_color="$GREEN"
        [[ "$state" == "STALE"     ]] && st_color="$YELLOW"
        [[ "$state" == "FAILED"    ]] && st_color="$RED"

        printf "%-20s  %-17s  %-16s  ${st_color}%s${NC}\n" \
            "$ip" "$mac" "$iface" "$state"

    done < <(run_cmd ip neigh show 2>/dev/null | grep -v "^$")
}

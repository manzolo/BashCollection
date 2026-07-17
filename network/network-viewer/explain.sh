#!/bin/bash
# explain.sh — Explain which route would be used to reach an IP/host

# Resolve a hostname to an IP address
_resolve_host() {
    local host="$1"
    # Already an IP?
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
       [[ "$host" =~ ^[0-9a-fA-F:]+$ ]]; then
        echo "$host"
        return 0
    fi

    # Try getent first (no extra deps), then host command
    local resolved=""
    resolved=$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)
    if [[ -z "$resolved" ]] && command -v host &>/dev/null; then
        resolved=$(run_cmd host "$host" 2>/dev/null \
            | grep -oP '(?<=has address )[\d.]+' | head -1)
    fi
    echo "$resolved"
}

# Core explain logic — used both from CLI and interactive menu
_explain_ip() {
    local target="$1"

    local resolved
    resolved=$(_resolve_host "$target")

    if [[ -z "$resolved" ]]; then
        msg_err "Cannot resolve host: $target"
        return 1
    fi

    local route_output
    route_output=$(run_cmd ip route get "$resolved" 2>/dev/null || true)

    if [[ -z "$route_output" ]]; then
        msg_err "No route found for $resolved"
        return 1
    fi

    # Parse fields from `ip route get` output
    local via iface src

    via=$(echo "$route_output"   | grep -oP '(?<=via )[\d.a-fA-F:]+' | head -1 || true)
    iface=$(echo "$route_output" | grep -oP '(?<=dev )\S+' | head -1 || true)
    src=$(echo "$route_output"   | grep -oP '(?<=src )[\d.a-fA-F:]+' | head -1 || true)

    [[ -z "$via"   ]] && via="-"
    [[ -z "$iface" ]] && iface="-"
    [[ -z "$src"   ]] && src="-"

    # Find the matching route in the table
    local matching_route
    matching_route=$(run_cmd ip route show 2>/dev/null \
        | grep " dev $iface " | head -3 || true)

    # Determine reason
    local reason
    if echo "$route_output" | grep -q "via"; then
        reason="No specific route for ${resolved}; using gateway ${via}."
    else
        reason="Direct delivery on local network ${iface}."
    fi

    print_header "Route Explanation for: $target"

    if [[ "$target" != "$resolved" ]]; then
        printf "  %-16s %s\n" "Resolved IP:" "$resolved"
    fi
    printf "  %-16s %s\n" "Destination:"  "$resolved"
    printf "  %-16s %s\n" "Gateway:"      "$via"
    printf "  %-16s %s\n" "Interface:"    "$iface"
    printf "  %-16s %s\n" "Source IP:"    "$src"

    echo ""
    echo -e "  ${BOLD}Reason:${NC} $reason"

    if [[ -n "$matching_route" ]]; then
        echo ""
        echo -e "  ${CYAN}Matching routes:${NC}"
        while IFS= read -r r; do
            echo "    $r"
        done <<< "$matching_route"
    fi
}

# Interactive: ask for IP/host via whiptail
explain_route_interactive() {
    local target
    target=$(whiptail --title "Explain Route" \
        --inputbox "Enter IP address or hostname:" 10 50 \
        3>&1 1>&2 2>&3) || return

    [[ -z "$target" ]] && return

    _explain_ip "$target"
    press_enter
}

# CLI entry point: network-viewer --explain <host>
explain_route_cli() {
    local target="$1"
    _explain_ip "$target"
}

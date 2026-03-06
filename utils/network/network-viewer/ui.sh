#!/bin/bash
# ui.sh — Whiptail menu and display helpers for network-viewer

# Print a separator line (loop-based to handle multi-byte UTF-8 chars correctly)
print_separator() {
    local char="${1:-─}"
    local width="${2:-70}"
    local i
    for ((i = 0; i < width; i++)); do printf '%s' "$char"; done
    printf '\n'
}

# Print a section header; optional second arg sets separator width
print_header() {
    local title="$1"
    local width="${2:-70}"
    echo -e "\n${CYAN}${BOLD}${title}${NC}"
    print_separator "─" "$width"
}

# Press Enter to continue
press_enter() {
    echo ""
    read -rp "  Press Enter to continue..." _dummy
}

# Main interactive menu loop
run_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "Network Viewer" \
            --menu "Select an option:" 20 62 8 \
            "1" "Network interfaces" \
            "2" "Networks and subnets" \
            "3" "Routing table" \
            "4" "Explain route for IP/host" \
            "5" "Full network map" \
            "6" "Toggle IPv6 display  [$(ipv6_status)]" \
            "7" "Toggle debug mode    [$(debug_status)]" \
            "Q" "Quit" \
            3>&1 1>&2 2>&3) || break

        case "$choice" in
            1) show_interfaces;    press_enter ;;
            2) show_networks;      press_enter ;;
            3) show_routing;       press_enter ;;
            4) explain_route_interactive ;;
            5) show_full_map | less -R ;;
            6) toggle_ipv6 ;;
            7) toggle_debug ;;
            Q|q) break ;;
        esac
    done
}

debug_status() {
    if [[ "$DEBUG"     == "true" ]]; then echo "ON"; else echo "OFF"; fi
}

ipv6_status() {
    if [[ "$SHOW_IPV6" == "true" ]]; then echo "ON"; else echo "OFF"; fi
}

toggle_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        DEBUG=false
        msg_info "Debug mode disabled."
    else
        DEBUG=true
        msg_info "Debug mode enabled."
    fi
    press_enter
}

toggle_ipv6() {
    if [[ "$SHOW_IPV6" == "true" ]]; then
        SHOW_IPV6=false
        msg_info "IPv6 display disabled."
    else
        SHOW_IPV6=true
        msg_info "IPv6 display enabled."
    fi
    press_enter
}

# mfirewall module: rule creation (ports, services, IPs, custom)
# Sourced by mfirewall.sh — do not execute directly.
# =================== RULE MANAGEMENT ===================

add_rules() {
    while true; do
        local choice
        choice=$(whiptail --title "Add Firewall Rules" --menu "Choose rule type:" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
        "1" "Allow Specific Port" \
        "2" "Block Specific Port" \
        "3" "Limit Connections (Rate Limiting)" \
        "4" "Allow Service by Name" \
        "5" "Allow from Specific IP" \
        "6" "Allow from Subnet/Range" \
        "7" "Port Range Rules" \
        "8" "Application Profile Rules" \
        "9" "Custom Rule Builder" \
        "10" "Return to Main Menu" 3>&1 1>&2 2>&3) || true
        
        case $choice in
            1) add_port_rule "allow" ;;
            2) add_port_rule "deny" ;;
            3) add_port_rule "limit" ;;
            4) add_service_rule ;;
            5) add_ip_rule ;;
            6) add_subnet_rule ;;
            7) add_port_range_rule ;;
            8) add_app_profile_rule ;;
            9) custom_rule_builder ;;
            10|*) break ;;
        esac
    done
}

add_port_rule() {
    local action="$1"
    local port
    port=$(whiptail --title "Port Number" --inputbox "Enter port number (1-65535):\n\nExamples: 22 (SSH), 80 (HTTP), 443 (HTTPS), 8080" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
    if [ -n "$port" ] && [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        local protocol
        protocol=$(whiptail --title "Protocol" --menu "Select protocol:" $WT_HEIGHT $WT_WIDTH 3 \
        "tcp" "TCP Protocol" \
        "udp" "UDP Protocol" \
        "both" "Both TCP and UDP" 3>&1 1>&2 2>&3) || true
        
        if [ -n "$protocol" ]; then
            local comment
            comment=$(whiptail --title "Comment (Optional)" --inputbox "Add a comment for this rule (optional):" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
            local cmd=""
            case $protocol in
                "tcp") cmd="sudo ufw $action $port/tcp" ;;
                "udp") cmd="sudo ufw $action $port/udp" ;;
                "both") cmd="sudo ufw $action $port" ;;
            esac
            
            if [ -n "$comment" ]; then
                cmd+=" comment '$comment'"
            fi
            
            execute_command "$cmd" "$action port $port ($protocol)"
        fi
    else
        show_message "Invalid Input" "Invalid port number. Must be between 1 and 65535." "error"
    fi
}

add_service_rule() {
    local service
    service=$(whiptail --title "Service Name" --inputbox "Enter service name:\n\nCommon services:\nssh, http, https, ftp, smtp, pop3, imap\n\nService name:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
    if [ -n "$service" ]; then
        execute_command "sudo ufw allow $service" "Allow service: $service"
    fi
}

add_ip_rule() {
    local ip
    ip=$(whiptail --title "IP Address" --inputbox "Enter IP address:\n\nExample: 192.168.1.100\n\nIP Address:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
    if [ -n "$ip" ] && [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        if (( ${BASH_REMATCH[1]} <= 255 && ${BASH_REMATCH[2]} <= 255 && ${BASH_REMATCH[3]} <= 255 && ${BASH_REMATCH[4]} <= 255 )); then
            local choice
            choice=$(whiptail --title "IP Rule Type" --menu "Choose rule type for IP $ip:" $WT_HEIGHT $WT_WIDTH 4 \
            "1" "Allow all traffic from this IP" \
            "2" "Allow specific port from this IP" \
            "3" "Block all traffic from this IP" 3>&1 1>&2 2>&3) || true
            
            case $choice in
                1) execute_command "sudo ufw allow from $ip" "Allow all traffic from $ip" ;;
                2)
                    local port
                    port=$(whiptail --title "Port" --inputbox "Enter port number:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
                    if [[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
                        local proto
                        proto=$(whiptail --title "Protocol" --inputbox "Protocol (tcp/udp, default: tcp):" $WT_HEIGHT $WT_WIDTH "tcp" 3>&1 1>&2 2>&3) || true
                        proto=${proto:-tcp}
                        if [[ "$proto" == "tcp" || "$proto" == "udp" ]]; then
                            execute_command "sudo ufw allow proto $proto from $ip to any port $port" "Allow $ip to access port $port/$proto"
                        fi
                    fi
                    ;;
                3) execute_command "sudo ufw deny from $ip" "Block all traffic from $ip" ;;
            esac
        else
            show_message "Invalid IP" "Invalid IP address format" "error"
        fi
    else
        show_message "Invalid IP" "Invalid IP address format" "error"
    fi
}

add_subnet_rule() {
    local subnet
    subnet=$(whiptail --title "Subnet" --inputbox "Enter subnet in CIDR notation:\n\nExamples:\n192.168.1.0/24 (local network)\n10.0.0.0/8 (large private network)\n\nSubnet:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
    if [ -n "$subnet" ] && [[ $subnet =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        execute_command "sudo ufw allow from $subnet" "Allow traffic from subnet $subnet"
    else
        show_message "Invalid Subnet" "Invalid subnet format. Use CIDR notation (e.g., 192.168.1.0/24)" "error"
    fi
}

add_port_range_rule() {
    local port_range
    port_range=$(whiptail --title "Port Range" --inputbox "Enter port range:\n\nExample: 8000:8010\n\nPort Range:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
    if [ -n "$port_range" ] && [[ $port_range =~ ^[0-9]+:[0-9]+$ ]]; then
        local protocol
        protocol=$(whiptail --title "Protocol" --menu "Select protocol:" $WT_HEIGHT $WT_WIDTH 2 \
        "tcp" "TCP Protocol" \
        "udp" "UDP Protocol" 3>&1 1>&2 2>&3) || true
        
        if [ -n "$protocol" ]; then
            execute_command "sudo ufw allow $port_range/$protocol" "Allow port range $port_range ($protocol)"
        fi
    else
        show_message "Invalid Range" "Invalid port range format. Use start:end (e.g., 8000:8010)" "error"
    fi
}

add_app_profile_rule() {
    local app_list
    app_list=$(sudo ufw app list 2>/dev/null || echo "No application profiles available")
    local app_name
    app_name=$(whiptail --title "Application Profiles" --inputbox "$app_list\n\nEnter application profile name:" 20 $WT_WIDTH 3>&1 1>&2 2>&3) || true
    if [ -n "$app_name" ] && sudo ufw app info "$app_name" >/dev/null 2>&1; then
        execute_command "sudo ufw allow '$app_name'" "Allow application profile: $app_name"
    elif [ -n "$app_name" ]; then
        show_message "Profile Not Found" "Application profile '$app_name' not found" "error"
    fi
}

custom_rule_builder() {
    local action
    action=$(whiptail --title "Custom Rule Builder - Action" --menu "Select action:" $WT_HEIGHT $WT_WIDTH 4 \
    "allow" "Allow traffic" \
    "deny" "Deny traffic (silent)" \
    "reject" "Reject traffic (with response)" \
    "limit" "Rate limit traffic" 3>&1 1>&2 2>&3) || true
    
    if [ -z "$action" ]; then return; fi
    
    local rule_parts=("$action")
    
    # Direction
    local direction
    direction=$(whiptail --title "Direction (Optional)" --menu "Select direction:" $WT_HEIGHT $WT_WIDTH 3 \
    "in" "Incoming traffic" \
    "out" "Outgoing traffic" \
    "skip" "Skip (no direction specified)" 3>&1 1>&2 2>&3) || true
    
    if [ "$direction" != "skip" ] && [ -n "$direction" ]; then
        rule_parts+=("$direction")
    fi
    
    # From IP
    local from_ip
    from_ip=$(whiptail --title "From IP (Optional)" --inputbox "Enter source IP or subnet (leave empty to skip):\n\nExamples:\n192.168.1.100\n192.168.1.0/24" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
    if [ -n "$from_ip" ]; then
        rule_parts+=("from" "$from_ip")
    fi
    
    # To specification
    local to_spec
    to_spec=$(whiptail --title "To Specification" --inputbox "Enter destination (leave empty for 'any'):" $WT_HEIGHT $WT_WIDTH "any" 3>&1 1>&2 2>&3) || true
    to_spec=${to_spec:-any}
    rule_parts+=("to" "$to_spec")
    
    # Port
    local port
    port=$(whiptail --title "Port (Optional)" --inputbox "Enter port number (leave empty to skip):" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
    if [ -n "$port" ]; then
        rule_parts+=("port" "$port")
    fi
    
    # Protocol
    local protocol
    protocol=$(whiptail --title "Protocol (Optional)" --menu "Select protocol:" $WT_HEIGHT $WT_WIDTH 4 \
    "tcp" "TCP Protocol" \
    "udp" "UDP Protocol" \
    "icmp" "ICMP Protocol" \
    "skip" "Skip protocol specification" 3>&1 1>&2 2>&3) || true
    
    if [ "$protocol" != "skip" ] && [ -n "$protocol" ]; then
        rule_parts+=("proto" "$protocol")
    fi
    
    # Comment
    local comment
    comment=$(whiptail --title "Comment (Optional)" --inputbox "Add a comment for this rule:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
    if [ -n "$comment" ]; then
        rule_parts+=("comment" "\"$comment\"")
    fi
    
    # Preview and confirm
    local final_cmd="sudo ufw ${rule_parts[*]}"
    if whiptail --title "Rule Preview" --yesno "Generated rule:\n\n$final_cmd\n\nAdd this custom rule?" $WT_HEIGHT $WT_WIDTH; then
        execute_command "$final_cmd" "Custom UFW rule"
    fi
}


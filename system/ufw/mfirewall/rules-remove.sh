# mfirewall module: rule removal
# Sourced by mfirewall.sh — do not execute directly.
# =================== REMOVE RULES ===================

remove_rules() {
    while true; do
        local choice
        choice=$(whiptail --title "Remove Firewall Rules" --menu "Choose removal method:" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
        "1" "Remove by Rule Number" \
        "2" "Remove by Port" \
        "3" "Remove by Service Name" \
        "4" "Remove by IP Address" \
        "5" "Remove Multiple Rules" \
        "6" "Remove All Rules (Reset)" \
        "7" "Return to Main Menu" 3>&1 1>&2 2>&3) || true
        
        case $choice in
            1) remove_by_number ;;
            2) remove_by_port ;;
            3) remove_by_service ;;
            4) remove_by_ip ;;
            5) remove_multiple_rules ;;
            6)
                if confirm_action "Remove ALL rules? This will reset UFW completely!\n\nWARNING: This action cannot be undone!"; then
                    execute_command "sudo ufw --force reset" "Remove all UFW rules" true
                fi
                ;;
            7|*) break ;;
        esac
    done
}

remove_by_number() {
    local rules_output
    rules_output=$(sudo ufw status numbered 2>/dev/null)
    if ! echo "$rules_output" | grep -q "^\["; then
        show_message "No Rules" "No numbered rules found" "error"
        return
    fi
    
    local rule_num
    
    rule_num=$(whiptail --title "Rule Number" --inputbox "Current numbered rules:\n\n$rules_output\n\nEnter rule number to remove:" 25 $WT_WIDTH 3>&1 1>&2 2>&3) || true
    if [ -n "$rule_num" ] && [[ $rule_num =~ ^[0-9]+$ ]]; then
        local rule_line
        rule_line=$(echo "$rules_output" | grep "^\[ *$rule_num\]")
        if [ -n "$rule_line" ]; then
            if confirm_action "Remove this rule?\n\n$rule_line"; then
                execute_command "sudo ufw delete $rule_num" "Remove rule number $rule_num" true
            fi
        else
            show_message "Rule Not Found" "Rule number $rule_num not found" "error"
        fi
    elif [ -n "$rule_num" ]; then
        show_message "Invalid Input" "Invalid rule number format" "error"
    fi
}

remove_by_port() {
    local port
    port=$(whiptail --title "Port Number" --inputbox "Enter port number to remove rules for:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
    if [ -n "$port" ] && [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        local choice
        choice=$(whiptail --title "Remove Port Rules" --menu "Select rule type to remove for port $port:" $WT_HEIGHT $WT_WIDTH 6 \
        "1" "Remove TCP allow rule" \
        "2" "Remove UDP allow rule" \
        "3" "Remove both TCP and UDP allow rules" \
        "4" "Remove TCP deny rule" \
        "5" "Remove UDP deny rule" \
        "6" "Remove all rules for this port" 3>&1 1>&2 2>&3) || true
        
        case $choice in
            1) execute_command "sudo ufw delete allow $port/tcp" "Remove TCP allow rule for port $port" true ;;
            2) execute_command "sudo ufw delete allow $port/udp" "Remove UDP allow rule for port $port" true ;;
            3) execute_command "sudo ufw delete allow $port" "Remove allow rules for port $port" true ;;
            4) execute_command "sudo ufw delete deny $port/tcp" "Remove TCP deny rule for port $port" true ;;
            5) execute_command "sudo ufw delete deny $port/udp" "Remove UDP deny rule for port $port" true ;;
            6)
                if confirm_action "Remove ALL rules for port $port?"; then
                    sudo ufw delete allow $port 2>/dev/null || true
                    sudo ufw delete deny $port 2>/dev/null || true
                    sudo ufw delete reject $port 2>/dev/null || true
                    show_message "Rules Removed" "All rules for port $port have been removed" "success"
                fi
                ;;
        esac
    else
        show_message "Invalid Port" "Invalid port number (must be 1-65535)" "error"
    fi
}

remove_by_service() {
    local service
    service=$(whiptail --title "Service Name" --inputbox "Enter service name to remove:\n\nExamples: ssh, http, https, ftp" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
    if [ -n "$service" ]; then
        execute_command "sudo ufw delete allow $service" "Remove rule for service $service"
    fi
}

remove_by_ip() {
    local ip
    ip=$(whiptail --title "IP Address" --inputbox "Enter IP address to remove rules for:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
    if [ -n "$ip" ] && [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        execute_command "sudo ufw delete allow from $ip" "Remove rules for IP $ip"
    else
        show_message "Invalid IP" "Invalid IP address format" "error"
    fi
}

remove_multiple_rules() {
    local rules_output
    rules_output=$(sudo ufw status numbered 2>/dev/null)
    if ! echo "$rules_output" | grep -q "^\["; then
        show_message "No Rules" "No numbered rules found" "error"
        return
    fi
    
    local rule_numbers
    
    rule_numbers=$(whiptail --title "Multiple Rule Removal" --inputbox "Current rules:\n\n$rules_output\n\nEnter rule numbers separated by spaces (e.g., 1 3 5):" 25 100 3>&1 1>&2 2>&3) || true
    if [ -n "$rule_numbers" ]; then
        local -a rules
        read -ra rules <<< "$rule_numbers"
        
        # Sort in descending order
        mapfile -t rules < <(printf '%s\n' "${rules[@]}" | sort -nr)
        
        local valid_rules=()
        local preview_text="Rules to be removed:\n\n"
        
        for rule in "${rules[@]}"; do
            if [[ $rule =~ ^[0-9]+$ ]]; then
                local rule_line
                rule_line=$(echo "$rules_output" | grep "^\[ *$rule\]")
                if [ -n "$rule_line" ]; then
                    valid_rules+=("$rule")
                    preview_text+="$rule_line\n"
                fi
            fi
        done
        
        if [ ${#valid_rules[@]} -gt 0 ]; then
            if whiptail --title "Confirm Multiple Removal" --yesno "$preview_text\nRemove ${#valid_rules[@]} rule(s)?" 20 100; then
                backup_configuration
                for rule in "${valid_rules[@]}"; do
                    sudo ufw --force delete "$rule" 2>/dev/null || true
                    sleep 0.5
                done
                show_message "Rules Removed" "${#valid_rules[@]} rules removed successfully" "success"
            fi
        else
            show_message "No Valid Rules" "No valid rules found to remove" "error"
        fi
    fi
}


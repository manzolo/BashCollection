# mfirewall module: main menu and basic UFW control
# Sourced by mfirewall.sh — do not execute directly.
# =================== MAIN MENU ===================

main_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "UFW Manager Professional v$SCRIPT_VERSION" --menu "Choose an option:" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
        "1" "View Detailed UFW Status" \
        "2" "Basic UFW Control" \
        "3" "Add Firewall Rules" \
        "4" "Remove Firewall Rules" \
        "5" "Advanced Rules Examples" \
        "6" "Bulk Rule Management" \
        "7" "Real-time Monitoring" \
        "8" "Logs & Analytics" \
        "9" "Predefined Configurations" \
        "10" "Security Audit" \
        "11" "Backup Configuration" \
        "12" "Restore Configuration" \
        "13" "System Information" \
        "14" "Exit" 3>&1 1>&2 2>&3) || true
        
        case $choice in
            1) show_detailed_status ;;
            2) manage_ufw_basic ;;
            3) add_rules ;;
            4) remove_rules ;;
            5) show_advanced_examples ;;
            6) bulk_rule_management ;;
            7) real_time_monitoring ;;
            8) log_management ;;
            9) predefined_configurations ;;
            10) security_audit ;;
            11) backup_configuration ;;
            12) restore_configuration ;;
            13) show_system_info ;;
            14) 
                if confirm_action "Exit UFW Manager Professional?"; then
                    echo "Thank you for using UFW Manager Professional!"
                    log_action "EXIT" "UFW Manager Professional session ended"
                    exit 0
                fi
                ;;
            *) 
                if [ -z "$choice" ]; then
                    if confirm_action "Exit UFW Manager Professional?"; then
                        exit 0
                    fi
                fi
                ;;
        esac
    done
}

manage_ufw_basic() {
    while true; do
        local ufw_status=""
        if command -v ufw &> /dev/null; then
            ufw_status=$(sudo ufw status | head -1 | awk '{print $2}' 2>/dev/null || echo "unknown")
        else
            ufw_status="not installed"
        fi
        
        local choice
        choice=$(whiptail --title "Basic UFW Management (Status: $ufw_status)" --menu "Choose action:" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
        "1" "Enable UFW" \
        "2" "Disable UFW" \
        "3" "Reset UFW (removes all rules)" \
        "4" "Reload UFW" \
        "5" "Show UFW Version" \
        "6" "Set Default Policies" \
        "7" "Return to Main Menu" 3>&1 1>&2 2>&3) || true
        
        case $choice in
            1) execute_command "sudo ufw enable" "Enable UFW firewall" true ;;
            2) execute_command "sudo ufw disable" "Disable UFW firewall" ;;
            3) 
                if confirm_action "Reset UFW completely? This will remove ALL rules!"; then
                    execute_command "sudo ufw --force reset" "Complete UFW reset" true
                fi
                ;;
            4) execute_command "sudo ufw reload" "Reload UFW configuration" ;;
            5) 
                local version_info
                version_info="UFW Version Information:\n$(ufw --version 2>/dev/null || echo 'Version information not available')"
                whiptail --title "UFW Version" --msgbox "$version_info" $WT_HEIGHT $WT_WIDTH || true
                ;;
            6) set_default_policies ;;
            7|*) break ;;
        esac
    done
}


# mfirewall module: status, real-time monitoring, log management
# Sourced by mfirewall.sh — do not execute directly.
# =================== STATUS AND MONITORING ===================

show_detailed_status() {
    local status_info=""
    
    # Get UFW status
    status_info+="FIREWALL STATUS:\n"
    status_info+="$(sudo ufw status verbose)\n\n"
    
    # Get numbered rules
    status_info+="NUMBERED RULES:\n"
    status_info+="$(sudo ufw status numbered)\n\n"
    
    # Get network interfaces
    status_info+="NETWORK INTERFACES:\n"
    status_info+="$(ip -brief addr show | head -5)\n\n"
    
    # Recent log entries
    status_info+="RECENT LOG ENTRIES:\n"
    status_info+="$(sudo tail -5 /var/log/ufw.log 2>/dev/null | grep -v "^$" || echo "No recent log entries")"
    
    whiptail --title "Detailed UFW Status" --scrolltext --msgbox "$status_info" 25 100 || true
}

real_time_monitoring() {
    show_message "Real-time Monitoring" "Real-time monitoring would require a separate terminal.\n\nUse this command in another terminal:\n\nsudo tail -f /var/log/ufw.log" "info"
}

log_management() {
    local choice
    choice=$(whiptail --title "Log Management" --menu "Choose log operation:" $WT_HEIGHT $WT_WIDTH 6 \
    "1" "View recent UFW logs" \
    "2" "Search logs by IP" \
    "3" "Search logs by port" \
    "4" "Log statistics" \
    "5" "Export logs" \
    "6" "Configure logging" 3>&1 1>&2 2>&3) || true
    
    case $choice in
        1)
            local recent_logs
            recent_logs=$(sudo tail -20 /var/log/ufw.log 2>/dev/null || echo "No logs found")
            whiptail --title "Recent UFW Logs" --scrolltext --msgbox "$recent_logs" 25 100 || true
            ;;
        2)
            local search_ip
            search_ip=$(whiptail --title "Search by IP" --inputbox "Enter IP address to search for:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
            if [ -n "$search_ip" ]; then
                local results
                results=$(grep "$search_ip" /var/log/ufw.log 2>/dev/null | tail -10 || echo "No matches found")
                whiptail --title "Search Results for $search_ip" --scrolltext --msgbox "$results" 25 100 || true
            fi
            ;;
        3)
            local search_port
            search_port=$(whiptail --title "Search by Port" --inputbox "Enter port number to search for:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3) || true
            if [ -n "$search_port" ]; then
                local results
                results=$(grep "DPT=$search_port" /var/log/ufw.log 2>/dev/null | tail -10 || echo "No matches found")
                whiptail --title "Search Results for Port $search_port" --scrolltext --msgbox "$results" 25 100 || true
            fi
            ;;
        4)
            local stats="LOG STATISTICS\n\n"
            stats+="Total log entries: $(wc -l /var/log/ufw.log 2>/dev/null | cut -d' ' -f1 || echo '0')\n\n"
            stats+="Most blocked IPs:\n"
            stats+="$(grep 'BLOCK' /var/log/ufw.log 2>/dev/null | awk '{print $13}' | cut -d'=' -f2 | sort | uniq -c | sort -nr | head -5 || echo 'No data')"
            whiptail --title "Log Statistics" --scrolltext --msgbox "$stats" $WT_HEIGHT $WT_WIDTH || true
            ;;
        5)
            local export_file
            export_file="/tmp/ufw_logs_$(date +%Y%m%d_%H%M%S).txt"
            sudo cp /var/log/ufw.log "$export_file" 2>/dev/null
            show_message "Logs Exported" "Logs exported to:\n$export_file" "success"
            ;;
        6)
            configure_logging
            ;;
    esac
}

configure_logging() {
    local current_logging
    current_logging=$(sudo ufw status verbose | grep "Logging:" || echo "Logging: unknown")
    local choice
    choice=$(whiptail --title "Configure Logging" --menu "$current_logging\n\nChoose logging option:" $WT_HEIGHT $WT_WIDTH 5 \
    "1" "Enable logging" \
    "2" "Disable logging" \
    "3" "Set logging level - Low" \
    "4" "Set logging level - Medium" \
    "5" "Set logging level - High" 3>&1 1>&2 2>&3) || true
    
    case $choice in
        1) execute_command "sudo ufw logging on" "Enable UFW logging" ;;
        2) execute_command "sudo ufw logging off" "Disable UFW logging" ;;
        3) execute_command "sudo ufw logging low" "Set logging level to low" ;;
        4) execute_command "sudo ufw logging medium" "Set logging level to medium" ;;
        5) execute_command "sudo ufw logging high" "Set logging level to high" ;;
    esac
}


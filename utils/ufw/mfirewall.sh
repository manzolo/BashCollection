#!/bin/bash
# PKG_NAME: mfirewall
# PKG_VERSION: 1.2.1
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), ufw, whiptail
# PKG_ALIASES: manzolo-firewall
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Advanced interactive UFW firewall manager
# PKG_LONG_DESCRIPTION: TUI-based tool for managing UFW firewall with advanced features.
#  .
#  Features:
#  - Interactive whiptail-based interface
#  - Enable/disable firewall
#  - Add/remove firewall rules
#  - Port management (allow/deny)
#  - Application profiles
#  - Rule backup and restore
#  - Status monitoring and logging
#  - Default policy configuration
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# UFW Manager - Advanced Interactive Firewall Management (Whiptail Version)
# Author: Manzolo
# Version: 1.2 - Fixed
# License: MIT
# Compatible: Ubuntu 18.04+, Debian 10+

set -euo pipefail
LANG=C
LC_ALL=C

# =================== CONFIGURATION ===================
readonly SCRIPT_VERSION="1.2"
readonly SCRIPT_NAME="Manzolo UFW Manager"
readonly LOG_FILE="/var/log/ufw-manager.log"
readonly CONFIG_FILE="/etc/ufw-manager/config.conf"
readonly BACKUP_DIR="/etc/ufw-manager/backups"

# Whiptail configuration
readonly WT_HEIGHT=20
readonly WT_WIDTH=78
readonly WT_MENU_HEIGHT=12

# =================== UTILITY FUNCTIONS ===================

# Enhanced logging function
log_action() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user=$(whoami)
    
    echo "[$timestamp] [$level] [$user] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# Whiptail message boxes
show_message() {
    local title="$1"
    local message="$2"
    local type="${3:-info}"
    
    case $type in
        "error")
            whiptail --title "ERROR - $title" --msgbox "$message" $WT_HEIGHT $WT_WIDTH
            ;;
        "success")
            whiptail --title "SUCCESS - $title" --msgbox "$message" $WT_HEIGHT $WT_WIDTH
            ;;
        "warning")
            whiptail --title "WARNING - $title" --msgbox "$message" $WT_HEIGHT $WT_WIDTH
            ;;
        *)
            whiptail --title "INFO - $title" --msgbox "$message" $WT_HEIGHT $WT_WIDTH
            ;;
    esac
    
    log_action "INFO" "$message"
}

# Whiptail confirmation
confirm_action() {
    local message="$1"
    
    if whiptail --title "Confirmation Required" --yesno "$message\n\nProceed with this action?" $WT_HEIGHT $WT_WIDTH --defaultno; then
        return 0
    else
        return 1
    fi
}

# Progress gauge
show_progress() {
    local message="$1"
    local steps="${2:-10}"
    
    for ((i=0; i<=$steps; i++)); do
        echo $((i * 100 / steps))
        sleep 0.1
    done | whiptail --title "Processing" --gauge "$message" 6 $WT_WIDTH 0
}

# System requirements check (silent)
check_system_requirements() {
    local requirements_met=true
    local error_msg=""
    
    # Check UFW installation
    if ! command -v ufw &> /dev/null; then
        error_msg+="UFW is not installed!\n"
        error_msg+="Install with: sudo apt update && sudo apt install ufw\n\n"
        requirements_met=false
    fi
    
    # Check whiptail installation
    if ! command -v whiptail &> /dev/null; then
        error_msg+="Whiptail is not installed!\n"
        error_msg+="Install with: sudo apt install whiptail\n\n"
        requirements_met=false
    fi
    
    if [ "$requirements_met" = false ]; then
        whiptail --title "System Requirements" --msgbox "$error_msg" $WT_HEIGHT $WT_WIDTH
        exit 1
    fi
}

# Create necessary directories
setup_directories() {
    local dirs=("/etc/ufw-manager" "$BACKUP_DIR")
    
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            sudo mkdir -p "$dir" 2>/dev/null || true
        fi
    done
    
    # Create log file with proper permissions
    if [ ! -f "$LOG_FILE" ]; then
        sudo touch "$LOG_FILE" 2>/dev/null || true
        sudo chmod 644 "$LOG_FILE" 2>/dev/null || true
        sudo chown "$USER":"$USER" "$LOG_FILE" 2>/dev/null || true
    else
        # Ensure existing log file has proper permissions
        sudo chmod 644 "$LOG_FILE" 2>/dev/null || true
        sudo chown "$USER":"$USER" "$LOG_FILE" 2>/dev/null || true
    fi
}

# Enhanced command execution
execute_command() {
    local cmd="$1"
    local description="$2"
    local backup_before="${3:-false}"
    
    local info_text="Command: $cmd\n\nDescription: $description"
    
    if [ "$backup_before" = "true" ]; then
        info_text+="\n\nWARNING: This operation will create a backup first"
    fi
    
    if whiptail --title "Execute Command" --yesno "$info_text\n\nExecute this command?" $WT_HEIGHT $WT_WIDTH --defaultno; then
        # Create backup if requested
        if [ "$backup_before" = "true" ]; then
            backup_configuration
        fi
        
        show_progress "Executing: $description" 5
        
        if eval "$cmd" &>/dev/null; then
            show_message "Command Executed" "$description completed successfully!" "success"
            log_action "SUCCESS" "Executed: $cmd"
        else
            show_message "Command Failed" "Failed to execute: $description" "error"
            log_action "ERROR" "Failed: $cmd"
        fi
    else
        show_message "Cancelled" "Command execution cancelled by user" "warning"
        log_action "CANCELLED" "User cancelled: $cmd"
    fi
}

# =================== BACKUP AND RESTORE ===================

backup_configuration() {
    local backup_file="$BACKUP_DIR/ufw_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    show_progress "Creating UFW configuration backup..." 3
    
    if sudo tar -czf "$backup_file" /etc/ufw/ /lib/ufw/ 2>/dev/null; then
        show_message "Backup Created" "Backup created successfully:\n$backup_file" "success"
        log_action "BACKUP" "Created backup: $backup_file"
    else
        show_message "Backup Failed" "Failed to create backup" "error"
    fi
}

restore_configuration() {
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        show_message "No Backups" "No backups found in $BACKUP_DIR" "error"
        return
    fi
    
    # Build menu options
    local menu_options=()
    local i=1
    
    while IFS= read -r -d '' backup; do
        local filename=$(basename "$backup")
        menu_options+=("$i" "$filename")
        ((i++))
    done < <(find "$BACKUP_DIR" -name "*.tar.gz" -print0 | sort -z)
    
    if [ ${#menu_options[@]} -eq 0 ]; then
        show_message "No Backups" "No backup files found" "error"
        return
    fi
    
    local choice=$(whiptail --title "Restore Configuration" --menu "Select backup to restore:" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT "${menu_options[@]}" 3>&1 1>&2 2>&3)
    
    if [ -n "$choice" ]; then
        local backup_file=$(find "$BACKUP_DIR" -name "*.tar.gz" | sort | sed -n "${choice}p")
        local filename=$(basename "$backup_file")
        
        if confirm_action "Restore from backup: $filename?\n\nThis will reset current UFW configuration!"; then
            show_progress "Restoring configuration..." 5
            sudo ufw --force reset >/dev/null 2>&1
            sudo tar -xzf "$backup_file" -C / 2>/dev/null
            sudo ufw reload >/dev/null 2>&1
            show_message "Restore Complete" "Configuration restored successfully from $filename" "success"
        fi
    fi
}

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
    
    whiptail --title "Detailed UFW Status" --scrolltext --msgbox "$status_info" 25 100
}

# =================== MAIN MENU ===================

main_menu() {
    while true; do
        local choice=$(whiptail --title "UFW Manager Professional v$SCRIPT_VERSION" --menu "Choose an option:" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
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
        "14" "Exit" 3>&1 1>&2 2>&3)
        
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
        
        local choice=$(whiptail --title "Basic UFW Management (Status: $ufw_status)" --menu "Choose action:" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
        "1" "Enable UFW" \
        "2" "Disable UFW" \
        "3" "Reset UFW (removes all rules)" \
        "4" "Reload UFW" \
        "5" "Show UFW Version" \
        "6" "Set Default Policies" \
        "7" "Return to Main Menu" 3>&1 1>&2 2>&3)
        
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
                local version_info="UFW Version Information:\n$(ufw --version 2>/dev/null || echo 'Version information not available')"
                whiptail --title "UFW Version" --msgbox "$version_info" $WT_HEIGHT $WT_WIDTH
                ;;
            6) set_default_policies ;;
            7|*) break ;;
        esac
    done
}

set_default_policies() {
    local current_policies="Current default policies:\n$(sudo ufw status verbose | grep 'Default:' || echo 'Could not retrieve current policies')"
    
    local choice=$(whiptail --title "Set Default Policies" --menu "$current_policies\n\nChoose policy set:" 20 $WT_WIDTH $WT_MENU_HEIGHT \
    "1" "Secure (deny incoming, allow outgoing)" \
    "2" "Restrictive (deny both incoming/outgoing)" \
    "3" "Permissive (allow both - NOT recommended)" \
    "4" "Custom Configuration" 3>&1 1>&2 2>&3)
    
    case $choice in
        1)
            if confirm_action "Apply secure default policies?\n(deny incoming, allow outgoing)"; then
                execute_command "sudo ufw default deny incoming && sudo ufw default allow outgoing" "Apply secure policies"
            fi
            ;;
        2)
            if confirm_action "Apply restrictive policies?\n\nWARNING: This may block internet access!"; then
                execute_command "sudo ufw default deny incoming && sudo ufw default deny outgoing" "Apply restrictive policies"
            fi
            ;;
        3)
            if confirm_action "Apply permissive policies?\n\nWARNING: This is less secure!"; then
                execute_command "sudo ufw default allow incoming && sudo ufw default allow outgoing" "Apply permissive policies"
            fi
            ;;
        4) custom_default_policies ;;
    esac
}

custom_default_policies() {
    local incoming=$(whiptail --title "Incoming Policy" --menu "Choose default policy for incoming connections:" $WT_HEIGHT $WT_WIDTH 3 \
    "allow" "Allow all incoming" \
    "deny" "Deny all incoming (recommended)" \
    "reject" "Reject all incoming" 3>&1 1>&2 2>&3)
    
    if [ -n "$incoming" ]; then
        local outgoing=$(whiptail --title "Outgoing Policy" --menu "Choose default policy for outgoing connections:" $WT_HEIGHT $WT_WIDTH 3 \
        "allow" "Allow all outgoing (recommended)" \
        "deny" "Deny all outgoing" \
        "reject" "Reject all outgoing" 3>&1 1>&2 2>&3)
        
        if [ -n "$outgoing" ]; then
            if confirm_action "Apply custom policies?\nIncoming: $incoming\nOutgoing: $outgoing"; then
                execute_command "sudo ufw default $incoming incoming && sudo ufw default $outgoing outgoing" "Apply custom policies"
            fi
        fi
    fi
}

# =================== RULE MANAGEMENT ===================

add_rules() {
    while true; do
        local choice=$(whiptail --title "Add Firewall Rules" --menu "Choose rule type:" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
        "1" "Allow Specific Port" \
        "2" "Block Specific Port" \
        "3" "Limit Connections (Rate Limiting)" \
        "4" "Allow Service by Name" \
        "5" "Allow from Specific IP" \
        "6" "Allow from Subnet/Range" \
        "7" "Port Range Rules" \
        "8" "Application Profile Rules" \
        "9" "Custom Rule Builder" \
        "10" "Return to Main Menu" 3>&1 1>&2 2>&3)
        
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
    local port=$(whiptail --title "Port Number" --inputbox "Enter port number (1-65535):\n\nExamples: 22 (SSH), 80 (HTTP), 443 (HTTPS), 8080" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
    
    if [ -n "$port" ] && [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        local protocol=$(whiptail --title "Protocol" --menu "Select protocol:" $WT_HEIGHT $WT_WIDTH 3 \
        "tcp" "TCP Protocol" \
        "udp" "UDP Protocol" \
        "both" "Both TCP and UDP" 3>&1 1>&2 2>&3)
        
        if [ -n "$protocol" ]; then
            local comment=$(whiptail --title "Comment (Optional)" --inputbox "Add a comment for this rule (optional):" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
            
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
    local service=$(whiptail --title "Service Name" --inputbox "Enter service name:\n\nCommon services:\nssh, http, https, ftp, smtp, pop3, imap\n\nService name:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
    
    if [ -n "$service" ]; then
        execute_command "sudo ufw allow $service" "Allow service: $service"
    fi
}

add_ip_rule() {
    local ip=$(whiptail --title "IP Address" --inputbox "Enter IP address:\n\nExample: 192.168.1.100\n\nIP Address:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
    
    if [ -n "$ip" ] && [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        if (( ${BASH_REMATCH[1]} <= 255 && ${BASH_REMATCH[2]} <= 255 && ${BASH_REMATCH[3]} <= 255 && ${BASH_REMATCH[4]} <= 255 )); then
            local choice=$(whiptail --title "IP Rule Type" --menu "Choose rule type for IP $ip:" $WT_HEIGHT $WT_WIDTH 4 \
            "1" "Allow all traffic from this IP" \
            "2" "Allow specific port from this IP" \
            "3" "Block all traffic from this IP" 3>&1 1>&2 2>&3)
            
            case $choice in
                1) execute_command "sudo ufw allow from $ip" "Allow all traffic from $ip" ;;
                2)
                    local port=$(whiptail --title "Port" --inputbox "Enter port number:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
                    if [[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
                        local proto=$(whiptail --title "Protocol" --inputbox "Protocol (tcp/udp, default: tcp):" $WT_HEIGHT $WT_WIDTH "tcp" 3>&1 1>&2 2>&3)
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
    local subnet=$(whiptail --title "Subnet" --inputbox "Enter subnet in CIDR notation:\n\nExamples:\n192.168.1.0/24 (local network)\n10.0.0.0/8 (large private network)\n\nSubnet:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
    
    if [ -n "$subnet" ] && [[ $subnet =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        execute_command "sudo ufw allow from $subnet" "Allow traffic from subnet $subnet"
    else
        show_message "Invalid Subnet" "Invalid subnet format. Use CIDR notation (e.g., 192.168.1.0/24)" "error"
    fi
}

add_port_range_rule() {
    local port_range=$(whiptail --title "Port Range" --inputbox "Enter port range:\n\nExample: 8000:8010\n\nPort Range:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
    
    if [ -n "$port_range" ] && [[ $port_range =~ ^[0-9]+:[0-9]+$ ]]; then
        local protocol=$(whiptail --title "Protocol" --menu "Select protocol:" $WT_HEIGHT $WT_WIDTH 2 \
        "tcp" "TCP Protocol" \
        "udp" "UDP Protocol" 3>&1 1>&2 2>&3)
        
        if [ -n "$protocol" ]; then
            execute_command "sudo ufw allow $port_range/$protocol" "Allow port range $port_range ($protocol)"
        fi
    else
        show_message "Invalid Range" "Invalid port range format. Use start:end (e.g., 8000:8010)" "error"
    fi
}

add_app_profile_rule() {
    local app_list=$(sudo ufw app list 2>/dev/null || echo "No application profiles available")
    local app_name=$(whiptail --title "Application Profiles" --inputbox "$app_list\n\nEnter application profile name:" 20 $WT_WIDTH 3>&1 1>&2 2>&3)
    
    if [ -n "$app_name" ] && sudo ufw app info "$app_name" >/dev/null 2>&1; then
        execute_command "sudo ufw allow '$app_name'" "Allow application profile: $app_name"
    elif [ -n "$app_name" ]; then
        show_message "Profile Not Found" "Application profile '$app_name' not found" "error"
    fi
}

custom_rule_builder() {
    local action=$(whiptail --title "Custom Rule Builder - Action" --menu "Select action:" $WT_HEIGHT $WT_WIDTH 4 \
    "allow" "Allow traffic" \
    "deny" "Deny traffic (silent)" \
    "reject" "Reject traffic (with response)" \
    "limit" "Rate limit traffic" 3>&1 1>&2 2>&3)
    
    if [ -z "$action" ]; then return; fi
    
    local rule_parts=("$action")
    
    # Direction
    local direction=$(whiptail --title "Direction (Optional)" --menu "Select direction:" $WT_HEIGHT $WT_WIDTH 3 \
    "in" "Incoming traffic" \
    "out" "Outgoing traffic" \
    "skip" "Skip (no direction specified)" 3>&1 1>&2 2>&3)
    
    if [ "$direction" != "skip" ] && [ -n "$direction" ]; then
        rule_parts+=("$direction")
    fi
    
    # From IP
    local from_ip=$(whiptail --title "From IP (Optional)" --inputbox "Enter source IP or subnet (leave empty to skip):\n\nExamples:\n192.168.1.100\n192.168.1.0/24" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
    
    if [ -n "$from_ip" ]; then
        rule_parts+=("from" "$from_ip")
    fi
    
    # To specification
    local to_spec=$(whiptail --title "To Specification" --inputbox "Enter destination (leave empty for 'any'):" $WT_HEIGHT $WT_WIDTH "any" 3>&1 1>&2 2>&3)
    to_spec=${to_spec:-any}
    rule_parts+=("to" "$to_spec")
    
    # Port
    local port=$(whiptail --title "Port (Optional)" --inputbox "Enter port number (leave empty to skip):" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
    
    if [ -n "$port" ]; then
        rule_parts+=("port" "$port")
    fi
    
    # Protocol
    local protocol=$(whiptail --title "Protocol (Optional)" --menu "Select protocol:" $WT_HEIGHT $WT_WIDTH 4 \
    "tcp" "TCP Protocol" \
    "udp" "UDP Protocol" \
    "icmp" "ICMP Protocol" \
    "skip" "Skip protocol specification" 3>&1 1>&2 2>&3)
    
    if [ "$protocol" != "skip" ] && [ -n "$protocol" ]; then
        rule_parts+=("proto" "$protocol")
    fi
    
    # Comment
    local comment=$(whiptail --title "Comment (Optional)" --inputbox "Add a comment for this rule:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
    
    if [ -n "$comment" ]; then
        rule_parts+=("comment" "\"$comment\"")
    fi
    
    # Preview and confirm
    local final_cmd="sudo ufw ${rule_parts[*]}"
    if whiptail --title "Rule Preview" --yesno "Generated rule:\n\n$final_cmd\n\nAdd this custom rule?" $WT_HEIGHT $WT_WIDTH; then
        execute_command "$final_cmd" "Custom UFW rule"
    fi
}

# =================== REMOVE RULES ===================

remove_rules() {
    while true; do
        local choice=$(whiptail --title "Remove Firewall Rules" --menu "Choose removal method:" $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
        "1" "Remove by Rule Number" \
        "2" "Remove by Port" \
        "3" "Remove by Service Name" \
        "4" "Remove by IP Address" \
        "5" "Remove Multiple Rules" \
        "6" "Remove All Rules (Reset)" \
        "7" "Return to Main Menu" 3>&1 1>&2 2>&3)
        
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
    local rules_output=$(sudo ufw status numbered 2>/dev/null)
    if ! echo "$rules_output" | grep -q "^\["; then
        show_message "No Rules" "No numbered rules found" "error"
        return
    fi
    
    local rule_num=$(whiptail --title "Rule Number" --inputbox "Current numbered rules:\n\n$rules_output\n\nEnter rule number to remove:" 25 $WT_WIDTH 3>&1 1>&2 2>&3)
    
    if [ -n "$rule_num" ] && [[ $rule_num =~ ^[0-9]+$ ]]; then
        local rule_line=$(echo "$rules_output" | grep "^\[ *$rule_num\]")
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
    local port=$(whiptail --title "Port Number" --inputbox "Enter port number to remove rules for:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
    
    if [ -n "$port" ] && [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        local choice=$(whiptail --title "Remove Port Rules" --menu "Select rule type to remove for port $port:" $WT_HEIGHT $WT_WIDTH 6 \
        "1" "Remove TCP allow rule" \
        "2" "Remove UDP allow rule" \
        "3" "Remove both TCP and UDP allow rules" \
        "4" "Remove TCP deny rule" \
        "5" "Remove UDP deny rule" \
        "6" "Remove all rules for this port" 3>&1 1>&2 2>&3)
        
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
    local service=$(whiptail --title "Service Name" --inputbox "Enter service name to remove:\n\nExamples: ssh, http, https, ftp" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
    
    if [ -n "$service" ]; then
        execute_command "sudo ufw delete allow $service" "Remove rule for service $service"
    fi
}

remove_by_ip() {
    local ip=$(whiptail --title "IP Address" --inputbox "Enter IP address to remove rules for:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
    
    if [ -n "$ip" ] && [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        execute_command "sudo ufw delete allow from $ip" "Remove rules for IP $ip"
    else
        show_message "Invalid IP" "Invalid IP address format" "error"
    fi
}

remove_multiple_rules() {
    local rules_output=$(sudo ufw status numbered 2>/dev/null)
    if ! echo "$rules_output" | grep -q "^\["; then
        show_message "No Rules" "No numbered rules found" "error"
        return
    fi
    
    local rule_numbers=$(whiptail --title "Multiple Rule Removal" --inputbox "Current rules:\n\n$rules_output\n\nEnter rule numbers separated by spaces (e.g., 1 3 5):" 25 100 3>&1 1>&2 2>&3)
    
    if [ -n "$rule_numbers" ]; then
        local -a rules
        read -ra rules <<< "$rule_numbers"
        
        # Sort in descending order
        local IFS=$'\n'
        rules=($(sort -nr <<<"${rules[*]}"))
        unset IFS
        
        local valid_rules=()
        local preview_text="Rules to be removed:\n\n"
        
        for rule in "${rules[@]}"; do
            if [[ $rule =~ ^[0-9]+$ ]]; then
                local rule_line=$(echo "$rules_output" | grep "^\[ *$rule\]")
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

# =================== ADVANCED FEATURES ===================

show_advanced_examples() {
    local examples_text="ADVANCED UFW COMMAND EXAMPLES\n\n"
    
    examples_text+="=== BASICS AND MANAGEMENT ===\n"
    examples_text+="1. Enable/disable UFW:\n"
    examples_text+="    sudo ufw enable\n    sudo ufw disable\n\n"
    
    examples_text+="2. Check status:\n"
    examples_text+="    sudo ufw status verbose\n    sudo ufw status numbered\n\n"
    
    examples_text+="=== BASIC RULES ===\n"
    examples_text+="3. Allow SSH from anywhere:\n"
    examples_text+="    sudo ufw allow ssh\n\n"
    
    examples_text+="4. Deny FTP traffic:\n"
    examples_text+="    sudo ufw deny 21/tcp\n\n"
    
    examples_text+="5. Limit SSH connections (anti-brute force):\n"
    examples_text+="    sudo ufw limit 22/tcp\n\n"
    
    examples_text+="=== SUBNETS AND CIDR ===\n"
    examples_text+="6. Allow entire subnet (CIDR notation):\n"
    examples_text+="    sudo ufw allow from 192.168.1.0/24\n\n"
    
    examples_text+="7. Allow subnet to specific port:\n"
    examples_text+="    sudo ufw allow from 10.0.0.0/8 to any port 22\n\n"
    
    examples_text+="8. Deny range of IPs:\n"
    examples_text+="    sudo ufw deny from 203.0.113.0/24\n\n"
    
    examples_text+="9. Allow specific IP range to web server:\n"
    examples_text+="    sudo ufw allow proto tcp from 172.16.0.0/12 to any port 80,443\n\n"
    
    examples_text+="=== INTERFACES AND DIRECTION ===\n"
    examples_text+="10. Allow on specific interface:\n"
    examples_text+="     sudo ufw allow in on eth0 to any port 80\n\n"
    
    examples_text+="11. Block outgoing traffic to IP:\n"
    examples_text+="     sudo ufw reject out to 10.0.0.50\n\n"
    
    examples_text+="12. Allow from specific interface and IP range:\n"
    examples_text+="     sudo ufw allow in on eth1 from 192.168.2.0/24\n\n"
    
    examples_text+="=== PORTS AND PROTOCOLS ===\n"
    examples_text+="13. Allow port range:\n"
    examples_text+="     sudo ufw allow 60000:61000/udp\n\n"
    
    examples_text+="14. Allow multiple ports:\n"
    examples_text+="     sudo ufw allow 80,443/tcp\n\n"
    
    examples_text+="15. Allow specific protocol:\n"
    examples_text+="     sudo ufw allow proto udp to any port 53\n\n"
    
    examples_text+="=== MANAGING RULES ===\n"
    examples_text+="16. Insert rule at specific position:\n"
    examples_text+="     sudo ufw insert 1 deny from 203.0.113.1\n\n"
    
    examples_text+="17. Delete rule by number:\n"
    examples_text+="     sudo ufw delete 3\n\n"
    
    examples_text+="18. Delete specific rule:\n"
    examples_text+="     sudo ufw delete allow 80/tcp\n\n"
    
    examples_text+="=== COMPLEX EXAMPLES ===\n"
    examples_text+="19. Allow LAN access but restrict specific IP:\n"
    examples_text+="     sudo ufw allow from 192.168.1.0/24\n"
    examples_text+="     sudo ufw deny from 192.168.1.100\n\n"
    
    examples_text+="20. Complex rule with multiple parameters:\n"
    examples_text+="     sudo ufw allow proto tcp from 192.168.1.0/24 to any port 22,80,443\n"
    
    whiptail --title "Advanced UFW Examples" --scrolltext --msgbox "$examples_text" 30 100
}

bulk_rule_management() {
    local choice=$(whiptail --title "Bulk Rule Management" --menu "Choose bulk operation:" $WT_HEIGHT $WT_WIDTH 4 \
    "1" "Import rules from file" \
    "2" "Export current rules to file" \
    "3" "Apply predefined rule set" \
    "4" "Return to main menu" 3>&1 1>&2 2>&3)
    
    case $choice in
        1)
            local file_path=$(whiptail --title "Import Rules" --inputbox "Enter file path containing UFW rules:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
            if [ -n "$file_path" ] && [ -f "$file_path" ]; then
                if confirm_action "Import rules from $file_path?"; then
                    local count=0
                    while IFS= read -r line; do
                        if [[ $line =~ ^[[:space:]]*# ]] || [[ -z $line ]]; then
                            continue
                        fi
                        sudo ufw $line 2>/dev/null && ((count++))
                    done < "$file_path"
                    show_message "Import Complete" "$count rules imported successfully" "success"
                fi
            else
                show_message "File Error" "File not found or invalid path" "error"
            fi
            ;;
        2)
            local export_file="/tmp/ufw_rules_$(date +%Y%m%d_%H%M%S).txt"
            sudo ufw status numbered > "$export_file"
            show_message "Export Complete" "Rules exported to:\n$export_file" "success"
            ;;
        3)
            predefined_configurations
            ;;
    esac
}

predefined_configurations() {
    local choice=$(whiptail --title "Predefined Rule Sets" --menu "Choose configuration:" $WT_HEIGHT $WT_WIDTH 6 \
    "1" "Web Server (HTTP/HTTPS + SSH)" \
    "2" "Database Server (MySQL/PostgreSQL + SSH)" \
    "3" "Mail Server (SMTP/POP3/IMAP + SSH)" \
    "4" "Development Server (Common dev ports)" \
    "5" "Secure Desktop (Minimal access)" \
    "6" "Gaming Server configurations" 3>&1 1>&2 2>&3)
    
    case $choice in
        1)
            if confirm_action "Apply web server configuration?\n\nThis will allow:\n- SSH (22)\n- HTTP (80)\n- HTTPS (443)\n- Alt HTTP (8080)"; then
                show_progress "Applying web server rules..." 4
                sudo ufw allow ssh
                sudo ufw allow http
                sudo ufw allow https
                sudo ufw allow 8080/tcp comment 'Alternative HTTP'
                show_message "Configuration Applied" "Web server configuration applied successfully" "success"
            fi
            ;;
        2)
            if confirm_action "Apply database server configuration?\n\nThis will allow:\n- SSH (22)\n- MySQL (3306)\n- PostgreSQL (5432)"; then
                show_progress "Applying database server rules..." 3
                sudo ufw allow ssh
                sudo ufw allow 3306/tcp comment 'MySQL'
                sudo ufw allow 5432/tcp comment 'PostgreSQL'
                show_message "Configuration Applied" "Database server configuration applied successfully" "success"
            fi
            ;;
        3)
            if confirm_action "Apply mail server configuration?\n\nThis will allow:\n- SSH, SMTP, POP3, POP3S, IMAP, IMAPS"; then
                show_progress "Applying mail server rules..." 6
                sudo ufw allow ssh
                sudo ufw allow 25/tcp comment 'SMTP'
                sudo ufw allow 110/tcp comment 'POP3'
                sudo ufw allow 995/tcp comment 'POP3S'
                sudo ufw allow 143/tcp comment 'IMAP'
                sudo ufw allow 993/tcp comment 'IMAPS'
                show_message "Configuration Applied" "Mail server configuration applied successfully" "success"
            fi
            ;;
        4)
            if confirm_action "Apply development server configuration?\n\nCommon development ports for Node.js, Django, Angular, React"; then
                show_progress "Applying development server rules..." 5
                sudo ufw allow ssh
                sudo ufw allow 3000/tcp comment 'Node.js dev'
                sudo ufw allow 8000/tcp comment 'Django dev'
                sudo ufw allow 4200/tcp comment 'Angular dev'
                sudo ufw allow 3001/tcp comment 'React dev'
                show_message "Configuration Applied" "Development server configuration applied successfully" "success"
            fi
            ;;
        5)
            if confirm_action "Apply secure desktop configuration?\n\nThis will reset UFW and apply minimal rules"; then
                show_progress "Applying secure desktop rules..." 4
                sudo ufw --force reset
                sudo ufw default deny incoming
                sudo ufw default allow outgoing
                sudo ufw allow out 53 comment 'DNS'
                sudo ufw allow out 80 comment 'HTTP'
                sudo ufw allow out 443 comment 'HTTPS'
                sudo ufw enable
                show_message "Configuration Applied" "Secure desktop configuration applied successfully" "success"
            fi
            ;;
        6)
            gaming_server_config
            ;;
    esac
}

gaming_server_config() {
    local choice=$(whiptail --title "Gaming Server Configuration" --menu "Choose gaming server type:" $WT_HEIGHT $WT_WIDTH 3 \
    "1" "Steam Server" \
    "2" "Minecraft Server" \
    "3" "Custom Gaming Ports" 3>&1 1>&2 2>&3)
    
    case $choice in
        1)
            if confirm_action "Configure Steam server ports?\n(27015 TCP/UDP)"; then
                sudo ufw allow 27015/tcp comment 'Steam Server'
                sudo ufw allow 27015/udp comment 'Steam Server'
                show_message "Steam Config" "Steam server ports configured" "success"
            fi
            ;;
        2)
            if confirm_action "Configure Minecraft server port?\n(25565 TCP)"; then
                sudo ufw allow 25565/tcp comment 'Minecraft Server'
                show_message "Minecraft Config" "Minecraft server port configured" "success"
            fi
            ;;
        3)
            local port_range=$(whiptail --title "Custom Gaming Ports" --inputbox "Enter custom port range (e.g., 7777:7784):" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
            if [ -n "$port_range" ]; then
                sudo ufw allow $port_range comment 'Custom Gaming'
                show_message "Custom Gaming" "Custom gaming ports configured" "success"
            fi
            ;;
    esac
}

real_time_monitoring() {
    show_message "Real-time Monitoring" "Real-time monitoring would require a separate terminal.\n\nUse this command in another terminal:\n\nsudo tail -f /var/log/ufw.log" "info"
}

log_management() {
    local choice=$(whiptail --title "Log Management" --menu "Choose log operation:" $WT_HEIGHT $WT_WIDTH 6 \
    "1" "View recent UFW logs" \
    "2" "Search logs by IP" \
    "3" "Search logs by port" \
    "4" "Log statistics" \
    "5" "Export logs" \
    "6" "Configure logging" 3>&1 1>&2 2>&3)
    
    case $choice in
        1)
            local recent_logs=$(sudo tail -20 /var/log/ufw.log 2>/dev/null || echo "No logs found")
            whiptail --title "Recent UFW Logs" --scrolltext --msgbox "$recent_logs" 25 100
            ;;
        2)
            local search_ip=$(whiptail --title "Search by IP" --inputbox "Enter IP address to search for:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
            if [ -n "$search_ip" ]; then
                local results=$(grep "$search_ip" /var/log/ufw.log 2>/dev/null | tail -10 || echo "No matches found")
                whiptail --title "Search Results for $search_ip" --scrolltext --msgbox "$results" 25 100
            fi
            ;;
        3)
            local search_port=$(whiptail --title "Search by Port" --inputbox "Enter port number to search for:" $WT_HEIGHT $WT_WIDTH 3>&1 1>&2 2>&3)
            if [ -n "$search_port" ]; then
                local results=$(grep "DPT=$search_port" /var/log/ufw.log 2>/dev/null | tail -10 || echo "No matches found")
                whiptail --title "Search Results for Port $search_port" --scrolltext --msgbox "$results" 25 100
            fi
            ;;
        4)
            local stats="LOG STATISTICS\n\n"
            stats+="Total log entries: $(wc -l /var/log/ufw.log 2>/dev/null | cut -d' ' -f1 || echo '0')\n\n"
            stats+="Most blocked IPs:\n"
            stats+="$(grep 'BLOCK' /var/log/ufw.log 2>/dev/null | awk '{print $13}' | cut -d'=' -f2 | sort | uniq -c | sort -nr | head -5 || echo 'No data')"
            whiptail --title "Log Statistics" --scrolltext --msgbox "$stats" $WT_HEIGHT $WT_WIDTH
            ;;
        5)
            local export_file="/tmp/ufw_logs_$(date +%Y%m%d_%H%M%S).txt"
            sudo cp /var/log/ufw.log "$export_file" 2>/dev/null
            show_message "Logs Exported" "Logs exported to:\n$export_file" "success"
            ;;
        6)
            configure_logging
            ;;
    esac
}

configure_logging() {
    local current_logging=$(sudo ufw status verbose | grep "Logging:" || echo "Logging: unknown")
    
    local choice=$(whiptail --title "Configure Logging" --menu "$current_logging\n\nChoose logging option:" $WT_HEIGHT $WT_WIDTH 5 \
    "1" "Enable logging" \
    "2" "Disable logging" \
    "3" "Set logging level - Low" \
    "4" "Set logging level - Medium" \
    "5" "Set logging level - High" 3>&1 1>&2 2>&3)
    
    case $choice in
        1) execute_command "sudo ufw logging on" "Enable UFW logging" ;;
        2) execute_command "sudo ufw logging off" "Disable UFW logging" ;;
        3) execute_command "sudo ufw logging low" "Set logging level to low" ;;
        4) execute_command "sudo ufw logging medium" "Set logging level to medium" ;;
        5) execute_command "sudo ufw logging high" "Set logging level to high" ;;
    esac
}

security_audit() {
    show_progress "Running security audit..." 5
    
    local audit_results="SECURITY AUDIT RESULTS\n\n"
    
    # Check if UFW is enabled
    if sudo ufw status | grep -q "Status: active"; then
        audit_results+="[OK] UFW is active\n"
    else
        audit_results+="[WARNING] UFW is not active\n"
    fi
    
    # Check default policies
    local default_in=$(sudo ufw status verbose | grep "Default:" | awk '{print $2}')
    local default_out=$(sudo ufw status verbose | grep "Default:" | awk '{print $4}')
    
    if [ "$default_in" = "deny" ]; then
        audit_results+="[OK] Default incoming policy is secure (deny)\n"
    else
        audit_results+="[WARNING] Default incoming policy: $default_in\n"
    fi
    
    audit_results+="\nSECURITY RECOMMENDATIONS:\n\n"
    
    if sudo ufw status | grep -q "22/tcp.*ALLOW.*Anywhere"; then
        audit_results+="[WARNING] SSH is open to everywhere - consider restricting to specific IPs\n"
    fi
    
    if sudo ufw status | grep -q "80/tcp.*ALLOW.*Anywhere"; then
        audit_results+="[INFO] HTTP port is open (standard for web servers)\n"
    fi
    
    audit_results+="\nRule count: $(sudo ufw status numbered | grep -c '^\[' || echo '0')\n"
    
    whiptail --title "Security Audit Results" --scrolltext --msgbox "$audit_results" 25 $WT_WIDTH
}

show_system_info() {
    local system_info="SYSTEM INFORMATION\n\n"
    system_info+="OS: $(lsb_release -d 2>/dev/null | cut -f2 || uname -a)\n"
    system_info+="Kernel: $(uname -r)\n"
    system_info+="Uptime: $(uptime -p 2>/dev/null || uptime)\n\n"
    system_info+="UFW INFORMATION:\n"
    system_info+="Version: $(ufw --version 2>/dev/null || echo 'Unknown')\n"
    system_info+="Rules count: $(sudo ufw status numbered | grep -c '^\[' || echo '0')\n\n"
    system_info+="NETWORK INTERFACES:\n"
    system_info+="$(ip -brief addr show)\n"
    
    whiptail --title "System Information" --scrolltext --msgbox "$system_info" 25 90
}

# =================== INITIALIZATION ===================

initialize_script() {
    setup_directories
    log_action "START" "UFW Manager Professional v$SCRIPT_VERSION started"
    check_system_requirements
}

# =================== MAIN EXECUTION ===================

main() {
    initialize_script
    main_menu
}

# Execute main function
main "$@"
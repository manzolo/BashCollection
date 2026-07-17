# mprocmon module: help, configuration, logs, main menu
# Sourced by mprocmon.sh — do not execute directly.
show_help() {
    whiptail --title "Manzolo Network & File Monitor - Help" --msgbox \
"Network and File Monitor v$SCRIPT_VERSION || true

FEATURES:
• Advanced port scanning with lsof and ss
• Comprehensive process analysis
• File lock detection and monitoring
• Process-file relationship mapping
• logging and error handling
• Data export capabilities

MENU OPTIONS:
1. lsof Port Analysis - Detailed network connection analysis
2. ss Network Analysis - Fast socket statistics
3. Process Analysis - Complete process information
4. File Lock Analysis - Check file usage and locks
5. Process File Search - Find files used by processes
6. System Overview - Comprehensive system status
7. Log Viewer - View application logs
8. Configuration - Adjust settings

TIPS:
• All activities are logged in $LOG_DIR
• Use export functions to save analysis results
• Requires appropriate permissions for full functionality
• Use Ctrl+C to interrupt long operations

REQUIREMENTS:
• whiptail, lsof, ss, netstat, ps, ip commands
• Read permissions for /proc filesystem
• Network monitoring capabilities

LOG LOCATION: $LOG_FILE" 25 75
}

# Configuration management
manage_configuration() {
    local temp_file="$TEMP_DIR/config_choice"
    
    if whiptail --title "Configuration Management" --menu "Choose option:" 15 60 4 \
        "1" "View current configuration" \
        "2" "Reset to defaults" \
        "3" "View log directory" \
        "4" "Clear old logs" 2> "$temp_file"; then

        local choice
        choice=$(cat "$temp_file")
        
        case $choice in
            1)
                {
                    echo "Current Configuration:"
                    echo "====================="
                    echo "Script Version: $SCRIPT_VERSION"
                    echo "Log Directory: $LOG_DIR"
                    echo "Config File: $CONFIG_FILE"
                    echo "Temp Directory: $TEMP_DIR"
                    echo "Current User: $(whoami)"
                    echo "System: $(uname -a)"
                } | whiptail --textbox /dev/stdin 20 70
                ;;
            2)
                whiptail --yesno "Reset all configuration to defaults?" 8 40 && {
                    rm -f "$CONFIG_FILE"
                    whiptail --msgbox "Configuration reset to defaults" 8 40
                }
                ;;
            3)
                ls -la "$LOG_DIR" | whiptail --textbox /dev/stdin 20 80
                ;;
            4)
                local old_logs
                old_logs=$(find "$LOG_DIR" -name "*.log" -mtime +7 2>/dev/null | wc -l)
                if [[ "$old_logs" -gt 0 ]]; then
                    if whiptail --yesno "Delete $old_logs log files older than 7 days?" 8 50; then
                        find "$LOG_DIR" -name "*.log" -mtime +7 -delete
                        whiptail --msgbox "Old log files deleted" 8 30
                    fi
                else
                    whiptail --msgbox "No old log files found" 8 30
                fi
                ;;
        esac
    fi
}

# View logs function
view_logs() {
    local log_files=()
    
    # Get list of log files
    while IFS= read -r -d '' file; do
        log_files+=("$(basename "$file")" "$(date -r "$file" '+%Y-%m-%d %H:%M')")
    done < <(find "$LOG_DIR" -name "*.log" -type f -print0 2>/dev/null | head -20)
    
    if [[ ${#log_files[@]} -eq 0 ]]; then
        whiptail --msgbox "No log files found in $LOG_DIR" 8 50
        return 0
    fi
    
    local temp_file="$TEMP_DIR/log_choice"
    
    if whiptail --title "Log Viewer" --menu "Select log file:" 20 70 10 "${log_files[@]}" 2> "$temp_file"; then
        local selected_log
        selected_log=$(cat "$temp_file")
        local log_path="$LOG_DIR/$selected_log"
        
        if [[ -r "$log_path" ]]; then
            whiptail --textbox "$log_path" 25 90
        else
            whiptail --msgbox "Cannot read log file: $log_path" 8 50
        fi
    fi
}

# Main menu function
show_main_menu() {
    while true; do
        local temp_file="$TEMP_DIR/main_menu"
        
        if whiptail --title "Manzolo Network & File Monitor v$SCRIPT_VERSION" \
            --menu "Select monitoring option:" 20 75 12 \
            "1" "Port Analysis (lsof) - Detailed network connections" \
            "2" "Network Analysis (ss) - Fast socket statistics" \
            "3" "Process Analysis - Complete process information" \
            "4" "File Lock Analysis - Check file usage and locks" \
            "5" "Process File Search - Find files used by processes" \
            "6" "System Overview - Comprehensive status report" \
            "7" "Log Viewer - View application logs" \
            "8" "Configuration - Manage settings" \
            "9" "Help - Usage information" \
            "10" "Exit - Quit application" 2> "$temp_file"; then

            local choice
            choice=$(cat "$temp_file")
            
            case $choice in
                1) clear; show_ports_lsof ;;
                2) clear; show_ports_ss ;;
                3) clear; analyze_process ;;
                4) clear; check_file_locks ;;
                5) clear; search_files_by_process ;;
                6) clear; show_system_overview ;;
                7) view_logs ;;
                8) manage_configuration ;;
                9) show_help ;;
                10)
                    log_message "INFO" "User initiated shutdown"
                    print_color "$GREEN" "Thank you for using Manzolo Network & File Monitor!"
                    exit 0
                    ;;
                *)
                    whiptail --msgbox "Invalid option selected!" 8 40
                    ;;
            esac
        else
            # User pressed Cancel or ESC
            log_message "INFO" "User cancelled - shutting down"
            exit 0
        fi
    done
}

# Main execution

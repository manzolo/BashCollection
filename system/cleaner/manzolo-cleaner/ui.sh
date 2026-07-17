# manzolo-cleaner module: init and main menu
# Sourced by manzolo-cleaner.sh — do not execute directly.
init_script() {
    # Create the log file if it doesn't exist
    touch "$LOG_FILE"
    log_message "INFO" "Script started"
    
    # Check dependencies
    check_dependencies
    
    # Create temporary files
    touch "$TEMP_OUTPUT"
    rm -f "$TEMP_COMMAND"
}

# Improved main menu (unchanged)
main_menu() {
    while true; do
        choice=$(dialog --clear --backtitle "$SCRIPT_NAME v2.5.1" --title "Main Menu" \
        --menu "Choose an option:" 17 50 6 \
        1 "🐳 Docker Cleanup" \
        2 "🐧 Ubuntu Cleanup" \
        3 "⚙️  Settings" \
        4 "📊 Quick Stats" \
        5 "ℹ️  Information" \
        6 "🚪 Exit" \
        2>&1 >/dev/tty)

        case $choice in
            1)
                docker_menu
                ;;
            2)
                ubuntu_menu
                ;;
            3)
                settings_menu
                ;;
            4)
                run_command_in_terminal "System Stats" "
                {
                    echo '=== QUICK STATS ==='
                    echo \"Free space: \$(df -h / | tail -1 | awk '{print \$4}')\"
                    echo \"Free RAM: \$(free -h | grep Mem | awk '{print \$7}')\"
                    echo \"Active processes: \$(ps aux | wc -l)\"
                    echo \"Uptime: \$(uptime -p)\"
                    if command -v docker &> /dev/null && docker info &> /dev/null; then
                        echo ''
                        echo '=== DOCKER STATS ==='
                        docker system df
                    fi
                }" "true" "false"
                ;;
            5)
                dialog --title "Information" --msgbox "ManzoloCleaner v2.5\n\nAdvanced system cleaning tool\nwith support for Docker and Ubuntu.\nFixed kernel removal and command execution.\n\nLog: $LOG_FILE\n\nCreated by: ManzoloScript" 12 50
                ;;
            6)
                dialog --defaultno --title "Confirmation" --yesno "Are you sure you want to exit?" 8 40
                if [ $? -eq 0 ]; then
                    clear
                    echo -e "${GREEN}Thank you for using ManzoloCleaner!${NC}"
                    log_message "INFO" "Script finished"
                    rm -f "$TEMP_OUTPUT" "$TEMP_COMMAND"
                    exit 0
                fi
                ;;
            *)
                clear
                echo -e "${GREEN}Thank you for using ManzoloCleaner!${NC}"
                log_message "INFO" "Script finished"
                rm -f "$TEMP_OUTPUT" "$TEMP_COMMAND"
                exit 0
                ;;
        esac
    done
}

# MAIN - Script start

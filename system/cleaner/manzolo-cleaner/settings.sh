# manzolo-cleaner module: settings menu
# Sourced by manzolo-cleaner.sh — do not execute directly.
settings_menu() {
    while true; do
        choice=$(dialog --clear --backtitle "$SCRIPT_NAME - Settings" --title "Settings" \
        --menu "Choose an option:" 15 50 5 \
        1 "View log" \
        2 "Clean log" \
        3 "Show system info" \
        4 "Test essential commands" \
        5 "Back to main menu" \
        2>&1 >/dev/tty)

        case $choice in
            1)
                if [ -f "$LOG_FILE" ]; then
                    dialog --title "Log Content" --textbox "$LOG_FILE" 20 80
                else
                    dialog --msgbox "No log file found." 8 40
                fi
                ;;
            2)
                if [ -f "$LOG_FILE" ]; then
                    dialog --title "Confirmation" --yesno "Delete the log file?" 8 40
                    if [ $? -eq 0 ]; then
                        rm -f "$LOG_FILE"
                        dialog --msgbox "Log deleted." 8 30
                    fi
                else
                    dialog --msgbox "No log file to delete." 8 40
                fi
                ;;
            3)
                run_command_in_terminal "System Info" "
                {
                    echo '=== SYSTEM INFORMATION ==='
                    echo \"System: \$(lsb_release -d | cut -f2)\"
                    echo \"Kernel: \$(uname -r)\"
                    echo \"Architecture: \$(uname -m)\"
                    echo \"CPU: \$(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)\"
                    echo \"Total RAM: \$(free -h | grep Mem | awk '{print \$2}')\"
                    echo \"Free RAM: \$(free -h | grep Mem | awk '{print \$7}')\"
                    echo \"Uptime: \$(uptime -p)\"
                    echo ''
                    echo '=== DISK SPACE ==='
                    df -h | awk 'NR==1 || /^\/dev\//'
                }" "true" "false"
                ;;
            4)
                run_command_in_terminal "Test Essential Commands" "
                {
                    echo '=== ESSENTIAL COMMANDS TEST ==='
                    command -v sudo && echo '✓ sudo available' || echo '✗ sudo not available'
                    command -v docker && echo '✓ docker available' || echo '✗ docker not available'
                    command -v apt && echo '✓ apt available' || echo '✗ apt not available'
                    command -v journalctl && echo '✓ journalctl available' || echo '✗ journalctl not available'
                    command -v dialog && echo '✓ dialog available' || echo '✗ dialog not available'
                    command -v bc && echo '✓ bc available' || echo '✗ bc not available'
                }" "true" "false"
                ;;
            5|*)
                break
                ;;
        esac
    done
}

# Initialization function (added temp command file)

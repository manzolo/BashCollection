#!/bin/bash

# ManzoloCleaner - Advanced System Cleaning Tool
# Improved version v2.5 with fixed kernel removal, better command execution, and optimizations

# Configuration
SCRIPT_NAME="ManzoloCleaner"
LOG_FILE="/tmp/manzolo_cleaner.log"
CONFIG_FILE="$HOME/.manzolo_cleaner.conf"
TEMP_OUTPUT="/tmp/manzolo_cleaner_output.txt"
TEMP_COMMAND="/tmp/manzolo_temp_command.sh"  # New: Temp file for complex commands

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
}

# Function to check dependencies
check_dependencies() {
    local missing_deps=()
    
    # Check for dialog
    if ! command -v dialog &> /dev/null; then
        missing_deps+=("dialog")
    fi
    
    # Check for sudo
    if ! command -v sudo &> /dev/null; then
        missing_deps+=("sudo")
    fi

    # Check for bc (used in space calculation)
    if ! command -v bc &> /dev/null; then
        missing_deps+=("bc")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}Missing dependencies:${NC}"
        for dep in "${missing_deps[@]}"; do
            echo "- $dep"
        done
        echo -e "\n${YELLOW}Please install the missing dependencies (e.g., sudo apt install dialog bc) before continuing.${NC}"
        exit 1
    fi
}

# Improved function to run commands and save output (fixed for multiline)
run_command_in_terminal() {
    local title="$1"
    local command="$2"
    local show_output="${3:-true}"
    local calculate_space="${4:-false}"  # New: Option to calculate space freed
    
    log_message "INFO" "Executing command: $command"
    
    # Clear the temporary file before writing
    : > "$TEMP_OUTPUT"
    
    # For complex/multiline commands, write to a temp script file
    if [[ $command == *'{'* || $command == *';'* ]]; then
        echo "#!/bin/bash" > "$TEMP_COMMAND"
        echo "$command" >> "$TEMP_COMMAND"
        chmod +x "$TEMP_COMMAND"
        actual_cmd="$TEMP_COMMAND"
    else
        actual_cmd="$command"
    fi
    
    # Show a waiting message
    dialog --title "$title" --infobox "Executing...\n$command" 6 60
    
    # Execute the command and save the output
    local before_space=0
    if [ "$calculate_space" = "true" ]; then
        before_space=$(df / --output=used | tail -1 | sed 's/ //g')  # Bytes used on root
    fi
    
    if [ "$show_output" = "true" ]; then
        if [[ $command == *'{'* || $command == *';'* ]]; then
            . "$TEMP_COMMAND" >> "$TEMP_OUTPUT" 2>&1
        else
            eval "$actual_cmd" >> "$TEMP_OUTPUT" 2>&1
        fi
    else
        if [[ $command == *'{'* || $command == *';'* ]]; then
            . "$TEMP_COMMAND" >> "$LOG_FILE" 2>&1
        else
            eval "$actual_cmd" >> "$LOG_FILE" 2>&1
        fi
    fi
    local status=$?
    
    # Calculate space freed if requested
    local space_msg=""
    if [ "$calculate_space" = "true" ]; then
        local after_space=$(df / --output=used | tail -1 | sed 's/ //g')
        local freed=$((before_space - after_space))
        if [ $freed -gt 0 ]; then
            space_msg="\nSpace freed: $(calculate_space_freed $freed)"
        fi
    fi
    
    # Log the output
    if [ "$show_output" = "true" ]; then
        cat "$TEMP_OUTPUT" >> "$LOG_FILE" 2>/dev/null
    fi
    
    # Clean up temp command file
    rm -f "$TEMP_COMMAND"
    
    # Show the output in a dialog window
    if [ "$show_output" = "true" ]; then
        if [ -s "$TEMP_OUTPUT" ]; then
            dialog --title "$title - Output" --textbox "$TEMP_OUTPUT" 20 80
        else
            dialog --title "$title" --msgbox "No output produced by the command." 6 50
        fi
    fi
    
    # Show status message with space info
    if [ $status -eq 0 ]; then
        dialog --title "$title" --msgbox "Operation completed successfully.$space_msg" 8 60
    else
        dialog --title "$title" --msgbox "Error during command execution.\nCheck the log: $LOG_FILE" 8 60
        log_message "ERROR" "Error executing: $command"
    fi
}

# Function to calculate space freed (unchanged, but now checked)
calculate_space_freed() {
    local freed="$1"
    
    if [ $freed -gt 1073741824 ]; then
        echo "$(echo "scale=2; $freed / 1073741824" | bc) GB"
    elif [ $freed -gt 1048576 ]; then
        echo "$(echo "scale=2; $freed / 1048576" | bc) MB"
    else
        echo "$(echo "scale=2; $freed / 1024" | bc) KB"
    fi
}

# Function to check if Docker is installed and running (unchanged)
check_docker() {
    if ! command -v docker &> /dev/null; then
        dialog --msgbox "Docker is not installed on the system." 8 50
        return 1
    fi
    
    if ! docker info &> /dev/null; then
        dialog --msgbox "Docker is not running or you do not have the necessary permissions." 10 60
        return 1
    fi
    
    return 0
}

# Improved Docker menu (added space calculation for prunes)
docker_menu() {
    if ! check_docker; then
        return
    fi
    
    while true; do
        choice=$(dialog --clear --backtitle "$SCRIPT_NAME - Docker Menu" --title "Docker Cleanup" \
        --menu "Choose an option:" 18 60 8 \
        1 "Docker System Prune (full)" \
        2 "Docker Builder Prune" \
        3 "Remove stopped containers" \
        4 "Remove unused images" \
        5 "Remove unused volumes" \
        6 "Remove unused networks" \
        7 "Show Docker stats" \
        8 "Back to main menu" \
        2>&1 >/dev/tty)

        case $choice in
            1)
                dialog --defaultno --title "Confirmation" --yesno "This will remove:\n- All stopped containers\n- All unused networks\n- All unused images\n- All build cache\n\nContinue?" 12 60
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Docker System Prune" "docker system prune -a -f" "true" "true"
                fi
                ;;
            2)
                dialog --defaultno --title "Confirmation" --yesno "Remove all Docker build cache?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Docker Builder Prune" "docker builder prune -a -f" "true" "true"
                fi
                ;;
            3)
                dialog --title "Confirmation" --yesno "Remove all stopped containers?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Remove Stopped Containers" "docker container prune -f" "true" "true"
                fi
                ;;
            4)
                choice_img=$(dialog --title "Choose type" --menu "What type of images to remove?" 12 50 2 \
                1 "Only dangling images" \
                2 "All unused images" \
                2>&1 >/dev/tty)
                if [ $? -eq 0 ]; then
                    if [ "$choice_img" = "1" ]; then
                        dialog --title "Confirmation" --yesno "Remove dangling images?" 8 50
                        if [ $? -eq 0 ]; then
                            run_command_in_terminal "Remove Dangling Images" "docker image prune -f" "true" "true"
                        fi
                    else
                        dialog --defaultno --title "Confirmation" --yesno "Remove all unused images?" 8 50
                        if [ $? -eq 0 ]; then
                            run_command_in_terminal "Remove All Unused Images" "docker image prune -a -f" "true" "true"
                        fi
                    fi
                fi
                ;;
            5)
                dialog --defaultno --title "Confirmation" --yesno "Remove unused volumes?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Remove Unused Volumes" "docker volume prune -f" "true" "true"
                fi
                ;;
            6)
                dialog --title "Confirmation" --yesno "Remove unused networks?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Remove Unused Networks" "docker network prune -f" "true" "true"
                fi
                ;;
            7)
                run_command_in_terminal "Docker Statistics" "docker system df && docker images && docker ps -a" "true" "false"
                ;;
            8|*)
                break
                ;;
        esac
    done
}

# Improved Ubuntu menu (fixed kernel removal)
ubuntu_menu() {
    while true; do
        choice=$(dialog --clear --backtitle "$SCRIPT_NAME - Ubuntu Menu" --title "Ubuntu Cleanup" \
        --menu "Choose an option:" 20 70 10 \
        1 "Update package cache" \
        2 "Remove unnecessary packages" \
        3 "Clean APT cache" \
        4 "Clear old kernels" \
        5 "Clean system logs" \
        6 "Empty trash bin" \
        7 "Clean thumbnail cache" \
        8 "Full Ubuntu cleanup" \
        9 "Show disk space" \
        10 "Back to main menu" \
        2>&1 >/dev/tty)

        case $choice in
            1)
                run_command_in_terminal "Update Cache" "sudo apt update" "true" "false"
                ;;
            2)
                dialog --title "Confirmation" --yesno "Remove unnecessary packages?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Remove Unnecessary Packages" "sudo apt autoremove -y && sudo apt autoclean" "true" "true"
                fi
                ;;
            3)
                dialog --title "Confirmation" --yesno "Clean the APT cache?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clean APT Cache" "sudo apt clean" "true" "true"
                fi
                ;;
            4)
                dialog --defaultno --title "Confirmation" --yesno "Remove old kernels?\nWARNING: Always keep at least 2 kernels for safety." 10 60
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clear Old Kernels" "
                    {
                        echo 'Installed Kernels:'
                        dpkg --list | grep '^ii' | grep linux-image | awk '{print \$2}' | sort -V
                        echo ''
                        echo 'Current Kernel: $(uname -r)'
                        echo ''
                        # List kernels to remove (all except current and the 2 most recent)
                        kernels_to_remove=\$(dpkg --list | grep '^ii' | grep linux-image | awk '{print \$2}' | grep -v \"\$(uname -r)\" | sort -V | head -n -2)
                        if [ -z \"\$kernels_to_remove\" ]; then
                            echo 'No old kernels to remove (keeping at least 2).'
                        else
                            echo 'Kernels to remove:'
                            echo \"\$kernels_to_remove\"
                            echo ''
                            echo 'Removing old kernels...'
                            sudo apt-get purge -y \$kernels_to_remove 2>/dev/null || true
                            sudo apt-get autoremove -y
                            echo 'Old kernels removed successfully.'
                        fi
                    }" "true" "true"
                fi
                ;;
            5)
                dialog --title "Confirmation" --yesno "Clean system logs?\nOnly the last 7 days will be kept." 10 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clean Logs" "sudo journalctl --vacuum-time=7d && sudo find /var/log -name '*.log' -type f -mtime +30 -delete || true" "true" "true"
                fi
                ;;
            6)
                dialog --title "Confirmation" --yesno "Empty the trash bin?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Empty Trash Bin" "rm -rf ~/.local/share/Trash/* || true" "true" "true"
                fi
                ;;
            7)
                dialog --title "Confirmation" --yesno "Clean the thumbnail cache?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clean Thumbnails" "rm -rf ~/.cache/thumbnails/* || true" "true" "true"
                fi
                ;;
            8)
                dialog --defaultno --title "Confirmation" --yesno "Perform full Ubuntu cleanup?\nThis will include all cleanup options." 10 60
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Full Ubuntu Cleanup" "
                    {
                        echo 'Starting full cleanup...'
                        sudo apt update
                        sudo apt autoremove -y
                        sudo apt clean
                        sudo apt autoclean
                        sudo journalctl --vacuum-time=7d
                        rm -rf ~/.local/share/Trash/* || true
                        rm -rf ~/.cache/thumbnails/* || true
                        rm -rf ~/.cache/* 2>/dev/null || true
                        echo 'Cleanup completed!'
                    }" "true" "true"
                fi
                ;;
            9)
                run_command_in_terminal "Disk Space" "df -h | awk 'NR==1 || /^\/dev\//' && du -sh ~/.* 2>/dev/null | sort -hr | head -10" "true" "false"
                ;;
            10|*)
                break
                ;;
        esac
    done
}

# Settings menu (unchanged, minor fixes)
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
        choice=$(dialog --clear --backtitle "$SCRIPT_NAME v2.5" --title "Main Menu" \
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
main() {
    # Welcome banner
    clear
    echo -e "${BLUE}"
    echo "███╗   ███╗ █████╗ ███╗   ██╗███████╗ ██████╗ ██╗     ██████╗ "
    echo "████╗ ████║██╔══██╗████╗  ██║╚══███╔╝██╔═══██╗██║     ██╔═══██╗"
    echo "██╔████╔██║███████║██╔██╗ ██║  ███╔╝ ██║   ██║██║     ██║   ██║"
    echo "██║╚██╔╝██║██╔══██║██║╚██╗██║ ███╔╝  ██║   ██║██║     ██║   ██║"
    echo "██║ ╚═╝ ██║██║  ██║██║ ╚████║███████╗╚██████╔╝███████╗╚██████╔╝"
    echo "╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝ ╚═════╝ ╚══════╝ ╚═════╝ "
    echo -e "${NC}"
    echo -e "${YELLOW}               CLEANER v2.5${NC}"
    echo ""
    echo -e "${GREEN}Initializing...${NC}"
    
    # Initialize the script
    init_script
    
    sleep 2
    
    # Start the main menu
    main_menu
}

# Run the script
main "$@"
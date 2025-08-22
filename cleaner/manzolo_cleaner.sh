#!/bin/bash

# ManzoloCleaner - Advanced System Cleaning Tool
# Improved version with dialog, optimized output, and a cat error fix

# Configuration
SCRIPT_NAME="ManzoloCleaner"
LOG_FILE="/tmp/manzolo_cleaner.log"
CONFIG_FILE="$HOME/.manzolo_cleaner.conf"
TEMP_OUTPUT="/tmp/manzolo_cleaner_output.txt"

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
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}Missing dependencies:${NC}"
        for dep in "${missing_deps[@]}"; do
            echo "- $dep"
        done
        echo -e "\n${YELLOW}Please install the missing dependencies (e.g., sudo apt install dialog) before continuing.${NC}"
        exit 1
    fi
}

# Function to run commands and save output
run_command_in_terminal() {
    local title="$1"
    local command="$2"
    local show_output="${3:-true}"
    
    log_message "INFO" "Executing command: $command"
    
    # Clear the temporary file before writing
    : > "$TEMP_OUTPUT"
    
    # Show a waiting message
    dialog --title "$title" --infobox "Executing...\n$command" 6 60
    
    # Execute the command and save the output to a temporary file
    if [ "$show_output" = "true" ]; then
        eval "$command" >> "$TEMP_OUTPUT" 2>&1
    else
        eval "$command" >> "$LOG_FILE" 2>&1
    fi
    local status=$?
    
    # Log the output
    if [ "$show_output" = "true" ]; then
        cat "$TEMP_OUTPUT" >> "$LOG_FILE" 2>/dev/null
    fi
    
    # Show the output in a dialog window
    if [ "$show_output" = "true" ]; then
        if [ -s "$TEMP_OUTPUT" ]; then
            dialog --title "$title - Output" --textbox "$TEMP_OUTPUT" 20 80
        else
            dialog --title "$title" --msgbox "No output produced by the command." 6 50
        fi
    fi
    
    # Show status message
    if [ $status -eq 0 ]; then
        dialog --title "$title" --msgbox "Operation completed successfully." 6 50
    else
        dialog --title "$title" --msgbox "Error during command execution.\nCheck the log: $LOG_FILE" 8 60
        log_message "ERROR" "Error executing: $command"
    fi
}

# Function to calculate space freed
calculate_space_freed() {
    local before="$1"
    local after="$2"
    local freed=$((before - after))
    
    if [ $freed -gt 1073741824 ]; then
        echo "$(echo "scale=2; $freed / 1073741824" | bc) GB"
    elif [ $freed -gt 1048576 ]; then
        echo "$(echo "scale=2; $freed / 1048576" | bc) MB"
    else
        echo "$(echo "scale=2; $freed / 1024" | bc) KB"
    fi
}

# Function to check if Docker is installed and running
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

# Improved Docker menu
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
                    run_command_in_terminal "Docker System Prune" "docker system prune -f"
                fi
                ;;
            2)
                dialog --defaultno --title "Confirmation" --yesno "Remove all Docker build cache?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Docker Builder Prune" "docker builder prune -a -f"
                fi
                ;;
            3)
                dialog --title "Confirmation" --yesno "Remove all stopped containers?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Remove Stopped Containers" "docker container prune -f"
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
                            run_command_in_terminal "Remove Dangling Images" "docker image prune -f"
                        fi
                    else
                        dialog --defaultno --title "Confirmation" --yesno "Remove all unused images?" 8 50
                        if [ $? -eq 0 ]; then
                            run_command_in_terminal "Remove All Unused Images" "docker image prune -a -f"
                        fi
                    fi
                fi
                ;;
            5)
                dialog --defaultno --title "Confirmation" --yesno "Remove unused volumes?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Remove Unused Volumes" "docker volume prune -f"
                fi
                ;;
            6)
                dialog --title "Confirmation" --yesno "Remove unused networks?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Remove Unused Networks" "docker network prune -f"
                fi
                ;;
            7)
                run_command_in_terminal "Docker Statistics" "
                {
                    echo '=== DOCKER STATISTICS ==='
                    echo 'Docker Images:'
                    docker images --format 'table {{.Repository}}\\t{{.Tag}}\\t{{.Size}}'
                    echo ''
                    echo 'Containers (active and stopped):'
                    docker ps -a --format 'table {{.Names}}\\t{{.Image}}\\t{{.Status}}'
                    echo ''
                    echo 'Volumes:'
                    docker volume ls --format 'table {{.Name}}'
                    echo ''
                    echo 'Networks:'
                    docker network ls --format 'table {{.Name}}\\t{{.Driver}}'
                    echo ''
                    echo 'Space Usage:'
                    docker system df
                } > '$TEMP_OUTPUT'"
                ;;
            8|*)
                break
                ;;
        esac
    done
}

# Improved Ubuntu menu
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
                run_command_in_terminal "Update Cache" "sudo apt update"
                ;;
            2)
                dialog --title "Confirmation" --yesno "Remove unnecessary packages?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Remove Unnecessary Packages" "sudo apt autoremove -y && sudo apt autoclean"
                fi
                ;;
            3)
                dialog --title "Confirmation" --yesno "Clean the APT cache?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clean APT Cache" "sudo apt clean"
                fi
                ;;
            4)
                dialog --defaultno --title "Confirmation" --yesno "Remove old kernels?\nWARNING: Always keep at least 2 kernels for safety." 10 60
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clear Old Kernels" "
                    {
                        echo 'Installed Kernels:'
                        dpkg --list | grep linux-image | awk '{print \$2}'
                        echo ''
                        echo \"Current Kernel: \$(uname -r)\"
                        echo 'Removing old kernels...'
                        sudo apt-get purge \$(dpkg-query -W -f'\${Package}\n' 'linux-*' | sed -nr 's/.*-([0-9]+(\\.[0-9]+){2}-[^-]+).*/\\1 &/p' | linux-version sort | awk '(\$1==c){exit} {print \$2}' c=\$(uname -r | cut -f1,2 -d-))
                    } > '$TEMP_OUTPUT' 2>&1"
                fi
                ;;
            5)
                dialog --title "Confirmation" --yesno "Clean system logs?\nOnly the last 7 days will be kept." 10 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clean Logs" "sudo journalctl --vacuum-time=7d && sudo find /var/log -name '*.log' -type f -mtime +30 -delete"
                fi
                ;;
            6)
                dialog --title "Confirmation" --yesno "Empty the trash bin?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Empty Trash Bin" "rm -rf ~/.local/share/Trash/*"
                fi
                ;;
            7)
                dialog --title "Confirmation" --yesno "Clean the thumbnail cache?" 8 50
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Clean Thumbnails" "rm -rf ~/.cache/thumbnails/*"
                fi
                ;;
            8)
                dialog --defaultno --title "Confirmation" --yesno "Perform full Ubuntu cleanup?\nThis will include all cleanup options." 10 60
                if [ $? -eq 0 ]; then
                    run_command_in_terminal "Full Ubuntu Cleanup" "
                    {
                        echo 'Starting full cleanup...'
                        echo 'Updating cache...'
                        sudo apt update
                        echo 'Removing unnecessary packages...'
                        sudo apt autoremove -y
                        echo 'Cleaning APT cache...'
                        sudo apt clean
                        sudo apt autoclean
                        echo 'Cleaning logs...'
                        sudo journalctl --vacuum-time=7d
                        echo 'Emptying trash bin...'
                        rm -rf ~/.local/share/Trash/*
                        echo 'Cleaning thumbnails...'
                        rm -rf ~/.cache/thumbnails/*
                        echo 'Cleaning user cache...'
                        rm -rf ~/.cache/* 2>/dev/null || true
                        echo 'Cleanup completed!'
                    } > '$TEMP_OUTPUT' 2>&1"
                fi
                ;;
            9)
                run_command_in_terminal "Disk Space" "
                {
                    echo '=== DISK SPACE ==='
                    df -h | awk 'NR==1 || /^\\/dev\\//'
                    echo ''
                    echo '=== Largest directories in /home ==='
                    du -sh ~/.* 2>/dev/null | sort -hr | head -10
                } > '$TEMP_OUTPUT'"
                ;;
            10|*)
                break
                ;;
        esac
    done
}

# Settings menu
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
                    run_command_in_terminal "ManzoloCleaner Log" "cat '$LOG_FILE'"
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
                    df -h | awk 'NR==1 || /^\\/dev\\//'
                } > '$TEMP_OUTPUT'"
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
                } > '$TEMP_OUTPUT'"
                ;;
            5|*)
                break
                ;;
        esac
    done
}

# Initialization function
init_script() {
    # Create the log file if it doesn't exist
    touch "$LOG_FILE"
    log_message "INFO" "Script started"
    
    # Check dependencies
    check_dependencies
    
    # Create the temporary output file
    touch "$TEMP_OUTPUT"
}

# Improved main menu
main_menu() {
    while true; do
        choice=$(dialog --clear --backtitle "$SCRIPT_NAME v2.4" --title "Main Menu" \
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
                } > '$TEMP_OUTPUT'"
                ;;
            5)
                dialog --title "Information" --msgbox "ManzoloCleaner v2.4\n\nAdvanced system cleaning tool\nwith support for Docker and Ubuntu.\n\nLog: $LOG_FILE\n\nCreated by: ManzoloScript" 12 50
                ;;
            6)
                dialog --defaultno --title "Confirmation" --yesno "Are you sure you want to exit?" 8 40
                if [ $? -eq 0 ]; then
                    clear
                    echo -e "${GREEN}Thank you for using ManzoloCleaner!${NC}"
                    log_message "INFO" "Script finished"
                    rm -f "$TEMP_OUTPUT"
                    exit 0
                fi
                ;;
            *)
                clear
                echo -e "${GREEN}Thank you for using ManzoloCleaner!${NC}"
                log_message "INFO" "Script finished"
                rm -f "$TEMP_OUTPUT"
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
    echo -e "${YELLOW}               CLEANER v2.4${NC}"
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

# mfirewall module: logging, dialogs, command execution helpers
# Sourced by mfirewall.sh — do not execute directly.
# =================== UTILITY FUNCTIONS ===================

# Enhanced logging function
log_action() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user
    user=$(whoami)
    echo "[$timestamp] [$level] [$user] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# Whiptail message boxes
show_message() {
    local title="$1"
    local message="$2"
    local type="${3:-info}"
    
    case $type in
        "error")
            whiptail --title "ERROR - $title" --msgbox "$message" $WT_HEIGHT $WT_WIDTH || true
            ;;
        "success")
            whiptail --title "SUCCESS - $title" --msgbox "$message" $WT_HEIGHT $WT_WIDTH || true
            ;;
        "warning")
            whiptail --title "WARNING - $title" --msgbox "$message" $WT_HEIGHT $WT_WIDTH || true
            ;;
        *)
            whiptail --title "INFO - $title" --msgbox "$message" $WT_HEIGHT $WT_WIDTH || true
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
    done | whiptail --title "Processing" --gauge "$message" 6 $WT_WIDTH 0 || true
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
        whiptail --title "System Requirements" --msgbox "$error_msg" $WT_HEIGHT $WT_WIDTH || true
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


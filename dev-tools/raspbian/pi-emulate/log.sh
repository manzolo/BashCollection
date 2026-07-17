# ==============================================================================
# LOGGING SYSTEM
# ==============================================================================

log_init() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== QEMU RPi Manager v${VERSION} Started: $(date) ===" >> "$LOG_FILE" 2>/dev/null || true
}

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Write to log file only if it exists and is writable
    if [ -w "$LOG_FILE" ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
    fi
    
    case $level in
        ERROR) echo -e "\033[0;31m[ERROR]\033[0m $message" >&2 ;;
        WARNING) echo -e "\033[1;33m[WARNING]\033[0m $message" >&2 ;;
        INFO) [ "${VERBOSE}" = "1" ] && echo -e "\033[0;32m[INFO]\033[0m $message" ;;
        DEBUG) [ "${DEBUG}" = "1" ] && echo -e "\033[0;34m[DEBUG]\033[0m $message" ;;
    esac
    return 0
}

# ==============================================================================
# LOG VIEWER
# ==============================================================================

view_logs() {
    local log_files=$(ls -1t "$LOGS_DIR"/*.log 2>/dev/null)
    
    if [ -z "$log_files" ]; then
        dialog --msgbox "No log files found!" 8 40
        return
    fi
    
    local log_menu=""
    local counter=1
    local log_array=()
    
    while IFS= read -r log_file; do
        local basename=$(basename "$log_file")
        log_menu+="$counter \"$basename\" "
        log_array+=("$log_file")
        ((counter++))
    done <<< "$log_files"
    
    local choice
    choice=$(eval dialog --title \"Select Log File\" --menu \"Choose a log file to view:\" 15 60 8 $log_menu 2>&1 >/dev/tty)
    
    [ -z "$choice" ] && return
    
    local selected_log="${log_array[$((choice-1))]}"
    
    if [ -f "$selected_log" ]; then
        #dialog --title "Log: $(basename "$selected_log")" --textbox "$selected_log" 20 80
        clear
        cat $selected_log
        read -r
    else
        dialog --msgbox "Log file not found!" 8 40
    fi
}
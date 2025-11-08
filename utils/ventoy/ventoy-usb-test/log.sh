# Utility functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Show compilation log
show_compilation_log() {
    local log_file="$1"
    
    if [[ -f "$log_file" ]]; then
        # Create a filtered version of the log
        local filtered_log=$(mktemp)
        
        # Extract key sections
        {
            echo "=== COMPILATION PHASES ==="
            grep "PHASE:" "$log_file" 2>/dev/null || echo "No phases identified"
            echo
            echo "=== ERRORS ==="
            grep -i "error\|failed\|fatal" "$log_file" 2>/dev/null || echo "No explicit errors found"
            echo
            echo "=== LAST 20 LINES ==="
            tail -20 "$log_file" 2>/dev/null || echo "Log not readable"
        } > "$filtered_log"
        
        local log_content=$(cat "$filtered_log")
        whiptail --title "OVMF Compilation Log" --scrolltext \
            --msgbox "$log_content" 20 80
            
        rm -f "$filtered_log"
    else
        whiptail --title "Error" --msgbox "Log file not found or already deleted." 8 40
    fi
}

# Show system logs (placeholder)
show_system_logs() {
    whiptail --title "System Logs" --msgbox \
        "System log function not implemented.\n\nFor now, use: journalctl -f" \
        10 50
}
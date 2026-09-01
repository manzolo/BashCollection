# Logging helpers
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Show a filtered view of the OVMF compilation log
show_compilation_log() {
    local log_file="$1"

    if [[ ! -f "$log_file" ]]; then
        whiptail --title "Error" --msgbox "Log file not found or already deleted." 8 40 || true
        return
    fi

    local log_content
    log_content=$(
        echo "=== COMPILATION PHASES ==="
        grep "PHASE:" "$log_file" 2>/dev/null || echo "No phases identified"
        echo
        echo "=== ERRORS ==="
        grep -i "error\|failed\|fatal" "$log_file" 2>/dev/null || echo "No explicit errors found"
        echo
        echo "=== LAST 20 LINES ==="
        tail -20 "$log_file" 2>/dev/null || echo "Log not readable"
    )
    whiptail --title "OVMF Compilation Log" --scrolltext \
        --msgbox "$log_content" 20 80 || true
}

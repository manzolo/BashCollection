# manzolo-backup-home module: logging, progress, header, system info
# Sourced by manzolo-backup-home.sh — do not execute directly.
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    case "$level" in
        "ERROR")   echo -e "${RED}${ERROR} [${timestamp}] ERROR: ${message}${NC}" ;;
        "WARN")    echo -e "${YELLOW}${WARNING} [${timestamp}] WARNING: ${message}${NC}" ;;
        "INFO")    echo -e "${BLUE}${INFO} [${timestamp}] INFO: ${message}${NC}" ;;
        "SUCCESS") echo -e "${GREEN}${SUCCESS} [${timestamp}] SUCCESS: ${message}${NC}" ;;
        "DEBUG")   [ "$VERBOSE" = true ] && echo -e "${GRAY}🐛 [${timestamp}] DEBUG: ${message}${NC}" ;;
        *)         echo -e "${WHITE}📝 [${timestamp}] ${message}${NC}" ;;
    esac
    
    # Also log to file if log directory exists
    [ -d "$LOG_DIR" ] && echo "[${timestamp}] ${level}: ${message}" >> "$LOG_DIR/backup.log"
}

# Progress bar function
show_progress() {
    local current="$1"
    local total="$2"
    local source_dir="$3"
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((current * width / total))
    local remaining=$((width - completed))
    
    # Clear the line and show progress with current directory
    printf "\r\033[K${CYAN}["
    printf "%*s" "$completed" "" | tr ' ' '='
    printf "%*s" "$remaining" "" | tr ' ' '-'
    printf "] %d%% (%d/%d) ${WHITE}%s${NC}" "$percentage" "$current" "$total" "$(basename "$source_dir")"
}

# Fancy header
print_header() {
    local title="$1"
    local width=80
    
    echo -e "\n${PURPLE}$(printf '═%.0s' {1..80})${NC}"
    printf "${WHITE}%*s${NC}\n" $(((width + ${#title}) / 2)) "$title"
    echo -e "${PURPLE}$(printf '═%.0s' {1..80})${NC}\n"
}

# System information display - fixed alignment
show_system_info() {
    local hostname_str datetime_str
    hostname_str="$(hostname)"
    datetime_str="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC} ${ROCKET} ${WHITE}SYSTEM INFORMATION${NC}                                                     ${CYAN}│${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC} ${INFO} Host: ${hostname_str}"
    echo -e "${CYAN}│${NC} ${INFO} User: ${REAL_USER}"
    echo -e "${CYAN}│${NC} ${CLOCK} Time: ${datetime_str}"
    echo -e "${CYAN}│${NC} ${DISK} Dest: ${DEST_DISK}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────────────┘${NC}"
}

# Load configuration file

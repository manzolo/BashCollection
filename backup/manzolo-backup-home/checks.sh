# manzolo-backup-home module: prerequisites and real-user detection
# Sourced by manzolo-backup-home.sh — do not execute directly.
check_prerequisites() {
    local missing_tools=()
    
    # Check required tools
    for tool in rsync find du df date; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log "ERROR" "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log "ERROR" "This script must be run with sudo to handle root files"
        echo -e "${YELLOW}Usage:${NC} sudo $0 $*"  # $* echoes the original argv forwarded by main
        exit 1
    fi
    
    # Create log directory
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"
}

# Determine real user
get_real_user() {
    if [ -n "${SUDO_USER:-}" ]; then
        REAL_USER="$SUDO_USER"
    elif [ -n "${1:-}" ]; then
        REAL_USER="$1"
    else
        log "ERROR" "Cannot determine the real user. Specify username as parameter."
        exit 1
    fi
    
    # Validate user exists
    if ! id "$REAL_USER" &>/dev/null; then
        log "ERROR" "User '$REAL_USER' does not exist"
        exit 1
    fi
    
    # Add user's home to backup directories
    local user_home
    user_home=$(getent passwd "$REAL_USER" | cut -d: -f6)
    if [ ! -d "$user_home" ]; then
        log "ERROR" "Home directory '$user_home' for user '$REAL_USER' does not exist"
        exit 1
    fi
    BACKUP_DIRS+=("$user_home")
}

# Create comprehensive exclude file

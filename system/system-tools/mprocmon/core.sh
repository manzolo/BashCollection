# mprocmon module: environment, logging, validation helpers
# Sourced by mprocmon.sh — do not execute directly.
init_environment() {
    # Create necessary directories
    mkdir -p "$LOG_DIR" "$TEMP_DIR"
    
    # Set trap for cleanup
    trap cleanup EXIT INT TERM
    
    # Initialize log file
    log_message "INFO" "Starting $SCRIPT_NAME v$SCRIPT_VERSION"
    log_message "INFO" "PID: $$, User: $(whoami), Date: $(date)"
}

# Cleanup function
cleanup() {
    local exit_code=$?
    log_message "INFO" "Cleaning up temporary files"
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    exit $exit_code
}

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Print colored output
print_color() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# Error handling function
handle_error() {
    local error_message="$1"
    local exit_code="${2:-1}"
    
    print_color "$RED" "ERROR: $error_message"
    log_message "ERROR" "$error_message"
    
    whiptail --title "Error" --msgbox "$error_message" 10 60 || true
    exit "$exit_code"
}

# Check dependencies
check_dependencies() {
    local dependencies=("whiptail" "lsof" "ss" "netstat" "ps")
    local missing_deps=()
    
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        local install_msg="Missing dependencies: ${missing_deps[*]}\n\n"
        install_msg+="Installation commands:\n"
        install_msg+="Ubuntu/Debian: sudo apt-get install whiptail lsof iproute2 net-tools procps\n"
        install_msg+="CentOS/RHEL: sudo yum install newt lsof iproute net-tools procps-ng\n"
        install_msg+="Fedora: sudo dnf install newt lsof iproute net-tools procps-ng"
        
        handle_error "$install_msg"
    fi
    
    log_message "INFO" "All dependencies satisfied"
}

# Validate input functions
validate_pid() {
    local pid="$1"
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ "$pid" -le 0 ]]; then
        return 1
    fi
    return 0
}

validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        return 1
    fi
    return 0
}

validate_file_path() {
    local path="$1"
    if [[ -z "$path" ]] || [[ ! "$path" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
        return 1
    fi
    return 0
}

# Enhanced port scanning with lsof

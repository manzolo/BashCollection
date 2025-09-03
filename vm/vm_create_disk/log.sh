# Global logging configuration
LOG_LEVEL=${LOG_LEVEL:-2}  # 0=ERROR, 1=WARN, 2=INFO, 3=DEBUG
VERBOSE=${VERBOSE:-0}      # 0=normal, 1=verbose (affects command output)

_log() {
    local level="$1"
    local color="$2"
    local prefix="$3"
    local message="$4"
    local min_log_level="$5"
    local use_stderr="${6:-0}"
    
    # Check if message should be logged based on level
    if [ "$LOG_LEVEL" -lt "$min_log_level" ]; then
        return 0
    fi
    
    # Format message with timestamp and level
    local timestamp=$(date '+%H:%M:%S')
    local formatted="[${timestamp}] ${prefix} ${message}"
    
    # Output to appropriate stream
    if [ "$use_stderr" -eq 1 ]; then
        echo -e "${color}${formatted}${NC}" >&2
    else
        echo -e "${color}${formatted}${NC}"
    fi
}

# Public logging functions
log_error() {
    _log "ERROR" "$RED" "[ERROR  ]" "$1" 0 1
}

log_warn() {
    _log "WARN" "$YELLOW" "[WARN   ]" "$1" 1 1
}

log_info() {
    _log "INFO" "$BLUE" "[INFO   ]" "$1" 2 0
}

log_success() {
    _log "SUCCESS" "$GREEN" "[SUCCESS]" "$1" 2 0
}

log_debug() {
    _log "DEBUG" "$GRAY" "[DEBUG  ]" "$1" 3 1
}

# ==============================================================================
# SPECIALIZED LOGGING FUNCTIONS
# ==============================================================================

# For progress messages during operations
log_progress() {
    if [ "$LOG_LEVEL" -ge 2 ]; then
        echo -e "${BLUE}▶ $1${NC}"
    fi
}

# For command execution with optional verbose output
log_exec() {
    local cmd="$1"
    local description="$2"
    
    if [ -n "$description" ]; then
        log_progress "$description"
    fi
    
    log_debug "Executing: $cmd"
    
    if [ "$VERBOSE" -eq 1 ]; then
        eval "$cmd"
    else
        eval "$cmd" >/dev/null 2>&1
    fi
    
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        log_debug "Command succeeded: $cmd"
    else
        log_error "Command failed (exit $exit_code): $cmd"
    fi
    
    return $exit_code
}

# For formatting partition information
log_partition_table() {
    local device="$1"
    local partition_table="$2"
    
    log_info "Partition table for $(basename "$device"):"
    
    # Generate formatted table
    sudo parted -s "$device" print | awk -v part_table="$partition_table" '
    BEGIN {
        if (part_table == "mbr") {
            printf "%-6s %-10s %-10s %-10s %-12s %-8s %s\n", "Num", "Start", "End", "Size", "Filesystem", "Type", "Name"
            printf "%-6s %-10s %-10s %-10s %-12s %-8s %s\n", "---", "-----", "---", "----", "----------", "----", "----"
        } else {
            printf "%-6s %-10s %-10s %-10s %-12s %s\n", "Num", "Start", "End", "Size", "Filesystem", "Name"  
            printf "%-6s %-10s %-10s %-10s %-12s %s\n", "---", "-----", "---", "----", "----------", "----"
        }
    }
    /^[ ]*[0-9]+/ {
        num=$1; start=$2; end=$3; size=$4
        fs=$5; if(fs=="" || fs=="unknown") fs="none"
        
        # Determine type and name based on filesystem
        type="primary"
        name="Unknown"
        
        if ($0 ~ /extended/) type="extended"
        else if (num >= 5) type="logical"
        
        if (fs=="swap") name="Linux swap"
        else if (fs ~ /^ext[234]$|xfs|btrfs/) name="Linux filesystem"
        else if (fs ~ /ntfs|fat/) name="Microsoft basic data"
        else if (fs=="none") name="Unformatted"
        
        if (part_table == "mbr") {
            printf "%-6s %-10s %-10s %-10s %-12s %-8s %s\n", num, start, end, size, fs, type, name
        } else {
            printf "%-6s %-10s %-10s %-10s %-12s %s\n", num, start, end, size, fs, name
        }
    }' | while IFS= read -r line; do
        echo "  $line"
    done
}

# ==============================================================================
# MIGRATION HELPERS (for backward compatibility)
# ==============================================================================

# Legacy function aliases - these will gradually be replaced
log() { 
    log_info "$1" 
}

error() { 
    log_error "$1" 
}

warning() { 
    log_warn "$1" 
}

success() { 
    log_success "$1" 
}

# Function to demonstrate the new logging system
demo_logging() {
    echo "=== Logging System Demo ==="
    echo
    
    log_error "This is an error message"
    log_warn "This is a warning message"  
    log_info "This is an info message"
    log_success "This is a success message"
    log_debug "This is a debug message (only visible with LOG_LEVEL=3)"
    log_progress "This is a progress message"
    
    echo
    echo "=== Command Execution Demo ==="
    log_exec "echo 'Hello World'" "Testing echo command"
    log_exec "false" "Testing failed command"
    
    echo
    echo "=== Partition Table Demo ==="
    # This would work with a real device:
    # log_partition_table "/dev/sda" "gpt"
}
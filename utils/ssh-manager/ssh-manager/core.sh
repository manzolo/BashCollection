#!/bin/bash
# Core functions for SSH Manager
# Provides: logging, colors, messaging, basic utilities

# Colors for output
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
RESET='\e[0m'

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    rotate_log
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" >> "$LOG_FILE"
}

# Log rotation
rotate_log() {
    local max_size=$((1024*1024)) # 1MB
    if [[ -f "$LOG_FILE" ]]; then
        local file_size
        file_size=$(wc -c < "$LOG_FILE" 2>/dev/null)
        if [[ -n "$file_size" && "$file_size" =~ ^[0-9]+$ && "$file_size" -gt "$max_size" ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.1"
            touch "$LOG_FILE"
            log_message "INFO" "Log file rotated"
        fi
    fi
}

# Function to print colored messages
print_message() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${RESET}"
}

# Test SSH connectivity
test_ssh_connection() {
    local user="$1"
    local host="$2"
    local port="${3:-22}"

    print_message "$BLUE" "🔍 Testing connectivity to $user@$host:$port..."

    if timeout 5 ssh -o ConnectTimeout=3 -p "$port" "$user@$host" exit 2> ssh_error.log; then
        print_message "$GREEN" "✅ Connection successful"
        rm -f ssh_error.log
        return 0
    else
        print_message "$RED" "❌ Connection failed: $(cat ssh_error.log)"
        log_message "ERROR" "Connection test failed for $user@$host:$port - $(cat ssh_error.log)"
        rm -f ssh_error.log
        return 1
    fi
}

# Check for SSH key existence
check_ssh_key() {
    if [[ ! -f "$HOME/.ssh/id_rsa.pub" ]]; then
        print_message "$RED" "❌ No SSH public key found. Generate one with 'ssh-keygen'."
        return 1
    fi
    return 0
}

# Get server index by name
get_server_index_by_name() {
    local server_name="$1"
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")

    for ((i=0; i<server_count; i++)); do
        local name
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        if [[ "$name" == "$server_name" ]]; then
            echo "$i"
            return 0
        fi
    done

    return 1
}

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

# Parsed SSH options are kept in a shared array for Bash 4 compatibility
PARSED_SSH_OPTIONS=()
INTERRUPTED=0
RETURN_TO_MAIN_MENU=0

handle_interrupt() {
    INTERRUPTED=1
    RETURN_TO_MAIN_MENU=1
    echo
}

clear_interrupt_state() {
    INTERRUPTED=0
}

clear_main_menu_request() {
    RETURN_TO_MAIN_MENU=0
}

should_return_to_main_menu() {
    [[ "$RETURN_TO_MAIN_MENU" -eq 1 ]]
}

pause_for_enter() {
    local prompt="${1:-\nPress ENTER to continue...}"

    if should_return_to_main_menu; then
        return 0
    fi

    print_message "$YELLOW" "$prompt"
    read -r

    if [[ $? -eq 130 || "$INTERRUPTED" -eq 1 ]]; then
        return 0
    fi

    return 0
}

# Parse SSH options conservatively to avoid command injection.
# Complex shell constructs should live in ~/.ssh/config instead.
parse_ssh_options() {
    local raw_options="$1"
    PARSED_SSH_OPTIONS=()

    [[ -z "$raw_options" || "$raw_options" == "null" ]] && return 0

    if [[ "$raw_options" == *$'\n'* || "$raw_options" == *$'\r'* ]] || \
       [[ "$raw_options" =~ [\`\;\&\|\<\>\$\(\)\{\}\\\'\"] ]]; then
        print_message "$RED" "❌ Unsafe SSH options detected. Use simple flags only or move complex logic to ~/.ssh/config."
        return 1
    fi

    read -r -a PARSED_SSH_OPTIONS <<< "$raw_options"
    return 0
}

# Build a shell-escaped ssh command string for tools like sshfs that only accept a string.
build_ssh_command_string() {
    local port="$1"
    local ssh_command=()
    local ssh_command_string

    ssh_command=(ssh -p "$port")
    if [[ ${#PARSED_SSH_OPTIONS[@]} -gt 0 ]]; then
        ssh_command+=("${PARSED_SSH_OPTIONS[@]}")
    fi

    printf -v ssh_command_string '%q ' "${ssh_command[@]}"
    printf '%s\n' "${ssh_command_string% }"
}

# Test SSH connectivity
test_ssh_connection() {
    local user="$1"
    local host="$2"
    local port="${3:-22}"

    print_message "$BLUE" "🔍 Testing connectivity to $user@$host:$port..."

    local error_log="$CONFIG_DIR/ssh_error.log"
    
    if timeout 5 ssh -o ConnectTimeout=3 -p "$port" "$user@$host" exit 2> "$error_log"; then
        print_message "$GREEN" "✅ Connection successful"
        rm -f "$error_log"
        return 0
    else
        if [[ -f "$error_log" ]]; then
            print_message "$RED" "❌ Connection failed: $(cat "$error_log")"
            log_message "ERROR" "Connection test failed for $user@$host:$port - $(cat "$error_log")"
            rm -f "$error_log"
        else
            print_message "$RED" "❌ Connection failed (no error log)"
            log_message "ERROR" "Connection test failed for $user@$host:$port"
        fi
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

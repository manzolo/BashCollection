#!/bin/bash
# Core functions for SSH Manager
# Provides: logging, colors, messaging, basic utilities

# Colors for output
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
RESET='\e[0m'

SSH_CONFIG_FILE="$HOME/.ssh/config"
EXPORT_DIR="$CONFIG_DIR/exports"

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
RESOLVED_SERVER_NAME=""
RESOLVED_HOST=""
RESOLVED_USER=""
RESOLVED_PORT=""
RESOLVED_SSH_ALIAS=""
RESOLVED_SSH_TARGET=""
RESOLVED_DISPLAY_TARGET=""
RESOLVED_IDENTITY_FILE=""
RESOLVED_PROXY_JUMP=""
RESOLVED_HAS_ALIAS=0

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

pause_for_key() {
    local prompt="${1:-\nPress any key to continue...}"

    if should_return_to_main_menu; then
        return 0
    fi

    print_message "$YELLOW" "$prompt"
    read -r -n 1 -s

    if [[ $? -eq 130 || "$INTERRUPTED" -eq 1 ]]; then
        return 0
    fi

    return 0
}

ensure_manager_runtime_dirs() {
    mkdir -p "$CONFIG_DIR" "$EXPORT_DIR"
    chmod 700 "$CONFIG_DIR" 2>/dev/null
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
    local target="${2:-}"
    local ssh_command=()
    local ssh_command_string

    ssh_command=(ssh)
    if [[ -z "$target" || "$target" == *@* ]]; then
        ssh_command+=(-p "$port")
    fi
    if [[ -n "$RESOLVED_PROXY_JUMP" ]]; then
        ssh_command+=(-J "$RESOLVED_PROXY_JUMP")
    fi
    if [[ ${#PARSED_SSH_OPTIONS[@]} -gt 0 ]]; then
        ssh_command+=("${PARSED_SSH_OPTIONS[@]}")
    fi

    printf -v ssh_command_string '%q ' "${ssh_command[@]}"
    printf '%s\n' "${ssh_command_string% }"
}

resolve_server_connection() {
    local index="$1"
    local ssh_options=""
    local ssh_g_output=""
    local configured_jump_host=""

    RESOLVED_SERVER_NAME=$(yq eval ".servers[$index].name" "$CONFIG_FILE")
    RESOLVED_HOST=$(yq eval ".servers[$index].host" "$CONFIG_FILE")
    RESOLVED_USER=$(yq eval ".servers[$index].user" "$CONFIG_FILE")
    RESOLVED_PORT=$(yq eval ".servers[$index].port // 22" "$CONFIG_FILE")
    RESOLVED_SSH_ALIAS=$(yq eval ".servers[$index].ssh_alias // \"\"" "$CONFIG_FILE")
    configured_jump_host=$(yq eval ".servers[$index].jump_host // \"\"" "$CONFIG_FILE")
    ssh_options=$(yq eval ".servers[$index].ssh_options // \"\"" "$CONFIG_FILE")
    [[ "$RESOLVED_SSH_ALIAS" == "null" ]] && RESOLVED_SSH_ALIAS=""
    [[ "$configured_jump_host" == "null" ]] && configured_jump_host=""

    RESOLVED_IDENTITY_FILE=""
    RESOLVED_PROXY_JUMP=""
    RESOLVED_HAS_ALIAS=0

    if ! parse_ssh_options "$ssh_options"; then
        return 1
    fi

    if [[ -n "$RESOLVED_SSH_ALIAS" ]]; then
        RESOLVED_HAS_ALIAS=1
        RESOLVED_SSH_TARGET="$RESOLVED_SSH_ALIAS"

        if ssh_g_output=$(ssh -G "$RESOLVED_SSH_ALIAS" 2>/dev/null); then
            local resolved_host resolved_user resolved_port resolved_identity resolved_proxy_jump
            resolved_host=$(awk '$1=="hostname"{print $2; exit}' <<< "$ssh_g_output")
            resolved_user=$(awk '$1=="user"{print $2; exit}' <<< "$ssh_g_output")
            resolved_port=$(awk '$1=="port"{print $2; exit}' <<< "$ssh_g_output")
            resolved_identity=$(awk '$1=="identityfile"{print $2; exit}' <<< "$ssh_g_output")
            resolved_proxy_jump=$(awk '$1=="proxyjump"{print $2; exit}' <<< "$ssh_g_output")

            [[ -n "$resolved_host" ]] && RESOLVED_HOST="$resolved_host"
            [[ -n "$resolved_user" ]] && RESOLVED_USER="$resolved_user"
            [[ -n "$resolved_port" ]] && RESOLVED_PORT="$resolved_port"
            [[ -n "$resolved_identity" ]] && RESOLVED_IDENTITY_FILE="$resolved_identity"
            [[ -n "$resolved_proxy_jump" ]] && RESOLVED_PROXY_JUMP="$resolved_proxy_jump"
        fi
    else
        RESOLVED_SSH_TARGET="$RESOLVED_USER@$RESOLVED_HOST"
    fi

    if [[ -n "$configured_jump_host" ]]; then
        RESOLVED_PROXY_JUMP="$configured_jump_host"
    fi

    if [[ "$RESOLVED_HAS_ALIAS" -eq 1 ]]; then
        RESOLVED_DISPLAY_TARGET="$RESOLVED_SSH_ALIAS ($RESOLVED_USER@$RESOLVED_HOST:$RESOLVED_PORT)"
    else
        RESOLVED_DISPLAY_TARGET="$RESOLVED_USER@$RESOLVED_HOST:$RESOLVED_PORT"
    fi

    return 0
}

append_resolved_connection_options() {
    local -n cmd_ref=$1

    if [[ "$RESOLVED_HAS_ALIAS" -eq 0 ]]; then
        cmd_ref+=(-p "$RESOLVED_PORT")
    fi
    if [[ -n "$RESOLVED_PROXY_JUMP" ]]; then
        cmd_ref+=(-J "$RESOLVED_PROXY_JUMP")
    fi
    if [[ ${#PARSED_SSH_OPTIONS[@]} -gt 0 ]]; then
        cmd_ref+=("${PARSED_SSH_OPTIONS[@]}")
    fi
}

format_last_used() {
    local last_used="$1"
    local now delta

    if [[ -z "$last_used" || "$last_used" == "null" || "$last_used" -le 0 ]]; then
        printf '%s\n' "never"
        return 0
    fi

    now=$(date +%s)
    delta=$((now - last_used))

    if [[ "$delta" -lt 60 ]]; then
        printf '%ss ago\n' "$delta"
    elif [[ "$delta" -lt 3600 ]]; then
        printf '%sm ago\n' "$((delta / 60))"
    elif [[ "$delta" -lt 86400 ]]; then
        printf '%sh ago\n' "$((delta / 3600))"
    else
        printf '%sd ago\n' "$((delta / 86400))"
    fi
}

record_server_usage() {
    local index="$1"
    local action="$2"
    local now use_count

    now=$(date +%s)
    use_count=$(yq eval ".servers[$index].use_count // 0" "$CONFIG_FILE")
    [[ "$use_count" == "null" || -z "$use_count" ]] && use_count=0

    yq eval "(.servers[$index].last_used) = $now" -i "$CONFIG_FILE"
    yq eval "(.servers[$index].last_action) = \"$action\"" -i "$CONFIG_FILE"
    yq eval "(.servers[$index].use_count) = $((use_count + 1))" -i "$CONFIG_FILE"
}

get_sorted_server_indices() {
    local server_count
    local sortable_lines=()
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")

    for ((i=0; i<server_count; i++)); do
        local name favorite last_used
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        favorite=$(yq eval ".servers[$i].favorite // false" "$CONFIG_FILE")
        last_used=$(yq eval ".servers[$i].last_used // 0" "$CONFIG_FILE")
        [[ "$favorite" == "true" ]] && favorite=0 || favorite=1
        [[ "$last_used" == "null" || -z "$last_used" ]] && last_used=0
        sortable_lines+=("${favorite}|${last_used}|${name}|${i}")
    done

    if [[ ${#sortable_lines[@]} -eq 0 ]]; then
        return 0
    fi

    printf '%s\n' "${sortable_lines[@]}" | sort -t'|' -k1,1n -k2,2nr -k3,3f | awk -F'|' '{print $4}'
}

build_server_menu_items() {
    local indices
    local menu_items=()
    local i

    indices=$(get_sorted_server_indices)
    while IFS= read -r i; do
        [[ -z "$i" ]] && continue

        local name host user port description favorite last_used recent_label display_text
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        port=$(yq eval ".servers[$i].port // 22" "$CONFIG_FILE")
        description=$(yq eval ".servers[$i].description // \"\"" "$CONFIG_FILE")
        favorite=$(yq eval ".servers[$i].favorite // false" "$CONFIG_FILE")
        last_used=$(yq eval ".servers[$i].last_used // 0" "$CONFIG_FILE")

        display_text="$name ($user@$host:$port)"
        [[ "$favorite" == "true" ]] && display_text="★ $display_text"

        recent_label=$(format_last_used "$last_used")
        [[ "$recent_label" != "never" ]] && display_text="$display_text - recent: $recent_label"
        [[ -n "$description" && "$description" != "null" ]] && display_text="$display_text - $description"

        menu_items+=("$name" "$display_text")
    done <<< "$indices"

    printf '%s\0' "${menu_items[@]}"
}

list_ssh_config_aliases() {
    [[ ! -f "$SSH_CONFIG_FILE" ]] && return 0

    awk '
        /^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]+/ {
            for (i = 2; i <= NF; i++) {
                if ($i !~ /[*?!]/) {
                    print $i
                }
            }
        }
    ' "$SSH_CONFIG_FILE" | sort -u
}

generate_export_host_alias() {
    local index="$1"
    local alias name

    alias=$(yq eval ".servers[$index].ssh_alias // \"\"" "$CONFIG_FILE")
    [[ "$alias" != "null" && -n "$alias" ]] && {
        printf '%s\n' "$alias"
        return 0
    }

    name=$(yq eval ".servers[$index].name" "$CONFIG_FILE")
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//')
    [[ -z "$name" ]] && name="ssh-manager-$index"
    printf '%s\n' "$name"
}

run_server_health_check() {
    local index="$1"
    local ssh_cmd=()
    local error_log tcp_status auth_status tunnel_count

    if ! resolve_server_connection "$index"; then
        print_message "$RED" "❌ Invalid SSH options for selected server"
        return 1
    fi

    print_message "$BLUE" "🔎 Health check: $RESOLVED_SERVER_NAME"
    print_message "$BLUE" "   Target: $RESOLVED_DISPLAY_TARGET"

    tunnel_count=$(yq eval ".servers[$index].portforwards | length" "$CONFIG_FILE" 2>/dev/null)
    [[ "$tunnel_count" == "null" || -z "$tunnel_count" ]] && tunnel_count=0
    print_message "$BLUE" "   Port forward profiles: $tunnel_count"

    if timeout 3 bash -c "</dev/tcp/$RESOLVED_HOST/$RESOLVED_PORT" 2>/dev/null; then
        print_message "$GREEN" "   ✓ TCP port $RESOLVED_PORT reachable on $RESOLVED_HOST"
        tcp_status=0
    else
        print_message "$RED" "   ✗ TCP port $RESOLVED_PORT not reachable on $RESOLVED_HOST"
        tcp_status=1
    fi

    error_log=$(mktemp "${TMPDIR:-/tmp}/ssh-manager-health.XXXXXX")
    ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout=5)
    append_resolved_connection_options ssh_cmd
    ssh_cmd+=("$RESOLVED_SSH_TARGET" exit)

    if "${ssh_cmd[@]}" 2>"$error_log"; then
        print_message "$GREEN" "   ✓ SSH authentication test passed"
        auth_status=0
    else
        print_message "$RED" "   ✗ SSH authentication/login test failed: $(cat "$error_log" 2>/dev/null)"
        auth_status=1
    fi
    rm -f "$error_log"

    if [[ -n "$RESOLVED_IDENTITY_FILE" ]]; then
        print_message "$BLUE" "   IdentityFile: $RESOLVED_IDENTITY_FILE"
    fi
    if [[ -n "$RESOLVED_PROXY_JUMP" ]]; then
        print_message "$BLUE" "   ProxyJump: $RESOLVED_PROXY_JUMP"
    fi

    if [[ "$tcp_status" -eq 0 && "$auth_status" -eq 0 ]]; then
        return 0
    fi

    return 1
}

# Test SSH connectivity
test_ssh_connection() {
    local user="$1"
    local host="$2"
    local port="${3:-22}"
    local error_log="$CONFIG_DIR/ssh_error.log"

    print_message "$BLUE" "🔍 Testing connectivity to $user@$host:$port..."

    if timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=3 -p "$port" "$user@$host" exit 2> "$error_log"; then
        print_message "$GREEN" "✅ Connection successful"
        rm -f "$error_log"
        return 0
    fi

    if [[ -f "$error_log" ]]; then
        print_message "$RED" "❌ Connection failed: $(cat "$error_log")"
        log_message "ERROR" "Connection test failed for $user@$host:$port - $(cat "$error_log")"
        rm -f "$error_log"
    else
        print_message "$RED" "❌ Connection failed (no error log)"
        log_message "ERROR" "Connection test failed for $user@$host:$port"
    fi
    return 1
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

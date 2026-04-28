#!/bin/bash
# Port forwarding management for SSH Manager
# Provides: Local (-L), Remote (-R), Dynamic (-D) SSH tunnels

# Global array to track active tunnels
declare -A ACTIVE_TUNNELS

# Port forward profiles directory
PF_DIR="$CONFIG_DIR/portforwards"
PF_PIDS_FILE="$PF_DIR/active_pids"

# Initialize port forward directory
init_portforward_dir() {
    mkdir -p "$PF_DIR"
    [[ ! -f "$PF_PIDS_FILE" ]] && touch "$PF_PIDS_FILE"
}

rewrite_pf_pids_file() {
    local temp_file
    temp_file=$(mktemp "$PF_DIR/.active_pids.XXXXXX")
    cat > "$temp_file"
    mv "$temp_file" "$PF_PIDS_FILE"
}

# Find a free local port
find_free_port() {
    local start_port="${1:-10000}"
    local port=$start_port

    while [[ $port -lt 65535 ]]; do
        if ! is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
        ((port++))
    done

    return 1
}

# Check if port is in use
is_port_in_use() {
    local port="$1"

    # Check with ss (preferred)
    if command -v ss &>/dev/null; then
        ss -tln 2>/dev/null | grep -qE ":${port}\s"
        return $?
    fi

    # Fallback to netstat
    if command -v netstat &>/dev/null; then
        netstat -tln 2>/dev/null | grep -qE ":${port}\s"
        return $?
    fi

    # Last resort: try to bind to the port
    (echo >/dev/tcp/localhost/$port) 2>/dev/null
    return $?
}

# Find SSH tunnel PIDs using port
find_tunnel_pids_by_port() {
    local port="$1"
    local pids=()

    # Find processes listening on this port
    if command -v lsof &>/dev/null; then
        pids=($(lsof -ti :$port 2>/dev/null))
    elif command -v ss &>/dev/null; then
        # Extract PIDs from ss output using sed instead of grep -P
        local ss_pids=$(ss -tlnp 2>/dev/null | grep ":$port " | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)
        pids=($ss_pids)
    fi

    # Filter for SSH processes only
    local ssh_pids=()
    for pid in "${pids[@]}"; do
        if ps -p "$pid" -o comm= 2>/dev/null | grep -qE '^(ssh|autossh)$'; then
            ssh_pids+=("$pid")
        fi
    done

    echo "${ssh_pids[@]}"
}

# Check if autossh is available
check_autossh() {
    command -v autossh &>/dev/null
}

# Add port forward profile
add_portforward() {
    local local_host
    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers configured. Add a server first." 8 50
        return 1
    fi

    # Select server
    local menu_items=()
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")

    for ((i=0; i<server_count; i++)); do
        local name host user
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        menu_items+=("$name" "$name ($user@$host)")
    done

    local server_choice
    server_choice=$(dialog --clear --title "Add Port Forward" --menu \
        "Select server for port forwarding:" \
        15 60 8 "${menu_items[@]}" 2>&1 >/dev/tty) || return

    if should_return_to_main_menu; then
        clear
        return
    fi

    local server_index
    if ! server_index=$(get_server_index_by_name "$server_choice"); then
        return 1
    fi

    # Select tunnel type
    local tunnel_type
    tunnel_type=$(dialog --clear --title "Tunnel Type" --menu \
        "Select port forwarding type:" \
        15 70 3 \
        "L" "Local Forward (-L) - Access remote service locally" \
        "R" "Remote Forward (-R) - Expose local service remotely" \
        "D" "Dynamic Forward (-D) - SOCKS proxy" \
        2>&1 >/dev/tty) || return

    local pf_name local_port remote_host remote_port description

    pf_name=$(dialog --inputbox "Port forward profile name:" 10 60 2>&1 >/dev/tty) || return
    [[ -z "$pf_name" ]] && return

    # Check for duplicate name
    if PF_NAME="$pf_name" yq eval ".servers[$server_index].portforwards[]? | select(.name == strenv(PF_NAME)) | .name" "$CONFIG_FILE" 2>/dev/null | grep -Fxq "$pf_name"; then
        dialog --title "Error" --msgbox "Port forward profile '$pf_name' already exists!" 8 50
        return 1
    fi

    case "$tunnel_type" in
        "L")
            local_port=$(dialog --inputbox "Local port (or 'auto' for automatic):" 10 60 "auto" 2>&1 >/dev/tty) || return
            if [[ "$local_port" == "auto" ]]; then
                local_port=$(find_free_port 10000)
                dialog --title "Auto Port" --msgbox "Assigned local port: $local_port" 8 40
            fi

            remote_host=$(dialog --inputbox "Remote host (e.g., localhost, 192.168.1.10):" 10 60 "localhost" 2>&1 >/dev/tty) || return
            remote_port=$(dialog --inputbox "Remote port:" 10 60 2>&1 >/dev/tty) || return
            description=$(dialog --inputbox "Description (optional):" 10 60 2>&1 >/dev/tty)

            if ! [[ "$local_port" =~ ^[0-9]+$ && "$local_port" -ge 1 && "$local_port" -le 65535 ]]; then
                dialog --title "Error" --msgbox "Invalid local port" 8 40
                return 1
            fi
            if ! [[ "$remote_port" =~ ^[0-9]+$ && "$remote_port" -ge 1 && "$remote_port" -le 65535 ]]; then
                dialog --title "Error" --msgbox "Invalid remote port" 8 40
                return 1
            fi
            ;;

        "R")
            remote_port=$(dialog --inputbox "Remote port:" 10 60 2>&1 >/dev/tty) || return
            local_host=$(dialog --inputbox "Local host (usually localhost):" 10 60 "localhost" 2>&1 >/dev/tty) || return
            local_port=$(dialog --inputbox "Local port:" 10 60 2>&1 >/dev/tty) || return
            description=$(dialog --inputbox "Description (optional):" 10 60 2>&1 >/dev/tty)
            remote_host="$local_host"  # For YAML structure consistency

            if ! [[ "$local_port" =~ ^[0-9]+$ && "$local_port" -ge 1 && "$local_port" -le 65535 ]]; then
                dialog --title "Error" --msgbox "Invalid local port" 8 40
                return 1
            fi
            if ! [[ "$remote_port" =~ ^[0-9]+$ && "$remote_port" -ge 1 && "$remote_port" -le 65535 ]]; then
                dialog --title "Error" --msgbox "Invalid remote port" 8 40
                return 1
            fi
            ;;

        "D")
            local_port=$(dialog --inputbox "SOCKS proxy local port:" 10 60 "1080" 2>&1 >/dev/tty) || return
            description=$(dialog --inputbox "Description (optional):" 10 60 2>&1 >/dev/tty)
            remote_host=""
            remote_port=""

            if ! [[ "$local_port" =~ ^[0-9]+$ && "$local_port" -ge 1 && "$local_port" -le 65535 ]]; then
                dialog --title "Error" --msgbox "Invalid local port" 8 40
                return 1
            fi
            ;;
    esac

    # Ask about auto-reconnect
    local autoreconnect="false"
    if check_autossh; then
        if dialog --title "Auto-Reconnect" --yesno \
            "Enable auto-reconnect (using autossh)?\n\nThis keeps the tunnel alive if connection drops." 10 60; then
            autoreconnect="true"
        fi
    fi

    # Build YAML entry
    backup_config

    # Initialize portforwards array if it doesn't exist
    if ! yq eval ".servers[$server_index].portforwards" "$CONFIG_FILE" &>/dev/null || \
       [[ "$(yq eval ".servers[$server_index].portforwards" "$CONFIG_FILE")" == "null" ]]; then
        yq eval ".servers[$server_index].portforwards = []" -i "$CONFIG_FILE"
    fi

    PF_NAME="$pf_name" TUNNEL_TYPE="$tunnel_type" LOCAL_PORT="$local_port" \
        yq eval ".servers[$server_index].portforwards += [{
            \"name\": strenv(PF_NAME),
            \"type\": strenv(TUNNEL_TYPE),
            \"local_port\": (strenv(LOCAL_PORT) | tonumber)
        }]" -i "$CONFIG_FILE"

    if [[ -n "$remote_host" ]]; then
        REMOTE_HOST="$remote_host" \
            yq eval "(.servers[$server_index].portforwards[-1].remote_host) = strenv(REMOTE_HOST)" -i "$CONFIG_FILE"
    fi
    if [[ -n "$remote_port" ]]; then
        REMOTE_PORT="$remote_port" \
            yq eval "(.servers[$server_index].portforwards[-1].remote_port) = (strenv(REMOTE_PORT) | tonumber)" -i "$CONFIG_FILE"
    fi
    if [[ -n "$description" ]]; then
        DESCRIPTION="$description" \
            yq eval "(.servers[$server_index].portforwards[-1].description) = strenv(DESCRIPTION)" -i "$CONFIG_FILE"
    fi
    if [[ "$autoreconnect" == "true" ]]; then
        yq eval "(.servers[$server_index].portforwards[-1].autoreconnect) = true" -i "$CONFIG_FILE"
    fi

    dialog --title "Success" --msgbox "Port forward profile '$pf_name' added successfully!" 8 50
    log_message "INFO" "Port forward profile added: $pf_name (type: $tunnel_type)"
}

# List port forward profiles
list_portforwards() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers configured" 8 50
        return 1
    fi

    local info_text="PORT FORWARD PROFILES\n\n"
    local found_any=false
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")

    for ((i=0; i<server_count; i++)); do
        local server_name
        server_name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")

        local pf_count
        pf_count=$(yq eval ".servers[$i].portforwards | length" "$CONFIG_FILE" 2>/dev/null)

        if [[ -n "$pf_count" && "$pf_count" != "null" && "$pf_count" -gt 0 ]]; then
            found_any=true
            info_text+="Server: $server_name\n"

            for ((j=0; j<pf_count; j++)); do
                local name type local_port remote_host remote_port desc autoreconnect
                name=$(yq eval ".servers[$i].portforwards[$j].name" "$CONFIG_FILE")
                type=$(yq eval ".servers[$i].portforwards[$j].type" "$CONFIG_FILE")
                local_port=$(yq eval ".servers[$i].portforwards[$j].local_port" "$CONFIG_FILE")
                remote_host=$(yq eval ".servers[$i].portforwards[$j].remote_host // \"\"" "$CONFIG_FILE")
                remote_port=$(yq eval ".servers[$i].portforwards[$j].remote_port // \"\"" "$CONFIG_FILE")
                desc=$(yq eval ".servers[$i].portforwards[$j].description // \"\"" "$CONFIG_FILE")
                autoreconnect=$(yq eval ".servers[$i].portforwards[$j].autoreconnect // false" "$CONFIG_FILE")

                info_text+="  [$((j+1))] $name ($type)\n"

                case "$type" in
                    "L") info_text+="      Local: $local_port → $remote_host:$remote_port\n" ;;
                    "R") info_text+="      Remote: $remote_port → $remote_host:$local_port\n" ;;
                    "D") info_text+="      SOCKS: localhost:$local_port\n" ;;
                esac

                [[ -n "$desc" && "$desc" != "null" ]] && info_text+="      Desc: $desc\n"
                [[ "$autoreconnect" == "true" ]] && info_text+="      Auto-reconnect: Yes\n"
            done
            info_text+="\n"
        fi
    done

    if [[ "$found_any" == "false" ]]; then
        dialog --title "Port Forwards" --msgbox "No port forward profiles configured" 8 50
    else
        dialog --title "Port Forward Profiles" --msgbox "$info_text" 25 80
    fi
}

# Start port forward
start_portforward() {
    init_portforward_dir

    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers configured" 8 50
        return 1
    fi

    # Build menu of available port forwards
    local menu_items=()
    local pf_map=()
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")

    for ((i=0; i<server_count; i++)); do
        local server_name
        server_name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")

        local pf_count
        pf_count=$(yq eval ".servers[$i].portforwards | length" "$CONFIG_FILE" 2>/dev/null)

        if [[ -n "$pf_count" && "$pf_count" != "null" && "$pf_count" -gt 0 ]]; then
            for ((j=0; j<pf_count; j++)); do
                local name type local_port remote_host remote_port
                name=$(yq eval ".servers[$i].portforwards[$j].name" "$CONFIG_FILE")
                type=$(yq eval ".servers[$i].portforwards[$j].type" "$CONFIG_FILE")
                local_port=$(yq eval ".servers[$i].portforwards[$j].local_port" "$CONFIG_FILE")
                remote_host=$(yq eval ".servers[$i].portforwards[$j].remote_host // \"\"" "$CONFIG_FILE")
                remote_port=$(yq eval ".servers[$i].portforwards[$j].remote_port // \"\"" "$CONFIG_FILE")

                local display_text="$name @ $server_name"
                case "$type" in
                    "L") display_text+=" (Local :$local_port → $remote_host:$remote_port)" ;;
                    "R") display_text+=" (Remote :$remote_port → $local_port)" ;;
                    "D") display_text+=" (SOCKS :$local_port)" ;;
                esac

                menu_items+=("$i:$j" "$display_text")
                pf_map+=("$i:$j")
            done
        fi
    done

    if [[ ${#menu_items[@]} -eq 0 ]]; then
        dialog --title "Error" --msgbox "No port forward profiles configured" 8 50
        return 1
    fi

    local choice
    choice=$(dialog --clear --title "Start Port Forward" --menu \
        "Select port forward to start:" \
        20 80 10 "${menu_items[@]}" 2>&1 >/dev/tty) || return

    # Parse choice
    local server_idx="${choice%:*}"
    local pf_idx="${choice#*:}"

    # Get server and port forward details
    local server_name
    server_name=$(yq eval ".servers[$server_idx].name" "$CONFIG_FILE")

    local pf_name pf_type pf_local_port pf_remote_host pf_remote_port autoreconnect
    pf_name=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].name" "$CONFIG_FILE")
    pf_type=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].type" "$CONFIG_FILE")
    pf_local_port=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].local_port" "$CONFIG_FILE")
    pf_remote_host=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].remote_host // \"\"" "$CONFIG_FILE")
    pf_remote_port=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].remote_port // \"\"" "$CONFIG_FILE")
    autoreconnect=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].autoreconnect // false" "$CONFIG_FILE")
    local ssh_cmd=()
    local error_log
    local tunnel_marker
    local start_time
    local tunnel_pid
    local port_pids
    local pidfile

    # Check if already running
    if grep -q "^${server_idx}:${pf_idx}:" "$PF_PIDS_FILE" 2>/dev/null; then
        local existing_pid
        existing_pid=$(grep "^${server_idx}:${pf_idx}:" "$PF_PIDS_FILE" | cut -d: -f3)
        if ps -p "$existing_pid" &>/dev/null; then
            dialog --title "Already Running" --msgbox "Port forward '$pf_name' is already active (PID: $existing_pid)" 8 60
            return 0
        else
            # Clean up stale entry
            grep -v "^${server_idx}:${pf_idx}:" "$PF_PIDS_FILE" | rewrite_pf_pids_file
        fi
    fi

    # Check if local port is already in use (for Local and Dynamic forwards)
    if [[ "$pf_type" == "L" || "$pf_type" == "D" ]]; then
        if is_port_in_use "$pf_local_port"; then
            print_message "$RED" "❌ Port $pf_local_port is already in use!"

            # Try to find what's using it
            port_pids=$(find_tunnel_pids_by_port "$pf_local_port")
            if [[ -n "$port_pids" ]]; then
                print_message "$YELLOW" "⚠️  Found SSH tunnel(s) using this port: $port_pids"
                print_message "$YELLOW" "   Use 'Port Forwarding → Stop tunnel' or run: kill $port_pids"
            else
                print_message "$YELLOW" "⚠️  Another process is using port $pf_local_port"
                if command -v lsof &>/dev/null; then
                    local proc_info
                    proc_info=$(lsof -ti :"$pf_local_port" 2>/dev/null | head -1)
                    if [[ -n "$proc_info" ]]; then
                        print_message "$YELLOW" "   Process PID: $proc_info"
                        ps -p "$proc_info" -o comm= 2>/dev/null | head -1
                    fi
                fi
            fi
            pause_for_enter
            return 1
        fi
    fi

    if ! resolve_server_connection "$server_idx"; then
        pause_for_enter
        return 1
    fi

    clear
    print_message "$BLUE" "🚀 Starting port forward: $pf_name"

    tunnel_marker="SSH_TUNNEL_${server_idx}_${pf_idx}_$$"
    ssh_cmd=(ssh -N -f)

    case "$pf_type" in
        "L") ssh_cmd+=(-L "${pf_local_port}:${pf_remote_host}:${pf_remote_port}") ;;
        "R") ssh_cmd+=(-R "${pf_remote_port}:${pf_remote_host}:${pf_local_port}") ;;
        "D") ssh_cmd+=(-D "${pf_local_port}") ;;
    esac

    append_resolved_connection_options ssh_cmd
    ssh_cmd+=(-o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes "$RESOLVED_SSH_TARGET")

    if [[ "$autoreconnect" == "true" ]] && check_autossh; then
        print_message "$BLUE" "🔄 Using autossh for auto-reconnect..."
        ssh_cmd[0]="autossh"
        ssh_cmd=("${ssh_cmd[@]:0:1}" -M 0 "${ssh_cmd[@]:1}")
    fi

    # Start the tunnel
    start_time=$(date +%s)
    error_log=$(mktemp "${TMPDIR:-/tmp}/ssh-manager-pf-error.XXXXXX")
    pidfile="/tmp/${tunnel_marker}.pid"
    tunnel_pid=""

    local command_status
    if [[ "$autoreconnect" == "true" ]] && check_autossh; then
        AUTOSSH_PIDFILE="$pidfile" "${ssh_cmd[@]}" 2>"$error_log"
    else
        "${ssh_cmd[@]}" 2>"$error_log"
    fi
    command_status=$?

    if [[ $command_status -eq 130 || "$INTERRUPTED" -eq 1 ]]; then
        print_message "$YELLOW" "⚠️  Tunnel start cancelled, returning to main menu"
        log_message "INFO" "Port forward start interrupted by user: $pf_name"
        rm -f "$error_log" "$pidfile"
    elif [[ $command_status -eq 0 ]]; then
        # Wait a bit for the tunnel to establish
        sleep 2

        # Method 1: Check autossh PID file
        if [[ "$autoreconnect" == "true" ]] && [[ -f "$pidfile" ]]; then
            tunnel_pid=$(cat "$pidfile" 2>/dev/null)
            rm -f "$pidfile"
        fi

        # Method 2: Find by port if Local or Dynamic
        if [[ -z "$tunnel_pid" && ("$pf_type" == "L" || "$pf_type" == "D") ]]; then
            port_pids=$(find_tunnel_pids_by_port "$pf_local_port")
            if [[ -n "$port_pids" ]]; then
                # Get the most recent PID
                for pid in $port_pids; do
                    local pid_start
                    pid_start=$(stat -c %Y "/proc/$pid" 2>/dev/null || echo 0)
                    if [[ $pid_start -ge $start_time ]]; then
                        tunnel_pid="$pid"
                        break
                    fi
                done
                # If no recent PID found, just use the first one
                [[ -z "$tunnel_pid" ]] && tunnel_pid=$(echo "$port_pids" | awk '{print $1}')
            fi
        fi

        # Method 3: Search by process command line
        if [[ -z "$tunnel_pid" ]]; then
            if [[ "$autoreconnect" == "true" ]] && check_autossh; then
                # Look for autossh process
                tunnel_pid=$(pgrep -f "autossh.*-p $port.*$user@$host" 2>/dev/null | head -1)
            else
                # Look for ssh process with our specific forward
                local search_pattern="ssh.*-N.*-p $port.*$user@$host"
                tunnel_pid=$(pgrep -f "$search_pattern" 2>/dev/null | head -1)
            fi
        fi

        # Verify PID is valid
        if [[ -n "$tunnel_pid" ]] && ps -p "$tunnel_pid" &>/dev/null; then
            printf '%s\n' "${server_idx}:${pf_idx}:${tunnel_pid}:${pf_name}" >> "$PF_PIDS_FILE"

            print_message "$GREEN" "✅ Port forward started successfully (PID: $tunnel_pid)"
            case "$pf_type" in
                "L") print_message "$GREEN" "   Access via: localhost:$pf_local_port" ;;
                "R") print_message "$GREEN" "   Exposed on remote: $host:$pf_remote_port" ;;
                "D") print_message "$GREEN" "   SOCKS proxy: localhost:$pf_local_port" ;;
            esac
            log_message "INFO" "Port forward started: $pf_name (PID: $tunnel_pid)"
        else
            print_message "$YELLOW" "⚠️  Tunnel may have started, but couldn't find PID automatically"

            # Try to verify the tunnel is working
            if [[ "$pf_type" == "L" || "$pf_type" == "D" ]]; then
                if is_port_in_use "$pf_local_port"; then
                    print_message "$GREEN" "   ✓ Port $pf_local_port is listening (tunnel likely active)"

                    # Try to find PID one more time
                    local found_pids
                    found_pids=$(find_tunnel_pids_by_port "$pf_local_port")
                    if [[ -n "$found_pids" ]]; then
                        tunnel_pid=$(echo "$found_pids" | awk '{print $1}')
                        echo "${server_idx}:${pf_idx}:${tunnel_pid}:${pf_name}" >> "$PF_PIDS_FILE"
                        print_message "$GREEN" "   Found PID: $tunnel_pid (saved for tracking)"
                        log_message "INFO" "Port forward started: $pf_name (PID: $tunnel_pid) - found via port"
                    fi
                else
                    print_message "$RED" "   ✗ Port $pf_local_port not listening (tunnel may have failed)"
                fi
            fi
        fi

        rm -f "$error_log"
    else
        local error_msg
        error_msg=$(cat "$error_log" 2>/dev/null || echo 'Unknown error')
        print_message "$RED" "❌ Failed to start port forward"
        print_message "$RED" "   Error: $error_msg"

        # Common error hints
        if echo "$error_msg" | grep -qi "permission denied\|password"; then
            print_message "$YELLOW" "\n💡 Hint: Try copying your SSH key to the server:"
            if [[ "$RESOLVED_HAS_ALIAS" -eq 1 ]]; then
                print_message "$YELLOW" "   ssh-copy-id $RESOLVED_SSH_TARGET"
            else
                print_message "$YELLOW" "   ssh-copy-id -p $RESOLVED_PORT $RESOLVED_SSH_TARGET"
            fi
        elif echo "$error_msg" | grep -qi "address already in use"; then
            print_message "$YELLOW" "\n💡 Hint: Port $pf_local_port is already in use"
        elif echo "$error_msg" | grep -qi "connection refused\|no route"; then
            print_message "$YELLOW" "\n💡 Hint: Check if SSH server is accessible"
            if [[ "$RESOLVED_HAS_ALIAS" -eq 1 ]]; then
                print_message "$YELLOW" "   ssh $RESOLVED_SSH_TARGET"
            else
                print_message "$YELLOW" "   ssh -p $RESOLVED_PORT $RESOLVED_SSH_TARGET"
            fi
        fi

        log_message "ERROR" "Port forward failed: $pf_name - $error_msg"
        rm -f "$error_log" "$pidfile"
    fi

    if [[ $command_status -eq 0 ]]; then
        record_server_usage "$server_idx" "portforward:$pf_name"
    fi

    pause_for_enter
}

# Find all SSH tunnel processes
find_all_ssh_tunnels() {
    local tunnel_info=()

    # Find all SSH/autossh processes running with -N flag (no command execution = tunnel)
    local ssh_pids=$(pgrep -f "ssh.*-N" 2>/dev/null)
    local autossh_pids=$(pgrep -f "autossh" 2>/dev/null)

    # Combine and deduplicate
    local all_pids=$(echo "$ssh_pids $autossh_pids" | tr ' ' '\n' | sort -u)

    for pid in $all_pids; do
        if ps -p "$pid" &>/dev/null; then
            local cmdline=$(ps -p "$pid" -o args= 2>/dev/null)
            # Check if it's actually a tunnel (has -L, -R, or -D)
            if echo "$cmdline" | grep -qE -- '-[LRD]'; then
                # Try to extract port information using sed instead of grep -P
                local port=$(echo "$cmdline" | sed -n 's/.*-[LRD][[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
                tunnel_info+=("$pid:$port:$cmdline")
            fi
        fi
    done

    printf '%s\n' "${tunnel_info[@]}"
}

# Stop port forward (improved with orphan detection)
stop_portforward() {
    init_portforward_dir

    # Build menu of active tunnels from tracking file
    local menu_items=()
    if [[ -s "$PF_PIDS_FILE" ]]; then
        local cleaned_entries=()
        while IFS=: read -r server_idx pf_idx pid name; do
            if ps -p "$pid" &>/dev/null; then
                local server_name
                server_name=$(yq eval ".servers[$server_idx].name" "$CONFIG_FILE" 2>/dev/null || echo "Unknown")
                menu_items+=("$server_idx:$pf_idx:$pid" "$name @ $server_name (PID: $pid)")
                cleaned_entries+=("${server_idx}:${pf_idx}:${pid}:${name}")
            else
                :
            fi
        done < "$PF_PIDS_FILE"
        printf '%s\n' "${cleaned_entries[@]}" | rewrite_pf_pids_file
    fi

    # Find orphaned SSH tunnels (running but not tracked)
    local orphan_count=0
    while IFS=: read -r pid port cmdline; do
        # Check if this PID is already in our tracking file
        if ! grep -q ":$pid:" "$PF_PIDS_FILE" 2>/dev/null; then
            ((orphan_count++))
            menu_items+=("ORPHAN:$pid" "⚠️  Untracked tunnel (PID: $pid, Port: ${port:-?})")
        fi
    done < <(find_all_ssh_tunnels)

    if [[ ${#menu_items[@]} -eq 0 ]]; then
        dialog --title "No Active Tunnels" --msgbox "No port forwards are currently running" 8 50
        return 0
    fi

    # Add options
    menu_items+=("ALL" "🛑 Stop all tunnels (tracked + orphaned)")
    if [[ $orphan_count -gt 0 ]]; then
        menu_items+=("ORPHANS" "🧹 Stop all orphaned tunnels only")
    fi

    local choice
    choice=$(dialog --clear --title "Stop Port Forward" --menu \
        "Select tunnel to stop:\n(${orphan_count} orphaned tunnel(s) found)" \
        22 80 12 "${menu_items[@]}" 2>&1 >/dev/tty) || return

    if should_return_to_main_menu; then
        clear
        return
    fi

    clear

    case "$choice" in
        "ALL")
            print_message "$BLUE" "🛑 Stopping all port forwards..."

            # Stop tracked tunnels
            if [[ -s "$PF_PIDS_FILE" ]]; then
                while IFS=: read -r server_idx pf_idx pid name; do
                    if ps -p "$pid" &>/dev/null; then
                        kill "$pid" 2>/dev/null
                        print_message "$GREEN" "  ✅ Stopped: $name (PID: $pid)"
                        log_message "INFO" "Port forward stopped: $name (PID: $pid)"
                    fi
                done < "$PF_PIDS_FILE"
                : > "$PF_PIDS_FILE"
            fi

            # Stop orphaned tunnels
            while IFS=: read -r pid port cmdline; do
                if ! grep -q ":$pid:" "$PF_PIDS_FILE" 2>/dev/null && ps -p "$pid" &>/dev/null; then
                    kill "$pid" 2>/dev/null
                    print_message "$GREEN" "  ✅ Stopped orphaned tunnel (PID: $pid)"
                fi
            done < <(find_all_ssh_tunnels)

            print_message "$GREEN" "\n✅ All port forwards stopped"
            ;;

        "ORPHANS")
            print_message "$BLUE" "🧹 Stopping orphaned tunnels..."
            local stopped=0
            while IFS=: read -r pid port cmdline; do
                if ps -p "$pid" &>/dev/null; then
                    kill "$pid" 2>/dev/null && ((stopped++))
                    print_message "$GREEN" "  ✅ Stopped orphaned tunnel (PID: $pid, Port: ${port:-?})"
                fi
            done < <(find_all_ssh_tunnels | while IFS=: read -r pid port cmdline; do
                if ! grep -q ":$pid:" "$PF_PIDS_FILE" 2>/dev/null; then
                    echo "$pid:$port:$cmdline"
                fi
            done)
            print_message "$GREEN" "\n✅ Stopped $stopped orphaned tunnel(s)"
            ;;

        ORPHAN:*)
            # Stop specific orphaned tunnel
            local pid="${choice#ORPHAN:}"
            if ps -p "$pid" &>/dev/null; then
                kill "$pid" 2>/dev/null
                print_message "$GREEN" "✅ Stopped orphaned tunnel (PID: $pid)"
                log_message "INFO" "Orphaned tunnel stopped (PID: $pid)"
            else
                print_message "$RED" "❌ Process not found (PID: $pid)"
            fi
            ;;

        *)
            # Stop specific tracked tunnel
            local server_idx="${choice%%:*}"
            local rest="${choice#*:}"
            local pf_idx="${rest%%:*}"
            local pid="${rest#*:}"

            if ps -p "$pid" &>/dev/null; then
                kill "$pid" 2>/dev/null
                grep -v "^${server_idx}:${pf_idx}:${pid}:" "$PF_PIDS_FILE" | rewrite_pf_pids_file

                local pf_name
                pf_name=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].name" "$CONFIG_FILE" 2>/dev/null || echo "Unknown")

                print_message "$GREEN" "✅ Port forward stopped: $pf_name (PID: $pid)"
                log_message "INFO" "Port forward stopped: $pf_name (PID: $pid)"
            else
                print_message "$RED" "❌ Process not found (PID: $pid)"
                grep -v "^${server_idx}:${pf_idx}:${pid}:" "$PF_PIDS_FILE" | rewrite_pf_pids_file
            fi
            ;;
    esac

    pause_for_enter
}

# Show active tunnels status
show_active_tunnels() {
    init_portforward_dir

    if [[ ! -s "$PF_PIDS_FILE" ]]; then
        dialog --title "Active Tunnels" --msgbox "No port forwards are currently running" 8 50
        return 0
    fi

    local status_text="ACTIVE PORT FORWARDS\n\n"
    local found_active=false

    # Temporary file for cleaned PID list
    local temp_pids=$(mktemp)

    while IFS=: read -r server_idx pf_idx pid name; do
        if ps -p "$pid" &>/dev/null; then
            found_active=true

            local server_name host
            server_name=$(yq eval ".servers[$server_idx].name" "$CONFIG_FILE" 2>/dev/null || echo "Unknown")
            host=$(yq eval ".servers[$server_idx].host" "$CONFIG_FILE" 2>/dev/null || echo "unknown")

            local pf_type local_port remote_host remote_port
            pf_type=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].type" "$CONFIG_FILE" 2>/dev/null)
            local_port=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].local_port" "$CONFIG_FILE" 2>/dev/null)
            remote_host=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].remote_host // \"\"" "$CONFIG_FILE" 2>/dev/null)
            remote_port=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].remote_port // \"\"" "$CONFIG_FILE" 2>/dev/null)

            status_text+="[$pid] $name @ $server_name ($host)\n"
            status_text+="  Type: $pf_type | "

            case "$pf_type" in
                "L") status_text+="localhost:$local_port → $remote_host:$remote_port" ;;
                "R") status_text+="remote:$remote_port → localhost:$local_port" ;;
                "D") status_text+="SOCKS proxy on localhost:$local_port" ;;
            esac

            status_text+="\n  Status: Running\n\n"

            # Keep this PID in cleaned list
            echo "${server_idx}:${pf_idx}:${pid}:${name}" >> "$temp_pids"
        fi
    done < "$PF_PIDS_FILE"

    # Update PID file with only active tunnels
    mv "$temp_pids" "$PF_PIDS_FILE"

    if [[ "$found_active" == "false" ]]; then
        dialog --title "Active Tunnels" --msgbox "No port forwards are currently running" 8 50
    else
        dialog --title "Active Port Forwards" --msgbox "$status_text" 25 80
    fi
}

# Remove port forward profile
remove_portforward() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers configured" 8 50
        return 1
    fi

    # Build menu of available port forwards
    local menu_items=()
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")

    for ((i=0; i<server_count; i++)); do
        local server_name
        server_name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")

        local pf_count
        pf_count=$(yq eval ".servers[$i].portforwards | length" "$CONFIG_FILE" 2>/dev/null)

        if [[ -n "$pf_count" && "$pf_count" != "null" && "$pf_count" -gt 0 ]]; then
            for ((j=0; j<pf_count; j++)); do
                local name type
                name=$(yq eval ".servers[$i].portforwards[$j].name" "$CONFIG_FILE")
                type=$(yq eval ".servers[$i].portforwards[$j].type" "$CONFIG_FILE")

                menu_items+=("$i:$j" "$name @ $server_name (Type: $type)")
            done
        fi
    done

    if [[ ${#menu_items[@]} -eq 0 ]]; then
        dialog --title "Error" --msgbox "No port forward profiles configured" 8 50
        return 1
    fi

    local choice
    choice=$(dialog --clear --title "Remove Port Forward" --menu \
        "Select port forward profile to remove:" \
        20 70 10 "${menu_items[@]}" 2>&1 >/dev/tty) || return

    if should_return_to_main_menu; then
        clear
        return
    fi

    # Parse choice
    local server_idx="${choice%:*}"
    local pf_idx="${choice#*:}"

    local pf_name
    pf_name=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].name" "$CONFIG_FILE")

    dialog --clear --title "Confirm Removal" --yesno \
        "Are you sure you want to remove port forward profile:\n\n$pf_name" \
        10 60 || return

    backup_config
    yq eval "del(.servers[$server_idx].portforwards[$pf_idx])" -i "$CONFIG_FILE"

    dialog --title "Success" --msgbox "Port forward profile removed successfully!" 8 50
    log_message "INFO" "Port forward profile removed: $pf_name"
}

# Port forwarding submenu
portforward_menu() {
    while true; do
        local choice
        choice=$(dialog --clear --title "Port Forwarding" --menu \
            "Manage SSH tunnels:" \
            20 70 10 \
            "1" "▶️  Start tunnel" \
            "2" "⏹️  Stop tunnel" \
            "3" "📊 Show active tunnels" \
            "4" "➕ Add port forward profile" \
            "5" "📋 List all profiles" \
            "6" "🗑️  Remove profile" \
            "0" "← Back to main menu" 2>&1 >/dev/tty)

        if should_return_to_main_menu; then
            clear
            return
        fi

        case "$choice" in
            "") clear; return ;;
            "1")
                start_portforward
                if [[ "$INTERRUPTED" -eq 1 ]]; then
                    clear_interrupt_state
                    clear_main_menu_request
                    continue
                fi
                ;;
            "2")
                stop_portforward
                if [[ "$INTERRUPTED" -eq 1 ]]; then
                    clear_interrupt_state
                    clear_main_menu_request
                    continue
                fi
                ;;
            "3") show_active_tunnels ;;
            "4") add_portforward ;;
            "5") list_portforwards ;;
            "6") remove_portforward ;;
            "0") clear; return ;;
        esac
    done
}

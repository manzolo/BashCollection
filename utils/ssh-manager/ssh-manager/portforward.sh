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

    local server_index
    server_index=$(get_server_index_by_name "$server_choice")
    [[ $? -ne 0 ]] && return 1

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
    if yq eval ".servers[$server_index].portforwards[]? | select(.name == \"$pf_name\") | .name" "$CONFIG_FILE" 2>/dev/null | grep -q "$pf_name"; then
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

    # Add the port forward entry
    local yaml_entry="{\"name\": \"$pf_name\", \"type\": \"$tunnel_type\", \"local_port\": $local_port"

    [[ -n "$remote_host" ]] && yaml_entry+=", \"remote_host\": \"$remote_host\""
    [[ -n "$remote_port" ]] && yaml_entry+=", \"remote_port\": $remote_port"
    [[ -n "$description" ]] && yaml_entry+=", \"description\": \"$description\""
    [[ "$autoreconnect" == "true" ]] && yaml_entry+=", \"autoreconnect\": true"

    yaml_entry+="}"

    yq eval ".servers[$server_index].portforwards += [$yaml_entry]" -i "$CONFIG_FILE"

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
    local server_name host user port ssh_options
    server_name=$(yq eval ".servers[$server_idx].name" "$CONFIG_FILE")
    host=$(yq eval ".servers[$server_idx].host" "$CONFIG_FILE")
    user=$(yq eval ".servers[$server_idx].user" "$CONFIG_FILE")
    port=$(yq eval ".servers[$server_idx].port // 22" "$CONFIG_FILE")
    ssh_options=$(yq eval ".servers[$server_idx].ssh_options // \"\"" "$CONFIG_FILE")

    local pf_name pf_type pf_local_port pf_remote_host pf_remote_port autoreconnect
    pf_name=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].name" "$CONFIG_FILE")
    pf_type=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].type" "$CONFIG_FILE")
    pf_local_port=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].local_port" "$CONFIG_FILE")
    pf_remote_host=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].remote_host // \"\"" "$CONFIG_FILE")
    pf_remote_port=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].remote_port // \"\"" "$CONFIG_FILE")
    autoreconnect=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].autoreconnect // false" "$CONFIG_FILE")

    # Check if already running
    if grep -q "^${server_idx}:${pf_idx}:" "$PF_PIDS_FILE" 2>/dev/null; then
        local existing_pid
        existing_pid=$(grep "^${server_idx}:${pf_idx}:" "$PF_PIDS_FILE" | cut -d: -f3)
        if ps -p "$existing_pid" &>/dev/null; then
            dialog --title "Already Running" --msgbox "Port forward '$pf_name' is already active (PID: $existing_pid)" 8 60
            return 0
        else
            # Clean up stale entry
            sed -i "/^${server_idx}:${pf_idx}:/d" "$PF_PIDS_FILE"
        fi
    fi

    # Check if local port is already in use (for Local and Dynamic forwards)
    if [[ "$pf_type" == "L" || "$pf_type" == "D" ]]; then
        if is_port_in_use "$pf_local_port"; then
            print_message "$RED" "❌ Port $pf_local_port is already in use!"

            # Try to find what's using it
            local port_pids=$(find_tunnel_pids_by_port "$pf_local_port")
            if [[ -n "$port_pids" ]]; then
                print_message "$YELLOW" "⚠️  Found SSH tunnel(s) using this port: $port_pids"
                print_message "$YELLOW" "   Use 'Port Forwarding → Stop tunnel' or run: kill $port_pids"
            else
                print_message "$YELLOW" "⚠️  Another process is using port $pf_local_port"
                if command -v lsof &>/dev/null; then
                    local proc_info=$(lsof -ti :$pf_local_port 2>/dev/null | head -1)
                    if [[ -n "$proc_info" ]]; then
                        print_message "$YELLOW" "   Process PID: $proc_info"
                        ps -p "$proc_info" -o comm= 2>/dev/null | head -1
                    fi
                fi
            fi
            print_message "$YELLOW" "\nPress ENTER to continue..."
            read -r
            return 1
        fi
    fi

    # Build SSH command
    local ssh_cmd=""
    local forward_arg=""

    case "$pf_type" in
        "L") forward_arg="-L ${pf_local_port}:${pf_remote_host}:${pf_remote_port}" ;;
        "R") forward_arg="-R ${pf_remote_port}:${pf_remote_host}:${pf_local_port}" ;;
        "D") forward_arg="-D ${pf_local_port}" ;;
    esac

    local base_ssh_cmd="ssh -N -f $forward_arg -p $port"
    [[ -n "$ssh_options" && "$ssh_options" != "null" ]] && base_ssh_cmd+=" $ssh_options"
    base_ssh_cmd+=" -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes"
    base_ssh_cmd+=" $user@$host"

    clear
    print_message "$BLUE" "🚀 Starting port forward: $pf_name"

    # Create a unique marker for this tunnel
    local tunnel_marker="SSH_TUNNEL_${server_idx}_${pf_idx}_$$"

    if [[ "$autoreconnect" == "true" ]] && check_autossh; then
        print_message "$BLUE" "🔄 Using autossh for auto-reconnect..."
        # Use autossh without -f, start in background manually
        ssh_cmd="AUTOSSH_PIDFILE=/tmp/${tunnel_marker}.pid autossh -M 0 -f $forward_arg -p $port"
        [[ -n "$ssh_options" && "$ssh_options" != "null" ]] && ssh_cmd+=" $ssh_options"
        ssh_cmd+=" -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes"
        ssh_cmd+=" $user@$host -N"
    else
        # Standard SSH with -f (fork to background)
        ssh_cmd="$base_ssh_cmd"
    fi

    # Start the tunnel
    local start_time=$(date +%s)
    if eval "$ssh_cmd" 2>pf_error.log; then
        # Wait a bit for the tunnel to establish
        sleep 2

        # Find the PID using multiple methods
        local tunnel_pid=""

        # Method 1: Check autossh PID file
        if [[ "$autoreconnect" == "true" ]] && [[ -f "/tmp/${tunnel_marker}.pid" ]]; then
            tunnel_pid=$(cat "/tmp/${tunnel_marker}.pid" 2>/dev/null)
            rm -f "/tmp/${tunnel_marker}.pid"  # Clean up PID file
        fi

        # Method 2: Find by port if Local or Dynamic
        if [[ -z "$tunnel_pid" && ("$pf_type" == "L" || "$pf_type" == "D") ]]; then
            local port_pids=$(find_tunnel_pids_by_port "$pf_local_port")
            if [[ -n "$port_pids" ]]; then
                # Get the most recent PID
                for pid in $port_pids; do
                    local pid_start=$(stat -c %Y /proc/$pid 2>/dev/null || echo 0)
                    if [[ $pid_start -ge $start_time ]]; then
                        tunnel_pid="$pid"
                        break
                    fi
                done
                # If no recent PID found, just use the first one
                [[ -z "$tunnel_pid" ]] && tunnel_pid=$(echo $port_pids | awk '{print $1}')
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
            echo "${server_idx}:${pf_idx}:${tunnel_pid}:${pf_name}" >> "$PF_PIDS_FILE"

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
                    local found_pids=$(find_tunnel_pids_by_port "$pf_local_port")
                    if [[ -n "$found_pids" ]]; then
                        tunnel_pid=$(echo $found_pids | awk '{print $1}')
                        echo "${server_idx}:${pf_idx}:${tunnel_pid}:${pf_name}" >> "$PF_PIDS_FILE"
                        print_message "$GREEN" "   Found PID: $tunnel_pid (saved for tracking)"
                        log_message "INFO" "Port forward started: $pf_name (PID: $tunnel_pid) - found via port"
                    fi
                else
                    print_message "$RED" "   ✗ Port $pf_local_port not listening (tunnel may have failed)"
                fi
            fi
        fi

        rm -f pf_error.log
    else
        local error_msg=$(cat pf_error.log 2>/dev/null || echo 'Unknown error')
        print_message "$RED" "❌ Failed to start port forward"
        print_message "$RED" "   Error: $error_msg"

        # Common error hints
        if echo "$error_msg" | grep -qi "permission denied\|password"; then
            print_message "$YELLOW" "\n💡 Hint: Try copying your SSH key to the server:"
            print_message "$YELLOW" "   ssh-copy-id -p $port $user@$host"
        elif echo "$error_msg" | grep -qi "address already in use"; then
            print_message "$YELLOW" "\n💡 Hint: Port $pf_local_port is already in use"
        elif echo "$error_msg" | grep -qi "connection refused\|no route"; then
            print_message "$YELLOW" "\n💡 Hint: Check if SSH server is accessible"
            print_message "$YELLOW" "   ssh -p $port $user@$host"
        fi

        log_message "ERROR" "Port forward failed: $pf_name - $error_msg"
        rm -f pf_error.log
    fi

    print_message "$YELLOW" "\nPress ENTER to continue..."
    read -r
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
    local has_tracked=false

    if [[ -s "$PF_PIDS_FILE" ]]; then
        while IFS=: read -r server_idx pf_idx pid name; do
            if ps -p "$pid" &>/dev/null; then
                has_tracked=true
                local server_name
                server_name=$(yq eval ".servers[$server_idx].name" "$CONFIG_FILE" 2>/dev/null || echo "Unknown")
                menu_items+=("$server_idx:$pf_idx:$pid" "$name @ $server_name (PID: $pid)")
            else
                # Clean up stale entry
                sed -i "/^${server_idx}:${pf_idx}:${pid}:/d" "$PF_PIDS_FILE"
            fi
        done < "$PF_PIDS_FILE"
    fi

    # Find orphaned SSH tunnels (running but not tracked)
    local orphan_count=0
    while IFS=: read -r pid port cmdline; do
        # Check if this PID is already in our tracking file
        if ! grep -q ":$pid:" "$PF_PIDS_FILE" 2>/dev/null; then
            ((orphan_count++))
            local short_cmd=$(echo "$cmdline" | sed 's/.*ssh/ssh/' | cut -c1-50)
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
                > "$PF_PIDS_FILE"
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
                sed -i "/^${server_idx}:${pf_idx}:${pid}:/d" "$PF_PIDS_FILE"

                local pf_name
                pf_name=$(yq eval ".servers[$server_idx].portforwards[$pf_idx].name" "$CONFIG_FILE" 2>/dev/null || echo "Unknown")

                print_message "$GREEN" "✅ Port forward stopped: $pf_name (PID: $pid)"
                log_message "INFO" "Port forward stopped: $pf_name (PID: $pid)"
            else
                print_message "$RED" "❌ Process not found (PID: $pid)"
                sed -i "/^${server_idx}:${pf_idx}:${pid}:/d" "$PF_PIDS_FILE"
            fi
            ;;
    esac

    print_message "$YELLOW" "\nPress ENTER to continue..."
    read -r
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

        case "$choice" in
            "") clear; return ;;
            "1") start_portforward ;;
            "2") stop_portforward ;;
            "3") show_active_tunnels ;;
            "4") add_portforward ;;
            "5") list_portforwards ;;
            "6") remove_portforward ;;
            "0") clear; return ;;
        esac
    done
}

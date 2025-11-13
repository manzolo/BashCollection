#!/bin/bash
# Configuration management for SSH Manager
# Provides: configuration init, backup, validation

# Configuration initialization
init_config() {
    mkdir -p "$CONFIG_DIR"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << EOF
servers:
  - name: "Example Server"
    host: "example.com"
    user: "root"
    port: 22
    description: "Example server"
EOF
        print_message "$GREEN" "✅ Configuration file created: $CONFIG_FILE"
        log_message "INFO" "Initial configuration file created"
    fi
}

# Backup configuration
backup_config() {
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup-$(date +%Y%m%d%H%M%S)"
    log_message "INFO" "Configuration backed up"
}

# Validate YAML configuration
validate_config() {
    if ! yq eval '.servers' "$CONFIG_FILE" &> /dev/null; then
        print_message "$RED" "❌ Invalid YAML in configuration file"
        return 1
    fi

    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")

    if [[ "$server_count" == "0" || "$server_count" == "null" ]]; then
        print_message "$YELLOW" "⚠️ No servers configured"
        return 1
    fi

    for ((i=0; i<server_count; i++)); do
        local name host user port
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        port=$(yq eval ".servers[$i].port // 22" "$CONFIG_FILE")

        [[ -z "$name" || "$name" == "null" ]] && { print_message "$RED" "❌ Server $i: Missing name"; return 1; }
        [[ -z "$host" || "$host" == "null" ]] && { print_message "$RED" "❌ Server $i: Missing host"; return 1; }
        [[ -z "$user" || "$user" == "null" ]] && { print_message "$RED" "❌ Server $i: Missing user"; return 1; }
        if [[ "$port" != "null" && ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
            print_message "$RED" "❌ Server $i: Invalid port '$port'"
            return 1
        fi
    done

    return 0
}

# Check for duplicate server
check_duplicate_server() {
    local host="$1"
    local user="$2"
    local exclude_name="$3"  # Nome da escludere durante l'edit
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")

    for ((i=0; i<server_count; i++)); do
        local existing_host existing_user existing_name
        existing_host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        existing_user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        existing_name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")

        # Skip se è il server che stiamo modificando
        if [[ -n "$exclude_name" && "$existing_name" == "$exclude_name" ]]; then
            continue
        fi

        if [[ "$existing_host" == "$host" && "$existing_user" == "$user" ]]; then
            dialog --title "Error" --msgbox "Server with host '$host' and user '$user' already exists!" 8 50
            return 1
        fi
    done
    return 0
}

# Check for duplicate server name
check_duplicate_name() {
    local name="$1"
    local exclude_name="$2"  # Nome da escludere durante l'edit
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")

    for ((i=0; i<server_count; i++)); do
        local existing_name
        existing_name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")

        # Skip se è il server che stiamo modificando
        if [[ -n "$exclude_name" && "$existing_name" == "$exclude_name" ]]; then
            continue
        fi

        if [[ "$existing_name" == "$name" ]]; then
            dialog --title "Error" --msgbox "Server name '$name' already exists!" 8 50
            return 1
        fi
    done
    return 0
}

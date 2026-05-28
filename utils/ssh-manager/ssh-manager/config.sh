#!/bin/bash
# Configuration management for SSH Manager
# Provides: configuration init, backup, validation

migrate_config_to_json() {
    local yaml_file="${CONFIG_FILE%.json}.yaml"
    [[ ! -f "$yaml_file" ]] && return 0
    [[ -f "$CONFIG_FILE" ]] && return 0

    print_message "$BLUE" "🔄 Migrating config from YAML to JSON..."
    if command -v yq &>/dev/null; then
        yq -o=json "$yaml_file" > "$CONFIG_FILE" && rm -f "$yaml_file" && \
            print_message "$GREEN" "✅ Config migrated to JSON" && return 0
    fi
    if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
        python3 -c "
import yaml, json
with open('$yaml_file') as f:
    data = yaml.safe_load(f)
with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" && rm -f "$yaml_file" && print_message "$GREEN" "✅ Config migrated to JSON" && return 0
    fi
    print_message "$RED" "❌ Cannot migrate config: install yq or python3-yaml"
    return 1
}

# Configuration initialization
init_config() {
    ensure_manager_runtime_dirs
    migrate_config_to_json

    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
  "servers": [
    {
      "name": "Example Server",
      "host": "example.com",
      "user": "root",
      "port": 22,
      "description": "Example server"
    }
  ]
}
EOF
        chmod 600 "$CONFIG_FILE" 2>/dev/null
        print_message "$GREEN" "✅ Configuration file created: $CONFIG_FILE"
        log_message "INFO" "Initial configuration file created"
    fi
}

# Backup configuration
backup_config() {
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup-$(date +%Y%m%d%H%M%S)"
    log_message "INFO" "Configuration backed up"
}

# Validate JSON configuration
validate_config() {
    if ! jq '.servers' "$CONFIG_FILE" &> /dev/null; then
        print_message "$RED" "❌ Invalid JSON in configuration file"
        return 1
    fi

    local server_count
    server_count=$(jq '.servers | length' "$CONFIG_FILE")

    if [[ "$server_count" == "0" || "$server_count" == "null" ]]; then
        print_message "$YELLOW" "⚠️ No servers configured"
        return 1
    fi

    for ((i=0; i<server_count; i++)); do
        local fields name host user port
        readarray -t fields < <(jq -r --argjson i "$i" \
            '.servers[$i] | (.name // "null"), (.host // "null"), (.user // "null"), (.port // 22 | tostring)' \
            "$CONFIG_FILE")
        name="${fields[0]}"
        host="${fields[1]}"
        user="${fields[2]}"
        port="${fields[3]}"

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
    local exclude_name="$3"

    local count
    count=$(jq -r --arg host "$host" --arg user "$user" --arg exclude "$exclude_name" '
        [.servers[] | select(.host == $host and .user == $user and .name != $exclude)] | length
    ' "$CONFIG_FILE")

    if [[ "$count" -gt 0 ]]; then
        dialog --title "Error" --msgbox "Server with host '$host' and user '$user' already exists!" 8 50
        return 1
    fi
    return 0
}

# Check for duplicate server name
check_duplicate_name() {
    local name="$1"
    local exclude_name="$2"

    local count
    count=$(jq -r --arg name "$name" --arg exclude "$exclude_name" '
        [.servers[] | select(.name == $name and .name != $exclude)] | length
    ' "$CONFIG_FILE")

    if [[ "$count" -gt 0 ]]; then
        dialog --title "Error" --msgbox "Server name '$name' already exists!" 8 50
        return 1
    fi
    return 0
}

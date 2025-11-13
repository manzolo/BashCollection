#!/bin/bash
# Server management for SSH Manager
# Provides: add, edit, remove, show server info

# Add new server
add_server() {
    local name host user port description

    name=$(dialog --inputbox "Server name:" 10 60 2>&1 >/dev/tty) || return
    [[ -z "$name" ]] && return

    # Check for duplicate name
    if ! check_duplicate_name "$name"; then
        return 1
    fi

    host=$(dialog --inputbox "Server address (host/IP):" 10 60 2>&1 >/dev/tty) || return
    [[ -z "$host" ]] && return

    user=$(dialog --inputbox "Username:" 10 60 "root" 2>&1 >/dev/tty) || return
    [[ -z "$user" ]] && return

    port=$(dialog --inputbox "SSH port:" 10 60 "22" 2>&1 >/dev/tty) || return
    [[ -z "$port" ]] && port="22"

    description=$(dialog --inputbox "Description (optional):" 10 60 2>&1 >/dev/tty)

    ssh_options=$(dialog --inputbox "Custom SSH options (optional, e.g., -o ProxyCommand='...'):" 10 60 2>&1 >/dev/tty)

    if ! [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]; then
        dialog --title "Error" --msgbox "Port must be a number between 1 and 65535" 8 50
        return 1
    fi

    if ! check_duplicate_server "$host" "$user"; then
        return 1
    fi

    backup_config
    local new_server_yaml
    new_server_yaml=$(cat << EOF
  - name: "$name"
    host: "$host"
    user: "$user"
    port: $port
EOF
)

    if [[ -n "$description" && "$description" != "null" ]]; then
        new_server_yaml+="\n    description: \"$description\""
    fi
    if [[ -n "$ssh_options" && "$ssh_options" != "null" ]]; then
        new_server_yaml+="\n    ssh_options: \"$ssh_options\""
    fi

    echo -e "$new_server_yaml" >> "$CONFIG_FILE"

    dialog --title "Success" --msgbox "Server '$name' added successfully!" 8 50
    log_message "INFO" "New server added: $name ($user@$host:$port)"
}

# Edit existing server
edit_server() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers to edit" 8 50
        return
    fi

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

    local choice
    choice=$(dialog --clear --title "Edit Server" --menu \
        "Select server to edit:" \
        15 60 8 "${menu_items[@]}" 2>&1 >/dev/tty) || return

    local server_index
    server_index=$(get_server_index_by_name "$choice")
    if [[ $? -ne 0 ]]; then
        dialog --title "Error" --msgbox "Server not found!" 8 50
        return 1
    fi

    local name host user port description ssh_options
    name=$(yq eval ".servers[$server_index].name" "$CONFIG_FILE")
    host=$(yq eval ".servers[$server_index].host" "$CONFIG_FILE")
    user=$(yq eval ".servers[$server_index].user" "$CONFIG_FILE")
    port=$(yq eval ".servers[$server_index].port // 22" "$CONFIG_FILE")
    description=$(yq eval ".servers[$server_index].description // \"\"" "$CONFIG_FILE")
    ssh_options=$(yq eval ".servers[$server_index].ssh_options // \"\"" "$CONFIG_FILE")
    [[ "$description" == "null" ]] && description=""
    [[ "$ssh_options" == "null" ]] && ssh_options=""

    local new_name new_host new_user new_port new_description new_ssh_options
    new_name=$(dialog --inputbox "Server name:" 10 60 "$name" 2>&1 >/dev/tty) || return

    # Check for duplicate name only if changed
    if [[ "$new_name" != "$name" ]]; then
        if ! check_duplicate_name "$new_name" "$name"; then
            return 1
        fi
    fi

    new_host=$(dialog --inputbox "Server address:" 10 60 "$host" 2>&1 >/dev/tty) || return
    new_user=$(dialog --inputbox "Username:" 10 60 "$user" 2>&1 >/dev/tty) || return
    new_port=$(dialog --inputbox "SSH port:" 10 60 "$port" 2>&1 >/dev/tty) || return
    new_description=$(dialog --inputbox "Description:" 10 60 "$description" 2>&1 >/dev/tty)
    new_ssh_options=$(dialog --inputbox "Custom SSH options:" 10 60 "$ssh_options" 2>&1 >/dev/tty)

    if ! [[ "$new_port" =~ ^[0-9]+$ && "$new_port" -ge 1 && "$new_port" -le 65535 ]]; then
        dialog --title "Error" --msgbox "Port must be a number between 1 and 65535" 8 50
        return 1
    fi

    if [[ "$new_host" != "$host" || "$new_user" != "$user" ]]; then
        if ! check_duplicate_server "$new_host" "$new_user" "$name"; then
            return 1
        fi
    fi

    backup_config
    yq eval ".servers[$server_index].name = \"$new_name\"" -i "$CONFIG_FILE"
    yq eval ".servers[$server_index].host = \"$new_host\"" -i "$CONFIG_FILE"
    yq eval ".servers[$server_index].user = \"$new_user\"" -i "$CONFIG_FILE"
    yq eval ".servers[$server_index].port = $new_port" -i "$CONFIG_FILE"

    if [[ -n "$new_description" ]]; then
        yq eval ".servers[$server_index].description = \"$new_description\"" -i "$CONFIG_FILE"
    else
        yq eval "del(.servers[$server_index].description)" -i "$CONFIG_FILE"
    fi

    if [[ -n "$new_ssh_options" ]]; then
        yq eval ".servers[$server_index].ssh_options = \"$new_ssh_options\"" -i "$CONFIG_FILE"
    else
        yq eval "del(.servers[$server_index].ssh_options)" -i "$CONFIG_FILE"
    fi

    dialog --title "Success" --msgbox "Server edited successfully!" 8 50
    log_message "INFO" "Server edited: $new_name"
}

# Remove server
remove_server() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers to remove" 8 50
        return
    fi

    local menu_items=()
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")

    for ((i=0; i<server_count; i++)); do
        local name host user port
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        port=$(yq eval ".servers[$i].port // 22" "$CONFIG_FILE")
        menu_items+=("$name" "$name ($user@$host:$port)")
    done

    local choice
    choice=$(dialog --clear --title "Remove Server" --menu \
        "Select server to remove:" \
        15 70 8 "${menu_items[@]}" 2>&1 >/dev/tty) || return

    local server_index
    server_index=$(get_server_index_by_name "$choice")
    if [[ $? -ne 0 ]]; then
        dialog --title "Error" --msgbox "Server not found!" 8 50
        return 1
    fi

    local name host user port
    name=$(yq eval ".servers[$server_index].name" "$CONFIG_FILE")
    host=$(yq eval ".servers[$server_index].host" "$CONFIG_FILE")
    user=$(yq eval ".servers[$server_index].user" "$CONFIG_FILE")
    port=$(yq eval ".servers[$server_index].port // 22" "$CONFIG_FILE")

    dialog --clear --title "Confirm Removal" --yesno \
        "Are you sure you want to remove this server?\n\nName: $name\nHost: $host\nUser: $user\nPort: $port" \
        12 60 || return

    backup_config
    yq eval "del(.servers[$server_index])" -i "$CONFIG_FILE"
    dialog --title "Success" --msgbox "Server removed successfully!" 8 50
    log_message "INFO" "Server removed: $name"
}

# Show server information
show_server_info() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers configured" 8 50
        return
    fi

    local info_text=""
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")

    info_text+="Total configured servers: $server_count\n\n"

    for ((i=0; i<server_count; i++)); do
        local name host user port description ssh_options
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        port=$(yq eval ".servers[$i].port // 22" "$CONFIG_FILE")
        description=$(yq eval ".servers[$i].description // \"\"" "$CONFIG_FILE")
        ssh_options=$(yq eval ".servers[$i].ssh_options // \"\"" "$CONFIG_FILE")
        [[ "$description" == "null" ]] && description=""
        [[ "$ssh_options" == "null" ]] && ssh_options=""

        info_text+="[$(($i+1))] $name\n"
        info_text+="    Host: $host\n"
        info_text+="    User: $user\n"
        info_text+="    Port: $port\n"
        [[ -n "$description" ]] && info_text+="    Description: $description\n"
        [[ -n "$ssh_options" ]] && info_text+="    SSH Options: $ssh_options\n"
        info_text+="\n"
    done

    dialog --title "Server Information" --msgbox "$info_text" 20 70
}

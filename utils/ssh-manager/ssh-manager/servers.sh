#!/bin/bash
# Server management for SSH Manager
# Provides: add, edit, remove, show server info

# Add new server
add_server() {
    local name host user port description ssh_options ssh_alias jump_host favorite="false"

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
    ssh_alias=$(dialog --inputbox "SSH alias from ~/.ssh/config (optional):" 10 60 2>&1 >/dev/tty)
    jump_host=$(dialog --inputbox "Jump host / ProxyJump (optional):" 10 60 2>&1 >/dev/tty)

    ssh_options=$(dialog --inputbox "Custom SSH options (optional, e.g., -o ProxyCommand='...'):" 10 60 2>&1 >/dev/tty)

    if ! [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]; then
        dialog --title "Error" --msgbox "Port must be a number between 1 and 65535" 8 50
        return 1
    fi

    if ! check_duplicate_server "$host" "$user"; then
        return 1
    fi

    if ! parse_ssh_options "$ssh_options"; then
        dialog --title "Invalid SSH Options" --msgbox "Only simple SSH flags are supported here. Put complex quoting in ~/.ssh/config." 8 70
        return 1
    fi

    if dialog --title "Favorite" --yesno "Mark '$name' as favorite?" 8 45; then
        favorite="true"
    fi

    backup_config
    NAME="$name" HOST="$host" USERNAME="$user" PORT="$port" \
        yq eval '.servers += [{
            "name": strenv(NAME),
            "host": strenv(HOST),
            "user": strenv(USERNAME),
            "port": (strenv(PORT) | tonumber)
        }]' -i "$CONFIG_FILE"

    if [[ -n "$description" && "$description" != "null" ]]; then
        DESCRIPTION="$description" \
            yq eval '(.servers[-1].description) = strenv(DESCRIPTION)' -i "$CONFIG_FILE"
    fi
    if [[ -n "$ssh_options" && "$ssh_options" != "null" ]]; then
        SSH_OPTIONS="$ssh_options" \
            yq eval '(.servers[-1].ssh_options) = strenv(SSH_OPTIONS)' -i "$CONFIG_FILE"
    fi
    if [[ -n "$ssh_alias" && "$ssh_alias" != "null" ]]; then
        SSH_ALIAS="$ssh_alias" \
            yq eval '(.servers[-1].ssh_alias) = strenv(SSH_ALIAS)' -i "$CONFIG_FILE"
    fi
    if [[ -n "$jump_host" && "$jump_host" != "null" ]]; then
        JUMP_HOST="$jump_host" \
            yq eval '(.servers[-1].jump_host) = strenv(JUMP_HOST)' -i "$CONFIG_FILE"
    fi
    if [[ "$favorite" == "true" ]]; then
        yq eval '(.servers[-1].favorite) = true' -i "$CONFIG_FILE"
    fi

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

    local name host user port description ssh_options ssh_alias jump_host favorite
    name=$(yq eval ".servers[$server_index].name" "$CONFIG_FILE")
    host=$(yq eval ".servers[$server_index].host" "$CONFIG_FILE")
    user=$(yq eval ".servers[$server_index].user" "$CONFIG_FILE")
    port=$(yq eval ".servers[$server_index].port // 22" "$CONFIG_FILE")
    description=$(yq eval ".servers[$server_index].description // \"\"" "$CONFIG_FILE")
    ssh_options=$(yq eval ".servers[$server_index].ssh_options // \"\"" "$CONFIG_FILE")
    ssh_alias=$(yq eval ".servers[$server_index].ssh_alias // \"\"" "$CONFIG_FILE")
    jump_host=$(yq eval ".servers[$server_index].jump_host // \"\"" "$CONFIG_FILE")
    favorite=$(yq eval ".servers[$server_index].favorite // false" "$CONFIG_FILE")
    [[ "$description" == "null" ]] && description=""
    [[ "$ssh_options" == "null" ]] && ssh_options=""
    [[ "$ssh_alias" == "null" ]] && ssh_alias=""
    [[ "$jump_host" == "null" ]] && jump_host=""

    local new_name new_host new_user new_port new_description new_ssh_options new_ssh_alias new_jump_host new_favorite="$favorite"
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
    new_ssh_alias=$(dialog --inputbox "SSH alias from ~/.ssh/config:" 10 60 "$ssh_alias" 2>&1 >/dev/tty)
    new_jump_host=$(dialog --inputbox "Jump host / ProxyJump:" 10 60 "$jump_host" 2>&1 >/dev/tty)
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

    if ! parse_ssh_options "$new_ssh_options"; then
        dialog --title "Invalid SSH Options" --msgbox "Only simple SSH flags are supported here. Put complex quoting in ~/.ssh/config." 8 70
        return 1
    fi

    if dialog --title "Favorite" --yesno "Keep '$new_name' marked as favorite?" 8 50; then
        new_favorite="true"
    else
        new_favorite="false"
    fi

    backup_config
    NAME="$new_name" yq eval "(.servers[$server_index].name) = strenv(NAME)" -i "$CONFIG_FILE"
    HOST="$new_host" yq eval "(.servers[$server_index].host) = strenv(HOST)" -i "$CONFIG_FILE"
    USERNAME="$new_user" yq eval "(.servers[$server_index].user) = strenv(USERNAME)" -i "$CONFIG_FILE"
    PORT="$new_port" yq eval "(.servers[$server_index].port) = (strenv(PORT) | tonumber)" -i "$CONFIG_FILE"

    if [[ -n "$new_description" ]]; then
        DESCRIPTION="$new_description" yq eval "(.servers[$server_index].description) = strenv(DESCRIPTION)" -i "$CONFIG_FILE"
    else
        yq eval "del(.servers[$server_index].description)" -i "$CONFIG_FILE"
    fi

    if [[ -n "$new_ssh_options" ]]; then
        SSH_OPTIONS="$new_ssh_options" yq eval "(.servers[$server_index].ssh_options) = strenv(SSH_OPTIONS)" -i "$CONFIG_FILE"
    else
        yq eval "del(.servers[$server_index].ssh_options)" -i "$CONFIG_FILE"
    fi

    if [[ -n "$new_ssh_alias" ]]; then
        SSH_ALIAS="$new_ssh_alias" yq eval "(.servers[$server_index].ssh_alias) = strenv(SSH_ALIAS)" -i "$CONFIG_FILE"
    else
        yq eval "del(.servers[$server_index].ssh_alias)" -i "$CONFIG_FILE"
    fi

    if [[ -n "$new_jump_host" ]]; then
        JUMP_HOST="$new_jump_host" yq eval "(.servers[$server_index].jump_host) = strenv(JUMP_HOST)" -i "$CONFIG_FILE"
    else
        yq eval "del(.servers[$server_index].jump_host)" -i "$CONFIG_FILE"
    fi

    if [[ "$new_favorite" == "true" ]]; then
        yq eval "(.servers[$server_index].favorite) = true" -i "$CONFIG_FILE"
    else
        yq eval "del(.servers[$server_index].favorite)" -i "$CONFIG_FILE"
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
        local name host user port description ssh_options ssh_alias jump_host favorite last_used use_count
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        port=$(yq eval ".servers[$i].port // 22" "$CONFIG_FILE")
        description=$(yq eval ".servers[$i].description // \"\"" "$CONFIG_FILE")
        ssh_options=$(yq eval ".servers[$i].ssh_options // \"\"" "$CONFIG_FILE")
        ssh_alias=$(yq eval ".servers[$i].ssh_alias // \"\"" "$CONFIG_FILE")
        jump_host=$(yq eval ".servers[$i].jump_host // \"\"" "$CONFIG_FILE")
        favorite=$(yq eval ".servers[$i].favorite // false" "$CONFIG_FILE")
        last_used=$(yq eval ".servers[$i].last_used // 0" "$CONFIG_FILE")
        use_count=$(yq eval ".servers[$i].use_count // 0" "$CONFIG_FILE")
        [[ "$description" == "null" ]] && description=""
        [[ "$ssh_options" == "null" ]] && ssh_options=""
        [[ "$ssh_alias" == "null" ]] && ssh_alias=""
        [[ "$jump_host" == "null" ]] && jump_host=""

        info_text+="[$(($i+1))] $name\n"
        info_text+="    Host: $host\n"
        info_text+="    User: $user\n"
        info_text+="    Port: $port\n"
        [[ "$favorite" == "true" ]] && info_text+="    Favorite: yes\n"
        [[ -n "$ssh_alias" ]] && info_text+="    SSH Alias: $ssh_alias\n"
        [[ -n "$jump_host" ]] && info_text+="    Jump Host: $jump_host\n"
        [[ -n "$description" ]] && info_text+="    Description: $description\n"
        [[ -n "$ssh_options" ]] && info_text+="    SSH Options: $ssh_options\n"
        info_text+="    Last Used: $(format_last_used "$last_used")\n"
        info_text+="    Use Count: ${use_count:-0}\n"
        info_text+="\n"
    done

    dialog --title "Server Information" --msgbox "$info_text" 20 70
}

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
    jq_inplace "$CONFIG_FILE" \
        --arg name "$name" --arg host "$host" --arg user "$user" \
        --argjson port "$port" \
        --arg desc "$description" --arg opts "$ssh_options" \
        --arg alias "$ssh_alias" --arg jump "$jump_host" \
        --arg fav "$favorite" '
        .servers += [{
            "name": $name,
            "host": $host,
            "user": $user,
            "port": $port
        }] |
        if $desc != "" then (.servers[-1].description) = $desc else . end |
        if $opts != "" then (.servers[-1].ssh_options) = $opts else . end |
        if $alias != "" then (.servers[-1].ssh_alias) = $alias else . end |
        if $jump != "" then (.servers[-1].jump_host) = $jump else . end |
        if $fav == "true" then (.servers[-1].favorite) = true else . end
    '

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
    while IFS= read -r name && IFS= read -r host && IFS= read -r user; do
        menu_items+=("$name" "$name ($user@$host)")
    done < <(jq -r '.servers[] | .name, .host, .user' "$CONFIG_FILE")

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

    local fields name host user port description ssh_options ssh_alias jump_host favorite
    readarray -t fields < <(jq -r --argjson i "$server_index" '.servers[$i] | (
        .name, .host, .user,
        (.port // 22 | tostring),
        (.description // ""),
        (.ssh_options // ""),
        (.ssh_alias // ""),
        (.jump_host // ""),
        (.favorite // false | tostring)
    )' "$CONFIG_FILE")
    name="${fields[0]}" host="${fields[1]}" user="${fields[2]}" port="${fields[3]}"
    description="${fields[4]}" ssh_options="${fields[5]}" ssh_alias="${fields[6]}"
    jump_host="${fields[7]}" favorite="${fields[8]}"
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
    jq_inplace "$CONFIG_FILE" \
        --argjson idx "$server_index" \
        --arg name "$new_name" --arg host "$new_host" --arg user "$new_user" \
        --argjson port "$new_port" \
        --arg desc "$new_description" --arg opts "$new_ssh_options" \
        --arg alias "$new_ssh_alias" --arg jump "$new_jump_host" \
        --arg fav "$new_favorite" '
        (.servers[$idx].name) = $name |
        (.servers[$idx].host) = $host |
        (.servers[$idx].user) = $user |
        (.servers[$idx].port) = $port |
        if $desc != "" then (.servers[$idx].description) = $desc else del(.servers[$idx].description) end |
        if $opts != "" then (.servers[$idx].ssh_options) = $opts else del(.servers[$idx].ssh_options) end |
        if $alias != "" then (.servers[$idx].ssh_alias) = $alias else del(.servers[$idx].ssh_alias) end |
        if $jump != "" then (.servers[$idx].jump_host) = $jump else del(.servers[$idx].jump_host) end |
        if $fav == "true" then (.servers[$idx].favorite) = true else del(.servers[$idx].favorite) end
    '

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
    while IFS= read -r name && IFS= read -r host && IFS= read -r user && IFS= read -r port; do
        menu_items+=("$name" "$name ($user@$host:$port)")
    done < <(jq -r '.servers[] | .name, .host, .user, (.port // 22 | tostring)' "$CONFIG_FILE")

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

    local fields name host user port
    readarray -t fields < <(jq -r --argjson i "$server_index" \
        '.servers[$i] | .name, .host, .user, (.port // 22 | tostring)' "$CONFIG_FILE")
    name="${fields[0]}" host="${fields[1]}" user="${fields[2]}" port="${fields[3]}"

    dialog --clear --title "Confirm Removal" --yesno \
        "Are you sure you want to remove this server?\n\nName: $name\nHost: $host\nUser: $user\nPort: $port" \
        12 60 || return

    backup_config
    jq_inplace "$CONFIG_FILE" --argjson idx "$server_index" 'del(.servers[$idx])'
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
    server_count=$(jq '.servers | length' "$CONFIG_FILE")
    info_text+="Total configured servers: $server_count\n\n"

    local idx=1
    while IFS= read -r name && IFS= read -r host && IFS= read -r user && \
          IFS= read -r port && IFS= read -r description && IFS= read -r ssh_options && \
          IFS= read -r ssh_alias && IFS= read -r jump_host && IFS= read -r favorite && \
          IFS= read -r last_used && IFS= read -r use_count; do
        [[ "$description" == "null" ]] && description=""
        [[ "$ssh_options" == "null" ]] && ssh_options=""
        [[ "$ssh_alias" == "null" ]] && ssh_alias=""
        [[ "$jump_host" == "null" ]] && jump_host=""

        info_text+="[$idx] $name\n"
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
        ((idx++))
    done < <(jq -r '.servers[] | (
        .name, .host, .user,
        (.port // 22 | tostring),
        (.description // ""),
        (.ssh_options // ""),
        (.ssh_alias // ""),
        (.jump_host // ""),
        (.favorite // false | tostring),
        (.last_used // 0 | tostring),
        (.use_count // 0 | tostring)
    )' "$CONFIG_FILE")

    dialog --title "Server Information" --msgbox "$info_text" 20 70
}

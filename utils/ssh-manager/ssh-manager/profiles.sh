#!/bin/bash
# Profile toolkit for SSH Manager
# Provides: health checks, ssh config import/export, favorites/recents

toggle_favorite_server() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers configured" 8 50
        return 1
    fi

    local menu_items=()
    local sorted_indices
    sorted_indices=$(get_sorted_server_indices)

    while IFS= read -r i; do
        [[ -z "$i" ]] && continue
        local name host user favorite label
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        favorite=$(yq eval ".servers[$i].favorite // false" "$CONFIG_FILE")
        label="$name ($user@$host)"
        [[ "$favorite" == "true" ]] && label="★ $label"
        menu_items+=("$name" "$label")
    done <<< "$sorted_indices"

    local choice
    choice=$(dialog --clear --title "Toggle Favorite" --menu \
        "Select a server:" \
        18 70 10 "${menu_items[@]}" 2>&1 >/dev/tty) || return

    local index current_state
    index=$(get_server_index_by_name "$choice") || return 1
    current_state=$(yq eval ".servers[$index].favorite // false" "$CONFIG_FILE")

    backup_config
    if [[ "$current_state" == "true" ]]; then
        yq eval "del(.servers[$index].favorite)" -i "$CONFIG_FILE"
        dialog --title "Favorite Updated" --msgbox "'$choice' removed from favorites" 8 50
    else
        yq eval "(.servers[$index].favorite) = true" -i "$CONFIG_FILE"
        dialog --title "Favorite Updated" --msgbox "'$choice' added to favorites" 8 50
    fi
}

show_recent_and_favorites() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers configured" 8 50
        return 1
    fi

    local report="FAVORITES AND RECENT SERVERS\n\n"
    local sorted_indices
    sorted_indices=$(get_sorted_server_indices)

    while IFS= read -r i; do
        [[ -z "$i" ]] && continue
        local name host user favorite last_used use_count last_action prefix
        name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
        host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
        user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
        favorite=$(yq eval ".servers[$i].favorite // false" "$CONFIG_FILE")
        last_used=$(yq eval ".servers[$i].last_used // 0" "$CONFIG_FILE")
        use_count=$(yq eval ".servers[$i].use_count // 0" "$CONFIG_FILE")
        last_action=$(yq eval ".servers[$i].last_action // \"\"" "$CONFIG_FILE")
        [[ "$last_action" == "null" ]] && last_action=""

        prefix=" "
        [[ "$favorite" == "true" ]] && prefix="★"

        report+="${prefix} $name ($user@$host)\n"
        report+="    Last used: $(format_last_used "$last_used")\n"
        report+="    Use count: ${use_count:-0}\n"
        [[ -n "$last_action" ]] && report+="    Last action: $last_action\n"
        report+="\n"
    done <<< "$sorted_indices"

    dialog --title "Favorites / Recents" --msgbox "$report" 22 76
}

import_from_ssh_config() {
    if [[ ! -f "$SSH_CONFIG_FILE" ]]; then
        dialog --title "SSH Config Not Found" --msgbox "No SSH config file found at:\n$SSH_CONFIG_FILE" 9 70
        return 1
    fi

    local aliases=()
    mapfile -t aliases < <(list_ssh_config_aliases)
    if [[ ${#aliases[@]} -eq 0 ]]; then
        dialog --title "No Importable Hosts" --msgbox "No concrete Host aliases found in:\n$SSH_CONFIG_FILE" 9 70
        return 1
    fi

    local checklist_items=()
    local alias
    for alias in "${aliases[@]}"; do
        local ssh_g_output host user port proxy_jump
        ssh_g_output=$(ssh -G "$alias" 2>/dev/null)
        host=$(awk '$1=="hostname"{print $2; exit}' <<< "$ssh_g_output")
        user=$(awk '$1=="user"{print $2; exit}' <<< "$ssh_g_output")
        port=$(awk '$1=="port"{print $2; exit}' <<< "$ssh_g_output")
        proxy_jump=$(awk '$1=="proxyjump"{print $2; exit}' <<< "$ssh_g_output")
        [[ -z "$host" ]] && host="?"
        [[ -z "$user" ]] && user="$USER"
        [[ -z "$port" ]] && port="22"
        [[ -n "$proxy_jump" ]] && checklist_items+=("$alias" "$user@$host:$port via $proxy_jump" "off") || checklist_items+=("$alias" "$user@$host:$port" "off")
    done

    local selected
    selected=$(dialog --clear --separate-output --checklist \
        "Select SSH aliases to import:" \
        22 80 12 "${checklist_items[@]}" 2>&1 >/dev/tty) || return

    [[ -z "$selected" ]] && return 0

    local imported=0 skipped=0
    backup_config

    while IFS= read -r alias; do
        [[ -z "$alias" ]] && continue

        local ssh_g_output host user port proxy_jump description
        ssh_g_output=$(ssh -G "$alias" 2>/dev/null)
        host=$(awk '$1=="hostname"{print $2; exit}' <<< "$ssh_g_output")
        user=$(awk '$1=="user"{print $2; exit}' <<< "$ssh_g_output")
        port=$(awk '$1=="port"{print $2; exit}' <<< "$ssh_g_output")
        proxy_jump=$(awk '$1=="proxyjump"{print $2; exit}' <<< "$ssh_g_output")
        [[ -z "$host" ]] && host="$alias"
        [[ -z "$user" ]] && user="$USER"
        [[ -z "$port" ]] && port="22"

        if yq eval '.servers[]?.name' "$CONFIG_FILE" 2>/dev/null | grep -Fxq "$alias"; then
            ((skipped++))
            continue
        fi
        if yq eval '.servers[]? | .host + "|" + .user' "$CONFIG_FILE" 2>/dev/null | grep -Fxq "${host}|${user}"; then
            ((skipped++))
            continue
        fi

        description="Imported from ~/.ssh/config"
        NAME="$alias" HOST="$host" USERNAME="$user" PORT="$port" SSH_ALIAS="$alias" DESCRIPTION="$description" \
            yq eval '.servers += [{
                "name": strenv(NAME),
                "host": strenv(HOST),
                "user": strenv(USERNAME),
                "port": (strenv(PORT) | tonumber),
                "ssh_alias": strenv(SSH_ALIAS),
                "description": strenv(DESCRIPTION)
            }]' -i "$CONFIG_FILE"

        if [[ -n "$proxy_jump" ]]; then
            JUMP_HOST="$proxy_jump" yq eval '(.servers[-1].jump_host) = strenv(JUMP_HOST)' -i "$CONFIG_FILE"
        fi

        ((imported++))
    done <<< "$selected"

    dialog --title "Import Complete" --msgbox "Imported: $imported\nSkipped: $skipped\n\nSource: $SSH_CONFIG_FILE" 10 60
}

export_profiles_to_ssh_config() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers configured" 8 50
        return 1
    fi

    ensure_manager_runtime_dirs

    local export_file="$EXPORT_DIR/ssh-manager-export-$(date +%Y%m%d%H%M%S).conf"
    local server_count
    server_count=$(yq eval '.servers | length' "$CONFIG_FILE")

    {
        echo "# SSH Manager export generated on $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        for ((i=0; i<server_count; i++)); do
            local alias host user port description jump_host
            alias=$(generate_export_host_alias "$i")
            host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
            user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
            port=$(yq eval ".servers[$i].port // 22" "$CONFIG_FILE")
            description=$(yq eval ".servers[$i].description // \"\"" "$CONFIG_FILE")
            jump_host=$(yq eval ".servers[$i].jump_host // \"\"" "$CONFIG_FILE")
            [[ "$description" == "null" ]] && description=""
            [[ "$jump_host" == "null" ]] && jump_host=""

            echo "Host $alias"
            echo "    HostName $host"
            echo "    User $user"
            echo "    Port $port"
            [[ -n "$jump_host" ]] && echo "    ProxyJump $jump_host"
            [[ -n "$description" ]] && echo "    # $description"
            echo
        done
    } > "$export_file"

    dialog --title "Export Complete" --msgbox "Profiles exported to:\n$export_file" 10 70
}

run_health_check_menu() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "No servers configured" 8 50
        return 1
    fi

    local choice
    choice=$(dialog --clear --title "Health Check" --menu \
        "Select check scope:" \
        15 60 5 \
        "1" "Single server" \
        "2" "All servers" \
        "0" "Back" 2>&1 >/dev/tty) || return

    case "$choice" in
        "1")
            test_connectivity_menu
            ;;
        "2")
            clear
            local sorted_indices failures=0
            sorted_indices=$(get_sorted_server_indices)
            while IFS= read -r i; do
                [[ -z "$i" ]] && continue
                run_server_health_check "$i" || ((failures++))
                echo
            done <<< "$sorted_indices"
            if [[ "$failures" -eq 0 ]]; then
                print_message "$GREEN" "✅ All health checks passed"
            else
                print_message "$YELLOW" "⚠️  Health checks completed with $failures failure(s)"
            fi
            pause_for_enter
            ;;
    esac
}

profile_toolkit_menu() {
    while true; do
        local choice
        choice=$(dialog --clear --title "Profile Toolkit" --menu \
            "Profiles, health, import/export and favorites:" \
            20 72 10 \
            "1" "🔎 Health checks" \
            "2" "📥 Import from ~/.ssh/config" \
            "3" "📤 Export profiles to SSH config" \
            "4" "★ Toggle favorite" \
            "5" "🕘 Show favorites / recents" \
            "0" "← Back to main menu" 2>&1 >/dev/tty)

        if should_return_to_main_menu; then
            clear
            return
        fi

        case "$choice" in
            "") clear; return ;;
            "1") run_health_check_menu ;;
            "2") import_from_ssh_config ;;
            "3") export_profiles_to_ssh_config ;;
            "4") toggle_favorite_server ;;
            "5") show_recent_and_favorites ;;
            "0") clear; return ;;
        esac
    done
}

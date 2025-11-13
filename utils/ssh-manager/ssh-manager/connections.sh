#!/bin/bash
# Connection handlers for SSH Manager
# Provides: SSH, SFTP, SSHFS+MC connection handlers

# Generic function to handle SSH actions
handle_ssh_action() {
    local action="$1"

    if ! validate_config; then
        dialog --title "Error" --msgbox "Invalid or empty configuration file" 8 50
        return 1
    fi

    while true; do
        local menu_items=()
        local server_count
        server_count=$(yq eval '.servers | length' "$CONFIG_FILE")

        for ((i=0; i<server_count; i++)); do
            local name host user port description
            name=$(yq eval ".servers[$i].name" "$CONFIG_FILE")
            host=$(yq eval ".servers[$i].host" "$CONFIG_FILE")
            user=$(yq eval ".servers[$i].user" "$CONFIG_FILE")
            port=$(yq eval ".servers[$i].port // 22" "$CONFIG_FILE")
            description=$(yq eval ".servers[$i].description // \"\"" "$CONFIG_FILE")

            local display_text="$name ($user@$host:$port)"
            [[ -n "$description" && "$description" != "null" ]] && display_text="$display_text - $description"

            # Usa il nome del server come identificatore invece dell'indice
            menu_items+=("$name" "$display_text")
        done

        menu_items+=("T" "🔍 Test connectivity")
        menu_items+=("Q" "← Back to main menu")

        local choice
        choice=$(dialog --clear --title "SSH Manager - $action" --menu \
            "Select a server:\n(Use arrow keys and press Enter, or type to search)" \
            20 80 10 "${menu_items[@]}" 2>&1 >/dev/tty)

        case "$choice" in
            ""|"Q") clear; return ;;
            "T") test_connectivity_menu; continue ;;
            *)
                # Trova l'indice del server dal nome
                local server_index
                server_index=$(get_server_index_by_name "$choice")
                if [[ $? -eq 0 ]]; then
                    execute_ssh_action "$action" "$server_index"
                fi
                ;;
        esac
    done
}

# Execute specific SSH action
execute_ssh_action() {
    local action="$1"
    local index="$2"

    local name host user port ssh_options
    name=$(yq eval ".servers[$index].name" "$CONFIG_FILE")
    host=$(yq eval ".servers[$index].host" "$CONFIG_FILE")
    user=$(yq eval ".servers[$index].user" "$CONFIG_FILE")
    port=$(yq eval ".servers[$index].port // 22" "$CONFIG_FILE")
    ssh_options=$(yq eval ".servers[$index].ssh_options // \"\"" "$CONFIG_FILE")

    clear

    case "$action" in
        "ssh")
            print_message "$BLUE" "🚀 Connecting to: $user@$host:$port ($name)..."
            log_message "INFO" "SSH connection to $user@$host:$port"
            ssh $ssh_options -p "$port" -t "$user@$host" 2> ssh_error.log
            local status=$?
            ;;
        "ssh-copy-id")
            if ! check_ssh_key; then
                dialog --title "Error" --msgbox "No SSH public key found" 8 50
                return 1
            fi
            print_message "$BLUE" "🔑 Copying SSH key to: $user@$host:$port ($name)..."
            log_message "INFO" "Copying SSH key to $user@$host:$port"
            ssh-copy-id $ssh_options -p "$port" "$user@$host" 2> ssh_error.log
            local status=$?
            ;;
        "sftp")
            print_message "$BLUE" "📁 Starting SFTP with: $user@$host:$port ($name)..."
            log_message "INFO" "SFTP connection to $user@$host:$port"
            sftp $ssh_options -P "$port" "$user@$host" 2> ssh_error.log
            local status=$?
            ;;
        "sshfs-mc")
            if ! check_sshfs_mc; then
                print_message "$RED" "❌ Required packages not available"
                print_message "$YELLOW" "\nPress ENTER to continue..."
                read -r
                return 1
            fi

            execute_sshfs_mc "$name" "$host" "$user" "$port" "$ssh_options"
            local status=$?
            ;;
    esac

    if [[ $status -ne 0 ]]; then
        print_message "$RED" "❌ Error during $action: $(cat ssh_error.log 2>/dev/null || echo 'Unknown error')"
        log_message "ERROR" "$action failed on $user@$host:$port - $(cat ssh_error.log 2>/dev/null || echo 'Unknown error')"
        rm -f ssh_error.log
    else
        case "$action" in
            "ssh") print_message "$GREEN" "✅ SSH connection terminated successfully" ;;
            "ssh-copy-id") print_message "$GREEN" "✅ SSH key copied successfully" ;;
            "sftp") print_message "$GREEN" "✅ SFTP session terminated" ;;
            "sshfs-mc") print_message "$GREEN" "✅ SSHFS+MC session completed" ;;
        esac
        log_message "INFO" "Operation $action completed successfully on $user@$host:$port"
    fi

    if [[ "$action" != "sshfs-mc" ]]; then
        print_message "$YELLOW" "\nPress ENTER to continue..."
        read -r
    fi
}

# Execute SSHFS + MC
execute_sshfs_mc() {
    local name="$1"
    local host="$2"
    local user="$3"
    local port="$4"
    local ssh_options="$5"

    # Create mount point
    local mount_point="/tmp/sshfs-${name// /_}-$$"
    mkdir -p "$mount_point" || {
        print_message "$RED" "❌ Cannot create mount point: $mount_point"
        return 1
    }

    print_message "$BLUE" "🔗 Mounting remote filesystem: $user@$host:$port ($name)..."
    print_message "$BLUE" "📂 Mount point: $mount_point"

    # SSHFS mount options
    local sshfs_options="-p $port"
    if [[ -n "$ssh_options" && "$ssh_options" != "null" ]]; then
        sshfs_options="$sshfs_options -o ssh_command='ssh $ssh_options'"
    fi

    # Add common SSHFS options for better experience
    sshfs_options="$sshfs_options -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3"

    # Mount the remote filesystem
    if sshfs $sshfs_options "$user@$host:/" "$mount_point" 2> sshfs_error.log; then
        print_message "$GREEN" "✅ Remote filesystem mounted successfully"
        log_message "INFO" "SSHFS mount successful: $user@$host:/ -> $mount_point"

        print_message "$BLUE" "🗂️  Starting Midnight Commander..."
        print_message "$YELLOW" "💡 When you exit MC, the remote filesystem will be automatically unmounted"

        # Wait a moment to let user read the message
        sleep 2

        # Start Midnight Commander
        mc "$mount_point" 2> mc_error.log
        local mc_status=$?

        # Unmount the filesystem
        print_message "$BLUE" "🔌 Unmounting remote filesystem..."
        if fusermount -u "$mount_point" 2> unmount_error.log; then
            print_message "$GREEN" "✅ Remote filesystem unmounted successfully"
            log_message "INFO" "SSHFS unmount successful: $mount_point"
        else
            print_message "$YELLOW" "⚠️  Warning during unmount: $(cat unmount_error.log)"
            log_message "WARNING" "SSHFS unmount warning: $(cat unmount_error.log)"
            # Try force unmount
            if fusermount -uz "$mount_point" 2>/dev/null; then
                print_message "$GREEN" "✅ Force unmount successful"
            fi
        fi

        # Clean up mount point
        rmdir "$mount_point" 2>/dev/null

        # Clean up error logs
        rm -f sshfs_error.log mc_error.log unmount_error.log

        if [[ $mc_status -eq 0 ]]; then
            return 0
        else
            print_message "$YELLOW" "⚠️  MC exited with status: $mc_status"
            return 0  # Non è necessariamente un errore
        fi

    else
        print_message "$RED" "❌ Failed to mount remote filesystem: $(cat sshfs_error.log)"
        log_message "ERROR" "SSHFS mount failed: $user@$host:/ -> $mount_point - $(cat sshfs_error.log)"

        # Clean up
        rmdir "$mount_point" 2>/dev/null
        rm -f sshfs_error.log

        print_message "$YELLOW" "\nPress ENTER to continue..."
        read -r
        return 1
    fi
}

# Connectivity test menu
test_connectivity_menu() {
    if ! validate_config; then
        dialog --title "Error" --msgbox "Invalid configuration file" 8 50
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
    choice=$(dialog --clear --title "Connectivity Test" --menu \
        "Select server to test:" \
        15 60 8 "${menu_items[@]}" 2>&1 >/dev/tty)

    if [[ -n "$choice" ]]; then
        local server_index
        server_index=$(get_server_index_by_name "$choice")
        if [[ $? -eq 0 ]]; then
            local user host port
            user=$(yq eval ".servers[$server_index].user" "$CONFIG_FILE")
            host=$(yq eval ".servers[$server_index].host" "$CONFIG_FILE")
            port=$(yq eval ".servers[$server_index].port // 22" "$CONFIG_FILE")

            clear
            test_ssh_connection "$user" "$host" "$port"
            print_message "$YELLOW" "\nPress ENTER to continue..."
            read -r
        fi
    fi
}

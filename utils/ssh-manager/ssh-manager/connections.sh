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
        local sorted_indices
        sorted_indices=$(get_sorted_server_indices)

        while IFS= read -r i; do
            [[ -z "$i" ]] && continue
            local name host user port description favorite last_used display_text recent_label
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
        done <<< "$sorted_indices"

        menu_items+=("T" "🔍 Test connectivity")
        menu_items+=("Q" "← Back to main menu")

        local choice
        choice=$(dialog --clear --title "SSH Manager - $action" --menu \
            "Select a server:\n(Use arrow keys and press Enter, or type to search)" \
            20 80 10 "${menu_items[@]}" 2>&1 >/dev/tty)

        if should_return_to_main_menu; then
            clear
            return
        fi

        case "$choice" in
            ""|"Q") clear; return ;;
            "T") test_connectivity_menu; continue ;;
            *)
                # Trova l'indice del server dal nome
                local server_index
                server_index=$(get_server_index_by_name "$choice")
                if [[ $? -eq 0 ]]; then
                    execute_ssh_action "$action" "$server_index"
                    if [[ "$INTERRUPTED" -eq 1 ]]; then
                        clear_interrupt_state
                        clear_main_menu_request
                        continue
                    fi
                fi
                ;;
        esac
    done
}

# Execute specific SSH action
execute_ssh_action() {
    local action="$1"
    local index="$2"
    local status
    local ssh_cmd=()

    if ! resolve_server_connection "$index"; then
        pause_for_enter
        return 1
    fi

    clear

    case "$action" in
        "ssh")
            print_message "$BLUE" "🚀 Connecting to: $RESOLVED_DISPLAY_TARGET ($RESOLVED_SERVER_NAME)..."
            log_message "INFO" "SSH connection to $RESOLVED_DISPLAY_TARGET"
            ssh_cmd=(ssh)
            append_resolved_connection_options ssh_cmd
            ssh_cmd+=(-t "$RESOLVED_SSH_TARGET")
            "${ssh_cmd[@]}" 2> "$CONFIG_DIR/ssh_error.log"
            status=$?
            ;;
        "ssh-copy-id")
            if ! check_ssh_key; then
                dialog --title "Error" --msgbox "No SSH public key found" 8 50
                return 1
            fi
            print_message "$BLUE" "🔑 Copying SSH key to: $RESOLVED_DISPLAY_TARGET ($RESOLVED_SERVER_NAME)..."
            log_message "INFO" "Copying SSH key to $RESOLVED_DISPLAY_TARGET"
            ssh_cmd=(ssh-copy-id)
            append_resolved_connection_options ssh_cmd
            ssh_cmd+=("$RESOLVED_SSH_TARGET")
            "${ssh_cmd[@]}" 2> "$CONFIG_DIR/ssh_error.log"
            status=$?
            ;;
        "sftp")
            print_message "$BLUE" "📁 Starting SFTP with: $RESOLVED_DISPLAY_TARGET ($RESOLVED_SERVER_NAME)..."
            log_message "INFO" "SFTP connection to $RESOLVED_DISPLAY_TARGET"
            ssh_cmd=(sftp)
            if [[ "$RESOLVED_HAS_ALIAS" -eq 0 ]]; then
                ssh_cmd+=(-P "$RESOLVED_PORT")
            fi
            if [[ -n "$RESOLVED_PROXY_JUMP" ]]; then
                ssh_cmd+=(-o "ProxyJump=$RESOLVED_PROXY_JUMP")
            fi
            if [[ ${#PARSED_SSH_OPTIONS[@]} -gt 0 ]]; then
                ssh_cmd+=("${PARSED_SSH_OPTIONS[@]}")
            fi
            ssh_cmd+=("$RESOLVED_SSH_TARGET")
            "${ssh_cmd[@]}" 2> "$CONFIG_DIR/ssh_error.log"
            status=$?
            ;;
        "sshfs-mc")
            if ! check_sshfs_mc; then
                print_message "$RED" "❌ Required packages not available"
                pause_for_enter
                return 1
            fi

            execute_sshfs_mc "$index"
            status=$?
            ;;
    esac

    if [[ $status -eq 130 || "$INTERRUPTED" -eq 1 ]]; then
        print_message "$YELLOW" "⚠️  Operation cancelled, returning to main menu"
        log_message "INFO" "Operation $action interrupted by user"
        rm -f "$CONFIG_DIR/ssh_error.log"
    elif [[ $status -ne 0 ]]; then
        print_message "$RED" "❌ Error during $action: $(cat "$CONFIG_DIR/ssh_error.log" 2>/dev/null || echo 'Unknown error')"
        log_message "ERROR" "$action failed on $RESOLVED_DISPLAY_TARGET - $(cat "$CONFIG_DIR/ssh_error.log" 2>/dev/null || echo 'Unknown error')"
        rm -f "$CONFIG_DIR/ssh_error.log"
    else
        case "$action" in
            "ssh") print_message "$GREEN" "✅ SSH connection terminated successfully" ;;
            "ssh-copy-id") print_message "$GREEN" "✅ SSH key copied successfully" ;;
            "sftp") print_message "$GREEN" "✅ SFTP session terminated" ;;
            "sshfs-mc") print_message "$GREEN" "✅ SSHFS+MC session completed" ;;
        esac
        record_server_usage "$index" "$action"
        log_message "INFO" "Operation $action completed successfully on $RESOLVED_DISPLAY_TARGET"
    fi

    if [[ "$action" != "sshfs-mc" ]]; then
        pause_for_enter
    fi
}

# Execute SSHFS + MC
execute_sshfs_mc() {
    local index="$1"
    local mount_point
    local sshfs_cmd=()
    local ssh_command_string

    if ! resolve_server_connection "$index"; then
        return 1
    fi

    # Create mount point
    mount_point="/tmp/sshfs-${RESOLVED_SERVER_NAME// /_}-$$"
    mkdir -p "$mount_point" || {
        print_message "$RED" "❌ Cannot create mount point: $mount_point"
        return 1
    }

    print_message "$BLUE" "🔗 Mounting remote filesystem: $RESOLVED_DISPLAY_TARGET ($RESOLVED_SERVER_NAME)..."
    print_message "$BLUE" "📂 Mount point: $mount_point"

    sshfs_cmd=(sshfs)
    if [[ "$RESOLVED_HAS_ALIAS" -eq 0 ]]; then
        sshfs_cmd+=(-p "$RESOLVED_PORT")
    fi
    if [[ -n "$RESOLVED_PROXY_JUMP" || ${#PARSED_SSH_OPTIONS[@]} -gt 0 ]]; then
        ssh_command_string=$(build_ssh_command_string "$RESOLVED_PORT" "$RESOLVED_SSH_TARGET")
        sshfs_cmd+=(-o "ssh_command=$ssh_command_string")
    fi

    # Add common SSHFS options for better experience
    sshfs_cmd+=(-o "reconnect,ServerAliveInterval=15,ServerAliveCountMax=3")

    # Mount the remote filesystem
    sshfs_cmd+=("${RESOLVED_SSH_TARGET}:/" "$mount_point")
    if "${sshfs_cmd[@]}" 2> "$CONFIG_DIR/sshfs_error.log"; then
        print_message "$GREEN" "✅ Remote filesystem mounted successfully"
        log_message "INFO" "SSHFS mount successful: ${RESOLVED_SSH_TARGET}:/ -> $mount_point"

        print_message "$BLUE" "🗂️  Starting Midnight Commander..."
        print_message "$YELLOW" "💡 When you exit MC, the remote filesystem will be automatically unmounted"

        # Wait a moment to let user read the message
        sleep 2

        # Start Midnight Commander
        mc "$mount_point" 2> "$CONFIG_DIR/mc_error.log"
        local mc_status=$?

        # Unmount the filesystem
        print_message "$BLUE" "🔌 Unmounting remote filesystem..."
        if fusermount -u "$mount_point" 2> "$CONFIG_DIR/unmount_error.log"; then
            print_message "$GREEN" "✅ Remote filesystem unmounted successfully"
            log_message "INFO" "SSHFS unmount successful: $mount_point"
        else
            print_message "$YELLOW" "⚠️  Warning during unmount: $(cat "$CONFIG_DIR/unmount_error.log")"
            log_message "WARNING" "SSHFS unmount warning: $(cat "$CONFIG_DIR/unmount_error.log")"
            # Try force unmount
            if fusermount -uz "$mount_point" 2>/dev/null; then
                print_message "$GREEN" "✅ Force unmount successful"
            fi
        fi

        # Clean up mount point
        rmdir "$mount_point" 2>/dev/null

        # Clean up error logs
        rm -f "$CONFIG_DIR/sshfs_error.log" "$CONFIG_DIR/mc_error.log" "$CONFIG_DIR/unmount_error.log"

        if [[ $mc_status -eq 0 ]]; then
            return 0
        else
            print_message "$YELLOW" "⚠️  MC exited with status: $mc_status"
            return 0  # Non è necessariamente un errore
        fi

    else
        if [[ "$INTERRUPTED" -eq 1 ]]; then
            rmdir "$mount_point" 2>/dev/null
            rm -f "$CONFIG_DIR/sshfs_error.log"
            print_message "$YELLOW" "⚠️  SSHFS operation cancelled, returning to main menu"
            return 130
        fi

        print_message "$RED" "❌ Failed to mount remote filesystem: $(cat "$CONFIG_DIR/sshfs_error.log")"
        log_message "ERROR" "SSHFS mount failed: ${RESOLVED_SSH_TARGET}:/ -> $mount_point - $(cat "$CONFIG_DIR/sshfs_error.log")"

        # Clean up
        rmdir "$mount_point" 2>/dev/null
        rm -f "$CONFIG_DIR/sshfs_error.log"

        pause_for_enter
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
    choice=$(dialog --clear --title "Connectivity Test" --menu \
        "Select server to test:" \
        15 60 8 "${menu_items[@]}" 2>&1 >/dev/tty)

    if should_return_to_main_menu; then
        clear
        return
    fi

    if [[ -n "$choice" ]]; then
        local server_index
        server_index=$(get_server_index_by_name "$choice")
        if [[ $? -eq 0 ]]; then
            clear
            run_server_health_check "$server_index"
            pause_for_enter
            if [[ "$INTERRUPTED" -eq 1 ]]; then
                clear_interrupt_state
                clear_main_menu_request
                return
            fi
        fi
    fi
}

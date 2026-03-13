#!/bin/bash

# dialog.sh - Full dialog TUI

# Build shares menu entries (index + "name [type] status")
build_shares_menu() {
    local filter="${1:-all}"
    local sections
    sections=$(get_sections "$CONFIG_FILE")
    [ -z "$sections" ] && return

    local index=1
    while read -r name; do
        [ -z "$name" ] && continue

        local mp type
        mp=$(get_mountpoint "$name")
        type=$(get_field "$name" "type" "$CONFIG_FILE")
        type="${type:-cifs}"
        local desc
        desc=$(get_field "$name" "description" "$CONFIG_FILE")

        case "$filter" in
            mounted)   is_mounted "$mp" || continue ;;
            unmounted) is_mounted "$mp" && continue ;;
        esac

        local status
        status=$(get_status "$mp")
        local label="$name [$type] $status"
        [ -n "$desc" ] && label="$label — $desc"
        printf '%s\n' "$index" "$label"
        ((index++)) || true
    done <<< "$sections"
}

# Get section name by menu index
get_section_by_index() {
    local index=$1
    local filter="${2:-all}"
    local sections
    sections=$(get_sections "$CONFIG_FILE")
    [ -z "$sections" ] && return 1

    local current=1
    while read -r name; do
        [ -z "$name" ] && continue

        local mp
        mp=$(get_mountpoint "$name")

        case "$filter" in
            mounted)   is_mounted "$mp" || continue ;;
            unmounted) is_mounted "$mp" && continue ;;
        esac

        if [ "$current" -eq "$index" ]; then
            echo "$name"
            return 0
        fi
        ((current++)) || true
    done <<< "$sections"

    return 1
}

# Dialog: Mount a share (output shown in terminal)
dialog_mount() {
    local name="$1"

    if ! section_exists "$name" "$CONFIG_FILE"; then
        dialog --msgbox "Error: share '$name' not found" 7 50
        return 1
    fi

    local mp
    mp=$(get_mountpoint "$name")

    if is_mounted "$mp"; then
        dialog --msgbox "Share '$name' is already mounted at:\n\n$mp" 8 60
        return 0
    fi

    clear
    sudo -v 2>/dev/null || true
    do_mount "$name"
    local rc=$?

    echo ""
    if [ $rc -eq 0 ] && is_mounted "$mp"; then
        echo -e "${GREEN}✓ Mount successful: $mp${NC}"
        sleep 1
        if command -v nautilus &>/dev/null; then
            if dialog --yesno "Open Nautilus to browse files?" 6 50; then
                nautilus "$mp" >/dev/null 2>&1 &
            fi
        fi
    else
        echo -e "${RED}✗ Error: failed to mount share${NC}"
        read -rp "Press Enter to continue..."
        return 1
    fi
}

# Dialog: Unmount a share
dialog_umount() {
    local name="$1"

    if ! section_exists "$name" "$CONFIG_FILE"; then
        dialog --msgbox "Error: share '$name' not found" 7 50
        return 1
    fi

    local mp
    mp=$(get_mountpoint "$name")

    if ! is_mounted "$mp"; then
        dialog --msgbox "Share '$name' is not mounted" 7 50
        return 0
    fi

    if ! dialog --yesno "Unmount share:\n\n$name\n\nfrom: $mp?" 10 60; then
        return 0
    fi

    clear
    sudo -v 2>/dev/null || true
    do_umount "$name"
    local rc=$?

    echo ""
    if [ $rc -eq 0 ] && ! is_mounted "$mp"; then
        echo -e "${GREEN}✓ Share unmounted successfully${NC}"
        sleep 1
    else
        echo -e "${RED}✗ Error: failed to unmount (still in use?)${NC}"
        read -rp "Press Enter to continue..."
        return 1
    fi
}

# Dialog: Show status of all shares
dialog_show_status() {
    local sections
    sections=$(get_sections "$CONFIG_FILE")

    if [ -z "$sections" ]; then
        dialog --msgbox "No shares configured" 6 50
        return
    fi

    local status_text="SHARE STATUS\n============\n\n"

    while read -r name; do
        [ -z "$name" ] && continue

        local mp host share type desc
        mp=$(get_mountpoint "$name")
        host=$(get_field "$name" "host" "$CONFIG_FILE")
        share=$(get_field "$name" "share" "$CONFIG_FILE")
        type=$(get_field "$name" "type" "$CONFIG_FILE")
        type="${type:-cifs}"
        desc=$(get_field "$name" "description" "$CONFIG_FILE")

        local icon
        if is_mounted "$mp"; then icon="✓"; else icon="✗"; fi

        status_text+="[$icon] $name ($type)\n"
        [ -n "$desc" ] && status_text+="    Description: $desc\n"
        status_text+="    Host: $host\n"
        status_text+="    Share: $share\n"
        status_text+="    Mount: $mp\n\n"
    done <<< "$sections"

    dialog --msgbox "$status_text" 25 70
}

# Dialog: Add/edit share form
dialog_edit_form() {
    local edit_name="$1"

    local name="" description="" type="cifs" host="" share="" username="" password="" options="" mountpoint=""

    if [ -n "$edit_name" ]; then
        name="$edit_name"
        description=$(get_field "$name" "description" "$CONFIG_FILE")
        type=$(get_field "$name" "type" "$CONFIG_FILE"); type="${type:-cifs}"
        host=$(get_field "$name" "host" "$CONFIG_FILE")
        share=$(get_field "$name" "share" "$CONFIG_FILE")
        username=$(get_field "$name" "username" "$CONFIG_FILE")
        password=$(get_field "$name" "password" "$CONFIG_FILE")
        options=$(get_field "$name" "options" "$CONFIG_FILE")
        mountpoint=$(get_mountpoint "$name")
    fi

    # Choose type first
    local chosen_type
    chosen_type=$(dialog --menu "Share type" 12 50 3 \
        cifs  "Windows/Samba (CIFS)" \
        nfs   "Network File System (NFS)" \
        sshfs "SSH Filesystem (SSHFS)" \
        2>&1 >/dev/tty) || return 1

    type="$chosen_type"

    local temp_file
    temp_file=$(mktemp)

    local title
    title=$([ -z "$edit_name" ] && echo "Add share [$type]" || echo "Edit share [$type]")

    case "$type" in
        cifs)
            dialog --form "$title" 22 70 7 \
                "Name:"        1 1 "$name"        1 20 30 0 \
                "Description:" 2 1 "$description" 2 20 40 0 \
                "Host:"        3 1 "$host"        3 20 30 0 \
                "Share:"       4 1 "$share"       4 20 30 0 \
                "Username:"    5 1 "$username"    5 20 30 0 \
                "Options:"     6 1 "$options"     6 20 30 0 \
                "Mount point:" 7 1 "$mountpoint"  7 20 40 0 \
                2> "$temp_file"
            ;;
        nfs)
            dialog --form "$title" 20 70 6 \
                "Name:"        1 1 "$name"        1 20 30 0 \
                "Description:" 2 1 "$description" 2 20 40 0 \
                "Host:"        3 1 "$host"        3 20 30 0 \
                "Export path:" 4 1 "$share"       4 20 30 0 \
                "Options:"     5 1 "$options"     5 20 30 0 \
                "Mount point:" 6 1 "$mountpoint"  6 20 40 0 \
                2> "$temp_file"
            ;;
        sshfs)
            dialog --form "$title" 22 70 7 \
                "Name:"        1 1 "$name"        1 20 30 0 \
                "Description:" 2 1 "$description" 2 20 40 0 \
                "Host:"        3 1 "$host"        3 20 30 0 \
                "Remote path:" 4 1 "$share"       4 20 30 0 \
                "Username:"    5 1 "$username"    5 20 30 0 \
                "Options:"     6 1 "$options"     6 20 30 0 \
                "Mount point:" 7 1 "$mountpoint"  7 20 40 0 \
                2> "$temp_file"
            ;;
    esac

    local result=$?
    if [ $result -ne 0 ]; then
        rm -f "$temp_file"
        return 1
    fi

    local -a _fields
    mapfile -t _fields < "$temp_file"
    rm -f "$temp_file"

    local new_name new_description new_host new_share new_username new_options new_mountpoint
    case "$type" in
        cifs)
            new_name="${_fields[0]:-}"
            new_description="${_fields[1]:-}"
            new_host="${_fields[2]:-}"
            new_share="${_fields[3]:-}"
            new_username="${_fields[4]:-}"
            new_options="${_fields[5]:-}"
            new_mountpoint="${_fields[6]:-}"
            ;;
        nfs)
            new_name="${_fields[0]:-}"
            new_description="${_fields[1]:-}"
            new_host="${_fields[2]:-}"
            new_share="${_fields[3]:-}"
            new_options="${_fields[4]:-}"
            new_mountpoint="${_fields[5]:-}"
            new_username=""
            ;;
        sshfs)
            new_name="${_fields[0]:-}"
            new_description="${_fields[1]:-}"
            new_host="${_fields[2]:-}"
            new_share="${_fields[3]:-}"
            new_username="${_fields[4]:-}"
            new_options="${_fields[5]:-}"
            new_mountpoint="${_fields[6]:-}"
            ;;
    esac

    if [ -z "$new_name" ] || [ -z "$new_host" ] || [ -z "$new_share" ]; then
        dialog --msgbox "Error: Name, Host and Share are required" 7 60
        return 1
    fi

    # Duplicate name check: block if name already exists (add) or clashes with another section (rename)
    if [ -z "$edit_name" ] || [ "$new_name" != "$edit_name" ]; then
        if section_exists "$new_name" "$CONFIG_FILE"; then
            dialog --msgbox "Error: a share named '$new_name' already exists.\nChoose a different name." 8 60
            return 1
        fi
    fi

    local new_password=""
    if [ "$type" = "cifs" ]; then
        new_password=$(dialog --passwordbox "Password for '$new_name':" 8 50 2>&1 >/dev/tty)
        [ $? -ne 0 ] && return 1
    fi

    # If the user cleared the mountpoint field, fall back to the bare default
    # (do NOT read from config here — the section still exists at this point)
    [ -z "$new_mountpoint" ] && new_mountpoint="/mnt/shares/$new_name"

    # Handle rename: unmount old share if needed
    if [ -n "$edit_name" ] && [ "$new_name" != "$edit_name" ]; then
        local old_mp
        old_mp=$(get_mountpoint "$edit_name")

        if is_mounted "$old_mp"; then
            if ! dialog --yesno "Share '$edit_name' is currently mounted.\nUnmount it before renaming?" 8 60; then
                dialog --msgbox "Operation cancelled" 6 50
                return 1
            fi
            dialog_umount "$edit_name" || return 1
        fi
    fi

    rotate_config_backup
    [ -n "$edit_name" ] && delete_section "$edit_name" "$CONFIG_FILE"

    add_section "$new_name" "$type" "$new_host" "$new_share" "$new_username" "$new_password" "$new_options" "$new_mountpoint" "$new_description" "$CONFIG_FILE"

    local action
    action=$([ -z "$edit_name" ] && echo "added" || echo "updated")
    dialog --msgbox "Share '$new_name' $action successfully" 6 55
    return 0
}

# Dialog: Bookmark management submenu
dialog_menu_bookmark() {
    while true; do
        local choice
        choice=$(dialog --menu "Manage Bookmarks" 20 60 4 \
            1 "Add new share" \
            2 "Edit existing share" \
            3 "Delete share" \
            4 "Back to main menu" \
            2>&1 >/dev/tty)

        case $choice in
            1) dialog_edit_form "" ;;
            2)
                local -a menu_arr
                mapfile -t menu_arr < <(build_shares_menu)
                if [ ${#menu_arr[@]} -eq 0 ]; then
                    dialog --msgbox "No shares available" 6 50
                    continue
                fi
                local edit_choice
                edit_choice=$(dialog --menu "Select share to edit" 20 60 5 \
                    "${menu_arr[@]}" 2>&1 >/dev/tty) || continue
                local edit_name
                edit_name=$(get_section_by_index "$edit_choice") || continue
                dialog_edit_form "$edit_name"
                ;;
            3)
                local -a menu_arr
                mapfile -t menu_arr < <(build_shares_menu)
                if [ ${#menu_arr[@]} -eq 0 ]; then
                    dialog --msgbox "No shares available" 6 50
                    continue
                fi
                local del_choice
                del_choice=$(dialog --menu "Select share to delete" 20 60 5 \
                    "${menu_arr[@]}" 2>&1 >/dev/tty) || continue
                local del_name
                del_name=$(get_section_by_index "$del_choice") || continue

                local del_mp
                del_mp=$(get_mountpoint "$del_name")

                if is_mounted "$del_mp"; then
                    dialog --msgbox "Error: '$del_name' is currently mounted.\nUnmount it before deleting." 8 60
                    continue
                fi

                if dialog --yesno "Delete share '$del_name'?" 7 50; then
                    rotate_config_backup
                    delete_section "$del_name" "$CONFIG_FILE"
                    dialog --msgbox "Share deleted successfully" 6 50
                fi
                ;;
            4|"") return 0 ;;
        esac
    done
}

# Dialog: Mount menu
dialog_menu_mount() {
    local -a menu_arr
    mapfile -t menu_arr < <(build_shares_menu "unmounted")

    if [ ${#menu_arr[@]} -eq 0 ]; then
        dialog --msgbox "All shares are already mounted\nor no shares are configured" 8 60
        return
    fi

    local choice
    choice=$(dialog --menu "Select share to mount" 20 60 5 \
        "${menu_arr[@]}" 2>&1 >/dev/tty) || return

    local mount_name
    mount_name=$(get_section_by_index "$choice" "unmounted") || return
    dialog_mount "$mount_name"
}

# Dialog: Unmount menu
dialog_menu_umount() {
    local -a menu_arr
    mapfile -t menu_arr < <(build_shares_menu "mounted")

    if [ ${#menu_arr[@]} -eq 0 ]; then
        dialog --msgbox "No shares are currently mounted" 6 50
        return
    fi

    local choice
    choice=$(dialog --menu "Select share to unmount" 20 60 5 \
        "${menu_arr[@]}" 2>&1 >/dev/tty) || return

    local umount_name
    umount_name=$(get_section_by_index "$choice" "mounted") || return
    dialog_umount "$umount_name"
}

# Validate file and show errors in a dialog; return 0 if valid
_validate_and_report() {
    local file="$1"
    local errors
    errors=$(validate_config "$file" 2>&1)
    if [ -n "$errors" ]; then
        dialog --msgbox "Configuration errors found:\n\n$errors" 20 70
        return 1
    fi
    return 0
}

# Dialog: Edit config file directly (nano if available, otherwise dialog --editbox)
dialog_edit_config() {
    if command -v nano &>/dev/null; then
        # Make a backup before letting the user edit freely
        local backup
        backup=$(mktemp "${CONFIG_FILE}.bak.XXXXXX")
        cp "$CONFIG_FILE" "$backup"

        rotate_config_backup
        nano "$CONFIG_FILE"

        # Validate after nano exits
        if ! _validate_and_report "$CONFIG_FILE"; then
            if dialog --yesno "The configuration has errors.\nRestore the previous backup?" 8 60; then
                cp "$backup" "$CONFIG_FILE"
                dialog --msgbox "Previous configuration restored." 6 50
            fi
        else
            dialog --msgbox "Configuration saved successfully." 6 50
        fi
        rm -f "$backup"
    else
        local temp_out
        temp_out=$(mktemp)
        dialog --editbox "$CONFIG_FILE" 0 0 2> "$temp_out"
        local rc=$?
        if [ $rc -eq 0 ]; then
            # Validate before overwriting
            if _validate_and_report "$temp_out"; then
                rotate_config_backup
                chmod 600 "$temp_out"
                mv "$temp_out" "$CONFIG_FILE"
                dialog --msgbox "Configuration saved successfully." 6 50
            else
                rm -f "$temp_out"
            fi
        else
            rm -f "$temp_out"
        fi
    fi
}

# Dialog: Main menu loop
dialog_main_menu() {
    check_dialog
    while true; do
        local choice
        choice=$(dialog --menu "Share Manager - CIFS/NFS/SSHFS" 20 60 6 \
            1 "Mount share" \
            2 "Unmount share" \
            3 "Share status" \
            4 "Manage bookmarks" \
            5 "Edit configuration file" \
            6 "Exit" \
            2>&1 >/dev/tty)

        case $choice in
            1) dialog_menu_mount ;;
            2) dialog_menu_umount ;;
            3) dialog_show_status ;;
            4) dialog_menu_bookmark ;;
            5) dialog_edit_config ;;
            6|"") clear; exit 0 ;;
        esac
    done
}

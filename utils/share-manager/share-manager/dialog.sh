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
        mp=$(get_field "$name" "mountpoint" "$CONFIG_FILE")
        [ -z "$mp" ] && mp="/mnt/shares/$name"
        type=$(get_field "$name" "type" "$CONFIG_FILE")
        type="${type:-cifs}"

        case "$filter" in
            mounted)   is_mounted "$mp" || continue ;;
            unmounted) is_mounted "$mp" && continue ;;
        esac

        local status
        status=$(get_status "$mp")
        printf '%s\n' "$index" "$name [$type] $status"
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
        mp=$(get_field "$name" "mountpoint" "$CONFIG_FILE")
        [ -z "$mp" ] && mp="/mnt/shares/$name"

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
    mp=$(get_field "$name" "mountpoint" "$CONFIG_FILE")
    [ -z "$mp" ] && mp="/mnt/shares/$name"

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
    mp=$(get_field "$name" "mountpoint" "$CONFIG_FILE")
    [ -z "$mp" ] && mp="/mnt/shares/$name"

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

        local mp host share type
        mp=$(get_field "$name" "mountpoint" "$CONFIG_FILE")
        [ -z "$mp" ] && mp="/mnt/shares/$name"
        host=$(get_field "$name" "host" "$CONFIG_FILE")
        share=$(get_field "$name" "share" "$CONFIG_FILE")
        type=$(get_field "$name" "type" "$CONFIG_FILE")
        type="${type:-cifs}"

        local icon
        if is_mounted "$mp"; then icon="✓"; else icon="✗"; fi

        status_text+="[$icon] $name ($type)\n"
        status_text+="    Host: $host\n"
        status_text+="    Share: $share\n"
        status_text+="    Mount: $mp\n\n"
    done <<< "$sections"

    dialog --msgbox "$status_text" 25 70
}

# Dialog: Add/edit share form
dialog_edit_form() {
    local edit_name="$1"

    local name="" type="cifs" host="" share="" username="" password="" options="" mountpoint=""

    if [ -n "$edit_name" ]; then
        name="$edit_name"
        type=$(get_field "$name" "type" "$CONFIG_FILE"); type="${type:-cifs}"
        host=$(get_field "$name" "host" "$CONFIG_FILE")
        share=$(get_field "$name" "share" "$CONFIG_FILE")
        username=$(get_field "$name" "username" "$CONFIG_FILE")
        password=$(get_field "$name" "password" "$CONFIG_FILE")
        options=$(get_field "$name" "options" "$CONFIG_FILE")
        mountpoint=$(get_field "$name" "mountpoint" "$CONFIG_FILE")
        [ -z "$mountpoint" ] && mountpoint="/mnt/shares/$name"
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
            dialog --form "$title" 20 70 6 \
                "Name:"        1 1 "$name"       1 20 30 0 \
                "Host:"        2 1 "$host"       2 20 30 0 \
                "Share:"       3 1 "$share"      3 20 30 0 \
                "Username:"    4 1 "$username"   4 20 30 0 \
                "Options:"     5 1 "$options"    5 20 30 0 \
                "Mount point:" 6 1 "$mountpoint" 6 20 40 0 \
                2> "$temp_file"
            ;;
        nfs)
            dialog --form "$title" 20 70 5 \
                "Name:"        1 1 "$name"       1 20 30 0 \
                "Host:"        2 1 "$host"       2 20 30 0 \
                "Export path:" 3 1 "$share"      3 20 30 0 \
                "Options:"     4 1 "$options"    4 20 30 0 \
                "Mount point:" 5 1 "$mountpoint" 5 20 40 0 \
                2> "$temp_file"
            ;;
        sshfs)
            dialog --form "$title" 20 70 6 \
                "Name:"        1 1 "$name"       1 20 30 0 \
                "Host:"        2 1 "$host"       2 20 30 0 \
                "Remote path:" 3 1 "$share"      3 20 30 0 \
                "Username:"    4 1 "$username"   4 20 30 0 \
                "Options:"     5 1 "$options"    5 20 30 0 \
                "Mount point:" 6 1 "$mountpoint" 6 20 40 0 \
                2> "$temp_file"
            ;;
    esac

    local result=$?
    if [ $result -ne 0 ]; then
        rm -f "$temp_file"
        return 1
    fi

    local form_data
    form_data=$(cat "$temp_file")
    rm -f "$temp_file"

    local new_name new_host new_share new_username new_options new_mountpoint
    case "$type" in
        cifs)
            IFS=$'\n' read -r new_name new_host new_share new_username new_options new_mountpoint <<< "$form_data"
            ;;
        nfs)
            IFS=$'\n' read -r new_name new_host new_share new_options new_mountpoint <<< "$form_data"
            new_username=""
            ;;
        sshfs)
            IFS=$'\n' read -r new_name new_host new_share new_username new_options new_mountpoint <<< "$form_data"
            ;;
    esac

    if [ -z "$new_name" ] || [ -z "$new_host" ] || [ -z "$new_share" ]; then
        dialog --msgbox "Error: Name, Host and Share are required" 7 60
        return 1
    fi

    local new_password=""
    if [ "$type" = "cifs" ]; then
        new_password=$(dialog --passwordbox "Password for '$new_name':" 8 50 2>&1 >/dev/tty)
        [ $? -ne 0 ] && return 1
    fi

    [ -z "$new_mountpoint" ] && new_mountpoint="/mnt/shares/$new_name"

    # Handle rename: unmount old share if needed
    if [ -n "$edit_name" ] && [ "$new_name" != "$edit_name" ]; then
        local old_mp
        old_mp=$(get_field "$edit_name" "mountpoint" "$CONFIG_FILE")
        [ -z "$old_mp" ] && old_mp="/mnt/shares/$edit_name"

        if is_mounted "$old_mp"; then
            if ! dialog --yesno "Share '$edit_name' is currently mounted.\nUnmount it before renaming?" 8 60; then
                dialog --msgbox "Operation cancelled" 6 50
                return 1
            fi
            dialog_umount "$edit_name" || return 1
        fi
    fi

    [ -n "$edit_name" ] && delete_section "$edit_name" "$CONFIG_FILE"

    add_section "$new_name" "$type" "$new_host" "$new_share" "$new_username" "$new_password" "$new_options" "$new_mountpoint" "$CONFIG_FILE"

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
                del_mp=$(get_field "$del_name" "mountpoint" "$CONFIG_FILE")
                [ -z "$del_mp" ] && del_mp="/mnt/shares/$del_name"

                if is_mounted "$del_mp"; then
                    dialog --msgbox "Error: '$del_name' is currently mounted.\nUnmount it before deleting." 8 60
                    continue
                fi

                if dialog --yesno "Delete share '$del_name'?" 7 50; then
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

# Dialog: Main menu loop
dialog_main_menu() {
    check_dialog
    while true; do
        local choice
        choice=$(dialog --menu "Share Manager - CIFS/NFS/SSHFS" 20 60 5 \
            1 "Mount share" \
            2 "Unmount share" \
            3 "Share status" \
            4 "Manage bookmarks" \
            5 "Exit" \
            2>&1 >/dev/tty)

        case $choice in
            1) dialog_menu_mount ;;
            2) dialog_menu_umount ;;
            3) dialog_show_status ;;
            4) dialog_menu_bookmark ;;
            5|"") clear; exit 0 ;;
        esac
    done
}

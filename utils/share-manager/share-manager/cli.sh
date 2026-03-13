#!/bin/bash

# cli.sh - CLI commands: list, mount, umount, status

list_shares() {
    echo "Available shares:"
    echo "-----------------"

    local sections
    sections=$(get_sections "$CONFIG_FILE")

    if [ -z "$sections" ]; then
        echo "No shares configured"
        return
    fi

    while read -r name; do
        [ -z "$name" ] && continue

        local mp type
        mp=$(get_field "$name" "mountpoint" "$CONFIG_FILE")
        [ -z "$mp" ] && mp="/mnt/shares/$name"
        type=$(get_field "$name" "type" "$CONFIG_FILE")
        type="${type:-cifs}"

        local status
        if is_mounted "$mp"; then
            status="✓ Mounted"
        else
            status="✗ Not mounted"
        fi

        printf "%-20s %-6s %s\n" "$name" "[$type]" "$status"
    done <<< "$sections"
}

mount_share() {
    local share_name="$1"

    if [ -z "$share_name" ]; then
        echo -e "${RED}Error: specify a share name${NC}"
        exit 1
    fi

    if ! section_exists "$share_name" "$CONFIG_FILE"; then
        echo -e "${RED}Error: share '$share_name' not found in configuration${NC}"
        echo "Use '$(basename "$0") list' to see available shares"
        exit 1
    fi

    do_mount "$share_name" || {
        echo -e "${RED}Error: failed to mount '$share_name'${NC}"
        exit 1
    }

    echo -e "${GREEN}Share '$share_name' mounted successfully${NC}"
}

umount_share() {
    local share_name="$1"

    if [ -z "$share_name" ]; then
        echo -e "${RED}Error: specify a share name${NC}"
        exit 1
    fi

    if ! section_exists "$share_name" "$CONFIG_FILE"; then
        echo -e "${RED}Error: share '$share_name' not found in configuration${NC}"
        exit 1
    fi

    do_umount "$share_name" || {
        echo -e "${RED}Error: failed to unmount '$share_name'${NC}"
        exit 1
    }

    echo -e "${GREEN}Share '$share_name' unmounted successfully${NC}"
}

check_status() {
    local share_name="$1"

    if [ -z "$share_name" ]; then
        echo -e "${RED}Error: specify a share name${NC}"
        exit 1
    fi

    if ! section_exists "$share_name" "$CONFIG_FILE"; then
        echo -e "${RED}Error: share '$share_name' not found in configuration${NC}"
        exit 1
    fi

    local mp
    mp=$(get_field "$share_name" "mountpoint" "$CONFIG_FILE")
    [ -z "$mp" ] && mp="/mnt/shares/$share_name"

    if is_mounted "$mp"; then
        echo "Share '$share_name' is mounted at $mp"
        findmnt -n "$mp" 2>/dev/null || mount | grep "$mp" | tail -1
    else
        echo "Share '$share_name' is not mounted"
    fi
}

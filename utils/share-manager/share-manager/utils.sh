#!/bin/bash

# utils.sh - Common utility functions

# Check if a mountpoint is currently mounted
is_mounted() {
    local mount_point="$1"
    findmnt -rn "$mount_point" >/dev/null 2>&1
}

# Return a human-readable status string for a share
get_status() {
    local mp="$1"
    if is_mounted "$mp"; then
        echo "[MOUNTED]"
    else
        echo "[not mounted]"
    fi
}

# Check required dependencies based on configured share types
check_dependencies() {
    local missing=()

    if ! command -v findmnt &>/dev/null; then
        missing+=("findmnt (util-linux)")
    fi

    # Check type-specific tools only for types actually configured
    local types_used
    types_used=$(get_sections "$CONFIG_FILE" | while read -r s; do
        local t
        t=$(get_field "$s" "type" "$CONFIG_FILE")
        echo "${t:-cifs}"
    done | sort -u)

    if echo "$types_used" | grep -q "cifs"; then
        if ! command -v mount.cifs &>/dev/null; then
            missing+=("cifs-utils (for CIFS mounts)")
        fi
    fi

    if echo "$types_used" | grep -q "nfs"; then
        if ! command -v mount.nfs &>/dev/null && ! command -v showmount &>/dev/null; then
            missing+=("nfs-common (for NFS mounts)")
        fi
    fi

    if echo "$types_used" | grep -q "sshfs"; then
        if ! command -v sshfs &>/dev/null; then
            missing+=("sshfs (for SSHFS mounts)")
        fi
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Error: the following programs are not installed:${NC}"
        for prog in "${missing[@]}"; do
            echo "  - $prog"
        done
        exit 1
    fi
}

# Check that dialog is available
check_dialog() {
    if ! command -v dialog &>/dev/null; then
        echo -e "${RED}Error: 'dialog' is not installed${NC}"
        echo "Install with: sudo apt install dialog"
        exit 1
    fi
}

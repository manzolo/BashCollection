#!/bin/bash

# config.sh - INI parser and config file management

# Resolve real user home (works correctly with sudo)
_resolve_user_home() {
    if [ -n "$SUDO_USER" ]; then
        getent passwd "$SUDO_USER" | cut -d: -f6
    else
        echo "$HOME"
    fi
}

CONFIG_TEMPLATE='# manzolo-share-manager configuration
# Format: INI sections — one [section] per share
#
# Available fields:
#   type       - Protocol: cifs | nfs | sshfs  (default: cifs)
#   host       - Hostname or IP address of the remote server
#   share      - Share name (CIFS), export path (NFS), or remote path (SSHFS)
#   username   - Login username  (CIFS and SSHFS only; ignored for NFS)
#   password   - Login password  (CIFS only; ignored for NFS and SSHFS)
#   options    - Extra mount options, comma-separated (optional)
#   mountpoint - Local directory where the share will be mounted
#
# ─────────────────────────────────────────────────────────────────────────────
# CIFS (Windows / Samba) example
# Requires: cifs-utils   →   sudo apt install cifs-utils
# ─────────────────────────────────────────────────────────────────────────────
#
# [myshare]
# type=cifs
# host=fileserver.lan
# share=documents
# username=myuser
# password=mypassword
# options=vers=3.0
# mountpoint=/mnt/shares/myshare
#
# ─────────────────────────────────────────────────────────────────────────────
# NFS (Network File System) example
# Requires: nfs-common   →   sudo apt install nfs-common
# Note: username and password are not used for NFS
# ─────────────────────────────────────────────────────────────────────────────
#
# [backup]
# type=nfs
# host=192.168.1.100
# share=/volume1/backup
# options=vers=4,rw
# mountpoint=/mnt/shares/backup
#
# ─────────────────────────────────────────────────────────────────────────────
# SSHFS (SSH Filesystem) example
# Requires: sshfs   →   sudo apt install sshfs
# Note: uses SSH key authentication; password field is not used
# ─────────────────────────────────────────────────────────────────────────────
#
# [docs]
# type=sshfs
# host=192.168.1.100
# share=/home/user/docs
# username=user
# options=
# mountpoint=/mnt/shares/docs
'

init_config() {
    local user_home
    user_home=$(_resolve_user_home)

    CONFIG_DIR="$user_home/.config/manzolo-share-manager"
    CONFIG_FILE="$CONFIG_DIR/shares.conf"

    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
        chmod 700 "$CONFIG_DIR"
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        printf '%s' "$CONFIG_TEMPLATE" > "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        echo "Created configuration file: $CONFIG_FILE"
    fi
}

# Get all section names
get_sections() {
    local file="${1:-$CONFIG_FILE}"
    [ ! -f "$file" ] && return
    grep -E '^\[[a-zA-Z0-9_-]+\]$' "$file" | sed 's/\[//g; s/\]//g'
}

# Get a field value from a section
get_field() {
    local section="$1"
    local key="$2"
    local file="${3:-$CONFIG_FILE}"

    [ ! -f "$file" ] && return 1

    awk -v section="$section" -v key="$key" '
        /^\[/ { current_section = $0; gsub(/\[|\]/, "", current_section) }
        current_section == section && $0 ~ key "=" {
            idx = index($0, "=")
            field_key = substr($0, 1, idx - 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", field_key)
            if (field_key == key) {
                value = substr($0, idx + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                print value
                exit 0
            }
        }
    ' "$file"
}

# Set a field value in a section (atomic write)
set_field() {
    local section="$1"
    local key="$2"
    local value="$3"
    local file="${4:-$CONFIG_FILE}"

    [ ! -f "$file" ] && return 1

    local tmpfile
    tmpfile=$(mktemp "${file}.XXXXXX") || return 1

    awk -v section="$section" -v key="$key" -v newval="$value" '
        /^\[/ { current_section = $0; gsub(/\[|\]/, "", current_section); print $0; next }
        current_section == section && $0 ~ key "=" {
            idx = index($0, "=")
            field_key = substr($0, 1, idx - 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", field_key)
            if (field_key == key) { print key "=" newval; found = 1; next }
        }
        { print }
        END { if (!found && current_section == section) { print key "=" newval } }
    ' "$file" > "$tmpfile"

    chmod 600 "$tmpfile"
    mv "$tmpfile" "$file"
}

# Add a new section
add_section() {
    local name="$1"
    local type="$2"
    local host="$3"
    local share="$4"
    local username="$5"
    local password="$6"
    local options="${7:-}"
    local mountpoint="${8:-}"
    local file="${9:-$CONFIG_FILE}"

    [ ! -f "$file" ] && return 1
    [ -z "$mountpoint" ] && mountpoint="/mnt/shares/$name"

    local tmpfile
    tmpfile=$(mktemp "${file}.XXXXXX") || return 1
    cp "$file" "$tmpfile"

    {
        echo ""
        echo "[$name]"
        echo "type=$type"
        echo "host=$host"
        echo "share=$share"
        [ "$type" != "nfs" ] && echo "username=$username"
        [ "$type" = "cifs" ] && echo "password=$password"
        echo "options=$options"
        echo "mountpoint=$mountpoint"
    } >> "$tmpfile"

    chmod 600 "$tmpfile"
    mv "$tmpfile" "$file"
}

# Delete a section
delete_section() {
    local section="$1"
    local file="${2:-$CONFIG_FILE}"

    [ ! -f "$file" ] && return 1

    local tmpfile
    tmpfile=$(mktemp "${file}.XXXXXX") || return 1

    awk -v section="$section" '
        /^\[/ { current_section = $0; gsub(/\[|\]/, "", current_section) }
        current_section == section { next }
        { print }
    ' "$file" > "$tmpfile"

    chmod 600 "$tmpfile"
    mv "$tmpfile" "$file"
}

# Check if a section exists
section_exists() {
    local section="$1"
    local file="${2:-$CONFIG_FILE}"

    [ ! -f "$file" ] && return 1
    get_sections "$file" | grep -qx "$section"
}

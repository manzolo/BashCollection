#!/bin/bash

# mount.sh - Mount/unmount dispatcher for CIFS, NFS, SSHFS

_mount_cifs() {
    local name="$1" host="$2" share="$3" username="$4" password="$5" options="$6" mp="$7"

    local opts="username=$username,password=$password"
    [ -n "$options" ] && opts="$opts,$options"

    sudo mount -t cifs "//${host}/${share}" "$mp" -o "$opts" || return 1
}

_mount_nfs() {
    local name="$1" host="$2" share="$3" options="$6" mp="$7"

    local cmd="sudo mount -t nfs ${host}:${share} ${mp}"
    [ -n "$options" ] && cmd="$cmd -o $options"

    eval "$cmd" || return 1
}

_mount_sshfs() {
    local name="$1" host="$2" share="$3" username="$4" options="$6" mp="$7"

    local cmd="sshfs ${username}@${host}:${share} ${mp}"
    [ -n "$options" ] && cmd="$cmd -o $options"

    eval "$cmd" || return 1
}

# Main mount dispatcher
do_mount() {
    local name="$1"

    local type host share username password options mp
    type=$(get_field "$name" "type" "$CONFIG_FILE")
    type="${type:-cifs}"
    host=$(get_field "$name" "host" "$CONFIG_FILE")
    share=$(get_field "$name" "share" "$CONFIG_FILE")
    username=$(get_field "$name" "username" "$CONFIG_FILE")
    password=$(get_field "$name" "password" "$CONFIG_FILE")
    options=$(get_field "$name" "options" "$CONFIG_FILE")
    mp=$(get_field "$name" "mountpoint" "$CONFIG_FILE")
    [ -z "$mp" ] && mp="/mnt/shares/$name"

    if [ ! -d "$mp" ]; then
        echo "Creating mount directory: $mp"
        sudo mkdir -p "$mp" || {
            echo -e "${RED}Error: cannot create $mp${NC}"
            return 1
        }
    fi

    if is_mounted "$mp"; then
        echo "Share '$name' is already mounted at $mp"
        return 0
    fi

    echo "Mounting '$name' ($type) at $mp..."

    case "$type" in
        cifs)  _mount_cifs  "$name" "$host" "$share" "$username" "$password" "$options" "$mp" ;;
        nfs)   _mount_nfs   "$name" "$host" "$share" "$username" "$password" "$options" "$mp" ;;
        sshfs) _mount_sshfs "$name" "$host" "$share" "$username" "$password" "$options" "$mp" ;;
        *)
            echo -e "${RED}Error: unsupported type: $type${NC}"
            return 1
            ;;
    esac
}

# Unmount a share
do_umount() {
    local name="$1"

    local mp
    mp=$(get_field "$name" "mountpoint" "$CONFIG_FILE")
    [ -z "$mp" ] && mp="/mnt/shares/$name"

    if ! is_mounted "$mp"; then
        echo "Share '$name' is not mounted"
        return 0
    fi

    echo "Unmounting '$name' from $mp..."
    local type
    type=$(get_field "$name" "type" "$CONFIG_FILE")
    type="${type:-cifs}"

    if [ "$type" = "sshfs" ]; then
        fusermount -u "$mp" || sudo umount "$mp" || return 1
    else
        sudo umount "$mp" || return 1
    fi
}

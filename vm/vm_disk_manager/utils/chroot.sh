#!/bin/bash

# Run a chroot in an isolated mount namespace
run_chroot_isolated() {
    local root="$1"

    if [ ! -d "$root" ]; then
        whiptail --msgbox "Invalid root directory: $root" 8 60
        return 1
    fi

    if ! command -v unshare >/dev/null 2>&1; then
        whiptail --msgbox "'unshare' command not found.\nPlease install util-linux." 10 60
        return 1
    fi

    # Define preferred shells in order of preference
    local preferred_shells=("/bin/bash" "/usr/bin/bash" "/bin/sh" "/usr/bin/sh")
    local shell_path=""

    # Check for the first available shell in the chroot
    for shell in "${preferred_shells[@]}"; do
        if [ -x "$root$shell" ]; then
            shell_path="$shell"
            break
        fi
    done

    # If no suitable shell was found, exit
    if [ -z "$shell_path" ]; then
        whiptail --msgbox "No suitable shell found in $root.\nExpected one of: ${preferred_shells[*]}" 12 70
        return 1
    fi

    unshare -m bash -c "
        set -e
        mount --make-rprivate /

        # Ensure required mountpoints exist
        for d in proc sys dev dev/pts run; do
            [ -d '$root/'\$d ] || mkdir -p '$root/'\$d
        done

        # Bind required filesystems
        mountpoint -q '$root/proc'    2>/dev/null || mount -t proc  proc  '$root/proc'
        mountpoint -q '$root/sys'     2>/dev/null || mount -t sysfs sys   '$root/sys'
        mountpoint -q '$root/dev'     2>/dev/null || mount --bind /dev   '$root/dev'
        mountpoint -q '$root/dev/pts' 2>/dev/null || mount -t devpts devpts '$root/dev/pts'
        mountpoint -q '$root/run'     2>/dev/null || mount --bind /run   '$root/run'

        # Cleanup on exit
        cleanup_mounts() {
            umount -l '$root/run'     2>/dev/null || true
            umount -l '$root/dev/pts' 2>/dev/null || true
            umount -l '$root/dev'     2>/dev/null || true
            umount -l '$root/sys'     2>/dev/null || true
            umount -l '$root/proc'    2>/dev/null || true
        }
        trap cleanup_mounts EXIT

        echo 'Entering isolated chroot...'
        exec chroot '$root' '$shell_path' -l
    "
}
connect_nbd() {
    local disk_image="$1"
    local device

    # Ensure nbd module is loaded
    if ! lsmod | grep -q "^nbd "; then
        log "Loading nbd kernel module..." >&2
        sudo modprobe nbd max_part=8 || { error "Failed to load nbd kernel module" >&2; return 1; }
    fi

    # Find an available NBD device
    for i in $(seq 0 15); do
        device="/dev/nbd${i}"
        if sudo qemu-nbd -c "${device}" "${disk_image}" 2>/dev/null; then
            log "Connected ${disk_image} to ${device}" >&2
            udevadm settle >/dev/null 2>&1
            sleep 1
            echo "${device}"
            return 0
        fi
    done

    error "No available NBD devices found" >&2
    return 1
}
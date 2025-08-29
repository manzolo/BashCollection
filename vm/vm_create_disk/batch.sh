# Main function for non-interactive mode
non_interactive_mode() {
    local CONFIG_FILE=$1
    if [ ! -f "${CONFIG_FILE}" ]; then
        error "Configuration file '${CONFIG_FILE}' not found."
        exit 1
    fi

    source "${CONFIG_FILE}"

    if [ -z "${DISK_NAME}" ] || [ -z "${DISK_SIZE}" ] || [ -z "${DISK_FORMAT}" ]; then
        error "Required variables (DISK_NAME, DISK_SIZE, DISK_FORMAT) are missing in the config file."
        exit 1
    fi

    PARTITION_TABLE=${PARTITION_TABLE:-"mbr"}
    PREALLOCATION=${PREALLOCATION:-"off"}

    # Validate PARTITIONS array format
    for part in "${PARTITIONS[@]}"; do
        if [[ ! "$part" =~ ^[^:]+:[^:]*(:[^:]+)?$ ]]; then
            error "Invalid partition format in config: $part"
            exit 1
        fi
    done

    log "Using configuration from: $CONFIG_FILE"
    create_and_format_disk
}
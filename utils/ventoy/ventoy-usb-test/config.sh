#!/bin/bash

# Save configuration
save_config() {
    cat > "$CONFIG_FILE" << EOF
MEMORY="$MEMORY"
CORES="$CORES"
THREADS="$THREADS"
SOCKETS="$SOCKETS"
DISK="$DISK"
FORMAT="$FORMAT"
BIOS_MODE="$BIOS_MODE"
VGA_MODE="$VGA_MODE"
NETWORK=$NETWORK
SOUND=$SOUND
USB_VERSION="$USB_VERSION"
EOF
    log_info "Configuration saved to $CONFIG_FILE"
}

# Load saved configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_info "Configuration loaded from $CONFIG_FILE"
    fi
}

# Reset configuration to defaults
reset_to_defaults() {
    MEMORY="2048"
    CORES="4"
    THREADS="1"
    SOCKETS="1"
    MACHINE_TYPE="q35"
    DISK=""
    FORMAT="raw"
    BIOS_MODE="uefi"
    VGA_MODE="virtio"
    NETWORK=false
    SOUND=false
    USB_VERSION="3.0"
}
# Initial comprehensive checks
initial_checks() {
    # Fundamental checks
    check_dependencies

    # Resolve a usable OVMF path if the compiled-in default is absent
    # (distros vary: combined OVMF.fd vs split OVMF_CODE/OVMF_VARS).
    ovmf_autodetect_default || true

    # Inherit X11 credentials from invoking user when running under sudo,
    # otherwise QEMU's GTK display fails with an X authorization error.
    setup_x11_for_root

    # Welcome banner
    whiptail --title "Welcome" --msgbox \
        "$SCRIPT_NAME v$VERSION\n\nInteractive script for testing bootable USB/ISO media\nwith UEFI and BIOS Legacy support." \
        12 60
    
    # Load configuration if it exists
    load_config
    
    # Setup logging
    mkdir -p "$LOG_DIR"
    log_info "$SCRIPT_NAME v$VERSION started"
    log_info "Log directory: $LOG_DIR"
}
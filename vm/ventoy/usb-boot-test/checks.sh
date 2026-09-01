# shellcheck shell=bash
# Start-up checks for the interactive TUI.
initial_checks() {
    check_dependencies

    # Resolve a usable OVMF path if the compiled-in default is absent
    # (distros vary: combined OVMF.fd vs split OVMF_CODE/OVMF_VARS).
    ovmf_autodetect_default || true

    # Inherit X11 credentials from invoking user when running under sudo,
    # otherwise QEMU's GTK display fails with an X authorization error.
    setup_x11_for_root

    mkdir -p "$LOG_DIR"
    load_config
    log_info "$SCRIPT_NAME v$VERSION started — logs in $LOG_DIR"
}

# Help function
show_help() {
    cat << EOF
Advanced Interactive Chroot Script

Usage: ./$SCRIPT_NAME [OPTIONS]

Options:
    -c, --config FILE    Use configuration file
    -q, --quiet          Quiet mode (no interactive dialogs)
    -d, --debug          Enable debug mode
    -h, --help           Show this help message

Configuration file format:
    ROOT_DEVICE=/dev/sdaX
    ROOT_MOUNT=/mnt/chroot
    EFI_PART=/dev/sdaY
    BOOT_PART=/dev/sdaZ
    ADDITIONAL_MOUNTS=(/dev/sda1:/home /dev/sda2:/var)
    CUSTOM_SHELL=/bin/zsh
    PRESERVE_ENV=true
    ENABLE_GUI_SUPPORT=true
    CHROOT_USER=manzolo

Examples:
    ./$SCRIPT_NAME                    # Interactive mode
    ./$SCRIPT_NAME -q -c config.conf  # Quiet mode with config
    ./$SCRIPT_NAME -d                 # Debug mode

EOF
}
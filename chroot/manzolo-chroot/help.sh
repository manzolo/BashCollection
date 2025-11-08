show_help() {
    cat << EOF
Unified Advanced Interactive Chroot Script

Usage: $SCRIPT_NAME [OPTIONS]

Options:
    -c, --config FILE    Use configuration file
    -q, --quiet          Quiet mode (no interactive dialogs)
    -d, --debug          Enable debug mode
    -v, --virtual FILE   Direct virtual image mode
    -h, --help           Show this help message

Configuration file format:
    # For physical disk mode:
    ROOT_DEVICE=/dev/sdaX
    ROOT_MOUNT=/mnt/chroot
    EFI_PART=/dev/sdaY
    BOOT_PART=/dev/sdaZ
    
    # For virtual disk mode:
    VIRTUAL_IMAGE=/path/to/image.vhd
    
    # Common options:
    ADDITIONAL_MOUNTS=(/dev/sda1:/home /dev/sda2:/var)
    CUSTOM_SHELL=/bin/zsh
    PRESERVE_ENV=true
    ENABLE_GUI_SUPPORT=true
    CHROOT_USER=username

Examples:
    $SCRIPT_NAME                           # Interactive mode
    $SCRIPT_NAME -v disk.vhd               # Virtual disk mode
    $SCRIPT_NAME -q -c config.conf         # Quiet mode with config
    $SCRIPT_NAME -d                        # Debug mode

EOF
}
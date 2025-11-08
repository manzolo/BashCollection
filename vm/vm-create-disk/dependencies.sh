# Check for required dependencies with detailed error messages
check_dependencies() {
    local missing_tools=()
    local optional_tools=()
    
    # Critical tools
    command -v qemu-img >/dev/null || missing_tools+=("qemu-img (qemu-utils package)")
    command -v parted >/dev/null || missing_tools+=("parted")
    command -v mkfs.ext4 >/dev/null || missing_tools+=("mkfs.ext4 (e2fsprogs package)")
    command -v qemu-nbd >/dev/null || missing_tools+=("qemu-nbd (qemu-utils package)")
    command -v bc >/dev/null || missing_tools+=("bc")
    
    # Optional but recommended tools
    command -v mkfs.xfs >/dev/null || optional_tools+=("mkfs.xfs (xfsprogs package)")
    command -v mkfs.ntfs >/dev/null || optional_tools+=("mkfs.ntfs (ntfs-3g package)")
    command -v mkfs.vfat >/dev/null || optional_tools+=("mkfs.vfat (dosfstools package)")
    command -v mkfs.btrfs >/dev/null || optional_tools+=("mkfs.btrfs (btrfs-progs package)")
    command -v whiptail >/dev/null || optional_tools+=("whiptail (whiptail or newt package)")
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools:"
        for tool in "${missing_tools[@]}"; do
            log_error "  - $tool"
        done
        return 1
    fi
    
    if [ ${#optional_tools[@]} -gt 0 ]; then
        log_warn "Missing optional tools (some filesystem types may not be available):"
        for tool in "${optional_tools[@]}"; do
            log_warn "  - $tool"
        done
    fi
    
    return 0
}
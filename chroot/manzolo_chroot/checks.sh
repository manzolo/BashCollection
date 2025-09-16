check_system_requirements() {
    log "Checking system requirements"
    
    local missing_tools=()
    local required_tools=(
        "lsblk"
        "mount" 
        "umount"
        "chroot"
        "mountpoint"
        "findmnt"
    )
    
    # Additional tools for virtual mode
    if [[ "$VIRTUAL_MODE" == true ]]; then
        required_tools+=("qemu-nbd" "fdisk" "cryptsetup" "pvs" "vgs" "lvs")
    fi
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing_tools[*]}"
        
        if command -v apt &> /dev/null; then
            log "Attempting to install missing tools via apt"
            run_with_privileges apt update
            run_with_privileges apt install -y util-linux coreutils qemu-utils cryptsetup lvm2
        elif command -v yum &> /dev/null; then
            log "Attempting to install missing tools via yum"
            run_with_privileges yum install -y util-linux coreutils qemu-img cryptsetup lvm2
        elif command -v pacman &> /dev/null; then
            log "Attempting to install missing tools via pacman"
            run_with_privileges pacman -S --noconfirm util-linux coreutils qemu cryptsetup lvm2
        fi
        
        # Recheck
        missing_tools=()
        for tool in "${required_tools[@]}"; do
            if ! command -v "$tool" &> /dev/null; then
                missing_tools+=("$tool")
            fi
        done
        
        if [[ ${#missing_tools[@]} -gt 0 ]]; then
            error "Still missing required tools after installation attempt: ${missing_tools[*]}"
            exit 1
        fi
    fi
    
    # Check for NBD module if virtual mode
    if [[ "$VIRTUAL_MODE" == true ]]; then
        if ! lsmod | grep -q nbd; then
            log "Loading nbd module..."
            run_with_privileges modprobe nbd max_part=16 || {
                error "Cannot load nbd module"
                exit 1
            }
        fi
    fi
    
    # Install dialog if needed for interactive mode
    if [[ "$QUIET_MODE" == false ]] && ! command -v dialog &> /dev/null; then
        log "Installing dialog package for interactive mode"
        if command -v apt &> /dev/null; then
            run_with_privileges apt update && run_with_privileges apt install -y dialog
        elif command -v yum &> /dev/null; then
            run_with_privileges yum install -y dialog
        elif command -v pacman &> /dev/null; then
            run_with_privileges pacman -S --noconfirm dialog
        fi
    fi
    
    log "System requirements check completed"
}
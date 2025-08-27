# Check and unmount a device if it's already mounted
check_and_unmount() {
    local device="$1"
    local mountpoint
    
    mountpoint=$(findmnt --noheadings --output TARGET --source "$device" 2>/dev/null || true)

    if [[ -n "$mountpoint" ]]; then
        log "Device $device is already mounted at $mountpoint"
        if [[ "$QUIET_MODE" == false ]]; then
            if dialog --title "Warning: Device Already Mounted" --yesno "The device $device is already mounted at $mountpoint.\nDo you want to unmount it before proceeding?" 10 60; then
                log "Attempting to unmount $device from $mountpoint"
                
                if ! run_with_privileges umount "$mountpoint" 2>/dev/null; then
                    warning "Normal unmount failed, checking for processes"
                    
                    if ! terminate_processes_gracefully "$mountpoint"; then
                        warning "Could not terminate all processes gracefully"
                    fi
                    
                    if ! run_with_privileges umount "$mountpoint" 2>/dev/null; then
                        error "Failed to unmount $device. Trying lazy unmount."
                        if dialog --title "Unmount Error" --yesno "Unmount failed. Try a lazy unmount?" 10 60; then
                            if run_with_privileges umount -l "$mountpoint" 2>/dev/null; then
                                log "Successfully lazy unmounted $device."
                                return 0
                            else
                                error "Failed to lazy unmount $device. Manual intervention may be required."
                                dialog --title "Critical Error" --msgbox "Could not unmount the device. Please unmount it manually and try again." 10 60
                                return 1
                            fi
                        else
                            log "Unmount cancelled by user. Exiting."
                            return 1
                        fi
                    fi
                fi
                log "Successfully unmounted $device"
                return 0
            else
                log "Unmount cancelled by user. Exiting."
                return 1
            fi
        fi
    fi
    return 0
}

# Validate filesystem
validate_filesystem() {
    local device="$1"
    local fstype
    
    debug "Validating filesystem on $device"
    
    fstype=$(lsblk -no FSTYPE "$device" 2>/dev/null || echo "")
    
    if [[ -z "$fstype" ]] || [[ "$fstype" == "unknown" ]]; then
        debug "lsblk returned '$fstype', trying blkid"
        fstype=$(blkid -o value -s TYPE "$device" 2>/dev/null || echo "")
    fi
    
    if [[ -z "$fstype" ]] || [[ "$fstype" == "unknown" ]]; then
        debug "blkid failed, trying file command"
        local file_output
        file_output=$(file -s "$device" 2>/dev/null || echo "")
        
        case "$file_output" in
            *"ext2 filesystem"*) fstype="ext2" ;;
            *"ext3 filesystem"*) fstype="ext3" ;;
            *"ext4 filesystem"*) fstype="ext4" ;;
            *"XFS filesystem"*) fstype="xfs" ;;
            *"BTRFS filesystem"*) fstype="btrfs" ;;
            *"F2FS filesystem"*) fstype="f2fs" ;;
            *"FAT"*) fstype="vfat" ;;
        esac
    fi
    
    debug "Detected filesystem type: $fstype"
    
    case "$fstype" in
        ext2|ext3|ext4|xfs|btrfs|f2fs)
            debug "Valid Linux filesystem detected: $fstype"
            return 0
            ;;
        vfat|fat32|fat16)
            if [[ "$device" == "$EFI_PART" ]]; then
                debug "Valid EFI filesystem: $fstype"
                return 0
            else
                debug "FAT filesystem on non-EFI device: $fstype"
                if [[ "$QUIET_MODE" == false ]]; then
                    if dialog --title "Warning" --yesno "Device $device has FAT filesystem ($fstype).\nThis is unusual for a root filesystem.\nProceed anyway?" 10 60; then
                        return 0
                    else
                        return 1
                    fi
                fi
            fi
            ;;
        ntfs)
            error "NTFS filesystem detected. Cannot chroot into Windows partition."
            return 1
            ;;
        ""|unknown)
            debug "Could not determine filesystem type for $device"
            if [[ "$QUIET_MODE" == false ]]; then
                if dialog --title "Warning" --yesno "Cannot determine filesystem type for $device.\nThis might indicate:\n- Encrypted partition\n- Corrupted filesystem\n- Unsupported filesystem\n\nProceed anyway? (Risk of mount failure)" 12 70; then
                    return 0
                else
                    return 1
                fi
            else
                warning "Unknown filesystem type for $device, proceeding anyway"
                return 0
            fi
            ;;
        *)
            error "Unsupported filesystem: $fstype on $device"
            if [[ "$QUIET_MODE" == false ]]; then
                dialog --title "Error" --msgbox "Unsupported filesystem: $fstype\nDevice: $device\n\nSupported filesystems:\n- ext2/ext3/ext4\n- xfs, btrfs, f2fs\n- vfat (for EFI)" 12 60
            fi
            return 1
            ;;
    esac
}

# Function to check system requirements and install missing tools
check_system_requirements() {
    log "Checking system requirements"
    
    local missing_tools=()
    local optional_tools=()
    
    local required_tools=(
        "lsblk"
        "mount" 
        "umount"
        "chroot"
        "mountpoint"
        "findmnt"
    )
    
    local recommended_tools=(
        "fuser"
        "lsof"
        "blkid"
        "file"
        "xhost"
    )
    
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
            for tool in "${missing_tools[@]}"; do
                case "$tool" in
                    "lsblk"|"mount"|"umount"|"mountpoint"|"findmnt") 
                        run_with_privileges apt install -y util-linux ;;
                    "chroot") 
                        run_with_privileges apt install -y coreutils ;;
                esac
            done
        elif command -v yum &> /dev/null; then
            log "Attempting to install missing tools via yum"
            for tool in "${missing_tools[@]}"; do
                case "$tool" in
                    "lsblk"|"mount"|"umount"|"mountpoint"|"findmnt") 
                        run_with_privileges yum install -y util-linux ;;
                    "chroot") 
                        run_with_privileges yum install -y coreutils ;;
                esac
            done
        elif command -v pacman &> /dev/null; then
            log "Attempting to install missing tools via pacman"
            for tool in "${missing_tools[@]}"; do
                case "$tool" in
                    "lsblk"|"mount"|"umount"|"mountpoint"|"findmnt") 
                        run_with_privileges pacman -S --noconfirm util-linux ;;
                    "chroot") 
                        run_with_privileges pacman -S --noconfirm coreutils ;;
                esac
            done
        fi
        
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
    
    for tool in "${recommended_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            optional_tools+=("$tool")
        fi
    done
    
    if [[ ${#optional_tools[@]} -gt 0 ]]; then
        warning "Missing optional tools (some features may be limited): ${optional_tools[*]}"
    fi
    
    if [[ "$QUIET_MODE" == false ]] && ! command -v dialog &> /dev/null; then
        log "Installing dialog package for interactive mode"
        if command -v apt &> /dev/null; then
            run_with_privileges apt update && run_with_privileges apt install -y dialog
        elif command -v yum &> /dev/null; then
            run_with_privileges yum install -y dialog
        elif command -v pacman &> /dev/null; then
            run_with_privileges pacman -S --noconfirm dialog
        elif command -v zypper &> /dev/null; then
            run_with_privileges zypper install -y dialog
        else
            error "dialog not found and no supported package manager detected"
            exit 1
        fi
    fi
    
    log "System requirements check completed"
}

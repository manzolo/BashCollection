interactive_mode() {
    if [[ "$QUIET_MODE" == false ]] && ! command -v dialog &> /dev/null; then
        error "Dialog not available for interactive mode"
        exit 1
    fi
    
    # Ask the user what type of chroot they want
    local chroot_type
    if chroot_type=$(dialog --title "Chroot Type Selection" \
                           --menu "Select the type of chroot environment:" \
                           15 60 4 \
                           "physical" "Physical disk/partition chroot" \
                           "image" "Virtual disk image chroot" \
                           3>&1 1>&2 2>&3); then
        case "$chroot_type" in
            "image")
                VIRTUAL_MODE=true
                log "Virtual disk image mode selected"
                
                # Select virtual image file
                VIRTUAL_IMAGE=$(select_image_file)
                if [[ $? -ne 0 ]] || [[ -z "$VIRTUAL_IMAGE" ]]; then
                    error "No image file selected"
                    exit 1
                fi
                
                log "Selected virtual image: $VIRTUAL_IMAGE"
                ;;
            "physical")
                VIRTUAL_MODE=false
                log "Physical disk mode selected"
                
                # Select root device
                if ! ROOT_DEVICE=$(select_device "Root" false); then
                    error "No root device selected or operation cancelled"
                    exit 1
                fi
                ;;
            *)
                error "Unknown chroot type selected"
                exit 1
                ;;
        esac
    else
        error "No chroot type selected or operation cancelled"
        exit 1
    fi
    
    # Common options for both modes
    if dialog --title "Graphical Support" \
              --defaultno --yesno "Do you need to run graphical applications (X11/Wayland) inside the chroot?\n\nThis will setup display variables and authentication files." 10 60; then
        ENABLE_GUI_SUPPORT=true
        local chroot_user
        chroot_user=$(dialog --title "Chroot User" \
                            --inputbox "Enter the user to run GUI apps as in chroot (default: root):" \
                            10 50 "$ORIGINAL_USER" 3>&1 1>&2 2>&3)
        if [[ $? -eq 0 ]]; then
            if [[ -n "$chroot_user" ]]; then
                CHROOT_USER="$chroot_user"
            else
                CHROOT_USER="root"
            fi
        else
            CHROOT_USER="root"
        fi
    else
        ENABLE_GUI_SUPPORT=false
    fi
    
    # Mount point selection
    if ! ROOT_MOUNT=$(dialog --title "Root Mount Point" \
                            --inputbox "Enter root mount directory:" \
                            10 50 "/mnt/chroot" \
                            3>&1 1>&2 2>&3); then
        error "No mount point specified or operation cancelled"
        exit 1
    fi
    
    if [[ -z "$ROOT_MOUNT" ]]; then
        error "Empty mount point specified"
        exit 1
    fi
    
    # Additional options for physical mode only
    if [[ "$VIRTUAL_MODE" == false ]]; then
        if [[ -d "/sys/firmware/efi" ]]; then
            if dialog --title "UEFI Detected" --yesno "UEFI system detected. Mount EFI partition?" 8 50; then
                EFI_PART=$(select_device "EFI" true) || EFI_PART=""
            fi
        fi
        
        if dialog --title "Boot Partition" --defaultno --yesno "Mount a separate boot partition?" 8 50; then
            BOOT_PART=$(select_device "Boot" true) || BOOT_PART=""
        fi
    fi
    
    return 0
}
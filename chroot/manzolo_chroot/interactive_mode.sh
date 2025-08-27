interactive_mode() {
    if [[ "$QUIET_MODE" == false ]] && ! command -v dialog &> /dev/null; then
        error "Dialog not available for interactive mode"
        exit 1
    fi
    
    if ! ROOT_DEVICE=$(select_device "Root" false); then
        error "No root device selected or operation cancelled"
        exit 1
    fi
    
    if ! check_and_unmount "$ROOT_DEVICE"; then
        exit 1
    fi

    if dialog --title "Graphical Support" --yesno "Do you need to run graphical applications (X11/Wayland) inside the chroot?\n\nThis will setup display variables and authentication files." 10 60; then
        ENABLE_GUI_SUPPORT=true
        local chroot_user
        chroot_user=$(dialog --title "Chroot User" --inputbox "Enter the user to run GUI apps as in chroot (default: root):" 10 50 "$ORIGINAL_USER" 3>&1 1>&2 2>&3)
        if [[ $? -eq 0 ]]; then
            if [[ -n "$chroot_user" ]]; then
                CHROOT_USER="$chroot_user"
            else
                warning "No user specified, defaulting to root"
                CHROOT_USER="root"
            fi
        else
            debug "Chroot user selection cancelled, defaulting to root"
            CHROOT_USER="root"
        fi
    else
        ENABLE_GUI_SUPPORT=false
    fi    

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
    
    if [[ -d "/sys/firmware/efi" ]]; then
        if dialog --title "UEFI Detected" --yesno "UEFI system detected. Mount EFI partition?" 8 50; then
            EFI_PART=$(select_device "EFI" true) || EFI_PART=""
        fi
    fi
    
    if dialog --title "Boot Partition" --yesno "Mount a separate boot partition?" 8 50; then
        BOOT_PART=$(select_device "Boot" true) || BOOT_PART=""
    fi
    
    if dialog --title "Additional Mounts" --yesno "Configure additional mount points?" 8 40; then
        local additional_mount
        if additional_mount=$(dialog --title "Additional Mount" \
                                   --inputbox "Enter device:mountpoint (e.g., /dev/sda1:/home):" \
                                   10 60 \
                                   3>&1 1>&2 2>&3); then
            if [[ -n "$additional_mount" ]]; then
                ADDITIONAL_MOUNTS+=("$additional_mount")
            fi
        fi
    fi
}

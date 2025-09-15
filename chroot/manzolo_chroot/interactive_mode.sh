interactive_mode() {
    if [[ "$QUIET_MODE" == false ]] && ! command -v dialog &> /dev/null; then
        error "Dialog not available for interactive mode"
        exit 1
    fi
    
    # First, ask the user what type of chroot they want
    local chroot_type
    if chroot_type=$(dialog --title "Chroot Type Selection" \
                           --menu "Select the type of chroot environment:" \
                           15 60 4 \
                           "physical" "Physical disk/partition chroot" \
                           "image" "Virtual disk image chroot" \
                           3>&1 1>&2 2>&3); then
        case "$chroot_type" in
            "image")
                # Check if vchroot exists in PATH
                if command -v vchroot &> /dev/null; then
                    log "Launching virtual disk image chroot (vchroot)..."
                    exec vchroot "$@"
                elif [[ -x "$SCRIPT_DIR/virtual_chroot.sh" ]]; then
                    log "Launching virtual disk image chroot (local script)..."
                    exec "$SCRIPT_DIR/virtual_chroot.sh" "$@"
                else
                    dialog --title "Error" --msgbox "vchroot command not found in PATH and virtual_chroot.sh not found in script directory.\n\nPlease install vchroot or place virtual_chroot.sh in the same directory as this script." 12 60
                    exit 1
                fi
                ;;
            "physical")
                # Continue with normal physical device chroot
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
    
    # Continue with original physical device chroot logic
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
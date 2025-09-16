setup_virtual_disk() {
    local image_file="$1"
    
    if [[ ! -f "$image_file" ]]; then
        error "File not found: $image_file"
        return 1
    fi
    
    # Find available NBD device first
    if ! find_available_nbd; then
        error "Cannot find available NBD device"
        return 1
    fi
    
    # Validate that we have an NBD device
    if [[ -z "$NBD_DEVICE" ]]; then
        error "NBD device not set after find_available_nbd"
        return 1
    fi
    
    log "Using NBD device: $NBD_DEVICE"
    connect_nbd "$image_file"
    
    # Show partition information
    log "Partitions found:"
    sudo fdisk -l "$NBD_DEVICE" 2>/dev/null | grep "^$NBD_DEVICE" || true
    
    echo ""
    log "Filesystem details:"
    
    # Detect partitions properly
    local linux_part=""
    local efi_part=""
    local luks_parts=()
    local lvm_parts=()
    
    for part in ${NBD_DEVICE}p*; do
        if [[ -e "$part" ]]; then
            local fs_type=$(sudo blkid -o value -s TYPE "$part" 2>/dev/null || echo "unknown")
            local label=$(sudo blkid -o value -s LABEL "$part" 2>/dev/null || echo "")
            local size=$(lsblk -no SIZE "$part" 2>/dev/null || echo "unknown")
            
            echo "  $part: $fs_type, Size: $size, Label: $label"
            
            # Detect partition types
            case "$fs_type" in
                ext4|ext3|ext2|xfs|btrfs)
                    local size_mb=$(lsblk -bno SIZE "$part" 2>/dev/null | awk '{print int($1/1024/1024)}')
                    if [[ -z "$linux_part" ]] || (( size_mb > 500 )); then
                        linux_part="$part"
                    fi
                    ;;
                vfat)
                    local size_mb=$(lsblk -bno SIZE "$part" 2>/dev/null | awk '{print int($1/1024/1024)}')
                    if (( size_mb < 1000 )); then
                        efi_part="$part"
                    fi
                    ;;
                crypto_LUKS|LUKS)
                    luks_parts+=("$part")
                    ;;
                LVM2_member)
                    lvm_parts+=("$part")
                    ;;
            esac
        fi
    done
    
    local luks_csv=$(IFS=,; echo "${luks_parts[*]}")
    local lvm_csv=$(IFS=,; echo "${lvm_parts[*]}")
    
    [[ -n "$efi_part" ]] && log "EFI partition found: $efi_part"
    [[ -n "$luks_csv" ]] && log "LUKS partitions found: $luks_csv"
    [[ -n "$lvm_csv" ]] && log "LVM physical volumes found: $lvm_csv"
    
    if [[ -n "$luks_csv" ]]; then
        handle_luks_open "$luks_csv"
    fi
    
    sudo partprobe 2>/dev/null || true
    sleep 1
    
    handle_lvm_activate
    
    if [[ -z "$linux_part" ]]; then
        # Try to find root LV
        local root_lv
        root_lv=$(sudo lvs --noheadings -o lv_path 2>/dev/null | head -1 || true)
        if [[ -n "$root_lv" ]]; then
            linux_part="$root_lv"
            log "Using logical volume as root: $linux_part"
        fi
    fi
    
    if [[ -z "$linux_part" ]]; then
        error "No Linux partition found in virtual disk"
        return 1
    fi
    
    ROOT_DEVICE="$linux_part"
    EFI_PART="$efi_part"
    
    log "Linux partition found: $ROOT_DEVICE"
    return 0
}

select_image_file() {
    local current_dir="$PWD"
    local selected=""
    local show_hidden=${SHOW_HIDDEN:-0}

    while true; do
        local menu_items=()

        if [[ "$current_dir" != "/" ]]; then
            menu_items+=(".." "Go to parent directory")
        fi

        # Find directories and image files
        while IFS= read -r -d '' item; do
            local name=$(basename "$item")
            if [[ -d "$item" ]]; then
                menu_items+=("📁 $name" "Directory")
            elif [[ "$name" == *.vhd || "$name" == *.vtoy || "$name" == *.qcow2 || \
                    "$name" == *.img || "$name" == *.raw || "$name" == *.vmdk ]]; then
                menu_items+=("💾 $name" "Disk image")
            fi
        done < <(find "$current_dir" -maxdepth 1 \( -type d -o -type f \) \
                 -not -path "$current_dir" \
                 $([ $show_hidden -eq 0 ] && echo '-not -name ".*"') \
                 -print0 2>/dev/null | sort -z)

        if [[ ${#menu_items[@]} -eq 0 ]]; then
            error "No image files or directories found in $current_dir"
            return 1
        fi

        selected=$(dialog --title "Select image file or directory" \
                         --menu "Current: $current_dir" 20 60 12 \
                         "${menu_items[@]}" 2>&1 >/dev/tty) || return 1

        local raw_name=$(echo "$selected" | sed 's/^[📁💾] //')

        if [[ "$selected" == ".." ]]; then
            current_dir=$(dirname "$current_dir")
        elif [[ -d "$current_dir/$raw_name" ]]; then
            current_dir="$current_dir/$raw_name"
        elif [[ -f "$current_dir/$raw_name" ]]; then
            echo "$current_dir/$raw_name"
            return 0
        fi
    done
}
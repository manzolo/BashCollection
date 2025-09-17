# Fix per setup_virtual_disk() - dare priorità ai LV invece che alle partizioni
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
                    # NON dare priorità automaticamente alle partizioni ext4
                    # Le useremo solo come fallback se non troviamo LV
                    debug "Found ext4 partition: $part (size: $size)"
                    if [[ -z "$linux_part" ]]; then
                        linux_part="$part"
                        debug "Set as potential fallback root: $part"
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
    
    # Gestisci LUKS prima di tutto
    if [[ -n "$luks_csv" ]]; then
        handle_luks_open "$luks_csv"
    fi
    
    sudo partprobe 2>/dev/null || true
    sleep 1
    
    # Gestisci LVM dopo LUKS
    handle_lvm_activate
    
    # ORA cerca il miglior candidato per root
    # PRIORITÀ: 1. Logical Volume, 2. Partizione ext4
    
    local best_root_candidate=""
    
    # Prima priorità: cerca logical volume appropriato
    if [[ ${#ACTIVATED_VGS[@]} -gt 0 ]]; then
        log "Searching for root logical volume in activated VGs..."
        
        for vg in "${ACTIVATED_VGS[@]}"; do
            [[ -z "$vg" ]] && continue
            
            local all_lvs
            all_lvs=$(sudo lvs --noheadings -o lv_name,lv_size "$vg" 2>/dev/null || true)
            
            debug "Logical volumes in $vg:"
            while IFS= read -r lv_line; do
                [[ -z "$lv_line" ]] && continue
                debug "  $lv_line"
            done <<< "$all_lvs"
            
            # Cerca LV con nomi che indicano root
            local root_lv_names
            root_lv_names=$(sudo lvs --noheadings -o lv_path "$vg" 2>/dev/null | grep -E "(root|ubuntu|system)" || true)
            
            if [[ -n "$root_lv_names" ]]; then
                local first_root_lv
                first_root_lv=$(echo "$root_lv_names" | head -1 | awk '{print $1}')
                if [[ -n "$first_root_lv" ]]; then
                    best_root_candidate="$first_root_lv"
                    log "Found root-like LV: $best_root_candidate"
                    break
                fi
            fi
            
            # Se non trova LV con nome "root", prendi il più grande
            if [[ -z "$best_root_candidate" ]]; then
                local largest_lv
                largest_lv=$(sudo lvs --noheadings -o lv_path,lv_size --units b "$vg" 2>/dev/null | \
                           sort -k2 -nr | head -1 | awk '{print $1}' || true)
                if [[ -n "$largest_lv" ]]; then
                    best_root_candidate="$largest_lv"
                    log "Using largest LV as root: $best_root_candidate"
                    break
                fi
            fi
        done
    fi
    
    # Seconda priorità: usa partizione ext4 come fallback
    if [[ -z "$best_root_candidate" ]] && [[ -n "$linux_part" ]]; then
        best_root_candidate="$linux_part"
        log "No logical volumes found, using ext4 partition as fallback: $best_root_candidate"
    fi
    
    # Verifica finale
    if [[ -z "$best_root_candidate" ]]; then
        error "No suitable root device found in virtual disk"
        error "Checked: LVM logical volumes, ext4 partitions"
        return 1
    fi
    
    ROOT_DEVICE="$best_root_candidate"
    EFI_PART="$efi_part"
    
    log "Selected root device: $ROOT_DEVICE"
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
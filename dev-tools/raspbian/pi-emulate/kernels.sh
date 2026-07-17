# ==============================================================================
# KERNEL MANAGEMENT
# ==============================================================================

manage_kernels() {
    local choice
    choice=$(dialog --title "Kernel Management" --menu "Select action:" 15 60 6 \
        "1" "List installed kernels" \
        "2" "Download specific kernel" \
        "3" "Download all modern kernels" \
        "4" "Auto-select best kernel for OS" \
        "5" "Remove old kernels" \
        "6" "Back" \
        2>&1 >/dev/tty)
    
    case $choice in
        1) list_kernels ;;
        2) download_specific_kernel ;;
        3) download_all_modern_kernels ;;
        4) auto_select_kernel ;;
        5) cleanup_old_kernels ;;
        6) return ;;
    esac
}

list_kernels() {
    local kernel_list=""
    kernel_list+="Installed Kernels:\n\n"
    
    for kernel in "$KERNELS_DIR"/kernel-*; do
        if [ -f "$kernel" ]; then
            local basename=$(basename "$kernel")
            local size=$(du -h "$kernel" | cut -f1)
            kernel_list+="• $basename ($size)\n"
        fi
    done
    
    if [ -z "$(ls -A "$KERNELS_DIR" 2>/dev/null)" ]; then
        kernel_list+="No kernels installed.\n"
    fi
    
    dialog --title "Installed Kernels" --msgbox "$kernel_list" 20 60
}

download_specific_kernel() {
    local kernel_menu=""
    local counter=1
    
    for version in "${!KERNEL_DB[@]}"; do
        IFS='|' read -r url os_type status <<< "${KERNEL_DB[$version]}"
        kernel_menu+="$counter \"$version - $os_type [$status]\" "
        ((counter++))
    done
    
    local choice
    choice=$(eval dialog --title \"Download Kernel\" --menu \"Select kernel version:\" 15 60 6 $kernel_menu 2>&1 >/dev/tty)
    
    [ -z "$choice" ] && return
    
    local versions=(${!KERNEL_DB[@]})
    local selected_version="${versions[$((choice-1))]}"
    
    download_kernel_version "$selected_version"
}

download_kernel_version() {
    local version=$1
    IFS='|' read -r url os_type status <<< "${KERNEL_DB[$version]}"
    
    local kernel_file="${KERNELS_DIR}/kernel-qemu-${version}-${os_type}"
    
    if [ -f "$kernel_file" ]; then
        log INFO "Kernel $version already installed at $kernel_file"
        return
    fi
    
    log INFO "Downloading kernel $version from $url"
    wget --progress=bar:force -O "$kernel_file" "$url" 2>>"$LOG_FILE"
    
    if [ ! -f "$kernel_file" ] || [ ! -s "$kernel_file" ]; then
        log ERROR "Failed to download kernel $version"
        return 1
    fi
    
    # Download corresponding DTB if needed
    local dtb_url="${url%.gz}-dtb"
    local dtb_file="${DTBS_DIR}/versatile-pb-${version}.dtb"
    log INFO "Attempting to download DTB for kernel $version from $dtb_url"
    wget -q -O "$dtb_file" "$dtb_url" 2>>"$LOG_FILE" || {
        log WARNING "DTB for kernel $version not found or failed to download"
    }
    
    log INFO "Kernel $version downloaded successfully to $kernel_file"
}

download_all_modern_kernels() {
    dialog --title "Downloading Modern Kernels" --infobox "Downloading modern kernels...\nThis may take a few minutes." 6 50
    
    for version in "${!KERNEL_DB[@]}"; do
        IFS='|' read -r url os_type status <<< "${KERNEL_DB[$version]}"
        if [ "$status" = "modern" ]; then
            download_kernel_version "$version" || true
        fi
    done
    
    dialog --msgbox "Modern kernels downloaded!" 8 40
}

auto_select_kernel() {
    local os_type=$1
    
    case $os_type in
        jessie) echo "kernel-qemu-4.4.34-jessie" ;;
        stretch) echo "kernel-qemu-4.14.79-stretch" ;;
        buster) echo "kernel-qemu-5.4.51-buster" ;;
        bullseye) echo "kernel-qemu-5.10.63-bullseye" ;;
        *) echo "kernel-qemu-4.4.34-jessie" ;;  # Default fallback
    esac
}

cleanup_old_kernels() {
    local old_kernels=$(find "$KERNELS_DIR" -name "*4.4.34*" -o -name "*4.14*" 2>/dev/null)
    
    if [ -z "$old_kernels" ]; then
        dialog --msgbox "No old kernels found!" 8 40
        return
    fi
    
    if dialog --yesno "Remove old/legacy kernels?\n\nThis will keep only modern kernels (5.x)" 10 50; then
        echo "$old_kernels" | xargs rm -f
        dialog --msgbox "Old kernels removed!" 8 40
    fi
}
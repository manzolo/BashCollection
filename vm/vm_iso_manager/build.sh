# Fixed Ubuntu ISO building function
build_ubuntu_iso() {
    local workdir="$1"
    local outfile="$2"
    local volid="UBUNTU_CUSTOM"
    
    echo "[INFO] Building Ubuntu ISO with hybrid boot support..."
    
    # Ubuntu 24.04+ uses GRUB2, not isolinux
    # Look for the correct boot files
    local grub_bios_img=""
    local grub_efi_img=""
    
    # Find GRUB BIOS boot image (eltorito.img)
    if [[ -f "$workdir/boot/grub/i386-pc/eltorito.img" ]]; then
        grub_bios_img="boot/grub/i386-pc/eltorito.img"
    elif [[ -f "$workdir/[BOOT]/1-Boot-NoEmul.img" ]]; then
        grub_bios_img="[BOOT]/1-Boot-NoEmul.img"
    fi
    
    # Find EFI boot image - look for the actual ESP (EFI System Partition) image
    if [[ -f "$workdir/[BOOT]/2-Boot-NoEmul.img" ]]; then
        grub_efi_img="[BOOT]/2-Boot-NoEmul.img"
    elif [[ -f "$workdir/boot/grub/efi.img" ]]; then
        grub_efi_img="boot/grub/efi.img"
    fi
    
    echo "[DEBUG] GRUB BIOS image: ${grub_bios_img:-'NOT FOUND'}"
    echo "[DEBUG] GRUB EFI image: ${grub_efi_img:-'NOT FOUND'}"
    
    # Build based on what we have
    if [[ -n "$grub_bios_img" && -n "$grub_efi_img" ]]; then
        echo "[INFO] Creating hybrid BIOS+UEFI Ubuntu ISO..."
        
        # Create hybrid ISO with both BIOS and UEFI support
        if ! xorriso -as mkisofs \
            -iso-level 3 -full-iso9660-filenames -joliet -joliet-long -rock \
            -volid "$volid" \
            -rational-rock \
            -cache-inodes \
            -J -l \
            -b "$grub_bios_img" \
            -c "boot/grub/boot.cat" \
            -no-emul-boot -boot-load-size 4 -boot-info-table \
            -eltorito-alt-boot \
            -e "$grub_efi_img" \
            -no-emul-boot \
            -append_partition 2 0xef "$workdir/$grub_efi_img" \
            -partition_offset 16 \
            -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
            -isohybrid-gpt-basdat \
            -isohybrid-apm-hfsplus \
            -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1; then
            
            echo "[WARNING] Hybrid build with partition failed, trying without append_partition..."
            
            # Try without append_partition (simpler hybrid)
            if ! xorriso -as mkisofs \
                -iso-level 3 -joliet -joliet-long -rock \
                -volid "$volid" \
                -b "$grub_bios_img" \
                -c "boot/grub/boot.cat" \
                -no-emul-boot -boot-load-size 4 -boot-info-table \
                -eltorito-alt-boot \
                -e "$grub_efi_img" \
                -no-emul-boot \
                -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
                -isohybrid-gpt-basdat \
                -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1; then
                
                echo "[WARNING] Simple hybrid failed, trying basic dual boot..."
                
                # Fallback: basic dual boot
                xorriso -as mkisofs \
                    -iso-level 3 -joliet -rock \
                    -volid "$volid" \
                    -b "$grub_bios_img" \
                    -c "boot/grub/boot.cat" \
                    -no-emul-boot -boot-load-size 4 -boot-info-table \
                    -eltorito-alt-boot \
                    -e "$grub_efi_img" \
                    -no-emul-boot \
                    -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "Ubuntu hybrid ISO creation failed"
            fi
        fi
        
    elif [[ -n "$grub_efi_img" ]]; then
        echo "[INFO] Creating UEFI-only Ubuntu ISO..."
        
        # UEFI-only with proper EFI System Partition
        if ! xorriso -as mkisofs \
            -iso-level 3 -joliet -joliet-long -rock \
            -volid "$volid" \
            -e "$grub_efi_img" \
            -no-emul-boot \
            -append_partition 2 0xef "$workdir/$grub_efi_img" \
            -partition_offset 16 \
            -isohybrid-gpt-basdat \
            -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1; then
            
            # Fallback: simple UEFI
            xorriso -as mkisofs \
                -iso-level 3 -joliet -rock \
                -volid "$volid" \
                -e "$grub_efi_img" \
                -no-emul-boot \
                -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "Ubuntu UEFI ISO creation failed"
        fi
        
    elif [[ -n "$grub_bios_img" ]]; then
        echo "[INFO] Creating BIOS-only Ubuntu ISO..."
        
        xorriso -as mkisofs \
            -iso-level 3 -joliet -rock \
            -volid "$volid" \
            -b "$grub_bios_img" \
            -c "boot/grub/boot.cat" \
            -no-emul-boot -boot-load-size 4 -boot-info-table \
            -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "Ubuntu BIOS ISO creation failed"
    else
        echo "[ERROR] No suitable boot images found for Ubuntu"
        echo "[DEBUG] Available boot files:"
        find "$workdir" -name "*.img" -o -name "*.efi" | grep -E "(boot|grub|efi)" | head -10
        error "Cannot create bootable Ubuntu ISO - no boot images found"
    fi
    
    echo "[INFO] Ubuntu ISO created successfully"
    
    # Verify the ISO
    if command -v isoinfo >/dev/null 2>&1; then
        echo "[INFO] Verifying ISO structure..."
        if isoinfo -d -i "$outfile" >/dev/null 2>&1; then
            echo "[INFO] ISO structure verification passed"
        else
            echo "[WARNING] ISO structure verification failed"
        fi
    fi
}

# Simplified ISO building - one function per boot type
build_bootable_iso() {
    local workdir="$1"
    local outfile="$2"
    local iso_type="$3"
    
    echo "[INFO] Building bootable ISO for type: $iso_type"
    
    # Special handling for Ubuntu
    if [[ "$iso_type" == "ubuntu" ]]; then
        build_ubuntu_iso "$workdir" "$outfile"
        return 0
    fi
    
    # Determine volume ID
    local volid="CUSTOM_ISO"
    case "$iso_type" in
        windows) volid="WINDOWS_CUSTOM" ;;
        redhat) volid="REDHAT_CUSTOM" ;;
        gparted) volid="GPARTED_CUSTOM" ;;
        linux) volid="LINUX_CUSTOM" ;;
    esac
    
    # Look for boot files
    local has_isolinux=$(find "$workdir" -name "isolinux.bin" -o -name "syslinux.bin" | head -n1)
    local has_efi=$(find "$workdir" -path "*/EFI/*" -name "*.efi" -o -name "*.img" | head -n1)
    local has_windows_boot=$(find "$workdir" -name "etfsboot.com" -o -name "bootmgr" | head -n1)
    local has_efi_windows=$(find "$workdir" -name "efisys.bin" -o -name "bootmgfw.efi" | head -n1)
    
    # Choose build method based on what we find
    if [[ "$iso_type" == "windows" ]]; then
        build_windows_iso "$workdir" "$outfile" "$volid" "$has_windows_boot" "$has_efi_windows"
    elif [[ -n "$has_isolinux" && -n "$has_efi" ]]; then
        build_hybrid_iso "$workdir" "$outfile" "$volid" "$has_isolinux" "$has_efi"
    elif [[ -n "$has_isolinux" ]]; then
        build_bios_iso "$workdir" "$outfile" "$volid" "$has_isolinux"
    elif [[ -n "$has_efi" ]]; then
        build_uefi_iso "$workdir" "$outfile" "$volid" "$has_efi"
    else
        build_generic_iso "$workdir" "$outfile" "$volid"
    fi
}

build_windows_iso() {
    local workdir="$1"
    local outfile="$2"
    local volid="$3"
    local bios_boot="$4"
    local efi_boot="$5"
    
    echo "[INFO] Building Windows ISO..."
    
    # Special handling for Windows 11 UDF format
    if [[ -n "$bios_boot" && -n "$efi_boot" ]]; then
        echo "[INFO] Creating dual-boot Windows ISO"
        local bios_rel=$(realpath --relative-to="$workdir" "$bios_boot")
        local efi_rel=$(realpath --relative-to="$workdir" "$efi_boot")
        
        # Windows 11 style with UDF support
        xorriso -as mkisofs \
            -iso-level 4 -joliet -joliet-long -rock \
            -volid "$volid" \
            -allow-limited-size \
            -b "$bios_rel" \
            -no-emul-boot -boot-load-size 8 -boot-info-table \
            -eltorito-alt-boot \
            -e "$efi_rel" \
            -no-emul-boot \
            -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
            -isohybrid-gpt-basdat \
            -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || {
                
            echo "[WARNING] Modern Windows dual-boot failed, trying simplified version..."
            xorriso -as mkisofs \
                -iso-level 4 -joliet -rock \
                -volid "$volid" \
                -b "$bios_rel" \
                -no-emul-boot -boot-load-size 8 -boot-info-table \
                -eltorito-alt-boot \
                -e "$efi_rel" \
                -no-emul-boot \
                -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "Windows dual-boot ISO creation failed"
            }
            
    elif [[ -n "$efi_boot" ]]; then
        echo "[INFO] Creating UEFI-only Windows ISO"
        local efi_rel=$(realpath --relative-to="$workdir" "$efi_boot")
        
        xorriso -as mkisofs \
            -iso-level 4 -joliet -joliet-long -rock \
            -volid "$volid" \
            -allow-limited-size \
            -e "$efi_rel" \
            -no-emul-boot \
            -isohybrid-gpt-basdat \
            -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "Windows UEFI ISO creation failed"
            
    elif [[ -n "$bios_boot" ]]; then
        echo "[INFO] Creating BIOS-only Windows ISO"
        local bios_rel=$(realpath --relative-to="$workdir" "$bios_boot")
        
        xorriso -as mkisofs \
            -iso-level 3 -joliet -rock \
            -volid "$volid" \
            -b "$bios_rel" \
            -no-emul-boot -boot-load-size 8 -boot-info-table \
            -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "Windows BIOS ISO creation failed"
    else
        error "Windows boot files not found"
    fi
}

build_hybrid_iso() {
    local workdir="$1"
    local outfile="$2"
    local volid="$3"
    local isolinux_bin="$4"
    local efi_boot="$5"
    
    echo "[INFO] Creating hybrid BIOS+UEFI ISO..."
    
    local isolinux_rel=$(realpath --relative-to="$workdir" "$isolinux_bin")
    local efi_rel=$(realpath --relative-to="$workdir" "$efi_boot")
    local boot_dir=$(dirname "$isolinux_rel")
    
    xorriso -as mkisofs \
        -iso-level 3 -full-iso9660-filenames -joliet -rock \
        -volid "$volid" \
        -b "$isolinux_rel" \
        -c "$boot_dir/boot.cat" \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot \
        -e "$efi_rel" \
        -no-emul-boot \
        -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "Hybrid ISO creation failed"
}

build_bios_iso() {
    local workdir="$1"
    local outfile="$2"
    local volid="$3"
    local isolinux_bin="$4"
    
    echo "[INFO] Creating BIOS-only ISO..."
    
    local isolinux_rel=$(realpath --relative-to="$workdir" "$isolinux_bin")
    local boot_dir=$(dirname "$isolinux_rel")
    
    xorriso -as mkisofs \
        -iso-level 3 -full-iso9660-filenames -joliet -rock \
        -volid "$volid" \
        -b "$isolinux_rel" \
        -c "$boot_dir/boot.cat" \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "BIOS ISO creation failed"
}

build_uefi_iso() {
    local workdir="$1"
    local outfile="$2"
    local volid="$3"
    local efi_boot="$4"
    
    echo "[INFO] Creating UEFI-only ISO..."
    
    local efi_rel=$(realpath --relative-to="$workdir" "$efi_boot")
    
    xorriso -as mkisofs \
        -iso-level 3 -full-iso9660-filenames -joliet -rock \
        -volid "$volid" \
        -e "$efi_rel" \
        -no-emul-boot \
        -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "UEFI ISO creation failed"
}

build_generic_iso() {
    local workdir="$1"
    local outfile="$2"
    local volid="$3"
    
    echo "[INFO] Building generic ISO (no boot)..."
    
    xorriso -as mkisofs \
        -iso-level 3 -joliet -rock \
        -volid "$volid" \
        -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "Generic ISO creation failed"
}
#!/bin/bash
set -euo pipefail

DEBUG_MODE=0

LOGFILE="/tmp/isoedit.log"
rm -f "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1
echo "=== ISO EDIT START $(date) ==="

error() {
    echo "[ERROR] $1"
    whiptail --title "Error" --msgbox "$1" 10 60
    [[ -n "${tmpdir:-}" ]] && rm -rf "$tmpdir" 2>/dev/null || true
    echo "[INFO] See log at $LOGFILE"
    exit 1
}

install_dependency() {
    local cmd=$1
    local pkg=$2
    if ! whiptail --yesno "The command '$cmd' is missing. Do you want to install it with:\nsudo apt-get install $pkg ?" 12 60; then
        error "Please install '$cmd' manually:\nsudo apt-get install $pkg"
    fi
    sudo apt-get update
    sudo apt-get install -y "$pkg" || error "Installation of $pkg failed"
}

check_dependencies() {
    local deps=("whiptail:whiptail" "7z:p7zip-full" "file:file" "isoinfo:genisoimage")
    
    # Check for xorriso first (preferred)
    if ! command -v xorriso &>/dev/null; then
        install_dependency "xorriso" "xorriso"
    fi
    
    # Check other dependencies
    for dep in "${deps[@]}"; do
        local cmd=${dep%%:*}
        local pkg=${dep##*:}
        if ! command -v "$cmd" &>/dev/null; then
            install_dependency "$cmd" "$pkg"
        fi
    done
}

select_image_file() {
    local current_dir="$PWD"
    local selected=""
    while true; do
        local menu_items=()
        [[ "$current_dir" != "/" ]] && menu_items+=(".." "Parent folder")
        while IFS= read -r -d '' item; do
            menu_items+=("💿 $(basename "$item")" "ISO file")
        done < <(find "$current_dir" -maxdepth 1 -type f -iname "*.iso" -print0 | sort -z)
        while IFS= read -r -d '' item; do
            [[ -d "$item" && "$item" != "$current_dir" && "$item" != "$current_dir/." ]] && menu_items+=("📁 $(basename "$item")" "Folder")
        done < <(find "$current_dir" -maxdepth 1 -type d -not -name ".*" -print0 2>/dev/null || true)
        [[ ${#menu_items[@]} -eq 0 ]] && error "No files or directories found in $current_dir"

        selected=$(whiptail --title "Select ISO file" --menu "Folder: $current_dir" 20 70 15 "${menu_items[@]}" 3>&1 1>&2 2>&3) || return 1
        local raw_name=$(echo "$selected" | sed 's/^[^ ]* //')
        if [[ "$selected" == ".." ]]; then
            current_dir=$(dirname "$current_dir")
        elif [[ "$selected" == 📁* ]]; then
            current_dir="$current_dir/$raw_name"
        elif [[ -f "$current_dir/$raw_name" ]]; then
            echo "$current_dir/$raw_name"
            return 0
        fi
    done
}

detect_iso_type() {
    local workdir="$1"
    
    # Windows Detection
    if find "$workdir" -type f -name "bootmgr*" -o -name "winload.exe" | grep -q . || [[ -d "$workdir/sources" ]]; then
        echo "windows"
        return 0
    fi
    
    # Ubuntu Detection (modern Ubuntu uses GRUB2, not isolinux)
    if [[ -d "$workdir/casper" ]] || [[ -f "$workdir/ubuntu" ]] || [[ -d "$workdir/.disk" ]]; then
        echo "ubuntu"
        return 0
    fi
    
    # CentOS/RHEL/Rocky/Alma Detection
    if [[ -f "$workdir/.discinfo" ]] || [[ -f "$workdir/.treeinfo" ]] || [[ -d "$workdir/BaseOS" ]]; then
        echo "redhat"
        return 0
    fi
    
    # GParted Detection
    if [[ -f "$workdir/GParted-Live-Version" ]] || [[ -d "$workdir/syslinux" && -d "$workdir/utils" ]]; then
        echo "gparted"
        return 0
    fi
    
    # Generic Linux Detection
    if [[ -d "$workdir/isolinux" ]] || [[ -d "$workdir/syslinux" ]] || [[ -d "$workdir/live" ]]; then
        echo "linux"
        return 0
    fi
    
    # UEFI Detection
    if [[ -d "$workdir/EFI" ]]; then
        echo "uefi"
        return 0
    fi
    
    echo "unknown"
}

# Fixed Ubuntu ISO building function
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

cleanup_tempdir() {
    [[ -n "${tmpdir:-}" ]] && rm -rf "$tmpdir" 2>/dev/null || true
}

test_iso_with_qemu() {
    local iso_file="$1"
    local mode="$2"
    
    case "$mode" in
        "bios")
            echo "[INFO] Starting QEMU in BIOS mode..."
            qemu-system-x86_64 -m 2G -cdrom "$iso_file" -boot d -enable-kvm 2>/dev/null || \
            qemu-system-x86_64 -m 2G -cdrom "$iso_file" -boot d
            ;;
        "uefi")
            echo "[INFO] Starting QEMU in UEFI mode..."
            local ovmf_code=""
            
            # Find OVMF files
            for ovmf_dir in "/usr/share/OVMF" "/usr/share/ovmf" "/usr/share/qemu" "/usr/share/edk2-ovmf"; do
                if [[ -f "$ovmf_dir/OVMF_CODE.fd" ]]; then
                    ovmf_code="$ovmf_dir/OVMF_CODE.fd"
                    break
                elif [[ -f "$ovmf_dir/OVMF.fd" ]]; then
                    ovmf_code="$ovmf_dir/OVMF.fd"
                    break
                fi
            done
            
            [[ -z "$ovmf_code" ]] && error "OVMF firmware not found. Install with: sudo apt-get install ovmf"
            
            qemu-system-x86_64 -m 2G -cdrom "$iso_file" -boot d \
                -drive if=pflash,format=raw,readonly,file="$ovmf_code" \
                -enable-kvm 2>/dev/null || \
            qemu-system-x86_64 -m 2G -cdrom "$iso_file" -boot d \
                -drive if=pflash,format=raw,readonly,file="$ovmf_code"
            ;;
    esac
}

main() {
    check_dependencies

    tmpdir=$(mktemp -d /tmp/isoedit.XXXXXX) || error "Could not create temporary directory"
    echo "[INFO] Temporary directory: $tmpdir"
    trap 'cleanup_tempdir' INT TERM EXIT

    file=$(select_image_file) || exit 1
    echo "[INFO] Selected ISO file: $file"
    basefile=$(basename "$file" .iso)
    basefile=$(basename "$basefile" .ISO)

    mkdir -p "$tmpdir/work" || error "Could not create working directory"
    
    # Extract ISO
    echo "[INFO] Extracting ISO..."
    7z x -aoa "$file" -o"$tmpdir/work" >>"$LOGFILE" 2>&1 || error "7z extraction failed"

    sudo chown -R $(id -u):$(id -g) "$tmpdir/work"
    chmod -R u+rwX "$tmpdir/work"

    file_count=$(find "$tmpdir/work" -type f | wc -l)
    echo "[INFO] Extracted $file_count files"

    # Detect ISO type
    iso_type=$(detect_iso_type "$tmpdir/work")
    echo "[INFO] Detected ISO type: $iso_type"

    # Show boot info for Ubuntu
    echo "[INFO] Boot analysis:"
    [[ -d "$tmpdir/work/isolinux" ]] && echo "  - Found ISOLINUX (BIOS boot)"
    [[ -d "$tmpdir/work/syslinux" ]] && echo "  - Found SYSLINUX (BIOS boot)"  
    [[ -d "$tmpdir/work/EFI" ]] && echo "  - Found EFI directory (UEFI boot)"
    [[ -d "$tmpdir/work/boot/grub" ]] && echo "  - Found GRUB directory (Ubuntu GRUB2 boot)"
    [[ -f "$(find "$tmpdir/work" -name "bootmgr*" | head -n1)" ]] && echo "  - Found Windows Boot Manager"
    [[ -f "$(find "$tmpdir/work" -name "efi.img" | head -n1)" ]] && echo "  - Found EFI boot image"

    # Create custom README
    cat > "$tmpdir/work/CUSTOM_README.txt" <<EOF
=== ISO Editor - Custom Build ===
Original ISO: $file
Extracted files: $file_count
ISO Type: $iso_type
Modified: $(date)

This ISO has been customized using the ISO Editor script.
For more information, see the log at: $LOGFILE
EOF

    whiptail --msgbox "Extraction complete!\n\nPath: $tmpdir/work\nFiles: $file_count\nType: $iso_type\n\nPress OK to continue with editing..." 15 70

    # Interactive shell
    clear
    echo "=============================================="
    echo "ISO Editor - Interactive Mode"
    echo "=============================================="
    echo "Working directory: $tmpdir/work"
    echo "Files extracted: $file_count"
    echo "ISO Type: $iso_type"
    echo ""
    echo "You can now modify the files as needed."
    echo "Type 'exit' when you're done to rebuild the ISO."
    echo "=============================================="
    echo ""
    
    cd "$tmpdir/work" || error "Could not access working directory"
    stty sane
    $SHELL
    clear

    # Rebuild ISO
    outfile="${file%/*}/${basefile}-CUSTOM.iso"
    build_bootable_iso "$tmpdir/work" "$outfile" "$iso_type"

    whiptail --msgbox "ISO successfully created!\n\nLocation: $outfile\nType: $iso_type\n\nReady for testing!" 12 70
    
    cleanup_tempdir
    trap - INT TERM EXIT

    echo "=== ISO EDIT END $(date) ==="

    # Test menu
    while true; do
        choice=$(whiptail --title "Test ISO with QEMU" --menu "Select test mode for: $outfile" 15 70 4 \
            "1" "Test BIOS mode" \
            "2" "Test UEFI mode" \
            "3" "Show ISO info" \
            "4" "Exit" 3>&1 1>&2 2>&3) || choice=4

        case "$choice" in
            1) test_iso_with_qemu "$outfile" "bios" ;;
            2) test_iso_with_qemu "$outfile" "uefi" ;;
            3)
                clear
                echo "=== ISO Information ==="
                echo "File: $outfile"
                echo "Size: $(du -h "$outfile" | cut -f1)"
                echo "Type: $iso_type"
                echo ""
                echo "=== Structure ==="
                isoinfo -d -i "$outfile" 2>/dev/null || echo "Could not read ISO info"
                echo ""
                read -p "Press Enter to continue..."
                ;;
            4)
                echo "[INFO] Your custom ISO is ready at: $outfile"
                break
                ;;
        esac
    done
}

main
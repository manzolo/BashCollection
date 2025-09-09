#!/bin/bash
set -euo pipefail

LOGFILE="/tmp/isoedit.log"
rm -f "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1
echo "=== ISO EDIT START $(date) ==="

# Variabili globali per preservare informazioni di boot
BOOT_TYPE=""
BOOT_IMAGE=""
BOOT_CATALOG=""
ELTORITO_OPTS=""

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
    
    # Check for ISO creation tools (multiple options)
    local iso_tool_found=false
    
    # Check xorriso version and capabilities
    if command -v xorriso &>/dev/null; then
        local xorriso_version=$(xorriso -version 2>&1 | head -n1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "unknown")
        echo "[INFO] xorriso version: $xorriso_version"
        iso_tool_found=true
        
        # Test if xorriso supports UDF
        if xorriso -help 2>&1 | grep -q "\-udf"; then
            echo "[INFO] xorriso supports UDF"
        else
            echo "[WARNING] xorriso version doesn't support UDF, will use alternative methods"
        fi
    fi
    
    # Check genisoimage
    if command -v genisoimage &>/dev/null; then
        echo "[INFO] genisoimage found: $(genisoimage --version 2>&1 | head -n1 || echo 'version unknown')"
        iso_tool_found=true
    fi
    
    # Check mkisofs as fallback
    if command -v mkisofs &>/dev/null; then
        echo "[INFO] mkisofs found: $(mkisofs --version 2>&1 | head -n1 || echo 'version unknown')"
        iso_tool_found=true
    fi
    
    if ! $iso_tool_found; then
        install_dependency "xorriso or genisoimage" "xorriso genisoimage"
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

analyze_boot_info() {
    local isofile="$1"
    echo "[INFO] Analyzing boot information..."
    
    # Usa isoinfo per ottenere informazioni dettagliate
    local bootinfo
    bootinfo=$(isoinfo -d -i "$isofile" 2>/dev/null || true)
    
    if echo "$bootinfo" | grep -q "El Torito"; then
        echo "[INFO] El Torito boot found"
        BOOT_TYPE="eltorito"
        
        # Estrai informazioni più dettagliate
        local bootentry
        bootentry=$(isoinfo -d -i "$isofile" | grep -A 20 "El Torito" || true)
        
        # Cerca il boot catalog
        local boot_catalog_sector
        boot_catalog_sector=$(echo "$bootentry" | grep -o "Boot catalog starts at sector [0-9]*" | grep -o "[0-9]*" || echo "")
        
        if [[ -n "$boot_catalog_sector" ]]; then
            BOOT_CATALOG="boot.catalog"
            echo "[INFO] Boot catalog found at sector $boot_catalog_sector"
        fi
        
        # Determina se è UEFI o BIOS
        if echo "$bootentry" | grep -q -i "efi\|uefi"; then
            BOOT_TYPE="uefi"
            echo "[INFO] UEFI boot detected"
        else
            echo "[INFO] BIOS boot detected"
        fi
    fi
    
    # Salva le informazioni complete per debug
    echo "$bootinfo" > "$tmpdir/original_boot_info.txt"
}

extract_with_boot_preservation() {
    local isofile="$1"
    local workdir="$2"
    
    echo "[INFO] Extracting ISO with boot preservation..."
    
    # Prima estrai normalmente con 7z
    7z x -aoa "$isofile" -o"$workdir" >>"$LOGFILE" 2>&1 || error "7z extraction failed"
    
    # Poi estrai anche usando xorriso per preservare metadati
    echo "[INFO] Extracting boot information with xorriso..."
    xorriso -indev "$isofile" -extract / "$workdir/xorriso_extract" >>"$LOGFILE" 2>&1 || true
    
    # Se xorriso ha estratto file aggiuntivi, copiali
    if [[ -d "$workdir/xorriso_extract" ]]; then
        rsync -av "$workdir/xorriso_extract/" "$workdir/" >>"$LOGFILE" 2>&1 || true
        rm -rf "$workdir/xorriso_extract"
    fi
}

detect_iso_type() {
    local workdir="$1"
    
    # Controlla per Windows
    if find "$workdir" -type f -name "bootmgr*" -o -name "winload.exe" -o -name "Boot" -type d | grep -q .; then
        echo "windows"
        return 0
    fi
    
    # Controlla per Linux
    if find "$workdir" -type f -name "vmlinuz*" -o -name "initrd*" -o -name "isolinux.bin" | grep -q .; then
        echo "linux"
        return 0
    fi
    
    # Controlla per macOS
    if find "$workdir" -type d -name "*.app" -o -name "System" | grep -q .; then
        echo "macos"
        return 0
    fi
    
    echo "unknown"
}

build_bootable_iso() {
    local workdir="$1"
    local outfile="$2"
    local iso_type="$3"
    
    echo "[INFO] Building bootable ISO for type: $iso_type"
    
    case "$iso_type" in
        "windows")
            build_windows_iso "$workdir" "$outfile"
            ;;
        "linux")
            build_linux_iso "$workdir" "$outfile"
            ;;
        *)
            build_generic_iso "$workdir" "$outfile"
            ;;
    esac
}

build_windows_iso() {
    local workdir="$1"
    local outfile="$2"
    
    echo "[INFO] Building bootable Windows ISO..."
    
    # Cerca i file di boot necessari
    local bootfile
    local efi_boot
    
    bootfile=$(find "$workdir" -name "etfsboot.com" -o -name "bootmgr" | head -n1)
    efi_boot=$(find "$workdir" -name "efisys.bin" -o -name "bootmgfw.efi" | head -n1)
    
    if [[ -n "$bootfile" && -n "$efi_boot" ]]; then
        # ISO con supporto dual boot (BIOS + UEFI)
        echo "[INFO] Creating dual-boot Windows ISO (BIOS + UEFI)"
        
        # Metodo 1: Usa xorriso nativo (senza -as mkisofs)
        if ! xorriso -outdev "$outfile" \
            -volid "WINDOWS_CUSTOM" \
            -joliet on -rock \
            -compliance joliet_long_paths:on \
            -map "$workdir" / \
            -boot_image any next \
            -boot_image any system_area="$(realpath --relative-to="$workdir" "$bootfile")" \
            -boot_image any partition_table=on \
            -boot_image isolinux dir="$(dirname "$(realpath --relative-to="$workdir" "$bootfile")")" \
            -boot_image any cat_path=/boot.cat \
            -boot_image grub bin_path="$(realpath --relative-to="$workdir" "$efi_boot")" \
            -boot_image any platform_id=0xef \
            -boot_image any emul=no_emulation >>"$LOGFILE" 2>&1; then
            
            echo "[WARNING] xorriso native method failed, trying alternative approach..."
            
            # Metodo 2: Usa genisoimage per dual boot
            if command -v genisoimage &>/dev/null; then
                echo "[INFO] Using genisoimage for dual boot"
                genisoimage -allow-limited-size -iso-level 4 \
                    -b "$(realpath --relative-to="$workdir" "$bootfile")" \
                    -no-emul-boot -boot-load-size 8 -boot-info-table \
                    -eltorito-alt-boot \
                    -e "$(realpath --relative-to="$workdir" "$efi_boot")" \
                    -no-emul-boot \
                    -J -R -V "WINDOWS_CUSTOM" \
                    -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || {
                        
                        echo "[WARNING] genisoimage dual boot failed, trying xorriso without UDF..."
                        
                        # Metodo 3: xorriso -as mkisofs senza -udf
                        xorriso -as mkisofs \
                            -iso-level 4 -joliet -rock \
                            -volid "WINDOWS_CUSTOM" \
                            -b "$(realpath --relative-to="$workdir" "$bootfile")" \
                            -no-emul-boot -boot-load-size 8 -boot-info-table \
                            -eltorito-alt-boot \
                            -e "$(realpath --relative-to="$workdir" "$efi_boot")" \
                            -no-emul-boot \
                            -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "All Windows dual-boot methods failed"
                    }
            else
                error "genisoimage not found and xorriso native method failed"
            fi
        fi
            
    elif [[ -n "$bootfile" ]]; then
        # Solo BIOS
        echo "[INFO] Creating BIOS-only Windows ISO"
        
        # Prova prima con genisoimage (più affidabile per Windows)
        if command -v genisoimage &>/dev/null; then
            genisoimage -allow-limited-size \
                -b "$(realpath --relative-to="$workdir" "$bootfile")" \
                -no-emul-boot -boot-load-size 8 -boot-info-table \
                -J -R -V "WINDOWS_CUSTOM" \
                -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || {
                    
                    # Fallback con xorriso
                    xorriso -as mkisofs \
                        -iso-level 3 -joliet -rock \
                        -volid "WINDOWS_CUSTOM" \
                        -b "$(realpath --relative-to="$workdir" "$bootfile")" \
                        -no-emul-boot -boot-load-size 8 -boot-info-table \
                        -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "BIOS Windows ISO creation failed"
                }
        else
            # Solo xorriso
            xorriso -as mkisofs \
                -iso-level 3 -joliet -rock \
                -volid "WINDOWS_CUSTOM" \
                -b "$(realpath --relative-to="$workdir" "$bootfile")" \
                -no-emul-boot -boot-load-size 8 -boot-info-table \
                -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "BIOS Windows ISO creation failed"
        fi
    else
        error "Windows boot files not found"
    fi
}

build_linux_iso() {
    local workdir="$1"
    local outfile="$2"
    
    echo "[INFO] Building bootable Linux ISO..."
    
    # Cerca isolinux
    local isolinux_bin
    local isolinux_dir
    
    isolinux_bin=$(find "$workdir" -name "isolinux.bin" | head -n1)
    
    if [[ -n "$isolinux_bin" ]]; then
        isolinux_dir=$(dirname "$isolinux_bin")
        local rel_path=$(realpath --relative-to="$workdir" "$isolinux_bin")
        
        echo "[INFO] Found isolinux at: $rel_path"
        
        xorriso -as mkisofs \
            -iso-level 3 -full-iso9660-filenames -joliet -rock \
            -volid "LINUX_CUSTOM" \
            -b "$rel_path" \
            -c "$(dirname "$rel_path")/boot.cat" \
            -no-emul-boot -boot-load-size 4 -boot-info-table \
            -o "$outfile" "$workdir" >>"$LOGFILE" 2>&1 || error "Failed to create Linux ISO"
    else
        # Prova con syslinux
        local syslinux_bin
        syslinux_bin=$(find "$workdir" -name "syslinux" -o -name "ldlinux.sys" | head -n1)
        
        if [[ -n "$syslinux_bin" ]]; then
            echo "[INFO] Found syslinux, creating ISO..."
            build_generic_iso "$workdir" "$outfile"
        else
            error "Linux boot files not found (isolinux or syslinux)"
        fi
    fi
}

build_generic_iso() {
    local workdir="$1"
    local outfile="$2"
    
    echo "[INFO] Building generic ISO..."
    
    xorriso -outdev "$outfile" \
        -blank as_needed \
        -volid "CUSTOM_ISO" \
        -joliet on -rock \
        -map "$workdir" / >>"$LOGFILE" 2>&1 || error "Generic ISO creation failed"
}

cleanup_tempdir() {
    [[ -n "${tmpdir:-}" ]] && rm -rf "$tmpdir" 2>/dev/null || true
}

test_iso_with_qemu() {
    local iso_file="$1"
    local mode="$2"
    local iso_name="$3"
    
    case "$mode" in
        "bios")
            echo "[INFO] Starting QEMU $iso_name in BIOS/MBR mode..."
            qemu-system-x86_64 -m 4G -cdrom "$iso_file" -boot d -enable-kvm 2>/dev/null || \
            qemu-system-x86_64 -m 4G -cdrom "$iso_file" -boot d
            ;;
        "uefi")
            echo "[INFO] Starting QEMU $iso_name in UEFI mode..."
            local ovmf_code=""
            local ovmf_vars=""
            
            # Cerca i file OVMF in diverse posizioni
            for ovmf_dir in "/usr/share/OVMF" "/usr/share/ovmf" "/usr/share/qemu" "/usr/share/edk2-ovmf"; do
                if [[ -f "$ovmf_dir/OVMF_CODE.fd" ]]; then
                    ovmf_code="$ovmf_dir/OVMF_CODE.fd"
                    ovmf_vars="$ovmf_dir/OVMF_VARS.fd"
                    break
                elif [[ -f "$ovmf_dir/OVMF.fd" ]]; then
                    ovmf_code="$ovmf_dir/OVMF.fd"
                    break
                fi
            done
            
            [[ -z "$ovmf_code" ]] && error "OVMF firmware not found. Install with: sudo apt-get install ovmf"
            
            if [[ -n "$ovmf_vars" ]]; then
                # Copia OVMF_VARS in temp per modifiche
                local temp_vars="/tmp/OVMF_VARS_$$.fd"
                cp "$ovmf_vars" "$temp_vars"
                
                qemu-system-x86_64 -m 4G -cdrom "$iso_file" -boot d \
                    -drive if=pflash,format=raw,readonly,file="$ovmf_code" \
                    -drive if=pflash,format=raw,file="$temp_vars" \
                    -enable-kvm 2>/dev/null || \
                qemu-system-x86_64 -m 4G -cdrom "$iso_file" -boot d \
                    -drive if=pflash,format=raw,readonly,file="$ovmf_code" \
                    -drive if=pflash,format=raw,file="$temp_vars"
                    
                rm -f "$temp_vars"
            else
                qemu-system-x86_64 -m 4G -cdrom "$iso_file" -boot d \
                    -drive if=pflash,format=raw,readonly,file="$ovmf_code" \
                    -enable-kvm 2>/dev/null || \
                qemu-system-x86_64 -m 4G -cdrom "$iso_file" -boot d \
                    -drive if=pflash,format=raw,readonly,file="$ovmf_code"
            fi
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

    # Analizza informazioni di boot prima dell'estrazione
    analyze_boot_info "$file"

    mkdir -p "$tmpdir/work" || error "Could not create working directory"
    
    # Estrai con preservazione delle informazioni di boot
    extract_with_boot_preservation "$file" "$tmpdir/work"

    sudo chown -R $(id -u):$(id -g) "$tmpdir/work"
    chmod -R u+rwX "$tmpdir/work"

    file_count=$(find "$tmpdir/work" -type f | wc -l)
    echo "[INFO] Extracted $file_count files"

    # Rileva tipo di ISO
    iso_type=$(detect_iso_type "$tmpdir/work")
    echo "[INFO] Detected ISO type: $iso_type"

    # Rimuovi README esistenti e crea il nostro
    for readme in "$tmpdir/work/"{README,readme,ReadMe}*; do
        [[ -f "$readme" ]] && rm -f "$readme"
    done

    cat > "$tmpdir/work/CUSTOM_README.txt" <<EOF
=== ISO Editor - Custom Build ===
Original ISO: $file
Extracted files: $file_count
ISO Type: $iso_type
Boot Type: $BOOT_TYPE
Modified: $(date)

This ISO has been customized using the ISO Editor script.
EOF

    whiptail --msgbox "Extraction complete!\nPath: $tmpdir/work\nFiles: $file_count\nType: $iso_type" 15 60

    # Apri shell interattiva
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

    # Ricostruisci ISO
    outfile="${file%/*}/${basefile}-CUSTOM.iso"
    build_bootable_iso "$tmpdir/work" "$outfile" "$iso_type"

    whiptail --msgbox "ISO successfully created!\nLocation: $outfile\nType: $iso_type" 12 70
    cleanup_tempdir
    trap - INT TERM EXIT

    echo "=== ISO EDIT END $(date) ==="

    # Menu finale per testare ISO
    while true; do
        choice=$(whiptail --title "Test ISO with QEMU" --menu "Select ISO and boot mode" 20 70 6 \
            "1" "Test ORIGINAL ISO - BIOS mode" \
            "2" "Test ORIGINAL ISO - UEFI mode" \
            "3" "Test CUSTOM ISO - BIOS mode" \
            "4" "Test CUSTOM ISO - UEFI mode" \
            "5" "Show ISO info" \
            "6" "Exit" 3>&1 1>&2 2>&3) || choice=6

        case "$choice" in
            1) test_iso_with_qemu "$file" "bios" "ORIGINAL" ;;
            2) test_iso_with_qemu "$file" "uefi" "ORIGINAL" ;;
            3) test_iso_with_qemu "$outfile" "bios" "CUSTOM" ;;
            4) test_iso_with_qemu "$outfile" "uefi" "CUSTOM" ;;
            5)
                echo "=== Original ISO Info ==="
                file "$file"
                echo ""
                isoinfo -d -i "$file" 2>/dev/null || echo "Could not read ISO info"
                echo ""
                echo "=== Custom ISO Info ==="
                file "$outfile"
                echo ""
                isoinfo -d -i "$outfile" 2>/dev/null || echo "Could not read ISO info"
                read -p "Press Enter to continue..."
                ;;
            6)
                echo "[INFO] Testing complete. Your custom ISO is ready at: $outfile"
                break
                ;;
        esac
    done
}

main

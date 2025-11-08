#!/bin/bash
# PKG_NAME: vm-iso-manager
# PKG_VERSION: 1.0.0
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), whiptail, xorriso, squashfs-tools
# PKG_RECOMMENDS: genisoimage, isolinux
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Interactive ISO image editor and builder
# PKG_LONG_DESCRIPTION: Tool for editing and building bootable ISO images.
#  .
#  Features:
#  - Extract and modify ISO contents
#  - Rebuild bootable ISOs
#  - Interactive file browser
#  - UEFI and BIOS boot support
#  - Custom kernel and initrd support
#  - Squashfs filesystem handling
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

set -euo pipefail

DEBUG_MODE=0

# Determine the directory where the script is located (resolving symlinks)
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

shopt -s globstar

# Scan and "source" .sh file recursive.
for script in "$SCRIPT_DIR/vm-iso-manager/"**/*.sh; do
    if [ -f "$script" ]; then
        source "$script"
    else
        echo "Error: file script $script not found."
        exit 1
    fi
done

shopt -u globstar

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

cleanup_tempdir() {
    [[ -n "${tmpdir:-}" ]] && rm -rf "$tmpdir" 2>/dev/null || true
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